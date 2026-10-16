import XCTest
@testable import Eira

/// 日记：写作过程推出正文；角色写一次一个请求、可以选择不写；每天自动的那一次失败当天不再试；
/// 公开给角色看的进提示词，仅自己的不进。
final class DiaryTests: StoreTestCase {
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

    private func reply(_ json: String) -> MockNet.Reply { .init(status: 200, body: MockNet.anthropicStream(json)) }

    func testParseProcess() {
        let p = Diary.parseProcess("今天~~很累~~还好||\n\n\n\n明天见")
        XCTAssertEqual(p.text, "今天还好\n\n明天见")
        XCTAssertEqual(p.edits, 1)
        XCTAssertTrue(p.steps.contains { $0.pause })
    }

    func testDailyClaim() {
        XCTAssertTrue(Daily.claim("diary", "c1", "2026-10-14"))
        XCTAssertFalse(Daily.claim("diary", "c1", "2026-10-14"))
        XCTAssertTrue(Daily.claim("diary", "c2", "2026-10-14"))
        XCTAssertTrue(Daily.claim("diary", "c1", "2026-10-15"))
    }

    func testWriteOnceWithLock() async throws {
        MockNet.reset { _, _ in self.reply(#"{"write":"short","title":"雨","mood":"low","process":"下雨了~~，烦~~。","lock":"0614"}"#) }
        let out = try await Diary.write(charId: "char_a")
        XCTAssertEqual(MockNet.count, 1)
        guard case .wrote(let id) = out else { return XCTFail("应当写了一篇") }
        let e = Diary.Entry(row: try XCTUnwrap(Database.shared.get("diaries", id: id)))
        XCTAssertEqual(e.text, "下雨了。")
        XCTAssertEqual(e.kind, "short")
        XCTAssertTrue(e.locked)
        XCTAssertFalse(try Diary.tryOpen(id, "1111"))
        XCTAssertTrue(try Diary.tryOpen(id, "0614"))
        let opened = Diary.Entry(row: try XCTUnwrap(Database.shared.get("diaries", id: id)))
        XCTAssertFalse(opened.locked)
        XCTAssertEqual(opened.lock?["tries"]?.number, 2)
    }

    func testChooseNotToWrite() async throws {
        MockNet.reset { _, _ in self.reply(#"{"write":"none"}"#) }
        let out = try await Diary.write(charId: "char_a")
        XCTAssertEqual(out, .skipped)
        XCTAssertTrue(try Diary.ofChar("char_a").isEmpty)
    }

    /// 每天自动那一次：接口一直失败，当天只打一次；原因记在角色身上。
    func testAutoFailingOncePerDay() async throws {
        try Diary.patchChar("char_a", ["diaryAuto": .bool(true), "diaryHour": .number(0)])
        XCTAssertTrue(ExtraCalls.switchedOn(.load()).contains { $0.id == "diaryAuto" })
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let first = await Diary.ensureToday("char_a", now: noon)
        let second = await Diary.ensureToday("char_a", now: noon)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertFalse(try XCTUnwrap(Repo.character("char_a")).row.string("diaryAutoError").isEmpty)
        // 关了又开，当天也不再自动
        try Diary.patchChar("char_a", ["diaryAuto": .bool(false), "diaryAutoAt": .string("")])
        try Diary.patchChar("char_a", ["diaryAuto": .bool(true)])
        let third = await Diary.ensureToday("char_a", now: noon)
        XCTAssertFalse(third)
        XCTAssertEqual(MockNet.count, 1)
    }

    func testOffByDefault() async throws {
        let ran = await Diary.ensureToday("char_a")
        XCTAssertFalse(ran)
        XCTAssertFalse(ExtraCalls.switchedOn(.load()).contains { $0.id == "diaryAuto" })
    }

    /// 公开的进提示词，仅自己的不进。
    func testBlockInPrompt() throws {
        XCTAssertThrowsError(try Diary.saveMine(date: Diary.todayMine(), title: "", text: "  ", visibility: "public", charId: ""))
        try Diary.saveMine(date: Diary.todayMine(), title: "", text: "PUBLIC_ENTRY", visibility: "public", charId: "")
        try Diary.saveMine(date: Diary.todayMine(), title: "", text: "SELF_ENTRY", visibility: "self", charId: "")
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let b = try ChatPrompt.build(chat: chat, char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        let all = b.system + b.messages.map(\.content).joined()
        XCTAssertTrue(all.contains("[日记]"))
        XCTAssertTrue(all.contains("PUBLIC_ENTRY"))
        XCTAssertFalse(all.contains("SELF_ENTRY"))
    }

    func testDeleteCharacterDropsDiaries() async throws {
        MockNet.reset { _, _ in self.reply(#"{"write":"full","process":"写一点"}"#) }
        _ = try await Diary.write(charId: "char_a")
        try Diary.saveMine(date: Diary.todayMine(), title: "", text: "给你看", visibility: "public", charId: "char_a")
        try People.deleteCharacter("char_a")
        XCTAssertTrue(try Database.shared.all("diaries", where: "char_a").isEmpty)
        XCTAssertEqual(try Diary.mine().first?.charId, "")
    }

    /// 日历：心情读健康 app（我的写进去也写到那里），角色没有时读它那天日记里的；格子数日记；当天时间线与往年的今天
    func testCalendarMoodTimeline() throws {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let chatDay = f.string(from: Date(millis: 1_760_000_002_000))
        try Diary.saveMine(date: chatDay, title: "那天", text: "写了一点", visibility: "self", charId: "")
        try Database.shared.put("diaries", Row.new(prefix: "dy", ["owner": .string("char_a"), "date": .string(chatDay),
                                                                 "text": .string("角色的"), "mood": .string("low"), "personaId": .string("me_root")]))
        try Diary.setMyMood(chatDay, "good")
        XCTAssertEqual(Health.day(Diary.me, chatDay).mood, "good")
        XCTAssertEqual(Diary.moodOn("char_a", chatDay), "low")

        let p = chatDay.split(separator: "-").compactMap { Int($0) }
        let cells = Diary.month(p[0], p[1], charId: "char_a")
        XCTAssertEqual(cells[chatDay]?.me, "good")
        XCTAssertEqual(cells[chatDay]?.char, "low")
        XCTAssertEqual(cells[chatDay]?.mine, 1)
        XCTAssertEqual(cells[chatDay]?.theirs, 1)
        XCTAssertEqual(Diary.on(chatDay, charId: "char_a").count, 2)
        XCTAssertTrue(Diary.charChoices().contains { $0.id == "char_a" })

        let tl = Diary.timeline(chatDay, charId: "char_a")
        XCTAssertEqual(tl.filter { $0.type == "diary" }.count, 2)
        let chat = try XCTUnwrap(tl.first { $0.type == "chat" })
        XCTAssertEqual(chat.count, 3)
        XCTAssertEqual(chat.last, "[图片]")

        // 往年的今天：一年后的同一天读得到这两篇
        let next = "\(p[0] + 1)" + chatDay.dropFirst(4)
        XCTAssertEqual(Diary.pastYears(next, charId: "char_a").count, 2)
        XCTAssertTrue(Diary.pastYears(next, charId: "char_b").allSatisfy(\.mine))
    }

    /// 日记插图：存下图片 id；编辑时不传就不动，传了就换
    func testDiaryImages() throws {
        let e = try Diary.saveMine(date: "2026-10-15", title: "", text: "带图", visibility: "self", charId: "", imageIds: ["img_a", ""])
        XCTAssertEqual(e.imageIds, ["img_a"])
        let e2 = try Diary.saveMine(id: e.id, date: "2026-10-15", title: "", text: "改字", visibility: "self", charId: "")
        XCTAssertEqual(e2.imageIds, ["img_a"])
        let e3 = try Diary.saveMine(id: e.id, date: "2026-10-15", title: "", text: "改字", visibility: "self", charId: "", imageIds: [])
        XCTAssertEqual(e3.imageIds, [])
    }

    /// 交给模型的那一天带上当天的日程与身体状态；当天的对话按「上下文与记忆」里的历史窗口取，按轮数时也按轮数（网页版 dayContext、recentWindow）
    func testDayContextScheduleBodyAndTurns() throws {
        let c = try XCTUnwrap(Repo.character("char_a"))
        let date = Diary.todayOf(c)
        try DayPlan.save("char_a", date: date, [
            "items": .array([
                .object(["id": .string("it1"), "slot": .string("morning"), "text": .string("去图书馆"), "state": .string(DayPlan.plan)]),
                .object(["id": .string("it2"), "slot": .string("noon"), "text": .string("取消的事"), "state": .string(DayPlan.drop)]),
            ]),
            "event": .object(["text": .string("捡到一把伞"), "slot": .string("morning")]),
        ])
        try Health.set("char_a", date, ["mood": .string("low"), "energy": .string("high"), "note": .string("有点累")])
        for (role, text) in [(Message.Role.user, "第一轮问"), (.char, "第一轮答"), (.user, "第二轮问"), (.char, "第二轮答")] {
            _ = try Repo.append(Message.new(chatId: "chat_a", role: role, authorId: role == .user ? "me" : "char_a", content: text))
        }
        var ctx = try Diary.context(c, date: date, pid: "me_root")
        XCTAssertTrue(ctx.contains("### 林's schedule today\n早上: 去图书馆\nEvent: 捡到一把伞"))
        XCTAssertFalse(ctx.contains("取消的事"))
        XCTAssertTrue(ctx.contains("### 林's body today\nmood: 低落\nenergy: 精神\n有点累"))
        XCTAssertTrue(ctx.contains("第一轮问"))
        XCTAssertTrue(ctx.contains("第二轮答"))
        try setSettings(["historyMode": .string("turn"), "historyTurns": .number(1)])
        ctx = try Diary.context(c, date: date, pid: "me_root")
        XCTAssertFalse(ctx.contains("第一轮问"))
        XCTAssertFalse(ctx.contains("第一轮答"))
        XCTAssertTrue(ctx.contains("第二轮问"))
        XCTAssertTrue(ctx.contains("第二轮答"))
    }
}
