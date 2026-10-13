import XCTest
@testable import Eira

/// 问题反馈导出的那一份：该有的都有，聊天内容、人设、密钥、接口地址一个字都不许有。
final class DiagnosticsTests: StoreTestCase {
    private let secretKey = "sk-test-SECRETSECRET123456"

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "name": .string("主"), "provider": .string("openai"),
                                         "baseUrl": .string("https://secret-host.test/v1"), "apiKey": .string(secretKey),
                                         "model": .string("model-x")])]),
            "activeId": .string("svc_main"),
        ])])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    func testReportHasNoContentKeysOrAddresses() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.openaiStream("REPLY_CONTENT_A\nREPLY_CONTENT_B")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        // 接口把密钥原样写进错误说明的情况
        let key = secretKey
        MockNet.reset { _, _ in .init(status: 401, body: #"{"error":{"message":"Incorrect API key provided: \#(key)"}}"#) }
        do { try await ChatEngine.reply(chatId: "chat_a") { _ in } } catch {}
        _ = try ChatEngine.send(text: "USER_TYPED_TEXT", chatId: "chat_a")

        let report = Diagnostics.shared.report()
        for forbidden in ["SECRETSECRET", "secret-host", "PERSONA_TEXT", "SCENARIO_TEXT", "USER_DESC", "PINNED_MEMORY",
                          "REPLY_CONTENT", "USER_TYPED_TEXT", "LORE_"] {
            XCTAssertFalse(report.contains(forbidden), "诊断信息里出现了「\(forbidden)」")
        }
        // 该有的：请求成功与失败各一条，带任务名、模型名、状态码
        XCTAssertTrue(report.contains("request "))
        XCTAssertTrue(report.contains("request-failed "))
        XCTAssertTrue(report.contains("task=chat.reply"))
        XCTAssertTrue(report.contains("model=model-x"))
        XCTAssertTrue(report.contains("status=401"))
        XCTAssertTrue(report.contains("[已隐去]"))
        XCTAssertTrue(report.contains("messages："))
    }

    func testRedact() {
        XCTAssertFalse(Diagnostics.redact("Bearer abc.def.ghi").contains("abc.def"))
        XCTAssertFalse(Diagnostics.redact("api_key=hunter2hunter2").contains("hunter2"))
        XCTAssertFalse(Diagnostics.redact("key sk-ant-api03-xxxxxxxx").contains("api03"))
        XCTAssertFalse(Diagnostics.redact("token: \(String(repeating: "a", count: 40))").contains("aaaa"))
        XCTAssertEqual(Diagnostics.redact("接口 500：服务暂时不可用"), "接口 500：服务暂时不可用")
        XCTAssertEqual(Diagnostics.redact(String(repeating: "长", count: 1000)).count, 300)
    }

    /// 模型名之类代码自己填的字段不过滤：长模型名不能被当成密钥抹掉。
    func testCodeFieldsAreNotRedacted() {
        Diagnostics.shared.record("request", ["model": "claude-sonnet-long-model-name-20260101"])
        XCTAssertEqual(Diagnostics.shared.entries().last?["model"] as? String, "claude-sonnet-long-model-name-20260101")
    }

    func testKeepsOnlyTheLatest() {
        for i in 0..<(Diagnostics.limit + 20) { Diagnostics.shared.record("n", ["i": i]) }
        let all = Diagnostics.shared.entries()
        XCTAssertEqual(all.count, Diagnostics.limit)
        XCTAssertEqual(all.first?["i"] as? Int, 20)
        XCTAssertEqual(all.last?["i"] as? Int, Diagnostics.limit + 19)
    }
}
