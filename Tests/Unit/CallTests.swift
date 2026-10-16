import XCTest
@testable import Eira

/// 通话：一轮一次请求（重试最多一次，再取用户的上限）；挂断落一条记录；总结默认开、一通一次。
final class CallTests: StoreTestCase {
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

    func testPrepareUsesCallRules() throws {
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        chat.row["translateTo"] = .string("English")
        let p = try CallEngine.prepare(chat: chat, char: XCTUnwrap(Repo.character("char_a")))
        XCTAssertTrue(p.system.contains("[正在通话中]"))
        XCTAssertTrue(p.system.contains("a phone call"))
        // 设了翻译语言：每句后面跟 [译文：…]，同一次回复里写（网页版 4.633）；聊天那一段「顺带给出译文」不进通话
        XCTAssertTrue(p.system.contains("[译文：<that sentence in English>]"))
        XCTAssertFalse(p.system.contains("[顺带给出译文]"))
        XCTAssertTrue(p.system.contains("Use no bracketed markers of any kind"))
        chat.row["translateTo"] = .string("")
        let plain = try CallEngine.prepare(chat: chat, char: XCTUnwrap(Repo.character("char_a")))
        XCTAssertTrue(plain.system.contains("Do not repeat your line or add a translation"))
    }

    func testVideoCall() async throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let p = try CallEngine.prepare(chat: chat, char: XCTUnwrap(Repo.character("char_a")), video: true)
        XCTAssertTrue(p.system.contains("a video call"))
        XCTAssertTrue(p.system.contains("[动作：…]"))
        XCTAssertTrue(p.system.contains("frames from their camera"))
        // 画面挂在我最后那句上，一轮仍是一次请求
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("[动作：挥手]你好")) }
        let frame = AIImage(mediaType: "image/jpeg", base64: "AAAA")
        _ = try await CallEngine.turn(p, lines: [.init(role: "user", text: "看得见吗")], image: frame)
        XCTAssertEqual(MockNet.count, 1)
        let body = try XCTUnwrap(MockNet.requests.first?.httpBodyStreamData())
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("AAAA"))

        // 动作不念、字幕里换成括号；译文不念、另起一行
        let line = "[动作：挥手]你好 [译文：Hello]"
        XCTAssertEqual(CallEngine.speakable(line), "你好")
        XCTAssertEqual(CallEngine.subtitle(line), "（挥手）你好\nHello")
        XCTAssertEqual(CallEngine.lastAct(line), "挥手")
        XCTAssertEqual(CallEngine.speakable("好的[动"), "好的")
        XCTAssertEqual(CallEngine.label(direction: "in", outcome: "missed", seconds: 0, video: true), "未接视频通话")

        let m = try CallEngine.finish(chatId: "chat_a", charId: "char_a", direction: "out", outcome: "done", seconds: 65,
                                      lines: [.init(role: "char", text: line)], userName: "小于", charName: "林", video: true)
        XCTAssertTrue(m.content.hasPrefix("[视频通话 01:05]"))
        XCTAssertEqual(m.row["callKind"], .string("video"))
        XCTAssertTrue(m.content.contains("（挥手）"))
    }

    func testTurnIsOneRequestWithCap() async throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let p = try CallEngine.prepare(chat: chat, char: XCTUnwrap(Repo.character("char_a")))
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("喂？")) }
        let text = try await CallEngine.turn(p, lines: [], opening: CallEngine.openingLine(outgoing: true))
        XCTAssertEqual(text, "喂？")
        XCTAssertEqual(MockNet.count, 1)
        let body = try JSONValue.parse(XCTUnwrap(MockNet.requests.first?.httpBodyStreamData()))
        XCTAssertEqual(body["max_tokens"]?.number, 400)

        // 一直失败：开了三次重试也只多试一次
        try setSettings(["retryMax": .number(3)])
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        do { _ = try await CallEngine.turn(p, lines: [.init(role: "user", text: "在吗")]); XCTFail("应当报错") } catch {}
        XCTAssertEqual(MockNet.count, 2)
    }

    func testFinishAndSummaryOnce() async throws {
        XCTAssertTrue(ExtraCalls.active(.load()).contains { $0.id == "callSummary" })
        let lines: [CallEngine.Line] = [.init(role: "char", text: "喂？"), .init(role: "user", text: "是我")]
        let m = try CallEngine.finish(chatId: "chat_a", charId: "char_a", direction: "out", outcome: "done", seconds: 65,
                                      lines: lines, userName: "小于", charName: "林")
        XCTAssertEqual(m.content, "[语音通话 01:05]\n林：喂？\n小于：是我")
        XCTAssertEqual(m.kind, "call")
        XCTAssertTrue(CallEngine.autoSummary(outcome: "done", lines: lines))
        XCTAssertFalse(CallEngine.autoSummary(outcome: "cancelled", lines: lines))

        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        do { try await CallEngine.summarize(messageId: m.id); XCTFail("应当报错") } catch {}
        XCTAssertEqual(MockNet.count, 1)

        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("两人通了电话。")) }
        try await CallEngine.summarize(messageId: m.id)
        XCTAssertEqual(try Database.shared.get(Collections.messages, id: m.id)?.string("callSummary"), "两人通了电话。")

        // 关掉之后不自动写
        try setSettings(["callSummary": .bool(false)])
        XCTAssertFalse(CallEngine.autoSummary(outcome: "done", lines: lines))
    }
    /// 括起来的那一截（网页版 call.js speakable / splitNote，4.478）：行首或句末标点之后开始的不念；
    /// 收尾时和原话一样的扔掉，是这段对话要的译文就当译文，其余留在字幕里
    func testParenNotes() throws {
        XCTAssertEqual(CallEngine.speakable("（叹气）好吧。（小声）算了"), "好吧。算了")
        XCTAssertEqual(CallEngine.speakable("你好（笑）"), "你好（笑）")
        XCTAssertEqual(CallEngine.speakable("好的。（没说完"), "好的。")
        XCTAssertEqual(CallEngine.speakable("[动作：挥手]你好。\n（I'm here.）"), "你好。")

        XCTAssertEqual(CallEngine.splitNote("我在。（I'm here.）").main, "我在。")
        XCTAssertEqual(CallEngine.splitNote("我在。（I'm here.）").note, "I'm here.")
        XCTAssertEqual(CallEngine.splitNote("你好（笑）").note, "")

        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        chat.row["translateTo"] = .string("English")
        // 是译文：从台词里拿掉，当译文
        let a = CallEngine.settle("我在。（I'm here.）", chat: chat)
        XCTAssertEqual(a.text, "我在。")
        XCTAssertEqual(a.trans, "I'm here.")
        XCTAssertEqual(CallEngine.subtitle(CallEngine.Line(role: "char", text: a.text, trans: a.trans)), "我在。\nI'm here.")
        // 重复原话：扔掉
        let b = CallEngine.settle("好的。（好的！）", chat: chat)
        XCTAssertEqual(b.text, "好的。")
        XCTAssertEqual(b.trans, "")
        // 其余的留在字幕里，照样不念
        let c = CallEngine.settle("好的。（叹气）", chat: chat)
        XCTAssertEqual(c.text, "好的。（叹气）")
        XCTAssertEqual(c.trans, "")
        XCTAssertEqual(CallEngine.speakable(c.text), "好的。")
        // 没设翻译语言：英文那一截不算译文，留着
        chat.row["translateTo"] = .string("")
        XCTAssertEqual(CallEngine.settle("我在。（I'm here.）", chat: chat).text, "我在。（I'm here.）")
    }

    /// 已经是目标语言的不送去翻（网页版 translate.alreadyIn，4.570）
    func testAlreadyIn() {
        XCTAssertTrue(CallEngine.alreadyIn("你好，今天怎么样", "中文"))
        XCTAssertTrue(CallEngine.alreadyIn("好的 ok", "简体中文"))
        XCTAssertFalse(CallEngine.alreadyIn("宝贝我好想你 my love", "中文"))
        XCTAssertFalse(CallEngine.alreadyIn("想你了，мой милый", "中文"))
        XCTAssertTrue(CallEngine.alreadyIn("See you!", "English"))
        XCTAssertFalse(CallEngine.alreadyIn("See 你", "en"))
        XCTAssertTrue(CallEngine.alreadyIn("こんにちは", "日语"))
        XCTAssertTrue(CallEngine.alreadyIn("안녕", "韩语"))
        XCTAssertFalse(CallEngine.alreadyIn("Bonjour", "法语"))
    }

    private func translateApi(_ on: Bool, lang: String) throws {
        var services: [String: JSONValue] = ["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])]
        if on {
            services["translate"] = .object(["mode": .string("api"), "provider": .string("anthropic"),
                                             "baseUrl": .string("https://tr.test"), "apiKey": .string("k"), "model": .string("t")])
        }
        try setSettings(["services": .object(services)])
        var c = try XCTUnwrap(Repo.chat("chat_a"))
        c.row["translateTo"] = .string(lang)
        try Repo.save(c)
    }

    /// 单独配了翻译接口：通话提示词里不让模型写译文，一轮说完逐句交给翻译接口，一轮一次；
    /// 已经是目标语言的句子不送，整轮都是就不调；随回复写译文那一档一次都不调（网页版 transLine，4.633）
    func testCallTranslateApi() async throws {
        try translateApi(true, lang: "中文")
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let p = try CallEngine.prepare(chat: chat, char: XCTUnwrap(Repo.character("char_a")))
        XCTAssertFalse(p.system.contains("[译文："))
        XCTAssertTrue(p.system.contains("Do not repeat your line or add a translation"))

        MockNet.reset { r, _ in
            if r.url?.host == "tr.test" { return .init(status: 200, body: MockNet.anthropicStream(#"{"lines":["你好啊！","再见！"]}"#)) }
            return .init(status: 500, body: "{}")
        }
        let text = "Hello there! 你好。[动作：挥手]See you!"
        let segs = try await CallEngine.translateLine(chat: chat, text: text)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(MockNet.requests.first?.url?.host, "tr.test")
        let body = String(decoding: MockNet.requests.first?.httpBodyStreamData() ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("2. See you!"))
        XCTAssertFalse(body.contains("挥手"))
        XCTAssertEqual(segs ?? [], [CallEngine.Seg(t: "Hello there!", tr: "你好啊！"), CallEngine.Seg(t: "你好。", tr: ""),
                                    CallEngine.Seg(t: "[动作：挥手]See you!", tr: "再见！")])
        XCTAssertEqual(CallEngine.subtitle(CallEngine.Line(role: "char", text: text, segs: segs ?? [])),
                       "Hello there!\n你好啊！\n你好。\n（挥手）See you!\n再见！")

        // 整轮都已是目标语言：不调
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        let none = try await CallEngine.translateLine(chat: chat, text: "你好。今天怎么样？")
        XCTAssertNil(none)
        XCTAssertEqual(MockNet.count, 0)

        // 翻译接口一直失败：一轮只打一次，不重试
        try setSettings(["retryMax": .number(3)])
        do { _ = try await CallEngine.translateLine(chat: chat, text: "Hello!"); XCTFail("应当报错") } catch {}
        XCTAssertEqual(MockNet.count, 1)

        // 晚到的译文写回通话记录
        let m = try CallEngine.finish(chatId: "chat_a", charId: "char_a", direction: "out", outcome: "done", seconds: 5,
                                      lines: [.init(role: "char", text: "Hello!")], userName: "小于", charName: "林")
        try CallEngine.storeSegs(messageId: m.id, index: 0, text: "Hello!", segs: [CallEngine.Seg(t: "Hello!", tr: "你好！")])
        let log = try XCTUnwrap(Database.shared.get(Collections.messages, id: m.id)?["callLog"]?.array?.first?.object)
        XCTAssertEqual(CallEngine.subtitle(log: log), "Hello!\n你好！")

        // 随回复写译文那一档：提示词里让模型写 [译文：…]，不另调接口
        try translateApi(false, lang: "中文")
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        let inline = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertTrue(try CallEngine.prepare(chat: inline, char: XCTUnwrap(Repo.character("char_a"))).system.contains("[译文："))
        let skipped = try await CallEngine.translateLine(chat: inline, text: "Hello!")
        XCTAssertNil(skipped)
        XCTAssertEqual(MockNet.count, 0)
    }

    /// 角色写了 [去电] 而人不在这段对话里：不响铃，记一条未接来电，不调接口
    func testRingWhenAwayIsMissed() async throws {
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        let before = try XCTUnwrap(Repo.chat("chat_a")).unread
        await MainActor.run { CallEngine.ring(chatId: "chat_a", charId: "char_a") }
        let last = try XCTUnwrap(Repo.messages(chatId: "chat_a").last)
        XCTAssertEqual(last.kind, "call")
        XCTAssertEqual(last.row.string("direction"), "in")
        XCTAssertEqual(last.row.string("outcome"), "missed")
        XCTAssertEqual(last.content, "[未接语音通话]")
        XCTAssertEqual(try XCTUnwrap(Repo.chat("chat_a")).unread, before + 1)
        XCTAssertEqual(MockNet.count, 0)
    }

    /// 回复里的 [去电] 不落气泡；提示词里写着怎么打
    func testRingMarkInReply() async throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let built = try ChatPrompt.build(chat: chat, char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertTrue((built.system + built.messages.map(\.content).joined()).contains("[去电]"))
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("等一下\n[去电]")) }
        let before = try Repo.messages(chatId: "chat_a").count
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        let after = try Repo.messages(chatId: "chat_a")
        XCTAssertFalse(after.contains { $0.content.contains("去电") })
        // 回复那一条落下；来电在主线程上随后记下（不在这段对话里，记为未接）
        XCTAssertEqual(after.dropFirst(before).first?.content, "等一下")
    }
    /// 接不接你的来电（网页版 4.170）：默认总是接；「按作息」时免打扰时段内 15% 接、其余 90%；
    /// 拨出去先响 2.5 到 6 秒，响铃期间不发任何请求
    @MainActor
    func testCallAnswerAndDialWait() throws {
        var char = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(CallEngine.answerOf(char), "always")
        XCTAssertTrue(CallEngine.willAnswer(char, roll: 0.999))

        char.row["callAnswer"] = .string("schedule")
        char.row["proactiveQuietFrom"] = .number(0)
        char.row["proactiveQuietTo"] = .number(8)
        XCTAssertEqual(CallEngine.answerOf(char), "schedule")
        let night = try XCTUnwrap(Calendar.current.date(bySettingHour: 3, minute: 0, second: 0, of: Date()))
        let noon = try XCTUnwrap(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        XCTAssertTrue(CallEngine.willAnswer(char, at: night, roll: 0.1))
        XCTAssertFalse(CallEngine.willAnswer(char, at: night, roll: 0.2))
        XCTAssertTrue(CallEngine.willAnswer(char, at: noon, roll: 0.85))
        XCTAssertFalse(CallEngine.willAnswer(char, at: noon, roll: 0.95))
        XCTAssertTrue(CallEngine.answerInfo(char).contains("0:00 到 8:00"))
        char.row["callAnswer"] = .string("bogus")
        XCTAssertEqual(CallEngine.answerOf(char), "always")

        XCTAssertEqual(CallEngine.dialWait(roll: 0), 2.5, accuracy: 0.001)
        XCTAssertEqual(CallEngine.dialWait(roll: 1), 6, accuracy: 0.001)
        for _ in 0..<50 { XCTAssertTrue((2.5...6).contains(CallEngine.dialWait())) }

        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        let session = CallSession(chatId: "chat_a", char: try XCTUnwrap(Repo.character("char_a")))
        session.dial()
        XCTAssertEqual(session.phase, .connecting, "拨出去先响铃，不立刻接通")
        XCTAssertEqual(MockNet.count, 0)
        session.hangUp()
        XCTAssertEqual(session.outcome, "cancelled")
    }
}
