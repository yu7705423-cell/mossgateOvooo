import Foundation

/// 日常（网页版 system/day.js、events.js、food.js、draw.js、ai/tasks/day.js、context/day.js）。
///
/// 「今天角色遇上了什么」分两半：日程是它自己安排的，由模型按人设生成（一天一次，char.dayOn 开着才有，默认关）；
/// 撞上的事、运势与三顿吃什么由本地骰子从库里抽，不调接口。
/// 日程在请求回复之前排：**先占住当天（Daily.claim）、先把今天这一行存下，再发请求**，失败当天不再自动排（网页版第 15 条）。
///
/// 原生版暂未做：天气、出行、我的日程（课表）、记账结算、自动回复、联网搜索真实的店。
enum DayPlan {
    struct Slot: Identifiable, Equatable {
        let id: String
        let label: String
        let from: Int
        let to: Int
    }

    static let slots: [Slot] = [
        Slot(id: "morning", label: "早上", from: 6, to: 11), Slot(id: "noon", label: "中午", from: 11, to: 14),
        Slot(id: "afternoon", label: "下午", from: 14, to: 18), Slot(id: "evening", label: "晚上", from: 18, to: 23),
        Slot(id: "night", label: "深夜", from: 23, to: 6),
    ]
    static func slotIndex(_ id: String) -> Int { slots.firstIndex { $0.id == id } ?? -1 }

    static let plan = "plan", done = "done", drop = "drop"
    static func stateLabel(_ s: String) -> String { s == done ? "已完成" : s == drop ? "已取消" : "计划中" }

    struct Meal { let id: String; let label: String; let slot: String }
    static let meals = [Meal(id: "breakfast", label: "早饭", slot: "morning"), Meal(id: "lunch", label: "午饭", slot: "noon"),
                        Meal(id: "dinner", label: "晚饭", slot: "evening")]

    struct Choice: Identifiable, Equatable { let id: String; let label: String; let hint: String; var weight = 1.0 }
    static let domains = [Choice(id: "env", label: "环境", hint: "天气、交通、住的地方、随身的东西、公共场所"),
                          Choice(id: "social", label: "人际", hint: "家人、朋友、同事、同学、陌生人、网上"),
                          Choice(id: "luck", label: "运气", hint: "捡到、丢了、抽中、错过、排队、巧合")]
    static let tones = [Choice(id: "good", label: "好事", hint: "让这一天变好一点的，不必是大喜事"),
                        Choice(id: "bad", label: "坏事", hint: "添堵的、麻烦的，但不要写成灾难"),
                        Choice(id: "plain", label: "不好不坏", hint: "只是发生了，谈不上好还是坏")]
    static let rarities = [Choice(id: "common", label: "平常", hint: "几乎每周都可能遇上", weight: 10),
                           Choice(id: "rare", label: "少见", hint: "一年碰不上几回，但也不是天方夜谭", weight: 1)]

    // MARK: - 时刻

    static func zone(_ char: Character?) -> TimeZone { Diary.zone(char) }

    static func hour(_ char: Character?, _ at: Date = Date()) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone(char)
        return cal.component(.hour, from: at)
    }

    static func slotNow(_ char: Character?, _ at: Date = Date()) -> Slot {
        let h = hour(char, at)
        return slots.first { s in s.from < s.to ? (h >= s.from && h < s.to) : (h >= s.from || h < s.to) } ?? slots[0]
    }

    /// 角色那边今天是几号：深夜（六点之前）算前一天。
    static func dateKey(_ char: Character?, _ at: Date = Date()) -> String { Diary.todayOf(char, at) }

    static func weekday(_ char: Character?, _ at: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone(char)
        let d = hour(char, at) < 6 ? at.addingTimeInterval(-86400) : at
        return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][cal.component(.weekday, from: d) - 1]
    }

    // MARK: - 骰子（网页版 draw.js）

    static func penalty(_ id: String, _ recent: [String], _ cooldown: Int) -> Double {
        guard cooldown > 0, let i = recent.firstIndex(of: id), i < cooldown else { return 1 }
        return Double(i + 1) / Double(cooldown + 1)
    }

    static func pick(_ rows: [Row], weight: (Row) -> Double, recent: [String] = [], cooldown: Int = 0,
                     rng: () -> Double = { Double.random(in: 0..<1) }) -> Row? {
        let ws = rows.map { max(0, weight($0)) * penalty($0.id, recent, cooldown) }
        let total = ws.reduce(0, +)
        guard total > 0 else { return nil }
        var r = rng() * total
        for (i, w) in ws.enumerated() where w > 0 {
            r -= w
            if r < 0 { return rows[i] }
        }
        return rows.indices.last { ws[$0] > 0 }.map { rows[$0] }
    }

    static func overdue(_ base: Double, _ days: Int, slope: Double = 0.35) -> Double {
        min(1, max(0, base * (1 + slope * Double(max(0, days - 1)))))
    }

    static func drift(_ cur: Double, rng: () -> Double = { Double.random(in: 0..<1) }) -> Double {
        let next = cur * 0.7 + (rng() * 2 - 1) * 1.2
        return max(-2, min(2, (next * 100).rounded() / 100))
    }

    static func luckLabel(_ v: Double) -> String {
        v >= 1.2 ? "顺" : v >= 0.4 ? "还行" : v > -0.4 ? "平" : v > -1.2 ? "不太顺" : "背"
    }

    // MARK: - 事件库

    static func events() throws -> [Row] { try Database.shared.all("events") }

    static func eventWeight(_ e: Row, luck: Double) -> Double {
        if e.bool("off") { return 0 }
        let rarity = rarities.first { $0.id == e.string("rarity") }?.weight ?? 10
        let v = max(-2, min(2, luck))
        let tone: Double
        switch e.string("tone") {
        case "good": tone = max(0.2, 1 + 0.3 * v)
        case "bad": tone = max(0.2, 1 - 0.3 * v)
        default: tone = 1
        }
        return rarity * (e.number("weight").map { $0 > 0 ? $0 : 1 } ?? 1) * tone
    }

    static func rollEvent(char: Character, daysSince: Int, recent: [String], settings s: AppSettings,
                          rng: () -> Double = { Double.random(in: 0..<1) }) throws -> Row? {
        if char.row["eventsOn"]?.bool == false { return nil }
        let luck = char.row.number("luck") ?? 0
        let base = s.raw["eventChance"]?.number ?? 0.35
        let chance = overdue(base * (1 + 0.15 * max(0, -luck)), daysSince)
        guard rng() < chance else { return nil }
        return pick(try events(), weight: { eventWeight($0, luck: luck) }, recent: recent,
                    cooldown: Int(s.raw["eventCooldown"]?.number ?? 12), rng: rng)
    }

    @discardableResult
    static func addEvent(domain: String, tone: String, rarity: String, text: String, weight: Double = 1) throws -> Row {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !t.isEmpty else { throw StoreError(message: "请填写事件") }
        let row = Row.new(prefix: "ev", ["domain": .string(domain), "tone": .string(tone), "rarity": .string(rarity),
                                          "cell": .string("\(domain):\(tone)"), "text": .string(t),
                                          "weight": .number(max(1, weight)), "off": .bool(false)])
        try Database.shared.put("events", row)
        return row
    }

    // MARK: - 吃什么

    static func region(_ char: Character?) -> String {
        String((char?.row.string("region") ?? "").trimmingCharacters(in: .whitespaces).prefix(20))
    }

    static func recipes(region: String) throws -> [Row] { try Database.shared.all("recipes", where: region) }

    /// 有地区就是那个地区的加上不分地区的，没有就只有不分地区的。
    static func mealPool(_ char: Character, meal: String) throws -> [Row] {
        let r = region(char)
        let all = (r.isEmpty ? [] : try recipes(region: r)) + (try recipes(region: ""))
        return all.filter { !$0.bool("off") && ($0.string("meal").isEmpty || $0.string("meal") == meal) }
    }

    /// 抽一顿并记进这个角色的吃饭记录。库里没有就是没有，不编一顿出来。
    static func eat(_ char: Character, meal: String, settings s: AppSettings, rng: () -> Double) throws -> Row? {
        let history = try Database.shared.all("meals", where: char.id).sorted { ($0.number("at") ?? 0) > ($1.number("at") ?? 0) }
        guard let r = pick(try mealPool(char, meal: meal), weight: { $0.number("weight") ?? 1 },
                           recent: history.map { $0.string("recipeId") }, cooldown: Int(s.raw["mealCooldown"]?.number ?? 8), rng: rng) else { return nil }
        try Database.shared.put("meals", Row.new(prefix: "ml", [
            "charId": .string(char.id), "meal": .string(meal), "recipeId": .string(r.id), "name": .string(r.string("name")),
            "place": .string(r.string("place")), "price": .number(r.number("price") ?? 0), "at": .number(Date().millis),
        ]))
        return r
    }

    static func mealText(_ m: JSONValue) -> String {
        let label = meals.first { $0.id == m["meal"]?.string }?.label ?? "This meal"
        let name = m["name"]?.string ?? "", place = m["place"]?.string ?? ""
        return place.isEmpty ? "\(label): \(name)" : "\(label): \(name)（\(place)）"
    }

    // MARK: - 当天

    static func isOn(_ char: Character?) -> Bool { char?.row["dayOn"]?.bool == true }

    static func day(_ charId: String, date: String) throws -> Row? {
        try Database.shared.all("days", where: charId).last { $0.string("date") == date }
    }

    static func today(_ char: Character) throws -> Row? { try day(char.id, date: dateKey(char)) }

    static func recent(_ charId: String, _ n: Int) throws -> [Row] {
        Array(try Database.shared.all("days", where: charId).sorted { $0.string("date") > $1.string("date") }.prefix(n))
    }

    /// 存当天这一行。同一天已经有了就整行换掉。
    @discardableResult
    static func save(_ charId: String, date: String, _ fields: [String: JSONValue]) throws -> Row {
        var row: Row
        if let old = try day(charId, date: date) {
            row = old
            for (k, v) in fields { row[k] = v }
            row.touch()
        } else {
            var all = fields
            all["charId"] = .string(charId)
            all["date"] = .string(date)
            row = Row.new(prefix: "day", all)
        }
        try Database.shared.put("days", row)
        return row
    }

    /// 本地掷：运势挪一步、撞没撞上事、三顿吃什么。不调接口。
    static func rollLocal(_ char: Character, date: String, settings s: AppSettings,
                          rng: () -> Double = { Double.random(in: 0..<1) }) throws -> [String: JSONValue] {
        let luck = drift(char.row.number("luck") ?? 0, rng: rng)
        try Diary.patchChar(char.id, ["luck": .number(luck), "luckAt": .number(Date().millis)])
        var fresh = char
        fresh.row["luck"] = .number(luck)
        let past = try recent(char.id, 30)
        var gap = 1
        if let last = past.first(where: { $0.string("date") != date }), let a = dayDate(last.string("date")), let b = dayDate(date) {
            gap = max(1, Int((b.timeIntervalSince(a) / 86400).rounded()))
        }
        var event: JSONValue = .null
        if let hit = try rollEvent(char: fresh, daysSince: gap, recent: past.compactMap { $0["event"]?["eventId"]?.string },
                                   settings: s, rng: rng) {
            let pool = slots.filter { $0.id != "night" }
            event = .object(["eventId": .string(hit.id), "text": .string(hit.string("text")), "tone": .string(hit.string("tone")),
                             "domain": .string(hit.string("domain")), "slot": .string(pool[min(pool.count - 1, Int(rng() * Double(pool.count)))].id)])
        }
        var mealRows: [JSONValue] = []
        for m in meals {
            if let r = try eat(fresh, meal: m.id, settings: s, rng: rng) {
                mealRows.append(.object(["meal": .string(m.id), "name": .string(r.string("name")),
                                         "place": .string(r.string("place")), "recipeId": .string(r.id)]))
            }
        }
        return ["luck": .number(luck), "event": event, "meals": .array(mealRows)]
    }

    private static func dayDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    // MARK: - 日程（模型）

    /// 交给模型的「现在是什么情况」：剧情摘要、最近的记忆、最近的对话。
    static func situation(_ char: Character, settings s: AppSettings) throws -> String {
        var parts: [String] = []
        let chat = Diary.chatWith(char.id)
        if let chat, !chat.summary.isEmpty { parts.append("Story so far:\n" + String(chat.summary.prefix(1500))) }
        let mems = try Repo.memories(charId: char.id).sorted { ($0.row.number("createdAt") ?? 0) > ($1.row.number("createdAt") ?? 0) }
            .filter { $0.row["supersededBy"] == nil || $0.row["supersededBy"]?.isNull == true }.prefix(8)
        if !mems.isEmpty { parts.append("Recent memories:\n" + mems.map { "- " + String($0.content.prefix(160)) }.joined(separator: "\n")) }
        if let chat {
            let n = Int(s.raw["dayPlanRecent"]?.number ?? 12)
            let msgs = try Repo.messages(chatId: chat.id).filter { !$0.isError && !$0.content.isEmpty }
            let rows = n > 0 ? Array(msgs.suffix(n)) : msgs
            let me = (try? Repo.activePersona())?.name ?? "User"
            if !rows.isEmpty {
                parts.append("Most recent conversation (oldest first):\n" + rows.map {
                    "\($0.role == .user ? me : char.name): \(String($0.content.prefix(200)))"
                }.joined(separator: "\n"))
            }
        }
        // 你今天的日程（网页版 4.321）：开关在「我的日程」页，默认关；不给这个角色看的不带
        let mine = UserSched.forDayPlan(char, personaId: chat?.personaId ?? "", settings: s)
        if !mine.isEmpty { parts.append(mine) }
        return parts.isEmpty ? "" : "## Where things stand\n" + parts.joined(separator: "\n\n")
    }

    /// 排今天的日程（一次请求）。返回事项与睡着时的自动回复。
    static func generatePlan(_ char: Character, date: String, settings s: AppSettings,
                             weather: Weather.Forecast? = nil) async throws -> (items: [JSONValue], sleep: String) {
        let system = Templates.render("task.day-plan", [
            "charName": char.name.isEmpty ? "该角色" : char.name,
            "charPersona": char.persona.isEmpty ? "(no character card was written)" : char.persona,
            "date": date, "weekday": weekday(char), "zone": zone(char).identifier,
            "weather": weather.map { "## Weather\n" + Weather.promptLine($0) } ?? "", "constraints": "", "situation": try situation(char, settings: s),
            "slots": slots.map { "\($0.id) = \($0.label) (\($0.from):00 to \($0.to):00)" }.joined(separator: "\n"),
        ], settings: s)
        let r = try await AIService.shared.send(task: "day.plan", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: 1200, retries: 1)
        guard let j = JSONReply.parse(r.text), j.object != nil else { throw StoreError(message: JSONReply.failure(r.text)) }
        var items: [JSONValue] = []
        for it in j["items"]?.array ?? [] {
            let slot = it["slot"]?.string ?? "", text = (it["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard slotIndex(slot) >= 0, !text.isEmpty else { continue }
            items.append(.object(["id": .string(Ids.make("it")), "slot": .string(slot), "text": .string(String(text.prefix(60))),
                                  "kind": .string("plan"), "state": .string(plan), "cost": .number(max(0, it["cost"]?.number ?? 0)),
                                  "auto": .string(String((it["auto"]?.string ?? "").prefix(80)))]))
        }
        items.sort { slotIndex($0["slot"]?.string ?? "") < slotIndex($1["slot"]?.string ?? "") }
        return (items, String((j["sleep"]?.string ?? "").prefix(80)))
    }

    /// 安排今天：本地掷完先存下这一行，再请模型排日程。force 为真是你点的「重新安排」，全部重掷。
    @discardableResult
    static func makeToday(_ charId: String, force: Bool = false) async throws -> Row {
        guard let char = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        guard isOn(char) else { throw StoreError(message: "这个角色没有开启当日日程") }
        let date = dateKey(char)
        if !force, let d = try day(charId, date: date) { return d }
        let s = AppSettings.load()
        var local = try rollLocal(char, date: date, settings: s)
        local["items"] = .array([])
        local["planFailed"] = .string("")
        // 和风天气：配了、填了所在地区才查；查不到是 nil，不拦着日程。不调模型接口
        let w = await Weather.forChar(char, date: date)
        local["weather"] = w?.json ?? .null
        try save(charId, date: date, local)
        do {
            let p = try await generatePlan(try Repo.character(charId) ?? char, date: date, settings: s, weather: w)
            return try save(charId, date: date, ["items": .array(p.items), "sleepAuto": .string(p.sleep), "planFailed": .string("")])
        } catch {
            try? save(charId, date: date, ["planFailed": .string(error.localizedDescription)])
            throw error
        }
    }

    /// 只重查今天的天气，不重排日程（「日常 - 今天」那一行上的刷新）。不调模型接口
    @discardableResult
    static func refreshWeather(_ charId: String) async throws -> Weather.Forecast {
        guard let char = try Repo.character(charId), let d = try today(char) else { throw StoreError(message: "今天还没有安排") }
        let w = try await Weather.forecast(region(char), date: d.string("date"))
        try save(charId, date: d.string("date"), ["weather": w.json])
        return w
    }

    /// 请求回复之前调：开着、今天还没有这一行、今天还没自动试过才排。失败也算试过，当天不再自动排。
    @discardableResult
    static func ensureToday(_ charId: String) async -> Bool {
        guard let char = try? Repo.character(charId), isOn(char) else { return false }
        if (try? today(char)) != nil { return false }
        guard Daily.claim("day", charId, dateKey(char)) else { return false }
        do { try await makeToday(charId) }
        catch { Diagnostics.shared.record("day-plan-failed", ["error": error.localizedDescription]) }
        return true
    }

    /// 改一条事项的状态。
    static func setState(_ charId: String, date: String, itemId: String, _ state: String) throws {
        guard let d = try day(charId, date: date) else { return }
        let items = (d["items"]?.array ?? []).map { it -> JSONValue in
            guard var o = it.object, o["id"]?.string == itemId else { return it }
            o["state"] = .string(state)
            return .object(o)
        }
        try save(charId, date: date, ["items": .array(items)])
    }

    /// 角色在回复里写的 [事项完成：…] / [事项取消：…]：按字面找今天还在计划中的那一条（从后往前），找不到不改。
    @discardableResult
    static func mark(_ char: Character, title: String, done isDone: Bool) throws -> Bool {
        guard let d = try today(char) else { return false }
        let q = title.filter { !$0.isWhitespace }
        guard !q.isEmpty else { return false }
        for it in (d["items"]?.array ?? []).reversed() where it["state"]?.string == plan {
            let t = (it["text"]?.string ?? "").filter { !$0.isWhitespace }
            if !t.isEmpty && (t.contains(q) || q.contains(t)), let id = it["id"]?.string {
                try setState(char.id, date: d.string("date"), itemId: id, isDone ? done : drop)
                return true
            }
        }
        return false
    }

    // MARK: - 进聊天提示词（网页版 context/day.js 的 [你今天]）

    struct Brief {
        var date: String
        var slot: Slot
        var summary: [String]
        var nowItems: [String]
        var meal: String
        var event: JSONValue?
        var luck: Double
        var doneCount: Int
        var total: Int
    }

    static func brief(_ char: Character, at: Date = Date()) -> Brief? {
        guard isOn(char), let d = try? day(char.id, date: dateKey(char, at)) else { return nil }
        let cur = slotNow(char, at)
        let items = d["items"]?.array ?? []
        let summary = slots.compactMap { s -> String? in
            let list = items.filter { $0["slot"]?.string == s.id && $0["state"]?.string != drop }
            guard !list.isEmpty else { return nil }
            return "\(s.label): " + list.map { ($0["text"]?.string ?? "") + ($0["state"]?.string == done ? "（已完成）" : "") }.joined(separator: "；")
        }
        let nowItems = items.filter { $0["slot"]?.string == cur.id && $0["state"]?.string == plan }.compactMap { $0["text"]?.string }
        let mealId = meals.first { $0.slot == cur.id }?.id
        let meal = (d["meals"]?.array ?? []).first { $0["meal"]?.string == mealId }.map(mealText) ?? ""
        var event: JSONValue?
        if let ev = d["event"], ev.object != nil {
            let i = slotIndex(ev["slot"]?.string ?? "")
            if i >= 0 && i <= slotIndex(cur.id) { event = ev }
        }
        return Brief(date: d.string("date"), slot: cur, summary: summary, nowItems: nowItems, meal: meal, event: event,
                     luck: d.number("luck") ?? 0, doneCount: items.filter { $0["state"]?.string == done }.count, total: items.count)
    }

    static func block(_ char: Character, at: Date = Date()) -> String {
        guard let b = brief(char, at: at) else { return "" }
        var lines = ["Today is \(b.date). In your time zone it is currently \(b.slot.label)."]
        // 当天的天气预报（排日程时一起查的）。是预报，不是此刻的实况
        if let d = try? day(char.id, date: b.date), let w = Weather.Forecast(d["weather"]) { lines.append(Weather.promptLine(w)) }
        lines += b.summary
        var now: [String] = []
        if !b.nowItems.isEmpty { now.append("Planned for the current slot: \(b.nowItems.joined(separator: "；"))。") }
        if !b.meal.isEmpty { now.append(b.meal + "。") }
        if let ev = b.event {
            now.append("One other thing happened today: \(ev["text"]?.string ?? "")。")
            switch ev["tone"]?.string {
            case "good": now.append("It left you pleased.")
            case "bad": now.append("It left you out of sorts.")
            default: break
            }
        }
        if !now.isEmpty { lines += [""] + now }
        let l = b.luck
        let luck = l >= 1.2 ? "You have been in good form lately, and fairly even-tempered."
            : l >= 0.4 ? "You have been in reasonable form lately."
            : l > -0.4 ? ""
            : l > -1.2 ? "You have been in poor form lately, with less patience than usual."
            : "You have been in poor form for a while, and are more easily irritated than usual."
        if !luck.isEmpty { lines.append(luck) }
        lines += ["", "For slots that have not yet arrived, you know what you intend to do, not how it turned out."]
        return "[你今天]\n" + lines.joined(separator: "\n")
    }

    // MARK: - 批量生成（你点的）

    /// 给一格生成几条事件，先交回来给你过目，确认之后才入库（一格一次请求）。
    static func generateEvents(domain: String, tone: String, rarity: String, count: Int) async throws -> [String] {
        let s = AppSettings.load()
        let cell = try events().filter { $0.string("cell") == "\(domain):\(tone)" }
        let keep = Int(s.raw["eventDedupeList"]?.number ?? 0)
        let existing = (keep > 0 ? Array(cell.suffix(keep)) : cell).map { "- " + $0.string("text") }
        let d = domains.first { $0.id == domain }, t = tones.first { $0.id == tone }, r = rarities.first { $0.id == rarity }
        let system = Templates.render("task.event-batch", [
            "domain": d?.label ?? domain, "domainHint": d?.hint ?? "", "tone": t?.label ?? tone, "toneHint": t?.hint ?? "",
            "rarity": r?.label ?? rarity, "rarityHint": r?.hint ?? "", "count": String(count),
            "existing": existing.isEmpty ? "(this category is still empty)" : existing.joined(separator: "\n"),
        ], settings: s)
        let res = try await AIService.shared.send(task: "event.batch", system: system,
                                                  messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                  maxTokens: 400 + count * 60, retries: 1)
        guard let j = JSONReply.parse(res.text) else { throw StoreError(message: JSONReply.failure(res.text)) }
        var seen = Set(cell.map { norm($0.string("text")) })
        var out: [String] = []
        for e in j["events"]?.array ?? [] {
            let text = String((e["text"]?.string ?? e.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            let k = norm(text)
            if text.isEmpty || seen.contains(k) { continue }
            seen.insert(k)
            out.append(text)
        }
        return out
    }

    /// 给一个地区生成几道日常吃的，直接入库（一次请求）。
    @discardableResult
    static func generateRecipes(region: String, meal: String, count: Int) async throws -> Int {
        let s = AppSettings.load()
        let existing = try recipes(region: region)
        let system = Templates.render("task.recipe-batch", [
            "regionLine": region.isEmpty ? "不限地区，写哪儿都吃得到的那些" : "地区：\(region)",
            "meal": meals.first { $0.id == meal }?.label ?? "不限", "count": String(count),
            "existing": existing.isEmpty ? "（这一批还是空的）" : existing.map { "- " + $0.string("name") }.joined(separator: "\n"),
        ], settings: s)
        let res = try await AIService.shared.send(task: "recipe.batch", system: system,
                                                  messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                  maxTokens: 400 + count * 60, retries: 1)
        guard let j = JSONReply.parse(res.text) else { throw StoreError(message: JSONReply.failure(res.text)) }
        var seen = Set(existing.map { norm($0.string("name")) })
        var n = 0
        for d in j["dishes"]?.array ?? [] {
            let name = String((d["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            let k = norm(name)
            if name.isEmpty || seen.contains(k) { continue }
            seen.insert(k)
            try Database.shared.put("recipes", Row.new(prefix: "rc", [
                "region": .string(region), "name": .string(name), "meal": .string(meal),
                "note": .string(String((d["note"]?.string ?? "").prefix(60))), "place": .string(""),
                "price": .number(((d["price"]?.number ?? 0) * 100).rounded() / 100), "off": .bool(false),
            ]))
            n += 1
        }
        return n
    }

    static func norm(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
