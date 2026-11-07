import XCTest
@testable import Eira

/// 「我们」（网页版 4.117、4.263、4.264、4.283、4.396，反馈 10）：作品与篇、后续选项、大纲、写一段的请求怎么拼。
final class WorkTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
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

    func testCreateAndChapters() throws {
        var d = Works.Draft()
        d.kind = Works.EXTRA
        XCTAssertThrowsError(try Works.create(d), "番外要挂在一段会话上")
        d.chatId = "chat_a"
        let extra = try Works.create(d)
        XCTAssertEqual(extra.strings("castIds"), ["char_a"])
        XCTAssertTrue(extra.bool("carry"), "番外一律带原来的记忆")
        var s = Works.Draft()
        s.kind = Works.SAGA
        s.castIds = ["char_a"]
        s.carry = true
        let saga = try Works.create(s)
        XCTAssertFalse(saga.bool("carry"), "不挂会话的长篇没有原来的记忆可带")
        XCTAssertEqual(saga.string("opening"), "char")
        let a = try XCTUnwrap(Works.addChapter(saga.id, title: "开端"))
        let b = try XCTUnwrap(Works.addChapter(saga.id))
        XCTAssertEqual([a, b].map { $0.number("no") }, [1, 2])
        XCTAssertEqual(Works.chapterTitle(saga, a), "第 1 章　开端")
        let e1 = try XCTUnwrap(Works.addChapter(extra.id))
        XCTAssertEqual(Works.chapterTitle(extra, e1), "第 1 则")
        try Scenes.addBeat(sceneId: b.id, role: Scenes.CHAR, authorId: "char_a", text: "第二章的正文")
        XCTAssertTrue(try Works.moveChapter(b.id, -1))
        XCTAssertEqual(Works.chaptersOf(saga.id).map(\.id), [b.id, a.id])
        XCTAssertEqual(Works.statsOf(saga.id).chars, 6)
        try Works.removeChapter(b.id)
        XCTAssertTrue(Scenes.beatsOf(b.id).isEmpty)
        try Works.update(extra.id, ["carry": .bool(false)])
        XCTAssertEqual(Works.get(extra.id)?.bool("carry"), true, "番外的 carry 改不掉")
        try Works.remove(saga.id)
        XCTAssertNil(Works.get(saga.id))
        XCTAssertTrue(Works.chaptersOf(saga.id).isEmpty)
        // 删会话：挂在上面的作品连同章与正文一起删
        try Scenes.addBeat(sceneId: e1.id, role: Scenes.CHAR, authorId: "char_a", text: "番外正文")
        try People.deleteChat("chat_a")
        XCTAssertNil(Works.get(extra.id))
        XCTAssertNil(Works.getChapter(e1.id))
        XCTAssertTrue(Scenes.beatsOf(e1.id).isEmpty)
    }

    func testTakeNext() {
        let r = Works.takeNext("正文第一段\n\n[后续：她去车站]\n【后续：他留下】\n[后续：  ]\n[后续：第四个]\n[后续：第五个]")
        XCTAssertEqual(r.text, "正文第一段")
        XCTAssertEqual(r.items, ["她去车站", "他留下", "第四个"])
        XCTAssertEqual(Works.takeNext("没有标记").text, "没有标记")
        XCTAssertEqual(Works.takeNext("没有标记").items, [])
        XCTAssertEqual(Works.cutNext("写到这里[后续：一"), "写到这里")
    }

    func testOutline() throws {
        var d = Works.Draft()
        d.kind = Works.SAGA
        d.castIds = ["char_a"]
        d.length = (chapters: 24, perChapter: 3000)
        let w = try Works.create(d)
        let json = try JSONValue.parse(Data(#"{"master":{"mainline":"主线","subline":"","ending":"结局","twists":["转折一"],"arcs":[]},"volumes":[{"no":1,"title":"上","goal":"相遇","from":1,"to":12,"reveal":"身份","chapters":[{"no":1,"title":"初见","line":"在车站遇见"}]},{"no":2,"goal":"分开","from":13,"to":24}]}"#.utf8))
        let made = Novel.made(json)
        XCTAssertEqual(made.volumes.count, 2)
        XCTAssertEqual(made.chapters[1]?.first?.title, "初见")
        try Novel.setOutline(w.id) { $0.mode = Novel.HIDDEN }
        try Novel.applyOutline(w.id, made)
        let cur = try XCTUnwrap(Works.get(w.id))
        let o = Novel.outlineOf(cur)
        XCTAssertEqual(o.mode, Novel.HIDDEN)
        XCTAssertTrue(Novel.hasOutline(cur))
        XCTAssertEqual(Novel.volumeOf(o, 13)?.no, 2)
        XCTAssertEqual(Novel.lineOf(o, 1)?.line, "在车站遇见")
        XCTAssertEqual(Novel.volumeMissing(o, 14)?.no, 2)
        XCTAssertNil(Novel.volumeMissing(o, 2))
        XCTAssertEqual(Novel.visibleChapters(cur), 0, "隐藏、没揭晓：一章都不露")
        let ch = try XCTUnwrap(Works.addChapter(w.id, plan: "改走海边"))
        let lines = Novel.promptLines(try XCTUnwrap(Works.get(w.id)), ch)
        XCTAssertEqual(lines.first, "Progress: chapter 1 of 24 planned (4%).")
        XCTAssertTrue(lines.contains("主线：主线"))
        XCTAssertTrue(lines.contains("关键转折：转折一"))
        XCTAssertTrue(lines.contains("当前卷：第 1 卷　上（第 1 到 12 章）：相遇；本卷揭晓：身份"))
        XCTAssertTrue(lines.contains("本章：初见　在车站遇见"))
        XCTAssertTrue(lines.contains("本章走向（已选定）：改走海边"))
        // 存回去的结构与网页版一致：章纲按卷号作键
        XCTAssertNotNil(Works.get(w.id)?["outline"]?["chapters"]?["1"]?.array)
        try Novel.setOutline(w.id) { $0.revealed = "written" }
        XCTAssertEqual(Novel.visibleChapters(try XCTUnwrap(Works.get(w.id))), 1)
        XCTAssertEqual(Novel.volumesFor(24), 2)
        XCTAssertEqual(Novel.volumesFor(0), 1)
        XCTAssertEqual(Novel.volumesFor(1000), 20)
        // 重排：已经写过的卷留着，后面接上新排的
        let fresh = Novel.Made(master: nil, volumes: [Novel.Volume(no: 1, title: "新", goal: "重来", from: 13, to: 24, reveal: "")], chapters: [:])
        try WorkTasks.applyReplan(w.id, from: 13, fresh)
        let after = Novel.outlineOf(Works.get(w.id))
        XCTAssertEqual(after.volumes.map(\.goal), ["相遇", "重来"])
        XCTAssertEqual(after.volumes.map(\.no), [1, 2])
        XCTAssertEqual(after.master?.mainline, "主线")
    }

    func testPromptNotCarried() throws {
        var d = Works.Draft()
        d.kind = Works.SAGA
        d.castIds = ["char_a"]
        d.premise = "PREMISE_X"
        d.charAs = (name: "阿林", persona: "NEW_PERSONA")
        d.endNext = true
        let w = try Works.create(d)
        let c1 = try XCTUnwrap(Works.addChapter(w.id, title: "一"))
        try Scenes.addBeat(sceneId: c1.id, role: Scenes.CHAR, authorId: "char_a", text: "CHAPTER_ONE_END")
        let c2 = try XCTUnwrap(Works.addChapter(w.id, place: "海边", note: "NOTE_X", plan: "LEAD_X", planFrom: "end", fromChapterId: c1.id))
        try Scenes.addBeat(sceneId: c2.id, role: Scenes.ME, authorId: "me", text: "我先到了")
        try Scenes.addBeat(sceneId: c2.id, role: Scenes.DIRECTOR, text: "DIRECTOR_X")
        let built = try WorkPrompt.build(work: try XCTUnwrap(Works.get(w.id)), chapter: try XCTUnwrap(Works.getChapter(c2.id)),
                                         list: Scenes.beatsOf(c2.id), settings: .load())
        let s = built.system
        XCTAssertTrue(s.hasPrefix("You are 阿林. You and 小于 are together in this story."))
        XCTAssertTrue(s.contains("\n\n[阿林]\nNEW_PERSONA"), "不带原来的关系时，角色是这部作品里的那一个")
        XCTAssertFalse(s.contains("PERSONA_TEXT"))
        XCTAssertFalse(s.contains("PINNED_MEMORY"), "不带原来的关系：记忆一样都不注入")
        XCTAssertFalse(s.contains("[对方是谁]"))
        XCTAssertTrue(s.contains("林 在这部作品里是「阿林」"))
        XCTAssertTrue(s.contains("[这部作品]\nPREMISE_X"))
        XCTAssertTrue(s.contains("[这一篇]\n第 2 章\n地点：海边\n情境：NOTE_X"))
        XCTAssertTrue(s.contains("[这一篇的走向]\nLEAD_X"))
        XCTAssertTrue(s.contains("[前面写到哪儿了]\n第 1 章　一\nCHAPTER_ONE_END"))
        XCTAssertFalse(s.contains("本章走向（已选定）"), "末尾选的走向另成一块，不进大纲那一块")
        let tail = try XCTUnwrap(built.messages.last)
        XCTAssertEqual(built.messages.count, 1)
        XCTAssertEqual(tail.role, .user)
        XCTAssertTrue(tail.content.hasPrefix("我先到了\n"), "我那一段与末尾的提醒并成一条")
        XCTAssertTrue(tail.content.contains("DIRECTOR_X"))
        XCTAssertTrue(tail.content.contains("[后续选项]"))
    }

    func testPromptCarried() throws {
        var d = Works.Draft()
        d.chatId = "chat_a"
        d.premise = "P"
        let w = try Works.create(d)
        let ch = try XCTUnwrap(Works.addChapter(w.id))
        let s = try WorkPrompt.build(work: w, chapter: ch, list: [], settings: .load()).system
        XCTAssertTrue(s.contains("PERSONA_TEXT"), "带原来的关系：角色卡照常注入")
        XCTAssertTrue(s.contains("[对方是谁]"))
        XCTAssertTrue(s.contains("PINNED_MEMORY"), "记忆那一档默认带")
        try Works.update(w.id, ["carryMemory": .bool(false)])
        let s2 = try WorkPrompt.build(work: try XCTUnwrap(Works.get(w.id)), chapter: ch, list: [], settings: .load()).system
        XCTAssertTrue(s2.contains("PERSONA_TEXT"))
        XCTAssertFalse(s2.contains("PINNED_MEMORY"), "关掉「携带记忆」：一直记着的也不带")
    }
}

/// 「我们」的花钱次数（第 15 条）：写一段点一次调一次；简介、大纲、卷纲、走向、重排、改写身份各点一次调一次；
/// 收篇摘要默认关；让角色开场先记下再写，重开这一页不再写
extension CostTests {
    func testWorkWritingIsOneRequestPerTap() async throws {
        var d = Works.Draft()
        d.chatId = "chat_a"
        let w = try Works.create(d)
        let ch = try XCTUnwrap(Works.addChapter(w.id))
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        do { try await WorkRun.write(chapterId: ch.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(Scenes.beatsOf(ch.id).isEmpty)
        let ch2 = try XCTUnwrap(Works.addChapter(w.id, opening: "char"))
        XCTAssertTrue(Works.claimOpening(ch2.id))
        XCTAssertFalse(Works.claimOpening(ch2.id), "开过一次就不再自动开场，失败也算")
        let mine = try XCTUnwrap(Works.addChapter(w.id, opening: "me"))
        XCTAssertFalse(Works.claimOpening(mine.id))
        let old = try XCTUnwrap(Works.addChapter(w.id, opening: "char"))
        XCTAssertFalse(Works.claimOpening(old.id, now: Date(timeIntervalSinceNow: 120)), "建好一分钟之后不再自动开场")
    }

    func testWorkTasksFailingIsOneRequestEach() async throws {
        var d = Works.Draft()
        d.kind = Works.SAGA
        d.castIds = ["char_a"]
        d.premise = "P"
        d.length = (chapters: 24, perChapter: 3000)
        let w = try Works.create(d)
        let vol = Novel.Volume(no: 1, title: "", goal: "g", from: 1, to: 12, reveal: "")
        let runs: [(String, () async throws -> Void)] = [
            (WorkTasks.synopsisTask, { _ = try await WorkTasks.synopsis(w, hidden: false) }),
            (WorkTasks.outlineTask, { _ = try await WorkTasks.outline(w) }),
            (WorkTasks.outlineTask, { _ = try await WorkTasks.volume(w, vol) }),
            (WorkTasks.branchTask, { _ = try await WorkTasks.branches(w, after: nil, count: 3) }),
            (WorkTasks.outlineTask, { _ = try await WorkTasks.replan(w, from: 2) }),
            (WorkTasks.identityTask, { _ = try await WorkTasks.identity(w, who: "char") }),
        ]
        for (task, run) in runs {
            MockNet.reset { _, _ in .init(status: 500, body: "{}") }
            do { try await run(); XCTFail("\(task) 应当失败") } catch {}
            XCTAssertEqual(MockNet.count, 1, task)
            XCTAssertFalse(ExtraCalls.all.contains { $0.id == task }, task)
        }
        // 收篇摘要默认关：一次都不调
        let ch = try XCTUnwrap(Works.addChapter(w.id))
        try Scenes.addBeat(sceneId: ch.id, role: Scenes.CHAR, authorId: "char_a", text: "正文")
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        let none = try await WorkTasks.wrap(ch.id)
        XCTAssertEqual(none, "")
        XCTAssertEqual(MockNet.count, 0)
        XCTAssertFalse(try XCTUnwrap(ExtraCalls.all.first { $0.id == "workSummary" }).isOn(.load()))
        try setSettings(["workSummary": .bool(true)])
        do { _ = try await WorkTasks.wrap(ch.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
    }

    func testWorkWriteSettlesAndRoutes() async throws {
        var d = Works.Draft()
        d.chatId = "chat_a"
        d.endNext = true
        let w = try Works.create(d)
        let ch = try XCTUnwrap(Works.addChapter(w.id))
        MockNet.reset { _, _ in
            .init(status: 200, body: MockNet.anthropicStream("[时间：2026-01-01 周三 15:00]\n她推开门。\n[后续：去车站]\n[后续：留下]"))
        }
        let beat = try await WorkRun.write(chapterId: ch.id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(MockNet.requests.compactMap { $0.url?.host }, ["main.test"], "正文默认走主用")
        XCTAssertEqual(beat?.string("text"), "她推开门。")
        XCTAssertEqual(beat?.string("at"), "2026-01-01 周三 15:00")
        let cur = try XCTUnwrap(Works.getChapter(ch.id))
        XCTAssertEqual(Works.nextOf(try XCTUnwrap(Works.get(w.id)), cur, lastBeat: Scenes.told(ch.id).last), ["去车站", "留下"])
        // 长篇与番外的正文：没单独选时跟着「线下的正文」那一组；选了就走它（网页版 4.1091）
        try setSettings(["taskRoutes": .object(["scene": .string("svc_third")])])
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.openaiStream("又一段。")) }
        _ = try await WorkRun.write(chapterId: ch.id)
        XCTAssertEqual(MockNet.requests.compactMap { $0.url?.host }, ["third.test"])
        try setSettings(["taskRoutes": .object(["scene": .string("svc_third"), "work": .string("svc_spare")])])
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.openaiStream("再一段。")) }
        _ = try await WorkRun.write(chapterId: ch.id)
        XCTAssertEqual(MockNet.requests.compactMap { $0.url?.host }, ["spare.test"])
        XCTAssertEqual(Scenes.told(ch.id).count, 3)
    }
}
