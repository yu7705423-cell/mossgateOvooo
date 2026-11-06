import Foundation

/// 把「明天七点」这种话算成一个时刻（网页版 system/when.js，ARCHITECTURE 4.104g）。
///
/// - 按真实时间算，不按对话里的时间：提醒要在真实世界里到点。日子与钟点按本机的时区算，与网页版 `new Date` 一致；
/// - 只说点钟没说哪天，而那个点钟今天已经过去了，就是明天；
/// - 认不出来就回 nil，不猜。`hasTime` 分开报「认出了日子」和「认出了点钟」，自动挂时刻只认后者。
enum When {
    struct Hit: Equatable {
        /// 绝对时刻（毫秒）。只说了日子没说点钟时，是那天零点
        var at: Double
        /// 有没有说到点钟
        var hasTime: Bool
        /// 认出来的那一段原文
        var hit: String
    }

    private static let digit: [Swift.Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6,
                                                 "七": 7, "八": 8, "九": 9, "十": 10]

    /// 「十九」「二十三」「七」都认。认不出来返回 nil
    static func cnNum(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.allSatisfy({ $0.isASCII && $0.isNumber }) { return Int(t) }
        guard t.allSatisfy({ "零〇一二两三四五六七八九十".contains($0) }) else { return nil }
        let chars = Array(t)
        guard let at = chars.firstIndex(of: "十") else {
            var n = 0
            for ch in chars { guard let d = digit[ch] else { return nil }; n = n * 10 + d }
            return n
        }
        // 十 / 十三 / 二十 / 二十三：十前后各只认一个字
        let headPart = String(chars[..<at]), tailPart = String(chars[(at + 1)...])
        let high: Int? = headPart.isEmpty ? 1 : (headPart.count == 1 ? digit[headPart.first!] : nil)
        let low: Int? = tailPart.isEmpty ? 0 : (tailPart.count == 1 ? digit[tailPart.first!] : nil)
        guard let high, let low else { return nil }
        return high * 10 + low
    }

    private static let num = "[0-9零〇一二两三四五六七八九十]+"

    /// 时段词：覆盖哪几个钟头、省略数字时默认几点。只用来把十二小时制的数字挪到正确的那一半
    private static let spans: [(re: NSRegularExpression, from: Int, to: Int, fallback: Int)] = [
        (rx("凌晨|半夜|夜里"), 0, 5, 3),
        (rx("早上|早晨|清晨|上午|今早|明早"), 6, 11, 8),
        (rx("中午|正午|午间"), 11, 13, 12),
        (rx("下午|午后"), 13, 18, 15),
        (rx("傍晚|黄昏"), 17, 19, 18),
        (rx("晚上|夜晚|今晚|明晚|后晚"), 18, 23, 20),
    ]

    private static let week: [String: Int] = ["日": 0, "天": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6]

    private static func rx(_ p: String) -> NSRegularExpression { ReplyParser.regex(p, []) }
    private static let fullDate = rx(#"([0-9]{4})[-/年]([0-9]{1,2})[-/月]([0-9]{1,2})"#)
    private static let monthDay = rx(#"([0-9]{1,2})\s*[月/-]\s*([0-9]{1,2})\s*[日号]?"#)
    private static let daysLater = rx("(\(num))\\s*天(?:之)?后")
    private static let weekday = rx(#"(下下|下|这|本)?\s*(?:周|星期|礼拜)\s*([日天一二三四五六])"#)
    private static let colon = rx(#"([0-9]{1,2})\s*[:：]\s*([0-9]{2})"#)
    private static let dian = rx("(\(num))\\s*[点時时]\\s*(半|一刻|三刻|(?:\(num))\\s*分?)?")

    private static var cal: Calendar { Calendar.current }

    private static func startOfDay(_ d: Date) -> Date { cal.startOfDay(for: d) }

    private static func make(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    private static func contains(_ s: String, _ p: String) -> Bool { s.range(of: p, options: .regularExpression) != nil }

    private static func whichDay(_ text: String, _ now: Date) -> (day: Date, hit: String)? {
        let base = startOfDay(now)
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: base)
        func plus(_ n: Int) -> Date { make(c.year!, c.month!, c.day! + n) }

        if let m = ReplyParser.match(fullDate, text), let y = Int(m[1]), let mo = Int(m[2]), let d = Int(m[3]) {
            return (make(y, mo, d), m[0])
        }
        if let m = ReplyParser.match(monthDay, text), let mo = Int(m[1]), let d = Int(m[2]) {
            var year = c.year!
            // 说的月份已经过去了，就是明年那一次
            if mo < c.month! { year += 1 }
            return (make(year, mo, d), m[0])
        }
        if let m = ReplyParser.match(daysLater, text), let n = cnNum(m[1]) { return (plus(n), m[0]) }
        if text.contains("大后天") { return (plus(3), "大后天") }
        if contains(text, "后天|后晚") { return (plus(2), "后天") }
        if contains(text, "明天|明早|明晚|明日") { return (plus(1), "明天") }
        if contains(text, "今天|今早|今晚|今夜|今日") { return (base, "今天") }

        if let m = ReplyParser.match(weekday, text), let want = week[m[2]] {
            let cur = (c.weekday ?? 1) - 1
            var add = (want - cur + 7) % 7
            // 不带「下」的「周四」指这一周里还没到的那个；已经过了就是下一周
            if m[1].isEmpty || m[1] == "这" || m[1] == "本" { if add == 0 { add = 7 } }
            else if m[1] == "下" { add += 7 }
            else { add += 14 }
            return (plus(add), m[0])
        }
        return nil
    }

    private static func whichTime(_ text: String) -> (hour: Int, min: Int, hit: String)? {
        if let m = ReplyParser.match(colon, text), let h = Int(m[1]), let mi = Int(m[2]) { return (h, mi, m[0]) }
        if let m = ReplyParser.match(dian, text) {
            guard let hour = cnNum(m[1]) else { return nil }
            var min = 0
            let tail = m[2].trimmingCharacters(in: .whitespaces)
            if tail == "半" { min = 30 }
            else if tail == "一刻" { min = 15 }
            else if tail == "三刻" { min = 45 }
            else if !tail.isEmpty, let n = cnNum(tail.hasSuffix("分") ? String(tail.dropLast()) : tail) { min = n }
            return (hour, min, m[0])
        }
        return nil
    }

    /// 主入口。一个字都认不出来回 nil
    static func parse(_ text: String, now: Date = Date()) -> Hit? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let day = whichDay(text, now)
        let time = whichTime(text)
        let span = spans.first { ReplyParser.matches($0.re, text) }
        if day == nil && time == nil && span == nil { return nil }

        var hour = time?.hour ?? span?.fallback ?? 0
        let min = time?.min ?? 0
        // 十二小时制归位：「下午三点」是 15 点；「晚上十一点」本来就落在时段里，不动
        if let span, time != nil, hour < 12, hour + 12 <= span.to, hour < span.from { hour += 12 }
        if hour > 23 || hour < 0 { return nil }

        var dc = cal.dateComponents([.year, .month, .day], from: day?.day ?? startOfDay(now))
        dc.hour = hour; dc.minute = min; dc.second = 0
        var at = cal.date(from: dc) ?? now
        // 只说了点钟没说哪天，那个点钟今天已经过去了：说的是明天
        if day == nil && at <= now { at = at.addingTimeInterval(86400) }

        var hit = day?.hit ?? ""
        if let span, time == nil, let m = ReplyParser.match(span.re, text) { hit += m[0] }
        hit += time?.hit ?? ""
        return Hit(at: at.millis, hasTime: time != nil || span != nil, hit: hit)
    }

    /// 折算出来的时刻写成人看的样子：今天 / 明天 / 后天 / 昨天，其余写日期
    static func show(_ ms: Double, now: Date = Date()) -> String {
        guard ms > 0 else { return "" }
        let d = Date(millis: ms)
        let days = Int((startOfDay(d).timeIntervalSince(startOfDay(now)) / 86400).rounded())
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        let day = days == 0 ? "今天" : days == 1 ? "明天" : days == 2 ? "后天" : days == -1 ? "昨天"
            : String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return "\(day) " + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
