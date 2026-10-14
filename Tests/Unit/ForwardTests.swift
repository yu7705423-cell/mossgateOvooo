import XCTest
@testable import Eira

/// 转发聊天记录：冻起来的副本、给模型看的正文、可选会话、不调接口。
final class ForwardTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testSendFreezesCopy() throws {
        let a = try Repo.append(Message.new(chatId: "chat_a", role: .user, authorId: "", content: "第一句"))
        let b = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "第二\n句"))
        let target = try XCTUnwrap(Repo.chats().first { $0.id != "chat_a" } ?? Repo.chat("chat_a"))
        let sent = try Forward.send(from: "chat_a", to: target.id, list: [b, a])
        XCTAssertEqual(sent.kind, "forward")
        XCTAssertEqual(sent.role, .user)
        let char = try XCTUnwrap(Repo.character("char_a"))
        let fw = Forward.items(of: sent)
        XCTAssertEqual(fw.items.map(\.text), ["第一句", "第二 句"])
        XCTAssertEqual(fw.items[1].who, char.name)
        XCTAssertTrue(sent.content.hasPrefix("[转发的聊天记录：\(char.name)的聊天记录，共 2 条]"))
        XCTAssertTrue(sent.content.contains("\(char.name)：第二 句"))
        // 原消息删掉，副本不变
        try MessageActions.delete(b)
        let again = try XCTUnwrap(Repo.messages(chatId: target.id).first { $0.id == sent.id })
        XCTAssertEqual(Forward.items(of: again).items.count, 2)
    }

    func testTargetsPutCurrentFirst() throws {
        let list = try Forward.targets(from: "chat_a", personaId: "")
        XCTAssertEqual(list.first?.id, "chat_a")
    }

    func testEmptyThrows() {
        XCTAssertThrowsError(try Forward.send(from: "chat_a", to: "chat_a", list: []))
    }
}
