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

    private func configure(api: Bool, lang: String = "English") throws {
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
        c.row["translateTo"] = .string(lang)
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

    /// 网页版 4.570：已经是目标语言的句子不送去翻；整轮都是，就不调翻译接口
    func testAlreadyInTargetSkipsRequest() async throws {
        try configure(api: true, lang: "中文")
        MockNet.reset { r, _ in
            if r.url?.host == "tr.test" { return .init(status: 200, body: MockNet.anthropicStream(#"{"lines":["你好"]}"#)) }
            return .init(status: 200, body: MockNet.anthropicStream("你好\n再见"))
        }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.requests.filter { $0.url?.host == "tr.test" }.count, 0, "说中文、译成中文，不调翻译接口")
        XCTAssertEqual(MockNet.requests.filter { $0.url?.host == "main.test" }.count, 1)
    }

    func testOnlyForeignLinesAreSent() async throws {
        try configure(api: true)
        MockNet.reset { r, _ in
            if r.url?.host == "tr.test" { return .init(status: 200, body: MockNet.anthropicStream(#"{"lines":["Hello there"]}"#)) }
            return .init(status: 200, body: MockNet.anthropicStream("Good morning\n你好呀"))
        }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let tr = MockNet.requests.filter { $0.url?.host == "tr.test" }
        XCTAssertEqual(tr.count, 1)
        let body = String(data: try XCTUnwrap(tr.first?.httpBodyStreamData()), encoding: .utf8) ?? ""
        let sent = try JSONValue.parse(Data(body.utf8))["messages"]?.array?.first?["content"]?.string ?? ""
        XCTAssertEqual(sent, "1. 你好呀", "已经是英文的那一句不送")
        let rows = try Repo.messages(chatId: "chat_a").filter { $0.role == .char }
        XCTAssertEqual(rows.first { $0.content == "你好呀" }?.row.string("translation"), "Hello there")
        XCTAssertEqual(rows.first { $0.content == "Good morning" }?.row.string("translation"), "")
    }

    func testAlreadyIn() {
        XCTAssertTrue(TranslateOne.alreadyIn("我好想你", "中文"))
        XCTAssertTrue(TranslateOne.alreadyIn("我们周末去 Costco 买东西吗", "中文"), "夹一个拉丁词仍算中文（汉字数的两倍不少于字母数，同网页版）")
        XCTAssertFalse(TranslateOne.alreadyIn("宝贝我好想你 my love", "中文"))
        XCTAssertFalse(TranslateOne.alreadyIn("想你了，мой милый", "中文"))
        XCTAssertTrue(TranslateOne.alreadyIn("See you", "English"))
        XCTAssertFalse(TranslateOne.alreadyIn("你好", "English"))
        XCTAssertTrue(TranslateOne.alreadyIn("おはよう", "日语"))
        XCTAssertFalse(TranslateOne.alreadyIn("Bonjour", "法语"), "看不出来的照旧翻")
    }
}
