import XCTest
@testable import Eira

/// 聊天补齐：特殊消息画成卡片、列表预览不露协议原文、群管理（群昵称、管理员、禁言、全员禁言）、发文件进上下文
final class ChatFillTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    private func msg(_ kind: String, _ content: String, _ fields: [String: JSONValue] = [:], role: Message.Role = .char) -> Message {
        var m = Message.new(chatId: "chat_a", role: role, authorId: role == .user ? "me" : "char_a", content: content, kind: kind)
        for (k, v) in fields { m.row[k] = v }
        return m
    }

    func testSpecialCards() {
        let pact = SpecialCards.face(msg("pact", "[约定：一起看海]", ["title": .string("一起看海"), "pact": .string("done")]))
        XCTAssertEqual(pact?.title, "一起看海")
        XCTAssertEqual(pact?.foot, "约定已完成")
        let future = Date().millis + 86_400_000 * 3
        let letter = SpecialCards.face(msg("letter", "[信]", ["title": .string("给你"), "body": .string("BODY"), "openAt": .number(future)]))
        XCTAssertEqual(letter?.title, "给你")
        XCTAssertFalse(letter?.body.contains("BODY") ?? true)
        let mine = SpecialCards.face(msg("letter", "[信]", ["body": .string("BODY")], role: .user))
        XCTAssertEqual(mine?.body, "BODY")
        XCTAssertEqual(SpecialCards.face(msg("request", "[申请]", ["requestKind": .string("joint")]))?.foot, "待处理")
        XCTAssertNil(SpecialCards.face(msg("text", "你好")))
        XCTAssertTrue(SpecialCards.kinds.isSuperset(of: ["pact", "letter", "file", "card", "dreamcard", "forumpost", "boxslip"]))
        XCTAssertEqual(SpecialCards.stripped("[约定：一起看海]"), "一起看海")
    }

    func testPreviewHidesProtocol() {
        XCTAssertEqual(MsgPreview.text(msg("sticker", "[表情：开心]")), "[表情]")
        XCTAssertEqual(MsgPreview.text(msg("pact", "[约定：一起看海]", ["title": .string("一起看海")])), "[约定] 一起看海")
        XCTAssertEqual(MsgPreview.text(msg("text", "第一段\n\n第二段")), "第二段")
        XCTAssertEqual(MsgPreview.text(msg("notice", "[某某开启了全员禁言]")), "某某开启了全员禁言")
    }

    func testGroupManagement() throws {
        let z = try People.createCharacter(name: "小周")
        let g = try GroupChat.create(memberIds: ["char_a", z.id], title: "", personaId: "me_root")
        try GroupChat.setNick(g.id, z.id, "阿周")
        try GroupChat.setAdmin(g.id, z.id, true)
        try GroupChat.mute(g.id, "char_a", minutes: 10)
        var c = try XCTUnwrap(Repo.chat(g.id))
        XCTAssertEqual(GroupChat.nick(c, z.id), "阿周")
        XCTAssertEqual(GroupChat.role(c, z.id), "admin")
        XCTAssertTrue(GroupChat.isMuted(c, "char_a"))
        XCTAssertTrue(GroupChat.muteText(c, "char_a").hasPrefix("禁言中"))
        try GroupChat.unmute(g.id, "char_a")
        try GroupChat.setMuteAll(g.id, true)
        c = try XCTUnwrap(Repo.chat(g.id))
        // 全员禁言：管理员照样能说，成员不能
        XCTAssertFalse(GroupChat.isMuted(c, z.id))
        XCTAssertTrue(GroupChat.isMuted(c, "char_a"))
        let notices = try Repo.messages(chatId: g.id).filter { $0.kind == "notice" }.map(\.content)
        XCTAssertEqual(notices.count, 5)
        XCTAssertTrue(notices.contains { $0.contains("阿周") && $0.contains("管理员") })
        // 一样的值不再落提示
        try GroupChat.setNick(g.id, z.id, "阿周")
        XCTAssertEqual(try Repo.messages(chatId: g.id).filter { $0.kind == "notice" }.count, 5)
    }

    func testFileTextGoesIntoHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("旧.txt"), b = dir.appendingPathComponent("新.md")
        try "OLD_FILE_BODY".write(to: a, atomically: true, encoding: .utf8)
        try "NEW_FILE_BODY".write(to: b, atomically: true, encoding: .utf8)
        try ChatFiles.send(a, chatId: "chat_a")
        let sent = try ChatFiles.send(b, chatId: "chat_a")
        XCTAssertEqual(sent.row.string("ext"), "md")
        XCTAssertNotNil(MediaStore.url(.files, id: sent.row.string("fileId")))
        let built = try ChatPrompt.build(chat: try XCTUnwrap(Repo.chat("chat_a")), char: try XCTUnwrap(Repo.character("char_a")), settings: AppSettings.load())
        let all = built.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(all.contains("NEW_FILE_BODY"))
        XCTAssertFalse(all.contains("OLD_FILE_BODY"))
        XCTAssertTrue(all.contains("[文件：旧.txt]"))
        XCTAssertThrowsError(try ChatFiles.send(dir.appendingPathComponent("x.pdf"), chatId: "chat_a"))
    }
}
