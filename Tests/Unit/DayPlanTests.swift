import XCTest
@testable import Eira

/// 日常：骰子与时段；当日日程默认不排；开着时每天第一条消息前排一次，失败当天不再自动排；
/// 角色写的 [事项完成：…] 勾掉那一条；[你今天] 进提示词。
final class DayPlanTests: StoreTestCase {
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

    private func isPlan(_ r: URLRequest) -> Bool {
        String(data: r.httpBodyStreamData() ?? Data(), encoding: .utf8)?.contains("Plan what this character will do") == true
    }

    func testDice() {
        XCTAssertEqual(DayPlan.penalty("a", ["a", "b"], 3), 0.25)
        XCTAssertEqual(DayPlan.penalty("c", ["a", "b"], 3), 1)
        let rows = [Row.new(prefix: "x", ["w": .number(1)]), Row.new(prefix: "x", ["w": .number(3)])]
        XCTAssertEqual(DayPlan.pick(rows, weight: { $0.number("w") ?? 0 }, rng: { 0.1 })?.id, rows[0].id)
        XCTAssertEqual(DayPlan.pick(rows, weight: { $0.number("w") ?? 0 }, rng: { 0.9 })?.id, rows[1].id)
        XCTAssertNil(DayPlan.pick(rows, weight: { _ in 0 }))
        XCTAssertEqual(DayPlan.overdue(0.35, 1), 0.35, accuracy: 0.0001)
        XCTAssertEqual(DayPlan.overdue(0.9, 10), 1)
        XCTAssertEqual(DayPlan.drift(2, rng: { 1 }), 2)
    }

    func testNightCountsAsYesterday() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let threeAm = cal.date(bySettingHour: 3, minute: 0, second: 0, of: Date())!
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let c = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(DayPlan.dateKey(c, threeAm), Diary.shift(DayPlan.dateKey(c, noon), days: -1))
        XCTAssertEqual(DayPlan.slotNow(c, threeAm).id, "night")
    }

    func testEventRoll() throws {
        try DayPlan.addEvent(domain: "luck", tone: "good", rarity: "common", text: "捡到一把伞")
        var c = try XCTUnwrap(Repo.character("char_a"))
        let s = AppSettings(raw: ["eventChance": .number(1)])
        XCTAssertEqual(try DayPlan.rollEvent(char: c, daysSince: 1, recent: [], settings: s)?.string("text"), "捡到一把伞")
        c.row["eventsOn"] = .bool(false)
        XCTAssertNil(try DayPlan.rollEvent(char: c, daysSince: 1, recent: [], settings: s))
    }

    func testOffByDefault() async throws {
        XCTAssertFalse(ExtraCalls.switchedOn(.load()).contains { $0.id == "dayOn" })
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("好")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
    }

    /// 接口一直失败：第一条消息前排一次，失败写在当天那一行上；同一天之后的消息不再排。
    func testFailingPlanOncePerDay() async throws {
        try Diary.patchChar("char_a", ["dayOn": .bool(true)])
        XCTAssertTrue(ExtraCalls.switchedOn(.load()).contains { $0.id == "dayOn" })
        try setSettings(["retryMax": .number(3)])
        MockNet.reset { r, _ in
            if self.isPlan(r) { return .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
            return .init(status: 200, body: MockNet.anthropicStream("好"))
        }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.requests.filter(isPlan).count, 2)   // 一次 + 重试一次（min(1, retryMax)）
        XCTAssertEqual(MockNet.count, 4)
        let c = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertFalse(try XCTUnwrap(DayPlan.today(c)).string("planFailed").isEmpty)
    }

    /// 排成功：事项按时段排好，[你今天] 与今天的安排进提示词；角色写 [事项完成：…] 勾掉那一条。
    func testPlanBlockAndMark() async throws {
        try Diary.patchChar("char_a", ["dayOn": .bool(true)])
        let plan = #"{"items":[{"slot":"evening","text":"去超市买菜","cost":30,"auto":"在超市"},{"slot":"morning","text":"晨跑","cost":0,"auto":""},{"slot":"bogus","text":"x"}],"sleep":"睡了"}"#
        MockNet.reset { r, _ in
            if self.isPlan(r) { return .init(status: 200, body: MockNet.anthropicStream(plan)) }
            return .init(status: 200, body: MockNet.anthropicStream("刚跑完\n[事项完成：晨跑]"))
        }
        try await DayPlan.makeToday("char_a")
        let c = try XCTUnwrap(Repo.character("char_a"))
        let items = try XCTUnwrap(DayPlan.today(c))["items"]?.array ?? []
        XCTAssertEqual(items.compactMap { $0["text"]?.string }, ["晨跑", "去超市买菜"])
        let b = try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: c, settings: .load())
        let all = b.system + b.messages.map(\.content).joined()
        XCTAssertTrue(all.contains("[你今天]"))
        XCTAssertTrue(all.contains("[今天的安排]"))
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let after = try XCTUnwrap(DayPlan.today(c))["items"]?.array ?? []
        XCTAssertEqual(after.first { $0["text"]?.string == "晨跑" }?["state"]?.string, DayPlan.done)
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.content, "刚跑完")
    }

    func testMealDraw() throws {
        try Database.shared.put("recipes", Row.new(prefix: "rc", ["region": .string(""), "name": .string("豆浆油条"), "meal": .string("breakfast")]))
        let c = try XCTUnwrap(Repo.character("char_a"))
        let local = try DayPlan.rollLocal(c, date: DayPlan.dateKey(c), settings: AppSettings(raw: ["eventChance": .number(0)]))
        let meals = local["meals"]?.array ?? []
        XCTAssertEqual(meals.count, 1)
        XCTAssertEqual(meals.first?["name"]?.string, "豆浆油条")
        XCTAssertEqual(try Database.shared.all("meals", where: "char_a").count, 1)
    }
}
