import XCTest
@testable import Eira

/// 好友与拉黑：角色拉黑或删了你时不调接口、你发的不进历史；好友申请没通过那一轮不送达；
/// 你拉黑角色时照常回复、每条标被拒收；角色写的标记重新生成时退回
final class TiesTests: StoreTestCase {
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

    private var chat: Chat { get throws { try XCTUnwrap(Repo.chat("chat_a")) } }

    func testCharBlockedMeMakesNoRequest() async throws {
        try Ties.set("char_a", Ties.me, "me_root", blocked: true, now: Date().millis - 1000)
        let sent = try ChatEngine.send(text: "在吗", chatId: "chat_a")
        XCTAssertEqual(Ties.rejectedOf(sent, chat: try chat), "blocked")
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("不该出现")) }
        do { try await ChatEngine.reply(chatId: "chat_a") { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 0)
        // 被拒收的不进历史
        let built = try ChatPrompt.build(chat: try chat, char: try XCTUnwrap(Repo.character("char_a")), settings: AppSettings.load())
        XCTAssertFalse(built.messages.contains { $0.content.contains("在吗") })
        try Ties.forceUnblock(try chat)
        XCTAssertNil(Ties.charRejects(try chat))
    }

    func testFriendRequestNotAcceptedIsNotDelivered() async throws {
        try Ties.set("char_a", Ties.me, "me_root", removed: true)
        try Ties.request(try chat, text: "加回来吧")
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("不加")) }
        let before = try Repo.messages(chatId: "chat_a").count
        do { try await ChatEngine.reply(chatId: "chat_a") { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").count, before)
        XCTAssertNil(Ties.pendingRequest(try chat))

        try Ties.request(try chat, text: "")
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("[通过好友申请：小于]\n好吧")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertNil(Ties.charRejects(try chat))
        XCTAssertTrue(try Repo.messages(chatId: "chat_a").contains { $0.content.contains("通过了你的好友申请") })
    }

    func testUserBlocksCharStillReplies() async throws {
        try Ties.userSet(try chat, blocked: true)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("怎么了")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        let last = try XCTUnwrap(Repo.messages(chatId: "chat_a").last)
        XCTAssertEqual(Ties.rejectedByMe(last, chat: try chat), "blocked")
        XCTAssertEqual(Ties.notes([last], chat: try chat)[last.id], "你已拉黑该角色，这条消息被拒收")
        // 它被拒收过一条之后才知道
        let facts = Ties.facts(try XCTUnwrap(Repo.character("char_a")), chat: try chat, userName: "小于")
        XCTAssertTrue(facts.contains { $0.contains("has blocked you") })
    }

    func testCharMarkAndUndoOnRegenerate() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("[拉黑：你]\n别找我")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(Ties.charRejects(try chat), "blocked")
        XCTAssertFalse(try Repo.messages(chatId: "chat_a").contains { $0.content.contains("拉黑") })
        // 重新生成那一轮：先解除才能调接口，这里直接看退回
        let turn = try XCTUnwrap(ChatEngine.lastTurn(chatId: "chat_a"))
        try Ties.undoTurn(turn.id)
        XCTAssertNil(Ties.charRejects(try chat))
    }
}
