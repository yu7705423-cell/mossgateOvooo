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

    // MARK: - 译文（网页版 4.363）与配图（4.587、4.589）

    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private func body(_ r: URLRequest) -> String { String(decoding: r.httpBodyStreamData() ?? Data(), as: UTF8.self) }
    private func isImage(_ r: URLRequest) -> Bool { r.url?.host == "img.test" }

    private func translate(_ lang: String) throws {
        var row = try XCTUnwrap(Database.shared.get(Collections.chats, id: "chat_a"))
        row["translateTo"] = .string(lang)
        try Database.shared.put(Collections.chats, row)
    }

    private func imageService(rate: Double? = nil) throws {
        var s = AppSettings.load()
        var services = s.services
        services["image"] = .object(["presets": .array([.object([
            "id": .string("img_a"), "name": .string("测试"), "kind": .string("openai"),
            "baseUrl": .string("https://img.test/v1"), "apiKey": .string("k"), "model": .string("gpt-image-1")])]),
            "activeId": .string("img_a")])
        s.raw["services"] = .object(services)
        if let rate { s.raw["momentImageRate"] = .number(rate) }
        try s.save()
    }

    /// 等后台那一张画完
    private func settle(_ id: String) async throws {
        for _ in 0..<100 {
            if Moments.get(id)?.imagePending != true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("配图一直停在生成中")
    }

    /// 私聊开着翻译：发动态、评论、回复都在同一次调用里要译文，存在 translation 上；没开不要、给了也不存
    func testTranslationFollowsPrivateChat() async throws {
        try translate("English")
        MockNet.reset { _, _ in self.reply(#"{"text":"今天下雨","mood":"平静","translation":"It rained today"}"#) }
        let mo = try await Moments.createMoment(charId: "char_a", roll: 99)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(body(try XCTUnwrap(MockNet.requests.first)).contains("## Translation"))
        XCTAssertEqual(Moments.get(mo.id)?.translation, "It rained today")

        MockNet.reset { _, _ in self.reply(#"{"text":"好看","translation":"Looks nice"}"#) }
        let mine = try Moments.create(authorId: "me", text: "新发型", visibleTo: ["char_a"])
        _ = await Moments.reactToMine(mine.id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(Moments.get(mine.id)?.comments.first?.translation, "Looks nice")

        MockNet.reset { _, _ in self.reply(#"{"text":"泰山","translation":"Mount Tai"}"#) }
        try await Moments.send(comment: "哪座山", on: mo.id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(Moments.get(mo.id)?.comments.last?.translation, "Mount Tai")
        XCTAssertEqual(Moments.get(mo.id)?.comments.first?.translation, "")

        // 本来就是目标语言的不存
        try translate("中文")
        MockNet.reset { _, _ in self.reply(#"{"text":"今天下雨","translation":"今天下雨了"}"#) }
        let zh = try await Moments.createMoment(charId: "char_a", roll: 99)
        XCTAssertEqual(Moments.get(zh.id)?.translation, "")

        // 私聊没开翻译：不要译文，模型给了也不存
        try translate("")
        MockNet.reset { _, _ in self.reply(#"{"text":"今天下雨","translation":"It rained today"}"#) }
        let plain = try await Moments.createMoment(charId: "char_a", roll: 99)
        XCTAssertFalse(body(try XCTUnwrap(MockNet.requests.first)).contains("## Translation"))
        XCTAssertEqual(Moments.get(plain.id)?.translation, "")
    }

    /// 配图一栏按比例给：没掷中不给、写了也不画；没配生图接口不给
    func testImageRateNotGiven() async throws {
        MockNet.reset { _, _ in self.reply(#"{"text":"海边","imagePrompt":"a beach"}"#) }
        let noApi = try await Moments.createMoment(charId: "char_a", roll: 0)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertFalse(body(try XCTUnwrap(MockNet.requests.first)).contains("Attaching a picture"))
        XCTAssertEqual(Moments.get(noApi.id)?.imagePrompt, "")

        try imageService(rate: 0)
        MockNet.reset { r, _ in self.isImage(r) ? .init(status: 200, body: #"{"data":[{"b64_json":"\#(Self.png)"}]}"#)
            : self.reply(#"{"text":"海边","imagePrompt":"a beach"}"#) }
        let zero = try await Moments.createMoment(charId: "char_a", roll: 0)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertFalse(body(try XCTUnwrap(MockNet.requests.first)).contains("Attaching a picture"))
        XCTAssertFalse(Moments.get(zero.id)?.imagePending ?? true)
        XCTAssertEqual(Moments.imageRate(.load()), 0)

        // 默认 30：掷出 50 不给，掷出 10 给
        try imageService()
        try setSettings(["momentImageRate": .null])
        XCTAssertEqual(Moments.imageRate(.load()), 30)
        MockNet.reset { r, _ in self.isImage(r) ? .init(status: 200, body: #"{"data":[{"b64_json":"\#(Self.png)"}]}"#)
            : self.reply(#"{"text":"海边"}"#) }
        _ = try await Moments.createMoment(charId: "char_a", roll: 50)
        XCTAssertFalse(body(try XCTUnwrap(MockNet.requests.first)).contains("Attaching a picture"))
        MockNet.reset { r, _ in self.isImage(r) ? .init(status: 200, body: #"{"data":[{"b64_json":"\#(Self.png)"}]}"#)
            : self.reply(#"{"text":"海边"}"#) }
        let given = try await Moments.createMoment(charId: "char_a", roll: 10)
        XCTAssertTrue(body(try XCTUnwrap(MockNet.requests.first)).contains("Attaching a picture"))
        // 给了这一栏，角色没写描述：不画
        try await settle(given.id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(Moments.get(given.id)?.images.isEmpty ?? false)
    }

    /// 给了配图一栏、写了描述：再一次生图调用，画好挂上
    func testImageDrawn() async throws {
        try imageService(rate: 100)
        MockNet.reset { r, _ in self.isImage(r) ? .init(status: 200, body: #"{"data":[{"b64_json":"\#(Self.png)"}]}"#)
            : self.reply(#"{"text":"海边","imagePrompt":"a beach at dusk"}"#) }
        let mo = try await Moments.createMoment(charId: "char_a", roll: 99.9)
        XCTAssertEqual(Moments.get(mo.id)?.imagePrompt, "a beach at dusk")
        try await settle(mo.id)
        XCTAssertEqual(MockNet.count, 2)
        XCTAssertEqual(MockNet.requests.filter(isImage).count, 1)
        XCTAssertEqual(Moments.get(mo.id)?.images.count, 1)
        XCTAssertEqual(Moments.get(mo.id)?.imageError, "")
    }

    /// 生图接口一直失败：发一条动态共两次（文字一次、生图一次），不重试，原因记在动态上
    func testImageFailingOnce() async throws {
        try imageService(rate: 100)
        MockNet.reset { r, _ in self.isImage(r) ? .init(status: 500, body: #"{"error":{"message":"boom"}}"#)
            : self.reply(#"{"text":"海边","imagePrompt":"a beach"}"#) }
        let mo = try await Moments.createMoment(charId: "char_a", roll: 0)
        try await settle(mo.id)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(MockNet.count, 2)
        XCTAssertFalse(Moments.get(mo.id)?.imageError.isEmpty ?? true)
        XCTAssertTrue(Moments.get(mo.id)?.images.isEmpty ?? false)
    }

    /// 重新生成配图（4.589）：一次生图调用；成功换下旧图，失败旧图留着、写明原因；自己的动态不画
    func testRedrawImage() async throws {
        try imageService()
        let mo = try Moments.create(authorId: "char_a", text: "海边", images: ["img_old"], extra: ["imagePrompt": .string("a beach")])
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        do { _ = try await Moments.redrawImage(mo.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(Moments.get(mo.id)?.images, ["img_old"])
        XCTAssertFalse(Moments.get(mo.id)?.imageError.isEmpty ?? true)
        XCTAssertFalse(Moments.get(mo.id)?.imagePending ?? true)

        MockNet.reset { _, _ in .init(status: 200, body: #"{"data":[{"b64_json":"\#(Self.png)"}]}"#) }
        let id = try await Moments.redrawImage(mo.id, prompt: "a beach at night")
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(Moments.get(mo.id)?.images, [id])
        XCTAssertEqual(Moments.get(mo.id)?.imagePrompt, "a beach at night")
        XCTAssertEqual(Moments.get(mo.id)?.imageError, "")

        let mine = try Moments.create(authorId: "me", text: "我的", extra: ["imagePrompt": .string("x")])
        do { _ = try await Moments.redrawImage(mine.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
    }
}
