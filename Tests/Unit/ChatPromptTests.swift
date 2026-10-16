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

    /// 「你们之间」：网页版存在 states[根账号].blocks.us；没写过时退回关系底色 bonds[根账号].text。
    func testBondReadsWebShape() throws {
        try importFixture("data.json")
        var char = try XCTUnwrap(Repo.character("char_a"))
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let personas = try Repo.personas()
        let me = try personas.first { $0.id == chat.personaId } ?? Repo.activePersona(.load())
        let root = Repo.rootId(of: me?.id ?? "", in: personas)
        let key = root.isEmpty ? "root" : root
        char.row["bonds"] = .object([key: .object(["text": .string("BOND_TEXT")])])
        var b = try ChatPrompt.build(chat: chat, char: char, settings: .load())
        XCTAssertTrue(b.system.contains("[你们之间的关系]\nBOND_TEXT"))
        char.row["states"] = .object([key: .object(["blocks": .object(["us": .string("US_TEXT")])])])
        b = try ChatPrompt.build(chat: chat, char: char, settings: .load())
        XCTAssertTrue(b.system.contains("[你们之间的关系]\nUS_TEXT"))
        XCTAssertFalse(b.system.contains("BOND_TEXT"))
    }

    /// [现状]：总结记忆写下的几块，加上进行中的事；放久了的进行中的事不常驻
    func testStateBlockWithOngoing() throws {
        try importFixture("data.json")
        var char = try XCTUnwrap(Repo.character("char_a"))
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let personas = try Repo.personas()
        let me = try personas.first { $0.id == chat.personaId } ?? Repo.activePersona(.load())
        let root = Repo.rootId(of: me?.id ?? "", in: personas)
        let key = root.isEmpty ? "root" : root
        char.row["states"] = .object([key: .object(["blocks": .object(["user": .string("USER_STATE"), "recent": .string("LATELY_STATE")]),
                                                     "at": .number(Date().millis)])])
        try Database.shared.put(Collections.characters, char.row)
        let now = Date().millis
        try Database.shared.put(Collections.memories, Row.new(prefix: "mem", [
            "charId": .string("char_a"), "kind": .string("open"), "status": .string("open"), "about": .string("user"),
            "content": .string("ONGOING_FRESH"), "at": .number(now - 86_400_000), "rank": .string("B")]))
        try Database.shared.put(Collections.memories, Row.new(prefix: "mem", [
            "charId": .string("char_a"), "kind": .string("open"), "status": .string("open"),
            "content": .string("ONGOING_STALE"), "at": .number(now - 10 * 86_400_000), "rank": .string("B")]))
        let b = try ChatPrompt.build(chat: chat, char: try XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertTrue(b.system.contains("[现状] (as of"))
        XCTAssertTrue(b.system.contains("About the user:\nUSER_STATE"))
        XCTAssertTrue(b.system.contains("Lately:\nLATELY_STATE"))
        XCTAssertTrue(b.system.contains("Ongoing, not yet settled:"))
        XCTAssertTrue(b.system.contains("(about the user) ONGOING_FRESH"))
        XCTAssertFalse(b.system.contains("ONGOING_STALE"))
        // 记忆总开关关着时不给
        try setSettings(["memoryEnabled": .bool(false)])
        let off = try ChatPrompt.build(chat: chat, char: try XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertFalse(off.system.contains("[现状]"))
    }

    /// 单聊历史里角色从前那几条带着译文；末尾再提醒一次
    func testHistoryKeepsTranslation() throws {
        try importFixture("data.json")
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        chat.row["translateTo"] = .string("English")
        try Repo.save(chat)
        var last = try XCTUnwrap(Repo.messages(chatId: "chat_a").last { $0.role == .char && !$0.isError })
        last.row["translation"] = .string("TR_TEXT")
        try Database.shared.put(Collections.messages, last.row)
        let b = try ChatPrompt.build(chat: try XCTUnwrap(Repo.chat("chat_a")), char: try XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertTrue(b.messages.contains { $0.role == .assistant && $0.content.contains("[译文：TR_TEXT]") })
        XCTAssertTrue(b.messages.contains { $0.content.contains("[译文提醒]") && $0.content.contains("English") })
    }

    /// 撤回能力：角色有还挂着的动态时，写明可以撤回动态与那一条是什么（网页版 capabilities.js 的 postLine）
    func testRecallMentionsLatestPost() throws {
        _ = try build(["promptLean": .bool(false)])
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        for mo in Moments.by("char_a") where !mo.recalled { try Moments.update(mo.id, ["recalled": .number(Date().millis)]) }
        let none = try ChatPrompt.build(chat: chat, char: char, settings: .load()).system
        XCTAssertTrue(none.contains("[撤回]\n"), "撤回能力本身在")
        XCTAssertFalse(none.contains("[撤回动态]"))
        let mo = try Moments.create(authorId: "char_a", text: "去海边了\n  看日落")
        let with = try ChatPrompt.build(chat: chat, char: char, settings: .load()).system
        XCTAssertTrue(with.contains("[撤回动态]"))
        XCTAssertTrue(with.contains("去海边了 看日落"))
        try Moments.update(mo.id, ["recalled": .number(Date().millis)])
        XCTAssertFalse(try ChatPrompt.build(chat: chat, char: char, settings: .load()).system.contains("[撤回动态]"))
    }
}
