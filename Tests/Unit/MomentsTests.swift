import XCTest
@testable import Eira

/// 朋友圈：读写、可见范围、聊天时角色读到的两段；每个会调接口的地方只在用户点了才调，次数数得清。
final class MomentsTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func reply(_ json: String) -> MockNet.Reply { .init(status: 200, body: MockNet.anthropicStream(json)) }

    func testCreateLikeCommentEdit() throws {
        let mo = try Moments.create(authorId: "me", text: "去海边了", images: ["img_1"])
        try Moments.toggleLike(mo.id)
        XCTAssertEqual(Moments.get(mo.id)?.likes, ["me"])
        try Moments.toggleLike(mo.id)
        XCTAssertEqual(Moments.get(mo.id)?.likes, [])
        let c = try XCTUnwrap(try Moments.addComment(mo.id, authorId: "char_a", text: "好看"))
        try Moments.addComment(mo.id, authorId: "me", text: "谢谢", replyTo: c.id)
        XCTAssertEqual(Moments.get(mo.id)?.comments.last?.replyTo, c.id)
        try Moments.removeComment(mo.id, commentId: c.id)
        XCTAssertEqual(Moments.get(mo.id)?.comments.count, 1)
        try Moments.edit(mo.id, text: "去山里了")
        XCTAssertEqual(Moments.get(mo.id)?.text, "去山里了")
        XCTAssertGreaterThan(Moments.get(mo.id)?.editedAt ?? 0, 0)
        XCTAssertEqual(MockNet.count, 0)
    }

    func testVisibilityAndChatBlock() throws {
        let b = try People.createCharacter(name: "阿岚")
        try Moments.create(authorId: "me", text: "只给阿岚看", visibleTo: [b.id])
        try Moments.create(authorId: "me", text: "仅自己", visibleTo: [])
        try Moments.create(authorId: "me", text: "大家都看得见")
        let a = try XCTUnwrap(Repo.character("char_a"))
        let blockA = Moments.block(char: a, userName: "我")
        XCTAssertTrue(blockA.contains("[对方的朋友圈]"))
        XCTAssertTrue(blockA.contains("大家都看得见"))
        XCTAssertFalse(blockA.contains("只给阿岚看"))
        XCTAssertFalse(blockA.contains("仅自己"))
        let blockB = Moments.block(char: try XCTUnwrap(Repo.character(b.id)), userName: "我")
        XCTAssertTrue(blockB.contains("只给阿岚看"))
        // 角色自己的动态连同评论
        let own = try Moments.create(authorId: "char_a", text: "爬山")
        try Moments.addComment(own.id, authorId: "me", text: "哪座山")
        let again = Moments.block(char: a, userName: "我")
        XCTAssertTrue(again.contains("[你的朋友圈]"))
        XCTAssertTrue(again.contains("我：哪座山"))
        XCTAssertEqual(Moments.viewers(visibleTo: [b.id]).map(\.id), [b.id])
        XCTAssertTrue(Moments.viewers(visibleTo: []).isEmpty)
    }

    func testCreateMomentOneCall() async throws {
        MockNet.reset { _, _ in self.reply(#"{"text":"今天下雨","mood":"平静","imagePrompt":null}"#) }
        let mo = try await Moments.createMoment(charId: "char_a")
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(mo.authorId, "char_a")
        XCTAssertEqual(Moments.get(mo.id)?.text, "今天下雨")
    }

    /// 接口一直失败：刷新一次只打一次（自动重试默认 0）
    func testCreateMomentFailingOnce() async throws {
        do { _ = try await Moments.createMoment(charId: "char_a"); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(Moments.all().isEmpty)
    }

    /// 发布之后看得见的角色各一次；一位失败不拦着后面的
    func testReactToMineOnePerViewer() async throws {
        _ = try People.createCharacter(name: "阿岚")
        let mo = try Moments.create(authorId: "me", text: "新发型")
        let r = await Moments.reactToMine(mo.id)
        XCTAssertEqual(r.done, 0)
        XCTAssertEqual(r.failed.count, 2)
        XCTAssertEqual(MockNet.count, 2)

        MockNet.reset { _, _ in self.reply(#"{"text":"好看"}"#) }
        let only = try Moments.create(authorId: "me", text: "只给 a", visibleTo: ["char_a"])
        let r2 = await Moments.reactToMine(only.id)
        XCTAssertEqual(r2.done, 1)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(Moments.get(only.id)?.likes, ["char_a"])
        XCTAssertEqual(Moments.get(only.id)?.comments.first?.text, "好看")
        // 仅自己可见：一次都不调
        let mine = try Moments.create(authorId: "me", text: "仅自己", visibleTo: [])
        _ = await Moments.reactToMine(mine.id)
        XCTAssertEqual(MockNet.count, 1)
    }

    /// 我评论角色的动态：角色回一句，一次调用；我评论自己的动态不叫任何人
    func testCommentReply() async throws {
        let own = try Moments.create(authorId: "char_a", text: "爬山")
        MockNet.reset { _, _ in self.reply(#"{"text":"泰山"}"#) }
        try await Moments.send(comment: "哪座山", on: own.id)
        XCTAssertEqual(MockNet.count, 1)
        let cs = try XCTUnwrap(Moments.get(own.id)).comments
        XCTAssertEqual(cs.map(\.authorId), ["me", "char_a"])
        XCTAssertEqual(cs[1].replyTo, cs[0].id)

        let mine = try Moments.create(authorId: "me", text: "自言自语")
        try await Moments.send(comment: "补一句", on: mine.id)
        XCTAssertEqual(MockNet.count, 1)
    }
}
