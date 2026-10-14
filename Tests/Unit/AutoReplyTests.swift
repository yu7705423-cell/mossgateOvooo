import XCTest
@testable import Eira

/// 自动回复：我这边条数到了自动关并落提示；角色那边每段忙碌只回一次；都不调接口
final class AutoReplyTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testMineStopsAtMax() throws {
        try AutoReply.set("chat_a", AutoReply.mine, ["text": .string("在忙"), "max": .number(2), "on": .bool(true)])
        XCTAssertEqual(try AutoReply.fire("chat_a", AutoReply.mine).map(\.content), ["在忙"])
        let second = try AutoReply.fire("chat_a", AutoReply.mine)
        XCTAssertEqual(second.first?.content, "在忙")
        XCTAssertEqual(second.last?.kind, "notice")
        XCTAssertTrue(second.last?.content.contains("已达设定的条数上限") == true)
        XCTAssertFalse(AutoReply.isOn(try XCTUnwrap(Repo.chat("chat_a")), AutoReply.mine))
        XCTAssertTrue(try AutoReply.fire("chat_a", AutoReply.mine).isEmpty)
    }

    func testMineStopsAtTime() throws {
        try AutoReply.set("chat_a", AutoReply.mine, ["text": .string("在忙"), "until": .number(Date().millis - 1000), "on": .bool(true)])
        let out = try AutoReply.fire("chat_a", AutoReply.mine)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].content.contains("已到设定的结束时间"))
    }

    func testHersOncePerWindow() throws {
        // 免打扰时段设成全天（0 到 23 点之外只有一个小时），保证此刻在休息
        var char = try XCTUnwrap(Repo.character("char_a"))
        let h = DayPlan.hour(char)
        char.row["proactiveQuietFrom"] = .number(Double(h))
        char.row["proactiveQuietTo"] = .number(Double((h + 2) % 24))
        try Database.shared.put(Collections.characters, char.row)
        try AutoReply.set("chat_a", AutoReply.hers, ["on": .bool(true), "text": .string("睡了")])
        XCTAssertEqual(try AutoReply.fire("chat_a", AutoReply.hers).map(\.content), ["睡了"])
        XCTAssertTrue(try AutoReply.fire("chat_a", AutoReply.hers).isEmpty)
    }
}
