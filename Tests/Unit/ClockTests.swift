import XCTest
@testable import Eira

/// 时间感知：虚拟时间往下走或固定、时区标签、时差只在两边不在一处时说
final class ClockTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testVirtualTime() {
        var s = AppSettings.load()
        let real = Date(millis: 1_800_000_000_000)
        XCTAssertEqual(Clock.now(s, real: real), real)
        let at = Date(millis: 1_700_000_000_000)
        for (k, v) in Clock.virtualPatch(at, frozen: false, real: real) { s.raw[k] = v }
        // 一小时之后，虚拟时间也往下走了一小时
        let later = Date(millis: real.millis + 3_600_000)
        XCTAssertEqual(Clock.now(s, real: later).millis, at.millis + 3_600_000, accuracy: 1)
        s.raw["timeFrozen"] = .bool(true)
        XCTAssertEqual(Clock.now(s, real: later).millis, at.millis, accuracy: 1)
        XCTAssertEqual(Clock.toWorld(real.millis, s).millis, at.millis, accuracy: 1)
    }

    func testZonesAndBlock() throws {
        var s = AppSettings.load()
        s.raw["timeZoneUser"] = .string("Asia/Shanghai")
        XCTAssertEqual(Clock.label("Asia/Tokyo"), "日本 · 东京")
        XCTAssertEqual(Clock.zoneDiff("Asia/Tokyo", "Asia/Shanghai", at: Date()), 60)
        XCTAssertEqual(Clock.zoneDiff("Asia/Shanghai", "Asia/Shanghai", at: Date()), 0)
        var char = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(Clock.charZone(char, s), "Asia/Shanghai")
        char.row["timezone"] = .string("Asia/Tokyo")
        XCTAssertEqual(Clock.charZone(char, s), "Asia/Tokyo")
        s.raw["injectTime"] = .bool(false)
        XCTAssertFalse(Clock.enabled(s))
        XCTAssertFalse(Clock.stampOn(s))
    }
}
