import XCTest
@testable import Eira

/// 草稿箱：[草稿：…] 不落进聊天；会话开了才存、才写进提示词；默认关；不多调接口。
final class DraftsTests: StoreTestCase {
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

    func testParse() {
        XCTAssertEqual(ReplyParser.split("嗯\n[草稿：其实想你了]").parts.map(\.type), [.text, .draft])
    }

    func testOffByDefault() async throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertFalse(Drafts.on(chat))
        let built = try ChatPrompt.build(chat: chat, char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertFalse(built.system.contains("[草稿"))
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("好\n[草稿：其实想你了]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertTrue(Drafts.list("chat_a").isEmpty)
        XCTAssertFalse(try Repo.messages(chatId: "chat_a").contains { $0.content.contains("想你") })
    }

    func testStoredWhenOn() async throws {
        try Drafts.setOn("chat_a", true)
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let built = try ChatPrompt.build(chat: chat, char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertTrue((built.system + built.messages.map(\.content).joined()).contains("[草稿："))
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("好\n[草稿：其实想你了]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(Drafts.list("chat_a").map { $0.string("text") }, ["其实想你了"])
        XCTAssertFalse(try Repo.messages(chatId: "chat_a").contains { $0.content.contains("想你") })
    }
}
