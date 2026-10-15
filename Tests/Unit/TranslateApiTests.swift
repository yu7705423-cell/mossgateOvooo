import XCTest
@testable import Eira

/// 单独的翻译接口：默认随回复一起（不多调）；选了单独接口，模型不写译文，一轮之后一批一次另翻，写回各条
final class TranslateApiTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func configure(api: Bool) throws {
        var services: [String: JSONValue] = ["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])]
        if api {
            services["translate"] = .object(["mode": .string("api"), "provider": .string("anthropic"),
                                             "baseUrl": .string("https://tr.test"), "apiKey": .string("k"), "model": .string("t")])
        }
        try setSettings(["services": .object(services)])
        var c = try XCTUnwrap(Repo.chat("chat_a"))
        c.row["translateTo"] = .string("English")
        try Repo.save(c)
    }

    func testInlineByDefault() async throws {
        try configure(api: false)
        XCTAssertEqual(AppSettings.load().translateMode, "inline")
        XCTAssertFalse(ExtraCalls.switchedOn(.load()).contains { $0.id == "translateApi" })
        let built = try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertTrue(built.system.contains("[顺带给出译文]"))
    }

    func testApiTranslatesOncePerTurn() async throws {
        try configure(api: true)
        XCTAssertEqual(AppSettings.load().translateMode, "api")
        let built = try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertFalse(built.system.contains("[顺带给出译文]"))
        MockNet.reset { r, _ in
            if r.url?.host == "tr.test" { return .init(status: 200, body: MockNet.anthropicStream(#"{"lines":["Hi","Bye"]}"#)) }
            return .init(status: 200, body: MockNet.anthropicStream("你好\n再见"))
        }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.requests.filter { $0.url?.host == "tr.test" }.count, 1)
        let mine = try Repo.messages(chatId: "chat_a").filter { $0.role == .char && ["你好", "再见"].contains($0.content) }
        XCTAssertEqual(Set(mine.map { $0.row.string("translation") }), Set(["Hi", "Bye"]))
    }
}
