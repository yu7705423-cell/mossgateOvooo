import Foundation

/// 和风天气（网页版 system/weather.js）。角色当天的天气，按角色卡上的「所在地区」查。
///
/// 天气是事实，不是设定：数字不让模型编，排日程时查一次那座城市当天的预报，存在当天那一行的 weather 里，
/// 写进日程请求与聊天里「你今天」那一段。查天气不调模型接口，用量计入和风账号自己的额度。
/// 配置在 settings.services.qweather：{ host, key, cities }，与网页版同一份；城市名第一次查到的编号记在 cities 里。
enum Weather {
    struct Forecast: Equatable {
        var city = "", adm1 = "", date = "", textDay = "", textNight = ""
        var tempMin = 0.0, tempMax = 0.0
        var humidity: Double?, precip: Double?, uv: Double?
        var windDir = "", windScale = ""

        var json: JSONValue {
            var o: [String: JSONValue] = [
                "city": .string(city), "adm1": .string(adm1), "date": .string(date), "textDay": .string(textDay), "textNight": .string(textNight),
                "tempMin": .number(tempMin), "tempMax": .number(tempMax), "windDir": .string(windDir), "windScale": .string(windScale),
                "at": .number(Date().millis),
            ]
            o["humidity"] = humidity.map { .number($0) } ?? .null
            o["precip"] = precip.map { .number($0) } ?? .null
            o["uv"] = uv.map { .number($0) } ?? .null
            return .object(o)
        }

        init() {}

        init?(_ v: JSONValue?) {
            guard let o = v?.object, let c = o["city"]?.string else { return nil }
            city = c
            adm1 = o["adm1"]?.string ?? ""; date = o["date"]?.string ?? ""
            textDay = o["textDay"]?.string ?? ""; textNight = o["textNight"]?.string ?? ""
            tempMin = o["tempMin"]?.number ?? 0; tempMax = o["tempMax"]?.number ?? 0
            humidity = o["humidity"]?.number; precip = o["precip"]?.number; uv = o["uv"]?.number
            windDir = o["windDir"]?.string ?? ""; windScale = o["windScale"]?.string ?? ""
        }
    }

    static func config(_ s: AppSettings = .load()) -> [String: JSONValue] { s.services["qweather"]?.object ?? [:] }

    static func ready(_ s: AppSettings = .load()) -> Bool {
        let c = config(s)
        return !(c["host"]?.string ?? "").isEmpty && !(c["key"]?.string ?? "").isEmpty
    }

    /// 「abc123.re.qweatherapi.com」「https://abc123.re.qweatherapi.com/」都认
    static func hostOf(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespaces)
        h = h.replacingOccurrences(of: #"^https?://"#, with: "", options: [.regularExpression, .caseInsensitive])
        while h.hasSuffix("/") { h.removeLast() }
        return h.isEmpty ? "" : "https://\(h)"
    }

    private static let why: [Int: String] = [
        204: "没有这个地区的数据", 400: "请求参数有误", 401: "密钥不对，或者 API Host 与密钥不属于同一个账号",
        402: "额度已用完或账号欠费", 403: "没有权限，可能是密钥限制了来源或接口", 404: "没有这个地区",
        429: "请求太频繁", 500: "和风天气那边出错了",
    ]

    private static func api(_ path: String, _ params: [String: String]) async throws -> JSONValue {
        let c = config()
        let base = hostOf(c["host"]?.string ?? "")
        let key = c["key"]?.string ?? ""
        guard !base.isEmpty, !key.isEmpty else { throw StoreError(message: "尚未填写和风天气的 API Host 与 API KEY") }
        var comps = URLComponents(string: base + path)
        comps?.queryItems = (["lang": "zh"].merging(params) { _, n in n }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps?.url else { throw StoreError(message: "API Host 填写有误") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "X-QW-Api-Key")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch {
            if (error as? URLError)?.code == .timedOut { throw StoreError(message: "和风天气超过 10 秒没有回复") }
            throw StoreError(message: "连不上和风天气（\(error.localizedDescription)），请检查 API Host 是否填对")
        }
        let body = try? JSONValue.parse(data)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let e = body?["error"]
            throw StoreError(message: e?["detail"]?.string ?? e?["title"]?.string ?? why[status] ?? "HTTP \(status)")
        }
        if let code = body?["code"]?.string, code != "200" { throw StoreError(message: why[Int(code) ?? 0] ?? "和风天气返回 \(code)") }
        return body ?? .object([:])
    }

    /// 城市名对应到和风的城市。查到一次就记住
    static func lookup(_ name: String) async throws -> [String: JSONValue] {
        let key = name.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw StoreError(message: "没有填写所在地区") }
        if let c = config()["cities"]?[key]?.object { return c }
        let r = try await api("/geo/v2/city/lookup", ["location": key, "number": "1"])
        guard let c = r["location"]?.array?.first else { throw StoreError(message: "没有找到「\(key)」这个地区") }
        let city: [String: JSONValue] = ["id": c["id"] ?? .string(""), "name": c["name"] ?? .string(key), "adm1": c["adm1"] ?? .string(""),
                                         "country": c["country"] ?? .string(""), "tz": c["tz"] ?? .string("")]
        var s = AppSettings.load()
        var cities = config(s)["cities"]?.object ?? [:]
        cities[key] = .object(city)
        s.setService("qweather", ["cities": .object(cities)])
        try s.save()
        return city
    }

    private static func num(_ v: JSONValue?) -> Double? {
        if let n = v?.number { return n }
        if let t = v?.string, !t.isEmpty { return Double(t) }
        return nil
    }

    /// 某个城市某一天的预报。三天预报里对不上就取第一天：时区差出一天时，第一天就是它的「今天」
    static func forecast(_ name: String, date: String = "") async throws -> Forecast {
        let city = try await lookup(name)
        let r = try await api("/v7/weather/3d", ["location": city["id"]?.string ?? ""])
        let days = r["daily"]?.array ?? []
        guard let d = days.first(where: { $0["fxDate"]?.string == date }) ?? days.first else { throw StoreError(message: "和风天气没有给出预报") }
        var f = Forecast()
        f.city = city["name"]?.string ?? name; f.adm1 = city["adm1"]?.string ?? ""
        f.date = d["fxDate"]?.string ?? date
        f.textDay = d["textDay"]?.string ?? ""; f.textNight = d["textNight"]?.string ?? ""
        f.tempMin = num(d["tempMin"]) ?? 0; f.tempMax = num(d["tempMax"]) ?? 0
        f.humidity = num(d["humidity"]); f.precip = num(d["precip"]); f.uv = num(d["uvIndex"])
        f.windDir = d["windDirDay"]?.string ?? ""; f.windScale = d["windScaleDay"]?.string ?? ""
        return f
    }

    /// 这个角色当天的天气。没配、没填所在地区、查不到都是 nil，不拦着日程
    static func forChar(_ char: Character, date: String) async -> Forecast? {
        let region = DayPlan.region(char)
        guard ready(), !region.isEmpty else { return nil }
        do { return try await forecast(region, date: date) }
        catch { Diagnostics.shared.record("weather-failed", ["error": error.localizedDescription]); return nil }
    }

    /// 给人看的一行：成都 小雨转阴 18~24°C
    static func label(_ w: Forecast) -> String {
        let text = w.textDay == w.textNight || w.textNight.isEmpty ? w.textDay : "\(w.textDay)转\(w.textNight)"
        return "\(w.city) \(text) \(fmt(w.tempMin))~\(fmt(w.tempMax))°C"
    }

    static func fmt(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(x) }

    /// 进 prompt 的那一句：只陈述预报（第 14、16 条）
    static func promptLine(_ w: Forecast) -> String {
        var bits = ["\(w.textDay) by day"]
        if !w.textNight.isEmpty && w.textNight != w.textDay { bits.append("\(w.textNight) at night") }
        bits.append("\(fmt(w.tempMin)) to \(fmt(w.tempMax))°C")
        if let h = w.humidity { bits.append("humidity \(fmt(h))%") }
        if let p = w.precip, p != 0 { bits.append("precipitation \(fmt(p)) mm") }
        if !w.windDir.isEmpty { bits.append("wind \(w.windDir)" + (w.windScale.isEmpty ? "" : " force \(w.windScale)")) }
        if let u = w.uv { bits.append("UV index \(fmt(u))") }
        return "Weather forecast for \(w.city) today (\(w.date)): \(bits.joined(separator: ", "))."
    }
}
