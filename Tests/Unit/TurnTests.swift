import XCTest
@testable import Eira

/// 重新生成、切换版本，以及长按菜单里的撤回、编辑、删除、引用。
final class TurnTests: StoreTestCase {
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

    private func charRows() throws -> [Message] { try Repo.messages(chatId: "chat_a").filter { $0.role == .char } }

    func testLastTurnOfImportedChat() throws {
        let t = try XCTUnwrap(ChatEngine.lastTurn(chatId: "chat_a"))
        XCTAssertEqual(t.id, "turn_1")
        XCTAssertEqual(t.rows.map(\.id), ["msg_2", "msg_3"])
        // 老数据没有 swipes：把这一轮的正文当作唯一的版本
        XCTAssertEqual(t.versions.swipes.count, 1)
    }

    func testRegenerateReplacesTurnAndAddsVersion() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("新的一句\n第二句")) }
        try await ChatEngine.reply(chatId: "chat_a", regenerate: true) { _ in }
        XCTAssertEqual(MockNet.count, 1)
        // 请求里不含被重写的那一轮
        let body = String(data: MockNet.requests[0].httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("在呢"))

        let rows = try charRows()
        XCTAssertEqual(rows.map(\.content), ["新的一句", "第二句"])
        XCTAssertTrue(rows.allSatisfy { $0.turnId == "turn_1" })
        let t = try XCTUnwrap(ChatEngine.lastTurn(chatId: "chat_a"))
        XCTAssertEqual(t.versions.swipes.count, 2)
        XCTAssertEqual(t.versions.index, 1)
        XCTAssertEqual(t.versions.served.count, 1)   // 老的那一版没有记用的哪套接口
    }

    /// 重新生成失败：原来那一轮一条不少，也不写失败的消息。
    func testRegenerateFailureKeepsOldTurn() async throws {
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { try await ChatEngine.reply(chatId: "chat_a", regenerate: true) { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(try charRows().map(\.id), ["msg_2", "msg_3"])
        XCTAssertFalse(try Repo.messages(chatId: "chat_a").contains { $0.isError })
    }

    /// 模型只回了思考、没有正文：同样不动原来那一轮。
    func testRegenerateEmptyKeepsOldTurn() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("<think>想了想</think>")) }
        do { try await ChatEngine.reply(chatId: "chat_a", regenerate: true) { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(try charRows().map(\.id), ["msg_2", "msg_3"])
    }

    /// 切换版本不调接口。
    func testSwitchVersionMakesNoRequest() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("第二版")) }
        try await ChatEngine.reply(chatId: "chat_a", regenerate: true) { _ in }
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("不该出现")) }

        try await ChatEngine.switchVersion(chatId: "chat_a", step: -1) { _ in }
        XCTAssertEqual(MockNet.count, 0)
        XCTAssertEqual(try charRows().map(\.content), ["在呢", "[图片：一只猫]"])
        XCTAssertEqual(try ChatEngine.lastTurn(chatId: "chat_a")?.versions.index, 0)

        try await ChatEngine.switchVersion(chatId: "chat_a", step: 1) { _ in }
        XCTAssertEqual(try charRows().map(\.content), ["第二版"])
        XCTAssertEqual(MockNet.count, 0)
    }

    func testRecallMine() throws {
        let mine = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.id == "msg_1" })
        XCTAssertTrue(MessageActions.canRecall(mine))
        let out = try MessageActions.recall(mine)
        XCTAssertTrue(out.isRecalled)
        XCTAssertEqual(out.recalledBy, "user")
        // 角色已经回过：算读到了，进上下文时带原文
        XCTAssertEqual(out.row["recalled"]?["seen"]?.bool, true)
        let b = try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertTrue(b.messages.contains { $0.content.contains("[撤回了一条消息：你好]") })
        // 角色的消息不能由我撤回
        XCTAssertFalse(MessageActions.canRecall(try XCTUnwrap(charRows().first)))
    }

    func testCharRecallFoldsLater() {
        var m = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "说漏了")
        m.row["recalled"] = .object(["at": .number(Date().millis + 2500), "by": .string("char")])
        XCTAssertFalse(m.isRecalled)
        XCTAssertTrue(m.isRecalled(at: Date().addingTimeInterval(3)))
        XCTAssertGreaterThan(m.recallWait, 2)
    }

    func testEdit() throws {
        let m = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.id == "msg_1" })
        _ = try MessageActions.edit(m, text: "改过的")
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").first { $0.id == "msg_1" }?.content, "改过的")
        // 图片消息不能编辑正文
        XCTAssertFalse(MessageActions.canEdit(try XCTUnwrap(charRows().last)))
    }

    /// 删掉一轮里带着各个版本的第一条：版本挪到同一轮的下一条上，还能接着重新生成与切换。
    func testDeleteHeadKeepsVersions() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("一\n二")) }
        try await ChatEngine.reply(chatId: "chat_a", regenerate: true) { _ in }
        let head = try XCTUnwrap(charRows().first)
        XCTAssertNotNil(head.row["swipes"])
        try MessageActions.delete(head)
        XCTAssertEqual(try charRows().map(\.content), ["二"])
        XCTAssertEqual(try ChatEngine.lastTurn(chatId: "chat_a")?.versions.swipes.count, 2)
    }

    func testQuoteSendsFieldsAndReachesModel() throws {
        let q = try XCTUnwrap(charRows().first)
        let m = try ChatEngine.send(text: "这句什么意思", chatId: "chat_a", quote: q)
        XCTAssertEqual(m.row.string("quoteId"), q.id)
        XCTAssertEqual(m.row.string("quoteRole"), "char")
        let b = try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertTrue(b.messages.contains { $0.content.contains("[引用：在呢]\n这句什么意思") })
    }
}
