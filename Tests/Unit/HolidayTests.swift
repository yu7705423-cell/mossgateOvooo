import XCTest
@testable import Eira

/// 节日表与「节日与纪念日」一段（网页版 holidays.js、context/dates.js）。期望值由网页版的代码在 node 里算出来。
final class HolidayTests: StoreTestCase {
    private func rule(_ region: String, _ id: String) throws -> Holidays.Rule {
        let r = try XCTUnwrap(Holidays.regions.first(where: { $0.id == region }))
        return try XCTUnwrap(r.list.first(where: { $0.id == id })).rule
    }

    /// 上海那一天的正午
    private func at(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    private func promptText(now: Date, _ extra: [String: JSONValue] = [:]) throws -> String {
        var fields: [String: JSONValue] = ["timeZoneUser": .string("Asia/Shanghai")]
        for (k, v) in extra { fields[k] = v }
        try setSettings(fields)
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        let b = try ChatPrompt.build(chat: chat, char: char, settings: .load(), now: now)
        return ([b.system] + b.messages.map(\.content)).joined(separator: "\n")
    }

    func testDatesMatchWeb() throws {
        XCTAssertEqual(Holidays.dateOf(try rule("intl", "valentine"), 2027), "2027-02-14")
        XCTAssertEqual(Holidays.dateOf(try rule("cn", "national"), 2026), "2026-10-01")
        // 农历
        XCTAssertEqual(Holidays.dateOf(try rule("cn", "spring"), 2027), "2027-02-07")
        XCTAssertEqual(Holidays.dateOf(try rule("cn", "spring"), 2026), "2026-02-17")
        XCTAssertEqual(Holidays.dateOf(try rule("cn", "dragon"), 2026), "2026-06-19")
        XCTAssertEqual(Holidays.dateOf(try rule("cn", "midautumn"), 2028), "2028-10-03")
        XCTAssertEqual(Holidays.dateOf(try rule("cn", "laba"), 2027), "2027-01-15")
        XCTAssertEqual(Holidays.dateOf(try rule("kr", "buddha"), 2026), "2026-05-24")
        // 除夕：正月初一的前一天
        XCTAssertEqual(Holidays.dateOf(try rule("cn", "eve"), 2027), "2027-02-06")
        XCTAssertEqual(Holidays.dateOf(try rule("cn", "eve"), 2028), "2028-01-25")
        // 清明、复活节、第几个星期几
        XCTAssertEqual(Holidays.dateOf(try rule("cn", "qingming"), 2026), "2026-04-05")
        XCTAssertEqual(Holidays.dateOf(try rule("cn", "qingming"), 2028), "2028-04-04")
        XCTAssertEqual(Holidays.dateOf(try rule("us", "easter"), 2027), "2027-03-28")
        XCTAssertEqual(Holidays.dateOf(try rule("uk", "mothering"), 2026), "2026-03-15")
        XCTAssertEqual(Holidays.dateOf(try rule("uk", "goodfriday"), 2028), "2028-04-14")
        XCTAssertEqual(Holidays.dateOf(try rule("intl", "mother"), 2026), "2026-05-10")
        XCTAssertEqual(Holidays.dateOf(try rule("intl", "father"), 2028), "2028-06-18")
        XCTAssertEqual(Holidays.dateOf(try rule("us", "thanksgiving"), 2026), "2026-11-26")
        XCTAssertEqual(Holidays.dateOf(try rule("us", "memorial"), 2027), "2027-05-31")
        XCTAssertEqual(Holidays.dateOf(try rule("jp", "seijin"), 2028), "2028-01-10")
        // 界面上的农历写法，含闰月
        XCTAssertEqual(Holidays.lunarLabel("2027-02-06"), "农历腊月三十")
        XCTAssertEqual(Holidays.lunarLabel("2025-07-25"), "农历闰六月初一")
    }

    func testCfgDefaultsAndMerge() throws {
        var s = AppSettings(raw: [:])
        XCTAssertEqual(Holidays.cfg(s).regions, ["intl", "cn"])
        // 同一天同名的几个地区并成一条
        Holidays.setRegion("kr", true, &s)
        XCTAssertEqual(Holidays.cfg(s).regions, ["intl", "cn", "kr"])
        let today = try XCTUnwrap(Holidays.Day.parse("2027-02-03"))
        XCTAssertEqual(Holidays.around(today, s).map(\.name), ["除夕（中国）"])
        let hits = Holidays.around(try XCTUnwrap(Holidays.Day.parse("2027-02-07")), s)
        XCTAssertEqual(hits.first, Holidays.Hit(name: "春节（中国、韩国）", date: "2027-02-07", left: 0))
        // 关掉一项：存成「地区.节日」
        let spring = try XCTUnwrap(Holidays.regions[1].list.first(where: { $0.id == "spring" }))
        Holidays.setItem("cn", spring, false, &s)
        XCTAssertEqual(s.raw["holidayOff"], .array([.string("cn.spring")]))
        XCTAssertEqual(Holidays.around(try XCTUnwrap(Holidays.Day.parse("2027-02-07")), s).first?.name, "春节（韩国）")
        // 自定义：无效的不写
        XCTAssertNil(Holidays.addCustom(name: " ", month: 2, day: 9, lunar: false, &s))
        XCTAssertNil(Holidays.addCustom(name: "x", month: 2, day: 31, lunar: true, &s))
        let c = try XCTUnwrap(Holidays.addCustom(name: "社团成立日", month: 2, day: 9, lunar: false, &s))
        XCTAssertEqual(Holidays.cfg(s).custom.map(\.name), ["社团成立日"])
        Holidays.removeCustom(c.id, &s)
        XCTAssertTrue(Holidays.cfg(s).custom.isEmpty)
    }

    func testBlockOnTheDay() throws {
        let text = try promptText(now: at(2027, 2, 7))
        XCTAssertTrue(text.contains("[节日与纪念日]\nToday is 春节（中国）."), text)
    }

    func testBlockFollowingDaysAndCustom() throws {
        let custom: JSONValue = .array([.object(["id": .string("hd_x"), "name": .string("社团成立日"), "month": .number(2),
                                                 "day": .number(9), "lunar": .bool(false)])])
        let text = try promptText(now: at(2027, 2, 4), ["holidayCustom": custom])
        XCTAssertTrue(text.contains("[节日与纪念日]\n除夕（中国） is in 2 days, on 2027-02-06.\n春节（中国） is in 3 days, on 2027-02-07."), text)
        let later = try promptText(now: at(2027, 2, 7), ["holidayCustom": custom])
        XCTAssertTrue(later.contains("社团成立日 is in 2 days, on 2027-02-09."), later)
    }

    func testRegionOffMeansNoBlock() throws {
        XCTAssertFalse(try promptText(now: at(2027, 2, 7), ["holidayRegions": .array([.string("intl")])]).contains("[节日与纪念日]"))
    }

    func testItemOffMeansNoBlock() throws {
        XCTAssertFalse(try promptText(now: at(2027, 2, 7), ["holidayOff": .array([.string("cn.spring")])]).contains("[节日与纪念日]"))
    }

    func testTimeOffMeansNoBlock() throws {
        XCTAssertFalse(try promptText(now: at(2027, 2, 7), ["injectTime": .bool(false)]).contains("[节日与纪念日]"))
    }

    /// 第一条消息在 2025-10-09：一周年的前一天写「明天」；角色生日从角色卡读
    func testAnniversaryAndBirthday() throws {
        var c = try XCTUnwrap(Repo.character("char_a"))
        c.row["birthday"] = .string("10月10日")
        try Database.shared.put(Collections.characters, c.row)
        let text = try promptText(now: at(2026, 10, 8), ["holidayRegions": .array([])])
        XCTAssertTrue(text.contains("[节日与纪念日]\nTomorrow is the 1st anniversary of your first message with 小于.\nYour birthday is in 2 days, on 2026-10-10."), text)
    }
}
