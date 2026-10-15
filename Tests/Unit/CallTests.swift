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
}
