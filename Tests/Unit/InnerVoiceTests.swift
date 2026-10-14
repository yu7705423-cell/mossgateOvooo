import XCTest
@testable import Eira

/// 心声：随回复一起不多调接口；单独生成每轮多一次，失败不影响这一轮。
final class InnerVoiceTests: StoreTestCase {
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

    private func setMode(_ mode: String) throws {
        var c = try XCTUnwrap(Repo.chat("chat_a"))
        c.row["innerMode"] = .string(mode)
        try Repo.save(c)
    }

    func testInlineIsOneRequest() async throws {
        try setMode("inline")
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        let b = try ChatPrompt.build(chat: chat, char: char, settings: .load())
        // 默认排在聊天记录之后：在末尾那一段里，不在设定区
        XCTAssertFalse(b.system.contains("[心声]"))
        XCTAssertTrue(b.messages.contains { $0.content.contains("[心声]") })
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("好啊\n[心声：其实很开心]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.row.string("inner"), "其实很开心")
    }

    func testApartIsOneMoreRequest() async throws {
        try setMode("apart")
        XCTAssertEqual(ExtraCalls.active(.load()).map(\.id), ["inner"])
        MockNet.reset { _, n in .init(status: 200, body: MockNet.anthropicStream(n == 1 ? "好啊\n走吧" : "想多待一会儿")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 2)
        let last = try XCTUnwrap(Repo.messages(chatId: "chat_a").last)
        XCTAssertEqual(last.content, "走吧")
        XCTAssertEqual(last.row.string("inner"), "想多待一会儿")
    }

    /// 单独生成失败：这一轮照样落下，心声那一次只打一次。
    func testApartFailureKeepsTurn() async throws {
        try setMode("apart")
        MockNet.reset { _, n in n == 1 ? .init(status: 200, body: MockNet.anthropicStream("好啊")) : .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 2)
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.content, "好啊")
    }

    func testOffByDefault() throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertEqual(InnerVoice.mode(chat), "off")
        XCTAssertTrue(ExtraCalls.active(.load()).isEmpty)
    }
}
