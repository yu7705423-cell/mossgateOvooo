import Foundation

/// 日记（网页版 system/diary.js、ai/tasks/diary.js、ai/context/diary.js，ARCHITECTURE 4.333）。
///
/// 你的与角色的都在 diaries 这一域，owner 分：'me' 是你，其余是角色 id。按身份隔开（personaId）。
/// 角色写不写、写多少、写到一半停下，都由它自己在那一次输出里定（规约第 22 条）；程序只给它机会：
/// 你点「现在写一篇」（手动，一次请求），或者每天到了设定时刻之后自动一次（char.diaryAuto，默认关；
/// 先占住当天再发，失败也算试过，当天不再自动第二次）。
///
/// 原生版暂未做：你的日记上锁（要应用锁屏密码）、生成配图。
enum Diary {
    static let me = "me"
    static let kinds: [(id: String, label: String)] = [("full", "完整"), ("short", "简短"), ("unfinished", "未写完")]
    static let moods: [(id: String, label: String)] = [("good", "不错"), ("flat", "一般"), ("low", "低落"), ("tense", "烦躁")]
    static let visibility: [(id: String, label: String)] = [("public", "公开"), ("self", "仅自己")]
    static let hourDefault = 22
    static let titleMax = 40

    struct Entry: Identifiable, Equatable {
        var row: Row
        var id: String { row.id }
        var owner: String { row.string("owner") }
        var mine: Bool { owner == Diary.me }
        var date: String { row.string("date") }
        var title: String { row.string("title") }
        var text: String { row.string("text") }
        var process: String { row.string("process") }
        var kind: String { row.string("kind") }
        var mood: String { row.string("mood") }
        var charId: String { row.string("charId") }
        var imageIds: [String] { row.strings("imageIds") }
        var visibility: String { row.string("visibility").isEmpty ? "self" : row.string("visibility") }
        var created: Double { row.number("createdAt") ?? 0 }
        /// 角色的锁：{ code, digits, tries, lastTryAt, openedAt, hintAt }
        var lock: [String: JSONValue]? { row["lock"]?.object }
        /// 对你而言现在是不是锁着。你自己上了锁的（网页版写的）原生版暂时打不开
        var locked: Bool {
            guard let lock else { return false }
            if mine { return visibility == "lock" }
            return (lock["openedAt"]?.number ?? 0) <= 0
        }
    }

    // MARK: - 日期

    private static func key(_ d: Date, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 你这边的今天。
    static func todayMine(_ now: Date = Date()) -> String { key(now, .current) }

    static func zone(_ char: Character?) -> TimeZone {
        let id = char?.row.string("timezone") ?? ""
        return TimeZone(identifier: id) ?? .current
    }

    /// 角色那边的今天：深夜（早上六点之前）算前一天（网页版 day.dateKey）。
    static func todayOf(_ char: Character?, _ now: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone(char)
        let h = cal.component(.hour, from: now)
        return key(h < 6 ? now.addingTimeInterval(-86400) : now, zone(char))
    }

    static func shift(_ date: String, days: Int) -> String {
        let p = date.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return date }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        guard let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)),
              let n = cal.date(byAdding: .day, value: days, to: d) else { return date }
        return key(n, .current)
    }

    // MARK: - 写作过程

    struct Step: Equatable {
        var text = ""
        var deleted = ""
        var pause = false
    }

    /// 写的过程：写了又删掉的包在 ~~ ~~ 里，停下来的地方是 ||。正文是去掉这两样之后剩下的。
    static func parseProcess(_ process: String) -> (steps: [Step], text: String, edits: Int) {
        let src = process.replacingOccurrences(of: "\r\n", with: "\n")
        guard let re = try? NSRegularExpression(pattern: #"~~([\s\S]*?)~~|\|\|"#) else { return ([], src, 0) }
        let ns = src as NSString
        var steps: [Step] = []
        var last = 0
        for m in re.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { steps.append(Step(text: ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
            if ns.substring(with: m.range) == "||" { steps.append(Step(pause: true)) }
            else if m.range(at: 1).length > 0 { steps.append(Step(deleted: ns.substring(with: m.range(at: 1)))) }
            last = m.range.location + m.range.length
        }
        if last < ns.length { steps.append(Step(text: ns.substring(from: last))) }
        let text = steps.map(\.text).joined()
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (steps, text, steps.filter { !$0.deleted.isEmpty }.count)
    }

    // MARK: - 读

    static func personaId() -> String { (try? Repo.activePersona())?.id ?? "" }

    private static func samePersona(_ e: Entry, _ pid: String) -> Bool {
        let p = e.row.string("personaId")
        return p.isEmpty || p == pid
    }

    private static func sorted(_ list: [Entry]) -> [Entry] {
        list.sorted { $0.date != $1.date ? $0.date > $1.date : $0.created > $1.created }
    }

    static func mine(_ pid: String = personaId()) throws -> [Entry] {
        sorted(try Database.shared.all("diaries", where: me).map(Entry.init(row:)).filter { samePersona($0, pid) })
    }

    static func ofChar(_ charId: String, _ pid: String = personaId()) throws -> [Entry] {
        sorted(try Database.shared.all("diaries", where: charId).map(Entry.init(row:)).filter { samePersona($0, pid) })
    }

    /// 写过日记的角色，按最近一篇排。
    struct Writer: Identifiable {
        var char: Character
        var last: String
        var id: String { char.id }
    }

    static func writers(_ pid: String = personaId()) throws -> [Writer] {
        var last: [String: String] = [:]
        for r in try Database.shared.all("diaries") {
            let e = Entry(row: r)
            guard !e.mine, samePersona(e, pid) else { continue }
            if e.date > (last[e.owner] ?? "") { last[e.owner] = e.date }
        }
        var out: [Writer] = []
        for (k, v) in last {
            if let c = try? Repo.character(k) { out.append(Writer(char: c, last: v)) }
        }
        return out.sorted { $0.last > $1.last }
    }

    /// 你与这个角色的私聊（当前身份下）。
    static func chatWith(_ charId: String, _ pid: String = personaId()) -> Chat? {
        ((try? Repo.chats()) ?? []).first { c in
            !c.isGroup && c.characterIds == [charId] && (c.personaId.isEmpty || c.personaId == pid)
        }
    }

    /// 你的日记里，这个角色读得到的：公开、关联它或不关联任何角色，日期不早于 since。
    static func mineShownTo(_ charId: String, _ pid: String, since: String = "") throws -> [Entry] {
        try mine(pid).filter { $0.visibility == "public" && ($0.charId.isEmpty || $0.charId == charId) && (since.isEmpty || $0.date >= since) }
    }

    // MARK: - 日历与当天（网页版 diary.js 的 month、moodOn、on、timeline、pastYears）

    /// 心情：先读健康 app 里那一天的；角色没有时读它那一天日记里自己给的
    static func moodOn(_ who: String, _ date: String, _ pid: String = personaId()) -> String {
        let h = Health.day(who, date).mood
        if !h.isEmpty || who == me { return h }
        return ((try? ofChar(who, pid)) ?? []).first { $0.date == date && !$0.mood.isEmpty }?.mood ?? ""
    }

    /// 你那一天的心情，直接写进健康 app（不另存一份）
    static func setMyMood(_ date: String, _ mood: String) throws {
        try Health.set(me, date, ["mood": .string(moods.contains { $0.id == mood } ? mood : "")])
    }

    struct Cell: Equatable { var me = "", char = "", mine = 0, theirs = 0 }

    /// 一个月的格子。charId 空时 theirs 数所有角色的
    static func month(_ year: Int, _ month1: Int, charId: String, _ pid: String = personaId()) -> [String: Cell] {
        let prefix = String(format: "%04d-%02d-", year, month1)
        var out: [String: Cell] = [:]
        for r in (try? Database.shared.all("diaries")) ?? [] {
            let e = Entry(row: r)
            guard e.date.hasPrefix(prefix), samePersona(e, pid) else { continue }
            if e.mine { out[e.date, default: Cell()].mine += 1 }
            else if charId.isEmpty || e.owner == charId { out[e.date, default: Cell()].theirs += 1 }
        }
        var comps = DateComponents(); comps.year = year; comps.month = month1
        let days = Calendar(identifier: .gregorian).date(from: comps).flatMap { Calendar(identifier: .gregorian).range(of: .day, in: .month, for: $0)?.count } ?? 30
        for i in 1...days {
            let date = prefix + String(format: "%02d", i)
            let m = Health.day(me, date).mood
            let c = charId.isEmpty ? "" : moodOn(charId, date, pid)
            if !m.isEmpty || !c.isEmpty { out[date, default: Cell()].me = m; out[date, default: Cell()].char = c }
        }
        return out
    }

    /// 某一天的全部日记。charId 给了就只要你的与这个角色的
    static func on(_ date: String, charId: String, _ pid: String = personaId()) -> [Entry] {
        ((try? Database.shared.all("diaries")) ?? []).map(Entry.init(row:))
            .filter { $0.date == date && samePersona($0, pid) && (charId.isEmpty || $0.mine || $0.owner == charId) }
            .sorted { $0.created < $1.created }
    }

    /// 可以在日历上切换的角色：和当前身份有私聊的，外加写过日记的
    static func charChoices(_ pid: String = personaId()) -> [Character] {
        var ids = ((try? writers(pid)) ?? []).map(\.char.id)
        for c in (try? Repo.characters()) ?? [] where (c.parentId ?? "").isEmpty && !c.isNpc && !ids.contains(c.id) {
            if chatWith(c.id, pid) != nil { ids.append(c.id) }
        }
        return ids.compactMap { (try? Repo.character($0)) ?? nil }
    }

    struct Event: Equatable {
        var at: Double
        var time: String
        var type: String      // chat、letter、letterDue、anniversary、diary
        var title = ""
        var count = 0
        var last = ""
        var mine = false
        var years = 0
        var chatId = ""
        var diaryId = ""
    }

    private static func hm(_ ms: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date(millis: ms))
    }

    private static func localDate(_ ms: Double) -> String { key(Date(millis: ms), .current) }

    /// 一条消息在时间线上怎么显示：文字取头一截，别的写种类
    static func lineOf(_ m: Message) -> String {
        if m.kind == "image" || !m.imageId.isEmpty { return "[图片]" }
        if m.kind == "voice" { return "[语音]" }
        if m.kind == "sticker" { return "[表情]" }
        let t = m.content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.count > 40 ? String(t.prefix(40)) + "…" : t
    }

    /// 这一天发生过的事，按时间排好。只读已有的记录，不调接口
    static func timeline(_ date: String, charId: String, _ pid: String = personaId()) -> [Event] {
        var out: [Event] = []
        if !charId.isEmpty, let chat = chatWith(charId, pid) {
            let all = (try? Repo.messages(chatId: chat.id)) ?? []
            let said = all.filter { !$0.isError && !["side", "notice", "letter"].contains($0.kind) && localDate($0.createdAt) == date }
            if let first = said.first, let last = said.last {
                out.append(Event(at: first.createdAt, time: first.createdAt == last.createdAt ? hm(first.createdAt) : "\(hm(first.createdAt)) – \(hm(last.createdAt))",
                                 type: "chat", count: said.count, last: lineOf(last), chatId: chat.id))
            }
            for m in all where m.kind == "letter" && localDate(m.createdAt) == date {
                out.append(Event(at: m.createdAt, time: hm(m.createdAt), type: "letter", title: m.row.string("title"), mine: m.role == .user, chatId: chat.id))
            }
            for d in Space.drafts(chat.id) {
                let at = d.number("sendAt") ?? 0
                if at > 0 && localDate(at) == date {
                    out.append(Event(at: at, time: hm(at), type: "letterDue", title: d.string("title"), chatId: chat.id))
                }
            }
            let md = String(date.suffix(5))
            for x in Space.days(chat.id) {
                let d = x.string("date")
                if d == date || (x.bool("yearly") && String(d.suffix(5)) == md && d < date) {
                    out.append(Event(at: 0, time: "全天", type: "anniversary", title: x.string("title"),
                                     years: d < date ? (Int(date.prefix(4)) ?? 0) - (Int(d.prefix(4)) ?? 0) : 0))
                }
            }
        }
        for e in on(date, charId: charId, pid) {
            out.append(Event(at: e.created, time: hm(e.created), type: "diary", diaryId: e.id))
        }
        return out.sorted { $0.at < $1.at }
    }

    /// 往年的这一天写过的日记，新的在前
    static func pastYears(_ date: String, charId: String, _ pid: String = personaId()) -> [Entry] {
        let md = String(date.suffix(5))
        return sorted(((try? Database.shared.all("diaries")) ?? []).map(Entry.init(row:)).filter {
            samePersona($0, pid) && $0.date < date && String($0.date.suffix(5)) == md && (charId.isEmpty || $0.mine || $0.owner == charId)
        })
    }

    // MARK: - 你的日记

    @discardableResult
    static func saveMine(id: String? = nil, date: String, title: String, text: String, visibility: String, charId: String,
                         imageIds: [String]? = nil) throws -> Entry {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw StoreError(message: "请填写日记内容") }
        let vis = Diary.visibility.contains { $0.id == visibility } ? visibility : "self"
        var fields: [String: JSONValue] = [
            "title": .string(String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(titleMax))),
            "text": .string(t), "visibility": .string(vis),
            "charId": .string(charId.isEmpty || (try? Repo.character(charId)) == nil ? "" : charId),
            "date": .string(date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? date : todayMine()),
        ]
        if let imageIds { fields["imageIds"] = .array(imageIds.filter { !$0.isEmpty }.map { .string($0) }) }
        var row: Row
        if let id, let old = try Database.shared.get("diaries", id: id) {
            row = old
            for (k, v) in fields { row[k] = v }
            row.touch()
        } else {
            var all = fields
            all["owner"] = .string(me)
            all["personaId"] = .string(personaId())
            all["source"] = .string("manual")
            all["font"] = .string("")
            all["paper"] = .string("")
            if all["imageIds"] == nil { all["imageIds"] = .array([]) }
            all["lock"] = .null
            row = Row.new(prefix: "diary", all)
        }
        try Database.shared.put("diaries", row)
        return Entry(row: row)
    }

    static func remove(_ id: String) throws { try Database.shared.delete("diaries", id: id) }

    // MARK: - 角色的锁

    /// 输角色日记的密码：记一次尝试，对了记下解开的时刻，之后一直开着。
    static func tryOpen(_ id: String, _ input: String) throws -> Bool {
        guard var row = try Database.shared.get("diaries", id: id), var lock = row["lock"]?.object else { return true }
        let ok = input.trimmingCharacters(in: .whitespaces) == (lock["code"]?.string ?? "")
        let now = Date().millis
        lock["tries"] = .number((lock["tries"]?.number ?? 0) + 1)
        lock["lastTryAt"] = .number(now)
        lock["openedAt"] = .number(ok ? now : 0)
        row["lock"] = .object(lock)
        row.touch()
        try Database.shared.put("diaries", row)
        return ok
    }

    /// 请角色给提示：在私聊里以你的名义发一条，记下时刻。角色怎么回由它自己定，回复照常由你点。
    static func askHint(_ id: String) throws -> String {
        guard var row = try Database.shared.get("diaries", id: id), var lock = row["lock"]?.object else {
            throw StoreError(message: "这一篇没有上锁")
        }
        let e = Entry(row: row)
        guard let chat = chatWith(e.owner, row.string("personaId").isEmpty ? personaId() : row.string("personaId")) else {
            throw StoreError(message: "尚未与该角色建立会话")
        }
        lock["hintAt"] = .number(Date().millis)
        row["lock"] = .object(lock)
        try Database.shared.put("diaries", row)
        let p = e.date.split(separator: "-").compactMap { Int($0) }
        let m = Message.new(chatId: chat.id, role: .user, authorId: "me",
                            content: "\(p.count == 3 ? p[1] : 0) 月 \(p.count == 3 ? p[2] : 0) 日那篇上了锁的日记，可以给我一点密码的提示吗？")
        _ = try Repo.append(m)
        if var c = try Repo.chat(chat.id) { c.row["lastMessageAt"] = .number(Date().millis); try Repo.save(c) }
        return chat.id
    }

    // MARK: - 角色写

    static func hour(_ char: Character) -> Int {
        guard let n = char.row.number("diaryHour"), n >= 0, n <= 23 else { return hourDefault }
        return Int(n.rounded())
    }

    static func isAuto(_ char: Character) -> Bool { char.row["diaryAuto"]?.bool == true && !char.archived }

    /// 角色那边到了可以写的时刻：设定的钟点之后，或者凌晨（算前一天的那一次机会）。
    static func due(_ char: Character, _ now: Date = Date()) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone(char)
        let h = cal.component(.hour, from: now)
        return h >= hour(char) || h < 6
    }

    /// 历史窗口（网页版 window.js 的 recentWindow）：按轮数时从尾往前数 historyTurns 个起点，按条数时取最近 historyLimit 条；0 为全部。
    /// 一轮从「前一条不是用户」的那条用户消息开始（与聊天的历史同一把尺子）
    static func recentWindow(_ msgs: [Message], _ s: AppSettings) -> [Message] {
        if s.raw["historyMode"]?.string == "turn" {
            let n = max(0, Int((s.raw["historyTurns"]?.number ?? 10).rounded()))
            guard n > 0 else { return msgs }
            var seen = 0
            for i in stride(from: msgs.count - 1, through: 0, by: -1)
                where msgs[i].role == .user && (i == 0 || msgs[i - 1].role != .user) {
                seen += 1
                if seen >= n { return Array(msgs[i...]) }
            }
            return msgs
        }
        let n = max(0, Int((s.raw["historyLimit"]?.number ?? 20).rounded()))
        return n > 0 ? Array(msgs.suffix(n)) : msgs
    }

    /// 交给模型的那一天（网页版 tasks/diary.js 的 dayContext）：人设、记忆、当天的日程与撞上的事、身体状态、当天的对话、
    /// 你给它看的日记、它上一篇。
    static func context(_ char: Character, date: String, pid: String) throws -> String {
        let s = AppSettings.load()
        let personas = try Repo.personas()
        let userName = personas.first { $0.id == pid }?.name ?? "the user"
        var out: [String] = []
        if !char.persona.isEmpty { out.append("### Character card\n\(char.persona)") }
        let root = Repo.rootId(of: pid, in: personas)
        let mems = try Repo.memories(charId: char.id).filter { m in
            (m.rank == "S" || m.rank == "A") && (root.isEmpty || m.personaId.isEmpty || Repo.rootId(of: m.personaId, in: personas) == root)
        }.prefix(12).map { "- \($0.content)" }
        if !mems.isEmpty { out.append("### What \(char.name) remembers\n\(mems.joined(separator: "\n"))") }

        // 当天的日程（日常）与撞上的事
        if let plan = try DayPlan.day(char.id, date: date) {
            let items = plan["items"]?.array ?? []
            var lines: [String] = DayPlan.slots.compactMap { sl -> String? in
                let list = items.filter { $0["slot"]?.string == sl.id && $0["state"]?.string != DayPlan.drop }
                return list.isEmpty ? nil : "\(sl.label): " + list.map { $0["text"]?.string ?? "" }.joined(separator: "；")
            }
            let ev = plan["event"]?["text"]?.string ?? ""
            if !ev.isEmpty { lines.append("Event: \(ev)") }
            if !lines.isEmpty { out.append("### \(char.name)'s schedule today\n" + lines.joined(separator: "\n")) }
        }

        // 当天的身体状态（健康）
        let h = Health.day(char.id, date)
        if !h.mood.isEmpty || !h.energy.isEmpty || !h.note.isEmpty {
            let mood = Health.label(Health.moods, h.mood), energy = Health.label(Health.energy, h.energy)
            let lines = [h.mood.isEmpty ? "" : "mood: \(mood.isEmpty ? h.mood : mood)",
                         h.energy.isEmpty ? "" : "energy: \(energy.isEmpty ? h.energy : energy)",
                         h.note].filter { !$0.isEmpty }
            out.append("### \(char.name)'s body today\n" + lines.joined(separator: "\n"))
        }

        if let chat = chatWith(char.id, pid) {
            // 按世界时间（虚拟时间平移）归到角色那边的哪一天；分隔线不算对话
            let off = Clock.offset(s)
            let today = try Ties.keepDelivered(chat, Repo.messages(chatId: chat.id).filter { m in
                !m.isError && !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && m.kind != "side"
            }).filter { todayOf(char, Date(millis: $0.createdAt + off)) == date }
            let rows = recentWindow(today, s)
            if !rows.isEmpty {
                out.append("### Conversation with \(userName) today\n" + rows.map { "\($0.role == .user ? userName : char.name)：\($0.content)" }.joined(separator: "\n"))
            }
        }
        let shown = try mineShownTo(char.id, pid, since: date).filter { $0.date == date }
        if !shown.isEmpty {
            out.append("### \(userName)'s diary today, shown to \(char.name)\n" + shown.map { ($0.title.isEmpty ? "" : $0.title + "\n") + $0.text }.joined(separator: "\n\n"))
        }
        if let prev = try ofChar(char.id, pid).first(where: { $0.date < date }) {
            out.append("### \(char.name)'s previous diary entry (\(prev.date))\n\(prev.text)")
        }
        return out.joined(separator: "\n\n")
    }

    enum Outcome: Equatable {
        case skipped
        case wrote(String)
    }

    /// 写一次（一次请求）。角色选了不写时返回 .none。source：now 你点的 / auto 每天自动那一次。
    static func write(charId: String, source: String = "now", pid: String = personaId()) async throws -> Outcome {
        guard let char = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        let date = todayOf(char)
        let s = AppSettings.load()
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let p = date.split(separator: "-").compactMap { Int($0) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let wd = p.count == 3 ? cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)).map { weekdays[cal.component(.weekday, from: $0) - 1] } ?? "" : ""
        let userName = try Repo.personas().first { $0.id == pid }?.name ?? "the user"
        let system = Templates.render("task.diary", [
            "charName": char.name, "userName": userName, "date": date, "weekday": wd,
            "moodList": moods.map { "\($0.id) = \($0.label)" }.joined(separator: "\n"),
        ], settings: s) + "\n\n## \(date)\n" + (try context(char, date: date, pid: pid))
        let r = try await AIService.shared.send(task: "diary.write", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: 4000)
        guard let j = JSONReply.parse(r.text), j.object != nil else { throw StoreError(message: JSONReply.failure(r.text)) }
        let kind = (j["write"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        if kind == "none" {
            try patchChar(charId, ["diaryNoneAt": .string(date)])
            return .skipped
        }
        let process = j["process"]?.string ?? j["text"]?.string ?? ""
        let parsed = parseProcess(process)
        guard !parsed.text.isEmpty else { throw StoreError(message: "模型交回的日记是空的") }
        var lock: JSONValue = .null
        let codeRaw = j["lock"]?.string ?? j["lock"]?.number.map { String(Int($0)) } ?? ""
        let code = String(codeRaw.trimmingCharacters(in: .whitespaces).prefix(32))
        if !code.isEmpty && code != "null" && code != "none" {
            lock = .object(["code": .string(code), "digits": .bool(code.range(of: #"^\d{3,12}$"#, options: .regularExpression) != nil),
                            "tries": .number(0), "lastTryAt": .number(0), "openedAt": .number(0), "hintAt": .number(0)])
        }
        let mood = j["mood"]?.string ?? ""
        let row = Row.new(prefix: "diary", [
            "owner": .string(charId), "charId": .string(charId), "personaId": .string(pid), "date": .string(date),
            "kind": .string(kinds.contains { $0.id == kind } ? kind : "full"),
            "title": .string(String((j["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(titleMax))),
            "mood": .string(moods.contains { $0.id == mood } ? mood : ""),
            "process": .string(process), "text": .string(parsed.text), "edits": .number(Double(parsed.edits)),
            "font": .string("hand"), "paper": .string(""), "imageIds": .array([]), "source": .string(source), "lock": lock,
        ])
        try Database.shared.put("diaries", row)
        return .wrote(row.id)
    }

    /// 每天自动那一次：开着、到了时刻、今天还没试过、今天还没有一篇。先占住今天、在角色身上记一笔，再发请求；
    /// 失败的原因记在角色身上，明天再自动试。返回这一次有没有发出请求。
    @discardableResult
    static func ensureToday(_ charId: String, now: Date = Date()) async -> Bool {
        guard let char = try? Repo.character(charId), isAuto(char), due(char, now) else { return false }
        let date = todayOf(char, now)
        if char.row.string("diaryAutoAt") == date { return false }
        let pid = personaId()
        if ((try? ofChar(charId, pid)) ?? []).contains(where: { $0.date == date }) { return false }
        guard Daily.claim("diary", charId, date) else { return false }
        do { try patchChar(charId, ["diaryAutoAt": .string(date), "diaryAutoError": .string("")]) }
        catch { return false }
        do { _ = try await write(charId: charId, source: "auto", pid: pid) }
        catch { try? patchChar(charId, ["diaryAutoError": .string(error.localizedDescription)]) }
        return true
    }

    static func patchChar(_ id: String, _ patch: [String: JSONValue]) throws {
        guard var c = try Repo.character(id) else { return }
        for (k, v) in patch { c.row[k] = v }
        c.row.touch()
        try Database.shared.put(Collections.characters, c.row)
    }

    /// 删角色时：它的日记一并删掉；你的日记里关联它的改成不关联（网页版 purge.dropCharacter）。
    static func dropCharacter(_ id: String) throws {
        try Database.shared.deleteAll("diaries", where: id)
        for var r in try Database.shared.all("diaries", where: me) where r.string("charId") == id {
            r["charId"] = .string("")
            try Database.shared.put("diaries", r)
        }
    }

    // MARK: - 进聊天提示词（网页版 context/diary.js）

    /// 你设为公开、给这个角色看的日记，它自己最近写的，以及上了锁的那几篇的事实。最近几天由 diaryDays 定（默认 2，0 为全部）。
    static func block(char: Character, pid: String, userName: String, now: Date = Date()) -> String {
        let n = Int((AppSettings.load().raw["diaryDays"]?.number ?? 2).rounded())
        let since = n > 0 ? shift(todayMine(now), days: -(n - 1)) : ""
        let theirs = Array(((try? mineShownTo(char.id, pid, since: since)) ?? []).reversed())
        let ownAll = (try? ofChar(char.id, pid)) ?? []
        let own = Array(ownAll.filter { since.isEmpty || $0.date >= since }.reversed())
        let nowMs = now.millis
        func recent(_ t: Double?) -> Bool { (t ?? 0) > 0 && nowMs - (t ?? 0) < 7 * 86_400_000 }
        let locked = Array(ownAll.filter { e in
            guard let k = e.lock else { return false }
            return own.contains(e) || recent(k["lastTryAt"]?.number) || recent(k["openedAt"]?.number) || recent(k["hintAt"]?.number)
        }.reversed())
        if theirs.isEmpty && own.isEmpty && locked.isEmpty { return "" }
        func entry(_ e: Entry) -> String {
            "(\(e.date)\(e.kind == "unfinished" ? ", unfinished" : ""))\(e.title.isEmpty ? "" : " " + e.title)\n\(e.text)"
        }
        func at(_ t: Double) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "M-d HH:mm"
            return f.string(from: Date(millis: t))
        }
        var out: [String] = []
        if !own.isEmpty { out.append("Your own diary entries:\n" + own.map(entry).joined(separator: "\n\n")) }
        if !locked.isEmpty {
            out.append("Your locked entries:\n" + locked.map { e -> String in
                let k = e.lock ?? [:]
                var bits = ["- \(e.date): password \"\(k["code"]?.string ?? "")\"."]
                let opened = k["openedAt"]?.number ?? 0, tries = Int(k["tries"]?.number ?? 0)
                if opened > 0 { bits.append("\(userName) opened it at \(at(opened)) after \(max(1, tries)) tries.") }
                else if tries > 0 { bits.append("\(userName) has tried \(tries) times, last at \(at(k["lastTryAt"]?.number ?? 0)); not opened.") }
                else { bits.append("\(userName) has not tried to open it.") }
                if let h = k["hintAt"]?.number, h > 0 { bits.append("\(userName) asked you for a hint at \(at(h)).") }
                return bits.joined(separator: " ")
            }.joined(separator: "\n"))
        }
        if !theirs.isEmpty { out.append("Diary entries \(userName) has chosen to show you:\n" + theirs.map(entry).joined(separator: "\n\n")) }
        return "[日记]\n" + out.joined(separator: "\n\n")
    }
}

/// 每天一次的自动任务：当天试过就不再自动试，成功失败都算（网页版 ai/daily.js）。本机记着，不进库。
enum Daily {
    private static let key = "phone.daily.tried"
    private static let lock = NSLock()

    static func triedOn(_ task: String, _ id: String, _ date: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?["\(task):\(id)"] == date
    }

    /// 占住今天。占到了返回 true，今天已经被占过返回 false。在发请求之前调。
    static func claim(_ task: String, _ id: String, _ date: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var m = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        if m["\(task):\(id)"] == date { return false }
        for (k, v) in m where v != date && k.hasPrefix("\(task):") { m[k] = nil }
        m["\(task):\(id)"] = date
        UserDefaults.standard.set(m, forKey: key)
        return true
    }
}
