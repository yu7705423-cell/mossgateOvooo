import XCTest
@testable import Eira

/// 记忆与世界书的增删改，以及改完之后真的进提示词。
final class KnowledgeTests: StoreTestCase {
    private func prompt() throws -> ChatPrompt.Built {
        try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load())
    }

    func testNewMemoryDefaultsAndSave() throws {
        try importFixture("data.json")
        let m = Knowledge.newMemory(charId: "char_a", personaId: "me_root")
        XCTAssertEqual(m.kind, .fact)
        XCTAssertEqual(m.rank, "B")
        XCTAssertEqual(m.row.string("source"), "manual")
        // 新建的在保存之前不入库
        XCTAssertNil(try Database.shared.get(Collections.memories, id: m.id))
        try Knowledge.save(m, ["content": .string("NEW_PINNED"), "pinned": .bool(true)])
        XCTAssertTrue(try prompt().system.contains("NEW_PINNED"))
    }

    func testKindAndPinRules() throws {
        let m = Knowledge.newMemory(charId: "c", personaId: "p")
        let toOpen = Knowledge.kindPatch(m, to: .open)
        XCTAssertEqual(toOpen["category"]?.string, "pending")
        XCTAssertEqual(toOpen["status"]?.string, "open")
        XCTAssertEqual(Knowledge.pinPatch(pinned: true)["taboo"]?.bool, false)
        XCTAssertEqual(Knowledge.tabooPatch(taboo: true)["pinned"]?.bool, false)
        XCTAssertEqual(Knowledge.splitList("猫、狗, 鱼；鸟"), ["猫", "狗", "鱼", "鸟"])
    }

    /// 身份按根账号隔离：小号看得到大号的记忆，另一个大号看不到。
    func testMemoriesScopedByRootPersona() throws {
        try importFixture("data.json")
        let alt = try People.createPersona(name: "小号", parentId: "me_root")
        let other = try People.createPersona(name: "另一个")
        XCTAssertEqual(try Knowledge.memories(charId: "char_a", personaId: alt.id).count, 2)
        XCTAssertEqual(try Knowledge.memories(charId: "char_a", personaId: other.id).count, 0)
    }

    func testDeleteMemory() throws {
        try importFixture("data.json")
        try Knowledge.deleteMemory("mem_1")
        XCTAssertFalse(try prompt().system.contains("PINNED_MEMORY"))
    }

    func testLorebookEditing() throws {
        try importFixture("data.json")
        let entry = try Knowledge.addEntry(bookId: "lb_1")
        let added = try XCTUnwrap(Knowledge.book("lb_1")?.entries.first { $0.id == entry })
        XCTAssertTrue(added.enabled)
        XCTAssertEqual(added.priority, 100)
        XCTAssertEqual(added.part, "before")

        try Knowledge.updateEntry(bookId: "lb_1", entryId: entry, ["content": .string("NEW_LORE"), "constant": .bool(true)])
        XCTAssertTrue(try prompt().system.contains("NEW_LORE"))

        // 改一条不动别的字段
        try Knowledge.updateEntry(bookId: "lb_1", entryId: "e1", ["comment": .string("改了标题")])
        let e1 = try XCTUnwrap(Knowledge.book("lb_1")?.entries.first { $0.id == "e1" })
        XCTAssertEqual(e1.keys, ["猫"])
        XCTAssertEqual(e1.comment, "改了标题")

        try Knowledge.deleteEntry(bookId: "lb_1", entryId: entry)
        XCTAssertFalse(try prompt().system.contains("NEW_LORE"))
    }

    func testAttachAndGlobal() throws {
        try importFixture("data.json")
        let b = try Knowledge.createBook(name: "新书")
        let e = try Knowledge.addEntry(bookId: b.id)
        try Knowledge.updateEntry(bookId: b.id, entryId: e, ["content": .string("BOOK2"), "constant": .bool(true)])
        XCTAssertFalse(try prompt().system.contains("BOOK2"))

        try Knowledge.setAttached(true, bookId: b.id, charId: "char_a")
        XCTAssertTrue(try prompt().system.contains("BOOK2"))
        try Knowledge.setAttached(false, bookId: b.id, charId: "char_a")
        XCTAssertFalse(try prompt().system.contains("BOOK2"))

        try Knowledge.updateBook(b.id, ["global": .bool(true)])
        XCTAssertTrue(try prompt().system.contains("BOOK2"))
    }

    /// 删书时从角色身上摘下。
    func testDeleteBookDetaches() throws {
        try importFixture("data.json")
        try Knowledge.deleteBook("lb_1")
        XCTAssertEqual(try Repo.character("char_a")?.lorebookIds, [])
        XCTAssertFalse(try prompt().system.contains("LORE_ALWAYS"))
    }
}
