import XCTest
@testable import Eira

/// 花钱的次数（网页版第 15 条，CostTests 的同一套做法）：网络一律接住，数真正打出去几次。
/// 这一批：本群页面打开时接着聊（自动，默认关，先记「试过」再发）、每个角色的接口（不多打）、
/// 改为语音与图片版本（用户点了才调，每点一次一次，失败不重试）、群红包与退群（不多打）。
final class CostMediaTests: StoreTestCase {
    private var group: Chat!

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        GroupAmbient.reset()
        try importFixture("data.json")
        try setSettings(["currency": .string("CNY"), "services": .object([
            "chat": .object([
                "presets": .array([
                    .object(["id": .string("svc_main"), "name": .string("主"), "provider": .string("anthropic"),
                             "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")]),
                    .object(["id": .string("svc_spare"), "name": .string("副"), "provider": .string("openai"),
                             "baseUrl": .string("https://spare.test/v1"), "apiKey": .string("k"), "model": .string("m")]),
                    .object(["id": .string("svc_third"), "name": .string("三"), "provider": .string("openai"),
                             "baseUrl": .string("https://third.test/v1"), "apiKey": .string("k"), "model": .string("m")]),
                ]),
                "activeId": .string("svc_main"), "fallbackId": .string("svc_spare"),
            ]),
            "voice": .object(["enabled": .bool(true), "activeId": .string("v1"), "presets": .array([.object([
                "id": .string("v1"), "name": .string("测试"), "kind": .string("fish"), "baseUrl": .string("https://tts.test"),
                "apiKey": .string("k"), "model": .string("")])])]),
            "image": .object(["activeId": .string("img_a"), "presets": .array([.object([
                "id": .string("img_a"), "name": .string("测试"), "kind": .string("openai"), "baseUrl": .string("https://img.test/v1"),
                "apiKey": .string("k"), "model": .string("gpt-image-1")])])]),
        ])])
        var c = try XCTUnwrap(Repo.character("char_a"))
        c.row["voiceIds"] = .object(["v1": .string("fish-voice")])
        try Database.shared.put(Collections.characters, c.row)
        let z = try People.createCharacter(name: "小周")
        let me = try People.ensureActivePersona()
        group = try GroupChat.create(memberIds: ["char_a", z.id], title: "", personaId: me.id)
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        GroupAmbient.reset()
        try super.tearDownWithError()
    }

    private func hosts() -> [String] { MockNet.requests.compactMap { $0.url?.host } }
    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    // MARK: - 本群页面打开时接着聊（4.1018）

    func testAmbientDefaultOffAndRegistered() throws {
        XCTAssertFalse(ExtraCalls.switchedOn(.load()).contains { $0.id == "groupAmbient" })
        XCTAssertFalse(GroupAmbient.due(chatId: group.id, draftEmpty: true, busy: false, now: Date().millis + 3_600_000))
        try GroupMore.setAmbient(group.id, .init(page: true, pageMin: 3, perOpen: 10))
        XCTAssertTrue(ExtraCalls.switchedOn(.load()).contains { $0.id == "groupAmbient" })
    }

    /// 接口一直失败时：每满一个间隔一次，失败也算试过，下一次要再等满一个间隔；不重试、不换接口
    func testAmbientFailingCountsOncePerInterval() async throws {
        try GroupMore.setAmbient(group.id, .init(page: true, pageMin: 3, perOpen: 0))
        let t0 = Date().millis
        GroupAmbient.enter(group.id, now: t0 - 10 * 60_000)
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        XCTAssertTrue(GroupAmbient.due(chatId: group.id, draftEmpty: true, busy: false))
        // 输入框里有字、正在生成时不进行，也不记一次
        XCTAssertFalse(GroupAmbient.due(chatId: group.id, draftEmpty: false, busy: false))
        XCTAssertFalse(GroupAmbient.due(chatId: group.id, draftEmpty: true, busy: true))
        do { try await GroupAmbient.round(chatId: group.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(hosts(), ["spare.test"], "任务 group.ambient 走副用")
        let last = GroupAmbient.lastOf(group.id)
        XCTAssertGreaterThan(last.tryAt, 0)
        XCTAssertFalse(last.err.isEmpty)
        // 刚试过：不到一个间隔不再来，满了才再来
        XCTAssertFalse(GroupAmbient.due(chatId: group.id, draftEmpty: true, busy: false, now: Date().millis + 60_000))
        XCTAssertTrue(GroupAmbient.due(chatId: group.id, draftEmpty: true, busy: false, now: Date().millis + 3 * 60_000 + 1000))
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(try Repo.messages(chatId: group.id).isEmpty, "失败不落消息")
    }

    func testAmbientSilentAndPerOpen() async throws {
        try GroupMore.setAmbient(group.id, .init(page: true, pageMin: 1, perOpen: 1))
        GroupAmbient.enter(group.id, now: Date().millis - 5 * 60_000)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.openaiStream("[不回复]")) }
        let made = try await GroupAmbient.round(chatId: group.id)
        XCTAssertTrue(made.isEmpty)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(GroupAmbient.lastOf(group.id).silent)
        // 这次打开最多一轮：到了就不再进行
        XCTAssertFalse(GroupAmbient.due(chatId: group.id, draftEmpty: true, busy: false, now: Date().millis + 3_600_000))
        GroupAmbient.enter(group.id, now: Date().millis - 5 * 60_000)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.openaiStream("林：在呢\n小周：嗯")) }
        let next = try await GroupAmbient.round(chatId: group.id)
        XCTAssertEqual(next.map(\.content), ["在呢", "嗯"])
        XCTAssertEqual(MockNet.count, 1)
    }

    // MARK: - 每个角色单独的聊天接口（4.828）：只换哪一套，不多打

    func testCharRouteStillOneRequest() async throws {
        try CharApi.set("char_a", "svc_third")
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.openaiStream("好")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(hosts(), ["third.test"])

        // 失败：默认不换接口，只打一次
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { try await ChatEngine.reply(chatId: "chat_a") { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(hosts(), ["third.test"])

        // 群聊照旧用主用
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("林：在")) }
        try await ChatEngine.reply(chatId: group.id) { _ in }
        XCTAssertEqual(hosts(), ["main.test"])

        // 选的那一套被删了：改用主用，不报错
        try CharApi.set("char_a", "svc_gone")
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("好")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(hosts(), ["main.test"])
    }

    // MARK: - 改为语音（4.881）：点一次一次语音接口，失败不重试

    func testToVoiceOnceAndNoRetry() async throws {
        try setSettings(["retryMax": .number(3)])
        let m = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "早点睡"))
        MockNet.reset { _, _ in .init(status: 500, body: #"{"message":"boom"}"#) }
        let v = try MsgConvert.toVoice(m)
        XCTAssertEqual(v.kind, "voice")
        XCTAssertEqual(v.content, "[语音：早点睡]")
        XCTAssertEqual(v.row.string("textBefore"), "早点睡")
        let out = await MsgConvert.speak(m.id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(MockNet.requests.first?.url?.absoluteString, "https://tts.test/v1/tts")
        XCTAssertEqual(out?.row.string("media"), "error")
        // 改回文字：原文一字不差，不调接口
        let back = try MsgConvert.fromVoice(try XCTUnwrap(out))
        XCTAssertEqual(back.kind, "text")
        XCTAssertEqual(back.content, "早点睡")
        XCTAssertNil(back.row["voiceText"])
        XCTAssertEqual(MockNet.count, 1)

        // 成功时：一次，音频挂在消息上
        let m2 = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "晚安"))
        MockNet.reset { _, _ in .init(status: 200, body: "ID3") }
        _ = try MsgConvert.toVoice(m2)
        let done = await MsgConvert.speak(m2.id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(done?.row.string("media"), "done")
        XCTAssertFalse(done?.row.string("audioId").isEmpty ?? true)
        let req = try XCTUnwrap(MockNet.requests.first)
        XCTAssertNil(req.value(forHTTPHeaderField: "model"), "Fish Audio 型号留空时不带")
        let body = try JSONValue.parse(XCTUnwrap(req.httpBodyStreamData()))
        XCTAssertEqual(body["reference_id"]?.string, "fish-voice")
        XCTAssertEqual(body["text"]?.string, "晚安")
    }

    // MARK: - 图片版本（4.861）：每版一次生图接口，失败不重试；重画不丢旧的那一张

    private func charImage(_ imageId: String?) throws -> Message {
        var m = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "[图片：猫]", kind: "image")
        m.row["prompt"] = .string("猫")
        m.row["imageId"] = imageId.map { .string($0) } ?? .null
        m.row["media"] = .string(imageId == nil ? "error" : "done")
        return try Repo.append(m)
    }

    func testImageVersionsOneCallEach() async throws {
        try setSettings(["retryMax": .number(3)])
        let m = try charImage("img_old")
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        do { try await ImageVersions.add(m.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(ImageVersions.of(try XCTUnwrap(Database.shared.get(Collections.messages, id: m.id))), ["img_old"])

        MockNet.reset { _, _ in .init(status: 200, body: #"{"data":[{"b64_json":"\#(Self.png)"}]}"#) }
        let a = try await ImageVersions.add(m.id)
        let b = try await ImageVersions.add(m.id)
        XCTAssertEqual(MockNet.count, 2)
        let row = try XCTUnwrap(Database.shared.get(Collections.messages, id: m.id))
        XCTAssertEqual(ImageVersions.of(row), ["img_old", a, b])
        XCTAssertEqual(row.string("imageId"), "img_old", "再生成一版不换掉气泡里那一张")
    }

    func testRedrawKeepsOldVersion() async throws {
        let m = try charImage("img_old")
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        let out = try await ImageGen.regenerate(messageId: m.id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(out?.row.string("media"), "error")
        XCTAssertEqual(out?.row.strings("imageVers"), ["img_old"], "重画失败时旧的那一张仍能挑回来")

        MockNet.reset { _, _ in .init(status: 200, body: #"{"data":[{"b64_json":"\#(Self.png)"}]}"#) }
        let ok = try await ImageGen.regenerate(messageId: m.id)
        XCTAssertEqual(MockNet.count, 1)
        let newId = try XCTUnwrap(ok?.imageId)
        XCTAssertEqual(ok?.row.strings("imageVers"), ["img_old", newId])
    }

    // MARK: - 群红包、退群、改网名：不另调接口

    func testGroupMarksStayOneRequest() async throws {
        try setSettings(["featureOpt": .object(["grouppay": .string("on"), "groupleave": .string("on"), "selfnick": .string("on")])])
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("林：[红包：10｜2]\n小周：[领红包]\n林：[改网名：夜行]")) }
        try await ChatEngine.reply(chatId: group.id) { _ in }
        XCTAssertEqual(MockNet.count, 1)
        let todayN = await Usage.shared.today()
        XCTAssertEqual(todayN, 1)
    }
}
