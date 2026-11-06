import XCTest
@testable import Eira

/// 群里的几样（网页版 4.736、4.733、4.947、4.1018）：红包怎么分、领与退回、群里的转账只有收款人收得了、角色自行退群、
/// 角色改网名、群里名字的顺序、我在本群的身份与画外音。都不多调接口：每一轮仍是一次请求。
final class GroupPayTests: StoreTestCase {
    private var zhou: Character!
    private var yu: Character!
    private var group: Chat!

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["currency": .string("CNY"), "services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
        zhou = try People.createCharacter(name: "小周")
        yu = try People.createCharacter(name: "小于")
        let me = try People.ensureActivePersona()
        group = try GroupChat.create(memberIds: ["char_a", zhou.id, yu.id], title: "", personaId: me.id)
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func features(_ ids: [String]) throws {
        try setSettings(["featureOpt": .object(Dictionary(uniqueKeysWithValues: ids.map { ($0, JSONValue.string("on")) }))])
    }

    private func reply(_ text: String, chatId: String? = nil, regenerate: Bool = false) async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream(text)) }
        try await ChatEngine.reply(chatId: chatId ?? group.id, regenerate: regenerate) { _ in }
    }

    private func fresh() throws -> Chat { try XCTUnwrap(Repo.chat(group.id)) }
    private func msgs(_ chatId: String? = nil) throws -> [Message] { try Repo.messages(chatId: chatId ?? group.id) }

    // MARK: - 分

    func testSplit() throws {
        let luck = try RedPacket.split(RedPacket.luck, total: 10, count: 3, code: "CNY", rng: { 0.5 })
        XCTAssertEqual(luck.shares, [3.34, 3.33, 3.33])
        XCTAssertEqual(luck.total, 10)
        let eq = try RedPacket.split(RedPacket.equal, total: 10, count: 3, code: "CNY")
        XCTAssertEqual(eq.shares, [3.33, 3.33, 3.33])
        XCTAssertEqual(eq.total, 9.99, "除不尽的零头不发")
        let only = try RedPacket.split(RedPacket.only, total: 8.8, count: 5, code: "CNY")
        XCTAssertEqual(only.shares, [8.8])
        XCTAssertThrowsError(try RedPacket.split(RedPacket.luck, total: 0.02, count: 3, code: "CNY"))
        XCTAssertThrowsError(try RedPacket.split(RedPacket.luck, total: 0, count: 1, code: "CNY"))
        // 拼手气：每份至少一个最小单位，和就是总额
        for _ in 0..<50 {
            let r = try RedPacket.split(RedPacket.luck, total: 1, count: 7, code: "CNY")
            XCTAssertEqual(r.shares.count, 7)
            XCTAssertTrue(r.shares.allSatisfy { $0 >= 0.01 })
            XCTAssertEqual((r.shares.reduce(0, +) * 100).rounded(), 100)
        }
    }

    // MARK: - 角色发、领

    func testCharSendsAndClaims() async throws {
        try features(["grouppay"])
        try await reply("林：[红包：10｜2｜恭喜]\n小周：[领红包]")
        XCTAssertEqual(MockNet.count, 1)
        let all = try msgs()
        let rpMsg = try XCTUnwrap(all.first { $0.kind == "redpacket" })
        XCTAssertEqual(rpMsg.authorId, "char_a")
        let rp = try XCTUnwrap(RedPacket.packet(rpMsg))
        XCTAssertEqual(rp.shares.count, 2)
        XCTAssertEqual(rp.claims.map(\.who), [zhou.id])
        XCTAssertEqual(rp.note, "恭喜")
        XCTAssertEqual(rpMsg.content, "[红包：10.00｜2｜恭喜]（已领 1/2）")
        let notice = try XCTUnwrap(all.first { $0.kind == "notice" && !$0.row.string("rpOf").isEmpty })
        XCTAssertEqual(notice.authorId, zhou.id)
        XCTAssertTrue(notice.content.hasPrefix("[小周领取了林的红包 "), notice.content)
        // 我也能领；领过的不能再领
        XCTAssertEqual(RedPacket.whyNot(rpMsg, who: GroupChat.me), "")
        XCTAssertEqual(RedPacket.whyNot(rpMsg, who: zhou.id), "已经领过这个红包")
    }

    func testOffByDefaultNothingLands() async throws {
        try await reply("林：[红包：10｜2]\n林：[转账：小周｜20]\n林：好")
        XCTAssertEqual(MockNet.count, 1)
        let all = try msgs().filter { $0.role == .char }
        XCTAssertEqual(all.map(\.content), ["好"])
        // 群里拼的提示词里也没有这一项
        let b = try ChatPrompt.buildGroup(chat: fresh(), members: GroupChat.members(fresh()), settings: .load())
        XCTAssertFalse(b.system.contains("[红包：total｜count｜greeting]"))
    }

    func testPerCharacterFeatureCounts() async throws {
        // 全局没开，这个角色自己开了（网页版 4.882）：照样给、照样落
        var c = try XCTUnwrap(Repo.character("char_a"))
        c.row["featOpt"] = .object(["grouppay": .string("on")])
        try Database.shared.put(Collections.characters, c.row)
        let b = try ChatPrompt.buildGroup(chat: fresh(), members: GroupChat.members(fresh()), settings: .load())
        XCTAssertTrue(b.system.contains("[红包：total｜count｜greeting]"))
        try await reply("林：[红包：6｜3]")
        XCTAssertEqual(try msgs().filter { $0.kind == "redpacket" }.count, 1)
    }

    func testUserPacketClaimAndRegenerate() async throws {
        try features(["grouppay"])
        let sent = try RedPacket.send(chatId: group.id, type: RedPacket.luck, total: 9, count: 3, note: "", to: "")
        XCTAssertEqual(RedPacket.packet(sent)?.note, RedPacket.defaultNote)
        try await reply("小周：[领红包]\n小于：[领红包：我]")
        var rp = try XCTUnwrap(RedPacket.packet(XCTUnwrap(Repo.messages(chatId: group.id).first { $0.id == sent.id })))
        XCTAssertEqual(Set(rp.claims.map(\.who)), [zhou.id, yu.id])
        // 重新生成那一轮：领的那几份退回去
        try await reply("林：嗯", regenerate: true)
        rp = try XCTUnwrap(RedPacket.packet(XCTUnwrap(Repo.messages(chatId: group.id).first { $0.id == sent.id })))
        XCTAssertTrue(rp.claims.isEmpty)
        XCTAssertTrue(try XCTUnwrap(Repo.messages(chatId: group.id).first { $0.id == sent.id }).content.hasSuffix("（已领 0/3）"))
        // 我自己领一份，再删掉那一行：退回，剩下的人按先后对上金额
        let n1 = try XCTUnwrap(RedPacket.claim(sent.id, who: GroupChat.me))
        let saved = try Repo.append(n1)
        _ = try RedPacket.claim(sent.id, who: zhou.id)
        rp = try XCTUnwrap(RedPacket.packet(Message(row: XCTUnwrap(Database.shared.get(Collections.messages, id: sent.id)))))
        XCTAssertEqual(rp.claims.map(\.who), [GroupChat.me, zhou.id])
        try MessageActions.delete(saved)
        rp = try XCTUnwrap(RedPacket.packet(Message(row: XCTUnwrap(Database.shared.get(Collections.messages, id: sent.id)))))
        XCTAssertEqual(rp.claims.map(\.who), [zhou.id])
        XCTAssertEqual(rp.claims.first?.amount, rp.shares.first)
    }

    func testOnlyPacketAndExpiry() throws {
        let m = try RedPacket.send(chatId: group.id, type: RedPacket.only, total: 8.8, count: 1, note: "给你", to: zhou.id)
        XCTAssertEqual(m.content, "[专属红包：小周｜8.80｜给你]（已领 0/1）")
        XCTAssertEqual(RedPacket.whyNot(m, who: "char_a"), "这是给小周的专属红包")
        XCTAssertNil(try RedPacket.claim(m.id, who: "char_a"))
        XCTAssertThrowsError(try RedPacket.send(chatId: group.id, type: RedPacket.only, total: 1, count: 1, note: "", to: ""))

        let late = m.createdAt + RedPacket.ttl + 1
        XCTAssertEqual(RedPacket.state(RedPacket.packet(m), at: m.createdAt, now: late), "expired")
        XCTAssertEqual(RedPacket.whyNot(m, who: zhou.id, now: late), "红包已过期")
        XCTAssertEqual(RedPacket.left(try XCTUnwrap(RedPacket.packet(m))), 8.8)
        RedPacket.sweep(group.id, now: late)
        XCTAssertTrue(try XCTUnwrap(Database.shared.get(Collections.messages, id: m.id)).string("content").contains("已过期"))
        // 私聊里不能发红包
        XCTAssertThrowsError(try RedPacket.send(chatId: "chat_a", type: RedPacket.luck, total: 1, count: 1, note: "", to: ""))
    }

    // MARK: - 群里的转账

    func testGroupTransferOnlyRecipientSettles() async throws {
        try features(["grouppay"])
        try await reply("林：[转账：小周｜20 请你]")
        let t = try XCTUnwrap(msgs().first { $0.kind == "transfer" })
        XCTAssertEqual(t.row.string("to"), zhou.id)
        XCTAssertEqual(t.row.string("toName"), "小周")
        XCTAssertEqual(t.content, "[转账：小周｜20.00 请你]")
        try await reply("林：[收款]\n小周：[收款]")
        let after = try XCTUnwrap(Database.shared.get(Collections.messages, id: t.id))
        XCTAssertEqual(after.string("transfer"), "taken")
        XCTAssertEqual(after.string("content"), "[转账：小周｜20.00 请你]（已被收下）")
        let notices = try msgs().filter { $0.row.string("settledId") == t.id }
        XCTAssertEqual(notices.map(\.content), ["[小周收下了林的转账 20.00]"])
        XCTAssertEqual(notices.first?.authorId, zhou.id)
        // 删掉那一行：回到待收款，写法不变
        try MessageActions.delete(try XCTUnwrap(notices.first))
        XCTAssertEqual(try Database.shared.get(Collections.messages, id: t.id)?.string("content"), "[转账：小周｜20.00 请你]")

        // 我在群里转：要选收款人，不能转给自己
        let mine = try GroupPay.sendTransfer(chatId: group.id, to: yu.id, amount: 5, note: "")
        XCTAssertEqual(mine.content, "[转账：小于｜5.00]")
        XCTAssertThrowsError(try GroupPay.sendTransfer(chatId: group.id, to: GroupChat.me, amount: 5, note: ""))
        XCTAssertThrowsError(try GroupPay.sendTransfer(chatId: group.id, to: "", amount: 5, note: ""))
    }

    // MARK: - 自行退群（4.733）

    func testLeave() async throws {
        try features(["groupleave"])
        // 群资料里没开：不退
        try await reply("小周：[退群]\n林：嗯")
        XCTAssertTrue(try fresh().characterIds.contains(zhou.id))
        XCTAssertFalse(try ChatPrompt.buildGroup(chat: fresh(), members: GroupChat.members(fresh()), settings: .load()).system.contains("[退群]"))

        try GroupMore.setLeaveOn(group.id, true)
        XCTAssertTrue(try ChatPrompt.buildGroup(chat: fresh(), members: GroupChat.members(fresh()), settings: .load()).system.contains("[退群]"))
        var admins = try fresh()
        admins.row["admins"] = .array([.string(zhou.id)])
        try Repo.save(admins)
        try await reply("小周：[退群]\n林：再见")
        XCTAssertEqual(MockNet.count, 1)
        var c = try fresh()
        XCTAssertEqual(c.characterIds, ["char_a", yu.id])
        XCTAssertTrue((c.row["admins"]?.array ?? []).isEmpty)
        XCTAssertTrue(try msgs().contains { $0.kind == "notice" && $0.content == "[小周退出了群聊]" })
        // 只剩两名角色：再退不了
        XCTAssertFalse(GroupMore.canLeave(c, yu.id))
        // 重新生成那一轮：成员与管理员一起退回去
        try await reply("林：嗯", regenerate: true)
        c = try fresh()
        XCTAssertEqual(c.characterIds, ["char_a", zhou.id, yu.id])
        XCTAssertEqual(c.row["admins"]?.array?.compactMap(\.string), [zhou.id])
    }

    // MARK: - 网名（4.947）

    func testSelfNick() async throws {
        // 没开：碰巧写了也不改，提示词里没有写法
        try await reply("[改网名：夜行]\n好", chatId: "chat_a")
        XCTAssertEqual(try Repo.character("char_a")?.row.string("nick"), "")
        let off = try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertFalse(off.system.contains("[改网名：new name]"))

        try features(["selfnick"])
        let on = try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertTrue(on.system.contains("[改网名：new name]"))
        XCTAssertTrue(on.system.contains("none (your real name is shown)"))
        try await reply("[改网名：夜行]\n好", chatId: "chat_a")
        XCTAssertEqual(try Repo.character("char_a")?.row.string("nick"), "夜行")
        XCTAssertTrue(try msgs("chat_a").contains { $0.content == "[林把网名改为「夜行」]" && $0.row["nickUndo"] != nil })
        try await reply("嗯", chatId: "chat_a", regenerate: true)
        XCTAssertEqual(try Repo.character("char_a")?.row.string("nick"), "")
    }

    func testShownNameOrder() throws {
        var c = try fresh()
        XCTAssertEqual(GroupMore.shownName(c, zhou.id), "小周")
        var z = try XCTUnwrap(Repo.character(zhou.id))
        z.row["nick"] = .string("夜行")
        try Database.shared.put(Collections.characters, z.row)
        XCTAssertEqual(GroupMore.shownName(c, zhou.id), "夜行")
        z.row["remark"] = .string("周周")
        try Database.shared.put(Collections.characters, z.row)
        XCTAssertEqual(GroupMore.shownName(c, zhou.id), "周周")
        try GroupChat.setNick(group.id, zhou.id, "群里的周")
        c = try fresh()
        XCTAssertEqual(GroupMore.shownName(c, zhou.id), "群里的周")
        // @ 认群里显示的名字、备注、网名
        XCTAssertEqual(GroupChat.mentions(in: "@周周 在吗", chat: c, members: GroupChat.members(c)), [zhou.id])
        XCTAssertEqual(GroupChat.mentions(in: "@夜行 在吗", chat: c, members: GroupChat.members(c)), [zhou.id])
    }

    // MARK: - 我在本群的身份（4.1018）

    func testWatchAndVoiceModes() throws {
        _ = try Repo.append(Message.new(chatId: group.id, role: .char, authorId: "char_a", content: "在的"))
        var b = try ChatPrompt.buildGroup(chat: fresh(), members: GroupChat.members(fresh()), settings: .load())
        XCTAssertTrue(b.system.contains("writes their own"))
        XCTAssertEqual(b.messages.last?.role, .user, "成员身份：最后是成员说的就补一句对方还没回")

        try GroupMore.setMode(group.id, "watch")
        XCTAssertEqual(GroupMore.mode(try fresh()), "watch")
        b = try ChatPrompt.buildGroup(chat: fresh(), members: GroupChat.members(fresh()), settings: .load())
        XCTAssertTrue(b.system.contains("is not a member of this group and does not write in it"))
        XCTAssertEqual(b.messages.last?.role, .assistant, "旁观时不补「对方还没回」")

        try GroupMore.setMode(group.id, "voice")
        let v = try XCTUnwrap(GroupMore.sendVoiceover("外面下起了雨", chatId: group.id))
        XCTAssertEqual(v.kind, "voiceover")
        XCTAssertEqual(v.content, "[画外音：外面下起了雨]")
        XCTAssertEqual(GroupMore.voiceoverText(v), "外面下起了雨")
        b = try ChatPrompt.buildGroup(chat: fresh(), members: GroupChat.members(fresh()), settings: .load())
        XCTAssertTrue(b.system.contains("Lines marked [画外音：…]"))
        XCTAssertTrue(b.messages.contains { $0.content.contains("[画外音：外面下起了雨]") })
        // 成员不能替用户写画外音
        let segs = GroupChat.splitSpeakers("林：好\n[画外音：假的]\n小周：嗯", members: GroupChat.members(try fresh()), chat: try fresh(), userName: "我")
        XCTAssertEqual(segs.map(\.text), ["好", "嗯"])
        try GroupMore.setMode(group.id, "nope")
        XCTAssertEqual(GroupMore.mode(try fresh()), "voice")
    }

    func testAmbientConfig() throws {
        XCTAssertEqual(GroupMore.ambient(try fresh()), GroupMore.Ambient(page: false, pageMin: 3, perOpen: 10))
        try GroupMore.setAmbient(group.id, .init(page: true, pageMin: 0, perOpen: -1))
        XCTAssertEqual(GroupMore.ambient(try fresh()), GroupMore.Ambient(page: true, pageMin: 1, perOpen: 0))
    }
}
