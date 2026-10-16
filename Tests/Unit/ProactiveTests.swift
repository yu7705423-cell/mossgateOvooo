import XCTest
@testable import Eira

/// 主动发起对话与后台消息：默认不发；到点先排下一次再发，接口一直失败也只打一次；服务器管着时本机不发；
/// 交给服务器的任务里带着整份请求；取回结果只落进会话，不调模型。
final class ProactiveTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: "phone.proactive.next")
        BgPush.setDevice(nil)
        URLProtocol.registerClass(MockNet.self)
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        chat.row["unread"] = .number(0)
        chat.row["lastMessageAt"] = .number(0)
        try Repo.save(chat)
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        UserDefaults.standard.removeObject(forKey: "phone.proactive.next")
        BgPush.setDevice(nil)
        try super.tearDownWithError()
    }

    /// 打开这个角色的开关；免打扰设成不设，不受跑测试的时刻影响。
    private func turnOn() throws {
        var c = try XCTUnwrap(Repo.character("char_a"))
        c.row["proactive"] = .bool(true)
        c.row["proactiveMinutes"] = .number(60)
        c.row["proactiveQuietFrom"] = .number(0)
        c.row["proactiveQuietTo"] = .number(0)
        try Database.shared.put(Collections.characters, c.row)
    }

    /// 这段会话的最后一条消息放到很久以前，不算「正在聊」。
    private func quiet() throws {
        for m in try Repo.messages(chatId: "chat_a") {
            var row = m.row
            row["createdAt"] = .number(1_000_000)
            try Database.shared.put(Collections.messages, row)
        }
    }

    func testOffByDefault() async throws {
        XCTAssertFalse(ExtraCalls.switchedOn(.load()).contains { $0.id == "proactive" })
        let fired = await Proactive.tick()
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(MockNet.count, 0)
    }

    /// 接口一直失败：到点打一次，落点先挪走；紧接着再巡检一次不再打。
    func testFailingApiOncePerInterval() async throws {
        try turnOn()
        try quiet()
        XCTAssertTrue(ExtraCalls.switchedOn(.load()).contains { $0.id == "proactive" })
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        let now = Date().millis
        // 第一次巡检只掷落点，不发
        _ = await Proactive.tick(now: now)
        XCTAssertEqual(MockNet.count, 0)
        Proactive.setNext("char_a", now - 1000)
        _ = await Proactive.tick(now: now)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertGreaterThan(Proactive.nextAt("char_a"), now)
        _ = await Proactive.tick(now: now + 1000)
        XCTAssertEqual(MockNet.count, 1)
    }

    /// 服务器管着：本机不发，落点也不动。
    func testHeldByServer() async throws {
        try turnOn()
        try quiet()
        let now = Date().millis
        Proactive.setNext("char_a", now - 1000)
        _ = await Proactive.tick(now: now, holds: true)
        XCTAssertEqual(MockNet.count, 0)
        XCTAssertEqual(Proactive.nextAt("char_a"), now - 1000)
    }

    /// 成功：落成一轮，未读加上。
    func testSendLandsTurn() async throws {
        try turnOn()
        try quiet()
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("在忙吗")) }
        Proactive.setNext("char_a", Date().millis - 1000)
        let fired = await Proactive.tick()
        XCTAssertEqual(fired, ["char_a"])
        XCTAssertEqual(MockNet.count, 1)
        let body = String(data: try XCTUnwrap(MockNet.requests.first?.httpBodyStreamData()), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("You are the one opening this time"))
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.content, "在忙吗")
        XCTAssertEqual(try Repo.chat("chat_a")?.unread, 1)
    }

    /// 交给服务器的任务：不调任何接口；时间几次、请求的地址与留给服务器填的记号都在。
    func testJobsCarryRequest() throws {
        try turnOn()
        try quiet()
        try setSettings(["bgPush": .object(["on": .bool(true), "server": .string("https://push.test"), "perChar": .number(2)])])
        let jobs = try BgPush.jobsNow()
        XCTAssertEqual(MockNet.count, 0)
        let job = try XCTUnwrap(jobs.first { $0["charId"]?.string == "char_a" })
        XCTAssertEqual(job["due"]?.array?.count, 2)
        XCTAssertEqual(job["request"]?["provider"]?.string, "anthropic")
        XCTAssertEqual(job["request"]?["url"]?.string, "https://main.test/v1/messages")
        let body = String(data: try XCTUnwrap(job["request"]?["body"]).encoded(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(BgPush.markTime))
        XCTAssertNil(job["request"]?["body"]?["stream"])
    }

    /// 取回结果：成功的落进会话（时间是服务器发出的那一刻），失败的不补发；只有 /results 与 /ack 两个请求。
    @MainActor
    func testCollect() async throws {
        try turnOn()
        try setSettings(["bgPush": .object(["on": .bool(true), "server": .string("https://push.test")])])
        BgPush.setDevice(.init(server: "https://push.test", id: "d1", token: "t", endpoint: ""))
        let results = #"{"results":[{"id":"00000000-0000-0000-0000-000000000001","status":"done","firedAt":1700000000000,"chatId":"chat_a","charId":"char_a","text":"早"},{"id":"00000000-0000-0000-0000-000000000002","status":"failed","firedAt":1700000001000,"charId":"char_a","error":"接口 500"}]}"#
        MockNet.reset { r, _ in
            if r.url?.path == "/results" { return .init(status: 200, body: results) }
            return .init(status: 200, body: #"{"ok":true}"#)
        }
        let n = try await BgPush.shared.collect()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(MockNet.requests.map { $0.url?.path ?? "" }, ["/results", "/ack"])
        XCTAssertEqual(MockNet.requests.first?.value(forHTTPHeaderField: "authorization"), "Bearer d1.t")
        let row = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.content == "早" })
        XCTAssertEqual(row.row.number("createdAt"), 1700000000000)
        XCTAssertTrue(row.turnId.hasPrefix("bg-"))
        XCTAssertFalse(BgPush.shared.problem.isEmpty)
        XCTAssertGreaterThan(Proactive.nextAt("char_a"), Date().millis)
    }

    /// 群里主动开口：默认关；接口一直失败时到点只打一次，落点先挪走；应用在后台时不发
    func testGroupFailingOncePerInterval() async throws {
        let z = try People.createCharacter(name: "小周")
        var g = try GroupChat.create(memberIds: ["char_a", z.id], title: "", personaId: "me_root")
        // 刚建的群算「正在聊」（落点会顺延），放到很久以前
        g.row["lastMessageAt"] = .number(1_000_000)
        try Repo.save(g)
        XCTAssertFalse(GroupProactive.config(g).on)
        XCTAssertFalse(ExtraCalls.switchedOn(.load()).contains { $0.id == "groupProactive" })
        try GroupProactive.save(g.id, Proactive.Config(on: true, minutes: 60, quietFrom: 0, quietTo: 0))
        XCTAssertTrue(ExtraCalls.switchedOn(.load()).contains { $0.id == "groupProactive" })
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        let now = Date().millis
        Proactive.setNext(GroupProactive.key(g.id), now - 1000)
        _ = await GroupProactive.tick(now: now, holds: true)
        XCTAssertEqual(MockNet.count, 0)
        _ = await GroupProactive.tick(now: now)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertGreaterThan(GroupProactive.nextAt(g.id), now)
        _ = await GroupProactive.tick(now: now + 1000)
        XCTAssertEqual(MockNet.count, 1)
    }

    /// 深夜那一档：默认关；到了时段、接口一直失败时只打一次，先记试过，之后要隔够天数
    func testEmoOncePerDays() async throws {
        try turnOn()
        try quiet()
        // 深夜那一档不单列一项，并在「角色主动发消息」里（网页版 cost.js）
        XCTAssertNil(ExtraCalls.all.first(where: { $0.id == "emo" }))
        XCTAssertTrue(ExtraCalls.all.first(where: { $0.id == "proactive" })?.when(.load()).contains("深夜那一档另算") == true)
        var c = try XCTUnwrap(Repo.character("char_a"))
        c.row["emo"] = .bool(true)
        c.row["emoFrom"] = .number(0)
        c.row["emoTo"] = .number(23)
        c.row["emoDays"] = .number(5)
        try Database.shared.put(Collections.characters, c.row)
        Proactive.setEmoAt("char_a", 0)
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        let cal = Calendar.current
        let now = cal.date(bySettingHour: 2, minute: 0, second: 0, of: Date())!.millis
        Proactive.setNext("char_a", now - 1000)
        _ = await Proactive.tick(now: now)
        XCTAssertEqual(MockNet.count, 1)
        let body = String(decoding: MockNet.requests.first?.httpBodyStreamData() ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("during the night"))
        XCTAssertEqual(Proactive.emoAt("char_a"), now)
        // 一天后到点：还没隔够五天，走平常那一档（同样失败一次）
        Proactive.setNext("char_a", now + 86_400_000 - 1000)
        _ = await Proactive.tick(now: now + 86_400_000)
        XCTAssertEqual(MockNet.count, 2)
        XCTAssertFalse(String(decoding: MockNet.requests.last?.httpBodyStreamData() ?? Data(), as: UTF8.self).contains("during the night"))
    }
}

/// 当面时、回复正在生成时不主动发（网页版 proactive.js 的 chatFor：face.on、isReplying）
extension ProactiveTests {
    func testNotWhileFaceToFace() async throws {
        try turnOn()
        try quiet()
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        chat.row["face"] = .object(["on": .bool(true)])
        try Repo.save(chat)
        XCTAssertNil(Proactive.chatReady("char_a"))
        let now = Date().millis
        Proactive.setNext("char_a", now - 1000)
        let fired = await Proactive.tick(now: now)
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(MockNet.count, 0)

        chat = try XCTUnwrap(Repo.chat("chat_a"))
        chat.row["face"] = .object(["on": .bool(false)])
        try Repo.save(chat)
        XCTAssertNotNil(Proactive.chatReady("char_a"))
    }

    func testNotWhileReplying() async throws {
        try turnOn()
        try quiet()
        ChatEngine.Replying.begin("chat_a")
        XCTAssertNil(Proactive.chatReady("char_a"))
        let now = Date().millis
        Proactive.setNext("char_a", now - 1000)
        let fired = await Proactive.tick(now: now)
        ChatEngine.Replying.end("chat_a")
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(MockNet.count, 0)
        XCTAssertNotNil(Proactive.chatReady("char_a"))
    }
}

/// 群成员私下找你（网页版 4.649）：只在群里认识、还没有单聊的角色，到点时建一段单聊再发；建的那一刻不算刚聊过。
/// 接口一直失败也只打一次；既没有单聊也不在群里的，不建会话、不调接口
extension ProactiveTests {
    func testGroupMemberGetsPrivateChat() async throws {
        let me = try XCTUnwrap(Repo.activePersona()).id
        var zhou = try People.createCharacter(name: "小周")
        zhou.row["proactive"] = .bool(true)
        zhou.row["proactiveMinutes"] = .number(60)
        zhou.row["proactiveQuietFrom"] = .number(0)
        zhou.row["proactiveQuietTo"] = .number(0)
        try Database.shared.put(Collections.characters, zhou.row)
        XCTAssertNil(Proactive.soloChat(zhou.id))
        _ = try GroupChat.create(memberIds: ["char_a", zhou.id], title: "", personaId: me)
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        let now = Date().millis
        Proactive.setNext(zhou.id, now - 1000)
        let fired = await Proactive.tick(now: now)
        XCTAssertEqual(fired, [zhou.id])
        XCTAssertEqual(MockNet.count, 1)
        let solo = try XCTUnwrap(Proactive.soloChat(zhou.id))
        XCTAssertFalse(solo.isGroup)
        XCTAssertEqual(solo.characterIds, [zhou.id])
        XCTAssertEqual(solo.row.number("lastMessageAt"), 0)
        // 再巡检一次：落点已挪走，不再打；不重复建会话
        _ = await Proactive.tick(now: now + 1000)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(try Repo.chats().filter { $0.characterIds == [zhou.id] && !$0.isGroup }.count, 1)
    }

    func testStrangerGetsNoChat() async throws {
        var lone = try People.createCharacter(name: "路人")
        lone.row["proactive"] = .bool(true)
        lone.row["proactiveQuietFrom"] = .number(0)
        lone.row["proactiveQuietTo"] = .number(0)
        try Database.shared.put(Collections.characters, lone.row)
        let now = Date().millis
        Proactive.setNext(lone.id, now - 1000)
        let fired = await Proactive.tick(now: now)
        XCTAssertFalse(fired.contains(lone.id))
        XCTAssertEqual(MockNet.count, 0)
        XCTAssertNil(Proactive.soloChat(lone.id))
    }
}
