import XCTest
@testable import Eira

/// 群聊：按名字拆回各人、拼装、一轮一次调用、@、禁言。
final class GroupTests: StoreTestCase {
    private var zhou: Character!
    private var group: Chat!

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
        var z = try People.createCharacter(name: "小周")
        z.row["persona"] = .string("ZHOU_PERSONA")
        try Database.shared.put(Collections.characters, z.row)
        zhou = z
        group = try GroupChat.create(memberIds: ["char_a", z.id], title: "", personaId: "me_root")
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func members() -> [Character] { GroupChat.members(group) }

    func testCreateNeedsTwo() {
        XCTAssertThrowsError(try GroupChat.create(memberIds: ["char_a"], title: "", personaId: "me_root"))
        XCTAssertEqual(GroupChat.title(group, members: members()), "林、小周")
    }

    func testSplitSpeakers() {
        let raw = "开场一句\n林：在\n小周：嗯\n继续一句\n**林**：好\n【小周】：对\n小于：我替你说"
        let segs = GroupChat.splitSpeakers(raw, members: members(), chat: group, userName: "小于", fallback: zhou.id)
        XCTAssertEqual(segs.map(\.charId), [zhou.id, "char_a", zhou.id, "char_a", zhou.id])
        XCTAssertEqual(segs.map(\.text), ["开场一句", "在", "嗯\n继续一句", "好", "对"])
    }

    func testPromptShape() throws {
        _ = try ChatEngine.send(text: "大家好", chatId: group.id)
        let b = try ChatPrompt.buildGroup(chat: XCTUnwrap(Repo.chat(group.id)), members: members(), settings: .load())
        XCTAssertTrue(b.system.contains("[成员：林]\n\nPERSONA_TEXT"))
        XCTAssertTrue(b.system.contains("[成员：小周]\n\nZHOU_PERSONA"))
        XCTAssertTrue(b.system.contains("[群聊规则]"))
        XCTAssertTrue(b.system.contains("The members are 林、小周"))
        // 一对一才有的能力不进群
        XCTAssertFalse(b.system.contains("[转账：amount note]"))
        XCTAssertTrue(b.messages.last?.content.contains("大家好") == true)
    }

    /// 一轮一次调用；按名字落到各人；历史里成员的话带名字；重新生成照样走。
    func testGroupReplyOneRequest() async throws {
        _ = try ChatEngine.send(text: "@小周 在吗", chatId: group.id)
        XCTAssertEqual(try Repo.messages(chatId: group.id).last?.row["mentions"]?.array?.first?.string, zhou.id)
        let b = try ChatPrompt.buildGroup(chat: XCTUnwrap(Repo.chat(group.id)), members: members(), settings: .load())
        XCTAssertTrue(b.messages.contains { $0.content.contains("[本轮点名]") && $0.content.contains("小周") })

        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("小周：在的\n林：我也在")) }
        try await ChatEngine.reply(chatId: group.id) { _ in }
        XCTAssertEqual(MockNet.count, 1)
        let list = try Repo.messages(chatId: group.id).filter { $0.role == .char }
        XCTAssertEqual(list.map(\.authorId), [zhou.id, "char_a"])
        XCTAssertEqual(list.map(\.content), ["在的", "我也在"])
        XCTAssertEqual(Set(list.map(\.turnId)).count, 1)

        let next = try ChatPrompt.buildGroup(chat: XCTUnwrap(Repo.chat(group.id)), members: members(), settings: .load())
        XCTAssertTrue(next.messages.contains { $0.role == .assistant && $0.content.contains("小周：在的") })

        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("林：换一句")) }
        try await ChatEngine.reply(chatId: group.id, regenerate: true) { _ in }
        let after = try Repo.messages(chatId: group.id).filter { $0.role == .char }
        XCTAssertEqual(after.map(\.content), ["换一句"])
    }

    /// 被禁言的成员写的不落；全员都在禁言中时不调接口。
    func testMuted() async throws {
        var c = try XCTUnwrap(Repo.chat(group.id))
        c.row["mutes"] = .object([zhou.id: .number(0)])
        try Repo.save(c)
        _ = try ChatEngine.send(text: "在吗", chatId: group.id)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("小周：我被禁言了\n林：我在")) }
        try await ChatEngine.reply(chatId: group.id) { _ in }
        XCTAssertEqual(try Repo.messages(chatId: group.id).filter { $0.role == .char }.map(\.content), ["我在"])

        c = try XCTUnwrap(Repo.chat(group.id))
        c.row["muteAll"] = .bool(true)
        try Repo.save(c)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("林：x")) }
        do { try await ChatEngine.reply(chatId: group.id) { _ in }; XCTFail("应当不调用") } catch {}
        XCTAssertEqual(MockNet.count, 0)
    }

    /// 群里的 [私信：…] 落进那位成员与你的私聊，群里不显示；重新生成时一起撤掉
    func testDmGoesToPrivateChat() async throws {
        _ = try ChatEngine.send(text: "大家好", chatId: group.id)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("小周：[私信：只告诉你]\n林：大家好")) }
        try await ChatEngine.reply(chatId: group.id) { _ in }
        XCTAssertFalse(try Repo.messages(chatId: group.id).contains { $0.content.contains("只告诉你") })
        let pc = try People.chatFor(charId: zhou.id, personaId: group.personaId)
        let dm = try XCTUnwrap(Repo.messages(chatId: pc.id).last)
        XCTAssertEqual(dm.content, "只告诉你")
        XCTAssertEqual(dm.row.string("fromGroup"), group.id)
        XCTAssertEqual(try Repo.chat(pc.id)?.unread, 1)

        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("林：重来")) }
        try await ChatEngine.reply(chatId: group.id, regenerate: true) { _ in }
        XCTAssertFalse(try Repo.messages(chatId: pc.id).contains { $0.content == "只告诉你" })

        // 群里关了私信：不落
        var g = try XCTUnwrap(Repo.chat(group.id))
        g.row["groupDM"] = .bool(false)
        try Repo.save(g)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("小周：[私信：再说一次]\n林：嗯")) }
        try await ChatEngine.reply(chatId: group.id, regenerate: true) { _ in }
        XCTAssertFalse(try Repo.messages(chatId: pc.id).contains { $0.content == "再说一次" })
        XCTAssertFalse(try Repo.messages(chatId: group.id).contains { $0.content.contains("再说一次") })
    }
}

extension GroupTests {
    func testMentionCompletion() throws {
        XCTAssertNil(GroupChat.pendingAt("你好"))
        XCTAssertEqual(GroupChat.pendingAt("你好 @"), "")
        XCTAssertNil(GroupChat.pendingAt("@某人 你好"))
        let chat: Chat = group
        let members = GroupChat.members(chat)
        let first = try XCTUnwrap(members.first)
        let key = String(first.name.prefix(1))
        XCTAssertTrue(GroupChat.mentionCandidates("问一下 @\(key)", chat: chat, members: members).contains { $0.id == first.id })
        XCTAssertEqual(GroupChat.completeMention("问一下 @\(key)", chat: chat, first), "问一下 @\(GroupChat.nameIn(chat, first)) ")
    }
}
