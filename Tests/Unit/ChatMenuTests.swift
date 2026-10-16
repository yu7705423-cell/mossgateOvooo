import XCTest
@testable import Eira

/// 会话菜单的几页（审计 #25 到 #28）：心声样式存在网页版同一处、清空记忆、每轮调用几次、预设那一行、骰子面数。
final class ChatMenuTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    private func chat() throws -> Chat { try XCTUnwrap(Repo.chat("chat_a")) }

    // MARK: - 心声样式（网页版 chatlook.js 的 setInnerLook / innerSide）

    func testInnerLookStoredWhereWebReadsIt() throws {
        try ChatLook.set("chat_a", ["narr": .string("#112233")])
        try InnerLook.set("chat_a", "inline", ["fg": .string("#AA0000"), "fs": .number(15)])
        try InnerLook.set("chat_a", "card", ["bw": .number(2)])
        let look = try XCTUnwrap(chat().row["look"])
        XCTAssertEqual(look["inner"]?["inline"]?["fg"]?.string, "#AA0000")
        XCTAssertEqual(look["inner"]?["inline"]?["fs"]?.number, 15)
        XCTAssertEqual(look["inner"]?["card"]?["bw"]?.number, 2)
        // 别的样式不动
        XCTAssertEqual(look["narr"]?.string, "#112233")
        XCTAssertEqual(ChatLook.of(try chat()).narr, "#112233")

        // 改一项不冲掉同一边的其余几项；null 与空串都是恢复默认
        try InnerLook.set("chat_a", "inline", ["bg": .string("#FFFFFF")])
        XCTAssertEqual(InnerLook.of(try chat(), "inline").keys.sorted(), ["bg", "fg", "fs"])
        try InnerLook.set("chat_a", "inline", ["fg": .null, "bg": .string("")])
        XCTAssertEqual(InnerLook.of(try chat(), "inline").keys.sorted(), ["fs"])
        XCTAssertEqual(InnerLook.of(try chat(), "card")["bw"]?.number, 2)
    }

    /// 读的时候只留认识的几项，数值钳在网页版的范围里（导入的、手写的都经它过一遍）
    func testInnerLookCleansOnRead() throws {
        try ChatLook.set("chat_a", ["inner": .object(["inline": .object([
            "fg": .string("red"), "bc": .string("#00ff00"), "fs": .number(99), "r": .string("12.6"), "bw": .number(-3), "junk": .number(1),
        ])])])
        let l = InnerLook.of(try chat(), "inline")
        XCTAssertNil(l["fg"])
        XCTAssertEqual(l["bc"]?.string, "#00ff00")
        XCTAssertEqual(l["fs"]?.number, 30)
        XCTAssertEqual(l["r"]?.number, 13)
        XCTAssertEqual(l["bw"]?.number, 0)
        XCTAssertNil(l["junk"])
        XCTAssertTrue(InnerLook.of(try chat(), "card").isEmpty)
    }

    // MARK: - 清空记忆（网页版 purge.clearMemories）

    func testClearMemories() throws {
        // 别的角色的记忆不动
        let other = Row.new(prefix: "mem", ["charId": .string("char_other"), "content": .string("别人的")])
        try Database.shared.put(Collections.memories, other)
        // 现状块与历史版本一并清掉
        var c = try XCTUnwrap(Repo.character("char_a"))
        c.row["states"] = .object(["me_root": .object(["blocks": .object(["us": .string("现状")])])])
        try Database.shared.put(Collections.characters, c.row)
        try Database.shared.put(MemHistory.collection, Row.new(prefix: "snap", ["charId": .string("char_a"), "at": .number(1)]))
        try Database.shared.put(MemHistory.collection, Row.new(prefix: "snap", ["charId": .string("char_other"), "at": .number(1)]))
        let before = try Repo.messages(chatId: "chat_a").count

        XCTAssertEqual(try ClearHistory.counts("char_a").memories, 2)
        XCTAssertEqual(try ClearMemories.run(charId: "char_a"), 2)

        XCTAssertEqual(try Repo.memories(charId: "char_a").count, 0)
        XCTAssertEqual(try Repo.memories(charId: "char_other").count, 1)
        XCTAssertEqual(MemHistory.list("char_a").count, 0)
        XCTAssertEqual(MemHistory.list("char_other").count, 1)
        XCTAssertEqual(try Repo.character("char_a")?.row["states"]?.object?.isEmpty, true)
        // 聊天记录保留
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").count, before)
        XCTAssertEqual(try ClearHistory.counts("char_a").memories, 0)
    }

    // MARK: - 每轮的接口调用（网页版 cost.perTurn / worstPerTurn）

    func testPerTurn() throws {
        var s = AppSettings.load()
        XCTAssertEqual(ExtraCalls.perTurn(try chat(), s), 1)
        XCTAssertEqual(ExtraCalls.perTurnText(try chat(), s), "这段对话每轮调用 1 次接口")

        // 心声单独生成：每轮多一次
        var c = try chat()
        c.row["innerMode"] = .string("apart")
        try Repo.save(c)
        XCTAssertEqual(ExtraCalls.perTurn(try chat(), s), 2)

        // 自动重试与换接口相乘：重试 2 次时最坏是三倍
        try setSettings(["retryMax": .number(2)])
        s = AppSettings.load()
        XCTAssertEqual(ExtraCalls.worstPerTurn(try chat(), s), 6)
        XCTAssertEqual(ExtraCalls.perTurnText(try chat(), s),
                       "这段对话每轮固定调用 2 次接口，请求失败时最多 6 次。点击查看是哪几项，并可逐项关闭")
    }

    /// 群聊：单独生成读成随回复一起（4.636），不多算；按人头调用时回复本身变成成员数那么多次
    func testPerTurnGroup() throws {
        let b = Row.new(prefix: "char", ["name": .string("乙")])
        try Database.shared.put(Collections.characters, b)
        let g = Row.new(prefix: "chat", ["characterIds": .array([.string("char_a"), .string(b.id)]), "group": .bool(true),
                                         "innerMode": .string("apart")])
        try Database.shared.put(Collections.chats, g)
        let group = try XCTUnwrap(Repo.chat(g.id))
        XCTAssertEqual(ExtraCalls.perTurn(group, AppSettings.load()), 1)
        try setSettings(["groupPerChar": .bool(true)])
        XCTAssertEqual(ExtraCalls.perTurn(group, AppSettings.load()), 2)
    }

    // MARK: - 预设那一行写出名字（网页版 Conversation.js）

    func testPresetLabel() throws {
        XCTAssertEqual(ChatPresetPage.label(try chat()), "跟随全局（默认）")
        try setSettings([
            "presetActive": .string("ps_global"),
            "presets": .array([
                .object(["id": .string("ps_global"), "name": .string("日常")]),
                .object(["id": .string("ps_other"), "name": .string("长篇")]),
            ]),
        ])
        XCTAssertEqual(ChatPresetPage.label(try chat()), "跟随全局（日常）")
        var c = try chat()
        c.row["presetId"] = .string("ps_other")
        try Repo.save(c)
        XCTAssertEqual(ChatPresetPage.label(try chat()), "长篇")
        // 选过的那一套删了：写跟随全局
        c.row["presetId"] = .string("ps_gone")
        try Repo.save(c)
        XCTAssertEqual(ChatPresetPage.label(try chat()), "跟随全局（日常）")
    }

    // MARK: - 骰子面数存在 chat.diceFaces（网页版 extras.setFaces）

    func testDiceFacesReadBack() throws {
        XCTAssertEqual(ChatEngine.diceFaces(try chat()), 6)
        var c = try chat()
        c.row["diceFaces"] = .number(20)
        try Repo.save(c)
        XCTAssertEqual(ChatEngine.diceFaces(try chat()), 20)
        XCTAssertEqual(ExtrasPageView.faces, [6, 20, 100])
    }
}
