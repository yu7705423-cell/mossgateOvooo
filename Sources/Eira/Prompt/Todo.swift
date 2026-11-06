import Foundation

extension Notification.Name {
    /// 待办有了变化（落了待确认、计入、打勾、删除）。会话页的确认栏、待办页据此刷新
    static let eiraTodosChanged = Notification.Name("eira.todosChanged")
}

/// 待办（网页版 system/todo.js，ARCHITECTURE 4.104d、4.104i、4.326、4.348）。**用户自己的**，不是角色的日程（days），
/// 也不是你们之间的约定（spaceItems 的 pact）。数据域 todos，字段与默认值见 docs/web-fields.md。
///
/// 两道监督：本地比对线索词（不花钱、每条都看）、角色在回复里写 `[待办：…]`（搭在本来就要发的那次回复上，不多调接口）。
/// 两道都不直接入库，一律先落成待确认（pending），点了「计入」才算；忽略的记为 drop，不再问第二遍。
enum Todo {
    static let collection = "todos"

    static let pending = "pending", open = "open", done = "done", drop = "drop"
    static let fromLocal = "local", fromChar = "char", fromMe = "manual", fromCollect = "collect", fromFit = "fit"
    static let weekly = "weekly"

    static func fromLabel(_ f: String) -> String {
        f == fromChar ? "角色提出" : f == fromLocal ? "对话中识别" : f == fromCollect ? "收藏馆" : f == fromFit ? "起居" : "手动添加"
    }

    /// 一条待办。读的时候按网页版的默认值补
    struct Item: Identifiable, Equatable {
        var row: Row
        var id: String { row.id }
        var text: String { row.string("text") }
        var state: String { row.string("state") }
        var from: String { row.string("from") }
        var chatId: String { row.string("chatId") }
        var charId: String { row.string("charId") }
        var dueAt: String { row.string("dueAt") }
        /// 几点做（HH:MM，可空），和提醒时刻是两回事
        var time: String { row.string("time") }
        var remindAt: Double { Todo.ms(row["remindAt"]) }
        var doneAt: Double { Todo.ms(row["doneAt"]) }
        var createdAt: Double { row.number("createdAt") ?? 0 }
        var weekdays: [Int] { (row["weekdays"]?.array ?? []).compactMap { $0.number.map { Int($0) } } }
        var doneDates: [String] { row.strings("doneDates") }
        var alarmId: String { row.string("alarmId") }
        var alarmAt: Double { Todo.ms(row["alarmAt"]) }
        var rungAt: Double { Todo.ms(row["rungAt"]) }
        var whenText: String { row.string("whenText") }
        var isRepeat: Bool { row.string("repeat") == Todo.weekly && !weekdays.isEmpty }
    }

    /// 网页版的时刻字段是毫秒数，空着时可能是 0 或空串
    static func ms(_ v: JSONValue?) -> Double {
        if let n = v?.number { return n.isFinite ? n : 0 }
        if let s = v?.string { return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return 0
    }

    // MARK: - 线索词（用户可改，第 13 条）

    static let defaultCues = [
        "我想", "我要", "我打算", "打算", "我准备", "准备", "我得", "我该",
        "记得", "别忘", "不要忘", "提醒我", "回头", "有空", "改天", "下次",
        "要去", "想去", "得去", "要买", "想买", "要做", "想做", "要写", "要看",
    ]

    /// 明知会误报的那几句。线索词一撞上它们就不当待办
    static let defaultSkips = [
        "我想你", "我想他", "我想她", "我想吃你", "我要睡", "我想睡", "我要死",
        "我想哭", "我要哭", "我想笑", "我要疯", "我想不", "我要是", "我想起",
        "我想到", "我要不", "准备好", "打算好", "我得了",
    ]

    private static func listOf(_ key: String, _ fallback: [String], _ s: AppSettings) -> [String] {
        guard let raw = s.raw[key]?.array else { return fallback }
        return raw.map { ($0.string ?? $0.number.map { String($0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func cues(_ s: AppSettings = .load()) -> [String] { listOf("todoCues", defaultCues, s) }
    static func skips(_ s: AppSettings = .load()) -> [String] { listOf("todoSkips", defaultSkips, s) }
    static func detectOn(_ s: AppSettings = .load()) -> Bool { s.raw["todoDetect"]?.bool != false }
    /// 本地这一道开着没有。线索词删光了也算关着
    static func localOn(_ s: AppSettings = .load()) -> Bool { detectOn(s) && !cues(s).isEmpty }

    private static let stop = ReplyParser.regex(#"[。！？；\n，,.!?;]"#, [])

    /// 本地识别：取线索词连同它后面那一截，到标点为止。命中返回 (cue, text)
    static func detect(_ text: String, cues cueList: [String]? = nil, skips skipList: [String]? = nil) -> (cue: String, text: String)? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let cs = cueList ?? cues(), ks = skipList ?? skips()
        for cue in cs {
            guard let r = raw.range(of: cue) else { continue }
            let rest = String(raw[r.lowerBound...])
            if ks.contains(where: { rest.hasPrefix($0) }) { continue }
            let ns = rest as NSString
            let hit = stop.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length))
            let cut = hit.map { $0.range.location } ?? -1
            let one = (cut > 0 ? ns.substring(to: cut) : rest).trimmingCharacters(in: .whitespacesAndNewlines)
            // 光一个线索词不算事
            if one.utf16.count <= cue.utf16.count { continue }
            return (cue, one)
        }
        return nil
    }

    // MARK: - 存取

    static func all() -> [Item] {
        ((try? Database.shared.all(collection)) ?? []).map(Item.init(row:))
    }

    static func get(_ id: String) -> Item? {
        (try? Database.shared.get(collection, id: id)).flatMap { $0 }.map(Item.init(row:))
    }

    private static func changed() {
        Task { @MainActor in NotificationCenter.default.post(name: .eiraTodosChanged, object: nil) }
    }

    @discardableResult
    static func create(_ fields: [String: JSONValue]) throws -> Item {
        let row = Row.new(prefix: "td", fields)
        try Database.shared.put(collection, row)
        changed()
        return Item(row: row)
    }

    /// 浅合并，和网页版 update 一样；不认识的字段原样留着
    @discardableResult
    static func update(_ id: String, _ patch: [String: JSONValue]) throws -> Item? {
        guard var row = try Database.shared.get(collection, id: id) else { return nil }
        for (k, v) in patch { row[k] = v }
        row.touch()
        try Database.shared.put(collection, row)
        changed()
        return Item(row: row)
    }

    static func remove(_ id: String) throws {
        if get(id)?.alarmId.isEmpty == false { TodoAlarm.unschedule(id) }
        try Database.shared.delete(collection, id: id)
        changed()
    }

    /// 同一件事不问第二遍。已经忽略过的也算数
    private static func already(_ text: String, chatId: String) -> Bool {
        all().contains { $0.chatId == chatId && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text }
    }

    static let nearLines = 4
    static let nearMs: Double = 10 * 60000

    /// 认不出时刻的时候往回翻几句，看看刚才有没有说过一个点钟
    static func timeNear(_ near: [String], now: Date = Date()) -> Double {
        for line in near.suffix(nearLines).reversed() {
            if let got = When.parse(line, now: now), got.hasTime, got.at > now.millis { return got.at }
        }
        return 0
    }

    /// 落一条待确认的。重复的、空的都不落。**两道监督都走这里**，谁都不能直接写成已计入
    @discardableResult
    static func propose(text: String, chatId: String = "", charId: String = "", srcMsgId: String = "",
                        from: String = fromLocal, near: [String] = [], now: Date = Date()) throws -> Item? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !already(t, chatId: chatId) else { return nil }
        // 只认说到点钟的：顺口带了个「今天」不算约了时间
        let got = When.parse(t, now: now)
        let own = got.map { $0.hasTime && $0.at > now.millis ? $0.at : 0 } ?? 0
        let remind = own > 0 ? own : timeNear(near, now: now)
        return try create([
            "text": .string(t), "chatId": .string(chatId), "charId": .string(charId), "srcMsgId": .string(srcMsgId),
            "from": .string(from), "state": .string(pending), "dueAt": .string(""), "remindAt": .number(remind),
            "createdAt": .number(now.millis),
        ])
    }

    /// 反过来那一半：先说了事，后补一句时刻。补给这段对话里还等着确认、又没挂时刻的那一条
    @discardableResult
    static func attachTime(chatId: String, text: String, now: Date = Date()) throws -> Item? {
        guard let got = When.parse(text, now: now), got.hasTime, got.at > now.millis else { return nil }
        if detect(text) != nil { return nil }
        guard let row = pendingOf(chatId).filter({ $0.remindAt == 0 && now.millis - $0.createdAt <= nearMs }).last else { return nil }
        return try update(row.id, ["remindAt": .number(got.at)])
    }

    /// 用户自己加的一条，不经过确认那一步
    @discardableResult
    static func addMine(_ text: String, _ patch: [String: JSONValue] = [:]) throws -> Item? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var f: [String: JSONValue] = [
            "text": .string(t), "chatId": .string(""), "charId": .string(""), "srcMsgId": .string(""), "from": .string(fromMe),
            "state": .string(open), "dueAt": .string(""), "createdAt": .number(Date().millis),
        ]
        for (k, v) in patch { f[k] = v }
        return try create(f)
    }

    @discardableResult
    static func setState(_ id: String, _ state: String) throws -> Item? {
        // 做完的、忽略的不再响：系统里排着的那一条撤掉（网页版留着，到点照响一条已经做完的事）
        if state == done || state == drop, get(id)?.alarmId.isEmpty == false { TodoAlarm.cancelLocal(id) }
        return try update(id, ["state": .string(state), "doneAt": .number(state == done ? Date().millis : 0)])
    }

    static func accept(_ id: String) throws { try setState(id, open) }
    static func ignore(_ id: String) throws { try setState(id, drop) }

    /// 某个状态的全部，新的在前
    static func listOfState(_ state: String) -> [Item] {
        all().filter { $0.state == state }.sorted { $0.createdAt > $1.createdAt }
    }

    static func openOnes() -> [Item] { listOfState(open) }
    static func doneOnes() -> [Item] { listOfState(done) }
    static func pendingAll() -> [Item] { listOfState(pending) }

    /// 这段对话里还等着确认的那几条，早的在前
    static func pendingOf(_ chatId: String) -> [Item] {
        all().filter { $0.state == pending && $0.chatId == chatId }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 忽略掉的清干净。清了之后同样的话会重新问起
    @discardableResult
    static func clearDropped() throws -> Int {
        let gone = listOfState(drop)
        for x in gone { try Database.shared.delete(collection, id: x.id) }
        changed()
        return gone.count
    }

    // MARK: - 按天看（「我的日程」里的任务，4.326）

    /// 你的时区里、应用的时间里，今天是哪一天（与「我的日程」同一把尺子，4.348）
    static func todayKey(_ s: AppSettings = .load(), real: Date = Date()) -> String {
        UserSched.today(s, at: Clock.now(s, real: real)).key
    }

    /// 本机时区里这一刻是哪一天、几点（网页版 new Date(ms)）
    static func keyOf(ms: Double) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(millis: ms))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func hmOf(ms: Double) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date(millis: ms))
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func isDateKey(_ s: String) -> Bool { s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }

    /// 这一条落不落在这一天。每周重复的 from 是开始的那一天；
    /// from 同时是来源的字段名（网页版两处共用），不是日期时当作没有开始日期
    static func onDay(_ r: Item, _ key: String) -> Bool {
        guard r.state == open || r.state == done else { return false }
        if r.isRepeat {
            return r.weekdays.contains(UserSched.weekdayOfKey(key)) && (!isDateKey(r.from) || key >= r.from)
        }
        if !r.dueAt.isEmpty { return r.dueAt == key }
        return r.remindAt > 0 && keyOf(ms: r.remindAt) == key
    }

    /// 这一天完成了没有。每周重复的按天算
    static func doneOn(_ r: Item, _ key: String) -> Bool { r.isRepeat ? r.doneDates.contains(key) : r.state == done }

    /// 这一条在这一天几点：写了 time 用它，否则用提醒时刻（不重复的才有）
    static func timeOf(_ r: Item, _ key: String) -> String {
        if !r.time.isEmpty { return r.time }
        if !r.isRepeat && r.remindAt > 0 && keyOf(ms: r.remindAt) == key { return hmOf(ms: r.remindAt) }
        return ""
    }

    struct DayTask: Identifiable {
        var row: Item
        var time: String
        var done: Bool
        var id: String { row.id }
    }

    /// 某一天的任务，有时间的按时间排在前
    static func tasksOn(_ key: String) -> [DayTask] {
        all().filter { onDay($0, key) }.map { DayTask(row: $0, time: timeOf($0, key), done: doneOn($0, key)) }
            .sorted { a, b in
                if a.time.isEmpty != b.time.isEmpty { return !a.time.isEmpty }
                if a.time != b.time { return a.time < b.time }
                return a.row.createdAt < b.row.createdAt
            }
    }

    /// 在某一天打勾或取消。每周重复的只动那一天
    @discardableResult
    static func toggleOn(_ id: String, _ key: String) throws -> Item? {
        guard let r = get(id) else { return nil }
        if !r.isRepeat { return try setState(id, r.state == done ? open : done) }
        var set = Set(r.doneDates)
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        // 有意截断：只留最近 400 天的记号（网页版同样），一年多以前的打勾不再有用
        return try update(id, ["doneDates": .array(set.sorted().suffix(400).map { .string($0) })])
    }

    /// 重复写成一句话：「每周一、三」
    static func repeatText(_ r: Item) -> String {
        guard r.isRepeat else { return "" }
        let wd = Array("一二三四五六日")
        return "每周" + r.weekdays.sorted().compactMap { (1...7).contains($0) ? String(wd[$0 - 1]) : nil }.joined(separator: "、")
    }

    // MARK: - 进提示词（网页版 context/plan.js：[你记着的事]）

    /// 只给已经计入、还没做的；每周重复的写在「对方的日程」里，这里不再列。条数 planCount（默认 8，0 为全给）
    static func planBlock(userName: String, settings s: AppSettings, now: Date = Date()) -> String {
        let n = max(0, Int(s.num("planCount", 8).rounded()))
        func at(_ r: Item) -> Double { r.remindAt > 0 ? r.remindAt : ms(r.row["dueAt"]) }
        let candidates = openOnes().filter { !$0.isRepeat }
        // 排好时间的按时间来，没排时间的垫在后面；同一档保持原来的先后
        var rows = candidates.enumerated().sorted { a, b in
            let x = at(a.element), y = at(b.element)
            if (x > 0) != (y > 0) { return x > 0 }
            if x != y { return x < y }
            return a.offset < b.offset
        }.map(\.element)
        if n > 0 { rows = Array(rows.prefix(n)) }
        guard !rows.isEmpty else { return "" }
        let lines = rows.map { r -> String in
            let t = at(r) > 0 ? When.show(at(r), now: now) : ""
            return t.isEmpty ? r.text : "\(t)\u{3000}\(r.text)"
        }
        let who = userName.isEmpty ? "对方" : userName
        return "[你记着的事]\n\(lines.joined(separator: "\n"))\nThese are things \(who) has said they intend to do. They have not been done yet."
    }

    // MARK: - 对话里的两道

    /// 用户刚发出去的一句：比对线索词，命中落成待确认；没命中而这句只补了时刻，补给刚才那一条（网页版 Conversation 的 send）。
    /// 写不进去时在屏幕上说（第 20 条），不挡这条消息
    static func watchUser(_ text: String, chatId: String, charId: String, msgId: String) {
        guard localOn() else { return }
        do {
            if let hit = detect(text) {
                let near = ((try? Repo.messages(chatId: chatId, limit: 6)) ?? []).filter { $0.id != msgId }.suffix(5).map(\.content)
                try propose(text: hit.text, chatId: chatId, charId: charId, srcMsgId: msgId, from: fromLocal, near: Array(near))
            } else {
                try attachTime(chatId: chatId, text: text)
            }
        } catch {
            Problems.report("待办未能记下：\(error.localizedDescription)")
        }
    }

    /// 角色写的 `[待办：…]`：不占气泡，落一条待确认。时刻可能在前面几句里说过
    static func fromMark(_ text: String, chatId: String, charId: String) {
        do {
            let near = ((try? Repo.messages(chatId: chatId, limit: 6)) ?? []).map(\.content)
            try propose(text: text, chatId: chatId, charId: charId, from: fromChar, near: near)
        } catch {
            Problems.report("待办未能记下：\(error.localizedDescription)")
        }
    }
}

/// 备忘（网页版 system/note.js，ARCHITECTURE 4.104h）：用户自己要留着的字。和待办同一个 app，两个数据域。
/// 角色手机里那份备忘录是角色的，和这一份无关。Apple 备忘录没有写入接口，送过去走系统分享面板。
enum Notes {
    static let collection = "notes"
    static let fromMe = "manual", fromChat = "chat"

    static func fromLabel(_ f: String) -> String { f == fromChat ? "来自对话" : "手动添加" }

    /// 列表上显示的那一行：第一行（有意截断：列表只显示一行）
    static func titleOf(_ r: Row) -> String {
        let first = r.string("text").components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let t = String(first.trimmingCharacters(in: .whitespaces).prefix(40))
        return t.isEmpty ? "（空）" : t
    }

    /// 第一行之外还剩什么（有意截断：列表上的副标题只显示一行）
    static func restOf(_ r: Row) -> String {
        let lines = r.string("text").components(separatedBy: .newlines)
        guard let at = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        let rest = lines[(at + 1)...].joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return String(rest.prefix(60))
    }

    @discardableResult
    static func add(_ text: String = "", from: String = fromMe, chatId: String = "", charId: String = "") throws -> Row {
        let at = Date().millis
        let row = Row.new(prefix: "nt", ["text": .string(text), "from": .string(from), "chatId": .string(chatId), "charId": .string(charId),
                                         "createdAt": .number(at), "updatedAt": .number(at)])
        try Database.shared.put(collection, row)
        return row
    }

    static func get(_ id: String) -> Row? { (try? Database.shared.get(collection, id: id)).flatMap { $0 } }

    static func update(_ id: String, text: String) throws {
        guard var row = try Database.shared.get(collection, id: id) else { return }
        row["text"] = .string(text)
        row.touch()
        try Database.shared.put(collection, row)
    }

    static func remove(_ id: String) throws { try Database.shared.delete(collection, id: id) }

    /// 改得最近的在前；同一时刻按建的时间、最后按 id
    static func all() -> [Row] {
        ((try? Database.shared.all(collection)) ?? []).sorted { a, b in
            let ua = a.number("updatedAt") ?? 0, ub = b.number("updatedAt") ?? 0
            if ua != ub { return ua > ub }
            let ca = a.created ?? 0, cb = b.created ?? 0
            if ca != cb { return ca > cb }
            return a.id > b.id
        }
    }

    static func search(_ q: String) -> [Row] {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return all() }
        return all().filter { $0.string("text").lowercased().contains(t) }
    }
}
