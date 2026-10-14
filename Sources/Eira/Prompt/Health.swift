import Foundation

/// 健康（网页版 system/health.js）。**这是一本记录，不是一个会看病的东西**：全程不调接口，不评估、不建议。
///
/// 数据域 health，按 who 查（me 或角色 id），每人每天一行：
///     sleepMin, sleepAt, steps, weight（公斤）, water, poops: [{ at, form }], mood, energy, symptoms, note, took（今天吃过的药）
/// 经期 cycles { start, end, note }，用药 meds { name, dose, times, note, active }。
/// 上下文区块 health 只写事实：你的那一份要「设置」里 healthInject 开着（默认关），排便、经期各另有一道开关；
/// 角色那一份跟着角色身上的 healthOn。角色身体状态的自动生成（每天一次，会多调接口）原生版暂未提供，可以手填。
enum Health {
    static let collection = "health", cycles = "cycles", meds = "meds"
    static let me = "me"

    static let moods: [(id: String, label: String)] = [("good", "不错"), ("flat", "一般"), ("low", "低落"), ("tense", "烦躁")]
    static let energy: [(id: String, label: String)] = [("high", "精神"), ("mid", "还行"), ("low", "疲惫")]
    static let symptoms: [(id: String, label: String)] = [("headache", "头痛"), ("stomach", "胃不舒服"), ("cold", "感冒"), ("fever", "发热"),
        ("throat", "嗓子疼"), ("cramp", "腹痛"), ("back", "腰背酸"), ("sleepy", "困倦"), ("dizzy", "头晕")]
    /// 布里斯托七档，只描述外观，不下结论
    static let poopForms: [(id: String, label: String)] = [("b1", "一颗颗硬球"), ("b2", "块状凹凸"), ("b3", "表面有裂痕"),
        ("b4", "表面光滑"), ("b5", "软块"), ("b6", "糊状"), ("b7", "水样")]

    static func label(_ list: [(id: String, label: String)], _ id: String) -> String { list.first(where: { $0.id == id })?.label ?? "" }

    static func dateKey(_ d: Date = Clock.now(AppSettings.load())) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func date(of key: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    static func daysBetween(_ a: String, _ b: String) -> Int {
        guard let x = date(of: a), let y = date(of: b) else { return 0 }
        return Calendar.current.dateComponents([.day], from: x, to: y).day ?? 0
    }

    static func shift(_ key: String, _ days: Int) -> String {
        guard let d = date(of: key), let n = Calendar.current.date(byAdding: .day, value: days, to: d) else { return key }
        return dateKey(n)
    }

    // MARK: - 每天一行

    struct Day: Equatable {
        var row: Row?
        var who: String
        var date: String
        func n(_ k: String) -> Double { row?.number(k) ?? 0 }
        func s(_ k: String) -> String { row?.string(k) ?? "" }
        var sleepMin: Double { n("sleepMin") }
        var steps: Double { n("steps") }
        var weight: Double { n("weight") }
        var water: Double { n("water") }
        var mood: String { s("mood") }
        var energy: String { s("energy") }
        var note: String { s("note") }
        var sleepAt: String { s("sleepAt") }
        var symptoms: [String] { row?.strings("symptoms") ?? [] }
        var took: [String] { row?.strings("took") ?? [] }
        /// 排便：一次一条。旧行的「几次 + 一个形态」读的时候摊开（网页版 withPoops）
        var poops: [(at: String, form: String)] {
            if let list = row?["poops"]?.array {
                return list.map { ($0["at"]?.string ?? "", $0["form"]?.string ?? "") }
            }
            let n = max(0, Int((row?.number("poop") ?? 0).rounded()))
            return (0..<n).map { i in ("", i == 0 ? (row?.string("poopForm") ?? "") : "") }
        }
        var filled: Bool { !energy.isEmpty || !mood.isEmpty || !symptoms.isEmpty || sleepMin > 0 || !poops.isEmpty || !note.isEmpty }
    }

    static func day(_ who: String, _ date: String = dateKey()) -> Day {
        let row = ((try? Database.shared.all(collection, where: who)) ?? []).first { $0.string("date") == date }
        return Day(row: row, who: who, date: date)
    }

    static func set(_ who: String, _ date: String, _ patch: [String: JSONValue]) throws {
        var r = day(who, date).row ?? Row.new(prefix: "hl", [
            "who": .string(who), "date": .string(date), "sleepMin": .number(0), "sleepAt": .string(""), "steps": .number(0),
            "weight": .number(0), "water": .number(0), "poops": .array([]), "mood": .string(""), "energy": .string(""),
            "symptoms": .array([]), "note": .string(""), "took": .array([]), "source": .string("manual"),
        ])
        if r["poops"]?.array == nil {
            r["poops"] = .array(day(who, date).poops.map { .object(["at": .string($0.at), "form": .string($0.form)]) })
        }
        for (k, v) in patch { r[k] = v }
        r.touch()
        try Database.shared.put(collection, r)
    }

    /// 最近 n 天，新的在前；空着的日子不补
    static func recent(_ who: String = me, _ n: Int = 30) -> [Day] {
        ((try? Database.shared.all(collection, where: who)) ?? [])
            .sorted { $0.string("date") > $1.string("date") }.prefix(n)
            .map { Day(row: $0, who: who, date: $0.string("date")) }
    }

    static func addWater(_ who: String = me, _ n: Int = 1) throws {
        let d = day(who)
        try set(who, d.date, ["water": .number(max(0, d.water + Double(n)))])
    }

    static func toggleSymptom(_ who: String, _ date: String, _ id: String) throws {
        var list = day(who, date).symptoms
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
        try set(who, date, ["symptoms": .array(list.map { .string($0) })])
    }

    private static func writePoops(_ who: String, _ date: String, _ list: [(at: String, form: String)]) throws {
        try set(who, date, ["poops": .array(list.map { .object(["at": .string($0.at), "form": .string($0.form)]) })])
    }

    static func hhmm(_ d: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func addPoop(_ who: String, _ date: String) throws { try writePoops(who, date, day(who, date).poops + [(hhmm(), "")]) }

    static func updatePoop(_ who: String, _ date: String, _ i: Int, at: String? = nil, form: String? = nil) throws {
        var list = day(who, date).poops
        guard list.indices.contains(i) else { return }
        if let at { list[i].at = String(at.filter { $0.isNumber || $0 == ":" }.prefix(5)) }
        if let form { list[i].form = form }
        try writePoops(who, date, list)
    }

    static func removePoop(_ who: String, _ date: String, _ i: Int) throws {
        var list = day(who, date).poops
        guard list.indices.contains(i) else { return }
        list.remove(at: i)
        try writePoops(who, date, list)
    }

    /// 正规成 HH:MM；拼不成的当没填
    static func poopTime(_ at: String) -> String {
        let p = at.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), p[1].count == 2, h < 24, m < 60 else { return "" }
        return String(format: "%02d:%02d", h, m)
    }

    // MARK: - 体重与睡眠

    static func unit(_ s: AppSettings = .load()) -> String { s.raw["weightUnit"]?.string == "lb" ? "lb" : "kg" }
    static func toDisplay(_ kg: Double, _ s: AppSettings = .load()) -> Double {
        unit(s) == "lb" ? (kg * 2.2046226 * 10).rounded() / 10 : (kg * 10).rounded() / 10
    }
    static func fromDisplay(_ v: Double, _ s: AppSettings = .load()) -> Double {
        unit(s) == "lb" ? (v / 2.2046226 * 100).rounded() / 100 : v
    }

    static func fmtSleep(_ min: Double) -> String {
        let m = max(0, Int(min.rounded()))
        guard m > 0 else { return "" }
        return m >= 60 ? "\(m / 60) 小时" + (m % 60 > 0 ? " \(m % 60) 分" : "") : "\(m) 分钟"
    }

    // MARK: - 经期（对你自己记录的算术，不是医学判断）

    static func listCycles() -> [Row] {
        ((try? Database.shared.all(cycles)) ?? []).sorted { $0.string("start") > $1.string("start") }
    }

    static func startCycle(_ date: String = dateKey()) throws {
        try Database.shared.put(cycles, Row.new(prefix: "cy", ["start": .string(date), "end": .string(""), "note": .string("")]))
    }

    static func endCycle(_ id: String, _ date: String = dateKey()) throws {
        guard var r = try Database.shared.get(cycles, id: id) else { return }
        r["end"] = .string(date)
        r.touch()
        try Database.shared.put(cycles, r)
    }

    static func removeCycle(_ id: String) throws { try Database.shared.delete(cycles, id: id) }

    static func openCycle() -> Row? { listCycles().first { !$0.string("start").isEmpty && $0.string("end").isEmpty } }

    /// 至少两次才有间隔可算；只取最近六次；离谱的间隔不参与平均
    static func predictCycle() -> (avg: Int, samples: Int, next: String)? {
        let list = listCycles().filter { !$0.string("start").isEmpty }
        guard list.count >= 2 else { return nil }
        var gaps: [Int] = []
        var i = 0
        while i < list.count - 1 && gaps.count < 6 {
            let g = daysBetween(list[i + 1].string("start"), list[i].string("start"))
            if g > 10 && g < 90 { gaps.append(g) }
            i += 1
        }
        guard !gaps.isEmpty else { return nil }
        let avg = Int((Double(gaps.reduce(0, +)) / Double(gaps.count)).rounded())
        return (avg, gaps.count, shift(list[0].string("start"), avg))
    }

    // MARK: - 用药（只记，不给任何用药建议）

    static func listMeds() -> [Row] {
        ((try? Database.shared.all(meds)) ?? []).sorted { $0.string("name").localizedStandardCompare($1.string("name")) == .orderedAscending }
    }

    static func activeMeds() -> [Row] { listMeds().filter { $0["active"]?.bool != false } }

    static func saveMed(id: String?, name: String, dose: String, times: [String], note: String, active: Bool) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw StoreError(message: "请填写名称") }
        var r = (id.flatMap { try? Database.shared.get(meds, id: $0) }) ?? Row.new(prefix: "md")
        r["name"] = .string(String(n.prefix(40)))
        r["dose"] = .string(String(dose.prefix(40)))
        r["times"] = .array(Array(Set(times)).sorted().map { .string($0) })
        r["note"] = .string(String(note.prefix(200)))
        r["active"] = .bool(active)
        r.touch()
        try Database.shared.put(meds, r)
    }

    static func removeMed(_ id: String) throws { try Database.shared.delete(meds, id: id) }

    static func takeMed(_ id: String, _ date: String = dateKey()) throws {
        var took = day(me, date).took
        if let i = took.firstIndex(of: id) { took.remove(at: i) } else { took.append(id) }
        try set(me, date, ["took": .array(took.map { .string($0) })])
    }

    // MARK: - 角色那一份（设定出来的，不是测出来的）

    static func charOn(_ char: Character?) -> Bool { char?.row["healthOn"]?.bool == true }

    static func setCharOn(_ charId: String, _ on: Bool) throws {
        guard var c = try Repo.character(charId) else { return }
        c.row["healthOn"] = .bool(on)
        c.row.touch()
        try Database.shared.put(Collections.characters, c.row)
    }

    // MARK: - 上下文（网页版 context/health.js）

    private static func poopLines(_ d: Day) -> [String] {
        let list = d.poops
        guard !list.isEmpty else { return [] }
        let bits = list.map { e -> String in
            let at = poopTime(e.at), form = label(poopForms, e.form)
            if !at.isEmpty && !form.isEmpty { return "\(at) (\(form))" }
            if !at.isEmpty { return at }
            if !form.isEmpty { return "time not recorded (\(form))" }
            return "time not recorded"
        }
        return ["Bowel movements today: \(list.count) — \(bits.joined(separator: "; "))."]
    }

    static func block(char: Character?, userName: String, settings s: AppSettings) -> String {
        var a: [String] = []
        if s.raw["healthInject"]?.bool == true {
            let d = day(me)
            if d.sleepMin > 0 { a.append("Slept \(fmtSleep(d.sleepMin))" + (d.sleepAt.isEmpty ? "." : ", went to bed at \(d.sleepAt).")) }
            if d.steps > 0 { a.append("Walked \(Int(d.steps)) steps.") }
            if d.weight > 0 { a.append("Weight \(toDisplay(d.weight, s)) \(unit(s)).") }
            if d.water > 0 { a.append("Drank \(Int(d.water)) glasses of water.") }
            if !d.mood.isEmpty { a.append("Mood: \(label(moods, d.mood)).") }
            if !d.energy.isEmpty { a.append("Energy: \(label(energy, d.energy)).") }
            if !d.symptoms.isEmpty { a.append("Unwell: \(d.symptoms.map { label(symptoms, $0) }.filter { !$0.isEmpty }.joined(separator: "、")).") }
            if !d.note.isEmpty { a.append("Also noted: \(d.note)") }
            if s.raw["healthPoopInject"]?.bool == true { a += poopLines(d) }
            if s.raw["healthCycleInject"]?.bool == true {
                if let open = openCycle() {
                    a.append("Currently on day \(daysBetween(open.string("start"), dateKey()) + 1) of their period.")
                } else if let p = predictCycle() {
                    a.append("Next period estimated around \(p.next), from their own records.")
                }
            }
            if !a.isEmpty { a.insert("## \(userName.isEmpty ? "They" : userName) today", at: 0) }
        }
        var b: [String] = []
        if let char, charOn(char) {
            let d = day(char.id)
            if !d.energy.isEmpty { b.append("Energy: \(label(energy, d.energy)).") }
            if !d.mood.isEmpty { b.append("Mood: \(label(moods, d.mood)).") }
            if !d.symptoms.isEmpty { b.append("Unwell: \(d.symptoms.map { label(symptoms, $0) }.filter { !$0.isEmpty }.joined(separator: "、")).") }
            if d.sleepMin > 0 { b.append("Slept \(fmtSleep(d.sleepMin)).") }
            b += poopLines(d)
            if !d.note.isEmpty { b.append("Also: \(d.note)") }
            if !b.isEmpty { b.insert("## Your own body today", at: 0) }
        }
        guard !a.isEmpty || !b.isEmpty else { return "" }
        return "\n\n" + (a + b + ["These are recorded figures. Do not invent them and do not change them."]).joined(separator: "\n")
    }

    /// 状态栏「身体状况」那一栏：角色今天的几项，读记录，不让模型写
    static func statusText(_ char: Character?) -> String {
        guard let char else { return "" }
        let d = day(char.id)
        return [label(energy, d.energy), label(moods, d.mood), d.symptoms.map { label(symptoms, $0) }.joined(separator: "、")]
            .filter { !$0.isEmpty }.joined(separator: "，")
    }
}
