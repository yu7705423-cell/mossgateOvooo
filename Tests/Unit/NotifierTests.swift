import XCTest
@testable import Eira

/// 通知：后台刷新只问服务器、不调模型、不确认；同一条结果只弹一次。
final class NotifierTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: "eira-notified-results")
        URLProtocol.registerClass(MockNet.self)
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        try importFixture("data.json")
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        BgPush.setDevice(nil)
        UserDefaults.standard.removeObject(forKey: "eira-notified-results")
        try super.tearDownWithError()
    }

    func testLine() {
        XCTAssertEqual(Notifier.line("[时间：晚上]\n\n  在吗  \n[图片：猫]"), "在吗")
        XCTAssertEqual(Notifier.line("[表情：开心]"), "")
    }

    func testOffByDefaultAsksNothing() async throws {
        XCTAssertFalse(Notifier.isOn())
        BgPush.setDevice(.init(server: "https://push.test", id: "d", token: "t", endpoint: ""))
        try setSettings(["bgPush": .object(["on": .bool(true), "server": .string("https://push.test")])])
        let n = try await Notifier.peekResults()
        XCTAssertEqual(n, 0)
        XCTAssertEqual(MockNet.count, 0)
    }

    func testPeekOnlyAsksAndDedups() async throws {
        try setSettings(["nativeNotify": .bool(true),
                         "bgPush": .object(["on": .bool(true), "server": .string("https://push.test")])])
        BgPush.setDevice(.init(server: "https://push.test", id: "d", token: "t", endpoint: ""))
        let body = #"{"results":[{"id":"r1","status":"done","chatId":"chat_a","charId":"char_a","text":"早"},{"id":"r2","status":"failed","charId":"char_a"}]}"#
        MockNet.reset { _, _ in .init(status: 200, body: body) }
        let before = try Repo.messages(chatId: "chat_a").count
        let first = try await Notifier.peekResults()
        let second = try await Notifier.peekResults()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(MockNet.requests.map { $0.url?.path ?? "" }, ["/results", "/results"])
        // 不落库：打开应用时照常取回
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").count, before)
    }
}
