import XCTest
@testable import Eira

/// 互动标识：连续互发按本地日期算、增量同步不重复数、成就、让角色知道默认关。不调接口。
final class BadgesTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
        // 清掉夹具里的消息，从干净的一段开始数
        for m in try Repo.messages(chatId: "chat_a") { try Database.shared.delete(Collections.messages, id: m.id) }
    }

    private func put(_ role: Message.Role, _ text: String, _ at: Date, kind: String = "text", extra: [String: JSONValue] = [:]) throws {
        var m = Message.new(chatId: "chat_a", role: role, authorId: role == .user ? "me" : "char_a", content: text, kind: kind)
        m.row["createdAt"] = .number(at.millis)
        for (k, v) in extra { m.row[k] = v }
        try Repo.save(m)
    }

    func testStreakAndIncremental() throws {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let d1 = cal.date(byAdding: .day, value: -2, to: today)!, d2 = cal.date(byAdding: .day, value: -1, to: today)!
        for d in [d1, d2, today] {
            try put(.user, "在吗", d)
            try put(.char, "在", d.addingTimeInterval(60))
        }
        try put(.user, "[转账]", today.addingTimeInterval(120), kind: "transfer", extra: ["amount": .number(520)])
        try Badges.sync("chat_a", now: today.addingTimeInterval(200))
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        let s = Badges.streak(chat, now: today.addingTimeInterval(300))
        XCTAssertEqual(s.state, "lit")
        XCTAssertEqual(s.n, 3)
        XCTAssertEqual(s.form?.name, "火苗")
        XCTAssertNotNil(chat.row["unlocked"]?["520"])
        XCTAssertNotNil(chat.row["unlocked"]?["streak-3"])
        // 再同步一次：没有新消息，不重复数
        try Badges.sync("chat_a", now: today.addingTimeInterval(400))
        chat = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertEqual(chat.row["stats"]?["n"]?.number, 7)
        // 明天还没互发：快断了
        XCTAssertEqual(Badges.streak(chat, now: cal.date(byAdding: .day, value: 1, to: today)!).state, "risk")
    }

    func testAwareOffByDefault() throws {
        try put(.user, "在吗", Date())
        try put(.char, "在", Date().addingTimeInterval(1))
        try Badges.sync("chat_a")
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertEqual(Badges.block(chat, msgs: []), "")
        chat.row["badgeAware"] = .bool(true)
        XCTAssertTrue(Badges.block(chat, msgs: []).contains("[互动标识]"))
    }

    func testRemindPlan() throws {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        for k in 1...3 {
            let d = cal.date(byAdding: .day, value: -k, to: today)!
            try put(.user, "在吗", d)
            try put(.char, "在", d.addingTimeInterval(60))
        }
        try Badges.sync("chat_a", now: today)
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        // 今天还没互发：排今天 21 点
        let plan = try XCTUnwrap(Badges.remindPlan(chat, now: today))
        XCTAssertEqual(cal.component(.hour, from: plan.at), 21)
        XCTAssertTrue(cal.isDate(plan.at, inSameDayAs: today))
        XCTAssertEqual(plan.n, 3)
        // 关了提醒就不排
        chat.row["badgeRemind"] = .bool(false)
        XCTAssertNil(Badges.remindPlan(chat, now: today))
    }

    func testYearAndAwards() throws {
        let cal = Calendar.current
        let y = cal.component(.year, from: Date())
        let d = cal.date(from: DateComponents(year: y, month: 3, day: 2, hour: 23))!
        try put(.user, "今天下雨了，下雨天想吃火锅", d)
        try put(.char, "火锅可以", d.addingTimeInterval(60))
        try put(.user, "火锅", d.addingTimeInterval(86400))
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let yr = Badges.yearOf(chat, msgs: try Repo.messages(chatId: "chat_a"), year: y)
        XCTAssertEqual(yr.n, 3)
        XCTAssertEqual(yr.nU, 2)
        XCTAssertEqual(yr.activeDays, 2)
        XCTAssertEqual(yr.bothDays, 1)
        XCTAssertEqual(yr.bestStreak, 1)
        XCTAssertEqual(yr.busiest?.n, 2)
        XCTAssertEqual(yr.words.first?.w, "火锅")

        // 角色在回复里颁发：落一条、记进收藏；删掉那一条，标识一并收回
        XCTAssertEqual(ReplyParser.split("[授予：最会点菜的人｜连续三次没点错]").parts.first?.type, .award)
        let m = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "[授予：最会点菜的人]", kind: "award")
        try Repo.save(m)
        let a = try XCTUnwrap(Badges.addAward("chat_a", name: "最会点菜的人", reason: "连续三次没点错", by: "char_a", to: "me", msgId: m.id))
        XCTAssertEqual(Badges.awards(try Repo.chat("chat_a")).map(\.name), ["最会点菜的人"])
        try Interact.drop(m)
        XCTAssertTrue(Badges.awards(try Repo.chat("chat_a")).isEmpty)
        XCTAssertFalse(a.id.isEmpty)
    }
}
