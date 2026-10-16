import XCTest
@testable import Eira

/// 清空聊天记录（网页版 purge.clearHistory，审计 #5）：这个角色名下的单聊消息全删，总结进度、前情、未读归零；
/// 群聊不动，记忆保留；清完之后没人提到的图与语音只算出来，不删。
final class ClearHistoryTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testClearResetsPointersAndKeepsGroups() throws {
        // 已经总结过、有前情、有未读的一段
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        chat.row["memoryUpTo"] = .string("msg_2")
        chat.row["memoryUpToAt"] = .number(1_760_000_002_000)
        chat.row["memoryTriedId"] = .string("msg_3")
        chat.row["memoryTriedAt"] = .number(1_760_000_003_000)
        chat.row["summary"] = .string("前情")
        try Repo.save(chat)
        var img = Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "[图片]", kind: "image")
        img.row["imageId"] = .string("img_only_here")
        _ = try Repo.append(img)
        var voice = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "[语音：在]", kind: "voice")
        voice.row["audioId"] = .string("f_only_here")
        _ = try Repo.append(voice)
        // 群聊里的话不归这个角色
        let group = Row.new(prefix: "chat", ["characterIds": .array([.string("char_a"), .string("char_x")]), "group": .bool(true),
                                             "personaId": .string("me_root"), "summary": .string("群前情")])
        try Database.shared.put(Collections.chats, group)
        _ = try Repo.append(Message.new(chatId: group.id, role: .user, authorId: "me", content: "群里的话"))

        let n = try ClearHistory.counts("char_a")
        XCTAssertEqual(n, ClearHistory.Counts(chats: 1, messages: 5, memories: 2))

        let r = try ClearHistory.run(charId: "char_a")
        XCTAssertEqual(r.messages, 5)
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").count, 0)
        let after = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertTrue(after.row["memoryUpTo"]?.isNull ?? true)
        XCTAssertEqual(after.row.number("memoryUpToAt"), 0)
        XCTAssertTrue(after.row["memoryTriedId"]?.isNull ?? true)
        XCTAssertEqual(after.row.number("memoryTriedAt"), 0)
        XCTAssertEqual(after.summary, "")
        XCTAssertEqual(after.row.number("unread"), 0)
        XCTAssertEqual(try MemorySummary.pending(chatId: "chat_a").count, 0)
        // 记忆保留；群聊原样
        XCTAssertEqual(try Repo.memories(charId: "char_a").count, 2)
        XCTAssertEqual(try Repo.messages(chatId: group.id).count, 1)
        XCTAssertEqual(try Repo.chat(group.id)?.summary, "群前情")
        // img_a 还被角色头像与表情用着，不算没人用；只在消息里出现过的那一张图与那段语音算
        XCTAssertEqual(r.orphanImages, ["img_only_here"])
        XCTAssertEqual(r.orphanFiles, ["f_only_here"])
    }

    /// 清完再聊：新消息照常进积压，总结从头接上
    func testPendingAfterClear() throws {
        try ClearHistory.run(charId: "char_a")
        _ = try Repo.append(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "重新开始"))
        _ = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "好", turnId: "t1"))
        XCTAssertEqual(try MemorySummary.pending(chatId: "chat_a").count, 2)
    }
}
