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
}
