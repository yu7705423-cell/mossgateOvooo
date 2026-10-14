import XCTest
@testable import Eira

/// 长按菜单里不调接口的那几件：记住这句、收进示例、生成信息。
final class MessageMenuTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testRememberMakesManualMemory() throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        let m = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.role == .char && $0.kind == "text" })
        let r = try MessageActions.remember(m, chat: chat, char: char)
        let mem = try XCTUnwrap(Database.shared.get(Collections.memories, id: r.memoryId))
        XCTAssertEqual(r.charId, "char_a")
        XCTAssertEqual(mem.string("rank"), "A")
        XCTAssertEqual(mem.string("source"), "manual")
        XCTAssertTrue(mem.string("content").hasSuffix("说：\(m.content)"))
        let mine = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.role == .user })
        XCTAssertTrue(try XCTUnwrap(Database.shared.get(Collections.memories, id: MessageActions.remember(mine, chat: chat, char: char).memoryId))
            .string("content").hasPrefix("我说："))
    }

    func testAddExampleOnce() throws {
        let m = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.role == .char && $0.kind == "text" })
        XCTAssertTrue(try MessageActions.addExample(m))
        XCTAssertFalse(try MessageActions.addExample(m))
        XCTAssertTrue(try XCTUnwrap(Repo.character("char_a")).row.string("exampleDialogue").contains("：\(m.content)"))
    }

    func testServedText() throws {
        var m = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "嗯", turnId: "turn_x")
        m.row["served"] = .array([.object(["name": .string("主用"), "model": .string("model-a"), "at": .number(Date().millis)])])
        m.row["swipeIndex"] = .number(0)
        m = try Repo.append(m)
        XCTAssertTrue(try MessageActions.servedText(m).hasPrefix("由「主用」的 model-a 生成"))
        let bare = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "嗯"))
        XCTAssertEqual(try MessageActions.servedText(bare), "这一条生成时尚未记录模型")
    }
}
