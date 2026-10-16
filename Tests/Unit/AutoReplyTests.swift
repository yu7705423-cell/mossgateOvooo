import XCTest
@testable import Eira

/// 自动回复：我这边条数到了自动关并落提示；角色那边每段忙碌只回一次；都不调接口
final class AutoReplyTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testMineStopsAtMax() throws {
        try AutoReply.set("chat_a", AutoReply.mine, ["text": .string("在忙"), "max": .number(2), "on": .bool(true)])
        XCTAssertEqual(try AutoReply.fire("chat_a", AutoReply.mine).map(\.content), ["[自动回复] 在忙"])
        let second = try AutoReply.fire("chat_a", AutoReply.mine)
        XCTAssertEqual(second.first?.content, "[自动回复] 在忙")
        XCTAssertEqual(second.last?.kind, "notice")
        XCTAssertTrue(second.last?.content.contains("已达设定的条数上限") == true)
        XCTAssertFalse(AutoReply.isOn(try XCTUnwrap(Repo.chat("chat_a")), AutoReply.mine))
        XCTAssertTrue(try AutoReply.fire("chat_a", AutoReply.mine).isEmpty)
    }

    func testMineStopsAtTime() throws {
        try AutoReply.set("chat_a", AutoReply.mine, ["text": .string("在忙"), "until": .number(Date().millis - 1000), "on": .bool(true)])
        let out = try AutoReply.fire("chat_a", AutoReply.mine)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].content.contains("已到设定的结束时间"))
    }

    func testHersOncePerWindow() throws {
        // 免打扰时段设成全天（0 到 23 点之外只有一个小时），保证此刻在休息
        var char = try XCTUnwrap(Repo.character("char_a"))
        let h = DayPlan.hour(char)
        char.row["proactiveQuietFrom"] = .number(Double(h))
        char.row["proactiveQuietTo"] = .number(Double((h + 2) % 24))
        try Database.shared.put(Collections.characters, char.row)
        try AutoReply.set("chat_a", AutoReply.hers, ["on": .bool(true), "text": .string("睡了")])
        XCTAssertEqual(try AutoReply.fire("chat_a", AutoReply.hers).map(\.content), ["[自动回复] 睡了"])
        XCTAssertTrue(try AutoReply.fire("chat_a", AutoReply.hers).isEmpty)
    }

    /// 停止的提示只给你看、不进提示词；从前没带标记的自动回复进提示词时补上 [自动回复]
    func testPromptTagsAndLocalNotice() throws {
        try AutoReply.set("chat_a", AutoReply.mine, ["text": .string("在忙"), "max": .number(1), "on": .bool(true)])
        let out = try AutoReply.fire("chat_a", AutoReply.mine)
        XCTAssertEqual(out.last?.row.bool("local"), true)
        var old = Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "旧的自动回复")
        old.row["auto"] = .bool(true)
        _ = try Repo.append(old)
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let b = try ChatPrompt.build(chat: chat, char: try XCTUnwrap(Repo.character("char_a")), settings: .load())
        let text = b.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(text.contains("[自动回复] 在忙"))
        XCTAssertTrue(text.contains("[自动回复] 旧的自动回复"))
        XCTAssertFalse(text.contains("自动回复已停止"))
    }
}

/// 群聊的自动回复按成员设置（网页版 4.649）：开着、在休息的成员各回一句当天日程里的那一句，每段只回一次；
/// 能发言的都回过了才不再立即回；旧版在群里存下的那一份不算。都不调接口
extension AutoReplyTests {
    /// 让这个角色此刻在休息、开着「日常」、当天日程里写好了休息时的那一句
    private func asleep(_ id: String, _ line: String) throws {
        var c = try XCTUnwrap(Repo.character(id))
        let h = DayPlan.hour(c)
        c.row["proactiveQuietFrom"] = .number(Double(h))
        c.row["proactiveQuietTo"] = .number(Double((h + 2) % 24))
        c.row["dayOn"] = .bool(true)
        try Database.shared.put(Collections.characters, c.row)
        try DayPlan.save(id, date: DayPlan.dateKey(c, Clock.now(.load())), ["items": .array([]), "sleepAuto": .string(line)])
    }

    func testGroupMembersEachReplyOnce() throws {
        let zhou = try People.createCharacter(name: "小周")
        let g = try GroupChat.create(memberIds: ["char_a", zhou.id], title: "", personaId: "me_root")
        try asleep("char_a", "睡了")
        try asleep(zhou.id, "明天说")
        // 旧版在群里存下的「角色那边」不算
        try AutoReply.set(g.id, AutoReply.hers, ["on": .bool(true), "text": .string("旧的")])
        XCTAssertTrue(try AutoReply.fire(g.id, AutoReply.hers).isEmpty)

        try AutoReply.setMember(g.id, "char_a", ["on": .bool(true)])
        XCTAssertTrue(AutoReply.member(try XCTUnwrap(Repo.chat(g.id)), "char_a").on)
        XCTAssertFalse(AutoReply.member(try XCTUnwrap(Repo.chat(g.id)), zhou.id).on)
        let first = try AutoReply.afterGroupSend(g.id)
        XCTAssertEqual(first.rows.map(\.content), ["[自动回复] 睡了"])
        XCTAssertEqual(first.rows.first?.authorId, "char_a")
        // 还有一位空着，照常让群里回
        XCTAssertFalse(first.hold)
        XCTAssertNotNil(AutoReply.memberAway(try XCTUnwrap(Repo.chat(g.id)), "char_a"))
        // 同一段休息只回一次
        XCTAssertTrue(try AutoReply.fireGroup(g.id).isEmpty)
    }

    func testGroupAllRepliedHolds() throws {
        let zhou = try People.createCharacter(name: "小周")
        let g = try GroupChat.create(memberIds: ["char_a", zhou.id], title: "", personaId: "me_root")
        try asleep("char_a", "睡了")
        try asleep(zhou.id, "明天说")
        try AutoReply.setMember(g.id, "char_a", ["on": .bool(true)])
        try AutoReply.setMember(g.id, zhou.id, ["on": .bool(true)])
        XCTAssertEqual(AutoReply.membersOn(try XCTUnwrap(Repo.chat(g.id))), 2)
        let out = try AutoReply.afterGroupSend(g.id)
        XCTAssertEqual(Set(out.rows.map(\.content)), ["[自动回复] 睡了", "[自动回复] 明天说"])
        XCTAssertTrue(out.hold)
    }
}
