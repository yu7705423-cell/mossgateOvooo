import XCTest
import UIKit
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

extension CostTests {
    /// 发图再请回复：仍然只打一次；识图交给聊天模型时图随这一次带上，不另调接口。
    func testImageWithVisionIsStillOneRequest() async throws {
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")]),
            "vision": .object(["mode": .string("chat")])])])
        let png = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).pngData { _ in }
        _ = try ChatEngine.sendImage(imageId: try Images.save(png), chatId: "chat_a")
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("看到了")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        let body = String(data: MockNet.requests.first?.httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"type\":\"image\""))
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").first { $0.kind == "image" && $0.role == .user }?.row.string("vision"), "done")
    }
}

extension CostTests {
    /// 翻译这一条：点一次打一次；接口一直失败时也只打一次，译文不动。转发不调接口。
    func testTranslateOneIsOneRequest() async throws {
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        chat.row["translateTo"] = .string("中文")
        try Repo.save(chat)
        let m = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "Good night"))
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        do { _ = try await TranslateOne.run(m, chat: chat); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertNil(try Repo.messages(chatId: "chat_a").first { $0.id == m.id }?.row["translation"])

        // 不是聊天回复，走副用（OpenAI 格式那一套）
        let j = #"{"lines":["晚安"]}"#
        MockNet.reset { r, _ in .init(status: 200, body: r.url?.host == "spare.test" ? MockNet.openaiStream(j) : MockNet.anthropicStream(j)) }
        let out = try await TranslateOne.run(m, chat: chat)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(hosts(), ["spare.test"])
        XCTAssertEqual(out.row.string("translation"), "晚安")

        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        try Forward.send(from: "chat_a", to: "chat_a", list: [m])
        XCTAssertEqual(MockNet.count, 0)
    }
}

extension CostTests {
    /// 回复途中断开：收到的那部分落成气泡，最后一条标上中断；不重试、不另落失败行。
    func testPartialReplyIsKept() async throws {
        try setSettings(["retryMax": .number(3)])
        let piece = String(data: try JSONSerialization.data(withJSONObject: ["type": "content_block_delta",
            "delta": ["type": "text_delta", "text": "先说这一句\n还有这一句"]]), encoding: .utf8)!
        MockNet.reset { _, _ in
            .init(status: 200, body: "data: \(piece)\n\ndata: {\"type\":\"error\",\"error\":{\"message\":\"overloaded\"}}\n\n")
        }
        let before = try Repo.messages(chatId: "chat_a").count
        do { try await ChatEngine.reply(chatId: "chat_a") { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        let after = try Repo.messages(chatId: "chat_a")
        XCTAssertEqual(after.count, before + 2)
        XCTAssertEqual(after.suffix(2).map(\.content), ["先说这一句", "还有这一句"])
        XCTAssertTrue(after.last?.row.bool("cutOff") == true)
        XCTAssertFalse(after.contains { $0.isError && $0.createdAt > 0 && $0.content.isEmpty && $0.row.string("error").contains("overloaded") })
    }
}

extension CostTests {
    /// 余额不足：失败那一条记下是哪一套、是不是余额不足；填了链接的给「去充值」，没填充值链接时用站点
    func testBalanceFailureGivesTopupLink() async throws {
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "name": .string("主"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m"),
                                         "siteUrl": .string("main.example.com")])]),
            "activeId": .string("svc_main")])])])
        MockNet.reset { _, _ in .init(status: 402, body: #"{"error":{"message":"insufficient balance"}}"#) }
        do { try await ChatEngine.reply(chatId: "chat_a") { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        let last = try XCTUnwrap(Repo.messages(chatId: "chat_a").last)
        XCTAssertTrue(last.isError)
        let links = FailLinks.of(last, settings: AppSettings.load())
        XCTAssertTrue(links.broke)
        XCTAssertEqual(links.rows.map(\.label), ["去充值"])
        XCTAssertEqual(links.rows.first?.url.absoluteString, "https://main.example.com")
        XCTAssertNil(ChatPreset.link("javascript:alert(1)"))
    }
}
