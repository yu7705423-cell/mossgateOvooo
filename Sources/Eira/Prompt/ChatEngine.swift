import Foundation

/// 一轮回复从头到尾：拼请求 → 发一次 → 切成几条 → 一条一条落库。照网页版 Conversation.js 的 generate 与 reply.js 的 renderTurn。
///
/// 一轮只调一次接口（网页版第 15 条）。图片、语音、视频原生版还不能生成，照网页版「没配接口」的样子落成
/// media 为 off 的消息，界面上显示文字描述，不另外调接口。
enum ChatEngine {
    /// 每落一条调一次，界面据此刷新。
    typealias OnRow = @Sendable (Message) -> Void

    /// 生成这一轮。失败时写一条 status 为 error 的消息（网页版同样），再把错误抛给界面。
    static func reply(chatId: String, onRow: @escaping OnRow) async throws {
        guard let chat = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
        guard let charId = chat.characterIds.first, let char = try Repo.character(charId) else {
            throw StoreError(message: "这段会话的角色不存在")
        }
        let settings = AppSettings.load()
        let built = try ChatPrompt.build(chat: chat, char: char, settings: settings)
        let turnId = Ids.make("turn")

        let result: AIService.Result
        do {
            result = try await AIService.shared.send(task: "chat.reply", system: built.system, messages: built.messages)
        } catch {
            var row = Message.new(chatId: chat.id, role: .char, authorId: char.id, content: "", turnId: turnId)
            row.row["status"] = .string("error")
            row.row["error"] = .string(error.localizedDescription)
            try? Repo.save(row)
            onRow(row)
            throw error
        }

        try markRecalled(built.recalled)
        // 交给模型看过的图标成看过，往后不再重传
        for id in built.seenImages {
            guard var row = try Database.shared.get(Collections.messages, id: id) else { continue }
            row["vision"] = .string("done")
            try Database.shared.put(Collections.messages, row)
        }
        try await write(raw: result.text, chat: chat, char: char, turnId: turnId,
                        served: ["id": .string(result.presetId), "name": .string(result.presetName)], onRow: onRow)
    }

    /// 把一次回复落成消息。parts 之间按网页版的节奏停顿：非文字 700 毫秒，文字 320 + 每字 28 毫秒，最多 1.8 秒。
    static func write(raw: String, chat: Chat, char: Character, turnId: String, served: [String: JSONValue],
                      instant: Bool = false, onRow: @escaping OnRow) async throws {
        let parsed = ReplyParser.split(raw)
        guard !parsed.parts.isEmpty else { throw StoreError(message: "模型返回了空内容") }

        let narrationOn = chat.row.bool("narration")
        let parts = parsed.parts.filter { $0.type != .narration || narrationOn }
        var created: [Message] = []
        var lastAt = 0.0
        var sawSilence = false

        for (i, part) in parts.enumerated() {
            if part.type == .silence { sawSilence = true; continue }
            guard var m = row(for: part, chat: chat, char: char, turnId: turnId) else { continue }
            if created.isEmpty {
                m.row["raw"] = .string(raw)
                m.row["think"] = .string(parsed.think)
                m.row["swipes"] = .array([.string(raw)])
                m.row["swipeIndex"] = .number(0)
                m.row["served"] = .array([.object(served)])
                if let stamp = parsed.stamp { m.row["stamp"] = .string(stampBody(stamp)) }
            }
            // 同一毫秒的两条排序不稳，至少隔一毫秒
            let at = max(Date().millis, lastAt + 1)
            m.row["createdAt"] = .number(at)
            m.row["updatedAt"] = .number(at)
            lastAt = at
            try Repo.save(m)
            created.append(m)
            onRow(m)
            if !instant && i < parts.count - 1 {
                let ms = part.type == .text ? min(1800, 320 + part.text.count * 28) : 700
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            }
        }

        if created.isEmpty && sawSilence {
            var m = Message.new(chatId: chat.id, role: .char, authorId: char.id, content: "[不回复]", kind: "silence", turnId: turnId)
            m.row["raw"] = .string(raw)
            m.row["think"] = .string(parsed.think)
            m.row["swipes"] = .array([.string(raw)])
            m.row["swipeIndex"] = .number(0)
            try Repo.save(m)
            created.append(m)
            onRow(m)
        }

        if !created.isEmpty, var c = try Repo.chat(chat.id) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
    }

    /// 一段落成一条消息。content 一律是协议里的那种写法，和网页版存的一字不差。
    private static func row(for p: ReplyParser.Part, chat: Chat, char: Character, turnId: String) -> Message? {
        func make(_ kind: String, _ content: String) -> Message {
            Message.new(chatId: chat.id, role: .char, authorId: char.id, content: content, kind: kind, turnId: turnId)
        }
        var m: Message
        switch p.type {
        case .text:
            m = make("text", p.text)
        case .image:
            m = make("image", "[图片：\(p.text)]")
            m.row["prompt"] = .string(p.text)
            m.row["imageId"] = .null
            m.row["media"] = .string("off")
            m.row["mediaError"] = .string("还没有配置生图接口")
        case .clip:
            m = make("clip", "[视频：\(p.text)]")
            m.row["prompt"] = .string(p.text)
            m.row["clipId"] = .null
            m.row["posterId"] = .null
            m.row["media"] = .string("off")
            m.row["mediaError"] = .string("还没有配置视频接口")
        case .voice:
            m = make("voice", "[语音：\(p.text)]")
            m.row["voiceText"] = .string(p.text)
            m.row["audioId"] = .null
            m.row["media"] = .string("off")
            m.row["mediaError"] = .string("还没有配置语音接口")
        case .sticker:
            let found = sticker(named: p.text)
            m = make("sticker", "[表情：\(found?.string("name") ?? p.text)]")
            m.row["stickerId"] = found.map { JSONValue.string($0.id) } ?? .null
            m.row["stickerName"] = .string(p.text)
        case .location:
            let content = [p.text, p.address ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            m = make("location", "[位置：\(content)]")
            m.row["place"] = .string(p.text)
            m.row["address"] = .string(p.address ?? "")
        case .narration:
            m = make("narration", "[旁白：\(p.text)]")
            m.row["narration"] = .string(p.text)
        case .dice:
            let faces = Int(chat.row.number("diceFaces") ?? 6)
            let value = Int.random(in: 1...max(2, faces))
            m = make("dice", "[骰子：\(value)]")
            m.row["faces"] = .number(Double(faces))
            m.row["value"] = .number(Double(value))
        case .silence:
            return nil
        }
        if let t = p.translation, !t.isEmpty, t != p.text { m.row["translation"] = .string(t) }
        if let inner = p.inner { m.row["inner"] = .string(String(inner.prefix(300))) }
        if let it = p.innerTrans { m.row["innerTrans"] = .string(String(it.prefix(600))) }
        if p.recall, char.row["canRecall"]?.bool != false {
            // 角色撤回：晚两秒半折起来，让人先看见一眼（网页版 recall.js 的 charMark）
            m.row["recalled"] = .object(["at": .number(Date().millis + 2500), "by": .string("char")])
        }
        if let q = p.quote { applyQuote(q, to: &m, chatId: chat.id) }
        return m
    }

    /// 引用：在最近 40 条里找去掉空白之后含这段话的那一条；找不到只存摘录。
    private static func applyQuote(_ q: String, to m: inout Message, chatId: String) {
        let needle = q.filter { !$0.isWhitespace }
        let recent = (try? Repo.messages(chatId: chatId, limit: 40)) ?? []
        let hit = recent.reversed().first { !needle.isEmpty && $0.content.filter { !$0.isWhitespace }.contains(needle) }
        m.row["quoteId"] = hit.map { JSONValue.string($0.id) } ?? .null
        m.row["quoteText"] = .string(String((hit?.content ?? q).prefix(40)))
        if let hit {
            m.row["quoteRole"] = .string(hit.role.rawValue)
            m.row["quoteAuthorId"] = .string(hit.authorId)
        }
    }

    private static func sticker(named name: String) -> Row? {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"\.(png|jpe?g|gif|webp)$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .lowercased()
        }
        let rows = (try? Database.shared.all("stickers")) ?? []
        // 重名的写成「名字（分组）」
        if let m = name.range(of: #"^(.+?)（(.+)）$"#, options: .regularExpression) {
            let inner = String(name[m])
            let parts = inner.dropLast().split(separator: "（", maxSplits: 1).map(String.init)
            if parts.count == 2, let r = rows.first(where: { norm($0.string("name")) == norm(parts[0]) && $0.string("group") == parts[1] }) {
                return r
            }
        }
        return rows.first { norm($0.string("name")) == norm(name) }
    }

    /// 时间戳去掉括号与「时间：」，只留时间本身（历史里写回 `[…] `）。
    private static func stampBody(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let f = t.first, "[【(（".contains(f) { t.removeFirst() }
        if let l = t.last, "]】)）".contains(l) { t.removeLast() }
        return t.replacingOccurrences(of: #"^\s*(?:时间|時間|time)\s*[:：]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    /// 发送成功之后，这一轮召回的记忆记一次「用过」。
    private static func markRecalled(_ ids: [String]) throws {
        for id in ids {
            guard var row = try Database.shared.get(Collections.memories, id: id) else { continue }
            row["useCount"] = .number((row.number("useCount") ?? 0) + 1)
            row["lastUsedAt"] = .number(Date().millis)
            try Database.shared.put(Collections.memories, row)
        }
    }

    /// 用户发一张图（已经由 Images.save 存好）。content 写 `[图片]`，和网页版存的一样；
    /// 识图交给聊天模型时标成待看，下一次请求带上原图。
    static func sendImage(imageId: String, chatId: String) throws -> Message {
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: "[图片]", kind: "image")
        m.row["imageId"] = .string(imageId)
        m.row["vision"] = .string(AppSettings.load().visionMode == "chat" ? "chat" : "off")
        try Repo.save(m)
        if var c = try Repo.chat(chatId) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
        return m
    }

    /// 用户发一条文字。
    static func send(text: String, chatId: String) throws -> Message {
        let m = Message.new(chatId: chatId, role: .user, authorId: "me", content: text)
        try Repo.save(m)
        if var c = try Repo.chat(chatId) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
        return m
    }
}
