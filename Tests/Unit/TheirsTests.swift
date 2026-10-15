import XCTest
@testable import Eira

/// 角色手机：锁屏密码按角色卡推（与网页版同一个散列）、提示与解开、备忘录与浏览记录追加、相册与密码本、代发与拒收、
/// 生成一项一次请求、聊天里的改密码（冷却、删提示放回）与存图
final class TheirsTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
        Theirs.relock("char_a")
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func reply(_ text: String) -> MockNet.Reply { .init(status: 200, body: MockNet.anthropicStream(text)) }

    private func patchChar(_ f: [String: JSONValue]) throws {
        var c = try XCTUnwrap(Repo.character("char_a"))
        for (k, v) in f { c.row[k] = v }
        try Database.shared.put(Collections.characters, c.row)
    }

    func testDateAndDigitParsing() {
        XCTAssertEqual(Theirs.mmdd("1999-03-14"), "0314")
        XCTAssertEqual(Theirs.mmdd("3月14日"), "0314")
        XCTAssertEqual(Theirs.mmdd("03/14"), "0314")
        XCTAssertEqual(Theirs.mmdd("19990314"), "0314")
        XCTAssertEqual(Theirs.mmdd("13/40"), "")
        XCTAssertEqual(Theirs.year("1999-03-14"), "1999")
        XCTAssertEqual(Theirs.fours("门牌 2046，电话 13800，车 7788"), ["2046", "7788"])
        // 与网页版 hashOf 逐位一致
        XCTAssertEqual(Theirs.hash("char_a:lock"), 2_362_788_269)
    }

    func testLocalLockFromCard() throws {
        // 没有生日也没有数字：按角色 id 推，与网页版同一串
        XCTAssertEqual(Theirs.lock("char_a")?.code, "4456")
        XCTAssertEqual(Theirs.lock("char_a")?.src, "random")
        // 有生日：生日与出生年份两样里，按角色 id 固定挑中同一个（网页版挑中年份）
        try patchChar(["birthday": .string("1999-03-14")])
        XCTAssertEqual(Theirs.lock("char_a")?.code, "1999")
        XCTAssertEqual(Theirs.lock("char_a")?.code, "1999")
        // 当场推的不写库
        XCTAssertNil(Theirs.get("char_a"))
    }

    func testHintsAndOpen() throws {
        try patchChar(["birthday": .string("1999-03-14")])
        XCTAssertFalse(Theirs.tryCode("char_a", "0000"))
        XCTAssertTrue(Theirs.tryCode("char_a", "1999"))
        XCTAssertEqual(try Theirs.nextHint("char_a"), "这串数字是一个年份。")
        XCTAssertEqual(Theirs.lock("char_a")?.shown, 1)
        // 问过一条之后存下来，改生日不换正在猜的这一串
        try patchChar(["birthday": .string("2001-05-20")])
        XCTAssertEqual(Theirs.lock("char_a")?.code, "1999")
        _ = try Theirs.nextHint("char_a"); _ = try Theirs.nextHint("char_a")
        XCTAssertNil(try Theirs.nextHint("char_a"))
        XCTAssertFalse(Theirs.isOpen("char_a"))
        Theirs.open("char_a")
        XCTAssertTrue(Theirs.isOpen("char_a"))
        Theirs.relock("char_a")
        XCTAssertFalse(Theirs.isOpen("char_a"))
    }

    func testNotesVisitsAlbum() throws {
        XCTAssertEqual(try Theirs.addNotes("char_a", [.object(["title": .string("买菜"), "text": .string("葱")]), .object(["title": .string("")])]), 1)
        try Theirs.addNotes("char_a", [.object(["title": .string("第二条")])])
        XCTAssertEqual(Theirs.notes("char_a").map(\.title), ["买菜", "第二条"])
        try Theirs.addVisits("char_a", [.object(["query": .string("旧的")])])
        try Theirs.addVisits("char_a", [.object(["query": .string("新的"), "site": .string("百科")])])
        XCTAssertEqual(Theirs.visits("char_a").map(\.query), ["新的", "旧的"])
        try Theirs.removeVisit("char_a", at: 0)
        XCTAssertEqual(Theirs.visits("char_a").map(\.query), ["旧的"])

        let book = try Theirs.addAlbum("char_a", name: "去年夏天", code: "0707")
        try Theirs.addPhotos("char_a", [.object(["note": .string("海边")])], albumId: book.id)
        XCTAssertEqual(Theirs.inAlbum("char_a", book.id).count, 1)
        XCTAssertFalse(Theirs.albumOpen("char_a", book.id))
        XCTAssertFalse(Theirs.openAlbum("char_a", book.id, code: "1111"))
        XCTAssertTrue(Theirs.openAlbum("char_a", book.id, code: "0707"))
        try Theirs.removeAlbum("char_a", book.id)
        XCTAssertEqual(Theirs.inAlbum("char_a", "").map(\.note), ["海边"])
    }

    func testStartChatAndProxyRejected() throws {
        let c = try Theirs.startChat("char_a", npcId: "", name: "同事")
        XCTAssertThrowsError(try Theirs.startChat("char_a", npcId: "", name: "同事"))
        XCTAssertEqual(try Theirs.sendOther(c.id, "明天见", mode: Theirs.proxyAware), "")
        XCTAssertEqual(Theirs.chat(c.id)?.lines.last?.proxy, Theirs.proxyAware)
        XCTAssertEqual(Theirs.proxyMode("char_a"), Theirs.proxyAware)
        XCTAssertEqual(Theirs.chat(c.id)?.preview, "明天见")
    }

    /// 生成一项一次请求；接口一直失败时也只打一次
    func testMakeOneCallEach() async throws {
        do { _ = try await Theirs.makeNotes("char_a", count: 3); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        MockNet.reset { _, _ in self.reply(#"{"chats":[{"name":"小于","preview":"在吗"},{"name":"宝贝","preview":"想你"},{"name":"阿明","preview":"明天开会"}]}"#) }
        let made = try await Theirs.makeChats("char_a", count: 3)
        XCTAssertEqual(made, 1)
        XCTAssertEqual(MockNet.count, 1)
        // 你的名字、爱称都不算另一个联系人
        XCTAssertEqual(Theirs.chatsOf("char_a").map(\.name), ["阿明"])
        MockNet.reset { _, _ in self.reply(#"{"code":"123","why":"x","hints":["a"]}"#) }
        do { _ = try await Theirs.makeLock("char_a", digits: 4); XCTFail("位数不对应当不收") } catch {}
        XCTAssertEqual(Theirs.lock("char_a")?.code, "4456")
        MockNet.reset { _, _ in self.reply(#"{"code":"0520","why":"纪念日","hints":["一","二","三"]}"#) }
        let digits = try await Theirs.makeLock("char_a", digits: 4)
        XCTAssertEqual(digits, 4)
        XCTAssertEqual(Theirs.lock("char_a")?.code, "0520")
        XCTAssertEqual(Theirs.lock("char_a")?.src, "ai")
    }

    func testLockcodeMarkerCooldownAndUndo() async throws {
        Theirs.open("char_a")
        MockNet.reset { _, _ in self.reply("好\n[改密码：0520｜纪念日]") }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(Theirs.lock("char_a")?.code, "0520")
        XCTAssertEqual(Theirs.lock("char_a")?.src, "char")
        XCTAssertFalse(Theirs.isOpen("char_a"))
        let notice = try XCTUnwrap(Repo.messages(chatId: "chat_a").last { $0.row["lockUndo"] != nil })
        XCTAssertFalse(notice.content.contains("0520"))
        // 不满冷却天数、也没聊到密码：再写一次当没写过
        MockNet.reset { _, _ in self.reply("[改密码：1111｜随便]") }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(Theirs.lock("char_a")?.code, "0520")
        // 删掉那一行提示：放回换之前的那一份
        try Interact.drop(notice)
        XCTAssertEqual(Theirs.lock("char_a")?.code, "4456")
    }

    func testKeepMarkerSavesJustSentImage() async throws {
        var m = Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "[图片：海]", kind: "image")
        m.row["imageId"] = .string("img_a")
        _ = try Repo.append(m)
        MockNet.reset { _, _ in self.reply("好看\n[存图：那天的海]") }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let p = try XCTUnwrap(Theirs.photos("char_a").first)
        XCTAssertEqual(p.note, "那天的海")
        XCTAssertEqual(p.imageId, "img_a")
        XCTAssertEqual(p.from, "you")
        XCTAssertTrue(try Repo.messages(chatId: "chat_a").contains { $0.content == "[林把这张照片存了下来]" })
    }

    /// 存图默认不进提示词（相册页上为该角色开启才进）；改密码冷却够了就进
    func testCapsInPrompt() throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a")), char = try XCTUnwrap(Repo.character("char_a"))
        var sys = try ChatPrompt.build(chat: chat, char: char, settings: .load()).system
        XCTAssertFalse(sys.contains("[存图"))
        XCTAssertTrue(sys.contains("[改密码"))
        try Theirs.setKeepOn("char_a", true)
        sys = try ChatPrompt.build(chat: chat, char: char, settings: .load()).system
        XCTAssertTrue(sys.contains("[存图"))
    }

    /// 代发进双方的提示词：代发的那句与对方紧接着回的；知道的点明是代发，不知道的写成它自己发的；对方那边也记得
    func testProxyFacts() throws {
        var other = try XCTUnwrap(Repo.character("char_a")).row
        other["id"] = .string("char_b"); other["name"] = .string("阿明")
        try Database.shared.put(Collections.characters, other)
        let c = try Theirs.startChat("char_a", npcId: "char_b", name: "阿明")
        _ = try Theirs.sendOther(c.id, "明天见", mode: Theirs.proxyUnaware)
        try Theirs.addLine(c.id, ["from": .string("other"), "text": .string("好"), "re": .bool(true)])
        try Theirs.addLine(c.id, ["from": .string("other"), "text": .string("生成的背景"), "re": .bool(false)])
        let me = try XCTUnwrap(Repo.character("char_a")), b = try XCTUnwrap(Repo.character("char_b"))
        let s = AppSettings.load()
        XCTAssertEqual(Theirs.factsForSender(me, personaId: "me_root", userName: "小于", settings: s),
                       ["You sent to 阿明: 「明天见」", "阿明 replied: 「好」"])
        XCTAssertEqual(Theirs.factsForRecipient(b, settings: s), ["林 messaged you: 「明天见」", "You replied to 林: 「好」"])
        _ = try Theirs.sendOther(c.id, "是我", mode: Theirs.proxyAware)
        XCTAssertTrue(Theirs.proxyBlock(char: me, personaId: "me_root", userName: "小于", settings: s)
            .contains("小于 logged into your account and sent to 阿明 as you: 「是我」"))
    }
}
