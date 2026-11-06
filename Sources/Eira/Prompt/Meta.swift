import Foundation

/// 元模式（网页版 system/meta.js，ARCHITECTURE 4.817、4.825、4.832、4.851、4.854、4.903）。
///
/// 一个什么都不注入的机器人：默认只发对话记录本身，没有 system，回复原样一条，按 Markdown 画，不拆条、不认标记。
/// 要加东西在这段会话自己的设置页里加（网页版第 5 条），都默认空着或关着：
///   系统提示词（metaSystem）、预设（metaPresetId，只用它自己加的条目，内置的提示词一句都不发）、世界书（metaBooks，只扫挂上的几本，
///   全局的书不自动带）、时间感知（metaTime、metaGap）、一段一条（metaSplit）、元可以发表情包（metaCaps.sticker）、回复用的接口（metaApiId）。
/// 可以有好几个元：每个元是一段 meta 会话，最早那一个是 chat_meta / char_meta，之后新建的是 chat_meta_xxx / char_meta_xxx。
/// 「元」不是一张角色卡：不在角色表里，按角色跑的功能碰不到它；会话与消息是普通的 chats、messages，备份、恢复跟着走。
/// 第一次点开才建，开机不写（网页版第 20 条）。一条消息一次请求，不排日程、不召回、不压底色（第 15 条）。
///
/// 原生版暂未做的：元的记忆（4.818）、元发图片与语音（4.825 的后两样）、心声与状态栏（4.864）、美化与聊天背景、头像。
/// 这几样的字段（metaMemory、metaCaps.image / voice、metaVoiceId、faces……）照原样留在会话上，网页版导入导出不丢。
enum Meta {
    static let firstChatId = "chat_meta"
    static let firstCharId = "char_meta"
    static let name = "元"

    static func isMetaChatId(_ id: String) -> Bool { id == firstChatId || id.hasPrefix("chat_meta_") }
    static func isMetaCharId(_ id: String) -> Bool { id == firstCharId || id.hasPrefix("char_meta_") }
    static func isMeta(_ c: Chat?) -> Bool { c?.row.bool("meta") == true }

    static func charIdOf(_ chatId: String) -> String {
        chatId == firstChatId ? firstCharId : "char_meta_" + chatId.dropFirst("chat_meta_".count)
    }

    static func nameOf(_ c: Chat?) -> String {
        let n = c?.row.string("metaName").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? name : n
    }

    /// 所有建过的元，按建的先后。最早那一个还没建时不在里面（消息列表照样画一行，点开才建）
    static func list(_ chats: [Chat]? = nil) -> [Chat] {
        ((chats ?? ((try? Repo.chats()) ?? [])).filter(isMeta)).sorted { ($0.row.created ?? 0) < ($1.row.created ?? 0) }
    }

    /// 这个 id 是不是一个元：最早那一个（没建也算），或者建过、还在的那几个
    static func valid(_ id: String) -> Bool { id == firstChatId || isMeta((try? Repo.chat(id)) ?? nil) }

    /// 点开时才建。已经有了就是那一段
    @discardableResult
    static func ensure(_ id: String = firstChatId) throws -> Chat {
        if let have = try Repo.chat(id) { return have }
        let now = Date().millis
        let c = Chat(row: Row(fields: ["id": .string(id), "createdAt": .number(now), "updatedAt": .number(now),
                                       "characterIds": .array([.string(charIdOf(id))]), "meta": .bool(true),
                                       "metaSystem": .string(""), "metaPresetId": .string(""), "metaBooks": .array([])]))
        try Repo.save(c)
        return c
    }

    /// 新建一个元。名字不填就是「元」加序号
    @discardableResult
    static func create(_ name0: String = "") throws -> Chat {
        let id = Ids.make("chat_meta")
        let n = name0.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date().millis
        let c = Chat(row: Row(fields: ["id": .string(id), "createdAt": .number(now), "updatedAt": .number(now),
                                       "characterIds": .array([.string(charIdOf(id))]), "meta": .bool(true),
                                       "metaName": .string(n.isEmpty ? "\(name) \(list().count + 1)" : n),
                                       "metaSystem": .string(""), "metaPresetId": .string(""), "metaBooks": .array([]),
                                       "lastMessageAt": .number(now)]))
        try Repo.save(c)
        return c
    }

    /// 元在消息列表里的位置（4.854）：group 单独一组排在角色会话下面；mix 和角色会话排在一起
    static func place(_ s: AppSettings) -> String { s.raw["metaPlace"]?.string == "mix" ? "mix" : "group" }

    /// 删掉一个元：会话、聊天记录与它名下的记忆一起删，世界书留着
    static func remove(_ chatId: String) throws {
        let cid = charIdOf(chatId)
        for m in try Repo.memories(charId: cid) { try Database.shared.delete(Collections.memories, id: m.id) }
        try People.deleteChat(chatId)
    }

    /// 清空：只删这段会话的消息，提示词、预设、世界书的选择留着
    static func clear(_ chatId: String) throws {
        for m in try Repo.messages(chatId: chatId) { try Database.shared.delete(Collections.messages, id: m.id) }
        try set(chatId, ["lastMessageAt": .number(Date().millis)])
    }

    // MARK: - 设置

    struct Cfg: Equatable {
        var name = Meta.name
        var system = ""
        var presetId = ""
        var books: [String] = []
        var sticker = false
        var apiId = ""
        var time = false
        var gap = false
        var split = false
    }

    static func cfg(_ c: Chat?, settings s: AppSettings = .load(), lorebooks: [Lorebook]? = nil) -> Cfg {
        guard let c else { return Cfg() }
        let r = c.row
        let have = Set((lorebooks ?? ((try? Repo.lorebooks()) ?? [])).map(\.id))
        let pid = r.string("metaPresetId")
        return Cfg(name: nameOf(c), system: r.string("metaSystem"),
                   presetId: !pid.isEmpty && Presets.list(s).contains { $0.id == pid } ? pid : "",
                   books: r.strings("metaBooks").filter { have.contains($0) },
                   sticker: r["metaCaps"]?["sticker"]?.bool == true,
                   apiId: r.string("metaApiId"),
                   time: r.bool("metaTime"), gap: r.bool("metaGap"), split: r.bool("metaSplit"))
    }

    static func set(_ chatId: String, _ fields: [String: JSONValue]) throws {
        guard var c = try Repo.chat(chatId) else { throw StoreError(message: "这个元不存在或已删除") }
        for (k, v) in fields { c.row[k] = v }
        c.row.touch()
        try Repo.save(c)
        NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
    }

    static func setCap(_ chatId: String, _ key: String, _ on: Bool) throws {
        var caps = ((try Repo.chat(chatId))?.row["metaCaps"]?.object) ?? [:]
        caps[key] = .bool(on)
        try set(chatId, ["metaCaps": .object(caps)])
    }

    /// 选得到的世界书：聊天用的那一种
    static func bookChoices() -> [Lorebook] { ((try? Repo.lorebooks()) ?? []).filter { $0.purpose == "chat" } }

    /// 表情包此刻用不用得上：开着、并且表情库里有
    static func stickerOn(_ c: Chat?) -> Bool {
        cfg(c).sticker && !stickerNames().isEmpty
    }

    private static func stickerNames(limit: Int = 0) -> String {
        ChatPrompt.stickerNames(char: Character(row: Row(fields: [:])), limit: limit)
    }

    // MARK: - 发什么

    /// 对话里要发的那几条：只有正文。失败的、空的不发。引用写成 Markdown 的引用块（4.903），撤回照角色会话的写法
    static func history(_ msgs: [Message]) -> [AIMessage] {
        let byId = Dictionary(msgs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return msgs.filter { !$0.isError && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.kind != "typing" }
            .map { m in
                var text = m.content
                if m.isRecalled && m.role == .user {
                    let seen = m.row["recalled"]?["seen"]?.bool ?? false
                    text = seen ? "[撤回了一条消息：\(m.content)]" : "[撤回了一条消息]"
                } else {
                    let qid = m.row.string("quoteId")
                    let q = (byId[qid]?.content ?? m.row.string("quoteText")).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !q.isEmpty && (!qid.isEmpty || !m.row.string("quoteText").isEmpty) {
                        text = q.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n\n" + text
                    }
                }
                return AIMessage(role: m.role == .user ? .user : .assistant, content: text)
            }
    }

    struct Built: Sendable {
        var system: String
        var messages: [AIMessage]
    }

    /// 这一轮要发的东西。什么都没加时 system 是空串，messages 就是对话记录本身
    static func build(_ c: Chat, msgs: [Message], settings s: AppSettings = .load(), now: Date? = nil) -> Built {
        let cfg = cfg(c, settings: s)
        var out = history(msgs)
        var parts: [String] = []
        let names = ["char": cfg.name, "user": ""]
        if !cfg.system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(Templates.fill(cfg.system, names).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var scan = s.num("scanWindow", 6)
        if !cfg.presetId.isEmpty {
            // 预设里只取自己加的条目：内置的各段一个字都不给（pieces 为空，它们自然是空的）
            let ps = Presets.values(s, cfg.presetId)
            scan = ps.num("scanWindow", 6)
            let got = Layout.arrange("chat", pieces: [:], settings: ps, names: names)
            if !got.system.isEmpty { parts.append(got.system) }
            if !got.tail.isEmpty { out.append(AIMessage(role: .system, content: got.tail)) }
        }
        if !cfg.books.isEmpty {
            // 只扫挂上的那几本：全局的书一律算「关掉」，挂上的算「额外挂上」
            let all = ((try? Repo.lorebooks()) ?? []).map(\.id)
            let win = Int(scan) > 0 ? Int(scan) : 6
            let scanText = msgs.suffix(win).map(\.content).joined(separator: "\n")
            let lore = ChatPrompt.selectLore(char: Character(row: Row(fields: [:])), scanText: scanText, budget: 0, books: (off: all, on: cfg.books)).items
            let text = lore.map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !text.isEmpty { parts.append(text) }
        }
        let t = timeText(c, msgs: msgs, settings: s, now: now)
        if !t.isEmpty { parts.append(t) }
        if stickerOn(c) {
            parts.append(Templates.render("skeleton.sticker", ["names": stickerNames(limit: Int(s.num("stickerCold", 0)))], settings: s))
        }
        return Built(system: parts.joined(separator: "\n\n"), messages: out)
    }

    /// 时间感知（4.832）：只写事实，与角色会话「现在几点」同一种写法。「距上一条」量到上一轮结束为止
    static func timeText(_ c: Chat, msgs: [Message], settings s: AppSettings, now: Date? = nil) -> String {
        let cfg = cfg(c, settings: s)
        var lines: [String] = []
        if cfg.time { lines.append("It is now \(TimeText.format(now ?? Clock.now(s), zone: Clock.zone(Clock.userZone(s)))).") }
        if cfg.gap {
            let list = msgs.filter { $0.createdAt > 0 && !$0.isError }
            var i = list.count
            while i > 0 && list[i - 1].role == .user { i -= 1 }
            if i > 0 {
                let minutes = Int((Date().millis - list[i - 1].createdAt) / 60_000)
                if minutes < 5 { lines.append("The two of you are mid-conversation.") }
                else if minutes < 60 { lines.append("\(minutes) minutes have passed since either of you last spoke.") }
                else if minutes < 1440 { lines.append("\(minutes / 60) hours have passed since either of you last spoke.") }
                else { lines.append("\(minutes / 1440) days have passed since either of you last spoke.") }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 落库

    enum Piece: Equatable { case text(String), sticker(String) }

    /// 回复按开着的标记切开：独占一行的 [表情：名字] 落成表情；关着时原样留在正文里
    static func split(_ text: String, sticker: Bool, paragraphs para: Bool) -> [Piece] {
        var out: [Piece] = []
        var buf: [String] = []
        func flush() {
            let t = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out += para ? paragraphs(t).map(Piece.text) : [.text(t)] }
            buf = []
        }
        for line in text.components(separatedBy: "\n") {
            if sticker, let r = line.range(of: #"^\s*[\[【]\s*表情\s*[:：]\s*([\s\S]+?)\s*[\]】]\s*$"#, options: .regularExpression) {
                flush()
                let inner = String(line[r]).replacingOccurrences(of: #"^\s*[\[【]\s*表情\s*[:：]\s*|\s*[\]】]\s*$"#, with: "", options: .regularExpression)
                out.append(.sticker(inner))
                continue
            }
            buf.append(line)
        }
        flush()
        return out
    }

    /// 一段一条（4.903）：按空行切开。``` 围起来的代码块里的空行不切
    static func paragraphs(_ text: String) -> [String] {
        var out: [String] = []
        var buf: [String] = []
        var fence = false
        func flush() {
            let t = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            buf = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.range(of: #"^\s*(```|~~~)"#, options: .regularExpression) != nil { fence.toggle() }
            if !fence && line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            buf.append(line)
        }
        flush()
        return out
    }

    /// 正在看着的那几段元（页面挂着、应用在前台）。回复落库时人不在就记未读（4.903）
    nonisolated(unsafe) static var looking: Set<String> = []

    /// 回复落库：一样都没开时原样一条。versions 挂在这一轮第一条上（重新生成时的上一版，与角色会话同一个字段）
    @discardableResult
    static func land(_ raw: String, chatId: String, swipes: [String] = []) throws -> [Message] {
        guard let c = try Repo.chat(chatId) else { throw StoreError(message: "这个元不存在或已删除") }
        let cfg = cfg(c)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let turnId = Ids.make("turn")
        let author = charIdOf(chatId)
        let stickers = cfg.sticker ? ((try? Database.shared.all("stickers")) ?? []) : []
        var made: [Message] = []
        for p in split(text, sticker: stickerOn(c), paragraphs: cfg.split) {
            var m: Message
            switch p {
            case .text(let t):
                m = Message.new(chatId: chatId, role: .char, authorId: author, content: t, turnId: turnId)
            case .sticker(let n):
                // 名字对不上的不落（网页版 4.825）
                guard let st = StickerMatch.find(n, in: stickers) else { continue }
                m = Message.new(chatId: chatId, role: .char, authorId: author, content: "[表情：\(st.string("name"))]", kind: "sticker", turnId: turnId)
                m.row["stickerId"] = .string(st.id)
            }
            if made.isEmpty {
                m.row["raw"] = .string(raw)
                if !swipes.isEmpty {
                    m.row["swipes"] = .array((swipes + [raw]).map { .string($0) })
                    m.row["swipeIndex"] = .number(Double(swipes.count))
                }
            }
            made.append(try Repo.append(m))
        }
        var fields: [String: JSONValue] = ["lastMessageAt": .number(Date().millis)]
        if !made.isEmpty && !looking.contains(chatId) { fields["unread"] = .number(Double(c.unread + made.count)) }
        try set(chatId, fields)
        return made
    }

    /// 最后一轮：最后一条你说的之后那几条元的消息
    static func lastTurn(_ msgs: [Message]) -> [Message] {
        let ok = msgs.filter { !$0.isError }
        return Array(ok.reversed().prefix { $0.role == .char }.reversed())
    }

    /// 回复。regenerate：重新生成最后一轮（成功之后才换掉旧的，上一版留作候选；开着一段一条时不留，4.903）。
    /// 一次请求，失败不写失败的消息，错误交给界面在屏幕上说。停下时已经收到的那部分照常留下
    @discardableResult
    static func reply(chatId: String, regenerate: Bool = false, onDelta: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [Message] {
        guard let c = try Repo.chat(chatId), isMeta(c) else { throw StoreError(message: "这个元不存在或已删除") }
        let all = try Repo.messages(chatId: chatId)
        let old = regenerate ? lastTurn(all) : []
        if regenerate && old.isEmpty { throw StoreError(message: "没有可以重新生成的回复") }
        let oldIds = Set(old.map(\.id))
        let msgs = all.filter { !oldIds.contains($0.id) }
        let s = AppSettings.load()
        let built = build(c, msgs: msgs, settings: s)
        guard !built.messages.isEmpty else { throw StoreError(message: "还没有可以回复的消息") }
        // 这个元自己选的接口（4.832）：选了而且填全了只用它；没选跟随主用，失败换下一套照「设置 - 接口」
        let own = s.chatPresets.first { $0.id == cfg(c, settings: s).apiId && $0.usable }
        let text: String
        do {
            text = try await LastSent.$chat.withValue(chatId) {
                try await AIService.shared.send(task: "chat.reply", preset: own, system: built.system, messages: built.messages,
                                                retries: 1, onDelta: onDelta).text
            }
        } catch let e as AIError where !e.partial.isEmpty && !regenerate {
            try land(e.partial, chatId: chatId)
            throw e
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError(message: "模型返回了空内容") }
        var swipes: [String] = []
        if regenerate {
            if !cfg(c, settings: s).split, let head = old.first {
                swipes = head.row["swipes"]?.array?.compactMap(\.string) ?? []
                if swipes.isEmpty { swipes = [head.row.string("raw").isEmpty ? old.map(\.content).joined(separator: "\n\n") : head.row.string("raw")] }
            }
            for m in old { try Database.shared.delete(Collections.messages, id: m.id) }
        }
        return try land(text, chatId: chatId, swipes: swipes)
    }

    /// 在最后一轮的几个版本之间切换：存着的原文重新落一遍，不调接口
    static func switchVersion(chatId: String, step: Int) throws {
        let turn = lastTurn(try Repo.messages(chatId: chatId))
        guard let head = turn.first, let swipes = head.row["swipes"]?.array?.compactMap(\.string), swipes.count > 1 else { return }
        let n = swipes.count
        let i = ((Int(head.row.number("swipeIndex") ?? Double(n - 1)) + step) % n + n) % n
        for m in turn { try Database.shared.delete(Collections.messages, id: m.id) }
        let wasLooking = looking.contains(chatId)
        looking.insert(chatId)
        defer { if !wasLooking { looking.remove(chatId) } }
        var made = try land(swipes[i], chatId: chatId)
        if var first = made.first {
            first.row["swipes"] = .array(swipes.map { .string($0) })
            first.row["swipeIndex"] = .number(Double(i))
            try Repo.save(first)
            made[0] = first
        }
    }

    /// 你发一条。只落一条，不自动回复（4.851）：可以连发，再点「让对方回复」
    @discardableResult
    static func send(_ text: String, chatId: String, quote: Message? = nil) throws -> Message {
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: text)
        if let quote {
            m.row["quoteId"] = .string(quote.id)
            m.row["quoteText"] = .string(String(quote.content.prefix(40)))
            m.row["quoteRole"] = .string(quote.role.rawValue)
            m.row["quoteAuthorId"] = .string(quote.authorId)
        }
        m = try Repo.append(m)
        try set(chatId, ["lastMessageAt": .number(Date().millis)])
        return m
    }

    /// 从你的这一条之后全删掉（「从这里重新生成」）
    static func cutAfter(_ msgId: String, chatId: String) throws {
        let all = try Repo.messages(chatId: chatId)
        guard let i = all.firstIndex(where: { $0.id == msgId }) else { return }
        for m in all[(i + 1)...] { try Database.shared.delete(Collections.messages, id: m.id) }
    }

    // MARK: - 存为世界书（4.832）

    /// 这个元自己的那一本（第一次存时建，metaFor 记着是谁的）
    static func ownBook(_ chatId: String) -> Lorebook? {
        ((try? Repo.lorebooks()) ?? []).first { $0.row.string("metaFor") == chatId }
    }

    /// 存成一条常驻条目。默认存进这个元自己的那一本；存进去的那本没挂上的一并挂上，下一轮就读得到。回书名
    @discardableResult
    static func saveToBook(_ chatId: String, text: String, bookId: String = "", title: String = "") throws -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw StoreError(message: "内容不能为空") }
        var book: Row
        if !bookId.isEmpty, let b = try Database.shared.get(Collections.lorebooks, id: bookId) { book = b }
        else if let b = ownBook(chatId) { book = b.row }
        else {
            book = Row.new(prefix: "lb", ["name": .string("\(nameOf((try? Repo.chat(chatId)) ?? nil)) · 世界书"), "description": .string(""),
                                          "global": .bool(false), "entries": .array([]), "metaFor": .string(chatId)])
        }
        let first = body.components(separatedBy: "\n").first ?? body
        book["entries"] = .array((book["entries"]?.array ?? []) + [Ooc.entry(body, title: title.isEmpty ? String(first.prefix(24)) : title)])
        book.touch()
        try Database.shared.put(Collections.lorebooks, book)
        if let c = try Repo.chat(chatId), !c.row.strings("metaBooks").contains(book.id) {
            try set(chatId, ["metaBooks": .array((c.row.strings("metaBooks") + [book.id]).map { .string($0) })])
        }
        return book.string("name")
    }
}
