import XCTest
@testable import Eira

/// 我的日程（网页版 usersched.js）：时刻与周几的认法、整理规则、单双周、哪天有什么、写给角色的那一段与不给看的角色
final class UserSchedTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
        try setSettings(["timeZoneUser": .string("Asia/Shanghai")])
    }

    func testTimeParsing() {
        XCTAssertEqual(UserSched.hm("8:5"), "08:05")
        XCTAssertEqual(UserSched.hm("8点05"), "08:05")
        XCTAssertEqual(UserSched.hm("0805"), "08:05")
        XCTAssertEqual(UserSched.hm("9"), "09:00")
        XCTAssertEqual(UserSched.hm("25:00"), "")
        XCTAssertEqual(UserSched.hm("24:30"), "")
    }

    func testNormalize() {
        XCTAssertNil(UserSched.normalize(["title": .string("课"), "start": .string("8:00")]))   // 没有周几也没有日期
        let c = UserSched.normalize(["kind": .string("commute"), "origin": .string("家"), "dest": .string("公司"),
                                     "start": .string("8:30"), "mins": .number(40), "weekday": .number(1)])
        XCTAssertEqual(c?["title"]?.string, "家 到 公司")
        XCTAssertEqual(c?["end"]?.string, "09:10")
        let once = UserSched.normalize(["title": .string("面试"), "start": .string("14:00"), "end": .string("13:00"), "date": .string("2026-10-20")])
        XCTAssertEqual(once?["repeat"]?.string, UserSched.once)
        XCTAssertEqual(once?["end"]?.string, "")
    }

    func testOccursAndWeeks() throws {
        // 2026-10-12 是周一
        XCTAssertEqual(UserSched.weekdayOfKey("2026-10-12"), 1)
        XCTAssertEqual(UserSched.weekdayOfKey("2026-10-18"), 7)
        let owner = UserSched.ownerOf("")
        try UserSched.create(owner, ["title": .string("高数"), "start": .string("8:00"), "end": .string("9:40"), "weekday": .number(1),
                                     "weeks": .string("odd"), "from": .string("2026-09-07"), "kind": .string("class")])
        // 9 月 7 日那一周是第一周：10 月 12 日是第六周，双周不上
        XCTAssertEqual(UserSched.weekNo("2026-10-12", from: "2026-09-07"), 6)
        XCTAssertTrue(UserSched.itemsOn(owner, "2026-10-12").isEmpty)
        XCTAssertEqual(UserSched.itemsOn(owner, "2026-10-19").map(\.title), ["高数"])
    }

    func testBlockAndHidden() throws {
        let owner = UserSched.ownerOf("")
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        try UserSched.create(owner, ["title": .string("上班"), "start": .string("9:00"), "end": .string("18:00"), "date": .string(today),
                                     "kind": .string("work"), "place": .string("公司")])
        let char = try XCTUnwrap(Repo.character("char_a"))
        var s = AppSettings.load()
        let b = UserSched.block(char: char, personaId: "me_root", userName: "小于", settings: s)
        XCTAssertTrue(b.hasPrefix("[对方的日程]"))
        XCTAssertTrue(b.contains("Work: 上班 (公司)"))
        XCTAssertTrue(b.contains("Yesterday"))
        // 进提示词
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        // 每轮都变的那几块排在「此刻的状态」，默认贴着聊天记录末尾：系统段与消息里都找
        let built = try ChatPrompt.build(chat: chat, char: char, settings: s)
        XCTAssertTrue((built.system + built.messages.map(\.content).joined()).contains("[对方的日程]"))
        // 不给这个角色看
        UserSched.setVisible("char_a", false, &s)
        XCTAssertEqual(UserSched.block(char: char, personaId: "me_root", userName: "小于", settings: s), "")
        // 排日程时参考：默认关
        XCTAssertEqual(UserSched.forDayPlan(char, personaId: "me_root", settings: AppSettings.load()), "")
    }
}
