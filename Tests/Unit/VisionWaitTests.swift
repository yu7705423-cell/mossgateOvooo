import XCTest
@testable import Eira

/// 单独的识图接口那一档：发完图紧接着请角色回复（网页版 4.594，测试 visionwait）。
/// 回复等描述写回再发，模型收到的是 [图片：描述]，不是 [图片]；一轮仍只打一次聊天接口。
final class VisionWaitTests: StoreTestCase {
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

    /// 这一轮我发的一张图，还在识别
    private func pendingImage() throws -> Message {
        var m = Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "[图片]", kind: "image")
        m.row["imageId"] = .string("img_wait")
        m.row["vision"] = .string("pending")
        return try Repo.append(m)
    }

    private static func finish(_ id: String, _ desc: String) throws {
        var row = try XCTUnwrap(Database.shared.get(Collections.messages, id: id))
        row["imageDesc"] = .string(desc)
        row["vision"] = .string("done")
        row["content"] = .string("[图片：\(desc)]")
        try Database.shared.put(Collections.messages, row)
    }

    func testReplyWaitsForDescription() async throws {
        let img = try pendingImage()
        let id = img.id
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("看到了")) }
        // 识图在另一处跑：约 300 毫秒后写回描述
        let writer = Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? VisionWaitTests.finish(id, "一只猫趴在窗台上")
        }
        let start = Date()
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        _ = await writer.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25, "回复没有等识图写回")
        XCTAssertEqual(MockNet.count, 1, "一轮只打一次聊天接口")
        let body = String(data: try XCTUnwrap(MockNet.requests.first?.httpBodyStreamData()), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("一只猫趴在窗台上"), "请求里没有识图描述")
    }

    /// 没有在识别的图：不等
    func testNoPendingNoWait() async throws {
        let img = try pendingImage()
        try Self.finish(img.id, "一只猫")
        let waited = await Vision.settle(chatId: "chat_a")
        XCTAssertFalse(waited)
    }

    /// 超时照发：等满时限就不再等，图仍是 pending
    func testTimeoutGivesUp() async throws {
        let img = try pendingImage()
        let start = Date()
        let waited = await Vision.settle(chatId: "chat_a", timeoutMs: 400)
        XCTAssertTrue(waited)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(try Database.shared.get(Collections.messages, id: img.id)?.string("vision"), "pending")
    }

    /// 只看当前这一轮：角色回过之后，前面那张还挂着的不算
    func testOnlyCurrentTurn() throws {
        var old = Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "[图片]", kind: "image")
        old.row["vision"] = .string("pending")
        let char = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "好")
        var mine = Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "[图片]", kind: "image")
        mine.row["vision"] = .string("pending")
        let text = Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "看看这张")
        XCTAssertEqual(Vision.pendingInTurn([old, char, mine, text]), [mine.id])
        XCTAssertEqual(Vision.pendingInTurn([old, char]), [])
    }
}
