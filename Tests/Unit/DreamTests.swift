import XCTest
@testable import Eira

/// 梦境（网页版 dream.js、tasks/dream.js、context/dream.js）：骰子与碎片、随时间变淡、分幕的拼法、做一次只调一次接口、
/// 写进对话开着才进提示词、[梦境：…] 落一张卡片。
final class DreamTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: "phone.daily.tried")
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
        UserDefaults.standard.removeObject(forKey: "phone.daily.tried")
        try super.tearDownWithError()
    }

    private func char() throws -> Character { try XCTUnwrap(Repo.character("char_a")) }
    private func chat() throws -> Chat { try XCTUnwrap(Repo.chat("chat_a")) }

    private func today(_ level: String, mood: String = "怅然") throws -> Row {
        let row = Row.new(prefix: "dm", ["charId": .string("char_a"), "personaId": .string("me_root"), "date": .string(Dream.todayOf(try char())),
                                         "title": .string("雾"), "scenes": .array([.object(["text": .string("第一幕。")])]), "text": .string("第一幕。"),
                                         "mood": .string(mood), "recallLevel": .string(level), "kept": .array([.string("雾里的灯")])])
        try Database.shared.put("dreams", row)
        return row
    }

    func testRollAndOdds() throws {
        let c = try char()
        XCTAssertEqual(Dream.oddsOf(c), ["full": 20, "fragment": 60, "trace": 20])
        XCTAssertEqual(Dream.roll(c, { 0 }), "full")
        XCTAssertEqual(Dream.roll(c, { 0.5 }), "fragment")
        XCTAssertEqual(Dream.roll(c, { 0.99 }), "trace")
        try Diary.patchChar("char_a", ["dreamOdds": .object(["full": .number(0), "fragment": .number(0), "trace": .number(0)])])
        XCTAssertEqual(Dream.oddsOf(try char()), Dream.oddsDefault)
        XCTAssertEqual(Dream.keepFragments(["a", "b", "c", "d"], [], { 0.9 }).count, 3)
        XCTAssertEqual(Dream.keepFragments([], ["第一幕。后面", "第二幕！"], { 0.1 }), ["第一幕。", "第二幕！"])
    }

    func testFadeAfterNoon() throws {
        let cal = Calendar.current
        let morning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let afternoon = cal.date(bySettingHour: 13, minute: 0, second: 0, of: Date())!
        let row = Row.new(prefix: "dm", ["date": .string(Health.dateKey(morning)), "recallLevel": .string("full")])
        let c = try char()
        XCTAssertEqual(Dream.levelNow(row, c, at: morning), "full")
        XCTAssertEqual(Dream.levelNow(row, c, at: afternoon), "fragment")
        try Diary.patchChar("char_a", ["dreamFade": .bool(false)])
        XCTAssertEqual(Dream.levelNow(row, try char(), at: afternoon), "full")
    }

    func testPlanGivesTwistsPerScene() {
        let mats = ["A", "B", "C"].map { Dream.Material(key: $0, kind: "recent", id: "", text: $0) }
        var n = 0
        let rng: Dream.RNG = { n += 1; return Double(n % 7) / 7 }
        let plan = Dream.plan(mats, acts: 3, bizarre: 2, rng: rng)
        let scenes = plan["scenes"]?.array ?? []
        XCTAssertEqual(scenes.count, 3)
        XCTAssertEqual(scenes.map { $0["twists"]?.array?.count ?? 0 }, [1, 1, 1])
        XCTAssertEqual(Set(scenes.flatMap { ($0["keys"]?.array ?? []).compactMap(\.string) }), ["A", "B", "C"])
        // 最后一幕不跳切，二档不给物理失效
        XCTAssertNotEqual(scenes.last?["twists"]?[0]?["op"]?.string, "cut")
        XCTAssertFalse(scenes.contains { $0["twists"]?[0]?["op"]?.string == "physics" })
        XCTAssertEqual(Dream.twistsPerScene(1, 0), 1)
        XCTAssertEqual(Dream.twistsPerScene(1, 1), 0)
        XCTAssertEqual(Dream.twistsPerScene(3, 0), 2)
    }

    func testWriteOnceAndKeepMemory() async throws {
        try Diary.patchChar("char_a", ["dreamMemory": .bool(true)])
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream(
            #"{"title":"雾","scenes":[{"text":"第一幕。"},{"text":"第二幕。"}],"recall":"梦见了雾","mood":"怅然","fragments":["雾里的灯","一把伞"]}"#)) }
        let row = try await Dream.write("char_a")
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(row.id.hasPrefix("dm_"))
        XCTAssertEqual(row.string("text"), "第一幕。\n\n第二幕。")
        XCTAssertTrue(["full", "fragment", "trace"].contains(row.string("recallLevel")))
        XCTAssertEqual(row.string("source"), "now")
        XCTAssertTrue((row["materials"]?.array ?? []).contains { $0["kind"]?.string == "user" && $0["text"]?.string == "小于" })
        let body = String(decoding: try XCTUnwrap(MockNet.requests.first?.httpBodyStreamData()), as: UTF8.self)
        XCTAssertTrue(body.contains("Scene 1"))
        let mem = try XCTUnwrap(Repo.memories(charId: "char_a").first { $0.row.string("dreamId") == row.id })
        XCTAssertEqual(mem.rank, "C")
        XCTAssertEqual(Dream.get(row.id)?.string("memoryId"), mem.id)
        // 梦记成的那条记忆不再当原料
        XCTAssertFalse(Dream.draw(try char(), "me_root").contains { $0.id == mem.id })
    }

    func testBlockAndShareCard() throws {
        _ = try today("trace")
        // 写进对话默认关：不进提示词，标记也不落
        var b = try ChatPrompt.build(chat: chat(), char: char(), settings: .load())
        XCTAssertFalse((b.system + b.messages.map(\.content).joined()).contains("[昨夜的梦]"))
        XCTAssertNil(Dream.shareMessage("梦到你了", chat: try chat(), char: try char(), turnId: "t1"))
        try Diary.patchChar("char_a", ["dreamInject": .string("on")])
        b = try ChatPrompt.build(chat: chat(), char: char(), settings: .load())
        let all = b.system + b.messages.map(\.content).joined()
        XCTAssertTrue(all.contains("[昨夜的梦]\nLast night ("))
        XCTAssertTrue(all.contains("The feeling it left: 怅然.\nYou remember nothing of what happened in it."))
        XCTAssertTrue(b.system.contains("[梦境：a few words of your own about it]"))
        let m = try XCTUnwrap(Dream.shareMessage("梦到你了", chat: try chat(), char: try char(), turnId: "t1"))
        XCTAssertEqual(m.kind, "dreamcard")
        XCTAssertEqual(m.content, "[梦境：梦到你了]")
        XCTAssertEqual(m.row["dreamSnap"]?["level"]?.string, "trace")
        XCTAssertEqual(SpecialCards.face(m)?.title, "昨夜的梦")
        // 解析与网页版一致
        let p = ReplyParser.split("[梦境：梦到你了]").parts
        XCTAssertEqual(p.map(\.type), [.dreamShare])
        XCTAssertEqual(WebLogic.map([["type": "dreamshare", "body": "梦到你了"]]).0, p)
    }

    func testDeleteCharacterDropsDreams() throws {
        _ = try today("full")
        try People.deleteCharacter("char_a")
        XCTAssertTrue(Dream.ofChar("char_a").isEmpty)
    }
}
