import Foundation

/// 时间感知（网页版 system/time.js，ARCHITECTURE 4.67）。两件事：现在几点（可以是虚拟的），以及双方各在哪个时区。
///
/// 设置项与网页版同名：injectTime（时间感知总开关）、timeStamp（要求角色写出时间那一行）、
/// timeMode（real / virtual）、timeVirtualAt + timeSetAt（设定的那一刻与设定时的真实时刻，差就是偏移，虚拟时间会自己往下走）、
/// timeFrozen（停在设定的那一刻）、timeZoneUser（我在哪个时区）。角色的时区在角色卡上（characters[].timezone）。
enum Clock {
    static let local = "local"

    /// 按用得上的概率排，不求全（网页版 ZONES）
    static let zones: [(id: String, label: String)] = [
        (local, "跟随本设备"),
        ("Asia/Shanghai", "中国 · 北京、上海"), ("Asia/Hong_Kong", "中国香港"), ("Asia/Taipei", "中国台北"),
        ("Asia/Tokyo", "日本 · 东京"), ("Asia/Seoul", "韩国 · 首尔"), ("Asia/Singapore", "新加坡"),
        ("Asia/Bangkok", "泰国 · 曼谷"), ("Asia/Kolkata", "印度 · 新德里"), ("Asia/Dubai", "阿联酋 · 迪拜"),
        ("Europe/Moscow", "俄罗斯 · 莫斯科"), ("Europe/Istanbul", "土耳其 · 伊斯坦布尔"), ("Europe/Berlin", "德国 · 柏林"),
        ("Europe/Paris", "法国 · 巴黎"), ("Europe/Rome", "意大利 · 罗马"), ("Europe/Madrid", "西班牙 · 马德里"),
        ("Europe/London", "英国 · 伦敦"), ("America/New_York", "美国 · 纽约"), ("America/Chicago", "美国 · 芝加哥"),
        ("America/Denver", "美国 · 丹佛"), ("America/Los_Angeles", "美国 · 洛杉矶"), ("America/Toronto", "加拿大 · 多伦多"),
        ("America/Vancouver", "加拿大 · 温哥华"), ("America/Mexico_City", "墨西哥 · 墨西哥城"), ("America/Sao_Paulo", "巴西 · 圣保罗"),
        ("Australia/Sydney", "澳大利亚 · 悉尼"), ("Pacific/Auckland", "新西兰 · 奥克兰"), ("Africa/Cairo", "埃及 · 开罗"),
        ("Africa/Johannesburg", "南非 · 约翰内斯堡"),
    ]

    /// 跟随设备时要把真实时区解出来再说：写「本地」等于什么都没说
    static func resolve(_ id: String) -> String {
        id.isEmpty || id == local ? TimeZone.current.identifier : id
    }

    static func zone(_ id: String) -> TimeZone { TimeZone(identifier: resolve(id)) ?? .current }

    static func label(_ id: String) -> String {
        let real = resolve(id)
        return zones.first { $0.id == real }?.label ?? real
    }

    static func enabled(_ s: AppSettings) -> Bool { s.raw["injectTime"]?.bool ?? true }
    static func stampOn(_ s: AppSettings) -> Bool { enabled(s) && (s.raw["timeStamp"]?.bool ?? true) }

    static func isVirtual(_ s: AppSettings) -> Bool {
        s.raw["timeMode"]?.string == "virtual" && (s.raw["timeVirtualAt"]?.number ?? 0) > 0
    }

    /// 虚拟时间与真实时间差多少毫秒
    static func offset(_ s: AppSettings) -> Double {
        guard isVirtual(s), let at = s.raw["timeVirtualAt"]?.number else { return 0 }
        return at - (s.raw["timeSetAt"]?.number ?? at)
    }

    /// 现在（世界里的）几点
    static func now(_ s: AppSettings, real: Date = Date()) -> Date {
        if isVirtual(s), s.raw["timeFrozen"]?.bool == true, let at = s.raw["timeVirtualAt"]?.number {
            return Date(millis: at)
        }
        return Date(millis: real.millis + offset(s))
    }

    /// 真实时刻换算成世界时刻：历史消息的 createdAt 要过这一道
    static func toWorld(_ realMs: Double, _ s: AppSettings) -> Date { Date(millis: realMs + offset(s)) }

    static func userZone(_ s: AppSettings) -> String {
        let z = s.raw["timeZoneUser"]?.string ?? ""
        return z.isEmpty ? local : z
    }

    /// 角色没单独设就跟你同一个时区
    static func charZone(_ char: Character?, _ s: AppSettings) -> String {
        let z = char?.row.string("timezone") ?? ""
        return z.isEmpty ? userZone(s) : z
    }

    /// a 比 b 快多少分钟。先解析再比：一边跟随设备、一边显式填了同一个时区时不算时差
    static func zoneDiff(_ a: String, _ b: String, at date: Date) -> Int {
        if resolve(a) == resolve(b) { return 0 }
        return (zone(a).secondsFromGMT(for: date) - zone(b).secondsFromGMT(for: date)) / 60
    }

    static func clockOnly(_ d: Date, zone z: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone(z)
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// 设一个虚拟时刻：记下设定的那一刻与此刻的真实时刻
    static func virtualPatch(_ at: Date, frozen: Bool, real: Date = Date()) -> [String: JSONValue] {
        ["timeMode": .string("virtual"), "timeVirtualAt": .number(at.millis), "timeSetAt": .number(real.millis), "timeFrozen": .bool(frozen)]
    }
}
