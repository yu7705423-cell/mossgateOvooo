import XCTest
@testable import Eira

/// 主屏最后一批小组件（HomeWidgetsMore2.swift）里纯算的那几样：登记、编辑页的选项、对话取哪几条、在一起的天数、
/// 月历与 Love 日历的格子、时差旋钮的文字与分组、健康读数、自己填时的假计数。只算数据，不画界面。
final class HomeWidgetsMore2Tests: StoreTestCase {
    private typealias C = MoreWidgets.Calc

    private static let ids = [
        "ins-profile", "dw-moon", "dw-record", "dw-cal", "dw-pile", "dw-time", "ins-days", "dw-arch",
        "mm-post", "mm-gram", "mm-talk", "mm-diary",
        "ins-polaroid", "ins-film", "ins-stories", "ins-grid", "ins-weather",
        "zone-dial", "health", "album", "love",
    ]

    private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi)) ?? Date()
    }

    private func msg(_ id: String, _ role: Message.Role, _ content: String, at: Double, kind: String = "text") -> Message {
        var m = Message.new(chatId: "chat_x", role: role, authorId: role == .user ? "me" : "char_a", content: content, kind: kind)
        m.row["id"] = .string(id)
        m.row["createdAt"] = .number(at)
        return m
    }

    private func char(_ id: String, zone: String = "", npc: Bool = false, parent: String = "") -> Character {
        var f: [String: JSONValue] = ["id": .string(id), "name": .string(id)]
        if !zone.isEmpty { f["timezone"] = .string(zone) }
        if npc { f["isNpc"] = .bool(true) }
        if !parent.isEmpty { f["parentId"] = .string(parent) }
        return Character(row: Row(fields: f))
    }

    // MARK: - 登记

    /// 每一个都登记了、主屏认得、编辑页列得出
    func testAllRegistered() throws {
        for id in Self.ids {
            XCTAssertTrue(MoreWidgets.has(id), id)
            XCTAssertNotNil(MoreWidgets.all.first(where: { $0.id == id }), id)
            XCTAssertNotNil(HomeWidgets.def(id), id)
            XCTAssertFalse((MoreWidgets.all.first(where: { $0.id == id })?.sizes ?? []).isEmpty, id)
        }
        // 自定义组件（用户贴的 HTML）关在盒子里画，见 CustomWidget.swift
        XCTAssertTrue(MoreWidgets.has("custom"))
        XCTAssertEqual(HomeWidgets.def("custom")?.editable, true)
        let all = MoreWidgets.all.map { $0.id }
        XCTAssertEqual(Set(all).count, all.count, "id 不重复")
        // 没有可填项的两块不进编辑页
        XCTAssertEqual(HomeWidgets.def("ins-stories")?.editable, false)
        XCTAssertEqual(HomeWidgets.def("album")?.editable, false)
        XCTAssertEqual(HomeWidgets.def("love")?.editable, true)
        // 网页版 frameless 的自己画卡，其余垫主屏的卡
        XCTAssertEqual(MoreWidgets.all.first(where: { $0.id == "mm-post" })?.framed, false)
        XCTAssertEqual(MoreWidgets.all.first(where: { $0.id == "health" })?.framed, true)
    }

    /// 选项写在 placeholder 里：第一个是默认，带 * 的是多选默认选上的；when 只在那一项是这个值时显示
    func testChoicesAndWhen() throws {
        let style = MoreWidgets.choices(":ins|x:X")
        XCTAssertEqual(style.map { $0.value }, ["", "x"])
        XCTAssertEqual(style.map { $0.label }, ["ins", "X"])
        let show = MoreWidgets.choices("*sleep:睡眠|*steps:步数|weight:体重")
        XCTAssertEqual(show.filter { $0.on }.map { $0.value }, ["sleep", "steps"])

        let profile = try XCTUnwrap(MoreWidgets.all.first(where: { $0.id == "ins-profile" }))
        let banner = try XCTUnwrap(profile.fields.first(where: { $0.key == "banner" }))
        XCTAssertFalse(MoreWidgets.shows(banner, [:], defaults: profile.fields), "默认是 ins 样式，不显示横幅")
        XCTAssertTrue(MoreWidgets.shows(banner, ["style": "x"], defaults: profile.fields))
        let charField = try XCTUnwrap(profile.fields.first(where: { $0.key == "charId" }))
        XCTAssertTrue(MoreWidgets.shows(charField, [:], defaults: profile.fields))

        // 健康默认不含体重
        let health = try XCTUnwrap(MoreWidgets.all.first(where: { $0.id == "health" })?.fields.first)
        XCTAssertEqual(MoreWidgets.choices(health.placeholder).filter { $0.on }.map { $0.value }, C.healthDefault)
        XCTAssertFalse(C.healthDefault.contains("weight"))
    }

    // MARK: - 对话（mm-talk）

    /// 导入的记录：图片标记那一条跳过；出错的、撤回的也不要；取最后几条
    func testTalkLines() throws {
        try importFixture("data.json")
        let real = try Repo.messages(chatId: "chat_a")
        XCTAssertEqual(C.talkLines(real, 5).map { $0.content }, ["你好", "在呢"])
        XCTAssertEqual(C.talkLines(real, 1).map { $0.content }, ["在呢"])

        let now = Date()
        let base = now.timeIntervalSince1970 * 1000 - 600_000
        var failed = msg("m2", .char, "出错的一条", at: base + 2)
        failed.row["status"] = .string("error")
        var gone = msg("m3", .char, "撤回的一条", at: base + 3)
        gone.row["recalled"] = .object(["at": .number(base + 10), "by": .string("char_a")])
        var later = msg("m4", .char, "过一会儿才撤回", at: base + 4)
        later.row["recalled"] = .object(["at": .number(now.timeIntervalSince1970 * 1000 + 600_000), "by": .string("char_a")])
        let list = [
            msg("m1", .user, "第一句", at: base + 1), failed, gone, later,
            msg("m5", .user, "[图片：一张照片]", at: base + 5, kind: "text"),
            msg("m6", .char, "一张图", at: base + 6, kind: "image"),
            msg("m7", .user, "", at: base + 7),
            msg("m8", .user, "最后一句", at: base + 8),
        ]
        XCTAssertEqual(C.talkLines(list, 5, now: now).map { $0.id }, ["m1", "m4", "m8"], "还没到撤回时刻的照常显示")
        XCTAssertEqual(C.talkLines(list, 2, now: now).map { $0.id }, ["m4", "m8"])
        XCTAssertEqual(C.talkLines(list, 0, now: now).count, 0)

        XCTAssertEqual(C.talkCount(w: 4, h: 3), 5)
        XCTAssertEqual(C.talkCount(w: 4, h: 2), 3)
        XCTAssertEqual(C.talkCount(w: 2, h: 2), 2)
    }

    // MARK: - 对望（ins-days）

    /// 开始那天算第一天；自己填了日期按填的，填得认不出就按对话建立的那天，都没有是 0
    func testDaysTogether() throws {
        try importFixture("data.json")
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let created = try XCTUnwrap(chat.row.created)
        XCTAssertEqual(C.start(since: "", chatCreated: created), created)
        XCTAssertEqual(C.daysFrom(created, now: Date(millis: created + 1000)), 1)
        XCTAssertEqual(C.daysFrom(created, now: Date(millis: created + 3 * C.dayMs + 1000)), 4)

        let since = try XCTUnwrap(C.start(since: "2026-10-01", chatCreated: created))
        XCTAssertEqual(since, local(2026, 10, 1, 0, 0).timeIntervalSince1970 * 1000)
        XCTAssertEqual(C.daysFrom(since, now: local(2026, 10, 1, 8)), 1)
        XCTAssertEqual(C.daysFrom(since, now: local(2026, 10, 16, 8)), 16)

        XCTAssertEqual(C.start(since: "不是日期", chatCreated: created), created)
        XCTAssertNil(C.start(since: "", chatCreated: nil))
        XCTAssertEqual(C.daysFrom(nil), 0)
        XCTAssertNil(C.localDay("2026-13-01"))
    }

    // MARK: - 月历（dw-cal）与 Love 日历

    /// 2026 年 10 月 1 日是星期四：前面补四天九月，共五行，今天那一格标出来
    func testMonthGrid() {
        let g = C.monthGrid(local(2026, 10, 16))
        XCTAssertEqual(g.rows, 5)
        XCTAssertEqual(g.cells.count, 35)
        XCTAssertEqual(g.cells[0], C.CalDay(n: 27, out: true, today: false))
        XCTAssertEqual(g.cells[3], C.CalDay(n: 30, out: true, today: false))
        XCTAssertEqual(g.cells[4], C.CalDay(n: 1, out: false, today: false))
        XCTAssertEqual(g.cells[19], C.CalDay(n: 16, out: false, today: true))
        XCTAssertEqual(g.cells[34], C.CalDay(n: 31, out: false, today: false))
        XCTAssertEqual(g.cells.filter { $0.today }.count, 1)

        // 2026 年 2 月从星期日开始、正好四行；2026 年 8 月要六行
        let feb = C.monthGrid(local(2026, 2, 15))
        XCTAssertEqual(feb.rows, 4)
        XCTAssertEqual(feb.cells[0], C.CalDay(n: 1, out: false, today: false))
        XCTAssertEqual(C.monthGrid(local(2026, 8, 3)).rows, 6)
    }

    /// 小号只铺本周与下周；跨月时下个月的日子标出来。大号铺整月，前面空着
    func testLoveDays() {
        let small = C.loveDays(local(2026, 10, 16), compact: true)
        XCTAssertEqual(small.rows, 2)
        XCTAssertEqual(small.cells.compactMap { $0?.n }, Array(11...24))
        XCTAssertEqual(small.cells[5]?.today, true)

        let edge = C.loveDays(local(2026, 10, 28), compact: true)
        XCTAssertEqual(edge.cells[0]?.n, 25)
        XCTAssertEqual(edge.cells[7], C.CalDay(n: 1, out: true, today: false))
        XCTAssertEqual(edge.cells[3]?.today, true)

        let big = C.loveDays(local(2026, 10, 16), compact: false)
        XCTAssertEqual(big.rows, 5)
        XCTAssertEqual(big.cells.count, 35)
        XCTAssertNil(big.cells[3] ?? nil)
        XCTAssertEqual(big.cells[4]?.n, 1)
        XCTAssertEqual(big.cells[19]?.today, true)
        XCTAssertEqual(big.cells[34]?.n, 31)
        // 2026 年 8 月：前面空六格，后面补到六行
        let aug = C.loveDays(local(2026, 8, 3), compact: false)
        XCTAssertEqual(aug.rows, 6)
        XCTAssertNil(aug.cells[5] ?? nil)
        XCTAssertEqual(aug.cells[6]?.n, 1)
        XCTAssertNil(aug.cells[41] ?? nil)
    }

    // MARK: - 时差旋钮（zone-dial）

    func testZoneWords() {
        XCTAssertEqual(C.diffWord(0), "")
        XCTAssertEqual(C.diffWord(60), "快 1 小时")
        XCTAssertEqual(C.diffWord(-420), "慢 7 小时")
        XCTAssertEqual(C.diffWord(210), "快 3 小时30 分")
        XCTAssertEqual(C.diffWord(-30), "慢 30 分")
        XCTAssertEqual(C.dayWord(1), "次日")
        XCTAssertEqual(C.dayWord(-1), "前一日")
        XCTAssertEqual(C.dayWord(0), "")

        XCTAssertEqual(C.dialOffset(0), "现在")
        XCTAssertEqual(C.dialOffset(90), "+1:30")
        XCTAssertEqual(C.dialOffset(-45), "-0:45")
        XCTAssertEqual(C.dialMinute(base: 30, value: -60), 1410)
        XCTAssertEqual(C.dialMinute(base: 1400, value: 60), 20)
        XCTAssertEqual(C.minutes(fromDegrees: 7.5), 30)
        XCTAssertEqual(C.minutes(fromDegrees: -360), -1440)
        XCTAssertEqual(C.minutes(fromDegrees: 1), 0)

        XCTAssertEqual(C.shortZone("Asia/Tokyo"), "东京")
        XCTAssertEqual(C.shortZone("Asia/Shanghai"), "北京")
        XCTAssertEqual(C.shortZone("Asia/Hong_Kong"), "中国香港")
        XCTAssertEqual(C.shortZone("America/Argentina/Buenos_Aires"), "Buenos Aires")
    }

    /// 同一时刻钟面相同的放一行：没设时区的跟本人一行，首尔与东京一行；本人在最前，其余按时差排
    func testZoneRows() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let at = utc.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 15, minute: 30)) ?? Date()
        let s = AppSettings(raw: ["timeZoneUser": .string("Asia/Shanghai")])
        let chars = [char("a", zone: "Asia/Tokyo"), char("b", zone: "Europe/London"), char("c"), char("d", zone: "Asia/Seoul")]
        let rows = C.zoneRows(at: at, chars: chars, settings: s)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { $0.me }, [true, false, false])
        XCTAssertEqual(rows[0].chars.map { $0.id }, ["c"])
        XCTAssertEqual(rows[0].time, "23:30")
        XCTAssertTrue(rows[0].night)
        XCTAssertEqual(rows[1].zone, "Europe/London")
        XCTAssertEqual(rows[1].time, "16:30")
        XCTAssertEqual(rows[1].diff, -420)
        XCTAssertEqual(rows[1].day, 0)
        XCTAssertFalse(rows[1].night)
        XCTAssertEqual(rows[2].place, "东京")
        XCTAssertEqual(rows[2].chars.map { $0.id }, ["a", "d"])
        XCTAssertEqual(rows[2].time, "00:30")
        XCTAssertEqual(rows[2].day, 1)
        XCTAssertEqual(rows[2].diff, 60)
    }

    /// 不挑就是全部（不含 NPC 与分身）；挑了按挑的顺序，挑到 NPC 也不算
    func testPickChars() {
        let all = [char("a"), char("n", npc: true), char("s", parent: "a"), char("b")]
        XCTAssertEqual(C.pickChars([], all: all).map { $0.id }, ["a", "b"])
        XCTAssertEqual(C.pickChars(["b", "n", "a", "gone"], all: all).map { $0.id }, ["b", "a"])
    }

    // MARK: - 健康（health）

    func testHealthValues() {
        let row = Row(fields: ["id": .string("hl_1"), "who": .string("me"), "date": .string("2026-10-16"),
                               "sleepMin": .number(450), "steps": .number(12345), "water": .number(3),
                               "weight": .number(52.5), "mood": .string("good"), "poops": .array([.object(["at": .string("08:00")])])])
        let d = Health.Day(row: row, who: "me", date: "2026-10-16")
        let kg: (Double) -> Double = { $0 }
        XCTAssertEqual(C.healthValue("sleep", d, weight: kg), "7h30")
        XCTAssertEqual(C.healthValue("steps", d, weight: kg), "12,345")
        XCTAssertEqual(C.healthValue("water", d, weight: kg), "3")
        XCTAssertEqual(C.healthValue("weight", d, weight: kg), "52.5")
        XCTAssertEqual(C.healthValue("mood", d, weight: kg), "不错")
        XCTAssertEqual(C.healthValue("poop", d, weight: kg), "1")

        let empty = Health.Day(row: nil, who: "me", date: "2026-10-16")
        XCTAssertEqual(C.healthValue("sleep", empty, weight: kg), "—")
        XCTAssertEqual(C.healthValue("steps", empty, weight: kg), "—")
        XCTAssertEqual(C.healthValue("water", empty, weight: kg), "0")
        XCTAssertEqual(C.healthValue("weight", empty, weight: kg), "—")
        XCTAssertEqual(C.healthValue("mood", empty, weight: kg), "—")

        XCTAssertEqual(C.shortSleep(420), "7h")
        XCTAssertEqual(C.shortSleep(45), "45m")
        XCTAssertEqual(C.shortSleep(0), "—")
    }

    // MARK: - 推文、帖子与其余几样小算术

    /// 自己填时的计数按文字算（UTF-16 码元，同网页版），同一段字每次一样
    func testFakeCountAndNumbers() {
        XCTAssertEqual(C.fakeCount("abc", 1, 90), 63)
        XCTAssertEqual(C.fakeCount("", 1, 90), 89)
        XCTAssertEqual(C.fakeCount("你好", 5, 5000), 2463)
        XCTAssertEqual(C.fakeCount("你好", 5, 5000), C.fakeCount("你好", 5, 5000))

        XCTAssertEqual(C.shortK(999), "999")
        XCTAssertEqual(C.shortK(1500), "1.5K")
        XCTAssertEqual(C.shortK(12345), "1.2万")
        XCTAssertEqual(C.shortWan(9999), "9,999")
        XCTAssertEqual(C.shortWan(23000), "2.3万")
        XCTAssertEqual(C.grouped(1234567), "1,234,567")
        XCTAssertEqual(C.clock(205), "03:25")
        XCTAssertEqual(C.clock(-3), "00:00")
    }

    func testAgo() {
        let now = local(2026, 10, 16, 12)
        let ms = now.timeIntervalSince1970 * 1000
        XCTAssertEqual(C.ago(0, now: now), "")
        XCTAssertEqual(C.ago(ms - 30_000, now: now), "now")
        XCTAssertEqual(C.ago(ms - 5 * 60_000, now: now), "5m")
        XCTAssertEqual(C.ago(ms - 3 * 3_600_000, now: now), "3h")
        XCTAssertEqual(C.ago(ms - 2 * C.dayMs, now: now), "2d")
        XCTAssertEqual(C.ago(ms - 10 * C.dayMs, now: now), "Oct 6")
    }

    /// 每天一句：中文、英文、混排各取各的表，英文那一张与原有的 lineOfDay 是同一句；颜文字同一天不变
    func testLinesOfDay() {
        let d = local(2026, 10, 16)
        XCTAssertEqual(C.line("en", 7, d).t, MoreWidgets.lineOfDay(7, d).t)
        XCTAssertTrue(C.linesZH.contains(where: { $0.t == C.line("zh", 15, d).t }))
        let mix = C.line("mix", 11, d).t
        XCTAssertTrue(C.linesZH.contains(where: { $0.t == mix }) || MoreWidgets.linesEN.contains(where: { $0.t == mix }))
        XCTAssertEqual(C.linesZH.count, 16)
        XCTAssertEqual(C.kaomojiOfDay(13, d), C.kaomojiOfDay(13, d))
        XCTAssertTrue(C.kaomoji.contains(C.kaomojiOfDay(14, d)))
    }
}
