import XCTest
@testable import Eira

/// 状态栏：默认全关；开着时提示词里写栏目与规则；回复里的状态块不落成气泡，值存在最后一条上；带进下一轮
final class StatusBarTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    func testOffByDefault() throws {
        let c = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertFalse(StatusBar.active(c))
        XCTAssertEqual(StatusBar.piece(c, msgs: [], names: [:], settings: AppSettings.load()), "")
    }

    func testLift() {
        let r = StatusBar.lift("在呢\n今天好累\n[状态栏]\n心情：疲惫\n好感度：62\n[/状态栏]")
        XCTAssertEqual(r.text, "在呢\n今天好累")
        XCTAssertEqual(r.vals?["心情"], "疲惫")
        XCTAssertEqual(r.vals?["好感度"], "62")
        XCTAssertNil(StatusBar.lift("没有状态栏").vals)
    }

    func testReplyStoresSnapshotAndCarries() async throws {
        var cfg = StatusBar.config(try XCTUnwrap(Repo.chat("chat_a")))
        cfg.on = true
        for i in cfg.items.indices where ["mood", "time"].contains(cfg.items[i].id) { cfg.items[i].on = true }
        cfg.items.append(StatusBar.Item(id: "c_x", kind: "custom", on: true, label: "好感度", desc: "对你的好感", initial: "50",
                                        rule: "每轮变化不超过 5", show: "bar", min: 0, max: 100))
        try StatusBar.save("chat_a", cfg)
        let piece = StatusBar.piece(try XCTUnwrap(Repo.chat("chat_a")), msgs: [], names: [:], settings: AppSettings.load())
        XCTAssertTrue(piece.contains("心情：…"))
        XCTAssertTrue(piece.contains("Rule: 每轮变化不超过 5"))
        XCTAssertTrue(piece.contains("好感度：50"))

        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("在呢\n[状态栏]\n心情：开心\n好感度：55\n[/状态栏]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        let msgs = try Repo.messages(chatId: "chat_a")
        XCTAssertFalse(msgs.contains { $0.content.contains("状态栏") })
        let last = try XCTUnwrap(msgs.last)
        let vals = StatusBar.values(last)
        XCTAssertEqual(vals.first { $0.id == "mood" }?.value, "开心")
        XCTAssertEqual(vals.first { $0.id == "c_x" }?.value, "55")
        XCTAssertFalse(vals.first { $0.id == "time" }?.value.isEmpty ?? true)
        // 带进下一轮：上一轮的值作为当前状态
        let next = StatusBar.piece(try XCTUnwrap(Repo.chat("chat_a")), msgs: msgs, names: [:], settings: AppSettings.load())
        XCTAssertTrue(next.contains("好感度：55"))
        XCTAssertTrue(next.contains("心情：开心"))
        XCTAssertEqual(StatusBar.percent(cfg.items.last!, "55"), 55)
    }
}
