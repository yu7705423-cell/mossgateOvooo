import XCTest
@testable import Eira

/// 编辑资料上「从人设中生成 / 提取」（网页版 4.590）：每点一次只打一次接口，失败不重试、照实报错，记账用网页版的任务名。
final class CardFieldsTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc"), "provider": .string("openai"),
                                         "baseUrl": .string("https://spare.test/v1"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc")])])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func reply(_ text: String) -> MockNet.Reply { .init(status: 200, body: MockNet.openaiStream(text)) }

    func testTaskNamesAndFields() {
        XCTAssertEqual(CardFields.Kind.core.task, "card.core")
        XCTAssertEqual(CardFields.Kind.examples.task, "card.examples")
        XCTAssertEqual(CardFields.Kind.appearance.task, "card.appearance")
        XCTAssertEqual(CardFields.Kind.examples.field, "exampleDialogue")
        XCTAssertEqual(CardFields.Kind.core.field, "core")
        XCTAssertEqual(CardFields.Kind.appearance.field, "appearance")
        // 模板从网页版搬来，三份都在
        for k in CardFields.Kind.allCases {
            XCTAssertFalse(Templates.render(k.template, ["persona": "P"], settings: AppSettings.load()).isEmpty, k.template)
        }
    }

    /// 每一种各打一次，人设整段进了请求，记账记在各自的任务名下
    func testEachIsOneRequestWithPersona() async throws {
        for k in CardFields.Kind.allCases {
            MockNet.reset { [self] _, _ in reply("  结果 \(k.rawValue)  ") }
            let before = await Usage.shared.today(task: k.task)
            let out = try await CardFields.make(k, persona: "很长的人设 TAIL_\(k.rawValue)")
            XCTAssertEqual(out, "结果 \(k.rawValue)")
            XCTAssertEqual(MockNet.count, 1, k.rawValue)
            let body = String(data: MockNet.requests[0].httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("TAIL_\(k.rawValue)"), k.rawValue)
            let after = await Usage.shared.today(task: k.task)
            XCTAssertEqual(after - before, 1, k.task)
        }
    }

    /// 接口一直失败：开了自动重试与换接口也只打一次（手动的一次调用），并且抛出原因给界面
    func testFailingAPIIsOneRequestAndThrows() async throws {
        try setSettings(["retryMax": .number(3), "chatFallback": .bool(true)])
        for k in CardFields.Kind.allCases {
            MockNet.reset { _, _ in .init(status: 500, body: "{}") }
            do { _ = try await CardFields.make(k, persona: "人设"); XCTFail("应当失败") } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
            XCTAssertEqual(MockNet.count, 1, k.rawValue)
        }
    }

    /// 人设空着不发请求；接口回了空串报错，不拿空串去盖那一栏
    func testEmptyPersonaAndEmptyReply() async throws {
        MockNet.reset { [self] _, _ in reply("x") }
        do { _ = try await CardFields.make(.core, persona: "  \n"); XCTFail("应当失败") } catch {
            XCTAssertTrue(error.localizedDescription.contains("人设是空的"))
        }
        XCTAssertEqual(MockNet.count, 0)

        MockNet.reset { [self] _, _ in reply("   ") }
        do { _ = try await CardFields.make(.appearance, persona: "人设"); XCTFail("应当失败") } catch {
            XCTAssertTrue(error.localizedDescription.contains("外貌"))
        }
        XCTAssertEqual(MockNet.count, 1)
    }
}
