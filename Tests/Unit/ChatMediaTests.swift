import XCTest
@testable import Eira

/// 聊天补齐（网页版 4.799、4.808、4.828、4.861、4.881、4.910）：新标记的解析、文字图、图片版本、每个角色的接口、Fish Audio 的请求。
final class ChatMediaTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    private func one(_ raw: String) -> ReplyParser.Part? {
        let r = ReplyParser.split(raw)
        XCTAssertEqual(r.parts.count, 1, raw)
        return r.parts.first
    }

    // MARK: - 解析（与网页版 reply.js 一字不差，样本也在 weblogic-cases.json 里）

    func testRedPacketMarkers() throws {
        let a = try XCTUnwrap(one("[红包：100｜5｜恭喜发财]"))
        XCTAssertEqual(a.type, .redpacket)
        XCTAssertEqual(a.extra, "luck")
        XCTAssertEqual(a.amount, 100)
        XCTAssertEqual(a.count, 5)
        XCTAssertEqual(a.text, "恭喜发财")
        XCTAssertNil(a.to)

        let b = try XCTUnwrap(one("[普通红包：10｜3]"))
        XCTAssertEqual(b.extra, "equal")
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(b.text, "")

        let c = try XCTUnwrap(one("[专属红包：@小周｜8.8｜给你]"))
        XCTAssertEqual(c.extra, "only")
        XCTAssertEqual(c.to, "小周")
        XCTAssertEqual(c.amount, 8.8)
        XCTAssertEqual(c.count, 1)

        // 个数没写或写错按一个；金额读不出来整条不落
        XCTAssertEqual(one("[红包：50]")?.count, 1)
        XCTAssertEqual(ReplyParser.split("好的\n[红包：abc]").parts.map(\.type), [.text])

        XCTAssertEqual(one("[领红包]")?.type, .rpclaim)
        XCTAssertEqual(one("[领红包]")?.text, "")
        XCTAssertEqual(one("[领红包：小周]")?.text, "小周")
        XCTAssertEqual(one("[抢红包]")?.type, .rpclaim)
    }

    func testLeaveNickAndGroupTransferMarkers() throws {
        XCTAssertEqual(one("[退群]")?.type, .leave)
        XCTAssertEqual(one("[退出群聊]")?.type, .leave)
        XCTAssertEqual(one("[改网名：夜行]")?.type, .selfnick)
        XCTAssertEqual(one("[改网名：夜行]")?.text, "夜行")

        let t = try XCTUnwrap(one("[转账：小周｜52 奶茶]"))
        XCTAssertEqual(t.type, .transfer)
        XCTAssertEqual(t.to, "小周")
        XCTAssertEqual(t.amount, 52)
        XCTAssertEqual(t.text, "奶茶")
        // 竖线前面就是金额、后面读不出金额的，是私聊里原来的「金额｜留言」（网页版 4.753）
        let u = try XCTUnwrap(one("[转账：52｜奶茶]"))
        XCTAssertNil(u.to)
        XCTAssertEqual(u.amount, 52)
        XCTAssertEqual(u.text, "｜奶茶")
        XCTAssertNil(one("[转账：52 奶茶]")?.to)
    }

    func testWebMapping() {
        let (parts, unmapped) = WebLogic.map([
            ["type": "redpacket", "rtype": "only", "to": "小周", "total": 8.8, "count": 1, "note": "给你"],
            ["type": "rpclaim", "from": ""],
            ["type": "leave"],
            ["type": "selfnick", "name": "夜行"],
            ["type": "transfer", "amount": 52, "note": "奶茶", "to": "小周"],
        ])
        XCTAssertTrue(unmapped.isEmpty)
        XCTAssertEqual(parts.map(\.type), [.redpacket, .rpclaim, .leave, .selfnick, .transfer])
        XCTAssertEqual(parts[0].to, "小周")
        XCTAssertEqual(parts[0].count, 1)
        XCTAssertEqual(parts[0].extra, "only")
        XCTAssertEqual(parts[0].amount, 8.8)
        XCTAssertEqual(parts[3].text, "夜行")
        XCTAssertEqual(parts[4].to, "小周")
        // 和原生的切法一致
        XCTAssertEqual(parts[0], ReplyParser.split("[专属红包：@小周｜8.8｜给你]").parts.first)
        XCTAssertEqual(parts[4], ReplyParser.split("[转账：小周｜52 奶茶]").parts.first)
    }

    // MARK: - 文字图（4.799）

    private func charText(_ text: String) throws -> Message {
        try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: text, turnId: "turn_x"))
    }

    func testTextImageRoundTrip() throws {
        let m = try charText("窗外在下雨")
        XCTAssertTrue(MsgConvert.canConvert(m))
        let img = try MsgConvert.toTextImage(m)
        XCTAssertEqual(img.kind, "image")
        XCTAssertEqual(img.row.string("media"), "text")
        XCTAssertEqual(img.row.string("prompt"), "")
        XCTAssertEqual(img.row.string("imageDesc"), "窗外在下雨")
        XCTAssertEqual(img.content, "[图片：窗外在下雨]")
        XCTAssertTrue(MsgConvert.isTextImage(img))
        // 不会被送去生图：重新生成时不问图片怎么处理，没有图片版本、不需要重画
        XCTAssertFalse(ChatEngine.isDrawn(img))
        XCTAssertFalse(ImageVersions.can(img))
        XCTAssertFalse(MessageActions.needsRegen(img))
        XCTAssertFalse(MsgConvert.canConvert(img))
        // 编辑改的是描述
        XCTAssertEqual(MessageActions.editableText(img), "窗外在下雨")
        let edited = try MessageActions.edit(img, text: "窗外在下雪")
        XCTAssertEqual(edited.row.string("imageDesc"), "窗外在下雪")
        XCTAssertEqual(edited.row.string("prompt"), "")
        XCTAssertEqual(edited.content, "[图片：窗外在下雪]")
        // 改回文字：原文一字不差
        let back = try MsgConvert.fromTextImage(edited)
        XCTAssertEqual(back.kind, "text")
        XCTAssertEqual(back.content, "窗外在下雨")
        XCTAssertNil(back.row["textBefore"])
        XCTAssertNil(back.row["media"])
    }

    func testConvertOnlyCharText() throws {
        let mine = try ChatEngine.send(text: "你好", chatId: "chat_a")
        XCTAssertFalse(MsgConvert.canConvert(mine))
        XCTAssertThrowsError(try MsgConvert.toTextImage(mine))
        // 没配语音接口时不改、不调
        let m = try charText("早点睡")
        XCTAssertThrowsError(try MsgConvert.toVoice(m))
        XCTAssertEqual(try Database.shared.get(Collections.messages, id: m.id)?.string("kind"), "text")
    }

    // MARK: - 多选发图（4.910）

    func testQuoteOnlyOnFirstImage() throws {
        let q = try charText("看这个")
        let a = try ChatEngine.sendImage(imageId: "img_1", chatId: "chat_a", quote: q)
        let b = try ChatEngine.sendImage(imageId: "img_2", chatId: "chat_a")
        XCTAssertEqual(a.row.string("quoteId"), q.id)
        XCTAssertNil(b.row["quoteId"])
        XCTAssertLessThan(a.createdAt, b.createdAt)
    }

    // MARK: - 图片版本（4.861）

    func testImageVersionsBasics() throws {
        var m = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "[图片：猫]", kind: "image")
        m.row["prompt"] = .string("猫")
        m.row["imageId"] = .string("img_a")
        m.row["media"] = .string("done")
        m = try Repo.append(m)
        XCTAssertTrue(ImageVersions.can(m))
        XCTAssertEqual(ImageVersions.of(m), ["img_a"])

        // 再画一版接在后面；画好的那一张接在版本表最后
        var row = m.row
        row["imageVers"] = ImageVersions.json(["img_a", "img_b"])
        ImageVersions.noteDrawn(&row, "img_c")
        XCTAssertEqual(row.strings("imageVers"), ["img_a", "img_b", "img_c"])
        var plain = m.row
        ImageVersions.noteDrawn(&plain, "img_c")
        XCTAssertNil(plain["imageVers"], "没有版本表的老消息不另加")

        try Database.shared.put(Collections.messages, row)
        let picked = try XCTUnwrap(ImageVersions.pick(m.id, "img_b"))
        XCTAssertEqual(picked.imageId, "img_b")
        XCTAssertEqual(ImageVersions.of(picked), ["img_a", "img_b", "img_c"])
        XCTAssertNil(try ImageVersions.pick(m.id, "img_zz"))
        // 正在显示的那一版不删
        XCTAssertFalse(try ImageVersions.remove(m.id, "img_b"))
        XCTAssertTrue(try ImageVersions.remove(m.id, "img_a"))
        let after = try XCTUnwrap(Database.shared.get(Collections.messages, id: m.id))
        XCTAssertEqual(ImageVersions.of(after), ["img_b", "img_c"])
    }

    // MARK: - 每个角色单独的聊天接口（4.828）

    private func presets(fallback: Bool = false) throws {
        var s: [String: JSONValue] = ["services": .object(["chat": .object([
            "presets": .array([
                .object(["id": .string("svc_main"), "name": .string("主"), "provider": .string("anthropic"), "apiKey": .string("k"), "model": .string("m")]),
                .object(["id": .string("svc_spare"), "name": .string("副"), "provider": .string("openai"), "apiKey": .string("k"), "model": .string("m")]),
                .object(["id": .string("svc_third"), "name": .string("三"), "provider": .string("openai"), "apiKey": .string("k"), "model": .string("m")]),
                .object(["id": .string("svc_half"), "name": .string("半"), "provider": .string("openai"), "apiKey": .string(""), "model": .string("m")]),
            ]),
            "activeId": .string("svc_main"), "fallbackId": .string("svc_spare"),
        ])])]
        if fallback { s["chatFallback"] = .bool(true); s["failoverMax"] = .number(0) }
        try setSettings(s)
    }

    private func choose(_ id: String) throws { try CharApi.set("char_a", id) }

    func testCharRoute() throws {
        try presets()
        var s = AppSettings.load()
        XCTAssertNil(s.charPreset("char_a"))
        XCTAssertEqual(CharApi.label(try Repo.character("char_a"), s), "跟随主用")

        try choose("svc_third")
        s = AppSettings.load()
        XCTAssertEqual(s.charPreset("char_a")?.id, "svc_third")
        XCTAssertEqual(AIService.chain(task: "chat.reply", group: nil, settings: s, charPreset: s.charPreset("char_a")).map(\.id), ["svc_third"])
        XCTAssertEqual(CharApi.label(try Repo.character("char_a"), s), "三")
        // 其余任务不跟着角色走
        XCTAssertEqual(AIService.chain(task: "memory.extract", group: RouteGroup.of(task: "memory.extract"), settings: s).first?.id, "svc_spare")

        // 换接口开着：从这一套之后按主用、副用、其余的顺序换
        try presets(fallback: true)
        try choose("svc_third")
        s = AppSettings.load()
        XCTAssertEqual(AIService.chain(task: "chat.reply", group: nil, settings: s, charPreset: s.charPreset("char_a")).map(\.id),
                       ["svc_third", "svc_main", "svc_spare"])

        // 选的那套没填全、被删了：改用主用，不报错
        try presets()
        try choose("svc_half")
        s = AppSettings.load()
        XCTAssertNil(s.charPreset("char_a"))
        XCTAssertEqual(AIService.chain(task: "chat.reply", group: nil, settings: s, charPreset: s.charPreset("char_a")).first?.id, "svc_main")
        XCTAssertEqual(CharApi.label(try Repo.character("char_a"), s), "所选接口未填全，改用主用")
        try choose("svc_gone")
        XCTAssertEqual(CharApi.label(try Repo.character("char_a"), .load()), "所选接口已删除，改用主用")
        try choose("")
        XCTAssertEqual(try Repo.character("char_a")?.row.string("chatApiId"), "")
    }

    // MARK: - Fish Audio（4.808）

    func testFishRequestShape() throws {
        var p = VoicePreset(json: VoicePreset.empty)
        p.json["kind"] = .string("fish")
        p.json["apiKey"] = .string("fk")
        XCTAssertEqual(p.kind, "fish")
        XCTAssertTrue(p.ready, "模型可以留空")
        XCTAssertEqual(p.base, "https://api.fish.audio")
        var r = VoiceGen.fishRequest(p, "你好", "voice_model_1", 3)
        XCTAssertEqual(r.url, "https://api.fish.audio/v1/tts")
        XCTAssertEqual(r.headers["authorization"], "Bearer fk")
        XCTAssertNil(r.headers["model"], "不填型号就不带")
        XCTAssertEqual(r.body["reference_id"], .string("voice_model_1"))
        XCTAssertEqual(r.body["format"], .string("mp3"))
        XCTAssertEqual(r.body["prosody"]?["speed"]?.number, 2, "语速钳在 0.5 到 2")
        XCTAssertNil(r.body["language"])

        p.json["model"] = .string("s1")
        p.json["baseUrl"] = .string("https://relay.test/v1/")
        r = VoiceGen.fishRequest(p, "你好", "", 0.2)
        XCTAssertEqual(r.url, "https://relay.test/v1/tts")
        XCTAssertEqual(r.headers["model"], "s1")
        XCTAssertNil(r.body["reference_id"])
        XCTAssertEqual(r.body["prosody"]?["speed"]?.number, 0.5)
        XCTAssertTrue(VoicePreset.fishModels.contains("s2.1-pro"))
    }

    func testFishScript() {
        let raw = "<情绪 平静>你回来了。<停顿 0.8><声音 叹气><情绪 生气>今天怎么这么晚？"
        let segs = VoiceScript.plan("fish", raw)
        XCTAssertEqual(segs.count, 1, "情绪写在句子里，不切段")
        XCTAssertEqual(VoiceScript.text("fish", segs[0]), "(calm) 你回来了。…… (sighs) (angry) 今天怎么这么晚？")
    }
}
