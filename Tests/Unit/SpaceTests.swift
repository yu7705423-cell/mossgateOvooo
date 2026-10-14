import XCTest
@testable import Eira

/// 情侣空间：在一起的天数、纪念日倒计时、约定（角色写标记、认领完成、删提示退回）、信（拆信日期、定时寄出）、上下文默认不注入
final class SpaceTests: StoreTestCase {
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

    private var chat: Chat { get throws { try XCTUnwrap(Repo.chat("chat_a")) } }

    func testTogetherDaysAndAnniversary() throws {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -9, to: now)!
        try Space.setStart("chat_a", Calendar.current.startOfDay(for: start).millis)
        XCTAssertEqual(Space.togetherDays(try chat, now: now), 10)
        let soon = Calendar.current.date(byAdding: .day, value: 5, to: now)!
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        try Space.addDay(chatId: "chat_a", title: "认识的日子", date: f.string(from: soon), yearly: true)
        XCTAssertEqual(Space.upcoming("chat_a", now: now).first?.left, 5)
        XCTAssertThrowsError(try Space.addDay(chatId: "chat_a", title: " ", date: "2026-01-01", yearly: true))
        // 默认不注入
        XCTAssertEqual(Space.block(try chat, now: now), "")
        try Space.setInject("chat_a", true)
        let b = Space.block(try chat, now: now)
        XCTAssertTrue(b.contains("[你们之间]"))
        XCTAssertTrue(b.contains("day 10"))
        XCTAssertTrue(b.contains("认识的日子 is 5 days away"))
    }

    func testPactMarkersFromReply() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("好\n[约定：下个月一起去看海]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let p = try XCTUnwrap(Space.pacts("chat_a").last)
        XCTAssertEqual(p.row.string("title"), "下个月一起去看海")
        XCTAssertEqual(p.row.string("pact"), Space.pactOpen)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("去过了\n[约定完成：一起去看海]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(Space.pacts("chat_a").last?.row.string("pact"), Space.pactDone)
        let notice = try XCTUnwrap(Repo.messages(chatId: "chat_a").last { $0.row.string("settledKind") == "pact" })
        try Interact.drop(notice)
        XCTAssertEqual(Space.pacts("chat_a").last?.row.string("pact"), Space.pactOpen)
        // 认不出的完成不动
        XCTAssertNil(Space.findOpenPact("chat_a", "完全无关"))
    }

    func testLetterFromReplyAndSealed() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("[信：给你｜LETTER_BODY]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let l = try XCTUnwrap(Space.records("chat_a", "letter").last)
        XCTAssertEqual(l.row.string("title"), "给你")
        XCTAssertEqual(l.row.string("body"), "LETTER_BODY")
        // 我寄的封到下周：角色读到的只有信封
        let next = Date().addingTimeInterval(86_400 * 7)
        try Space.sendLetter(chatId: "chat_a", title: "未来", body: "SECRET_BODY", openAt: Space.openAt(of: next))
        let built = try ChatPrompt.build(chat: try chat, char: try XCTUnwrap(Repo.character("char_a")), settings: AppSettings.load())
        let all = built.messages.map(\.content).joined(separator: "\n")
        XCTAssertFalse(all.contains("SECRET_BODY"))
        XCTAssertTrue(all.contains("sealed until"))
    }

    func testTimedDraftDelivers() throws {
        let past = Date().millis - 60_000
        try Space.saveDraft(chatId: "chat_a", title: "定时", body: "TIMED", sendAt: past)
        try Space.saveDraft(chatId: "chat_a", title: "留着", body: "KEEP")
        XCTAssertEqual(Space.deliverDue(), 1)
        XCTAssertEqual(Space.drafts("chat_a").map { $0.string("title") }, ["留着"])
        let sent = try XCTUnwrap(Space.records("chat_a", "letter").last)
        XCTAssertEqual(sent.row.string("body"), "TIMED")
        XCTAssertEqual(sent.createdAt, past, accuracy: 1)
    }
}
