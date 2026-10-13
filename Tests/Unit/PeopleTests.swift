import XCTest
@testable import Eira

/// 角色、身份、会话：新建、改、找会话、删除。
final class PeopleTests: StoreTestCase {
    func testCreateCharacterDefaults() throws {
        let c = try People.createCharacter()
        XCTAssertTrue(c.id.hasPrefix("char_"))
        XCTAssertEqual(c.name, "新角色")
        XCTAssertEqual(c.row["canSendVoice"]?.bool, true)
        XCTAssertEqual(c.row["lorebookIds"]?.array?.count, 0)
        XCTAssertNotNil(try Repo.character(c.id))
    }

    /// 改资料只动给的那几项，网页版的其他字段原样留着。
    func testUpdateKeepsOtherFields() throws {
        try importFixture("data.json")
        let c = try XCTUnwrap(Repo.character("char_a"))
        _ = try People.update(c, ["name": .string("新名字"), "persona": .string("新人设")])
        let after = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(after.name, "新名字")
        XCTAssertEqual(after.persona, "新人设")
        XCTAssertEqual(after.row["webOnlyField"]?["keep"]?.bool, true)
        XCTAssertEqual(after.scenario, "SCENARIO_TEXT")
    }

    /// 同一个身份找同一个角色，用的是原来那一段；换个身份是另一段。
    func testChatForReusesPerPersona() throws {
        try importFixture("data.json")
        XCTAssertEqual(try People.chatFor(charId: "char_a", personaId: "me_root").id, "chat_a")
        let alt = try People.createPersona(name: "小号", parentId: "me_root")
        let other = try People.chatFor(charId: "char_a", personaId: alt.id)
        XCTAssertNotEqual(other.id, "chat_a")
        XCTAssertEqual(try People.chatFor(charId: "char_a", personaId: alt.id).id, other.id)
        XCTAssertEqual(try Repo.chats().count, 2)
    }

    func testDeleteCharacterCascades() throws {
        try importFixture("data.json")
        // 按角色挂着的数据域（日程）也要跟着删
        try Database.shared.put("days", Row.new(prefix: "day", ["charId": .string("char_a")]))
        try Database.shared.put("days", Row.new(prefix: "day", ["charId": .string("char_other")]))

        try People.deleteCharacter("char_a")
        XCTAssertNil(try Repo.character("char_a"))
        XCTAssertNil(try Repo.chat("chat_a"))
        XCTAssertTrue(try Repo.messages(chatId: "chat_a").isEmpty)
        XCTAssertTrue(try Repo.memories(charId: "char_a").isEmpty)
        XCTAssertEqual(try Database.shared.all("days").count, 1)
        // 身份、世界书这些不挂在角色身上的不动
        XCTAssertEqual(try Repo.personas().count, 1)
        XCTAssertEqual(try Repo.lorebooks().count, 1)
    }

    /// 群聊里删一个人：剩两人以上的群只移出它，不够两人的群整个删掉。
    func testDeleteCharacterInGroups() throws {
        let a = try People.createCharacter(name: "甲"), b = try People.createCharacter(name: "乙"), c = try People.createCharacter(name: "丙")
        func group(_ ids: [String]) throws -> String {
            let row = Row.new(prefix: "chat", ["group": .bool(true), "characterIds": .array(ids.map { .string($0) })])
            try Database.shared.put(Collections.chats, row)
            try Repo.save(Message.new(chatId: row.id, role: .user, authorId: "me", content: "在吗"))
            return row.id
        }
        let big = try group([a.id, b.id, c.id])
        let small = try group([a.id, b.id])
        try People.deleteCharacter(a.id)
        XCTAssertEqual(try Repo.chat(big)?.characterIds, [b.id, c.id])
        XCTAssertEqual(try Repo.messages(chatId: big).count, 1)
        XCTAssertNil(try Repo.chat(small))
        XCTAssertTrue(try Repo.messages(chatId: small).isEmpty)
    }

    func testPersonas() throws {
        // 从空白开始：没有身份时建一个「我」并设为当前
        let me = try People.ensureActivePersona()
        XCTAssertEqual(me.name, "我")
        XCTAssertEqual(try Repo.activePersona()?.id, me.id)
        XCTAssertEqual(try People.ensureActivePersona().id, me.id)

        let alt = try People.createPersona(name: "小号", parentId: me.id)
        try People.setActivePersona(alt.id)
        XCTAssertEqual(try Repo.activePersona()?.id, alt.id)
        XCTAssertEqual(Repo.rootId(of: alt.id, in: try Repo.personas()), me.id)

        let edited = try People.update(alt, ["description": .string("介绍")])
        XCTAssertEqual(edited.description, "介绍")
        XCTAssertEqual(edited.parentId, me.id)
    }
}
