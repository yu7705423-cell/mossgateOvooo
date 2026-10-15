import XCTest
@testable import Eira

/// HTML 卡片：整段摘出来落成一条、按字段读值、模板填值时转义、清洗拿掉脚本与外链、命中了才进提示词。
final class HtmlCardTests: StoreTestCase {
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

    func testLiftWithEnd() {
        let r = ReplyParser.split("看这个\n[卡片：微博]\n昵称：小林\n正文：今天 #下雨# 了\n[/卡片]\n好吧", autoSplitAt: 0)
        XCTAssertEqual(r.parts.map(\.type), [.text, .card, .text])
        XCTAssertEqual(r.parts[1].text, "微博")
        XCTAssertEqual(r.parts[1].extra, "昵称：小林\n正文：今天 #下雨# 了")
    }

    func testLiftWithoutEnd() {
        let r = ReplyParser.split("[卡片：微博]\n昵称：小林\n正文：嗯\n然后呢", autoSplitAt: 0)
        XCTAssertEqual(r.parts.map(\.type), [.card, .text])
        XCTAssertEqual(r.parts[1].text, "然后呢")
    }

    func testBuiltinFields() throws {
        let e = try XCTUnwrap(HtmlCard.builtinEntries.first { $0["comment"]?.string == "微博" })
        let entry = HtmlCard.Entry(json: e, bookId: HtmlCard.builtinBookId)
        let hot = try XCTUnwrap(entry.fields.first { $0.name == "热评" })
        XCTAssertTrue(hot.list)
        XCTAssertEqual(hot.sub, ["昵称", "内容", "点赞"])
        let v = HtmlCard.parseValues("昵称：小林\n热评：甲｜好看｜12\n热评：乙｜一般｜3", fields: entry.fields)
        XCTAssertEqual(v["昵称"], .string("小林"))
        XCTAssertEqual(v["热评"]?.array?.count, 2)
        XCTAssertEqual(v["热评"]?.array?.first?["内容"], .string("好看"))
        XCTAssertTrue(HtmlCard.block(name: "微博", values: v, fields: entry.fields).contains("热评：甲｜好看｜12"))
    }

    func testFillEscapes() {
        let card: [String: JSONValue] = ["html": .string("<p>{{正文}}</p>")]
        let doc = HtmlCard.doc(card, values: ["正文": .string("<script>alert(1)</script>")], sys: [:], dark: false)
        XCTAssertFalse(doc.contains("<script>alert"))
        XCTAssertTrue(doc.contains("&lt;script&gt;"))
        XCTAssertTrue(doc.contains("script-src 'none'"))
    }

    func testNoPlaceholderInUrl() {
        let card: [String: JSONValue] = ["html": .string("<img src=\"https://x.test/{{u}}\"><b>{{u}}</b>")]
        XCTAssertFalse(HtmlCard.problems(card["html"]!.string!, images: false).isEmpty)
        let filled = HtmlCard.fill(card, values: ["u": .string("secret")], sys: [:])
        XCTAssertEqual(filled.components(separatedBy: "secret").count, 2, "只填进正文那一处")
    }

    func testSanitize() {
        let s = HtmlCard.sanitize(#"<img src="http://x.test/a.png" onclick="x()"><a href="https://e.test">a</a><script>1</script><iframe src="https://e.test"></iframe><img src="data:image/png;base64,AA">"#, images: false)
        XCTAssertFalse(s.contains("onclick"))
        XCTAssertFalse(s.contains("http://x.test"))
        XCTAssertFalse(s.contains("https://e.test"))
        XCTAssertFalse(s.contains("<script"))
        XCTAssertFalse(s.contains("<iframe"))
        XCTAssertTrue(s.contains("data:image/png"))
    }

    func testPromptOnlyWhenHit() throws {
        try setSettings(["builtinCards": .object(["global": .bool(true)])])
        let char = try XCTUnwrap(Repo.character("char_a"))
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        var built = try ChatPrompt.build(chat: chat, char: char, settings: .load())
        XCTAssertFalse(built.system.contains("[卡片]"))
        _ = try Repo.append(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "刚刷到一条微博"))
        chat = try XCTUnwrap(Repo.chat("chat_a"))
        built = try ChatPrompt.build(chat: chat, char: char, settings: .load())
        XCTAssertTrue(built.system.contains("[卡片：card name]"))
        XCTAssertTrue(built.system.contains("· 微博"))
        XCTAssertFalse(built.system.contains("<style"), "模板不进提示词")
    }

    func testEngineStoresCard() async throws {
        try setSettings(["builtinCards": .object(["global": .bool(true)])])
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("你看\n[卡片：微博]\n昵称：林\n正文：今天下雨\n[/卡片]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let msgs = try Repo.messages(chatId: "chat_a")
        let card = try XCTUnwrap(msgs.last { $0.kind == "card" })
        XCTAssertTrue(card.content.hasPrefix("[卡片：微博]"))
        XCTAssertEqual(card.row["card"]?["bookId"], .string(HtmlCard.builtinBookId))
        XCTAssertEqual(card.row["card"]?["values"]?["昵称"], .string("林"))
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(MsgPreview.text(card).hasPrefix("[卡片] 微博"))
    }
}
