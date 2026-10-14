import XCTest
@testable import Eira

/// 关系底色：默认不压；开着时 S 级记忆变了才压；接口一直失败时同一份记忆只压一次。
final class BondTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        try Database.shared.put(Collections.memories, Row.new(prefix: "mem", [
            "charId": .string("char_a"), "personaId": .string(chat.personaId), "rank": .string("S"),
            "content": .string("两人确认了关系"), "kind": .string("event")]))
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func isBond(_ r: URLRequest) -> Bool {
        guard let body = r.httpBodyStreamData(), let s = String(data: body, encoding: .utf8) else { return false }
        return s.contains("两人确认了关系")
    }

    private func bondSig() throws -> String {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let key = try MemorySummary.stateKey(chat.personaId)
        return try XCTUnwrap(Repo.character("char_a")).row["bonds"]?[key]?["sig"]?.string ?? ""
    }

    func testOffByDefault() async throws {
        XCTAssertFalse(ExtraCalls.switchedOn(.load()).contains { $0.id == "bondAuto" })
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("好")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(try bondSig(), "")
    }

    /// 接口一直失败：第一条消息压一次（先记签名），第二条不再压；记忆变了才再压。
    func testFailingApiTriesOncePerChange() async throws {
        try setSettings(["bondAuto": .bool(true)])
        XCTAssertTrue(ExtraCalls.switchedOn(.load()).contains { $0.id == "bondAuto" })
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        _ = await Bond.autoRun(charId: "char_a", personaId: chat.personaId)
        XCTAssertEqual(MockNet.requests.filter(isBond).count, 1)
        XCTAssertFalse(try bondSig().isEmpty)
        let again = await Bond.autoRun(charId: "char_a", personaId: chat.personaId)
        XCTAssertFalse(again)
        XCTAssertEqual(MockNet.requests.filter(isBond).count, 1)

        // 新增一条 S 级记忆：签名变了，再压一次
        try Database.shared.put(Collections.memories, Row.new(prefix: "mem", [
            "charId": .string("char_a"), "rank": .string("S"), "content": .string("两人确认了关系之后搬到一起"), "kind": .string("event")]))
        _ = await Bond.autoRun(charId: "char_a", personaId: chat.personaId)
        XCTAssertEqual(MockNet.requests.filter(isBond).count, 2)
    }

    /// 压成功：写进底色与「你们之间」，提示词里读得到；锁住的「你们之间」不动。
    func testSuccessWritesUsBlock() async throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("两人已经在一起。")) }
        try await Bond.refresh(charId: "char_a", personaId: chat.personaId)
        let key = try MemorySummary.stateKey(chat.personaId)
        let c = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(c.row["bonds"]?[key]?["text"]?.string, "两人已经在一起。")
        XCTAssertEqual(c.row["states"]?[key]?["blocks"]?["us"]?.string, "两人已经在一起。")
        XCTAssertTrue(try ChatPrompt.build(chat: chat, char: c, settings: .load()).system.contains("两人已经在一起。"))
    }
}
