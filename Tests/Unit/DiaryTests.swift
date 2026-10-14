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
}
