import XCTest
@testable import Eira

/// 健康：每人每天一行、喝水不设上限、排便一次一条（旧行读的时候摊开）、经期推算、用药勾选、
/// 上下文默认不注入且只写事实，角色那一份跟着 healthOn，状态栏读记录
final class HealthTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testDayRecords() throws {
        let today = Health.dateKey()
        try Health.set(Health.me, today, ["sleepMin": .number(450), "steps": .number(8000), "mood": .string("good")])
        for _ in 0..<12 { try Health.addWater() }
        try Health.addWater(Health.me, -1)
        try Health.toggleSymptom(Health.me, today, "headache")
        try Health.addPoop(Health.me, today)
        try Health.updatePoop(Health.me, today, 0, at: "8:3x0", form: "b4")
        let d = Health.day(Health.me)
        XCTAssertEqual(d.water, 11)
        XCTAssertEqual(d.symptoms, ["headache"])
        XCTAssertEqual(d.poops.count, 1)
        XCTAssertEqual(d.poops[0].form, "b4")
        XCTAssertEqual(Health.recent().count, 1)
        XCTAssertEqual(Health.poopTime("8:30"), "08:30")
        XCTAssertEqual(Health.poopTime("1:99"), "")
        XCTAssertEqual(Health.fmtSleep(450), "7 小时 30 分")
    }

    func testOldPoopFormatReads() throws {
        let r = Row.new(prefix: "hl", ["who": .string(Health.me), "date": .string("2026-01-01"), "poop": .number(2), "poopForm": .string("b6")])
        try Database.shared.put(Health.collection, r)
        let d = Health.day(Health.me, "2026-01-01")
        XCTAssertEqual(d.poops.map(\.form), ["b6", ""])
    }

    func testCyclePrediction() throws {
        try Database.shared.put(Health.cycles, Row.new(prefix: "cy", ["start": .string("2026-01-01"), "end": .string("2026-01-05")]))
        XCTAssertNil(Health.predictCycle())
        try Database.shared.put(Health.cycles, Row.new(prefix: "cy", ["start": .string("2026-01-29"), "end": .string("2026-02-02")]))
        let p = try XCTUnwrap(Health.predictCycle())
        XCTAssertEqual(p.avg, 28)
        XCTAssertEqual(p.next, "2026-02-26")
    }

    func testBlockOffByDefaultAndFactsOnly() throws {
        try Health.set(Health.me, Health.dateKey(), ["steps": .number(5000), "poops": .array([.object(["at": .string("08:00"), "form": .string("b4")])])])
        var s = AppSettings.load()
        let char = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(Health.block(char: char, userName: "小于", settings: s), "")
        s.raw["healthInject"] = .bool(true)
        var b = Health.block(char: char, userName: "小于", settings: s)
        XCTAssertTrue(b.contains("Walked 5000 steps."))
        XCTAssertFalse(b.contains("Bowel"))
        s.raw["healthPoopInject"] = .bool(true)
        b = Health.block(char: char, userName: "小于", settings: s)
        XCTAssertTrue(b.contains("08:00 (表面光滑)"))
        // 角色那一份跟着它身上的开关
        try Health.set(char.id, Health.dateKey(), ["energy": .string("low")])
        XCTAssertFalse(Health.block(char: char, userName: "小于", settings: s).contains("Your own body"))
        try Health.setCharOn(char.id, true)
        let on = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertTrue(Health.block(char: on, userName: "小于", settings: s).contains("Energy: 疲惫."))
        XCTAssertEqual(Health.statusText(on), "疲惫")
    }

    func testMeds() throws {
        XCTAssertThrowsError(try Health.saveMed(id: nil, name: " ", dose: "", times: [], note: "", active: true))
        try Health.saveMed(id: nil, name: "维生素", dose: "1 片", times: ["20:00", "08:00", "08:00"], note: "", active: true)
        let m = try XCTUnwrap(Health.activeMeds().first)
        XCTAssertEqual(m.strings("times"), ["08:00", "20:00"])
        try Health.takeMed(m.id)
        XCTAssertEqual(Health.day(Health.me).took, [m.id])
        try Health.takeMed(m.id)
        XCTAssertTrue(Health.day(Health.me).took.isEmpty)
    }

    /// 用药提醒交给系统（网页版 4.482）：按每天次数算排几天（60 除以每天次数，最多 14 天）；
    /// 过了点的、今天已经记下吃过的、停用的、没有时间的不排；标识以 med- 开头
    func testMedRemindSlots() throws {
        try Health.saveMed(id: nil, name: "维生素", dose: "1 片", times: ["08:00", "20:00"], note: "", active: true)
        try Health.saveMed(id: nil, name: "停用的", dose: "", times: ["12:00"], note: "", active: false)
        try Health.saveMed(id: nil, name: "没有时间", dose: "", times: [], note: "", active: true)
        let a = try XCTUnwrap(Health.listMeds().first { $0.string("name") == "维生素" })
        let now = try XCTUnwrap(Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()))
        let list = MedRemind.slots(at: now, meds: Health.listMeds(), took: [])
        XCTAssertEqual(list.count, 1 + 13 * 2, "每天 2 次排满 14 天，今天 08:00 已过")
        XCTAssertEqual(list.first?.title, "维生素")
        XCTAssertEqual(list.first?.body, "20:00 · 1 片")
        XCTAssertEqual(list.first?.id, "med-\(a.id)-\(Health.dateKey(now).replacingOccurrences(of: "-", with: ""))-2000")
        XCTAssertTrue(list.allSatisfy { $0.at > now && $0.id.hasPrefix(MedRemind.prefix) })
        XCTAssertEqual(list.map(\.at), list.map(\.at).sorted())
        XCTAssertFalse(list.contains { $0.title == "停用的" || $0.title == "没有时间" })

        // 今天已经记下吃过：今天剩下的那次不排
        XCTAssertEqual(MedRemind.slots(at: now, meds: Health.listMeds(), took: [a.id]).count, 13 * 2)

        // 每天 15 次：60 / 15 = 4 天；总数不超过 60
        for i in 0..<4 { try Health.saveMed(id: nil, name: "药\(i)", dose: "", times: ["07:00", "13:00", "21:30"], note: "", active: true) }
        let many = MedRemind.slots(at: now, meds: Health.listMeds(), took: [])
        let perDay = 2 + 4 * 3
        XCTAssertEqual(perDay, 14)
        XCTAssertLessThanOrEqual(many.count, MedRemind.cap)
        let lastDay = try XCTUnwrap(many.last).at
        XCTAssertLessThan(lastDay.timeIntervalSince(now), Double(60 / perDay) * 86400)

        // 总开关默认开
        XCTAssertTrue(MedRemind.on())
        try setSettings(["medRemind": .bool(false)])
        XCTAssertFalse(MedRemind.on())
    }

    /// 从「健康」同步（网页版 4.484）：只填系统给得出的几项、手记的不动；没同步过不自动、不问授权；
    /// 十分钟内不重读；补到今天至少两天；关掉不读；读失败记在设置里；更新当天认库里已有的同步记录
    @MainActor
    func testHealthKitSync() async throws {
        final class Box { var calls: [Int] = []; var asked = 0 }
        let box = Box()
        let today = Health.dateKey()
        let yesterday = Health.shift(today, -1)
        let reading = HealthKitReader.Reading(days: [
            .init(date: yesterday, sleepMin: 431.6, steps: 0, weightKg: 52.345, water: 6),
            .init(date: today, sleepMin: 0, steps: 8000, weightKg: 0, water: 0),
            .init(date: "坏日期", steps: 10),
        ], cycles: [.init(start: Health.shift(today, -40), end: Health.shift(today, -35))])
        let reader: HealthSync.Reader = { d in box.calls.append(d); return reading }

        try Health.set(Health.me, yesterday, ["mood": .string("good"), "steps": .number(1234)])

        // 没同步过：自动那条路不读
        let none = await HealthSync.autoSync(reader: reader)
        XCTAssertNil(none)
        XCTAssertTrue(box.calls.isEmpty)

        let got = try await HealthSync.syncNow(days: 30, request: { box.asked += 1 }, reader: reader)
        XCTAssertEqual(box.asked, 1)
        XCTAssertEqual(box.calls, [30])
        XCTAssertEqual(got.days, 2)
        XCTAssertEqual(got.cycles, 1)
        let y = Health.day(Health.me, yesterday)
        XCTAssertEqual(y.sleepMin, 432)
        XCTAssertEqual(y.weight, 52.35, accuracy: 0.0001)
        XCTAssertEqual(y.water, 6)
        XCTAssertEqual(y.steps, 1234, "系统没给的那一项保留手填的值")
        XCTAssertEqual(y.mood, "good", "手记的不动")
        XCTAssertEqual(y.row?.string("source"), "healthkit")
        XCTAssertEqual(Health.day(Health.me, today).steps, 8000)
        let last = try XCTUnwrap(HealthSync.last())
        XCTAssertEqual(last["ok"]?.bool, true)
        XCTAssertEqual(last["auto"]?.bool, false)
        let okAt = try XCTUnwrap(last["okAt"]?.number)

        // 十分钟内不重读
        let soon = await HealthSync.autoSync(now: Date(millis: okAt + 5 * 60_000), reader: reader)
        XCTAssertNil(soon)
        XCTAssertEqual(box.calls.count, 1)

        // 过了：只读不问授权，补到今天
        let later = Date(millis: okAt).addingTimeInterval(3 * 86400)
        let auto = await HealthSync.autoSync(now: later, reader: reader)
        XCTAssertNotNil(auto)
        XCTAssertEqual(box.calls.last, 3)
        XCTAssertEqual(box.asked, 1)
        XCTAssertEqual(HealthSync.last()?["auto"]?.bool, true)
        XCTAssertEqual(HealthSync.autoDays(since: later.millis, now: later.addingTimeInterval(3600)), 2, "至少两天")
        XCTAssertEqual(HealthSync.autoDays(since: later.millis, now: later.addingTimeInterval(90 * 86400)), 30, "最多 30 天")

        // 读失败：不抛，记下原因
        struct Boom: LocalizedError { var errorDescription: String? { "系统没有授权：测试" } }
        let failAt = later.addingTimeInterval(3600)
        let failed = await HealthSync.autoSync(now: failAt) { _ in throw Boom() }
        XCTAssertNil(failed)
        XCTAssertEqual(HealthSync.last()?["ok"]?.bool, false)
        XCTAssertEqual(HealthSync.last()?["error"]?.string, "系统没有授权：测试")

        // 关掉不读
        try setSettings(["healthAutoSync": .bool(false)])
        let off = await HealthSync.autoSync(now: failAt.addingTimeInterval(3600), reader: reader)
        XCTAssertNil(off)
        XCTAssertEqual(box.calls.count, 2)

        // 更新当天：没有同步记号，库里已有从「健康」写进来的记录也算同步过，从没记过时间的读 7 天
        try setSettings(["healthAutoSync": .bool(true), "healthkitSync": .null])
        XCTAssertTrue(HealthSync.everSynced())
        _ = await HealthSync.autoSync(reader: reader)
        XCTAssertEqual(box.calls.last, 7)
    }

    /// 从「健康」读来的经期：前后三天内已有手填的一次不动；新的记成一次
    func testImportCycleKeepsManual() throws {
        let today = Health.dateKey()
        try Health.startCycle(Health.shift(today, -30))
        XCTAssertNil(try Health.importCycle(start: Health.shift(today, -29), end: Health.shift(today, -25)))
        XCTAssertEqual(Health.listCycles().count, 1)
        XCTAssertEqual(Health.listCycles().first?.string("end"), "", "手填的一次不补结束日期")
        XCTAssertNotNil(try Health.importCycle(start: Health.shift(today, -60), end: Health.shift(today, -55)))
        XCTAssertEqual(Health.listCycles().count, 2)
        XCTAssertNil(try Health.importCycle(start: "不是日期"))
    }
}
