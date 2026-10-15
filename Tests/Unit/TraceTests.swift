import XCTest
@testable import Eira

/// 请求记录：默认关、关着一条都不记；开着记下发了什么与回了什么；超过条数丢最早的；不多调接口
final class TraceTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "name": .string("主"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("好")) }
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    @MainActor
    func testOffByDefaultThenRecords() async throws {
        Trace.shared.clear()
        _ = try await AIService.shared.send(task: "chat.reply", system: "SYS", messages: [AIMessage(role: .user, content: "你好")])
        XCTAssertTrue(Trace.shared.rows.isEmpty, "默认关，不记")

        try setSettings(["traceOn": .bool(true), "traceMax": .number(2)])
        for _ in 0..<3 {
            _ = try await AIService.shared.send(task: "chat.reply", system: "SYS", messages: [AIMessage(role: .user, content: "你好")])
        }
        XCTAssertEqual(MockNet.count, 4, "记录不多发请求")
        XCTAssertEqual(Trace.shared.rows.count, 2, "超过条数丢最早的")
        let r = try XCTUnwrap(Trace.shared.rows.first)
        XCTAssertEqual(r.system, "SYS")
        XCTAssertEqual(r.messages.first?.content, "你好")
        XCTAssertEqual(r.reply, "好")
        XCTAssertTrue(Trace.text(r).contains("=== system ===\nSYS"))
        XCTAssertEqual(Trace.estimate("你好ab"), 3)
        Trace.shared.clear()
    }
}
