import XCTest
@testable import Eira

/// 一对一聊天的请求怎么拼。用网页版打的备份做数据。
final class ChatPromptTests: StoreTestCase {
    private func build(_ overrides: [String: JSONValue] = [:]) throws -> ChatPrompt.Built {
        try importFixture("data.json")
        if !overrides.isEmpty { try setSettings(overrides) }
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        return try ChatPrompt.build(chat: chat, char: char, settings: .load())
    }

    func testSystemBlocks() throws {
        let b = try build()
        XCTAssertTrue(b.system.contains("[你是谁]\nPERSONA_TEXT"))
        XCTAssertTrue(b.system.contains("[当前情境]\nSCENARIO_TEXT"))
        XCTAssertTrue(b.system.contains("[对方是谁]\nName: 小于\nUSER_DESC"))
        XCTAssertTrue(b.system.contains("[一直记着]\n- PINNED_MEMORY"))
        XCTAssertTrue(b.system.contains("林：女"))
        XCTAssertTrue(b.system.contains("小于：男"))
    }

    func testRulesUseMessageCountFromSettings() throws {
        XCTAssertTrue(Templates.defaults["skeleton.rules"]?.contains("{{count}}") == true)
        XCTAssertTrue(try build().system.contains("2 to 4"))
    }

    func testLorebookActivation() throws {
        let b = try build()
        // 最近几条里有「猫」：按关键词命中；常驻的一直在；没命中的、关掉的不在
        XCTAssertTrue(b.system.contains("LORE_CAT"))
        XCTAssertTrue(b.system.contains("LORE_ALWAYS"))
        XCTAssertFalse(b.system.contains("LORE_MISS"))
        XCTAssertFalse(b.system.contains("LORE_OFF"))
        // before 在角色卡前面，after 在后面
        let cat = try XCTUnwrap(b.system.range(of: "LORE_CAT")).lowerBound
        let card = try XCTUnwrap(b.system.range(of: "[你是谁]")).lowerBound
        let always = try XCTUnwrap(b.system.range(of: "LORE_ALWAYS")).lowerBound
        XCTAssertLessThan(cat, card)
        XCTAssertGreaterThan(always, card)
    }

    func testPersonaTextNeverInHistory() throws {
        let b = try build()
        XCTAssertFalse(b.messages.contains { $0.content.contains("PERSONA_TEXT") })
    }

    /// 默认带最近记下的 10 条：mem_2 在「最近记下的」里，相关记忆就不再重复它。
    func testRecentMemoriesInTail() throws {
        let b = try build()
        let tail = b.messages[b.messages.count - 2]
        XCTAssertTrue(tail.content.contains("[最近记下的]"))
        XCTAssertTrue(tail.content.contains("用户喜欢猫"))
        XCTAssertTrue(b.recalled.isEmpty)
    }

    func testHistoryShape() throws {
        let b = try build(["memoryRecent": .number(0)])
        // 最后一条是角色说的，所以末尾补一句 follow-up
        XCTAssertEqual(b.messages.last?.role, .user)
        XCTAssertEqual(b.messages.last?.content, Templates.defaults["skeleton.follow-up"])
        // 角色的两条并成一条
        XCTAssertTrue(b.messages.contains { $0.role == .assistant && $0.content.contains("在呢") && $0.content.contains("[图片：一只猫]") })
        // 时间、相关记忆插在倒数第一条之前
        let tail = b.messages[b.messages.count - 2]
        XCTAssertEqual(tail.role, .system)
        XCTAssertTrue(tail.content.contains("[现在几点]"))
        XCTAssertTrue(tail.content.contains("[相关记忆]"))
        XCTAssertTrue(tail.content.contains("用户喜欢猫"))
        XCTAssertEqual(b.recalled, ["mem_2"])
        // 第一条带日期
        XCTAssertTrue(b.messages.first?.content.hasPrefix("[20") == true)
    }

    func testProviderShapingWrapsSystemInContext() throws {
        let b = try build()
        let p = ChatPreset(json: ["id": .string("x"), "provider": .string("anthropic"), "apiKey": .string("k"), "model": .string("m")])
        let shaped = Provider.shape(p, b.messages)
        XCTAssertFalse(shaped.contains { $0.role == .system })
        XCTAssertTrue(shaped.last?.content.hasPrefix("<context>\n") == true)
        for (a, b) in zip(shaped, shaped.dropFirst()) { XCTAssertNotEqual(a.role, b.role) }
    }
}
