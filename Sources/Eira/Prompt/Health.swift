import Foundation
import HealthKit
import UserNotifications

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

    /// 从「健康」读来的一次经期（网页版 health.importCycle）：前后三天内已有一次的，手填优先、一律不动，
    /// 只在那一次本来就是同步来的、记了开始没记结束时补上结束日期。返回新建的那一行
    @discardableResult
    static func importCycle(start: String, end: String = "", source: String = "healthkit") throws -> Row? {
        guard start.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        if var near = listCycles().first(where: { !$0.string("start").isEmpty && abs(daysBetween($0.string("start"), start)) <= 3 }) {
            let src = near.string("source")
            if near.string("end").isEmpty, !end.isEmpty, end >= near.string("start"), !src.isEmpty, src != "manual" {
                near["end"] = .string(end)
                near.touch()
                try Database.shared.put(cycles, near)
            }
            return nil
        }
        let row = Row.new(prefix: "cy", ["start": .string(start), "end": .string(!end.isEmpty && end >= start ? end : ""),
                                         "note": .string(""), "source": .string(source)])
        try Database.shared.put(cycles, row)
        return row
    }

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

// MARK: - 用药提醒交给系统（网页版 system/medremind.js，ARCHITECTURE 4.482）
//
// 把接下来几天的每一次算出来，排成系统的定时本地通知（UNCalendarNotificationTrigger），应用关着也按时提醒。
// 每次交的是全部：先撤掉「med-」开头的那一组再排。系统对一只 app 挂着的定时通知有上限（64 条），
// 所以按每天几次算能排几天（60 除以每天次数），最多 14 天；打开应用、回到前台、加改删药、记下吃过、开关总开关时重排。
// 今天已经记下吃过的，今天剩下的那几次不排；过了点的不排；停用的不排。只在本机，不调接口、不上传。
@MainActor
enum MedRemind {
    nonisolated static let days = 14
    nonisolated static let cap = 60
    nonisolated static let prefix = "med-"

    struct Slot: Equatable {
        var id: String
        var at: Date
        var title: String
        var body: String
    }

    /// 交给系统的情况，界面读它。permission 为真是没允许通知
    struct PlanState: Equatable {
        var ok = false
        var off = false
        var n = 0
        var until: Date?
        var error = ""
        var permission = false
        var at = Date()
    }

    static private(set) var state: PlanState?
    private static var soon: Task<Void, Never>?

    /// 总开关（settings.medRemind），默认开
    nonisolated static func on(_ s: AppSettings = .load()) -> Bool { s.raw["medRemind"]?.bool != false }

    /// 接下来要交给系统的每一次。纯计算，测试直接调。took 是今天已经记下吃过的药
    nonisolated static func slots(at now: Date = Date(), meds: [Row] = Health.activeMeds(),
                                  took: [String] = Health.day(Health.me).took) -> [Slot] {
        let list = meds.filter { $0["active"]?.bool != false && !$0.strings("times").isEmpty }
        let perDay = list.reduce(0) { $0 + $1.strings("times").count }
        guard perDay > 0 else { return [] }
        let span = max(1, min(days, cap / perDay))
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var out: [Slot] = []
        for k in 0..<span {
            guard let day = cal.date(byAdding: .day, value: k, to: today) else { continue }
            let key = Health.dateKey(day)
            for m in list {
                if k == 0 && took.contains(m.id) { continue }
                for t in m.strings("times").sorted() {
                    let p = t.split(separator: ":")
                    guard p.count == 2, let h = Int(p[0]), let mi = Int(p[1]),
                          let when = cal.date(bySettingHour: h, minute: mi, second: 0, of: day), when > now else { continue }
                    let dose = m.string("dose")
                    out.append(Slot(id: "\(prefix)\(m.id)-\(key.replacingOccurrences(of: "-", with: ""))-\(t.replacingOccurrences(of: ":", with: ""))",
                                    at: when, title: m.string("name"), body: dose.isEmpty ? t : "\(t) · \(dose)"))
                }
            }
        }
        return Array(out.sorted { $0.at < $1.at }.prefix(cap))
    }

    /// 把接下来几天交给系统。先撤掉旧的那一组再排；总开关关着时只撤不排
    @discardableResult
    static func plan(now: Date = Date()) async -> PlanState {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        var st = PlanState(at: now)
        if !on() {
            st.off = true
            state = st
            return st
        }
        let auth = await center.notificationSettings().authorizationStatus
        guard auth == .authorized || auth == .provisional || auth == .ephemeral else {
            st.permission = true
            state = st
            return st
        }
        let items = slots(at: now)
        do {
            for it in items {
                let c = UNMutableNotificationContent()
                c.title = it.title
                c.body = it.body
                c.sound = .default
                c.threadIdentifier = "med"
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: it.at)
                try await center.add(UNNotificationRequest(identifier: it.id, content: c,
                                                           trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
            st.ok = true
            st.n = items.count
            st.until = items.last?.at
        } catch {
            st.error = error.localizedDescription
        }
        state = st
        return st
    }

    /// 改了药、记下吃过、开关变了：停 0.8 秒再排一次（网页版 replanSoon）
    static func planSoon() {
        soon?.cancel()
        soon = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await plan()
        }
    }

    /// 没允许通知时那一行上的「允许通知」：系统问一次，再重排
    static func askPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await plan()
    }
}

// MARK: - 从「健康」app 同步（网页版 system/healthkit.js 与外壳 HealthBridge.swift，ARCHITECTURE 4.484）
//
// 只读不写。读睡眠、步数、体重、饮水与经期，写进每日记录；心情、不适、排便、备注与用药是手记的，一个字都不碰。
// 某一项系统没给（没授权、或者没有数据），那一项也不动，保留手填的值。不调任何接口、不上传。
//
// 手动同步（「健康 - 设置」里那一行）先问授权：第一次弹系统那张勾选表，由用户自己点。
// 自动同步（打开应用、回到前台）只在手动同步成功过一次之后才有，只读、不问授权；十分钟内不重读；
// 从上次成功那天按日历天数补到今天，至少 2 天（昨晚的睡眠记在昨天），最多 30 天；从没记过时间的按 7 天。
// 结果记在 settings.healthkitSync = { at, okAt, ok, days, auto, error }；自动读失败不弹提示，原因写在设置页那一行上。
enum HealthKitReader {
    struct DayData: Equatable, Sendable {
        var date: String
        var sleepMin: Double = 0
        var steps: Double = 0
        var weightKg: Double = 0
        var water: Double = 0
    }

    struct CycleData: Equatable, Sendable {
        var start: String
        var end: String
    }

    struct Reading: Equatable, Sendable {
        var days: [DayData] = []
        var cycles: [CycleData] = []
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private static let store = HKHealthStore()

    private static var readTypes: Set<HKObjectType> {
        var out = Set<HKObjectType>()
        if let t = HKObjectType.quantityType(forIdentifier: .stepCount) { out.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .bodyMass) { out.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .dietaryWater) { out.insert(t) }
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { out.insert(t) }
        if let t = HKObjectType.categoryType(forIdentifier: .menstrualFlow) { out.insert(t) }
        return out
    }

    /// 问系统要读的权限。回来只表示询问走完了：HealthKit 不告诉应用用户拒了哪一项，读不到就是空的
    static func request() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw Failure(message: "这台设备没有健康数据") }
        do { try await store.requestAuthorization(toShare: [], read: readTypes) }
        catch { throw Failure(message: "系统没有授权：\(error.localizedDescription)") }
    }

    /// 最近 days 天，一天一行。读不到的项为 0，写入时跳过
    static func read(days: Int) async throws -> Reading {
        guard HKHealthStore.isHealthDataAvailable() else { throw Failure(message: "这台设备没有健康数据") }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let end = today.addingTimeInterval(86400)
        guard let start = cal.date(byAdding: .day, value: -max(1, days), to: today) else { throw Failure(message: "日期算不出来") }
        var rows: [String: DayData] = [:]
        func edit(_ date: Date, _ f: (inout DayData) -> Void) {
            let k = Health.dateKey(date)
            var r = rows[k] ?? DayData(date: k)
            f(&r)
            rows[k] = r
        }
        if let t = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            for (day, v) in await sums(t, unit: .count(), from: start, to: end, cal: cal) { edit(day) { $0.steps = v.rounded() } }
        }
        if let t = HKQuantityType.quantityType(forIdentifier: .dietaryWater) {
            // 本地那个字段记的是「几杯」，一杯按 250 毫升折算
            for (day, v) in await sums(t, unit: .liter(), from: start, to: end, cal: cal) { edit(day) { $0.water = (v * 1000 / 250).rounded() } }
        }
        // 体重取当天最后一次称的
        if let t = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            for s in await samples(t, from: start, to: end) {
                guard let q = s as? HKQuantitySample else { continue }
                let kg = q.quantity.doubleValue(for: .gramUnit(with: .kilo))
                edit(s.endDate) { $0.weightKg = kg }
            }
        }
        // 睡眠按「醒来那天」归日：凌晨三点睡的算前一晚。0 在床上、1 睡着（旧）、2 醒着、3 核心、4 深度、5 REM
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            for s in await samples(t, from: start, to: end) {
                guard let c = s as? HKCategorySample, c.value == 1 || c.value >= 3 else { continue }
                let mins = c.endDate.timeIntervalSince(c.startDate) / 60
                edit(c.endDate) { $0.sleepMin += mins }
            }
        }
        // 经期：有流量的日子连在一起算一次（隔开两天以上算下一次），带「周期开始」标记的样本一定开新的一次。往前多看 90 天
        var cycles: [CycleData] = []
        if let t = HKObjectType.categoryType(forIdentifier: .menstrualFlow),
           let farStart = cal.date(byAdding: .day, value: -90, to: today) {
            var cur: (Date, Date)?
            for s in await samples(t, from: farStart, to: end) {
                guard let c = s as? HKCategorySample, c.value != HKCategoryValueMenstrualFlow.none.rawValue else { continue }
                let day = cal.startOfDay(for: c.startDate)
                let isStart = (c.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool) ?? false
                if let open = cur, !isStart, day.timeIntervalSince(open.1) <= 86400 * 2 {
                    cur = (open.0, max(open.1, day))
                } else {
                    if let open = cur { cycles.append(CycleData(start: Health.dateKey(open.0), end: Health.dateKey(open.1))) }
                    cur = (day, day)
                }
            }
            if let open = cur { cycles.append(CycleData(start: Health.dateKey(open.0), end: Health.dateKey(open.1))) }
        }
        var list = rows.values.sorted { $0.date < $1.date }
        for i in list.indices { list[i].sleepMin = list[i].sleepMin.rounded() }
        return Reading(days: list, cycles: cycles)
    }

    private static func sums(_ type: HKQuantityType, unit: HKUnit, from: Date, to: Date, cal: Calendar) async -> [(Date, Double)] {
        await withCheckedContinuation { go in
            let q = HKStatisticsCollectionQuery(quantityType: type,
                                                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: from, end: to),
                                                options: .cumulativeSum, anchorDate: cal.startOfDay(for: from),
                                                intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, got, _ in
                var out: [(Date, Double)] = []
                got?.enumerateStatistics(from: from, to: to) { s, _ in
                    if let v = s.sumQuantity()?.doubleValue(for: unit), v > 0 { out.append((s.startDate, v)) }
                }
                go.resume(returning: out)
            }
            store.execute(q)
        }
    }

    private static func samples(_ type: HKSampleType, from: Date, to: Date) async -> [HKSample] {
        await withCheckedContinuation { go in
            let q = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: from, end: to),
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]) { _, got, _ in
                go.resume(returning: got ?? [])
            }
            store.execute(q)
        }
    }
}

@MainActor
enum HealthSync {
    typealias Reader = (Int) async throws -> HealthKitReader.Reading

    static let autoGap: TimeInterval = 10 * 60
    private static var busy = false

    /// 上一次同步：{ at, okAt, ok, days, auto, error }（毫秒时间戳，与网页版同一形状）
    static func last(_ s: AppSettings = .load()) -> [String: JSONValue]? { s.raw["healthkitSync"]?.object }

    /// 自动同步的开关（settings.healthAutoSync），默认开
    static func autoOn(_ s: AppSettings = .load()) -> Bool { s.raw["healthAutoSync"]?.bool != false }

    /// 同步成功过：记号里有成功时间，或者库里已有从「健康」写进来的记录（更新当天还没有记号）
    static func everSynced(_ s: AppSettings = .load()) -> Bool {
        if (last(s)?["okAt"]?.number ?? 0) > 0 { return true }
        return ((try? Database.shared.all(Health.collection)) ?? []).contains { $0.string("source") == "healthkit" }
    }

    /// 读来的写进本地：只填系统给得出的那几项，手记的一概不动。返回写了几天、读到几天、新记了几次经期
    @discardableResult
    static func apply(_ r: HealthKitReader.Reading) throws -> (days: Int, read: Int, cycles: Int) {
        var touched = 0
        for d in r.days {
            guard d.date.range(of: #"^\d{4}-\d\d-\d\d$"#, options: .regularExpression) != nil else { continue }
            var patch: [String: JSONValue] = [:]
            // 0 与「没给」是同一回事：系统不会给 0 步，只会不给
            if d.sleepMin > 0 { patch["sleepMin"] = .number(d.sleepMin.rounded()) }
            if d.steps > 0 { patch["steps"] = .number(d.steps.rounded()) }
            if d.weightKg > 0 { patch["weight"] = .number((d.weightKg * 100).rounded() / 100) }
            if d.water > 0 { patch["water"] = .number(d.water.rounded()) }
            guard !patch.isEmpty else { continue }
            patch["source"] = .string("healthkit")
            try Health.set(Health.me, d.date, patch)
            touched += 1
        }
        var cyc = 0
        for c in r.cycles {
            if try Health.importCycle(start: c.start, end: c.end) != nil { cyc += 1 }
        }
        return (touched, r.days.count, cyc)
    }

    private static func remember(_ patch: [String: JSONValue]) {
        do {
            var s = try AppSettings.loadForWrite()
            var o = s.raw["healthkitSync"]?.object ?? [:]
            for (k, v) in patch { o[k] = v }
            s.raw["healthkitSync"] = .object(o)
            try s.save()
            SettingsModel.shared.reload()
        } catch {
            Problems.report("健康同步的结果未能记下：\(error.localizedDescription)")
        }
    }

    /// 手动同步：问授权（第一次弹表），读 days 天，记下结果。失败照原样抛出，界面写出系统给的原因
    @discardableResult
    static func syncNow(days: Int = 30, request: () async throws -> Void = HealthKitReader.request,
                        reader: Reader = HealthKitReader.read) async throws -> (days: Int, read: Int, cycles: Int) {
        let now = Date().millis
        do {
            try await request()
            let got = try apply(try await reader(days))
            remember(["at": .number(now), "okAt": .number(now), "ok": .bool(true), "days": .number(Double(got.days)),
                      "auto": .bool(false), "error": .string("")])
            return got
        } catch {
            remember(["at": .number(now), "ok": .bool(false), "auto": .bool(false), "error": .string(error.localizedDescription)])
            throw error
        }
    }

    /// 读几天：从上次成功那天按日历天数补到今天，至少 2 天，最多 30 天；从没记过时间的按 7 天
    static func autoDays(since okAt: Double, now: Date) -> Int {
        guard okAt > 0 else { return 7 }
        let cal = Calendar.current
        let a = cal.startOfDay(for: Date(millis: okAt)), b = cal.startOfDay(for: now)
        let n = Int((b.timeIntervalSince(a) / 86400).rounded())
        return max(2, min(30, n))
    }

    /// 自动同步：开关开着、同步成功过、距上次超过十分钟才读；只读不问授权。回来的是这次的结果，没读就是 nil
    @discardableResult
    static func autoSync(now: Date = Date(), reader: Reader = HealthKitReader.read) async -> (days: Int, read: Int, cycles: Int)? {
        let s = AppSettings.load()
        guard !busy, autoOn(s), everSynced(s) else { return nil }
        let lastSync = last(s)
        if let at = lastSync?["at"]?.number, at > 0, now.millis - at < autoGap * 1000 { return nil }
        busy = true
        defer { busy = false }
        let days = autoDays(since: lastSync?["okAt"]?.number ?? 0, now: now)
        do {
            let got = try apply(try await reader(days))
            remember(["at": .number(now.millis), "okAt": .number(now.millis), "ok": .bool(true),
                      "days": .number(Double(got.days)), "auto": .bool(true), "error": .string("")])
            return got
        } catch {
            remember(["at": .number(now.millis), "ok": .bool(false), "auto": .bool(true), "error": .string(error.localizedDescription)])
            return nil
        }
    }

    /// 打开应用、回到前台时调：自动同步一次，并把用药提醒往后续排（网页版 healthkit.installAuto 与 medremind.start）
    static func didBecomeActive() {
        Task { @MainActor in
            await MedRemind.plan()
            await autoSync()
        }
    }
}
