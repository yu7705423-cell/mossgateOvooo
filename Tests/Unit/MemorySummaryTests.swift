import XCTest
@testable import Eira

/// 总结记忆：落库的样子、水位线；自动总结默认不调，接口一直失败时一个间隔只打一次（网页版第 15 条）。
final class MemorySummaryTests: StoreTestCase {
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

    private func reply(_ json: String) {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream(json)) }
    }

    func testExtractAppliesOps() async throws {
        reply(#"""
        {"events":[{"content":"小于提到周末去爬山","at":"2026-10-10","rank":"B","keywords":["爬山"],"weight":1,"about":"user"}],
         "facts":[{"content":"小于喜欢狗","since":"","slot":"","rank":"A","keywords":["狗"],"about":"user","replaces":"mem_2"}],
         "ended":[],
         "open":[{"content":"小于在等面试结果","since":"","due":"2026-10-20","keywords":["面试"],"about":"user"}],
         "closed":[],
         "state":{"user":"小于最近在找工作","recent":"天气转凉"},
         "spending":[]}
        """#)
        let r = try await MemorySummary.extract(chatId: "chat_a")
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(r.added, 3)
        XCTAssertEqual(r.updated, 1)
        XCTAssertEqual(r.state, 2)
        let mems = try Repo.memories(charId: "char_a")
        let dog = try XCTUnwrap(mems.first { $0.content == "小于喜欢狗" })
        XCTAssertEqual(dog.row.string("source"), "auto")
        XCTAssertEqual(dog.row.string("replaces"), "mem_2")
        XCTAssertEqual(mems.first { $0.id == "mem_2" }?.supersededBy, dog.id)
        let open = try XCTUnwrap(mems.first { $0.content == "小于在等面试结果" })
        XCTAssertEqual(open.kind, .open)
        XCTAssertEqual(open.row.string("dueAt"), "2026-10-20")
        let char = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(char.row["states"]?["me_root"]?["blocks"]?["user"]?.string, "小于最近在找工作")
        // 水位线挪到最后一条，积压清零
        XCTAssertEqual(try MemorySummary.pending(chatId: "chat_a").count, 0)
        // 请求里带着已有记忆的 id 与对话
        let body = String(data: MockNet.requests[0].httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("(id:mem_2)"))
        XCTAssertTrue(body.contains("你好"))

        // 了结：进行中的那一条标成完成
        _ = try ChatEngine.send(text: "面试过了", chatId: "chat_a")
        _ = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "恭喜", turnId: "t9"))
        reply(#"{"events":[],"facts":[],"ended":[],"open":[],"closed":[{"id":"\#(open.id)","on":"2026-10-14","result":"通过了"}]}"#)
        let r2 = try await MemorySummary.extract(chatId: "chat_a")
        XCTAssertEqual(r2.closed, 1)
        let closed = try XCTUnwrap(Repo.memories(charId: "char_a").first { $0.id == open.id })
        XCTAssertEqual(closed.status, "done")
        XCTAssertEqual(closed.row.string("result"), "通过了")
    }

    /// 默认设置：自动总结一次都不调。
    func testAutoOffByDefault() async throws {
        reply("{}")
        let r = await MemorySummary.autoRun(chatId: "chat_a")
        XCTAssertNil(r)
        XCTAssertEqual(MockNet.count, 0)
        XCTAssertTrue(ExtraCalls.switchedOn(.load()).isEmpty)
    }

    /// 接口一直失败：门槛到了只打一次；没攒够下一个间隔之前不再打；攒够了再打一次。
    func testAutoFailingOncePerInterval() async throws {
        try setSettings(["autoSummarizeInterval": .number(1)])
        XCTAssertEqual(ExtraCalls.switchedOn(.load()).map(\.id), ["autoSummarize"])
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        _ = await MemorySummary.autoRun(chatId: "chat_a")
        XCTAssertEqual(MockNet.count, 1)
        _ = await MemorySummary.autoRun(chatId: "chat_a")
        _ = await MemorySummary.autoRun(chatId: "chat_a")
        XCTAssertEqual(MockNet.count, 1)
        // 失败了水位线不动，积压还在
        XCTAssertEqual(try MemorySummary.pending(chatId: "chat_a").count, 3)
        // 又聊了一轮：再试一次
        _ = try ChatEngine.send(text: "在吗", chatId: "chat_a")
        _ = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "在", turnId: "t1"))
        _ = await MemorySummary.autoRun(chatId: "chat_a")
        XCTAssertEqual(MockNet.count, 2)
    }

    func testMarkCaughtUp() throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("{}")) }
        XCTAssertEqual(try MemorySummary.markCaughtUp(chatId: "chat_a"), 3)
        XCTAssertEqual(try MemorySummary.pending(chatId: "chat_a").count, 0)
        XCTAssertEqual(MockNet.count, 0)
    }

    func testTimeline() {
        let base = Date(timeIntervalSince1970: 1_760_000_000).millis
        var a = Message.new(chatId: "c", role: .user, authorId: "me", content: "早")
        a.row["createdAt"] = .number(base)
        var b = Message.new(chatId: "c", role: .char, authorId: "x", content: "早安")
        b.row["createdAt"] = .number(base + 60_000)
        var c = Message.new(chatId: "c", role: .user, authorId: "me", content: "我回来了")
        c.row["createdAt"] = .number(base + 3 * 3_600_000)
        let t = MemorySummary.timeline([a, b, c]) { $0.role == .user ? "小于" : "林" }
        let lines = t.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("["))
        XCTAssertEqual(lines[1], "小于：早")
        XCTAssertEqual(lines[2], "林：早安")
        XCTAssertTrue(lines[3].range(of: #"^\[\d{2}:\d{2}\] 小于：我回来了$"#, options: .regularExpression) != nil)
    }

    /// 时间线按用户的时区与虚拟时间写（网页版 clock.toWorld），线上 / 线下切换写成「[以下当面]」「[以下在手机上]」
    func testTimelineZoneVirtualAndFace() {
        var s = AppSettings.load()
        let base = Date(timeIntervalSince1970: 1_760_000_000).millis  // 2025-10-09 08:53:20 UTC，周四
        s.raw["timeZoneUser"] = .string("Asia/Tokyo")
        s.raw["timeMode"] = .string("virtual")
        s.raw["timeSetAt"] = .number(base)
        s.raw["timeVirtualAt"] = .number(base + 86_400_000)  // 虚拟时间快一天
        var a = Message.new(chatId: "c", role: .user, authorId: "me", content: "早")
        a.row["createdAt"] = .number(base)
        var mark = Message.new(chatId: "c", role: .user, authorId: "me", content: "[线下]", kind: "side")
        mark.row["side"] = .string(Face.FACE)
        mark.row["createdAt"] = .number(base + 30_000)
        var b = Message.new(chatId: "c", role: .char, authorId: "x", content: "到了")
        b.row["createdAt"] = .number(base + 60_000)
        var back = Message.new(chatId: "c", role: .user, authorId: "me", content: "[回到线上]", kind: "side")
        back.row["side"] = .string(Face.PHONE)
        back.row["createdAt"] = .number(base + 90_000)
        var c = Message.new(chatId: "c", role: .user, authorId: "me", content: "我回来了")
        c.row["createdAt"] = .number(base + 3 * 3_600_000)
        let lines = MemorySummary.timeline([a, mark, b, back, c], settings: s) { $0.role == .user ? "小于" : "林" }
            .components(separatedBy: "\n")
        XCTAssertEqual(lines, ["[2025-10-10 周五]", "小于：早", "[以下当面]", "林：到了", "[以下在手机上]", "[20:53] 小于：我回来了"])
        // 今天是哪天：同样按虚拟时间与用户时区
        XCTAssertEqual(MemorySummary.todayText(Date(millis: base), settings: s), "2025-10-10 (周五), 17:53")
    }

    /// 用途为「记忆总结」的世界书（4.395）：命中的与常驻的接在总结的提示词后面；没命中的、聊天用的书不进
    func testMemoryLoreInSummary() async throws {
        func entry(_ id: String, _ content: String, keys: [String] = [], constant: Bool = false) -> JSONValue {
            .object(["id": .string(id), "content": .string(content), "keys": .array(keys.map { .string($0) }),
                     "constant": .bool(constant), "enabled": .bool(true)])
        }
        try Database.shared.put(Collections.lorebooks, Row.new(prefix: "lb", [
            "name": .string("总结用"), "global": .bool(true), "forMemory": .bool(true),
            "entries": .array([entry("e1", "LORE-HIT", keys: ["你好"]), entry("e2", "LORE-MISS", keys: ["不会出现的词"]),
                               entry("e3", "LORE-CONST", constant: true)]),
        ]))
        try Database.shared.put(Collections.lorebooks, Row.new(prefix: "lb", [
            "name": .string("聊天用"), "global": .bool(true), "entries": .array([entry("e4", "LORE-CHAT", constant: true)]),
        ]))
        reply(#"{"events":[],"facts":[],"ended":[],"open":[],"closed":[]}"#)
        _ = try await MemorySummary.extract(chatId: "chat_a")
        XCTAssertEqual(MockNet.count, 1)
        let body = String(data: MockNet.requests[0].httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("Reference for this summary"))
        XCTAssertTrue(body.contains("LORE-HIT"))
        XCTAssertTrue(body.contains("LORE-CONST"))
        XCTAssertFalse(body.contains("LORE-MISS"))
        XCTAssertFalse(body.contains("LORE-CHAT"))
    }

    /// 总结的重试次数取 1 与用户的「自动重试」中较小的那个（网页版 runJSONTask 默认 retries 1）：默认 0 次，设成 3 也只重试 1 次
    func testExtractRetriesCappedAtOne() async throws {
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        do { _ = try await MemorySummary.extract(chatId: "chat_a"); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        try setSettings(["retryMax": .number(3)])
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        do { _ = try await MemorySummary.extract(chatId: "chat_a"); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 2)
    }

    /// 现状：手写一块就锁住，模型总结时锁住的那块不改；解锁之后照改
    func testStateManualLock() throws {
        let key = try MemorySummary.stateKey("me_root")
        try MemorySummary.setState(charId: "char_a", key: key, block: "user", text: "手写的")
        var c = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(MemorySummary.stateOf(char: c, key: key).blocks["user"], "手写的")
        XCTAssertTrue(MemorySummary.stateOf(char: c, key: key).locks.contains("user"))
        XCTAssertEqual(try MemorySummary.applyState(charId: "char_a", key: key, ["user": .string("模型的"), "recent": .string("最近")]), 1)
        c = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(MemorySummary.stateOf(char: c, key: key).blocks["user"], "手写的")
        try MemorySummary.lockState(charId: "char_a", key: key, block: "user", on: false)
        XCTAssertEqual(try MemorySummary.applyState(charId: "char_a", key: key, ["user": .string("模型的")]), 1)
        c = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(MemorySummary.stateOf(char: c, key: key).blocks["user"], "模型的")
    }

    /// 历史版本：一样不存；恢复把记忆与现状整份放回，恢复之前先存一份
    func testMemHistory() throws {
        XCTAssertNotNil(try MemHistory.take("char_a", why: "总结记忆"))
        XCTAssertNil(try MemHistory.take("char_a", why: "总结记忆"))
        let snap = try XCTUnwrap(MemHistory.list("char_a").first)
        let before = try Repo.memories(charId: "char_a").count
        try Knowledge.deleteMemory("mem_2")
        let key = try MemorySummary.stateKey("me_root")
        try MemorySummary.setState(charId: "char_a", key: key, block: "recent", text: "改过")
        let d = try XCTUnwrap(MemHistory.diff(snap.id))
        XCTAssertEqual(d.removed.count, 1)
        XCTAssertEqual(d.blocks.count, 1)
        XCTAssertFalse(d.same)
        XCTAssertEqual(try MemHistory.restore(snap.id), before)
        XCTAssertEqual(try Repo.memories(charId: "char_a").count, before)
        let c = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(MemorySummary.stateOf(char: c, key: key).blocks["recent"], "")
        XCTAssertEqual(MemHistory.list("char_a").first?.string("why"), "恢复之前")
        XCTAssertTrue(try XCTUnwrap(MemHistory.diff(snap.id)).same)
    }

    /// 体检：像的成对列出来；保留一条之后另一条让位（不删），可以撤回
    func testMemCheck() throws {
        XCTAssertGreaterThan(MemCheck.sim(MemCheck.grams("用户喜欢猫"), MemCheck.grams("用户很喜欢猫")), 0.8)
        XCTAssertLessThan(MemCheck.sim(MemCheck.grams("用户喜欢猫"), MemCheck.grams("明天下雨")), 0.2)
        var m = Knowledge.newMemory(charId: "char_a", personaId: "me_root")
        m = try Knowledge.save(m, ["content": .string("用户很喜欢猫")])
        let pairs = MemCheck.pairs(charId: "char_a", personaId: "me_root")
        let p = try XCTUnwrap(pairs.first { [$0.a.id, $0.b.id].contains(m.id) })
        let other = p.a.id == m.id ? p.b : p.a
        try MemCheck.supersede(other.id, by: m.id)
        XCTAssertTrue(MemCheck.pairs(charId: "char_a", personaId: "me_root").isEmpty)
        XCTAssertEqual(MemCheck.superseded(charId: "char_a", personaId: "me_root").map(\.id), [other.id])
        try MemCheck.restore(other.id)
        XCTAssertTrue(MemCheck.superseded(charId: "char_a", personaId: "me_root").isEmpty)
    }
    /// 按轮数总结：积压比 N 轮多时只吃最早的 N 轮、只标这一段，不把更早的整批划掉（网页版 4.606）；
    /// 「从这条起重新总结」把水位线退回去，不调接口
    func testRoundsTakeEarliestAndRewind() async throws {
        try setSettings(["autoSummarizeInterval": .number(1)])
        for i in 0..<3 {
            _ = try Repo.append(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "问\(i)"))
            _ = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "答\(i)", turnId: "r\(i)"))
        }
        let before = try MemorySummary.pending(chatId: "chat_a").count
        reply(#"{"events":[],"facts":[],"ended":[],"open":[],"closed":[],"state":{}}"#)
        _ = try await MemorySummary.extract(chatId: "chat_a")
        XCTAssertEqual(MockNet.count, 1)
        let left = try MemorySummary.pending(chatId: "chat_a").count
        XCTAssertGreaterThan(left, 0)
        XCTAssertLessThan(left, before)
        let first = try XCTUnwrap(Repo.messages(chatId: "chat_a").first)
        XCTAssertTrue(MemorySummary.summarized(chatId: "chat_a", msgId: first.id))
        try MemorySummary.rewind(chatId: "chat_a", to: first.id)
        XCTAssertEqual(try MemorySummary.pending(chatId: "chat_a").count, before)
        XCTAssertEqual(MockNet.count, 1)
    }

    /// 开启「每 N 轮」时的积压（网页版 4.606）：算出条数与要调几次；跳过时只标最近 N 轮之前的，不调接口
    func testBacklogAndSkip() throws {
        for i in 0..<5 {
            _ = try Repo.append(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "问\(i)"))
            _ = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "答\(i)", turnId: "b\(i)"))
        }
        let p = try MemorySummary.pending(chatId: "chat_a")
        let keep = MemorySummary.lastRounds(p, 2).count
        let b = try XCTUnwrap(MemorySummary.backlog(every: 2).first(where: { $0.chatId == "chat_a" }))
        XCTAssertEqual(b.msgs, p.count - keep)
        XCTAssertEqual(b.runs, Int((Double(MemorySummary.roundsIn(p) - 2) / 2).rounded(.up)))
        XCTAssertEqual(try MemorySummary.skipBacklog(chatId: "chat_a", keep: 2), p.count - keep)
        XCTAssertEqual(try MemorySummary.pending(chatId: "chat_a").count, keep)
        XCTAssertEqual(MockNet.count, 0)
        XCTAssertTrue(MemorySummary.backlog(every: 2).isEmpty)
    }

    /// 追平要几次：设了「每 N 轮」按轮数算（网页版 runsFor），没设按条数
    func testRunsForCountsRounds() throws {
        for i in 0..<5 {
            _ = try Repo.append(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "问\(i)"))
            _ = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "答\(i)", turnId: "r\(i)"))
        }
        let p = try MemorySummary.pending(chatId: "chat_a")
        let rounds = MemorySummary.roundsIn(p)
        XCTAssertEqual(MemorySummary.runsFor(p, every: 2, batch: 200), Int((Double(rounds) / 2).rounded(.up)))
        XCTAssertEqual(MemorySummary.runsFor(p, every: 0, batch: 4), Int((Double(p.count) / 4).rounded(.up)))
        XCTAssertEqual(MemorySummary.runsFor(p, every: 0, batch: 0), 1)
        XCTAssertEqual(MemorySummary.runsFor(Array(p.prefix(1)), every: 2, batch: 200), 0)
    }

    /// 自定义标识里「模型判断」的那几个随这一次顺带判断：只多几行清单，不多调接口；模型编出来的 id 不算数
    func testJudgedBadgesRideAlong() async throws {
        let def = try BadgeDefs.save(id: nil, ["name": .string("一起看过日出"), "how": .string("judge"), "cond": .string("两人一起看了日出"),
                                               "charIds": .array([.string("char_a")])], personaId: "me_root")
        _ = try ChatEngine.send(text: "今天一起看了日出", chatId: "chat_a")
        _ = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "很美", turnId: "tb"))
        reply(#"{"events":[],"facts":[],"ended":[],"open":[],"closed":[],"state":{},"badgesEarned":[{"id":"\#(def.id)"},{"id":"bd_fake"}]}"#)
        _ = try await MemorySummary.extract(chatId: "chat_a")
        XCTAssertEqual(MockNet.count, 1)
        let body = String(data: MockNet.requests[0].httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("(id:\(def.id)) badge"))
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertNotNil(chat.row["unlocked"]?[def.unlockId])
        XCTAssertNil(chat.row["unlocked"]?["custom-bd_fake"])
    }
}
