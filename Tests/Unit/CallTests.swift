import XCTest
@testable import Eira

/// 通话：一轮一次请求（重试最多一次，再取用户的上限）；挂断落一条记录；总结默认开、一通一次。
final class CallTests: StoreTestCase {
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

    func testPrepareUsesCallRules() throws {
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        chat.row["translateTo"] = .string("English")
        let p = try CallEngine.prepare(chat: chat, char: XCTUnwrap(Repo.character("char_a")))
        XCTAssertTrue(p.system.contains("[正在通话中]"))
        XCTAssertTrue(p.system.contains("a phone call"))
        // 通话里不夹译文
        XCTAssertFalse(p.system.contains("[译文"))
    }

    func testTurnIsOneRequestWithCap() async throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let p = try CallEngine.prepare(chat: chat, char: XCTUnwrap(Repo.character("char_a")))
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("喂？")) }
        let text = try await CallEngine.turn(p, lines: [], opening: CallEngine.openingLine(outgoing: true))
        XCTAssertEqual(text, "喂？")
        XCTAssertEqual(MockNet.count, 1)
        let body = try JSONValue.parse(XCTUnwrap(MockNet.requests.first?.httpBodyStreamData()))
        XCTAssertEqual(body["max_tokens"]?.number, 400)

        // 一直失败：开了三次重试也只多试一次
        try setSettings(["retryMax": .number(3)])
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        do { _ = try await CallEngine.turn(p, lines: [.init(role: "user", text: "在吗")]); XCTFail("应当报错") } catch {}
        XCTAssertEqual(MockNet.count, 2)
    }

    func testFinishAndSummaryOnce() async throws {
        XCTAssertTrue(ExtraCalls.active(.load()).contains { $0.id == "callSummary" })
        let lines: [CallEngine.Line] = [.init(role: "char", text: "喂？"), .init(role: "user", text: "是我")]
        let m = try CallEngine.finish(chatId: "chat_a", charId: "char_a", direction: "out", outcome: "done", seconds: 65,
                                      lines: lines, userName: "小于", charName: "林")
        XCTAssertEqual(m.content, "[语音通话 01:05]\n林：喂？\n小于：是我")
        XCTAssertEqual(m.kind, "call")
        XCTAssertTrue(CallEngine.autoSummary(outcome: "done", lines: lines))
        XCTAssertFalse(CallEngine.autoSummary(outcome: "cancelled", lines: lines))

        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        do { try await CallEngine.summarize(messageId: m.id); XCTFail("应当报错") } catch {}
        XCTAssertEqual(MockNet.count, 1)

        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("两人通了电话。")) }
        try await CallEngine.summarize(messageId: m.id)
        XCTAssertEqual(try Database.shared.get(Collections.messages, id: m.id)?.string("callSummary"), "两人通了电话。")

        // 关掉之后不自动写
        try setSettings(["callSummary": .bool(false)])
        XCTAssertFalse(CallEngine.autoSummary(outcome: "done", lines: lines))
    }
}
