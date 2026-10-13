import XCTest
@testable import Eira

/// 花钱的次数（网页版第 15 条）：网络一律接住，数真正打出去几次。
///
/// 底线：发一条消息只打一次；重试、换接口只在用户打开时发生，次数不超过用户填的；
/// 已经收到一半、用户取消、密钥错这类再试也没用的，一次都不多打。每打一次都记账。
final class CostTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([
                .object(["id": .string("svc_main"), "name": .string("主"), "provider": .string("anthropic"),
                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")]),
                .object(["id": .string("svc_spare"), "name": .string("副"), "provider": .string("openai"),
                         "baseUrl": .string("https://spare.test/v1"), "apiKey": .string("k"), "model": .string("m")]),
                .object(["id": .string("svc_third"), "name": .string("三"), "provider": .string("openai"),
                         "baseUrl": .string("https://third.test/v1"), "apiKey": .string("k"), "model": .string("m")]),
            ]),
            "activeId": .string("svc_main"),
            "fallbackId": .string("svc_spare"),
        ])])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func todayCount() async -> Int { await Usage.shared.today() }
    private func hosts() -> [String] { MockNet.requests.compactMap { $0.url?.host } }

    func testOneMessageOneRequest() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("在的\n刚下班")) }
        let before = try Repo.messages(chatId: "chat_a").count
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(hosts(), ["main.test"])
        let todayN = await todayCount()
        XCTAssertEqual(todayN, 1)
        let after = try Repo.messages(chatId: "chat_a")
        XCTAssertEqual(after.count, before + 2)
        XCTAssertEqual(after.suffix(2).map(\.content), ["在的", "刚下班"])
        // 一轮的第一条带原文与用的哪套接口
        XCTAssertEqual(after[after.count - 2].row.string("raw"), "在的\n刚下班")
    }

    /// 默认设置下失败：只打一次，不重试、不换接口；留一条失败的消息。
    func testFailureByDefaultIsOneRequest() async throws {
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        do { try await ChatEngine.reply(chatId: "chat_a") { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        let todayN = await todayCount()
        XCTAssertEqual(todayN, 1)
        let last = try XCTUnwrap(Repo.messages(chatId: "chat_a").last)
        XCTAssertTrue(last.isError)
        XCTAssertTrue(last.error.contains("boom"))
    }

    /// 重试次数取调用方给的与用户的 retryMax 里小的那个。
    func testRetryCappedByUserSetting() async throws {
        try setSettings(["retryMax": .number(2)])
        MockNet.reset { _, _ in .init(status: 503, body: "{}") }
        do { _ = try await AIService.shared.send(task: "test", system: "", messages: [.init(role: .user, content: "hi")], retries: 3) } catch {}
        XCTAssertEqual(MockNet.count, 3)
        let todayN = await todayCount()
        XCTAssertEqual(todayN, 3)
    }

    /// 用户的 retryMax 再大也钳在 3。
    func testRetryMaxClampedAtThree() async throws {
        try setSettings(["retryMax": .number(10)])
        MockNet.reset { _, _ in .init(status: 503, body: "{}") }
        do { _ = try await AIService.shared.send(task: "test", system: "", messages: [.init(role: .user, content: "hi")], retries: 10) } catch {}
        XCTAssertEqual(MockNet.count, 4)
    }

    /// 密钥错、参数错这类，再试一次也是同一个错误，不重试。
    func testNoRetryOnClientError() async throws {
        try setSettings(["retryMax": .number(3)])
        MockNet.reset { _, _ in .init(status: 401, body: "{}") }
        do { _ = try await AIService.shared.send(task: "test", system: "", messages: [.init(role: .user, content: "hi")], retries: 3) } catch {}
        XCTAssertEqual(MockNet.count, 1)
    }

    /// 换接口：开了才换，最多换 failoverMax 套，按主用、副用、其余的顺序。
    func testFailoverOnlyWhenEnabled() async throws {
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { _ = try await AIService.shared.send(task: "chat.reply", system: "", messages: [.init(role: .user, content: "hi")]) } catch {}
        XCTAssertEqual(hosts(), ["main.test"])

        try setSettings(["chatFallback": .bool(true)])
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { _ = try await AIService.shared.send(task: "chat.reply", system: "", messages: [.init(role: .user, content: "hi")]) } catch {}
        XCTAssertEqual(hosts(), ["main.test", "spare.test"])

        try setSettings(["chatFallback": .bool(true), "failoverMax": .number(0)])
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { _ = try await AIService.shared.send(task: "chat.reply", system: "", messages: [.init(role: .user, content: "hi")]) } catch {}
        XCTAssertEqual(hosts(), ["main.test", "spare.test", "third.test"])
    }

    /// 换过去成功了就停。
    func testFailoverStopsOnSuccess() async throws {
        try setSettings(["chatFallback": .bool(true), "failoverMax": .number(0)])
        MockNet.reset { req, _ in
            req.url?.host == "spare.test" ? .init(status: 200, body: MockNet.openaiStream("好")) : .init(status: 500, body: "{}")
        }
        let r = try await AIService.shared.send(task: "chat.reply", system: "", messages: [.init(role: .user, content: "hi")])
        XCTAssertEqual(r.text, "好")
        XCTAssertEqual(r.presetId, "svc_spare")
        XCTAssertEqual(hosts(), ["main.test", "spare.test"])
    }

    /// 已经收到一半再出错：不重试、不换接口。
    func testPartialReplyIsNeverRetried() async throws {
        try setSettings(["retryMax": .number(3), "chatFallback": .bool(true), "failoverMax": .number(0)])
        let piece = String(data: try JSONSerialization.data(withJSONObject: ["type": "content_block_delta",
            "delta": ["type": "text_delta", "text": "说到一半"]]), encoding: .utf8)!
        MockNet.reset { _, _ in
            .init(status: 200, body: "data: \(piece)\n\ndata: {\"type\":\"error\",\"error\":{\"message\":\"overloaded\"}}\n\n")
        }
        do {
            _ = try await AIService.shared.send(task: "chat.reply", system: "", messages: [.init(role: .user, content: "hi")], retries: 3)
            XCTFail("应当失败")
        } catch let e as AIError {
            XCTAssertEqual(e.partial, "说到一半")
        }
        XCTAssertEqual(MockNet.count, 1)
    }

    /// 后台任务默认走副用，聊天走主用。
    func testRouting() async throws {
        MockNet.reset { req, _ in .init(status: 200, body: req.url?.host == "main.test"
            ? MockNet.anthropicStream("x") : MockNet.openaiStream("x")) }
        _ = try await AIService.shared.send(task: "memory.extract", system: "", messages: [.init(role: .user, content: "hi")])
        _ = try await AIService.shared.send(task: "chat.reply", system: "", messages: [.init(role: .user, content: "hi")])
        XCTAssertEqual(hosts(), ["spare.test", "main.test"])
    }

    /// 没有可用的接口：一次都不打。
    func testNoUsablePresetSendsNothing() async throws {
        try setSettings(["services": .object([:])])
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("x")) }
        do { try await ChatEngine.reply(chatId: "chat_a") { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 0)
        let todayN = await todayCount()
        XCTAssertEqual(todayN, 0)
    }

    /// 请求的形状：Anthropic 的地址与头，OpenAI 兼容的地址。
    func testRequestShape() async throws {
        MockNet.reset { req, _ in .init(status: 200, body: req.url?.host == "main.test"
            ? MockNet.anthropicStream("x") : MockNet.openaiStream("x")) }
        _ = try await AIService.shared.send(task: "chat.reply", system: "S", messages: [.init(role: .user, content: "hi")])
        _ = try await AIService.shared.send(task: "other", system: "S", messages: [.init(role: .user, content: "hi")])
        let reqs = MockNet.requests
        XCTAssertEqual(reqs[0].url?.absoluteString, "https://main.test/v1/messages")
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(reqs[1].url?.absoluteString, "https://spare.test/v1/chat/completions")
        XCTAssertEqual(reqs[1].value(forHTTPHeaderField: "authorization"), "Bearer k")
    }
}
