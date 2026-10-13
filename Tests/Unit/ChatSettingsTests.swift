import XCTest
@testable import Eira

/// 会话设置：预设叠加、旁白、摘要进提示词；首次打开引导出不出现。
final class ChatSettingsTests: StoreTestCase {
    private func build() throws -> ChatPrompt.Built {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        return try ChatPrompt.build(chat: chat, char: XCTUnwrap(Repo.character("char_a")), settings: AppSettings.load().forChat(chat))
    }

    private func setChat(_ fields: [String: JSONValue]) throws {
        var row = try XCTUnwrap(Database.shared.get(Collections.chats, id: "chat_a"))
        for (k, v) in fields { row[k] = v }
        try Database.shared.put(Collections.chats, row)
    }

    /// 会话选了别的预设：那一套里的条数叠上去；选当前全局那一套或空串时照全局。
    func testPresetOverlay() throws {
        try importFixture("data.json")   // 全局 msgMin 2、msgMax 4
        try setSettings([
            "presetActive": .string("ps_global"),
            "presets": .array([
                .object(["id": .string("ps_global"), "name": .string("全局")]),
                .object(["id": .string("ps_other"), "name": .string("另一套"),
                         "data": .object(["msgMin": .number(5), "msgMax": .number(7)])]),
            ]),
        ])
        XCTAssertTrue(try build().system.contains("2 to 4"))
        try setChat(["presetId": .string("ps_other")])
        XCTAssertTrue(try build().system.contains("5 to 7"))
        try setChat(["presetId": .string("ps_global")])
        XCTAssertTrue(try build().system.contains("2 to 4"))
        XCTAssertEqual(AppSettings.load().presets.map(\.name), ["全局", "另一套"])
    }

    /// 预设里缺的键用出厂值，不沿用全局的。
    func testPresetMissingKeysUseDefaults() throws {
        try importFixture("data.json")
        try setSettings(["presets": .array([.object(["id": .string("ps_x"), "data": .object([:])])])])
        try setChat(["presetId": .string("ps_x")])
        XCTAssertTrue(try build().system.contains("3 to 9"))
    }

    func testNarrationCapability() throws {
        try importFixture("data.json")
        let template = try XCTUnwrap(Templates.defaults["skeleton.narration"])
        let marker = String(template.prefix(30))
        XCTAssertFalse(try build().system.contains(marker))
        try setChat(["narration": .bool(true)])
        XCTAssertTrue(try build().system.contains(marker))
        XCTAssertEqual(ChatPrompt.narrationLeast(1), " Every reply contains at least one\nnarration line.")
        XCTAssertEqual(ChatPrompt.narrationLeast(0), "")
    }

    func testSummaryInjected() throws {
        try importFixture("data.json")
        try setChat(["summary": .string("SUMMARY_TEXT")])
        XCTAssertTrue(try build().system.contains("[更早之前发生过什么]\nSUMMARY_TEXT"))
    }

    func testOnboardingOnlyOnEmptyStore() throws {
        XCTAssertTrue(OnboardingView.needed())
        try Database.shared.setKV(OnboardingView.doneKey, .bool(true))
        XCTAssertFalse(OnboardingView.needed())
    }

    func testOnboardingSkippedWhenDataExists() throws {
        try importFixture("data.json")
        XCTAssertFalse(OnboardingView.needed())
    }
}
