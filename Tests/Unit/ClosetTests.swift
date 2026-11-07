import XCTest
@testable import Eira

/// 衣帽间（网页版 closet.js、closet-story.js、context/closet.js）：字段与默认值、今天穿的、借穿与撤回、搭配卡片、
/// 礼物自动收进、按名字猜分类、描述里去掉人、余量与保质期、提示词那一段。
final class ClosetTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: "phone.daily.tried")
        try importFixture("data.json")
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "phone.daily.tried")
        try super.tearDownWithError()
    }

    private func item(_ owner: String, _ name: String, group: String = "acc", sub: String = "围巾", _ extra: [String: JSONValue] = [:]) throws -> Row {
        var f: [String: JSONValue] = ["owner": .string(owner), "group": .string(group), "sub": .string(sub), "name": .string(name)]
        for (k, v) in extra { f[k] = v }
        return try Closet.create(f)
    }

    private func chat() throws -> Chat { try XCTUnwrap(Repo.chat("chat_a")) }
    private func char() throws -> Character { try XCTUnwrap(Repo.character("char_a")) }

    func testCreateUsesWebDefaults() throws {
        let r = try Closet.create(["group": .string("scent"), "sub": .string("香水"), "name": .string("  ")])
        XCTAssertTrue(r.id.hasPrefix("cl_"))
        XCTAssertEqual(r.string("owner"), "me")
        XCTAssertEqual(r.string("personaId"), "me_root")
        XCTAssertEqual(r.string("side"), "beauty")
        XCTAssertEqual(r.string("name"), "未命名")
        XCTAssertEqual(r.string("source"), "self")
        XCTAssertEqual(r.string("doseUnit"), "喷")
        XCTAssertEqual(r.number("dose"), 2)
        XCTAssertEqual(r.number("pao"), 36)
        XCTAssertEqual(r.string("capUnit"), "毫升")
        XCTAssertEqual(r["imageId"], .null)
        XCTAssertEqual(r["level"], .null)
        XCTAssertEqual(r["wornDates"], .array([]))
        XCTAssertEqual(r["auto"], .bool(false))
        // 角色的不记身份
        let c = try item("char_a", "外套", group: "outer", sub: "夹克")
        XCTAssertEqual(c.string("personaId"), "")
        // 不认得的字段写回去时留着
        var raw = try XCTUnwrap(Database.shared.get("closet", id: c.id))
        raw["webOnly"] = .string("keep")
        try Database.shared.put("closet", raw)
        try Closet.update(c.id, ["name": .string("风衣")])
        XCTAssertEqual(try XCTUnwrap(Database.shared.get("closet", id: c.id)).string("webOnly"), "keep")
    }

    func testWearTodayCountsOncePerDay() throws {
        let r = try item("me", "白围巾")
        try Closet.wear(r.id, true)
        try Closet.wear(r.id, true)
        XCTAssertEqual(Closet.get(r.id)?.number("wornCount"), 1)
        XCTAssertEqual(Closet.wornToday("me").map(\.id), [r.id])
        try Closet.wear(r.id, false)
        XCTAssertEqual(Closet.get(r.id)?.number("wornCount"), 0)
        XCTAssertTrue(Closet.wornToday("me").isEmpty)
    }

    func testParserAndWebMapAgree() {
        let p = ReplyParser.split("[搭配：约会 | 白衬衫、牛仔裤，帆布鞋]\n[借走：围巾]").parts
        XCTAssertEqual(p.map(\.type), [.outfit, .closetAct])
        XCTAssertEqual(p[0].text, "约会")
        XCTAssertEqual(p[0].extra, "白衬衫、牛仔裤、帆布鞋")
        XCTAssertEqual(p[1].text, "围巾")
        XCTAssertEqual(p[1].extra, "借走")
        // 一件都没有就整条丢掉
        XCTAssertTrue(ReplyParser.split("[搭配：约会|]").parts.isEmpty)
        let (parts, unmapped) = WebLogic.map([
            ["type": "outfit", "name": "约会", "names": ["白衬衫", "牛仔裤", "帆布鞋"]],
            ["type": "closetact", "kind": "借走", "name": "围巾"],
        ])
        XCTAssertEqual(unmapped, [])
        XCTAssertEqual(parts, p)
    }

    func testOutfitCardFromReply() throws {
        let shirt = try item("me", "白衬衫", group: "top", sub: "衬衫")
        _ = try item("me", "牛仔裤", group: "bottom", sub: "牛仔裤")
        var part = ReplyParser.Part(type: .outfit, text: "约会")
        part.extra = "白衬衫、帆布鞋"
        let m = try XCTUnwrap(Closet.effect(part, chat: chat(), char: char(), turnId: "t1"))
        XCTAssertEqual(m.kind, "outfit")
        XCTAssertEqual(m.content, "[搭配：约会 | 白衬衫、帆布鞋]")
        XCTAssertEqual(m.row.string("outfitOwner"), "me")
        let items = m.row["outfitItems"]?.array ?? []
        XCTAssertEqual(items.map { $0["id"]?.string }, [shirt.id, ""])
        // 存成一套：认得出的那几件
        let saved = try Repo.append(m)
        let o = try XCTUnwrap(Closet.keepOutfit(saved))
        XCTAssertEqual(o.string("side"), "outfit")
        XCTAssertEqual(o.strings("items"), [shirt.id])
        XCTAssertEqual(try Closet.keepOutfit(saved)?.id, o.id)
    }

    func testBorrowAndUndoWhenNoticeDropped() throws {
        let scarf = try item("me", "灰色围巾")
        var part = ReplyParser.Part(type: .closetAct, text: "围巾")
        part.extra = "借走"
        let m = try XCTUnwrap(Closet.effect(part, chat: chat(), char: char(), turnId: "t1"))
        XCTAssertEqual(m.content, "[林借走了你的灰色围巾]")
        XCTAssertEqual(Closet.get(scarf.id)?["lent"]?["to"]?.string, "char_a")
        XCTAssertEqual(Closet.lentBetween("char_a").map(\.id), [scarf.id])
        // 换上借来的那一件
        var wearPart = ReplyParser.Part(type: .closetAct, text: "灰色围巾")
        wearPart.extra = "换上"
        let w = try XCTUnwrap(Closet.effect(wearPart, chat: chat(), char: char(), turnId: "t1"))
        XCTAssertEqual(w.content, "[林换上了借来的灰色围巾]")
        XCTAssertEqual(Closet.wornToday("char_a").map(\.id), [scarf.id])
        // 认不出就当没写过
        var miss = ReplyParser.Part(type: .closetAct, text: "不存在的帽子")
        miss.extra = "借走"
        XCTAssertNil(try Closet.effect(miss, chat: chat(), char: char(), turnId: "t1"))
        // 删掉提示那一行（重新生成那一轮）：照着改回去
        try Interact.unsettle(try Repo.append(w))
        try Interact.unsettle(try Repo.append(m))
        XCTAssertFalse(Closet.lentOut(try XCTUnwrap(Closet.get(scarf.id))))
        XCTAssertEqual(Closet.get(scarf.id)?.number("wornCount"), 0)
    }

    func testGroupChatIgnoresCloset() throws {
        var c = try chat()
        c.row["characterIds"] = .array([.string("char_a"), .string("char_b")])
        var part = ReplyParser.Part(type: .outfit, text: "")
        part.extra = "白衬衫"
        XCTAssertNil(try Closet.effect(part, chat: c, char: char(), turnId: "t1"))
    }

    func testGuessKindAndGarmentOnly() {
        XCTAssertEqual(Closet.guessKind("一条白色围巾")?.group, "acc")
        XCTAssertEqual(Closet.guessKind("珍珠耳环")?.sub, "耳饰")
        XCTAssertEqual(Closet.guessKind("针织毛衣")?.sub, "针织 / 毛衣")
        XCTAssertNil(Closet.guessKind("一盒糖"))
        XCTAssertNil(Closet.guessKind("平底锅"))
        XCTAssertEqual(Closet.garmentOnly("米色羊毛大衣。长发模特穿着。双排扣设计"), "米色羊毛大衣。双排扣设计")
    }

    func testGiftOpenedByCharGoesIntoItsCloset() throws {
        var g = try Interact.gift(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "", kind: "gift"), cover: "小盒子", inner: "银色项链")
        g = try Repo.append(g)
        let notice = try XCTUnwrap(Interact.settleGift(g.id, open: true, turnId: "t2"))
        let kept = try XCTUnwrap(Closet.giftItem(g.id))
        XCTAssertEqual(kept.string("owner"), "char_a")
        XCTAssertEqual(kept.string("group"), "jewelry")
        XCTAssertEqual(kept.string("giver"), "me")
        XCTAssertTrue(kept.bool("auto"))
        // 那一轮重新生成：礼物回到待拆，自动收的撤掉
        try Interact.unsettle(try Repo.append(notice))
        XCTAssertNil(Closet.giftItem(g.id))
        // 认不出的不收
        var candy = try Interact.gift(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "", kind: "gift"), cover: "一盒糖", inner: "")
        candy = try Repo.append(candy)
        _ = try Interact.settleGift(candy.id, open: true)
        XCTAssertNil(Closet.giftItem(candy.id))
    }

    func testRemainingAndExpiry() throws {
        let day = 86_400_000.0
        let now = Date().millis
        let start = Closet.dateKey(now - 10 * day)
        let r = try Closet.create(["group": .string("base"), "sub": .string("粉底"), "name": .string("粉底液"),
                                   "capacity": .number(30), "perDay": .number(1), "openedAt": .string(start), "pao": .number(12)])
        // 一泵 0.25 毫升，一次 2 泵，一天一次：十天用掉 5 毫升
        let rem = try XCTUnwrap(Closet.remaining(r, now: now))
        XCTAssertEqual(rem.pct, 83, accuracy: 1)
        XCTAssertEqual(Closet.expiry(r, now: now)?.basis, "opened")
        try Closet.calibrate(r.id, 10)
        let low = try XCTUnwrap(Closet.flagsOf(try XCTUnwrap(Closet.get(r.id)), now: now))
        XCTAssertNotNil(low.low)
        // 告诉角色那一次：当天之内一直在，之后冷却
        XCTAssertEqual(Closet.takeAlerts("me_root", now: now).count, 1)
        XCTAssertEqual(Closet.takeAlerts("me_root", now: now).count, 1)
        XCTAssertEqual(Closet.takeAlerts("me_root", now: now + 2 * day).count, 0)
    }

    func testBlockInPrompt() throws {
        let coat = try item("me", "驼色大衣", group: "outer", sub: "大衣", ["desc": .string("羊毛。模特很高。")])
        try Closet.wear(coat.id, true)
        let theirs = try item("char_a", "黑色风衣", group: "outer", sub: "风衣")
        try Closet.wear(theirs.id, true)
        let b = try ChatPrompt.build(chat: chat(), char: char(), settings: .load())
        // 衣帽间那一段归「此刻的状态」，默认贴在聊天记录末尾
        let all = b.system + b.messages.map(\.content).joined()
        XCTAssertTrue(all.contains("[衣帽间]"))
        XCTAssertTrue(all.contains("## What 小于 is wearing today\n- 驼色大衣 (外套 / 大衣): 羊毛。"))
        XCTAssertFalse(all.contains("模特"))
        XCTAssertTrue(all.contains("## What you are wearing today\n- 黑色风衣"))
        XCTAssertTrue(all.contains("do not invent items."))
        // 有分好类的衣物：搭配与换上的写法都在能力里
        XCTAssertTrue(b.system.contains("[搭配："))
        XCTAssertTrue(b.system.contains("[换上："))
        // 能力开关里关掉的不进
        try setSettings(["capsOff": .array([.string("outfit"), .string("closetact")])])
        let off = try ChatPrompt.build(chat: chat(), char: char(), settings: .load())
        XCTAssertFalse(off.system.contains("[搭配："))
    }

    func testWearPartsInImagePrompt() throws {
        let r = try item("char_a", "红色毛衣", group: "top", sub: "针织 / 毛衣")
        try Closet.wear(r.id, true)
        let c = try char()
        XCTAssertTrue(ClosetAI.wearParts("林的自拍", char: c, me: nil, settings: .load()).isEmpty, "默认关")
        try setSettings(["closetInImage": .bool(true)])
        let parts = ClosetAI.wearParts("林的自拍", char: c, me: nil, settings: .load())
        XCTAssertEqual(parts.first?.1, "林 is wearing: 红色毛衣")
    }

    func testDeleteCharacterDropsItsCloset() throws {
        _ = try item("char_a", "外套", group: "outer", sub: "夹克")
        try People.deleteCharacter("char_a")
        XCTAssertTrue(Closet.itemsOf("char_a").isEmpty)
    }
}
