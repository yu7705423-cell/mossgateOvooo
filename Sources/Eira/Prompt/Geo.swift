import Foundation

/// 共享位置：两个人隔多远（网页版 system/geo.js 与 context/geo.js）。
///
/// 要害是那个数字不能让模型编：距离在本机按 haversine 算好，连同单位写进上下文，再明说一句不要改。
/// 坐标两边都是自己填的（常用城市一点即填，表里没有的手填经纬度），不读设备定位。存在会话上（chat.share），默认关。
enum Geo {
    struct Spot: Equatable {
        var place = ""
        var lat: Double?
        var lng: Double?

        var json: JSONValue {
            .object(["place": .string(place), "lat": lat.map { .number($0) } ?? .null, "lng": lng.map { .number($0) } ?? .null])
        }
    }

    static let cities: [(name: String, lat: Double, lng: Double)] = [
        ("北京", 39.90, 116.41), ("上海", 31.23, 121.47), ("广州", 23.13, 113.26), ("深圳", 22.54, 114.06),
        ("成都", 30.57, 104.07), ("杭州", 30.27, 120.15), ("西安", 34.34, 108.94), ("武汉", 30.59, 114.31),
        ("重庆", 29.56, 106.55), ("南京", 32.06, 118.80), ("香港", 22.32, 114.17), ("台北", 25.03, 121.57),
        ("东京", 35.68, 139.65), ("首尔", 37.57, 126.98), ("新加坡", 1.35, 103.82), ("伦敦", 51.51, -0.13),
        ("巴黎", 48.86, 2.35), ("纽约", 40.71, -74.01), ("洛杉矶", 34.05, -118.24), ("悉尼", -33.87, 151.21),
    ]

    private static func num(_ v: JSONValue?) -> Double? {
        if let n = v?.number, n.isFinite { return n }
        if let t = v?.string, !t.isEmpty, let n = Double(t), n.isFinite { return n }
        return nil
    }

    /// 一端的位置。经纬度任一缺失或越界就算没坐标，只剩地点名（空值不当成 0：0 是个合法的经纬度）
    static func clean(_ v: JSONValue?) -> Spot? {
        guard let o = v?.object else { return nil }
        let lat = num(o["lat"]), lng = num(o["lng"])
        let ok = lat != nil && lng != nil && (-90...90).contains(lat!) && (-180...180).contains(lng!)
        return Spot(place: String((o["place"]?.string ?? "").trimmingCharacters(in: .whitespaces).prefix(40)),
                    lat: ok ? lat : nil, lng: ok ? lng : nil)
    }

    /// 球面距离，公里。任一端没坐标返回 nil，不猜
    static func distance(_ a: Spot, _ b: Spot) -> Double? {
        guard let la = a.lat, let ln = a.lng, let lb = b.lat, let mb = b.lng else { return nil }
        let r = 6371.0
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        let dLat = rad(lb - la), dLng = rad(mb - ln)
        let h = pow(sin(dLat / 2), 2) + cos(rad(la)) * cos(rad(lb)) * pow(sin(dLng / 2), 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// 一公里以内用米
    static func distanceText(_ km: Double?) -> String {
        guard let km else { return "" }
        if km < 1 { return "\(Int((km * 1000).rounded())) 米" }
        if km < 10 { return String(format: "%.1f 公里", km) }
        return "\(Int(km.rounded())) 公里"
    }

    struct State { var on = false; var me: Spot?; var char: Spot? }

    static func state(_ chat: Chat?) -> State {
        guard let s = chat?.row["share"]?.object else { return State() }
        return State(on: s["on"]?.bool == true, me: clean(s["me"]), char: clean(s["char"]))
    }

    private static func write(_ chatId: String, _ change: (inout [String: JSONValue]) -> Void) throws {
        guard var c = try Repo.chat(chatId) else { return }
        var s = c.row["share"]?.object ?? ["on": .bool(false), "me": .null, "char": .null]
        change(&s)
        c.row["share"] = .object(s)
        c.row.touch()
        try Repo.save(c)
    }

    static func setOn(_ chatId: String, _ on: Bool) throws { try write(chatId) { $0["on"] = .bool(on) } }

    /// side 是 me 或 char；nil 表示这一端不填了
    static func setSpot(_ chatId: String, side: String, _ spot: Spot?) throws {
        guard side == "me" || side == "char" else { return }
        try write(chatId) { $0[side] = spot?.json ?? .null }
    }

    /// 注入的那一段（区块抬头 [你们隔多远] 是协议）。没开、哪一端没填都为空
    static func block(_ chat: Chat) -> String {
        let s = state(chat)
        guard s.on, let me = s.me, let ch = s.char else { return "" }
        var lines = ["The other party is at \(me.place.isEmpty ? "an unnamed place" : me.place); you are at \(ch.place.isEmpty ? "an unnamed place" : ch.place)."]
        let text = distanceText(distance(me, ch))
        if !text.isEmpty {
            lines.append("The straight-line distance between the two is \(text).")
            lines.append("This distance was computed by the system. Write it exactly as given when the distance comes up. Do not substitute another figure, and do not estimate one yourself.")
        } else {
            lines.append("Only place names are available, without coordinates, so no distance can be determined. Do not state a specific figure.")
        }
        return "\n\n[你们隔多远]\n" + lines.joined(separator: "\n")
    }
}
