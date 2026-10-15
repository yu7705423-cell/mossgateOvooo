import XCTest
@testable import Eira

/// 和风天气：地址的认法、城市编号查一次记住、三天预报取对应那一天、写进提示词的那一句只陈述预报
final class WeatherTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["services": .object(["qweather": .object(["host": .string("https://abc.re.qweatherapi.com/"), "key": .string("k")])])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    func testHost() {
        XCTAssertEqual(Weather.hostOf("abc.re.qweatherapi.com"), "https://abc.re.qweatherapi.com")
        XCTAssertEqual(Weather.hostOf("https://abc.re.qweatherapi.com/"), "https://abc.re.qweatherapi.com")
        XCTAssertEqual(Weather.hostOf(" "), "")
    }

    func testForecastAndCityCache() async throws {
        MockNet.reset { req, _ in
            if req.url?.path.contains("/geo/") == true {
                return .init(status: 200, body: #"{"code":"200","location":[{"id":"101270101","name":"成都","adm1":"四川"}]}"#)
            }
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-QW-Api-Key"), "k")
            return .init(status: 200, body: #"{"code":"200","daily":[{"fxDate":"2026-10-15","textDay":"小雨","textNight":"阴","tempMin":"18","tempMax":"24","humidity":"80","precip":"1.2","windDirDay":"北风","windScaleDay":"1-3","uvIndex":"2"},{"fxDate":"2026-10-16","textDay":"晴","textNight":"晴","tempMin":"16","tempMax":"26"}]}"#)
        }
        let w = try await Weather.forecast("成都", date: "2026-10-16")
        XCTAssertEqual(w.textDay, "晴")
        XCTAssertEqual(Weather.label(w), "成都 晴 16~26°C")
        XCTAssertEqual(MockNet.count, 2)
        // 城市编号记住了：第二次只查预报
        let w2 = try await Weather.forecast("成都", date: "2026-10-15")
        XCTAssertEqual(MockNet.count, 3)
        XCTAssertEqual(Weather.promptLine(w2),
                       "Weather forecast for 成都 today (2026-10-15): 小雨 by day, 阴 at night, 18 to 24°C, humidity 80%, precipitation 1.2 mm, wind 北风 force 1-3, UV index 2.")
        // 存进当天那一行再读回来一样
        XCTAssertEqual(Weather.Forecast(w2.json), w2)
    }

    func testErrorsAndNotReady() async throws {
        MockNet.reset { _, _ in .init(status: 401, body: #"{"error":{"title":"Unauthorized"}}"#) }
        do { _ = try await Weather.forecast("北京"); XCTFail("应当失败") } catch {
            XCTAssertEqual(error.localizedDescription, "Unauthorized")
        }
        try setSettings(["services": .object([:])])
        XCTAssertFalse(Weather.ready())
        let char = try XCTUnwrap(Repo.character("char_a"))
        let w = await Weather.forChar(char, date: "2026-10-15")
        XCTAssertNil(w)
    }
}
