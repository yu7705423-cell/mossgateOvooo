import XCTest
@testable import Eira

/// 回复节奏：状态从本地推，到点时刻记在会话上，连发取早的，清掉再生成
final class PaceTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testModeDefaultsAndDue() throws {
        var c = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertEqual(Pace.mode(c), Pace.manual)
        c.row["paceBase"] = .number(100)
        c.row["paceSleep"] = .bool(false)
        let char = try Repo.character("char_a")
        let at = Date().millis
        // 抖动取 0.4 时乘 1.0；带问号减半
        XCTAssertEqual(Pace.due(c, char: char, text: "在吗", at: at, rng: { 0.4 }).secs, 100)
        XCTAssertEqual(Pace.due(c, char: char, text: "在吗？", at: at, rng: { 0.4 }).secs, 50)
        c.row["paceMax"] = .number(30)
        XCTAssertEqual(Pace.due(c, char: char, text: "在吗", at: at, rng: { 0.4 }).secs, 30)
    }

    func testScheduleKeepsEarlier() throws {
        var c = try XCTUnwrap(Repo.chat("chat_a"))
        c.row["paceMode"] = .string(Pace.paced)
        c.row["paceSleep"] = .bool(false)
        c.row["paceBase"] = .number(100)
        try Repo.save(c)
        let first = try XCTUnwrap(Pace.schedule("chat_a", text: "在吗", rng: { 0.4 }))
        let second = try XCTUnwrap(Pace.schedule("chat_a", text: "在吗", rng: { 1.0 }))
        XCTAssertEqual(second.dueAt, first.dueAt, accuracy: 1)
        try Pace.clear("chat_a")
        XCTAssertNil(Pace.pending(try XCTUnwrap(Repo.chat("chat_a"))))
    }
}

extension CostTests {
    /// 延迟回复到点：回一次；接口一直失败时也只打一次，并且清掉了，下一轮巡检不再打
    func testPaceDueIsOneRequestEvenOnFailure() async throws {
        var c = try XCTUnwrap(Repo.chat("chat_a"))
        c.row["pacePending"] = .object(["dueAt": .number(Date().millis - 1000), "state": .object(["kind": .string("free")])])
        try Repo.save(c)
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        await Pace.runDue()
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertNil(Pace.pending(try XCTUnwrap(Repo.chat("chat_a"))))
        await Pace.runDue()
        XCTAssertEqual(MockNet.count, 1)
    }

    func testPaceDueReplies() async throws {
        var c = try XCTUnwrap(Repo.chat("chat_a"))
        c.row["pacePending"] = .object(["dueAt": .number(Date().millis - 1000), "state": .object(["kind": .string("free")])])
        try Repo.save(c)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("来了")) }
        let n = await Pace.runDue()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.content, "来了")
    }
}
