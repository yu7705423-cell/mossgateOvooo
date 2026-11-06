import XCTest
@testable import Eira

/// 试点（docs/jscore-prompt.md）：一对一聊天的提示词由网页版自己的代码在 JavaScriptCore 里拼，和原生 ChatPrompt 对照。
///
/// 数据：Tests/Fixtures 里的 data.json（scripts/make-fixtures.mjs 用网页版的代码打的）与 webprompt-rich.json
/// （网页版备份的格式，手写的数据：几十条消息、引用、转账、表情、译文、撤回、群聊、几类记忆、世界书）。
///
/// 两边不一致的地方逐段列出来，日志里是 `[weblogic]` 开头的几行。试点阶段记成「预期内的失败」（XCTExpectFailure），
/// 不挡出包；WEBLOGIC_STRICT=1 时是真失败。脚本加载不了、拼装出错、区块构建失败、调到存根一律是真失败。
final class WebPromptTests: StoreTestCase {
    /// 网页版仓库是私密的，打包结果不进本仓库，由编译流程用 WEB_REPO_TOKEN 现取现打。没取到时整组跳过
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(WebPrompt.available, "没有网页版的拼装脚本（编译时没有取到网页版代码），跳过")
    }

    private var strict: Bool { ProcessInfo.processInfo.environment["WEBLOGIC_STRICT"] == "1" }

    /// 备份里的时间：data.json 的 t0，rich 的最后一条消息之后五分钟
    private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func both(_ fixture: String, chat chatId: String, now: Date, excludeTurn: String? = nil,
                      import: Bool = true) throws -> (ChatPrompt.Built, WebPrompt.Output) {
        if `import` { try importFixture(fixture) }
        let chat = try XCTUnwrap(Repo.chat(chatId))
        let char = try XCTUnwrap(Repo.character(chat.characterIds.first ?? ""))
        let native = try ChatPrompt.build(chat: chat, char: char, settings: .load(), now: now, excludeTurn: excludeTurn)
        let web = try XCTUnwrap(WebPrompt.shared.build(chat: chat, char: char, excludeTurn: excludeTurn, now: now),
                                "网页版拼装失败：\(WebPrompt.shared.lastError ?? "未知")")
        return (native, web)
    }

    private func healthy(_ web: WebPrompt.Output, _ label: String) {
        XCTAssertEqual(web.failed, [], "\(label)：网页版有区块构建失败")
        XCTAssertEqual(web.stubHits, [], "\(label)：拼装路径上调到了存根")
        XCTAssertTrue(web.writes.allSatisfy { $0.hasPrefix("put chats ") }, "\(label)：拼装途中想写别的数据域：\(web.writes)")
        XCTAssertEqual(web.commit.count, 40, "包头里记着网页版的提交号")
        for line in web.logs { print("[weblogic] \(label) 网页版日志：\(line)") }
    }

    func testFlagDefaultsOff() throws {
        XCTAssertFalse(WebPrompt.isOn)
        try WebPrompt.setOn(true)
        XCTAssertTrue(WebPrompt.isOn)
        try WebPrompt.setOn(false)
        XCTAssertFalse(WebPrompt.isOn)
    }

    func testBuildsFromWebBackup() throws {
        let (_, web) = try both("data.json", chat: "chat_a", now: Self.t0.addingTimeInterval(100))
        healthy(web, "data.json")
        XCTAssertTrue(web.system.contains("[你是谁]\nPERSONA_TEXT"))
        XCTAssertTrue(web.system.contains("[对方是谁]\nName: 小于\nUSER_DESC"))
        XCTAssertTrue(web.system.contains("[一直记着]\n- PINNED_MEMORY"))
        XCTAssertTrue(web.system.contains("LORE_CAT"))
        XCTAssertTrue(web.system.contains("LORE_ALWAYS"))
        XCTAssertFalse(web.system.contains("LORE_OFF"))
        XCTAssertFalse(web.system.contains("LORE_MISS"))
        XCTAssertTrue(web.system.contains("2 to 4"))
        XCTAssertTrue(web.messages.contains { $0.role == .assistant && $0.content.contains("在呢") && $0.content.contains("[图片：一只猫]") })
        XCTAssertEqual(web.messages.last?.role, .user)
        XCTAssertFalse(web.messages.contains { $0.content.contains("PERSONA_TEXT") })
        print("[weblogic] 提示词：data.json 灌表 \(web.timing.rows) 行 \(web.timing.bytes) 字节；读过的数据域 \(web.touched.joined(separator: "、"))；想写的 \(web.writes)")
    }

    /// 两份备份各拼一次，两边逐段对照
    func testSameAsNative() throws {
        let cases: [(String, String, Date)] = [
            ("data.json", "chat_a", Self.t0.addingTimeInterval(100)),
            ("webprompt-rich.json", "chat_r", Self.t0.addingTimeInterval(45 * 60)),
        ]
        var total = 0
        for (fixture, chatId, now) in cases {
            try Database.shared.wipe()
            let (native, web) = try both(fixture, chat: chatId, now: now)
            healthy(web, fixture)
            let diffs = WebPrompt.compare(native: native, web: web)
            total += diffs.count
            print("[weblogic] 提示词对照 \(fixture)：设定区 原生 \(native.system.count) 字 / 网页 \(web.system.count) 字，"
                  + "段数 \(WebPrompt.sections(native.system).count) / \(WebPrompt.sections(web.system).count)，"
                  + "聊天记录 \(native.messages.count) / \(web.messages.count) 条，不一致 \(diffs.count) 处")
            for d in diffs {
                print("[weblogic] \(fixture) 不一致：\(d)")
                if strict {
                    XCTFail("\(fixture)：原生与网页版不一致：\(d)")
                } else {
                    XCTExpectFailure("试点阶段：原生与网页版拼出来的提示词的已知差异") {
                        XCTFail("\(fixture)：原生与网页版不一致：\(d)")
                    }
                }
            }
        }
        print("[weblogic] 提示词对照：共 \(total) 处不一致")
    }

    /// 重新生成：去掉的那一轮两边都不在
    func testExcludeTurn() throws {
        let (native, web) = try both("webprompt-rich.json", chat: "chat_r", now: Self.t0.addingTimeInterval(45 * 60), excludeTurn: "turn_r9")
        healthy(web, "excludeTurn")
        XCTAssertFalse(web.messages.contains { $0.content.contains("See you tomorrow") })
        XCTAssertFalse(native.messages.contains { $0.content.contains("See you tomorrow") })
        XCTAssertTrue(web.messages.contains { $0.content.contains("那就这么定了") })
    }

    /// 灌表之后改了一条：下一次读到的是新的（网页版的排序缓存按版本号认，条数相同、内容不同也要认得出）
    func testSeesChangesBetweenBuilds() throws {
        let now = Self.t0.addingTimeInterval(100)
        let (_, first) = try both("data.json", chat: "chat_a", now: now)
        XCTAssertTrue(first.messages.contains { $0.content.hasSuffix("你好") })
        var m = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.id == "msg_1" })
        m.row["content"] = .string("改过的一句")
        try Repo.save(m)
        let (_, second) = try both("data.json", chat: "chat_a", now: now, import: false)
        XCTAssertTrue(second.messages.contains { $0.content.hasSuffix("改过的一句") })
        XCTAssertFalse(second.messages.contains { $0.content.hasSuffix("你好") })
    }

    /// 耗时：rich 那段会话再加 2000 条消息、300 条记忆，两边各拼 20 次。预算是每次 50 毫秒（模拟器）；
    /// 真机上 JSContext 没有 JIT，要从 TestFlight 包里量（docs/jscore-prompt.md）
    func testSpeed() throws {
        executionTimeAllowance = 120
        try importFixture("webprompt-rich.json")
        let base = Self.t0.millis
        for i in 0..<2000 {
            let at = base - Double(2000 - i) * 60_000
            try Database.shared.put(Collections.messages, Row(fields: [
                "id": .string("msg_bulk\(i)"), "chatId": .string("chat_r"), "role": .string(i % 3 == 0 ? "user" : "char"),
                "authorId": .string(i % 3 == 0 ? "me" : "char_r"), "kind": .string("text"), "status": .string("done"),
                "content": .string("第\(i)条：今天下班路上看到一只橘猫，蹲在便利店门口不肯走"),
                "turnId": .string("turn_bulk\(i / 3)"), "createdAt": .number(at), "updatedAt": .number(at),
            ]))
        }
        for i in 0..<300 {
            let at = base - Double(i) * 3_600_000
            try Database.shared.put(Collections.memories, Row(fields: [
                "id": .string("mem_bulk\(i)"), "charId": .string("char_r"), "personaId": .string("me_root"),
                "content": .string("第\(i)条记忆：用户提到过一家店"), "keywords": .array([.string("店\(i)")]),
                "rank": .string(["S", "A", "B", "C"][i % 4]), "category": .string("fact"),
                "createdAt": .number(at), "updatedAt": .number(at),
            ]))
        }
        let chat = try XCTUnwrap(Repo.chat("chat_r"))
        let char = try XCTUnwrap(Repo.character("char_r"))
        let now = Self.t0.addingTimeInterval(45 * 60)
        let s = AppSettings.load()

        let n = 20
        var start = Date()
        for _ in 0..<n { _ = try ChatPrompt.build(chat: chat, char: char, settings: s, now: now) }
        let nativePer = Date().timeIntervalSince(start) / Double(n)

        start = Date()
        let cold = try XCTUnwrap(WebPrompt.shared.build(chat: chat, char: char, now: now), WebPrompt.shared.lastError ?? "")
        let coldSeconds = Date().timeIntervalSince(start)
        healthy(cold, "speed")
        var sum = WebPrompt.Timing()
        start = Date()
        for _ in 0..<n {
            let t = try XCTUnwrap(WebPrompt.shared.build(chat: chat, char: char, now: now), WebPrompt.shared.lastError ?? "").timing
            sum.read += t.read; sum.feed += t.feed; sum.refill += t.refill; sum.build += t.build
        }
        let webPer = Date().timeIntervalSince(start) / Double(n)
        func ms(_ v: Double) -> String { String(format: "%.1f", v * 1000) }
        let k = Double(n)
        print("[weblogic] 提示词耗时：原生 \(ms(nativePer)) ms/次；网页版 \(ms(webPer)) ms/次"
              + "（读库 \(ms(sum.read / k))、灌表 \(ms(sum.feed / k))、换表 \(ms(sum.refill / k))、拼装 \(ms(sum.build / k))）；"
              + "第一次 \(ms(coldSeconds)) ms（含建 JSContext 与执行脚本 \(ms(WebPrompt.shared.loadSeconds)) ms）；"
              + "灌表 \(cold.timing.rows) 行 \(cold.timing.bytes / 1024) KB；预算 50 ms：\(webPer <= 0.05 ? "未超出" : "超出")")
        XCTAssertLessThan(webPer, 2, "一次拼装超过 2 秒")
    }
}

/// 开关开着时回复走网页版拼的那一份：发一条消息仍然只打一次接口（网页版第 15 条，CostTests 的同一条规矩）
final class WebPromptCostTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(WebPrompt.available, "没有网页版的拼装脚本（编译时没有取到网页版代码），跳过")
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "name": .string("主"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main"),
        ])])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func used() -> Int { Diagnostics.shared.entries().filter { $0["k"] as? String == "webprompt-used" }.count }

    func testFailingNetworkStillOneRequest() async throws {
        try WebPrompt.setOn(true)
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        do { try await ChatEngine.reply(chatId: "chat_a") { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(used(), 1, "这一轮用的是网页版拼的提示词")
        let body = String(data: MockNet.requests.first?.httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("PERSONA_TEXT"))
    }

    func testOffByDefault() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("在的")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(used(), 0, "默认关着，用的是原生拼的")
    }
}
