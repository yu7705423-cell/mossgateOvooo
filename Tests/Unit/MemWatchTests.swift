import XCTest
@testable import Eira

/// 记忆总结的「离开会话后」「隔夜」两条触发（网页版 memwatch.js，4.441）：默认都关、一次都不调；
/// 开着而接口一直失败时，同一段积压只打一次（先记试过再发，网页版第 15 条）。
final class MemWatchTests: StoreTestCase {
    private let later = Date(timeIntervalSince1970: 4_000_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    /// 再聊两轮，积压够离开那一条的两轮
    private func twoRounds() throws {
        for t in ["w1", "w2"] {
            _ = try ChatEngine.send(text: "在吗", chatId: "chat_a")
            _ = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "在", turnId: t))
        }
    }

    func testOffByDefault() async throws {
        try twoRounds()
        let s = AppSettings.load()
        XCTAssertEqual(MemWatch.idleMinutes(s), 0)
        XCTAssertFalse(MemWatch.overnightOn(s))
        let n = await MemWatch.overnight(now: later)
        XCTAssertEqual(n, 0)
        let r = await MemWatch.idleFire("chat_a", viewing: "", active: true)
        XCTAssertNil(r)
        XCTAssertEqual(MockNet.count, 0)
    }

    func testIdleFailingOnce() async throws {
        try twoRounds()
        try setSettings(["autoSummarizeIdle": .number(5)])
        XCTAssertTrue(MemWatch.enough(chatId: "chat_a"))
        // 又回到这段会话（在前台）：不算离开
        _ = await MemWatch.idleFire("chat_a", viewing: "chat_a", active: true)
        XCTAssertEqual(MockNet.count, 0)
        _ = await MemWatch.idleFire("chat_a", viewing: "", active: true)
        XCTAssertEqual(MockNet.count, 1)
        // 失败也算试过：同一段积压不再打
        XCTAssertFalse(MemWatch.enough(chatId: "chat_a"))
        _ = await MemWatch.idleFire("chat_a", viewing: "", active: true)
        _ = await MemWatch.idleFire("chat_a", viewing: "", active: false)
        XCTAssertEqual(MockNet.count, 1)
        // 记忆整个关掉时不总结
        try twoRounds()
        try setSettings(["memoryEnabled": .bool(false)])
        _ = await MemWatch.idleFire("chat_a", viewing: "", active: true)
        XCTAssertEqual(MockNet.count, 1)
    }

    func testOvernightFailingOnce() async throws {
        try twoRounds()
        let last = try XCTUnwrap(MemorySummary.sinceTried(chatId: "chat_a").last)
        // 当天的积压不算隔夜
        XCTAssertFalse(MemWatch.overnightDue(now: Date(millis: last.createdAt), settings: .load()).contains("chat_a"))
        XCTAssertTrue(MemWatch.overnightDue(now: later, settings: .load()).contains("chat_a"))

        try setSettings(["autoSummarizeOvernight": .bool(true)])
        _ = await MemWatch.overnight(now: later)
        let first = MockNet.count
        XCTAssertGreaterThanOrEqual(first, 1)
        XCTAssertFalse(MemWatch.overnightDue(now: later, settings: .load()).contains("chat_a"))
        // 回到前台再看一次：接口仍然失败，也不再打
        _ = await MemWatch.overnight(now: later)
        XCTAssertEqual(MockNet.count, first)
    }
}
