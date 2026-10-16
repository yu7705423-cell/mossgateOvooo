import XCTest
@testable import Eira

/// 对话中间的 system 消息怎么发（网页版 providers/midsystem.js、ARCHITECTURE 4.194），以及接口编辑页那几项进不进请求。
final class MidSystemTests: XCTestCase {
    private let history = [
        AIMessage(role: .user, content: "一"),
        AIMessage(role: .assistant, content: "二"),
        AIMessage(role: .system, content: "[现在几点]\n晚上"),
        AIMessage(role: .system, content: "[相关记忆]\n喜欢猫"),
        AIMessage(role: .user, content: "三"),
    ]

    private func preset(_ provider: String, _ extra: [String: JSONValue] = [:]) -> ChatPreset {
        var json: [String: JSONValue] = ["id": .string("p"), "provider": .string(provider),
                                         "apiKey": .string("k"), "model": .string("m")]
        json.merge(extra) { _, new in new }
        return ChatPreset(json: json)
    }

    private func body(_ p: ChatPreset, system: String = "S") throws -> [String: Any] {
        let req = Provider.Request(system: system, messages: history, maxTokens: 0, stream: false, cache: false)
        let data = try XCTUnwrap(Provider.urlRequest(p, req, idleSeconds: 0).httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func roles(_ b: [String: Any]) -> [String] {
        ((b["messages"] as? [[String: Any]]) ?? []).compactMap { $0["role"] as? String }
    }

    /// OpenAI 兼容默认（midSystem 没写）：转成 user、<context> 包住、和相邻的 user 并成一条
    func testOpenAIDefaultTurnsMidSystemIntoUser() throws {
        let b = try body(preset("openai"))
        XCTAssertEqual(roles(b), ["system", "user", "assistant", "user"])
        let last = try XCTUnwrap((b["messages"] as? [[String: Any]])?.last?["content"] as? String)
        XCTAssertEqual(last, "<context>\n[现在几点]\n晚上\n</context>\n\n<context>\n[相关记忆]\n喜欢猫\n</context>\n\n三")
    }

    /// 写了别的值也按 user（网页版 engine.asConfig：只有 'system' 才是原样）
    func testOpenAIUnknownValueStillUser() throws {
        XCTAssertEqual(roles(try body(preset("openai", ["midSystem": .string("whatever")]))),
                       ["system", "user", "assistant", "user"])
    }

    /// 选了「原样 system」：中间那几条原样发，不合并，最前面那条系统提示照旧
    func testOpenAISystemKeepsMidSystem() throws {
        let b = try body(preset("openai", ["midSystem": .string("system")]))
        XCTAssertEqual(roles(b), ["system", "user", "assistant", "system", "system", "user"])
        let msgs = try XCTUnwrap(b["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs[3]["content"] as? String, "[现在几点]\n晚上")
    }

    /// Anthropic 不收中途 system：不管 midSystem 写了什么，一律转成 user；系统提示放在 system 字段
    func testAnthropicAlwaysUserEvenIfSystemChosen() throws {
        for extra: [String: JSONValue] in [[:], ["midSystem": .string("system")]] {
            let b = try body(preset("anthropic", extra))
            XCTAssertEqual(roles(b), ["user", "assistant", "user"])
            XCTAssertEqual(b["system"] as? String, "S")
        }
    }

    /// 转成 user 时带着的图留下（网页版 { ...m, role: 'user' }），带图的不与相邻同角色合并
    func testConvertedSystemKeepsImages() {
        let pic = AIImage(mediaType: "image/png", base64: "x")
        let shaped = Provider.shape(preset("openai"), [
            AIMessage(role: .user, content: "一"),
            AIMessage(role: .system, content: "图", images: [pic]),
        ])
        XCTAssertEqual(shaped.count, 2)
        XCTAssertEqual(shaped[1].role, .user)
        XCTAssertEqual(shaped[1].images, [pic])
    }

    /// 思考深度只进 Anthropic 的请求；temperature 只进 OpenAI 兼容的请求；temperature 为 null 时不送
    func testEffortAndTemperaturePerProvider() throws {
        let a = try body(preset("anthropic", ["effort": .string("high"), "temperature": .number(0.5)]))
        XCTAssertEqual((a["output_config"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertNil(a["temperature"])

        let aEmpty = try body(preset("anthropic", ["effort": .string("")]))
        XCTAssertNil(aEmpty["output_config"])

        let o = try body(preset("openai", ["effort": .string("high"), "temperature": .number(0.5)]))
        XCTAssertEqual(o["temperature"] as? Double, 0.5)
        XCTAssertNil(o["output_config"])

        // 没写 temperature 的按 0.9（网页版 newChatPreset），写了 null 的不送
        XCTAssertEqual(try body(preset("openai"))["temperature"] as? Double, 0.9)
        XCTAssertNil(try body(preset("openai", ["temperature": .null]))["temperature"])
    }

    /// 标签上的 temperature 写法与网页版一致：不补零
    func testTemperatureLabel() {
        XCTAssertEqual(PresetEditor.number(0.9), "0.9")
        XCTAssertEqual(PresetEditor.number(1), "1")
        XCTAssertEqual(PresetEditor.number(0.8500000001), "0.85")
        XCTAssertEqual(PresetEditor.number(0), "0")
    }

    /// 流式开关：settings.streamMode 只有 'once' 是关
    func testStreamModeReading() {
        XCTAssertTrue(AppSettings(raw: [:]).streams)
        XCTAssertTrue(AppSettings(raw: ["streamMode": .string("stream")]).streams)
        XCTAssertFalse(AppSettings(raw: ["streamMode": .string("once")]).streams)
    }
}
