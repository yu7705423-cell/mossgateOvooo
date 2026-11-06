import XCTest
@testable import Eira

/// 角色眼中的你（网页版 impress.js 与 tasks/impress.js，4.346、4.347）：依据只认你自己发的那几句的编号；整理点一次打一次，
/// 结果先存成待确认，勾选的才收下；没勾的依据落回零散依据；收下的印象进「你对对方的印象」。
final class ImpressTests: StoreTestCase {
    private var me: Persona!
    private var char: Character!
    private var chat: Chat!

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc"), "provider": .string("openai"),
                                         "baseUrl": .string("https://spare.test/v1"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc")])])])
        me = try People.createPersona(name: "小于")
        try People.setActivePersona(me.id)
        char = try People.createCharacter(name: "林")
        chat = try People.chatFor(charId: char.id, personaId: me.id)
        try Repo.append(Message.new(chatId: chat.id, role: .user, authorId: "me", content: "我不太想说这件事"))
        try Repo.append(Message.new(chatId: chat.id, role: .char, authorId: char.id, content: "那就不说"))
        try Repo.append(Message.new(chatId: chat.id, role: .user, authorId: "me", content: "其实也没事"))
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func reply(_ text: String) -> MockNet.Reply { .init(status: 200, body: MockNet.openaiStream(text)) }

    func testOrganizeIsOneCallAndKeepsOnlyUserRefs() async throws {
        XCTAssertEqual(Impress.sinceCount(char.id, me.id), 3)
        MockNet.reset { [self] _, _ in
            reply(#"{"new":[{"text":"不舒服时先说没事","voice":"你总说没事","evidence":["#1","#2","#9"]},{"text":"没有依据的","evidence":[]}],"support":[],"against":[]}"#)
        }
        let draft = try await ImpressTask.organize(charId: char.id, personaId: me.id)
        XCTAssertEqual(MockNet.count, 1)
        let sent = String(data: MockNet.requests[0].httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(sent.contains("#1"))
        XCTAssertTrue(sent.contains("我不太想说这件事"))
        let usage = await Usage.shared.today(task: "impress.organize")
        XCTAssertEqual(usage, 1)
        // 编号只给了你说的两句：#9 不存在不收；没有依据的新印象不收
        let fresh = draft["fresh"]?.array ?? []
        XCTAssertEqual(fresh.count, 1)
        XCTAssertEqual(Impress.evidence(fresh[0]["evidence"]).count, 2)
        XCTAssertEqual(Impress.evidence(fresh[0]["evidence"]).first?["quote"]?.string, "我不太想说这件事")
        XCTAssertNotNil(Impress.draft(char.id, me.id))
    }

    func testAcceptMovesMarkAndUnpickedBecomeNotes() throws {
        let msgs = try Repo.messages(chatId: chat.id)
        let ev = Impress.evidenceOf(msgs[0])
        let d = try Impress.saveDraft(char.id, me.id, fresh: [.init(text: "甲", voice: "", evidence: [ev]), .init(text: "乙", voice: "", evidence: [ev])],
                                      support: [], against: [], noteIds: [], upTo: msgs[2].createdAt)
        try Impress.accept(d.id, fresh: [0])
        XCTAssertEqual(Impress.list(char.id, me.id).map { $0.string("text") }, ["甲"])
        XCTAssertEqual(Impress.notes(char.id, me.id).map { $0.string("text") }, ["乙"])
        XCTAssertNil(Impress.draft(char.id, me.id))
        XCTAssertEqual(Impress.sinceCount(char.id, me.id), 0)
        XCTAssertEqual(Impress.newCount(char.id, me.id), 1)
        try Impress.markSeen(char.id, me.id)
        XCTAssertEqual(Impress.newCount(char.id, me.id), 0)

        // 进「你对对方的印象」；别的账号看不到
        XCTAssertEqual(Impress.block(charId: char.id, personaId: me.id, userName: "小于"),
                       "\n\n[你对对方的印象]\nImpressions of 小于 you have formed, each based on things 小于 said:\n- 甲")
        XCTAssertEqual(Impress.block(charId: char.id, personaId: "me_other", userName: "x"), "")

        // 不准确：不进提示词，记成 dropped
        let id = Impress.list(char.id, me.id)[0].id
        try Impress.drop(id)
        XCTAssertTrue(Impress.list(char.id, me.id).isEmpty)
        XCTAssertEqual(Impress.dropped(char.id, me.id).count, 1)
    }

    func testLevelsCountDays() throws {
        func ev(_ day: String, _ id: String) -> [String: JSONValue] { ["msgId": .string(id), "day": .string(day), "at": .number(1)] }
        XCTAssertEqual(Impress.level(days: Impress.days([ev("2026-01-01", "a"), ev("2026-01-01", "b")]).count).id, "first")
        XCTAssertEqual(Impress.level(days: 2).id, "seen")
        XCTAssertEqual(Impress.level(days: 5).id, "sure")
        try setSettings(["impressSeen": .number(3), "impressSure": .number(4)])
        XCTAssertEqual(Impress.level(days: 2).id, "first")
        XCTAssertEqual(Impress.level(days: 4).id, "sure")
    }

    func testMergeIntoSection() throws {
        let msgs = try Repo.messages(chatId: chat.id)
        let d = try Impress.saveDraft(char.id, me.id, fresh: [.init(text: "怕麻烦别人", voice: "", evidence: [Impress.evidenceOf(msgs[0])])],
                                      support: [], against: [], noteIds: [], upTo: 0)
        let ids = try Impress.accept(d.id, fresh: [0])
        try Impress.merge(ids, personaId: me.id, key: "personality", text: "怕麻烦别人")
        let p = try XCTUnwrap(try Repo.personas().first { $0.id == me.id })
        XCTAssertEqual(SelfProfile.text(p, "personality"), "怕麻烦别人")
        XCTAssertGreaterThan(Impress.get(ids[0])?.number("mergedAt") ?? 0, 0)
    }

    func testFailingOrganizeAndCompareAreBounded() async throws {
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { try await ImpressTask.organize(charId: char.id, personaId: me.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertNil(Impress.draft(char.id, me.id))
        // 少于两位角色：不打
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { try await ImpressTask.compare(personaId: me.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 0)
    }

    func testNothingNewSendsNothing() async throws {
        let other = try People.createCharacter(name: "空")
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { try await ImpressTask.organize(charId: other.id, personaId: me.id); XCTFail("应当失败") } catch {
            XCTAssertTrue(error.localizedDescription.contains("没有新的对话"))
        }
        XCTAssertEqual(MockNet.count, 0)
    }
}
