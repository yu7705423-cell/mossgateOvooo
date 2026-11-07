import XCTest
@testable import Eira

/// 短信（网页版 4.307、4.392）：号码、身份状态、标记、角色发短信只发给有过往来的号码、拦截、提示词里的身份隔离。
final class SmsTests: StoreTestCase {
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

    private func lin() throws -> Character { try XCTUnwrap(Repo.character("char_a")) }

    private func thread() throws -> Row {
        try Sms.open(mine: PhoneNum.mine("me_root")[0], theirs: PhoneNum.numberOf("char_a"), personaId: "me_root")
    }

    func testNumbers() throws {
        XCTAssertEqual(PhoneNum.digits("(212) 555-0101"), "2125550101")
        XCTAssertTrue(PhoneNum.same("138 0000 0000", "13800000000"))
        XCTAssertFalse(PhoneNum.same("", ""))
        XCTAssertNotNil(PhoneNum.generate("Asia/Tokyo").range(of: #"^0[789]0-\d{4}-\d{4}$"#, options: .regularExpression))
        XCTAssertNotNil(PhoneNum.generate("").range(of: #"^1[35789]\d \d{4} \d{4}$"#, options: .regularExpression))
        XCTAssertNotNil(PhoneNum.generate("Mars/Base").range(of: #"^1[35789]\d \d{4} \d{4}$"#, options: .regularExpression), "认不出的时区按中国大陆")
        let n = PhoneNum.numberOf("char_a")
        XCTAssertFalse(n.isEmpty)
        XCTAssertEqual(PhoneNum.numberOf("char_a"), n, "第一次生成后存下")
        XCTAssertEqual(try Repo.character("char_a")?.row.string("phoneNumber"), n)
        XCTAssertEqual(PhoneNum.ownerOf(PhoneNum.digits(n))?.id, "char_a")
        // 我的号码：第一个自动生成，可以再加；重复的不加；至少留一个
        let mine = PhoneNum.mine("me_root")
        XCTAssertEqual(mine.count, 1)
        XCTAssertEqual(try Repo.personas().first { $0.id == "me_root" }?.row.strings("phones"), mine)
        try PhoneNum.addMine("139 1111 2222", "me_root")
        XCTAssertThrowsError(try PhoneNum.addMine("13911112222", "me_root"))
        XCTAssertEqual(PhoneNum.mine("me_root").count, 2)
        try PhoneNum.removeMine("13911112222", "me_root")
        XCTAssertThrowsError(try PhoneNum.removeMine(mine[0], "me_root"))
        // 别的字段写回去不丢
        XCTAssertEqual(try Repo.personas().first { $0.id == "me_root" }?.row.string("description"), "USER_DESC")
    }

    func testIdentityStates() throws {
        let mine = PhoneNum.mine("me_root")[0]
        let t = try thread()
        XCTAssertEqual(t.string("charId"), "char_a")
        XCTAssertEqual(try Sms.open(mine: PhoneNum.digits(mine), theirs: PhoneNum.digits(PhoneNum.numberOf("char_a")), personaId: "me_root").id, t.id,
                       "同一对号码是同一段，写法不同也算")
        XCTAssertFalse(Sms.isKnown(t))
        try Sms.guess(t.id, name: "小于", turnId: "turn_1")
        XCTAssertEqual(Sms.get(t.id)?.string("guess"), "小于")
        try Sms.undoTurn(chatId: t.id, turnId: "turn_1")
        XCTAssertEqual(Sms.get(t.id)?.string("guess"), "", "重新生成那一轮：认出那一句撤回")
        // 存过这个号码，等同于表明过身份（4.392）
        try PhoneNum.setSaved(mine, "char_a", true, "me_root")
        XCTAssertEqual(PhoneNum.savedBy(mine, "me_root"), ["char_a"])
        XCTAssertTrue(Sms.isKnown(try XCTUnwrap(Sms.get(t.id))))
        try PhoneNum.setSaved(mine, "char_a", false, "me_root")
        XCTAssertFalse(Sms.isKnown(try XCTUnwrap(Sms.get(t.id))))
        try Sms.confirm(t.id)
        XCTAssertTrue(Sms.isKnown(try XCTUnwrap(Sms.get(t.id))))
        // 已经知道是你时，认出不再记
        try Sms.guess(t.id, name: "别人")
        XCTAssertEqual(Sms.get(t.id)?.string("guess"), "")
    }

    func testMarksParse() {
        let r = ReplyParser.split("好\n[发短信：138 0000 0000|在吗]\n[借号发短信：老周｜139|到了]\n[认出：小于]")
        let sms = r.parts.filter { $0.type == .sms }
        XCTAssertEqual(sms.map(\.extra), ["发短信", "借号发短信", "认出"])
        XCTAssertEqual(sms.map(\.text), ["138 0000 0000|在吗", "老周｜139|到了", "小于"])
        XCTAssertEqual(r.parts.filter { $0.type == .text }.map(\.text), ["好"])
        // 网页版的结果换成同样的 Part
        let (parts, unmapped) = WebLogic.map([["type": "sms", "kind": "认出", "body": "小于"]])
        XCTAssertEqual(parts.first?.type, .sms)
        XCTAssertEqual(parts.first?.extra, "认出")
        XCTAssertEqual(parts.first?.text, "小于")
        XCTAssertTrue(unmapped.isEmpty)
    }

    func testCharSendOnlyKnownAndBlocked() throws {
        let lin = try lin()
        let mine = PhoneNum.mine("me_root")[0]
        XCTAssertNil(try Sms.charSend(char: lin, personaId: "me_root", body: "\(mine)|在吗"), "还没有往来：发不出去")
        let t = try thread()
        try Sms.send(t.id, text: "你好")
        XCTAssertNil(try Sms.charSend(char: lin, personaId: "me_root", body: "100 0000 0000|乱发"), "不认识的号码不发")
        let m = try XCTUnwrap(Sms.charSend(char: lin, personaId: "me_root", body: "\(mine)|在吗", turnId: "turn_x", fromChat: "chat_a"))
        XCTAssertEqual(m.chatId, t.id)
        XCTAssertEqual(m.row.string("fromChat"), "chat_a")
        XCTAssertEqual(Sms.get(t.id)?.number("unread"), 1)
        // 借号：只认关系网里有号码的 NPC，不临时造人（第 22 条）
        XCTAssertNil(try Sms.charSend(char: lin, personaId: "me_root", body: "\(mine)|借", borrow: "老周"))
        var npc = try People.createCharacter(name: "老周")
        npc.row["isNpc"] = .bool(true)
        npc.row["phoneNumber"] = .string("137 2222 3333")
        try Database.shared.put(Collections.characters, npc.row)
        var row = lin.row
        row["relations"] = .array([.object(["charId": .string(npc.id), "label": .string("朋友"), "circle": .string("同事")])])
        try Database.shared.put(Collections.characters, row)
        let lin2 = try XCTUnwrap(Repo.character("char_a"))
        let b = try XCTUnwrap(Sms.charSend(char: lin2, personaId: "me_root", body: "\(mine)|是我", borrow: "老周"))
        let bt = try XCTUnwrap(Sms.get(b.chatId))
        XCTAssertEqual(bt.string("via"), npc.id)
        XCTAssertTrue(PhoneNum.same(bt.string("theirs"), "13722223333"))
        XCTAssertEqual(bt.string("charId"), "char_a", "借号发来的仍由本人来回")
        XCTAssertEqual(SmsText.title(bt), bt.string("theirs"), "借号发来的只看得见号码")
        // 拦截：落进「已拦截」，记一笔失败，角色那边的事实里写明
        try Sms.setBlocked(PhoneNum.numberOf("char_a"), true, "me_root")
        let c = try XCTUnwrap(Sms.charSend(char: lin2, personaId: "me_root", body: "\(mine)|还在吗"))
        XCTAssertTrue(c.row.bool("intercepted"))
        XCTAssertEqual(Sms.intercepted("me_root").count, 1)
        XCTAssertFalse(Sms.visible(t.id).contains { $0.id == c.id })
        let facts = Sms.factsFor(lin2, personaId: "me_root", userName: "小于")
        XCTAssertTrue(facts[0].hasPrefix("You have exchanged SMS with these numbers: "))
        XCTAssertTrue(facts[0].contains("(identity not confirmed)"))
        XCTAssertTrue(facts.contains { $0.contains("failed to deliver: that number has been blocked by the recipient.") })
        let block = Sms.block(char: lin2, chat: try XCTUnwrap(Repo.chat("chat_a")), me: try Repo.activePersona())
        XCTAssertTrue(block.hasPrefix("\n\n[短信]\nYour own number: "))
        XCTAssertTrue(block.contains("Numbers of people in your relationships: 老周（同事） 137 2222 3333."))
        // 删一段：连同里面的消息
        try Sms.remove(t.id)
        XCTAssertNil(Sms.get(t.id))
        XCTAssertTrue(try Repo.messages(chatId: t.id).isEmpty)
    }

    func testPromptIdentityIsolation() throws {
        let t = try thread()
        try Sms.send(t.id, text: "你好，是我")
        let lin = try lin()
        var built = try Sms.build(thread: try XCTUnwrap(Sms.get(t.id)), char: lin, settings: .load())
        XCTAssertTrue(built.system.hasPrefix("[短信]\nYou are 林. This conversation takes place by SMS"))
        XCTAssertTrue(built.system.contains("has not been confirmed"))
        XCTAssertFalse(built.system.contains("[对方是谁]"), "身份没确认：不写成「对方是谁」")
        XCTAssertTrue(built.system.contains("[关于小于]"), "照样记得你，只是抬头写明是关于谁")
        XCTAssertTrue(built.system.contains("PINNED_MEMORY"), "记忆照常带着")
        XCTAssertTrue(built.system.contains("[认出]"), "身份没确认时给认出的写法")
        XCTAssertTrue(built.system.contains("[短信规则]\nEach reply is sent as 1 to 3 text messages"))
        XCTAssertFalse(built.system.contains("[转账"), "转账不在短信里说得通的那几样")
        XCTAssertEqual(built.messages.last?.role, .user)
        try Sms.confirm(t.id)
        built = try Sms.build(thread: try XCTUnwrap(Sms.get(t.id)), char: lin, settings: .load())
        XCTAssertTrue(built.system.contains("belongs to 小于"))
        XCTAssertTrue(built.system.contains("[对方是谁]"))
        XCTAssertFalse(built.system.contains("[认出]"))
        // 线上聊天里：有过往来就给发短信的写法与 [短信] 区块，没有认出
        let chat = try ChatPrompt.build(chat: try XCTUnwrap(Repo.chat("chat_a")), char: lin, settings: .load())
        XCTAssertTrue(chat.system.contains("[短信]\nYour own number"))
        XCTAssertTrue(chat.system.contains("[发短信"))
        XCTAssertFalse(chat.system.contains("[认出]"))
    }
}

/// 短信的花钱次数（第 15 条）：你点一次「回复」只打一次；角色在聊天里写的 [发短信] 搭在那一轮上，不另调
extension CostTests {
    private func smsThread() throws -> Row {
        try Sms.open(mine: PhoneNum.mine("me_root")[0], theirs: PhoneNum.numberOf("char_a"), personaId: "me_root")
    }

    func testSmsReplyIsOneRequestPerTap() async throws {
        let t = try smsThread()
        try Sms.send(t.id, text: "在吗")
        let chats = try Repo.chats().count
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        do { try await Sms.reply(threadId: t.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("在\n[认出：小于]")) }
        try await Sms.reply(threadId: t.id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(Sms.visible(t.id).map(\.content), ["在吗", "在"])
        XCTAssertEqual(Sms.get(t.id)?.string("guess"), "小于")
        XCTAssertEqual(try Repo.chats().count, chats, "短信不进会话列表")
        // 拦截了这个号码：一次都不调
        try Sms.setBlocked(t.string("theirs"), true, "me_root")
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("x")) }
        do { try await Sms.reply(threadId: t.id); XCTFail("应当拦下") } catch {}
        XCTAssertEqual(MockNet.count, 0)
    }

    func testChatReplySendsSmsInSameRequest() async throws {
        let mine = PhoneNum.mine("me_root")[0]
        let t = try smsThread()
        try Sms.send(t.id, text: "你好")
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("好\n[发短信：\(mine)|到家了]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        let sent = try XCTUnwrap(Sms.visible(t.id).last)
        XCTAssertEqual(sent.content, "到家了")
        XCTAssertEqual(sent.row.string("fromChat"), "chat_a")
        XCTAssertFalse(try Repo.messages(chatId: "chat_a").contains { $0.content.contains("到家了") }, "这一段一个字都不落")
        // 重新生成那一轮：发出去的那一条撤回
        try Sms.undoTurn(chatId: "chat_a", turnId: sent.turnId)
        XCTAssertNil(Sms.visible(t.id).first { $0.content == "到家了" })
    }
}
