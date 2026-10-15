import XCTest
@testable import Eira

/// 转账、礼物、拍一拍、回应、改备注：解析、落库的样子与网页版一致；重新生成时处理记录退回去；一轮只调一次接口。
final class InteractTests: StoreTestCase {
    private let heart = "\u{2764}\u{FE0F}"
    private let thumbs = "\u{1F44D}"

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

    private func reply(_ text: String) async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream(text)) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
    }

    private func all() throws -> [Message] { try Repo.messages(chatId: "chat_a") }

    // MARK: - 解析

    func testParse() {
        let p = ReplyParser.split("好\n[转账：¥52.5 买奶茶]\n[礼物：盒子 | 一张纸条]\n[收款]\n[拆开]\n[拍一拍]\n[回应：\(heart)：在吗]\n[备注：小猫]").parts
        XCTAssertEqual(p.map(\.type), [.text, .transfer, .gift, .settle, .unwrap, .pat, .react, .remark])
        XCTAssertEqual(p[1].amount, 52.5)
        XCTAssertEqual(p[1].text, "买奶茶")
        XCTAssertEqual(p[2].text, "盒子")
        XCTAssertEqual(p[2].extra, "一张纸条")
        XCTAssertTrue(p[3].flag)
        XCTAssertTrue(p[4].flag)
        XCTAssertEqual(p[6].text, heart)
        XCTAssertEqual(p[6].extra, "在吗")
        XCTAssertEqual(p[7].text, "小猫")
        // 退回、拒收；金额读不出来的转账整条丢掉；回应里不是 emoji 的不认
        let q = ReplyParser.split("[退回]\n[拒收]\n[转账：很多]\n[回应：好：在吗]").parts
        XCTAssertEqual(q.map(\.type), [.settle, .unwrap, .text])
        XCTAssertFalse(q[0].flag)
        XCTAssertFalse(q[1].flag)
    }

    // MARK: - 角色那边

    /// 角色转账、送礼：落成网页版同样的消息，一轮只打一次接口。
    func testCharTransferAndGift() async throws {
        try await reply("给你\n[转账：88 生日快乐]\n[礼物：限量球鞋 | 一张手写的纸条]")
        XCTAssertEqual(MockNet.count, 1)
        let list = try all()
        let tr = try XCTUnwrap(list.last { $0.kind == "transfer" })
        XCTAssertEqual(tr.content, "[转账：88.00 生日快乐]")
        XCTAssertEqual(tr.row.string("transfer"), "pending")
        XCTAssertEqual(tr.row.number("amount"), 88)
        XCTAssertEqual(tr.row.string("currency"), "CNY")
        let g = try XCTUnwrap(list.last { $0.kind == "gift" })
        XCTAssertEqual(g.content, "[礼物：限量球鞋（未拆封）]")
        XCTAssertEqual(g.row.string("inner"), "一张手写的纸条")

        // 用户收下、拆开
        _ = try Repo.append(XCTUnwrap(Interact.settleTransfer(tr.id, take: true)))
        _ = try Repo.append(XCTUnwrap(Interact.settleGift(g.id, open: true)))
        let after = try all()
        XCTAssertEqual(after.first { $0.id == tr.id }?.content, "[转账：88.00 生日快乐]（已被收下）")
        XCTAssertEqual(after.first { $0.id == g.id }?.content, "[礼物：限量球鞋，拆开是 一张手写的纸条]")
        XCTAssertTrue(after.contains { $0.kind == "notice" && $0.content.contains("收下了") && $0.content.contains("的转账 88.00") })
        // 同一笔不能处理两次
        XCTAssertNil(try Interact.settleTransfer(tr.id, take: false))
    }

    /// 用户转账，角色写 [收款]：那一笔变成已收下，落一行提示；删掉那一行，那一笔回到待收款。
    func testCharSettlesAndRegenerateUndoes() async throws {
        let tr = try ChatEngine.sendTransfer(chatId: "chat_a", amount: 20, note: "")
        XCTAssertEqual(tr.content, "[转账：20.00]")
        try await reply("[收款]\n谢谢")
        XCTAssertEqual(try all().first { $0.id == tr.id }?.row.string("transfer"), "taken")
        XCTAssertTrue(try all().contains { $0.kind == "notice" && $0.row.string("settledId") == tr.id })

        // 删掉提示行就回到待处理
        let notice = try XCTUnwrap(all().first { $0.kind == "notice" && $0.row.string("settledId") == tr.id })
        try MessageActions.delete(notice)
        XCTAssertEqual(try all().first { $0.id == tr.id }?.row.string("transfer"), "pending")
        XCTAssertEqual(try all().first { $0.id == tr.id }?.content, "[转账：20.00]")
    }

    func testRegenerateUndoesSettle() async throws {
        let g = try ChatEngine.sendGift(chatId: "chat_a", cover: "花", inner: "")
        XCTAssertEqual(g.content, "[礼物：花（未拆封）]")
        try await reply("[拆开]\n好看")
        XCTAssertEqual(try all().first { $0.id == g.id }?.row.string("gift"), "opened")
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("再想想")) }
        try await ChatEngine.reply(chatId: "chat_a", regenerate: true) { _ in }
        XCTAssertEqual(try all().first { $0.id == g.id }?.row.string("gift"), "pending")
        XCTAssertFalse(try all().contains { $0.kind == "notice" && $0.row.string("settledId") == g.id })
    }

    /// 没有待处理的就当没写过那一行。
    func testSettleWithoutPendingIsIgnored() async throws {
        try await reply("[收款]\n嗯")
        XCTAssertFalse(try all().contains { $0.kind == "notice" })
        XCTAssertEqual(try all().last?.content, "嗯")
    }

    // MARK: - 回应、拍一拍、备注、不回复

    func testReactPatRemark() async throws {
        let mine = try ChatEngine.send(text: "今天下雨了", chatId: "chat_a")
        try await reply("[回应：\(heart)：今天下雨]\n[拍一拍]\n[备注：小雨]\n带伞")
        let r = try XCTUnwrap(all().first { $0.id == mine.id }?.row["reactions"]?.array)
        XCTAssertEqual(r.first?["e"]?.string, heart)
        XCTAssertEqual(r.first?["by"]?.string, "char_a")
        XCTAssertTrue(try all().contains { $0.kind == "notice" && $0.row.bool("pat") && $0.content.contains("拍了拍") })
        XCTAssertEqual(try Repo.chat("chat_a")?.row.string("charRemark"), "小雨")
        XCTAssertTrue(try all().contains { $0.kind == "notice" && $0.content.hasSuffix("将你的备注改为「小雨」]") })

        // 重新生成：回应撤掉
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("好")) }
        try await ChatEngine.reply(chatId: "chat_a", regenerate: true) { _ in }
        XCTAssertTrue((try all().first { $0.id == mine.id }?.row["reactions"]?.array ?? []).isEmpty)
    }

    /// 只回应、不说话：落一行「已读，仅回应」。
    func testReactOnlyLeavesSilenceRow() async throws {
        _ = try ChatEngine.send(text: "晚安", chatId: "chat_a")
        try await reply("[回应：\(thumbs)：晚安]")
        let last = try XCTUnwrap(all().last)
        XCTAssertEqual(last.kind, "silence")
        XCTAssertTrue(last.row.bool("reacted"))
    }

    /// 用户点回应：同一个 emoji 第二次是取消；不是 emoji 的不收。
    func testUserReactionToggle() throws {
        let m = try ChatEngine.send(text: "在吗", chatId: "chat_a")
        XCTAssertTrue(try Interact.toggleReaction(m.id, emoji: thumbs, by: "me"))
        XCTAssertFalse(try Interact.toggleReaction(m.id, emoji: thumbs, by: "me"))
        XCTAssertFalse(try Interact.toggleReaction(m.id, emoji: "好", by: "me"))
        XCTAssertTrue((try all().first { $0.id == m.id }?.row["reactions"]?.array ?? []).isEmpty)
        XCTAssertTrue(Interact.isEmoji("\u{1F1E8}\u{1F1F3}"))
        XCTAssertFalse(Interact.isEmoji("12"))
    }

    // MARK: - 提示词

    /// 能力写进提示词；角色卡上关掉的不写；有待处理的转账时给整段细则。
    func testCapabilitiesInPrompt() throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        var char = try XCTUnwrap(Repo.character("char_a"))
        var b = try ChatPrompt.build(chat: chat, char: char, settings: .load())
        XCTAssertTrue(b.system.contains("[转账：amount note]"))
        XCTAssertTrue(b.system.contains("[拍一拍]"))
        XCTAssertFalse(b.system.contains("[不回复] and nothing else"))
        _ = try ChatEngine.sendTransfer(chatId: "chat_a", amount: 5, note: "")
        b = try ChatPrompt.build(chat: chat, char: char, settings: .load())
        XCTAssertTrue(b.system.contains("[转账]\nTo send money"))
        XCTAssertTrue(b.system.contains("人民币"))
        char.row["canTransfer"] = .bool(false)
        char.row["canSilence"] = .bool(true)
        b = try ChatPrompt.build(chat: chat, char: char, settings: .load())
        XCTAssertFalse(b.system.contains("[转账：amount note]"))
        XCTAssertTrue(b.system.contains("[不回复]"))
    }

    /// 外卖：角色请客，用户收下；用户让角色代付，角色写 [要了]；重新生成退回待处理。位置照网页版的写法落库。
    func testTakeoutAndLocation() async throws {
        let p = ReplyParser.split("[请客：奶茶 18]\n[外卖：炸鸡]\n[要了]\n[不要]").parts
        XCTAssertEqual(p.map(\.type), [.takeout, .takeout, .meal, .meal])
        XCTAssertEqual(p[0].extra, "treat")
        XCTAssertEqual(p[0].amount, 18)
        XCTAssertEqual(p[1].amount, 0)
        XCTAssertTrue(p[2].flag)
        XCTAssertFalse(p[3].flag)

        try await reply("[请客：奶茶 18]")
        let treat = try XCTUnwrap(all().last { $0.kind == "takeout" })
        XCTAssertEqual(treat.content, "[请客：奶茶 18.00]")
        XCTAssertEqual(treat.row.string("takeout"), "pending")
        _ = try Repo.append(XCTUnwrap(Interact.settleTakeout(treat.id, take: true)))
        XCTAssertEqual(try all().first { $0.id == treat.id }?.content, "[请客：奶茶 18.00]（已被收下）")

        let ask = try ChatEngine.sendTakeout(chatId: "chat_a", kind: "ask", item: "火锅", amount: 120)
        XCTAssertEqual(ask.content, "[代付：火锅 120.00]")
        try await reply("[要了]\n好")
        XCTAssertEqual(try all().first { $0.id == ask.id }?.row.string("takeout"), "taken")
        XCTAssertTrue(try all().contains { $0.content == "[林替小于付了火锅 120.00]" })
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("再说")) }
        try await ChatEngine.reply(chatId: "chat_a", regenerate: true) { _ in }
        XCTAssertEqual(try all().first { $0.id == ask.id }?.row.string("takeout"), "pending")

        // 自己吃的那一档一落库就算完
        let me = try ChatEngine.sendTakeout(chatId: "chat_a", kind: "self", item: "面", amount: 0)
        XCTAssertEqual(me.row.string("takeout"), "taken")
        let loc = try ChatEngine.sendLocation(chatId: "chat_a", place: "公园", address: "东门")
        XCTAssertEqual(loc.content, "[位置：公园 东门]")
    }

    func testCurrencyFormat() throws {
        XCTAssertEqual(Interact.format(3), "3.00")
        try setSettings(["currency": .string("JPY")])
        XCTAssertEqual(Interact.format(1234.6), "1235")
        XCTAssertEqual(Interact.display(5, "USD"), "$5.00")
    }

    func testExchangeRate() {
        var s = AppSettings(raw: [:])
        XCTAssertNil(Interact.rateOf("CNY", "JPY", s))
        Interact.setRate(&s, "CNY", "JPY", 20.5)
        XCTAssertEqual(Interact.rateOf("CNY", "JPY", s), 20.5)
        XCTAssertEqual(Interact.rateOf("JPY", "CNY", s)!, 1 / 20.5, accuracy: 1e-9)
        XCTAssertEqual(Interact.convert(10, "CNY", "JPY", s), 205)
        Interact.setRate(&s, "JPY", "CNY", 0.05)
        XCTAssertNil(s.raw["rates"]?["CNY>JPY"], "两个方向只存一个")
    }

    // MARK: - 头像库

    /// 头像库：空库不注入；角色按名字换上一张，认不出不换；第一次换时记下原本那张，可以换回
    func testAvatarPool() async throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        var b = try ChatPrompt.build(chat: chat, char: try XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertFalse(b.system.contains("[换头像"))
        let orig = try XCTUnwrap(Repo.character("char_a")).avatar
        try AvatarPool.add("char_a", imageId: "img_cat", name: "白猫")
        try AvatarPool.add("char_a", imageId: "img_black", name: "")
        XCTAssertEqual(AvatarPool.names(try XCTUnwrap(Repo.character("char_a")).row), "白猫、第 2 张")
        b = try ChatPrompt.build(chat: chat, char: try XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertTrue(b.system.contains("[换头像：name]. Available: 白猫、第 2 张"))

        XCTAssertEqual(ReplyParser.split("[换头像：白猫]\n好", autoSplitAt: 0).parts.map(\.type), [.wear, .text])
        _ = try ChatEngine.send(text: "换个头像", chatId: "chat_a")
        try await reply("[换头像：小狗]\n没有")
        XCTAssertEqual(try Repo.character("char_a")?.avatar, orig, "认不出不换")
        _ = try ChatEngine.send(text: "白猫那张", chatId: "chat_a")
        try await reply("[换头像：白 猫]\n换好了")
        XCTAssertEqual(MockNet.count, 1)
        let c = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(c.avatar, "img_cat")
        XCTAssertFalse(try all().contains { $0.content.contains("换头像") })
        if !orig.isEmpty {
            XCTAssertEqual(AvatarPool.base(c.row), orig)
            XCTAssertTrue(try AvatarPool.restore("char_a"))
            XCTAssertEqual(try Repo.character("char_a")?.avatar, orig)
        }
    }
}
