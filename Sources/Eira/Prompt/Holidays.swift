import Foundation

/// 节日表（网页版 system/holidays.js，ARCHITECTURE 4.380）。
///
/// 只算「哪一天是什么节」，告诉角色的那一段在下面的 `block`（网页版 context/dates.js）。
/// 角色来自各个国家，告诉它哪一套节日是在替用户做决定（第 16 条），所以按国家分组、让用户自己勾：
/// 设置里「节日」一页。默认勾「通用」与「中国」，其余默认不勾。
///
/// 设置项与网页版同名同形：holidayRegions（勾着的地区 id 数组）、holidayOff（关掉的「地区.节日」数组）、
/// holidayCustom（自定义节日 { id, name, month, day, lunar }）。网页版导进来的设置原样可用。
///
/// 农历用系统自带的 chinese 历法（网页版用浏览器的 Intl 'u-ca-chinese'，底下是同一套 ICU），不引库。
/// 闰月那一个月里的同一天不算（闰五月初五不是端午）。
///
/// 日期一律按「公历的年月日」算，不带时区：内部用 UTC 的公历日历做加减，与网页版 new Date(y, m, d) 的本地日期一一对应。
enum Holidays {
    struct Rule: Sendable, Equatable {
        /// 公历固定日 'MM-DD'
        var md: String? = nil
        /// 农历 'M-D'
        var lunar: String? = nil
        /// 除夕：农历正月初一的前一天
        var eve = false
        /// 第几个星期几：[月, 星期, 第几个]，星期 0 为周日，第几个 -1 为最后一个
        var nth: [Int]? = nil
        /// 复活节前后的偏移天数
        var easter: Int? = nil
        /// 清明（按节气公式算）
        var qingming = false
    }

    struct Holiday: Identifiable, Sendable {
        let id: String
        let name: String
        let rule: Rule
    }

    struct Region: Identifiable, Sendable {
        let id: String
        let name: String
        let list: [Holiday]
    }

    private static func md(_ id: String, _ name: String, _ v: String) -> Holiday { Holiday(id: id, name: name, rule: Rule(md: v)) }
    private static func lunar(_ id: String, _ name: String, _ v: String) -> Holiday { Holiday(id: id, name: name, rule: Rule(lunar: v)) }
    private static func nth(_ id: String, _ name: String, _ m: Int, _ w: Int, _ n: Int) -> Holiday {
        Holiday(id: id, name: name, rule: Rule(nth: [m, w, n]))
    }
    private static func easter(_ id: String, _ name: String, _ off: Int) -> Holiday { Holiday(id: id, name: name, rule: Rule(easter: off)) }

    /// 与网页版 REGIONS 同一份，id 一字不差（holidayOff 里存的就是它们）
    static let regions: [Region] = [
        Region(id: "intl", name: "通用", list: [
            md("newyear", "元旦", "01-01"),
            md("valentine", "情人节", "02-14"),
            md("women", "妇女节", "03-08"),
            md("fools", "愚人节", "04-01"),
            md("labor", "劳动节", "05-01"),
            nth("mother", "母亲节", 5, 0, 2),
            nth("father", "父亲节", 6, 0, 3),
            md("halloween", "万圣节", "10-31"),
            md("xmaseve", "平安夜", "12-24"),
            md("xmas", "圣诞节", "12-25"),
            md("nye", "跨年夜", "12-31"),
        ]),
        Region(id: "cn", name: "中国", list: [
            Holiday(id: "eve", name: "除夕", rule: Rule(eve: true)),
            lunar("spring", "春节", "1-1"),
            lunar("lantern", "元宵节", "1-15"),
            Holiday(id: "qingming", name: "清明节", rule: Rule(qingming: true)),
            md("youth", "青年节", "05-04"),
            md("children", "儿童节", "06-01"),
            lunar("dragon", "端午节", "5-5"),
            lunar("qixi", "七夕", "7-7"),
            lunar("ghost", "中元节", "7-15"),
            md("teacher", "教师节", "09-10"),
            lunar("midautumn", "中秋节", "8-15"),
            md("national", "国庆节", "10-01"),
            lunar("chongyang", "重阳节", "9-9"),
            lunar("laba", "腊八节", "12-8"),
            lunar("xiaonian", "小年", "12-23"),
        ]),
        Region(id: "jp", name: "日本", list: [
            md("ganjitsu", "元日", "01-01"),
            nth("seijin", "成人之日", 1, 1, 2),
            md("kenkoku", "建国纪念日", "02-11"),
            md("hina", "女儿节", "03-03"),
            md("white", "白色情人节", "03-14"),
            md("showa", "昭和之日", "04-29"),
            md("kenpo", "宪法纪念日", "05-03"),
            md("midori", "绿之日", "05-04"),
            md("kodomo", "儿童之日", "05-05"),
            md("tanabata", "七夕", "07-07"),
            nth("umi", "海之日", 7, 1, 3),
            md("obon", "盂兰盆节", "08-15"),
            nth("keiro", "敬老之日", 9, 1, 3),
            nth("sports", "体育之日", 10, 1, 2),
            md("bunka", "文化之日", "11-03"),
            md("shichigosan", "七五三", "11-15"),
            md("kinro", "勤劳感谢之日", "11-23"),
            md("omisoka", "大晦日", "12-31"),
        ]),
        Region(id: "kr", name: "韩国", list: [
            lunar("seollal", "春节", "1-1"),
            md("samil", "三一节", "03-01"),
            md("white", "白色情人节", "03-14"),
            md("black", "黑色情人节", "04-14"),
            lunar("buddha", "佛诞日", "4-8"),
            md("children", "儿童节", "05-05"),
            md("parents", "父母节", "05-08"),
            md("memorial", "显忠日", "06-06"),
            md("liberation", "光复节", "08-15"),
            lunar("chuseok", "中秋节", "8-15"),
            md("gaecheon", "开天节", "10-03"),
            md("hangeul", "韩文日", "10-09"),
        ]),
        Region(id: "us", name: "美国", list: [
            nth("mlk", "马丁·路德·金纪念日", 1, 1, 3),
            nth("presidents", "总统日", 2, 1, 3),
            md("patrick", "圣帕特里克节", "03-17"),
            easter("easter", "复活节", 0),
            nth("memorial", "阵亡将士纪念日", 5, 1, -1),
            md("independence", "独立日", "07-04"),
            nth("labor", "劳工节", 9, 1, 1),
            md("veterans", "退伍军人节", "11-11"),
            nth("thanksgiving", "感恩节", 11, 4, 4),
        ]),
        Region(id: "uk", name: "英国", list: [
            easter("mothering", "母亲节", -21),
            easter("goodfriday", "耶稣受难日", -2),
            easter("easter", "复活节", 0),
            md("george", "圣乔治日", "04-23"),
            md("bonfire", "篝火之夜", "11-05"),
            md("remembrance", "国殇纪念日", "11-11"),
            md("boxing", "节礼日", "12-26"),
        ]),
    ]

    static let defaultRegions = ["intl", "cn"]

    // MARK: - 公历日期（不带时区）

    private static let utc = TimeZone(secondsFromGMT: 0) ?? .current

    private static let greg: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }()

    private static let chinese: Calendar = {
        var c = Calendar(identifier: .chinese)
        c.timeZone = utc
        return c
    }()

    /// 一个公历日子：加减天数用它，越过月底、年底自己进位（同 new Date(y, m - 1, d + n)）
    struct Day: Equatable, Hashable, Sendable {
        var year: Int
        var month: Int
        var day: Int

        var text: String { String(format: "%04d-%02d-%02d", year, month, day) }
        var md: String { String(format: "%02d-%02d", month, day) }

        static func parse(_ s: String) -> Day? {
            let p = s.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return Day(year: p[0], month: p[1], day: p[2])
        }
    }

    /// 那一天的正午（UTC）。用正午避开任何换算上的边界
    private static func noon(_ d: Day) -> Date? {
        guard let first = greg.date(from: DateComponents(year: d.year, month: d.month, day: 1, hour: 12)) else { return nil }
        return greg.date(byAdding: .day, value: d.day - 1, to: first)
    }

    private static func dayOf(_ date: Date) -> Day {
        let c = greg.dateComponents([.year, .month, .day], from: date)
        return Day(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    /// d 往后（负数往前）n 天
    static func shift(_ d: Day, _ n: Int) -> Day {
        guard let at = noon(d), let moved = greg.date(byAdding: .day, value: n, to: at) else { return d }
        return dayOf(moved)
    }

    /// 星期几，0 为周日（同 getDay）
    private static func weekday(_ d: Day) -> Int {
        guard let at = noon(d) else { return 0 }
        return greg.component(.weekday, from: at) - 1
    }

    private static func daysIn(year: Int, month: Int) -> Int {
        guard let at = noon(Day(year: year, month: month, day: 1)) else { return 30 }
        return greg.range(of: .day, in: .month, for: at)?.count ?? 30
    }

    // MARK: - 农历

    struct LunarDate: Equatable {
        var month: Int
        var day: Int
        var leap: Bool
    }

    static func lunarOf(_ d: Day) -> LunarDate? {
        guard let at = noon(d) else { return nil }
        let c = chinese.dateComponents([.month, .day], from: at)
        guard let m = c.month, let dd = c.day else { return nil }
        return LunarDate(month: m, day: dd, leap: c.isLeapMonth ?? false)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lunarYears: [Int: [String: [String]]] = [:]

    /// 一年里农历日期到公历的表，每年算一次。腊月的日子一年里可能有两回（一月一次、十二月一次），都记下
    private static func lunarTable(_ year: Int) -> [String: [String]] {
        lock.lock()
        if let t = lunarYears[year] { lock.unlock(); return t }
        lock.unlock()
        var t: [String: [String]] = [:]
        var d = Day(year: year, month: 1, day: 1)
        while d.year == year {
            if let l = lunarOf(d), !l.leap {
                t["\(l.month)-\(l.day)", default: []].append(d.text)
            }
            d = shift(d, 1)
        }
        lock.lock()
        lunarYears[year] = t
        lock.unlock()
        return t
    }

    private static let lunarMonths = ["", "正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
    private static let lunarDays = ["", "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]

    /// 农历几月几日的写法，界面上用：「农历腊月三十」「农历闰六月初一」
    static func lunarLabel(_ dateStr: String) -> String {
        guard let d = Day.parse(dateStr), let l = lunarOf(d) else { return "" }
        let m = lunarMonths.indices.contains(l.month) ? lunarMonths[l.month] : "\(l.month)"
        let dd = lunarDays.indices.contains(l.day) ? lunarDays[l.day] : "\(l.day)"
        return "农历\(l.leap ? "闰" : "")\(m)月\(dd)"
    }

    // MARK: - 其余几种规则

    private static func nthWeekday(_ year: Int, _ month: Int, _ wd: Int, _ n: Int) -> Day {
        if n > 0 {
            let first = Day(year: year, month: month, day: 1)
            let s = ((wd - weekday(first)) % 7 + 7) % 7
            return shift(first, s + (n - 1) * 7)
        }
        let last = Day(year: year, month: month, day: daysIn(year: year, month: month))
        let s = ((weekday(last) - wd) % 7 + 7) % 7
        return shift(last, -s)
    }

    /// 公历复活节（匿名格里历算法）
    private static func easterOf(_ year: Int) -> Day {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30, i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7, m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31, day = ((h + l - 7 * m + 114) % 31) + 1
        return Day(year: year, month: month, day: day)
    }

    /// 清明：21 世纪的节气公式
    private static func qingmingOf(_ year: Int) -> Day {
        let y = year % 100
        let day = Int((Double(y) * 0.2422 + 4.81).rounded(.down)) - y / 4
        return Day(year: year, month: 4, day: day)
    }

    /// 这个节日在某一年落在哪几天（'YYYY-MM-DD'，通常一天，腊月的可能两天）；算不出返回空数组
    static func datesOf(_ h: Rule, _ year: Int) -> [String] {
        if let md = h.md { return ["\(String(format: "%04d", year))-\(md)"] }
        if let l = h.lunar { return lunarTable(year)[l] ?? [] }
        if h.eve {
            // 正月初一的前一天，可能落在上一年的十二月里，所以连下一年的春节一起看
            let firsts = (lunarTable(year)["1-1"] ?? []) + (lunarTable(year + 1)["1-1"] ?? [])
            return firsts.compactMap(Day.parse).map { shift($0, -1) }.filter { $0.year == year }.map(\.text)
        }
        if let n = h.nth, n.count == 3 { return [nthWeekday(year, n[0], n[1], n[2]).text] }
        if let off = h.easter { return [shift(easterOf(year), off).text] }
        if h.qingming { return [qingmingOf(year).text] }
        return []
    }

    /// 某一年里的第一天，界面上写「今年哪一天」用
    static func dateOf(_ h: Rule, _ year: Int) -> String { datesOf(h, year).first ?? "" }

    // MARK: - 用户的选择

    struct Custom: Identifiable, Equatable {
        let id: String
        let name: String
        let month: Int
        let day: Int
        let lunar: Bool

        init?(_ v: JSONValue) {
            guard let o = v.object else { return nil }
            id = o["id"]?.string ?? ""
            name = o["name"]?.string ?? ""
            month = Custom.int(o["month"])
            day = Custom.int(o["day"])
            lunar = o["lunar"]?.bool ?? false
        }

        /// 网页版存的是数字；读到别的（文字、非有限数）按 0 算，不崩
        private static func int(_ v: JSONValue?) -> Int {
            let x = v?.number ?? Double(v?.string ?? "") ?? 0
            return x.isFinite && abs(x) < 10_000 ? Int(x.rounded()) : 0
        }

        var rule: Rule {
            lunar ? Rule(lunar: "\(month)-\(day)") : Rule(md: String(format: "%02d-%02d", month, day))
        }
    }

    struct Cfg {
        var regions: [String]
        var off: [String]
        var custom: [Custom]
    }

    /// 没存过（不是数组）时取默认，与网页版 cfg() 一致
    static func cfg(_ s: AppSettings) -> Cfg {
        Cfg(regions: s.raw["holidayRegions"]?.array.map { $0.compactMap(\.string) } ?? defaultRegions,
            off: s.raw["holidayOff"]?.array.map { $0.compactMap(\.string) } ?? [],
            custom: (s.raw["holidayCustom"]?.array ?? []).compactMap(Custom.init))
    }

    static func keyOf(_ regionId: String, _ h: Holiday) -> String { "\(regionId).\(h.id)" }
    static func regionOn(_ id: String, _ s: AppSettings) -> Bool { cfg(s).regions.contains(id) }
    static func itemOn(_ regionId: String, _ h: Holiday, _ s: AppSettings) -> Bool { !cfg(s).off.contains(keyOf(regionId, h)) }

    static func setRegion(_ id: String, _ on: Bool, _ s: inout AppSettings) {
        let r = cfg(s).regions.filter { $0 != id }
        s.raw["holidayRegions"] = .array((on ? r + [id] : r).map { JSONValue.string($0) })
    }

    static func setItem(_ regionId: String, _ h: Holiday, _ on: Bool, _ s: inout AppSettings) {
        let k = keyOf(regionId, h)
        let off = cfg(s).off.filter { $0 != k }
        s.raw["holidayOff"] = .array((on ? off : off + [k]).map { JSONValue.string($0) })
    }

    /// 自定义节日：每年重复。名称为空或日期无效时返回 nil、不写
    @discardableResult
    static func addCustom(name: String, month: Int, day: Int, lunar: Bool, _ s: inout AppSettings) -> Custom? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, (1...12).contains(month), (1...(lunar ? 30 : 31)).contains(day) else { return nil }
        let rand = (0..<3).map { _ in String(Int.random(in: 0..<36), radix: 36) }.joined()
        let id = "hd_\(String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36))\(rand)"
        let obj: JSONValue = .object(["id": .string(id), "name": .string(String(n.prefix(40))),
                                      "month": .number(Double(month)), "day": .number(Double(day)), "lunar": .bool(lunar)])
        // 原有的几条原样留着（不认得的字段不丢）
        s.raw["holidayCustom"] = .array((s.raw["holidayCustom"]?.array ?? []) + [obj])
        return Custom(obj)
    }

    static func removeCustom(_ id: String, _ s: inout AppSettings) {
        let list = s.raw["holidayCustom"]?.array ?? []
        s.raw["holidayCustom"] = .array(list.filter { $0.object?["id"]?.string != id })
    }

    struct Enabled {
        let name: String
        /// 地区名，通用与自定义为空
        let region: String
        let rule: Rule
    }

    /// 勾着的全部节日
    static func enabled(_ s: AppSettings) -> [Enabled] {
        let c = cfg(s)
        var out: [Enabled] = []
        for r in regions where c.regions.contains(r.id) {
            for h in r.list where !c.off.contains(keyOf(r.id, h)) {
                out.append(Enabled(name: h.name, region: r.id == "intl" ? "" : r.name, rule: h.rule))
            }
        }
        for x in c.custom { out.append(Enabled(name: x.name, region: "", rule: x.rule)) }
        return out
    }

    struct Hit: Equatable {
        let name: String
        let date: String
        let left: Int
    }

    /// 从 today 起 lead 天之内的节日，按天数排好。同一天同名的几个地区并成一条：「春节（中国、韩国）」
    static func around(_ today: Day, lead: Int = 3, _ s: AppSettings) -> [Hit] {
        var want: [String: Int] = [:]
        for i in 0...max(0, lead) { want[shift(today, i).text] = i }
        let years = Set(want.keys.compactMap { Int($0.prefix(4)) }).sorted()
        struct Acc { var name: String; var date: String; var left: Int; var regions: [String]; var plain: Bool }
        var keys: [String] = []
        var hits: [String: Acc] = [:]
        for h in enabled(s) {
            for yr in years {
                for at in datesOf(h.rule, yr) {
                    guard let left = want[at] else { continue }
                    let k = "\(at)|\(h.name)"
                    var cur = hits[k] ?? Acc(name: h.name, date: at, left: left, regions: [], plain: false)
                    if hits[k] == nil { keys.append(k) }
                    if !h.region.isEmpty {
                        if !cur.regions.contains(h.region) { cur.regions.append(h.region) }
                    } else { cur.plain = true }
                    hits[k] = cur
                }
            }
        }
        return keys.compactMap { hits[$0] }
            .map { x in Hit(name: x.plain || x.regions.isEmpty ? x.name : "\(x.name)（\(x.regions.joined(separator: "、"))）",
                            date: x.date, left: x.left) }
            .sorted { a, b in
                a.left != b.left ? a.left < b.left
                    : a.name.compare(b.name, locale: Locale(identifier: "en")) == .orderedAscending
            }
    }
}

// MARK: - 节日与纪念日（网页版 context/dates.js）

/// 当天与之后三天（用户定的）才出现，平时一个字都没有。只写「哪天是什么日子」，
/// 不写该怎么过、该不该提（第 16 条）。不调接口。
///
/// 纪念日从已有记录里取：两边的生日、在一起那一天（情侣空间）、空间里自己加的纪念日、这段对话第一条消息那一天。
/// 日期按该角色那边的时区算，和「现在几点」同一个钟。「现在几点」关掉时这一段也不给：日期本身就是时间。
extension Holidays {
    static let lead = 3

    struct Fact: Equatable {
        let text: String
        let left: Int
    }

    private static func ordinal(_ n: Int) -> String {
        let suffixes = ["th", "st", "nd", "rd"]
        if n % 100 >= 11 && n % 100 <= 13 { return "\(n)th" }
        let i = n % 10
        return "\(n)\(i < suffixes.count ? suffixes[i] : "th")"
    }

    private static func capFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    private static func sayWhen(_ subject: String, _ left: Int, _ date: String) -> String {
        if left == 0 { return "Today is \(subject)." }
        if left == 1 { return "Tomorrow is \(subject)." }
        return "\(capFirst(subject)) is in \(left) days, on \(date)."
    }

    /// 该角色那边的今天
    static func today(char: Character?, settings s: AppSettings, now real: Date) -> Day {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Clock.zone(Clock.charZone(char, s))
        let c = cal.dateComponents([.year, .month, .day], from: Clock.now(s, real: real))
        return Day(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// 本机日历上那一刻的月日与年（网页版 localMd：在一起那一天、第一条消息那一天按设备本地日期算）
    private static func localDay(_ ms: Double) -> Day {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(millis: ms))
        return Day(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// 这一段的全部事实。群聊里 char 是第一个成员（时区跟它走），生日按名字写
    static func facts(char: Character?, chat: Chat?, me: Persona?, settings s: AppSettings, now real: Date) -> [Fact] {
        let t = today(char: char, settings: s, now: real)
        let days = (0...lead).map { shift(t, $0) }
        var out: [Fact] = []
        let rawName = me?.row.string("name") ?? ""
        let userName = rawName.isEmpty ? "the user" : rawName

        for h in around(t, lead: lead, s) { out.append(Fact(text: sayWhen(h.name, h.left, h.date), left: h.left)) }

        func yearly(_ md: String, _ sinceYear: Int, _ subject: (Int) -> String) {
            guard !md.isEmpty else { return }
            for (left, d) in days.enumerated() where d.md == md {
                let n = sinceYear > 0 ? d.year - sinceYear : 0
                if sinceYear > 0 && n < 1 { continue }
                out.append(Fact(text: sayWhen(subject(n), left, d.text), left: left))
            }
        }

        // 群聊这一段全群共用一份，生日按名字写；单聊写「你的生日」
        let inGroup = chat?.isGroup ?? false
        if let chat, inGroup {
            for id in chat.characterIds {
                guard let c = (try? Repo.character(id)) ?? nil else { continue }
                let name = c.row.string("name")
                yearly(Badges.birthdayMd(c.row.string("birthday")), 0) { _ in "\(name)'s birthday" }
            }
        } else if let char {
            yearly(Badges.birthdayMd(char.row.string("birthday")), 0) { _ in "your birthday" }
        }
        if let me { yearly(Badges.birthdayMd(me.row.string("birthday")), 0) { _ in "\(userName)'s birthday" } }

        // 在一起那一天与第一条消息那一天只在单人会话里有意义
        if let chat, char != nil, !inGroup {
            if let start = chat.row.number("loveStartAt"), start > 0 {
                let s0 = localDay(start)
                yearly(s0.md, s0.year) { n in "the \(ordinal(n)) anniversary of the day you and \(userName) got together" }
            }
            let msgs = (try? Repo.messages(chatId: chat.id)) ?? []
            if let first = msgs.first(where: { $0.createdAt > 0 }) {
                let s0 = localDay(first.createdAt)
                yearly(s0.md, s0.year) { n in "the \(ordinal(n)) anniversary of your first message with \(userName)" }
            }
            // 情侣空间里自己加的日子。标题是用户写的，原样引出来
            let world = Clock.now(s, real: real)
            for it in Space.days(chat.id) {
                guard Space.nextAt(it, from: world) != nil else { continue }
                let left = Space.leftDays(it, from: world)
                if left < 0 || left > lead { continue }
                out.append(Fact(text: sayWhen("\"\(it.string("title"))\"", left, days[left].text), left: left))
            }
        }
        // 按天数排，同一天的保持先后
        return out.enumerated().sorted { a, b in
            a.element.left != b.element.left ? a.element.left < b.element.left : a.offset < b.offset
        }.map(\.element)
    }

    static func block(char: Character?, chat: Chat?, me: Persona?, settings s: AppSettings, now real: Date) -> String {
        guard Clock.enabled(s) else { return "" }
        let list = facts(char: char, chat: chat, me: me, settings: s, now: real)
        guard !list.isEmpty else { return "" }
        return "\n\n[节日与纪念日]\n" + list.map(\.text).joined(separator: "\n")
    }
}
