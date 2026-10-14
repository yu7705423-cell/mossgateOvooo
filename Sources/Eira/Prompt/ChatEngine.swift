import Foundation

/// 一轮回复从头到尾：拼请求 → 发一次 → 切成几条 → 一条一条落库。照网页版 Conversation.js 的 generate 与 reply.js 的 renderTurn。
///
/// 一轮只调一次接口（网页版第 15 条）。角色写的图片、语音在配了接口时每条生成一次（ImageGen、VoiceGen）；视频原生版还不能生成，
/// 照网页版「没配接口」的样子落成 media 为 off 的消息，界面上显示文字描述，不另外调接口。
enum ChatEngine {
    /// 每落一条调一次，界面据此刷新。
    typealias OnRow = @Sendable (Message) -> Void

    /// 一轮回复的几个版本。存在这一轮第一条上：swipes 是每个版本的原文，served 是每个版本用的哪套接口。
    struct Versions: Sendable {
        var swipes: [String]
        var index: Int
        var served: [JSONValue]
    }

    /// 生成这一轮。失败时写一条 status 为 error 的消息（网页版同样），再把错误抛给界面。
    ///
    /// regenerate 为 true 时重新生成最后一轮：拿去掉这一轮之后的同样前文再请求一次（网页版 streamReply 的 excludeTurn），
    /// **成功之后**才换掉旧的那几条，新的原文追加成一个新版本。失败时旧的那一轮原样留着，不写失败的消息。
    static func reply(chatId: String, regenerate: Bool = false, onRow: @escaping OnRow) async throws {
        guard let chat = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
        guard let charId = chat.characterIds.first, let char = try Repo.character(charId) else {
            throw StoreError(message: "这段会话的角色不存在")
        }
        var old: Turn?
        if regenerate {
            guard let t = try lastTurn(chatId: chatId) else { throw StoreError(message: "没有可以重新生成的回复") }
            old = t
        }
        let settings = AppSettings.load().forChat(chat)
        // 当日日程：这个角色开了、今天还没排、今天还没自动试过，先排一次再拼上下文（默认关，一天一次）
        if !chat.isGroup { await DayPlan.ensureToday(char.id) }
        // 关系底色：开着且 S 级记忆变过时重压一次。不等它：这一轮用旧的，下一轮是新的（默认关）
        if !chat.isGroup && settings.raw["bondAuto"]?.bool == true {
            let cid = char.id, pid = chat.personaId
            Task.detached { await Bond.autoRun(charId: cid, personaId: pid) }
        }
        let built: ChatPrompt.Built
        if chat.isGroup {
            // 一个能说话的都没有：不调接口。调了写出来的也一句都发不出去
            let members = GroupChat.members(chat)
            guard !GroupChat.speaking(chat, members: members).isEmpty else { throw StoreError(message: "群成员都在禁言中，本轮不调用接口") }
            built = try ChatPrompt.buildGroup(chat: chat, members: members, settings: settings, excludeTurn: old?.id)
        } else {
            built = try ChatPrompt.build(chat: chat, char: char, settings: settings, excludeTurn: old?.id)
        }
        let turnId = old?.id ?? Ids.make("turn")

        let result: AIService.Result
        do {
            result = try await AIService.shared.send(task: "chat.reply", system: built.system, messages: built.messages)
        } catch {
            if old != nil { throw error }
            var row = Message.new(chatId: chat.id, role: .char, authorId: char.id, content: "", turnId: turnId)
            row.row["status"] = .string("error")
            row.row["error"] = .string(error.localizedDescription)
            row = (try? Repo.append(row)) ?? row
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
        let served: JSONValue = .object(["id": .string(result.presetId), "name": .string(result.presetName)])
        var versions = Versions(swipes: [result.text], index: 0, served: [served])
        if let old {
            versions.swipes = old.versions.swipes + [result.text]
            versions.index = versions.swipes.count - 1
            versions.served = old.versions.served + [served]
        }
        // 先确认新的切得出内容，再删旧的：模型回了一段空白，不能把原来那一轮也弄没了
        guard !plan(raw: result.text, chat: chat, char: char).plan.isEmpty else { throw StoreError(message: "模型返回了空内容") }
        if let old { try removeRows(old.rows, turnId: old.id, chatId: chat.id) }
        let created = try await write(raw: result.text, chat: chat, char: char, turnId: turnId, versions: versions, onRow: onRow)
        // 心声「单独生成」那一档：整轮说完之后另调一次（默认关，在会话设置里开）
        if let m = await InnerVoice.attach(chat: chat, char: char, created: created) { onRow(m) }
    }

    // MARK: - 轮与版本

    struct Turn: Sendable {
        var id: String
        var rows: [Message]
        var versions: Versions
    }

    /// 最后一轮：最后一条是角色说的、带 turnId 时，末尾连着的、同一个 turnId 的那几条。失败的那一条不算。
    static func lastTurn(chatId: String) throws -> Turn? {
        let all = try Repo.messages(chatId: chatId).filter { !$0.isError }
        guard let last = all.last, last.role == .char, !last.turnId.isEmpty else { return nil }
        let rows = Array(all.reversed().prefix { $0.turnId == last.turnId }.reversed())
        guard let head = rows.first(where: { $0.row["swipes"] != nil || $0.row["raw"] != nil }) ?? rows.first else { return nil }
        var swipes = head.row["swipes"]?.array?.compactMap(\.string) ?? []
        if swipes.isEmpty, let raw = head.row["raw"]?.string { swipes = [raw] }
        if swipes.isEmpty { swipes = [rows.map(\.content).joined(separator: "\n")] }
        let index = min(max(0, Int(head.row.number("swipeIndex") ?? Double(swipes.count - 1))), swipes.count - 1)
        let served = head.row["served"]?.array ?? []
        return Turn(id: last.turnId, rows: rows, versions: Versions(swipes: swipes, index: index, served: served))
    }

    /// 在最后一轮的几个版本之间切换。存着的原文重新切一遍，**不调接口**。
    static func switchVersion(chatId: String, step: Int, onRow: @escaping OnRow) async throws {
        guard let t = try lastTurn(chatId: chatId), t.versions.swipes.count > 1,
              let chat = try Repo.chat(chatId),
              let char = try chat.characterIds.first.flatMap({ try Repo.character($0) }) else { return }
        let n = t.versions.swipes.count
        var v = t.versions
        v.index = ((v.index + step) % n + n) % n
        guard !plan(raw: v.swipes[v.index], chat: chat, char: char).plan.isEmpty else { throw StoreError(message: "这个版本没有内容") }
        try removeRows(t.rows, turnId: t.id, chatId: chatId)
        try await write(raw: v.swipes[v.index], chat: chat, char: char, turnId: t.id, versions: v, instant: true, onRow: onRow)
    }

    /// 换掉一整轮：这一轮的消息删掉（收款、拆礼物那几行删掉时那一笔回到待处理），这一轮贴的回应一并撤掉。
    private static func removeRows(_ rows: [Message], turnId: String, chatId: String) throws {
        for m in rows { try Interact.drop(m) }
        try Interact.undoReactions(chatId: chatId, turnId: turnId)
    }

    typealias Plan = [(part: ReplyParser.Part, char: Character)]

    /// 一次回复切成「谁说了什么」。一对一时全是同一个人；群聊时先按名字拆回各人，再各自切（网页版 renderGroupTurn）。
    static func plan(raw: String, chat: Chat, char: Character) -> (plan: Plan, think: String, stamp: String?) {
        guard chat.isGroup else {
            let parsed = ReplyParser.split(raw)
            return (parsed.parts.map { (part: $0, char: char) }, parsed.think, parsed.stamp)
        }
        let members = GroupChat.members(chat)
        let byId = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let msgs = (try? Repo.messages(chatId: chat.id)) ?? []
        let personas = (try? Repo.personas()) ?? []
        let me = personas.first { $0.id == chat.personaId } ?? ((try? Repo.activePersona(.load())) ?? nil)
        var out: Plan = []
        var stamp: String?
        for (i, seg) in GroupChat.splitSpeakers(raw, members: members, chat: chat, userName: me?.name ?? "",
                                                fallback: GroupChat.pendingMentions(msgs).first ?? "").enumerated() {
            guard let who = byId[seg.charId] else { continue }
            let parsed = ReplyParser.split(seg.text)
            if i == 0 { stamp = parsed.stamp }
            out += parsed.parts.map { (part: $0, char: who) }
        }
        return (out, ReplyParser.stripThink(raw).1, stamp)
    }

    /// 把一次回复落成消息。parts 之间按网页版的节奏停顿：非文字 700 毫秒，文字 320 + 每字 28 毫秒，最多 1.8 秒。
    @discardableResult
    static func write(raw: String, chat: Chat, char: Character, turnId: String, versions: Versions,
                      instant: Bool = false, onRow: @escaping OnRow) async throws -> [Message] {
        let parsed = plan(raw: raw, chat: chat, char: char)
        guard !parsed.plan.isEmpty else { throw StoreError(message: "模型返回了空内容") }
        func head(_ m: inout Message) {
            m.row["raw"] = .string(raw)
            m.row["think"] = .string(parsed.think)
            m.row["swipes"] = .array(versions.swipes.map { .string($0) })
            m.row["swipeIndex"] = .number(Double(versions.index))
            m.row["served"] = .array(versions.served)
        }

        let narrationOn = chat.row.bool("narration")
        let steps = parsed.plan.filter { $0.part.type != .narration || narrationOn }
        let parts = steps.map(\.part)
        var created: [Message] = []
        var sawSilence = false
        // 角色写的 [图片：…]、[语音：…] 在后台一条一条生成，不挡着这一轮结束。中途停下也照样交出去：落库时已经占住了
        defer { MediaJobs.launch(created, onRow: onRow) }

        for (i, step) in steps.enumerated() {
            let part = step.part
            let who = step.char
            if part.type == .silence { sawSilence = true; continue }
            // 被禁言的成员这一轮写的一概不落。每一条都现查
            if chat.isGroup, let now = try Repo.chat(chat.id), GroupChat.isMuted(now, who.id) { continue }
            let built = try effect(part, chat: chat, char: who, turnId: turnId) ?? row(for: part, chat: chat, char: who, turnId: turnId, draw: !instant)
            guard var m = built else { continue }
            if created.isEmpty {
                head(&m)
                if let stamp = parsed.stamp { m.row["stamp"] = .string(stampBody(stamp)) }
            }
            m = try Repo.append(m)
            created.append(m)
            onRow(m)
            if !instant && i < parts.count - 1 {
                let ms = part.type == .text ? min(1800, 320 + part.text.count * 28) : 700
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            }
        }

        // 一条气泡都没落、而模型写了 [不回复] 或只回应了：落一行「已读，未回复」，原文与版本挂在它上面
        let reacted = parts.contains { $0.type == .react }
        if created.isEmpty && (sawSilence || reacted) {
            var m = Message.new(chatId: chat.id, role: .char, authorId: steps.first?.char.id ?? char.id, content: "[不回复]", kind: "silence", turnId: turnId)
            m.row["reacted"] = .bool(reacted)
            head(&m)
            m = try Repo.append(m)
            created.append(m)
            onRow(m)
        }

        if !created.isEmpty, var c = try Repo.chat(chat.id) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
        return created
    }

    /// 不是一条消息、而是一件事的那几样：收款、拆礼物、拍一拍、回应、改备注（网页版 reply.js 的 renderPart）。
    /// 改完状态，需要落一行提示的返回那一行；什么都不落的返回 nil。不是这几样的也返回 nil，交给 row(for:)。
    private static func effect(_ p: ReplyParser.Part, chat: Chat, char: Character, turnId: String) throws -> Message? {
        switch p.type {
        case .settle:
            // 处理的是对方那一笔。没有待处理的就当没写过这一行
            guard let target = try Interact.pendingTransfer(chat.id, from: .user) else { return nil }
            return try Interact.settleTransfer(target.id, take: p.flag, turnId: turnId)
        case .unwrap:
            guard let target = try Interact.pendingGift(chat.id, from: .user) else { return nil }
            return try Interact.settleGift(target.id, open: p.flag, turnId: turnId)
        case .meal:
            guard let target = try Interact.pendingTakeout(chat.id, from: .user) else { return nil }
            return try Interact.settleTakeout(target.id, take: p.flag, turnId: turnId)
        case .pat:
            guard char.row["canPat"]?.bool != false else { return nil }
            return Interact.pat(chatId: chat.id, role: .char, turnId: turnId)
        case .agenda:
            // 只认角色自己的事项；找不到那一条就不改（网页版 reply.js 的 agenda）
            try DayPlan.mark(char, title: p.text, done: p.flag)
            return nil
        case .remark:
            guard char.row["canRemark"]?.bool != false, !chat.isGroup else { return nil }
            return try Interact.setTheirRemark(chatId: chat.id, name: p.text, char: char, turnId: turnId)
        case .react:
            // 按摘录找到那一条贴上去；没写摘录的贴到对方最近一条上。认不出是哪一条的丢掉
            guard char.row["canReact"]?.bool != false else { return nil }
            let recent = (try? Repo.messages(chatId: chat.id, limit: 60)) ?? []
            var target: Message?
            if let q = p.extra {
                let needle = q.filter { !$0.isWhitespace }
                target = recent.reversed().first { $0.turnId != turnId && !needle.isEmpty && $0.content.filter { !$0.isWhitespace }.contains(needle) }
            } else {
                target = recent.last { $0.role == .user && !$0.isError && $0.kind != "silence" }
            }
            if let target { try Interact.toggleReaction(target.id, emoji: p.text, by: char.id, turnId: turnId) }
            return nil
        default:
            return nil
        }
    }

    /// 一段落成一条消息。content 一律是协议里的那种写法，和网页版存的一字不差。
    /// draw 为假（切换版本时重新落一遍）：图片不进生成队列，留一句原因，要画由用户点「重新生成」。切一次版本不能多画一张。
    private static func row(for p: ReplyParser.Part, chat: Chat, char: Character, turnId: String, draw: Bool = true) -> Message? {
        func make(_ kind: String, _ content: String) -> Message {
            Message.new(chatId: chat.id, role: .char, authorId: char.id, content: content, kind: kind, turnId: turnId)
        }
        var m: Message
        switch p.type {
        case .text:
            m = make("text", p.text)
            // 命中禁写词的留个记号，气泡下方标出来。本地扫的，不依赖模型听不听话（网页版 ban.js）
            let banned = Ban.scan(p.text, Ban.list(.load()))
            if !banned.isEmpty { m.row["ban"] = .array(banned.map { .string($0) }) }
        case .image:
            m = make("image", "[图片：\(p.text)]")
            m.row["prompt"] = .string(p.text)
            m.row["imageId"] = .null
            let ready = AppSettings.load().imageReady
            m.row["media"] = .string(ready && draw ? "pending" : "off")
            // 落库这一刻就占住：界面不会先看到「中断」，用户也点不出第二张
            if ready && draw { _ = MediaJobs.claim(m.id) }
            m.row["mediaError"] = .string(!ready ? "还没有配置生图接口" : draw ? "" : "切换版本后未自动生成")
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
            let s = AppSettings.load()
            let speak = VoiceGen.canSpeak(char, s)
            m.row["media"] = .string(speak && draw ? "pending" : "off")
            m.row["mediaError"] = .string(!s.voiceReady ? "还没有配置语音接口" : !speak ? "这个角色在当前语音接口上还没有配音色" : draw ? "" : "切换版本后未自动合成")
            if speak && draw { _ = MediaJobs.claim(m.id) }
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
        case .transfer:
            guard let a = p.amount, let t = try? Interact.transfer(make("transfer", ""), amount: a, note: p.text) else { return nil }
            m = t
        case .gift:
            guard let g = try? Interact.gift(make("gift", ""), cover: p.text, inner: p.extra ?? "") else { return nil }
            m = g
        case .takeout:
            guard let t = try? Interact.takeout(make("takeout", ""), kind: p.extra ?? "self", item: p.text, amount: p.amount ?? 0) else { return nil }
            m = t
        case .silence, .settle, .unwrap, .pat, .react, .remark, .meal, .agenda:
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
    /// 识图交给聊天模型时标成待看，下一次请求带上原图；选了单独的识图接口时标成 pending，由 Vision.describe 读成描述。
    static func sendImage(imageId: String, chatId: String) throws -> Message {
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: "[图片]", kind: "image")
        m.row["imageId"] = .string(imageId)
        let s = AppSettings.load()
        m.row["vision"] = .string(s.visionMode == "chat" ? "chat" : (s.visionMode == "api" && s.visionPreset != nil) ? "pending" : "off")
        m = try Repo.append(m)
        if var c = try Repo.chat(chatId) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
        return m
    }

    /// 用户发一个表情。content 写 `[表情：名字]`，和网页版存的一样（Conversation.js 的 sendSticker）。
    static func sendSticker(_ st: Stickers.Item, chatId: String, quote: Message? = nil) throws -> Message {
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: "[表情：\(st.name)]", kind: "sticker")
        m.row["stickerId"] = .string(st.id)
        if let quote { for (k, v) in MessageActions.quoteFields(of: quote) { m.row[k] = v } }
        m = try Repo.append(m)
        if var c = try Repo.chat(chatId) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
        Stickers.markUsed(st.id)
        return m
    }

    /// 用户这边的转账、礼物、拍一拍。落成和角色那边同样的消息（网页版 TransferBits）。
    static func sendTransfer(chatId: String, amount: Double, note: String) throws -> Message {
        try post(Interact.transfer(Message.new(chatId: chatId, role: .user, authorId: "me", content: ""), amount: amount, note: note))
    }

    static func sendGift(chatId: String, cover: String, inner: String) throws -> Message {
        try post(Interact.gift(Message.new(chatId: chatId, role: .user, authorId: "me", content: ""), cover: cover, inner: inner))
    }

    static func sendTakeout(chatId: String, kind: String, item: String, amount: Double) throws -> Message {
        try post(Interact.takeout(Message.new(chatId: chatId, role: .user, authorId: "me", content: ""), kind: kind, item: item, amount: amount))
    }

    static func sendLocation(chatId: String, place: String, address: String) throws -> Message {
        try post(Interact.location(Message.new(chatId: chatId, role: .user, authorId: "me", content: ""), place: place, address: address))
    }

    static func pat(chatId: String) throws -> Message {
        try post(Interact.pat(chatId: chatId, role: .user))
    }

    private static func post(_ m: Message) throws -> Message {
        let out = try Repo.append(m)
        if var c = try Repo.chat(m.chatId) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
        return out
    }

    /// 用户发一条文字。quote 是引用的那一条。
    static func send(text: String, chatId: String, quote: Message? = nil) throws -> Message {
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: text)
        if let quote { for (k, v) in MessageActions.quoteFields(of: quote) { m.row[k] = v } }
        // 群里写了「@名字」：记下这一轮点了谁（网页版 mentions）
        if let chat = try Repo.chat(chatId), chat.isGroup {
            let ids = GroupChat.mentions(in: text, chat: chat, members: GroupChat.members(chat))
            if !ids.isEmpty { m.row["mentions"] = .array(ids.map { .string($0) }) }
        }
        m = try Repo.append(m)
        if var c = try Repo.chat(chatId) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
        return m
    }
}
