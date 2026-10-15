import XCTest
@testable import Eira

/// 线下：场次与正文、拼装、写一轮的次数、多人拆段与进离场、线下正文进线上历史。
final class SceneTests: StoreTestCase {
    private var zhou: Character!

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
        zhou = try People.createCharacter(name: "小周")
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func make(cast: [String] = ["char_a"], place: String = "旧书店") throws -> Row {
        var d = Scenes.Draft()
        d.place = place
        d.at = "2026-01-01 周三 14:30"
        d.castIds = cast
        return try Scenes.create(chatId: "chat_a", d)
    }

    func testBeatsAndVersions() throws {
        let sc = try make()
        let a = try Scenes.addBeat(sceneId: sc.id, role: Scenes.ME, authorId: "me", text: "我推门进去")
        let b = try Scenes.addBeat(sceneId: sc.id, role: Scenes.CHAR, authorId: "char_a", text: "第一版", at: "2026-01-01 周三 14:35")
        XCTAssertEqual(Scenes.beatsOf(sc.id).map(\.id), [a.id, b.id])
        XCTAssertEqual(Scenes.timeOf(sc.id), "2026-01-01 周三 14:35")

        try Scenes.addSwipe(b.id, text: "第二版", raw: "第二版", think: "", at: "")
        var cur = try XCTUnwrap(Database.shared.get(Scenes.beats, id: b.id))
        XCTAssertEqual(cur.string("text"), "第二版")
        XCTAssertEqual(Scenes.versions(cur).count, 2)
        try Scenes.pickSwipe(b.id, 0)
        cur = try XCTUnwrap(Database.shared.get(Scenes.beats, id: b.id))
        XCTAssertEqual(cur.string("text"), "第一版")
        try Scenes.dropSwipe(b.id)
        cur = try XCTUnwrap(Database.shared.get(Scenes.beats, id: b.id))
        XCTAssertEqual(Scenes.versions(cur).count, 1)
        XCTAssertEqual(cur.string("text"), "第二版")

        try Scenes.appendBeat(b.id, text: "接着的一句", raw: "接着的一句", at: "")
        cur = try XCTUnwrap(Database.shared.get(Scenes.beats, id: b.id))
        XCTAssertEqual(cur.string("text"), "第二版\n接着的一句")

        XCTAssertEqual(try Scenes.dropFrom(a.id), 2)
        XCTAssertTrue(Scenes.beatsOf(sc.id).isEmpty)
        // 老数据里 swipes 是裸字符串
        var old = Row.new(prefix: "bt", ["sceneId": .string(sc.id), "role": .string("char"), "text": .string("x"),
                                         "swipes": .array([.string("x"), .string("y")]), "swipeIndex": .number(1)])
        old["authorId"] = .string("char_a")
        XCTAssertEqual(Scenes.versions(old).map { $0["text"]?.string }, ["x", "y"])
    }

    func testDirectorLines() throws {
        let sc = try make()
        try Scenes.addBeat(sceneId: sc.id, role: Scenes.DIRECTOR, text: "整场用第二人称", hold: true)
        try Scenes.addBeat(sceneId: sc.id, role: Scenes.DIRECTOR, text: "早先的一条")
        try Scenes.addBeat(sceneId: sc.id, role: Scenes.ME, authorId: "me", text: "嗯")
        try Scenes.addBeat(sceneId: sc.id, role: Scenes.DIRECTOR, text: "这一段让角色先沉默")
        // 常驻的一直在，其余只管下一段：早先那条已经被我那一段隔开了
        XCTAssertEqual(ChatPrompt.directorLines(Scenes.beatsOf(sc.id)), ["整场用第二人称", "这一段让角色先沉默"])
    }

    func testPromptShape() throws {
        let sc = try make()
        try Scenes.addBeat(sceneId: sc.id, role: Scenes.ME, authorId: "me", text: "我在门口站了一会儿")
        try Scenes.addBeat(sceneId: sc.id, role: Scenes.DIRECTOR, text: "STAY_QUIET")
        let char = try XCTUnwrap(Repo.character("char_a"))
        let built = try ChatPrompt.buildScene(scene: try XCTUnwrap(Scenes.get(sc.id)), chat: try XCTUnwrap(Repo.chat("chat_a")), char: char,
                                              list: Scenes.beatsOf(sc.id), more: true, settings: .load())
        XCTAssertTrue(built.system.contains("[正文规则]"))
        XCTAssertTrue(built.system.contains("地点：旧书店"))
        XCTAssertTrue(built.system.contains("[时间]"))
        XCTAssertFalse(built.system.contains("[离场与进场]"))
        let last = try XCTUnwrap(built.messages.last)
        XCTAssertEqual(last.role, .user)
        XCTAssertTrue(last.content.hasPrefix("我在门口站了一会儿"))
        XCTAssertTrue(last.content.contains("[场外指示]\nSTAY_QUIET"))
        XCTAssertTrue(last.content.contains("[接着写]"))
        XCTAssertTrue(last.content.contains("[提醒]"))
        // 选了文风才有文风那一段
        XCTAssertFalse(built.system.contains("[文风]"))
        try Scenes.update(sc.id, ["tones": .array([.string("lean")])])
        let styled = try ChatPrompt.buildScene(scene: try XCTUnwrap(Scenes.get(sc.id)), chat: try XCTUnwrap(Repo.chat("chat_a")), char: char,
                                               list: Scenes.beatsOf(sc.id), settings: .load())
        XCTAssertTrue(styled.system.contains("[文风]\nShort sentences."))
    }

    func testSplitSectionsAndExits() throws {
        let lin = try XCTUnwrap(Repo.character("char_a"))
        let secs = SceneRun.splitSections("开头一句\n【林】\n林说了话\n**【小周】** 小周接着\n[离场]", [lin, zhou])
        XCTAssertEqual(secs.map(\.char.id), ["char_a", "char_a", zhou.id])
        XCTAssertEqual(secs.map(\.text), ["开头一句", "林说了话", "小周接着\n[离场]"])
        let ex = SceneRun.takeExits("走了\n[离场]\n[进场：小周]\n【进场：没有这人】", allowed: [zhou])
        XCTAssertEqual(ex.text, "走了")
        XCTAssertTrue(ex.leave)
        XCTAssertEqual(ex.enter.map(\.id), [zhou.id])
        XCTAssertEqual(ex.unknown, ["没有这人"])
        XCTAssertEqual(SceneRun.stampInner("[时间：2026-01-01 周三 14:30]"), "2026-01-01 周三 14:30")
    }

    /// 一个人在场：写一段只打一次
    func testOneRoundOneRequest() async throws {
        let sc = try make()
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("[时间：2026-01-01 周三 14:40]\n他抬起头。")) }
        let r = try await SceneRun.writeRound(sceneId: sc.id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(r.beats.count, 1)
        let b = try XCTUnwrap(Scenes.told(sc.id).last)
        XCTAssertEqual(b.string("text"), "他抬起头。")
        XCTAssertEqual(b.string("at"), "2026-01-01 周三 14:40")
        XCTAssertEqual(b.string("authorId"), "char_a")
    }

    /// 失败：只打一次，不落空段
    func testFailureOneRequest() async throws {
        let sc = try make()
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        do { _ = try await SceneRun.writeRound(sceneId: sc.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(Scenes.beatsOf(sc.id).isEmpty)
    }

    /// 多人在场：默认一次调用写整轮，拆回各人；写了 [离场] 的落成状态
    func testEnsembleOneRequest() async throws {
        let sc = try make(cast: ["char_a", zhou.id])
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("【林】\n林放下书。\n【小周】\n小周笑了一下。\n[离场]")) }
        let r = try await SceneRun.writeRound(sceneId: sc.id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(r.beats.map { $0.string("authorId") }, ["char_a", zhou.id])
        XCTAssertEqual(r.beats.map { $0.string("text") }, ["林放下书。", "小周笑了一下。"])
        let row = try XCTUnwrap(Scenes.get(sc.id))
        XCTAssertEqual(Scenes.presentOf(row).map(\.id), ["char_a"])
        XCTAssertEqual(Scenes.leftOf(row).map(\.id), [zhou.id])
        XCTAssertEqual(r.notes, ["小周离场"])
    }

    /// 打开「每人单独调用」：在场几个人打几次；默认关着
    func testPerCharIsOptIn() async throws {
        XCTAssertFalse(SceneRun.perCharOn())
        XCTAssertFalse(ExtraCalls.all.first(where: { $0.id == "scenePerChar" })!.isOn(.load()))
        try setSettings(["scenePerChar": .bool(true)])
        let sc = try make(cast: ["char_a", zhou.id])
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("一段。")) }
        let r = try await SceneRun.writeRound(sceneId: sc.id)
        XCTAssertEqual(MockNet.count, 2)
        XCTAssertEqual(r.beats.map { $0.string("authorId") }, ["char_a", zhou.id])
    }

    /// 重写：只关乎那一段的作者，添一版不删旧的
    func testRewriteAddsVersion() async throws {
        let sc = try make()
        let b = try Scenes.addBeat(sceneId: sc.id, role: Scenes.CHAR, authorId: "char_a", text: "旧的")
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("新的")) }
        _ = try await SceneRun.writeRound(sceneId: sc.id, rewrite: b.id)
        XCTAssertEqual(MockNet.count, 1)
        let cur = try XCTUnwrap(Database.shared.get(Scenes.beats, id: b.id))
        XCTAssertEqual(Scenes.versions(cur).compactMap { $0["text"]?.string }, ["旧的", "新的"])
        XCTAssertEqual(Scenes.told(sc.id).count, 1)
    }

    /// 线下正文按时间排进线上的聊天记录，前后各标一行；场外指示不进
    func testOnlineHistorySeesBeats() throws {
        let sc = try make()
        try Scenes.addBeat(sceneId: sc.id, role: Scenes.ME, authorId: "me", text: "BEAT_MINE", now: Date().addingTimeInterval(3600))
        try Scenes.addBeat(sceneId: sc.id, role: Scenes.CHAR, authorId: "char_a", text: "BEAT_CHAR", now: Date().addingTimeInterval(3601))
        try Scenes.addBeat(sceneId: sc.id, role: Scenes.DIRECTOR, text: "DIRECTOR_NOTE", now: Date().addingTimeInterval(3602))
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let built = try ChatPrompt.build(chat: chat, char: try XCTUnwrap(Repo.character("char_a")), settings: .load())
        let all = built.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(all.contains("[以下是线下见面的经过]"))
        XCTAssertTrue(all.contains("小于：BEAT_MINE"))
        XCTAssertTrue(all.contains("林：BEAT_CHAR"))
        XCTAssertTrue(all.contains("[以下在手机上]"))
        XCTAssertFalse(all.contains("DIRECTOR_NOTE"))
        XCTAssertFalse(built.messages.contains { $0.role == .assistant && $0.content.contains("BEAT_CHAR") })
    }

    func testDeleteChatDropsBeats() throws {
        let sc = try make()
        try Scenes.addBeat(sceneId: sc.id, role: Scenes.ME, authorId: "me", text: "x")
        try People.deleteChat("chat_a")
        XCTAssertNil(Scenes.get(sc.id))
        XCTAssertTrue(try Database.shared.all(Scenes.beats, where: sc.id).isEmpty)
    }
    /// 收场摘要与压缩都默认关：关着时一次都不打
    func testSummaryAndCompressOffByDefault() async throws {
        let sc = try make()
        for i in 0..<5 { try Scenes.addBeat(sceneId: sc.id, role: Scenes.CHAR, authorId: "char_a", text: "段\(i)") }
        try setSettings(["sceneWindow": .number(2)])
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("摘要")) }
        let wrapped = try await SceneRun.wrap(sc.id)
        let squeezed = try await SceneRun.compressIfDue(sc.id)
        XCTAssertEqual(wrapped, "")
        XCTAssertFalse(squeezed)
        XCTAssertEqual(MockNet.count, 0)
        for id in ["sceneSummary", "sceneCompress"] { XCTAssertFalse(ExtraCalls.all.first(where: { $0.id == id })!.isOn(.load())) }
    }

    /// 压缩：接口一直失败时，先记下试过，要再多出一个窗口的段落才再试
    func testCompressFailingCountsOnce() async throws {
        let sc = try make()
        for i in 0..<5 { try Scenes.addBeat(sceneId: sc.id, role: Scenes.CHAR, authorId: "char_a", text: "段\(i)") }
        try setSettings(["sceneWindow": .number(2), "sceneCompress": .bool(true)])
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { _ = try await SceneRun.compressIfDue(sc.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        // 再写一段：窗口外多了一段，不到一个窗口，不再试
        try Scenes.addBeat(sceneId: sc.id, role: Scenes.CHAR, authorId: "char_a", text: "段5")
        let again = try await SceneRun.compressIfDue(sc.id)
        XCTAssertFalse(again)
        XCTAssertEqual(MockNet.count, 1)
        // 多出一个窗口之后再试一次
        try Scenes.addBeat(sceneId: sc.id, role: Scenes.CHAR, authorId: "char_a", text: "段6")
        do { _ = try await SceneRun.compressIfDue(sc.id) } catch {}
        XCTAssertEqual(MockNet.count, 2)
    }

    /// 压缩成功：写进这一场的摘要，记下压到哪一段，不重复压
    func testCompressOnce() async throws {
        let sc = try make()
        for i in 0..<5 { try Scenes.addBeat(sceneId: sc.id, role: Scenes.CHAR, authorId: "char_a", text: "段\(i)") }
        try setSettings(["sceneWindow": .number(2), "sceneCompress": .bool(true), "sceneSummary": .bool(true)])
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("前情")) }
        let first = try await SceneRun.compressIfDue(sc.id)
        let second = try await SceneRun.compressIfDue(sc.id)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(Scenes.get(sc.id)?.string("summary"), "前情")
        let text = try await SceneRun.wrap(sc.id)
        XCTAssertEqual(text, "前情")
        XCTAssertEqual(MockNet.count, 2)
    }
}
