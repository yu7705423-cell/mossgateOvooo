import XCTest
@testable import Eira

/// 搜索聊天记录：正文与译文都搜，失败的、撤回的不算，新的在前，只在本机找。
final class SearchChatTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testFindsContentAndTranslation() throws {
        let a = try Repo.append(Message.new(chatId: "chat_a", role: .user, authorId: "", content: "今天去看海"))
        var b = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "Let us go to the sea")
        b.row["translation"] = .string("一起去看海")
        b = try Repo.append(b)
        let hits = try SearchChatView.search("看海", chatId: "chat_a")
        XCTAssertEqual(hits.map(\.id), [b.id, a.id])
        XCTAssertEqual(try SearchChatView.search("SEA", chatId: "chat_a").map(\.id), [b.id])
    }

    func testSkipsErrorsAndBlank() throws {
        var e = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "独一无二的失败")
        e.row["status"] = .string("error")
        _ = try Repo.append(e)
        XCTAssertTrue(try SearchChatView.search("独一无二的失败", chatId: "chat_a").isEmpty)
        XCTAssertTrue(try SearchChatView.search("  ", chatId: "chat_a").isEmpty)
    }

    func testOtherChatNotInSingleSearch() throws {
        let others = try Repo.chats().filter { $0.id != "chat_a" }
        guard let other = others.first else { return }
        _ = try Repo.append(Message.new(chatId: other.id, role: .user, authorId: "", content: "别处的暗号"))
        XCTAssertTrue(try SearchChatView.search("别处的暗号", chatId: "chat_a").isEmpty)
        XCTAssertEqual(try SearchChatView.search("别处的暗号", chatId: other.id).count, 1)
    }
}
