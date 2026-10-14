import Foundation

/// 情侣空间（网页版 system/space.js）。**一段单人会话就是一个空间。**
///
/// 大部分内容不另存：礼物墙是这段会话里 kind 为 gift 的消息，去过的地方是 location，一起听是 listen，通话是 call，
/// 约定是 pact，寄出的信是 letter。它们天生在上下文里、天生跟着会话一起删。
/// 自己存的只有两样，在 spaceItems 里（按 chatId 查）：纪念日（type day）与还没寄出的信（type draft）。
/// 在一起的起始日记在会话的 loveStartAt；「让角色知道这些」是会话的 spaceInject，默认关。
enum Space {
    static let items = "spaceItems"
    static let pactOpen = "open", pactDone = "done"
    static let letterMax = 20000

    // MARK: - 空间

    static func spaces(personaId: String) -> [(chat: Chat, char: Character)] {
        ((try? Repo.chats()) ?? [])
            .filter { !$0.isGroup && $0.characterIds.count == 1 && ($0.personaId.isEmpty || $0.personaId == personaId) }
            .compactMap { c -> (chat: Chat, char: Character)? in
                guard let ch = try? Repo.character(c.characterIds[0]) else { return nil }
                return (chat: c, char: ch)
            }
            .sorted { $0.chat.lastMessageAt > $1.chat.lastMessageAt }
    }

    private static func startOfDay(_ ms: Double) -> Date { Calendar.current.startOfDay(for: Date(millis: ms)) }

    /// 在一起多少天（起始日那天算第 1 天）。没设起始日为 nil：不拿会话创建时间顶替
    static func togetherDays(_ chat: Chat, now: Date = Date()) -> Int? {
        guard let start = chat.row.number("loveStartAt"), start > 0 else { return nil }
        let days = Calendar.current.dateComponents([.day], from: startOfDay(start), to: Calendar.current.startOfDay(for: now)).day ?? 0
        return max(0, days) + 1
    }

    static func setStart(_ chatId: String, _ ms: Double) throws { try patchChat(chatId, ["loveStartAt": .number(ms)]) }
    static func injectOn(_ chat: Chat) -> Bool { chat.row.bool("spaceInject") }
    static func setInject(_ chatId: String, _ on: Bool) throws { try patchChat(chatId, ["spaceInject": .bool(on)]) }

    private static func patchChat(_ chatId: String, _ f: [String: JSONValue]) throws {
        guard var c = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
        for (k, v) in f { c.row[k] = v }
        c.row.touch()
        try Repo.save(c)
    }

    // MARK: - 记录：会话里那几种消息的视图

    static func records(_ chatId: String, _ kind: String) -> [Message] {
        ((try? Repo.messages(chatId: chatId)) ?? []).filter { $0.kind == kind }
    }

    struct Stats: Equatable {
        var days: Int?
        var gifts = 0, places = 0, calls = 0, letters = 0, pactsOpen = 0, pactsDone = 0, drafts = 0
        var listenSeconds = 0.0, listenCount = 0.0
    }

    static func stats(_ chat: Chat) -> Stats {
        var s = Stats(days: togetherDays(chat))
        for m in (try? Repo.messages(chatId: chat.id)) ?? [] {
            switch m.kind {
            case "gift": s.gifts += 1
            case "location": s.places += 1
            case "call": s.calls += 1
            case "letter": s.letters += 1
            case "pact": if m.row.string("pact") == pactDone { s.pactsDone += 1 } else { s.pactsOpen += 1 }
            default: break
            }
        }
        s.listenSeconds = chat.row.number("listenSeconds") ?? 0
        s.listenCount = chat.row.number("listenCount") ?? 0
        s.drafts = drafts(chat.id).count
        return s
    }

    // MARK: - 纪念日与未寄出的信

    private static func itemsOf(_ chatId: String, _ type: String) -> [Row] {
        ((try? Database.shared.all(items, where: chatId)) ?? []).filter { $0.string("type") == type }
            .sorted { ($0.number("createdAt") ?? 0) < ($1.number("createdAt") ?? 0) }
    }

    static func days(_ chatId: String) -> [Row] { itemsOf(chatId, "day") }
    static func drafts(_ chatId: String) -> [Row] { itemsOf(chatId, "draft") }

    @discardableResult
    static func addDay(chatId: String, title: String, date: String, yearly: Bool) throws -> Row {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        guard !t.isEmpty else { throw StoreError(message: "请填写纪念日名称") }
        guard date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw StoreError(message: "请选择日期") }
        let r = Row.new(prefix: "si", ["chatId": .string(chatId), "type": .string("day"), "title": .string(t),
                                        "date": .string(date), "yearly": .bool(yearly)])
        try Database.shared.put(items, r)
        return r
    }

    static func updateDay(_ id: String, title: String, date: String, yearly: Bool) throws {
        guard var r = try Database.shared.get(items, id: id), r.string("type") == "day" else { return }
        r["title"] = .string(String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20)))
        r["date"] = .string(date)
        r["yearly"] = .bool(yearly)
        r.touch()
        try Database.shared.put(items, r)
    }

    static func removeItem(_ id: String) throws { try Database.shared.delete(items, id: id) }

    /// 下一次是哪天：每年一次的滚到今年或明年；只过一次的过了就是过了（left 为负）
    static func nextAt(_ item: Row, from now: Date = Date()) -> Date? {
        let parts = item.string("date").split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        if !item.bool("yearly") { return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) }
        let y = cal.component(.year, from: today)
        guard var at = cal.date(from: DateComponents(year: y, month: parts[1], day: parts[2])) else { return nil }
        if at < today { at = cal.date(from: DateComponents(year: y + 1, month: parts[1], day: parts[2])) ?? at }
        return at
    }

    static func leftDays(_ item: Row, from now: Date = Date()) -> Int {
        guard let at = nextAt(item, from: now) else { return 0 }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: at).day ?? 0
    }

    /// 按「还有几天」排好；已经过去的（只过一次的）排在最后
    static func upcoming(_ chatId: String, now: Date = Date()) -> [(item: Row, left: Int)] {
        days(chatId).map { ($0, leftDays($0, from: now)) }
            .sorted { a, b in (a.left < 0) != (b.left < 0) ? b.left < 0 : a.left < b.left }
    }

    // MARK: - 约定

    static func pactContent(_ title: String, done: Bool) -> String { "[约定：\(title)]" + (done ? "（已完成）" : "") }

    static func pacts(_ chatId: String) -> [Message] { records(chatId, "pact") }

    static func makePact(chatId: String, role: Message.Role, authorId: String, title: String, turnId: String? = nil) throws -> Message {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !t.isEmpty else { throw StoreError(message: "请填写约定内容") }
        var m = Message.new(chatId: chatId, role: role, authorId: authorId, content: pactContent(t, done: false), kind: "pact", turnId: turnId)
        m.row["pact"] = .string(pactOpen)
        m.row["title"] = .string(t)
        return m
    }

    /// 模型写「约定完成」时给的是一小段原话，拿它回头去认。认不出就不动
    static func findOpenPact(_ chatId: String, _ title: String) -> Message? {
        let q = title.filter { !$0.isWhitespace }
        let open = pacts(chatId).filter { $0.row.string("pact") == pactOpen }
        guard !open.isEmpty else { return nil }
        if q.isEmpty { return open.last }
        return open.last { m in
            let t = m.row.string("title").filter { !$0.isWhitespace }
            return !t.isEmpty && (t.contains(q) || q.contains(t))
        }
    }

    /// 标记完成：改那一条，落一行「约定已完成」。那一行删掉，约定回到未完成
    static func completePact(_ id: String, turnId: String? = nil, byChar: Bool = false, charId: String = "") throws -> Message? {
        guard var row = try Database.shared.get(Collections.messages, id: id), row.string("kind") == "pact",
              row.string("pact") != pactDone else { return nil }
        let title = row.string("title")
        row["pact"] = .string(pactDone)
        row["doneAt"] = .number(Date().millis)
        row["content"] = .string(pactContent(title, done: true))
        row.touch()
        try Database.shared.put(Collections.messages, row)
        var n = Message.new(chatId: row.string("chatId"), role: byChar ? .char : .user, authorId: byChar ? charId : "me",
                            content: "[约定已完成：\(title)]", kind: "notice", turnId: turnId)
        n.row["settledId"] = .string(id)
        n.row["settledKind"] = .string("pact")
        return n
    }

    static func unsettlePact(_ notice: Message) throws {
        guard notice.row.string("settledKind") == "pact",
              var row = try Database.shared.get(Collections.messages, id: notice.row.string("settledId")), row.string("kind") == "pact" else { return }
        row["pact"] = .string(pactOpen)
        row["doneAt"] = .number(0)
        row["content"] = .string(pactContent(row.string("title"), done: false))
        row.touch()
        try Database.shared.put(Collections.messages, row)
    }

    // MARK: - 信

    static func letterMessage(chatId: String, role: Message.Role, authorId: String, title: String, body: String,
                              openAt: Double = 0, turnId: String? = nil) throws -> Message {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        let b = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(letterMax))
        guard !b.isEmpty else { throw StoreError(message: "请填写信的内容") }
        var m = Message.new(chatId: chatId, role: role, authorId: authorId, content: "[信\(t.isEmpty ? "" : "：" + t)]\n\(b)", kind: "letter", turnId: turnId)
        m.row["title"] = .string(t)
        m.row["body"] = .string(b)
        if openAt > 0 { m.row["openAt"] = .number(openAt) }
        return m
    }

    /// 寄出一封（我写的）
    @discardableResult
    static func sendLetter(chatId: String, title: String, body: String, openAt: Double = 0, at: Double? = nil) throws -> Message {
        var m = try letterMessage(chatId: chatId, role: .user, authorId: "me", title: title, body: body, openAt: openAt)
        m = try Repo.append(m)
        // 定时寄出的：投递时间用当初定的那个时刻，不是发现它的时刻
        if let at {
            m.row["createdAt"] = .number(at)
            try Database.shared.put(Collections.messages, m.row)
        }
        try patchChat(chatId, ["lastMessageAt": .number(Date().millis)])
        return m
    }

    /// 存进信箱（不寄）。sendAt 为定时投递的时刻，0 为不定时
    @discardableResult
    static func saveDraft(chatId: String, id: String? = nil, title: String, body: String, sendAt: Double = 0, openAt: Double = 0) throws -> Row {
        let b = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(letterMax))
        guard !b.isEmpty else { throw StoreError(message: "请填写信的内容") }
        var r = (id.flatMap { try? Database.shared.get(items, id: $0) }) ?? Row.new(prefix: "si", ["chatId": .string(chatId), "type": .string("draft")])
        r["title"] = .string(String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)))
        r["body"] = .string(b)
        r["sendAt"] = .number(max(0, sendAt))
        r["openAt"] = .number(max(0, openAt))
        r.touch()
        try Database.shared.put(items, r)
        return r
    }

    static func sendDraft(_ id: String) throws {
        guard let r = try Database.shared.get(items, id: id), r.string("type") == "draft" else { return }
        try sendLetter(chatId: r.string("chatId"), title: r.string("title"), body: r.string("body"), openAt: r.number("openAt") ?? 0)
        try Database.shared.delete(items, id: id)
    }

    /// 到点该寄的那几封：投递时间用当初定的时刻。应用打开、回到前台时扫一遍
    @discardableResult
    static func deliverDue(now: Double = Date().millis) -> Int {
        var n = 0
        for r in (try? Database.shared.all(items)) ?? [] where r.string("type") == "draft" {
            let at = r.number("sendAt") ?? 0
            guard at > 0, at <= now else { continue }
            guard (try? Repo.chat(r.string("chatId"))) != nil else { try? Database.shared.delete(items, id: r.id); continue }
            do {
                try sendLetter(chatId: r.string("chatId"), title: r.string("title"), body: r.string("body"),
                               openAt: r.number("openAt") ?? 0, at: at)
                try Database.shared.delete(items, id: r.id)
                n += 1
            } catch {
                Problems.report("定时信未能寄出：\(error.localizedDescription)")
            }
        }
        return n
    }

    /// 封着的信：那天之前只有信封
    static func sealed(_ m: Message, now: Double = Date().millis) -> Bool {
        m.kind == "letter" && (m.row.number("openAt") ?? 0) > now
    }

    static func sealedText(_ m: Message) -> String {
        let t = m.row.string("title")
        let d = Date(millis: m.row.number("openAt") ?? 0)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "[信\(t.isEmpty ? "" : "：" + t)] (sealed until \(f.string(from: d)))"
    }

    /// 'yyyy-MM-dd' 那天零点；不在今天之后给 0
    static func openAt(of date: Date, now: Date = Date()) -> Double {
        let d = Calendar.current.startOfDay(for: date)
        return d > now ? d.millis : 0
    }

    // MARK: - 上下文（网页版 context/space.js，区块 space，默认不注入）

    static func block(_ chat: Chat, now: Date = Date()) -> String {
        guard !chat.isGroup, injectOn(chat) else { return "" }
        var lines: [String] = []
        if let d = togetherDays(chat, now: now) { lines.append("This is day \(d) of your relationship.") }
        // 三天之内的那几个「节日与纪念日」一段里已经有了（网页版 LEAD = 3）；原生版没有那一段，这里一并写
        for x in upcoming(chat.id, now: now) where x.left >= 0 && x.left <= 30 {
            let title = x.item.string("title")
            lines.append(x.left == 0 ? "Today is \(title)." : "\(title) is \(x.left) days away.")
        }
        let open = pacts(chat.id).filter { $0.row.string("pact") == pactOpen }.map { $0.row.string("title") }
        if !open.isEmpty { lines.append("Promises not yet fulfilled: \(open.joined(separator: "；"))。") }
        guard !lines.isEmpty else { return "" }
        lines.append("The above concerns the two of you.")
        return "\n\n[你们之间]\n" + lines.joined(separator: "\n")
    }
}
