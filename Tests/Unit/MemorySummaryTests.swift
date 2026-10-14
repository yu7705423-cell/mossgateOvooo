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
        XCTAssertTrue(ExtraCalls.active(.load()).isEmpty)
    }

    /// 接口一直失败：门槛到了只打一次；没攒够下一个间隔之前不再打；攒够了再打一次。
    func testAutoFailingOncePerInterval() async throws {
        try setSettings(["autoSummarizeInterval": .number(1)])
        XCTAssertEqual(ExtraCalls.active(.load()).map(\.id), ["autoSummarize"])
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
}
