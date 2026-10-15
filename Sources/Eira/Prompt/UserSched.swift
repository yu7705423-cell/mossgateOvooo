import Foundation

/// 你的日程（网页版 system/usersched.js、context/usersched.js，ARCHITECTURE 4.321）。
///
/// 和待办分开：日程是一段段占着的时间（课表、排班、通勤），每周一样地来。数据域 userSched，按 owner（身份的本体）查。
/// 一行：repeat（weekly / once）、weekday（1 到 7，周一为 1）或 date、start、end、title、place、note、
/// from、to（每周重复的起止日期）、weeks（all / odd / even）、kind（class / work / commute / other）、
/// 通勤另有 origin、dest、via、mins；source（manual / import）。
///
/// 日期一律按你的时区算。角色读到的是事实：哪天几点到几点、什么事、在哪儿（规约第 16 条）。
/// 不给看的角色记在 settings.userSchedHidden。读往前几天、往后几天由 userSchedBack / userSchedAhead 定（默认 1 与 0）。
enum UserSched {
    static let collection = "userSched"
    static let weekly = "weekly", once = "once"
    static let weeks: [(id: String, label: String)] = [("all", "每周"), ("odd", "单周"), ("even", "双周")]
    static let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    static let kinds: [(id: String, label: String, tag: String, en: String)] = [
        ("class", "课程", "课", "Class"), ("work", "上班", "班", "Work"), ("commute", "通勤", "通", "Commute"), ("other", "其他", "他", "Other"),
    ]
    static let ways = ["地铁", "公交", "步行", "骑车", "开车", "打车", "其他"]

    struct Item: Identifiable, Equatable {
        var row: Row
        var id: String { row.id }
        var repeatMode: String { row.string("repeat") == UserSched.once ? UserSched.once : UserSched.weekly }
        var weekday: Int { Int(row.number("weekday") ?? 0) }
        var date: String { row.string("date") }
        var start: String { row.string("start") }
        var end: String { row.string("end") }
        var title: String { row.string("title") }
        var place: String { row.string("place") }
        var note: String { row.string("note") }
        var from: String { row.string("from") }
        var to: String { row.string("to") }
        var weeksMode: String { row.string("weeks").isEmpty ? "all" : row.string("weeks") }
        var origin: String { row.string("origin") }
        var dest: String { row.string("dest") }
        var via: String { row.string("via") }
        var mins: Int { Int(row.number("mins") ?? 0) }
        /// 老数据没有 kind：导入的算课程，手动的算其他
        var kind: String {
            let k = row.string("kind")
            if UserSched.kinds.contains(where: { $0.id == k }) { return k }
            return row.string("source") == "import" ? "class" : "other"
        }
        var span: String { end.isEmpty ? start : "\(start)-\(end)" }
        var whenText: String {
            repeatMode == UserSched.once ? date
                : ((1...7).contains(weekday) ? UserSched.weekdays[weekday - 1] : "") + (weeksMode == "odd" ? "（单周）" : weeksMode == "even" ? "（双周）" : "")
        }
    }

    // MARK: - 整理

    /// 「8:5」「08:05」「8点05」「0805」都认成 08:05；认不出为空
    static func hm(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespaces)
        for c in ["：", "点", "時", "时"] { s = s.replacingOccurrences(of: c, with: ":") }
        if s.hasSuffix("分") { s.removeLast() }
        var h = -1, mi = 0
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let a = Int(parts[0]), parts[0].count <= 2, parts[1].count <= 2 {
            h = a; mi = parts[1].isEmpty ? 0 : (Int(parts[1]) ?? -1)
        } else if parts.count == 1, s.count <= 2, let a = Int(s) {
            h = a
        } else if parts.count == 1, s.count == 4, s.allSatisfy(\.isNumber), let a = Int(s.prefix(2)), let b = Int(s.suffix(2)) {
            h = a; mi = b
        }
        guard (0...24).contains(h), (0..<60).contains(mi), !(h == 24 && mi > 0) else { return "" }
        return String(format: "%02d:%02d", h, mi)
    }

    static func minutes(_ t: String) -> Int {
        let x = hm(t)
        guard !x.isEmpty else { return -1 }
        return (Int(x.prefix(2)) ?? 0) * 60 + (Int(x.suffix(2)) ?? 0)
    }

    private static func isDate(_ s: String) -> Bool { s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }

    private static func clean(_ s: String, _ n: Int) -> String {
        String(s.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(n))
    }

    /// 整理成能存的一行；缺了必需的（名字、开始时刻、周几或日期）返回 nil
    static func normalize(_ raw: [String: JSONValue]) -> [String: JSONValue]? {
        func str(_ k: String) -> String { raw[k]?.string ?? raw[k]?.number.map { String(Int($0)) } ?? "" }
        let weekdayRaw = Int(raw["weekday"]?.number ?? Double(str("weekday")) ?? 0)
        let repeatMode = str("repeat") == once || (weekdayRaw == 0 && isDate(str("date"))) ? once : weekly
        let kind = kinds.contains { $0.id == str("kind") } ? str("kind") : ""
        let commute = kind == "commute"
        let origin = commute ? clean(str("origin"), 30) : ""
        let dest = commute ? clean(str("dest"), 30) : ""
        let mins = commute ? max(0, Int((raw["mins"]?.number ?? Double(str("mins")) ?? 0).rounded())) : 0
        var title = clean(str("title"), 60)
        if title.isEmpty && commute && (!origin.isEmpty || !dest.isEmpty) {
            title = "\(origin.isEmpty ? "出发地" : origin) 到 \(dest.isEmpty ? "目的地" : dest)"
        }
        let start = hm(str("start"))
        var end = hm(str("end"))
        if end.isEmpty && mins > 0 && !start.isEmpty {
            let e = min(24 * 60, minutes(start) + mins)
            end = String(format: "%02d:%02d", e / 60, e % 60)
        }
        if !end.isEmpty && minutes(end) <= minutes(start) { end = "" }
        guard !title.isEmpty, !start.isEmpty else { return nil }
        var row: [String: JSONValue] = ["repeat": .string(repeatMode), "title": .string(title), "start": .string(start), "end": .string(end),
                                        "place": .string(clean(str("place"), 60)), "note": .string(clean(str("note"), 200))]
        if !kind.isEmpty { row["kind"] = .string(kind) }
        if commute {
            row["origin"] = .string(origin); row["dest"] = .string(dest)
            row["via"] = .string(clean(str("via"), 10)); row["mins"] = .number(Double(mins))
        }
        if repeatMode == once {
            guard isDate(str("date")) else { return nil }
            row["date"] = .string(str("date"))
        } else {
            guard (1...7).contains(weekdayRaw) else { return nil }
            row["weekday"] = .number(Double(weekdayRaw))
            let f = isDate(str("from")) ? str("from") : ""
            var t = isDate(str("to")) ? str("to") : ""
            if !f.isEmpty && !t.isEmpty && t < f { t = "" }
            row["from"] = .string(f); row["to"] = .string(t)
            row["weeks"] = .string(weeks.contains { $0.id == str("weeks") } ? str("weeks") : "all")
        }
        return row
    }

    // MARK: - 存取

    /// 这一个身份的日程归谁：小号跟本体
    static func ownerOf(_ personaId: String) -> String {
        let all = (try? Repo.personas()) ?? []
        let pid = personaId.isEmpty ? (((try? Repo.activePersona()) ?? nil)?.id ?? "") : personaId
        return Repo.rootId(of: pid, in: all)
    }

    static func list(_ owner: String) -> [Item] {
        ((try? Database.shared.all(collection, where: owner)) ?? []).map(Item.init(row:))
    }

    @discardableResult
    static func create(_ owner: String, _ raw: [String: JSONValue], source: String = "manual") throws -> Item {
        guard !owner.isEmpty else { throw StoreError(message: "没有当前身份") }
        guard var f = normalize(raw) else { throw StoreError(message: "请填写名称、开始时刻，以及周几或日期") }
        f["owner"] = .string(owner)
        f["source"] = .string(source)
        let row = Row.new(prefix: "us", f)
        try Database.shared.put(collection, row)
        return Item(row: row)
    }

    static func update(_ id: String, _ raw: [String: JSONValue]) throws {
        guard var cur = try Database.shared.get(collection, id: id) else { throw StoreError(message: "这一条已经不在了") }
        var merged = cur.fields
        merged.merge(raw) { _, n in n }
        guard let f = normalize(merged) else { throw StoreError(message: "请填写名称、开始时刻，以及周几或日期") }
        // 换了重复方式，另一种的字段清掉；不是通勤了，通勤那几项也清掉
        var wipe: [String: JSONValue] = f["repeat"]?.string == once
            ? ["weekday": .number(0), "from": .string(""), "to": .string(""), "weeks": .string("all")]
            : ["date": .string("")]
        if f["kind"]?.string != "commute" { wipe.merge(["origin": .string(""), "dest": .string(""), "via": .string(""), "mins": .number(0)]) { a, _ in a } }
        for (k, v) in wipe { cur[k] = v }
        for (k, v) in f { cur[k] = v }
        if f["kind"] == nil { cur["kind"] = nil }
        cur.touch()
        try Database.shared.put(collection, cur)
    }

    static func remove(_ id: String) throws { try Database.shared.delete(collection, id: id) }

    // MARK: - 日期（按 UTC 的日历算日子，与网页版一致）

    private static let utcCal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

    private static func dateOf(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return utcCal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    private static func keyOf(_ d: Date) -> String {
        let c = utcCal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func shiftKey(_ key: String, _ n: Int) -> String {
        guard let d = dateOf(key), let x = utcCal.date(byAdding: .day, value: n, to: d) else { return key }
        return keyOf(x)
    }

    /// 1 到 7，周一为 1
    static func weekdayOfKey(_ key: String) -> Int {
        guard let d = dateOf(key) else { return 0 }
        return (utcCal.component(.weekday, from: d) + 5) % 7 + 1
    }

    private static func mondayOf(_ key: String) -> String { shiftKey(key, 1 - weekdayOfKey(key)) }

    static func isoWeek(_ key: String) -> Int {
        guard let thu = dateOf(shiftKey(key, 4 - weekdayOfKey(key))) else { return 0 }
        let y = utcCal.component(.year, from: thu)
        guard let jan1 = utcCal.date(from: DateComponents(year: y, month: 1, day: 1)) else { return 0 }
        return Int((thu.timeIntervalSince(jan1) / 86400 / 7).rounded(.down)) + 1
    }

    /// 这一天是第几周：有起始日期按它那一周算第一周，没有按 ISO 周数
    static func weekNo(_ key: String, from: String = "") -> Int {
        guard !from.isEmpty, let a = dateOf(mondayOf(key)), let b = dateOf(mondayOf(from)) else { return isoWeek(key) }
        return Int((a.timeIntervalSince(b) / (7 * 86400)).rounded(.down)) + 1
    }

    static func occursOn(_ r: Item, _ key: String) -> Bool {
        if r.repeatMode == once { return r.date == key }
        if r.weekday != weekdayOfKey(key) { return false }
        if !r.from.isEmpty && key < r.from { return false }
        if !r.to.isEmpty && key > r.to { return false }
        if r.weeksMode == "odd" || r.weeksMode == "even" {
            let n = weekNo(key, from: r.from)
            if (n % 2 == 1) != (r.weeksMode == "odd") { return false }
        }
        return true
    }

    static func itemsOn(_ owner: String, _ key: String) -> [Item] {
        list(owner).filter { occursOn($0, key) }.sorted {
            minutes($0.start) != minutes($1.start) ? minutes($0.start) < minutes($1.start) : minutes($0.end) < minutes($1.end)
        }
    }

    /// 你的时区里，这一刻是哪一天、几点几分
    static func today(_ s: AppSettings, at: Date) -> (key: String, time: String) {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = Clock.zone(Clock.userZone(s))
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let p = f.string(from: at).split(separator: " ")
        return (String(p[0]), String(p[1]))
    }

    // MARK: - 给角色看

    static func visibleTo(_ charId: String, _ s: AppSettings) -> Bool {
        !(s.raw["userSchedHidden"]?.array ?? []).contains(.string(charId))
    }

    static func setVisible(_ charId: String, _ on: Bool, _ s: inout AppSettings) {
        var cur = (s.raw["userSchedHidden"]?.array ?? []).compactMap(\.string).filter { $0 != charId }
        if !on { cur.append(charId) }
        s.raw["userSchedHidden"] = .array(cur.map { .string($0) })
    }

    static func window(_ s: AppSettings) -> (back: Int, ahead: Int) {
        (max(0, Int(s.num("userSchedBack", 1))), max(0, Int(s.num("userSchedAhead", 0))))
    }

    // 写给模型的一行。类别名用英文（第 14 条），名称、地点、交通方式是数据，原样给
    private static func line(_ r: Item) -> String {
        let en = kinds.first { $0.id == r.kind }?.en ?? "Other"
        if r.kind == "commute" {
            return "- \(r.span) Commute from \(r.origin.isEmpty ? "?" : r.origin) to \(r.dest.isEmpty ? "?" : r.dest)"
                + (r.via.isEmpty ? "" : " by \(r.via)") + (r.mins > 0 ? ", about \(r.mins) min" : "")
        }
        return "- \(r.span) \(en): \(r.title)" + (r.place.isEmpty ? "" : " (\(r.place))") + (r.note.isEmpty ? "" : " \(r.note)")
    }

    /// 几天的日程写成几行文字。一条日程都没有返回空
    static func textFor(_ owner: String, back: Int, ahead: Int, settings s: AppSettings, at: Date = Date()) -> String {
        guard !list(owner).isEmpty else { return "" }
        let today = today(s, at: at).key
        return (-back...ahead).map { i -> String in
            let key = shiftKey(today, i)
            let rel = i == 0 ? "Today" : i == -1 ? "Yesterday" : i == 1 ? "Tomorrow" : i < 0 ? "\(-i) days ago" : "In \(i) days"
            let rows = itemsOn(owner, key)
            return "\(rel), \(key) \(weekdays[weekdayOfKey(key) - 1]):\n" + (rows.isEmpty ? "- (nothing scheduled)" : rows.map(line).joined(separator: "\n"))
        }.joined(separator: "\n")
    }

    /// 此刻那一句：正在做什么、接下来是什么
    static func nowText(_ owner: String, settings s: AppSettings, at: Date = Date()) -> String {
        let t = today(s, at: at)
        let m = minutes(t.time)
        let rows = itemsOn(owner, t.key)
        let cur = rows.filter { r in
            let a = minutes(r.start), e = r.end.isEmpty ? a : minutes(r.end)
            return a <= m && m < max(e, a + 1)
        }
        var parts: [String] = []
        if cur.isEmpty { parts.append("Nothing is scheduled at this moment (\(t.time)).") }
        else {
            parts.append("In progress now (\(t.time)): " + cur.map { r in
                "\(kinds.first { $0.id == r.kind }?.en ?? "Other") \(r.title) \(r.span)"
            }.joined(separator: "; ") + ".")
        }
        if let next = rows.first(where: { minutes($0.start) > m }) { parts.append("Next today: \(next.title) at \(next.start).") }
        return parts.joined(separator: " ")
    }

    /// [对方的日程] 区块。不给看的角色、这个身份没有日程时一个字都不写
    static func block(char: Character, personaId: String, userName: String, settings s: AppSettings, at: Date = Date()) -> String {
        guard visibleTo(char.id, s) else { return "" }
        let owner = ownerOf(personaId)
        let w = window(s)
        let days = textFor(owner, back: w.back, ahead: w.ahead, settings: s, at: at)
        guard !days.isEmpty else { return "" }
        let who = userName.isEmpty ? "The user" : userName
        return "[对方的日程]\n\(who)'s own schedule, in \(who)'s time zone.\n\(days)\n\(nowText(owner, settings: s, at: at))"
    }

    /// 排角色今天的日程时带上的那一段（开关 dayPlanUserSched，默认关）
    static func forDayPlan(_ char: Character, personaId: String, settings s: AppSettings) -> String {
        guard s.raw["dayPlanUserSched"]?.bool == true, visibleTo(char.id, s) else { return "" }
        let text = textFor(ownerOf(personaId), back: 0, ahead: 0, settings: s)
        return text.isEmpty ? "" : "The user's own schedule (user's time zone):\n\(text)"
    }

    // MARK: - 从文件或截图导入（网页版 ai/tasks/usersched.js）
    //
    // 一份来源只调一次接口，而且是你点了才调。文件先在本机读成文字，再交给副用接口整理；截图交给识图接口，一次读完、一次整理。
    // 整理出来的先放在确认页，你看过、点了存入才进库。

    /// 周几：数字 1 到 7（0 与 7 都算周日），或「周一」「星期三」「Mon」
    static func weekdayNum(_ v: JSONValue?) -> Int {
        if let n = v?.number { return (1...7).contains(Int(n)) ? Int(n) : Int(n) == 0 ? 7 : 0 }
        let s = (v?.string ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Int(s) { return (1...7).contains(n) ? n : n == 0 ? 7 : 0 }
        for pre in ["星期", "礼拜", "周"] where s.hasPrefix(pre) {
            if let c = s.dropFirst(pre.count).first, let i = Array("一二三四五六日天").firstIndex(of: c) { return min(i + 1, 7) }
        }
        return ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].firstIndex(of: String(s.prefix(3))).map { $0 + 1 } ?? 0
    }

    struct Draft: Identifiable, Equatable {
        let id = UUID()
        var raw: [String: JSONValue]
        var skip = false
        var ok: Bool { UserSched.normalize(raw) != nil }
        func s(_ k: String) -> String { raw[k]?.string ?? "" }
        var summary: String {
            guard ok else { return "信息不全：缺少开始时刻、周几或日期，不会存入" }
            let kind = UserSched.kinds.first { $0.id == s("kind") }?.label ?? ""
            let when = s("repeat") == UserSched.once ? s("date")
                : UserSched.weekdays[max(0, Int(raw["weekday"]?.number ?? 1) - 1)] + (s("weeks") == "odd" ? "（单周）" : s("weeks") == "even" ? "（双周）" : "")
            let span = s("end").isEmpty ? s("start") : "\(s("start"))-\(s("end"))"
            return [kind, when, span, s("place"), s("note")].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        static func == (a: Draft, b: Draft) -> Bool { a.id == b.id && a.skip == b.skip }
    }

    struct Pending { var items: [Draft]; var unclear: String; var from: String }

    /// 模型交回来的一条，整理成确认页上的一行
    static func draftOf(_ v: JSONValue) -> Draft {
        func str(_ k: String) -> String { (v[k]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let raw: [String: JSONValue] = [
            "kind": .string(["class", "work", "other"].contains(str("kind")) ? str("kind") : "class"),
            "repeat": .string(str("repeat") == once ? once : weekly),
            "weekday": .number(Double(weekdayNum(v["weekday"]))),
            "date": .string(str("date")), "start": .string(hm(str("start"))), "end": .string(hm(str("end"))),
            "title": .string(String(str("title").prefix(60))), "place": .string(String(str("place").prefix(60))),
            "note": .string(String(str("note").prefix(200))),
            "weeks": .string(["odd", "even"].contains(str("weeks")) ? str("weeks") : "all"),
            "from": .string(str("from")), "to": .string(str("to")),
        ]
        return Draft(raw: raw)
    }

    private static func prompt(_ source: String, settings s: AppSettings) -> String {
        let t = today(s, at: Date()).key
        return Templates.render("task.user-sched", ["today": t, "weekday": weekdays[max(0, weekdayOfKey(t) - 1)], "source": source], settings: s)
    }

    private static func shape(_ j: JSONValue, from: String) -> Pending {
        Pending(items: (j["items"]?.array ?? []).map(draftOf).filter { !$0.s("title").isEmpty },
                unclear: String((j["unclear"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)), from: from)
    }

    /// 读一份文件（xlsx、docx、txt、csv、md），整理成待确认的几行。调一次副用接口
    static func extract(file url: URL) async throws -> Pending {
        let text = try DocText.read(url)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError(message: "这份文件里没有读到文字") }
        let s = AppSettings.load()
        let r = try await AIService.shared.send(task: "usersched.import",
                                                system: prompt("## Source (read from \(url.lastPathComponent))\n\(text)", settings: s),
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")], maxTokens: 4000)
        guard let j = JSONReply.parse(r.text), j.object != nil else { throw StoreError(message: JSONReply.failure(r.text)) }
        return shape(j, from: url.lastPathComponent)
    }

    /// 识图能不能用：单独的识图接口，或者把图交给聊天模型
    static func visionReady(_ s: AppSettings = .load()) -> Bool { s.visionActive }

    /// 读一张截图。调一次识图接口（识图交给聊天模型时走聊天那一套）
    static func extract(image data: Data, mediaType: String) async throws -> Pending {
        let s = AppSettings.load()
        guard s.visionActive else { throw StoreError(message: "尚未配置识图接口，可在「设置 - 识图」中填写") }
        let image = AIImage(mediaType: mediaType, base64: data.base64EncodedString())
        let r = try await AIService.shared.send(task: "usersched.import", preset: s.visionMode == "api" ? s.visionPreset : nil,
                                                system: prompt("## Source\nThe attached image.", settings: s),
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.", images: [image])],
                                                maxTokens: 4000)
        guard let j = JSONReply.parse(r.text), j.object != nil else { throw StoreError(message: "识图接口返回的内容读不出来") }
        return shape(j, from: "截图")
    }

    /// 确认之后存进去。replace 为真先清掉这个身份原来导入的那些（手动加的留着）
    @discardableResult
    static func install(_ owner: String, _ drafts: [Draft], replace: Bool) throws -> Int {
        if replace { for r in list(owner) where r.row.string("source") == "import" { try remove(r.id) } }
        var n = 0
        for d in drafts where d.ok && !d.skip { try create(owner, d.raw, source: "import"); n += 1 }
        return n
    }
}
