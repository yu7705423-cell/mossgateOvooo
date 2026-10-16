import SwiftUI

/// 主屏小组件的最后一批，照网页版搬：
/// - src/screens/home/decorWidgets.js：资料卡（ins-profile，ins 与 X 两种）、圆窗、唱片、月历、照片堆、照片与时间、对望（ins-days）、拱窗
/// - src/screens/home/mimicWidgets.js：推文、帖子、对话、日记（mm-*）
/// - src/screens/home/insWidgets.js：拍立得、胶片、快拍、九宫格、天气（ins-*）
/// - src/screens/home/zoneWidget.js：时差旋钮（zone-dial）
/// - src/screens/home/widgets.js：健康、相册、Love 日历
/// 网页版的自定义组件（custom，用户贴的 HTML）不搬：原生版没有那个沙盒。
///
/// 只读本机的库，不调接口、不联网：天气读当天日程里存下的那一份，歌曲封面只用存在本机的图。
/// 人设正文一个字都不露，资料卡只用签名（网页版第 6 条）。
/// 数据在各自的小视图里 .task(id: cell) 读：格子的设置改了就重读，会话、朋友圈变了也重读。
extension MoreWidgets {
    // MARK: - 登记

    private static func f2Img(_ key: String, _ label: String, _ desc: String = "", when: String = "") -> Field {
        Field(key: key, kind: "image", label: label, placeholder: desc, when: when)
    }
    private static func f2Text(_ key: String, _ label: String, _ placeholder: String, when: String = "") -> Field {
        Field(key: key, kind: "text", label: label, placeholder: placeholder, when: when)
    }
    /// 几个选项里挑一个：placeholder 写成「值:标签|值:标签」，第一个是没设时的那一档
    private static func f2Choice(_ key: String, _ label: String, _ items: String, when: String = "") -> Field {
        Field(key: key, kind: "choice", label: label, placeholder: items, when: when)
    }
    /// 开关，没设时是开着的（网页版 c[key] !== false）
    private static func f2Switch(_ key: String, _ label: String) -> Field {
        Field(key: key, kind: "switch", label: label, placeholder: "")
    }
    private static let f2Char = Field(key: "charId", kind: "char", label: "角色", placeholder: "不选则跟随最近聊过的角色")
    private static func f2Who(_ label: String) -> Field { Field(key: "who", kind: "who", label: label, placeholder: "") }
    private static func f2Tone(_ items: String = "paper:白|ink:黑|glass:半透明") -> Field { f2Choice("tone", "底色", items) }
    private static let f2Custom = "source=custom"

    static let more2: [Def] = [
        // decorWidgets.js
        Def(id: "ins-profile", label: "资料卡", desc: "角色的头像、名字、签名与几个数字，ins 或 X 主页的样子",
            sizes: [(4, 2)],
            fields: [f2Char, f2Choice("style", "样式", ":ins|x:X"), f2Img("banner", "横幅的图", when: "style=x"),
                     f2Text("handle", "@ 名", "留空则不显示", when: "style=x")],
            framed: false),
        Def(id: "dw-moon", label: "圆窗", desc: "一张图羽化成圆形，下面一句原句",
            sizes: [(2, 2)],
            fields: [f2Img("img", "圆窗里的图"), f2Text("text", "一句话", "留空则每天换一句原句"), f2Switch("kaomoji", "颜文字")],
            framed: false),
        Def(id: "dw-record", label: "唱片", desc: "一起听最近的那一首：歌名、进度与一起听的人",
            sizes: [(4, 2), (2, 2)], fields: [f2Img("img", "唱片中间的图", "不放则用歌曲的封面")], framed: false),
        Def(id: "dw-cal", label: "月历", desc: "一张照片配这个月的日历，今天加黑点",
            sizes: [(4, 2)], fields: [f2Img("img", "照片")], framed: false),
        Def(id: "dw-pile", label: "照片堆", desc: "一大一小两张照片错开叠放",
            sizes: [(2, 2)],
            fields: [f2Img("img", "后面那张"), f2Img("img2", "前面那张"), f2Text("text", "一行字", "留空则写今天的日期")],
            framed: false),
        Def(id: "dw-time", label: "照片与时间", desc: "一张照片铺满，左上角是时间与日期",
            sizes: [(4, 2), (2, 2)], fields: [f2Img("img", "照片")], framed: false),
        Def(id: "ins-days", label: "对望", desc: "两个头像与在一起的天数",
            sizes: [(2, 2), (4, 2)],
            fields: [f2Char, f2Img("imgA", "我这一侧的图", "不放则用我的头像"), f2Img("imgB", "角色这一侧的图", "不放则用角色的头像"),
                     Field(key: "since", kind: "date", label: "从哪天算起", placeholder: "从这段对话开始的那天算起"),
                     Field(key: "lang", kind: "lang", label: "文字", placeholder: "en")],
            framed: false),
        Def(id: "dw-arch", label: "拱窗", desc: "一张图裁成拱形，下面一行字",
            sizes: [(2, 2)], fields: [f2Img("img", "拱窗里的图"), f2Text("text", "一行字", "留空则每天换一句原句")], framed: false),
        // mimicWidgets.js
        Def(id: "mm-post", label: "推文", desc: "一条推文的样子。可接角色最新的朋友圈，或自己填",
            sizes: [(4, 2), (4, 3)],
            fields: [f2Choice("source", "内容", "data:最新动态|custom:自己填"), f2Who("谁的"),
                     f2Text("handle", "@ 后面的字", "留空则不显示"),
                     f2Text("text", "正文（自己填）", "留空则每天换一句原句", when: f2Custom),
                     f2Img("img", "配图（自己填，三行高时显示）", when: f2Custom),
                     f2Img("avatar", "头像（自己填）", "不放则用所选的人的头像", when: f2Custom),
                     f2Text("name", "名字（自己填）", "留空则用所选的人的名字", when: f2Custom),
                     f2Tone()],
            framed: false),
        Def(id: "mm-gram", label: "帖子", desc: "一张 ins 帖子的样子。可接角色最新一条带图的动态，或自己放图",
            sizes: [(4, 4), (2, 3)],
            fields: [f2Choice("source", "内容", "data:最新带图动态|custom:自己填"), f2Who("谁的"),
                     f2Img("img", "图片（自己填）", when: f2Custom),
                     f2Text("caption", "配文（自己填）", "留空则每天换一句原句", when: f2Custom),
                     f2Img("avatar", "头像（自己填）", "不放则用所选的人的头像", when: f2Custom),
                     f2Text("name", "名字（自己填）", "留空则用所选的人的名字", when: f2Custom),
                     f2Tone()],
            framed: false),
        Def(id: "mm-talk", label: "对话", desc: "Telegram 聊天的样子，显示和角色最近的几条消息",
            sizes: [(4, 2), (4, 3), (2, 2)],
            fields: [f2Char, f2Text("status", "名字下面的小字", "last seen recently"), f2Tone("glass:半透明|paper:白|ink:黑")],
            framed: false),
        Def(id: "mm-diary", label: "日记", desc: "iCity 日记的样子。可接角色或自己最新的一篇日记，或自己填",
            sizes: [(4, 2), (4, 3), (2, 2)],
            fields: [f2Choice("source", "内容", "data:最新日记|custom:自己填"), f2Who("谁的日记"),
                     f2Img("img", "小图（宽版显示）"),
                     f2Text("text", "正文（自己填）", "留空则每天换一句原句", when: f2Custom),
                     f2Text("by", "署名（自己填）", "留空则不显示", when: f2Custom),
                     f2Tone()],
            framed: false),
        // insWidgets.js
        Def(id: "ins-polaroid", label: "拍立得", desc: "一张照片加一行手写感的字",
            sizes: [(2, 2), (2, 3), (4, 3)],
            fields: [f2Img("cover", "照片"), f2Text("caption", "文字", "例如 a quiet sunday"), f2Switch("date", "显示日期"),
                     f2Choice("tilt", "摆放", ":端正|l:左倾|r:右倾")],
            framed: true),
        Def(id: "ins-film", label: "胶片", desc: "最近的几张照片排成一条底片",
            sizes: [(4, 1), (4, 2), (2, 1)],
            fields: [f2Choice("source", "照片来自", "album:相册|moments:朋友圈"), f2Text("label", "边上的字", "FILM 400")],
            framed: true),
        Def(id: "ins-stories", label: "快拍", desc: "一排头像，二十四小时内发过动态的带一圈",
            sizes: [(4, 1)], fields: [], framed: true),
        Def(id: "ins-grid", label: "九宫格", desc: "最近九张照片，像主页的格子",
            sizes: [(2, 2), (4, 4)], fields: [f2Choice("source", "照片来自", "moments:朋友圈|album:相册")], framed: true),
        Def(id: "ins-weather", label: "天气", desc: "角色所在城市今天的天气",
            sizes: [(2, 2), (2, 1)], fields: [f2Char], framed: true),
        // zoneWidget.js
        Def(id: "zone-dial", label: "时区", desc: "拨动表盘查看同一时刻各时区的时间，以及各时区里的角色；只选一个角色时显示该时段的日程",
            sizes: [(4, 2), (4, 4), (2, 2)],
            fields: [Field(key: "chars", kind: "chars", label: "显示哪些角色", placeholder: "")], framed: true),
        // widgets.js
        Def(id: "health", label: "健康", desc: "今天的睡眠、步数、喝水等几项，显示哪几项自己选",
            sizes: [(2, 1), (2, 2), (4, 1), (4, 2)],
            fields: [Field(key: "show", kind: "multi", label: "显示哪几项",
                           placeholder: "*sleep:睡眠|*steps:步数|*water:喝水|weight:体重|mood:心情|poop:排便")],
            framed: true),
        Def(id: "album", label: "相册", desc: "相册里最近存的几张图", sizes: [(2, 2), (4, 2), (2, 1)], fields: [], framed: true),
        Def(id: "love", label: "Love 日历", desc: "头像、一行字与这个月的日历",
            sizes: [(2, 2), (4, 4), (4, 3)],
            fields: [f2Img("cover", "图片"), f2Text("word", "文字", "Love"),
                     Field(key: "lang", kind: "lang", label: "星期与月份", placeholder: "en"), f2Switch("serif", "衬线字体")],
            framed: true),
    ]

    /// 这一批的本体；不是这一批的返回 nil
    static func view2(_ cell: Shell.Cell, home: HomeLook, open: @escaping (String) -> Void, openChat: @escaping (String) -> Void) -> AnyView? {
        switch cell.ref {
        case "ins-profile": return AnyView(ProfileW(cell: cell, home: home, open: open, openChat: openChat))
        case "dw-moon": return AnyView(MoonW(cell: cell, home: home))
        case "dw-record": return AnyView(RecordW(cell: cell, home: home, open: open, openChat: openChat))
        case "dw-cal": return AnyView(CalW(cell: cell, home: home, open: open))
        case "dw-pile": return AnyView(PileW(cell: cell, home: home))
        case "dw-time": return AnyView(PhotoTimeW(cell: cell, home: home))
        case "ins-days": return AnyView(PairW(cell: cell, home: home, open: open))
        case "dw-arch": return AnyView(ArchW(cell: cell, home: home))
        case "mm-post": return AnyView(PostW(cell: cell, home: home, open: open))
        case "mm-gram": return AnyView(GramW(cell: cell, home: home, open: open))
        case "mm-talk": return AnyView(TalkW(cell: cell, home: home, openChat: openChat))
        case "mm-diary": return AnyView(DiaryW(cell: cell, home: home, open: open))
        case "ins-polaroid": return AnyView(PolaroidW(cell: cell, home: home))
        case "ins-film": return AnyView(FilmW(cell: cell, home: home, open: open))
        case "ins-stories": return AnyView(StoriesW(cell: cell, home: home, open: open))
        case "ins-grid": return AnyView(GridW(cell: cell, home: home, open: open))
        case "ins-weather": return AnyView(WeatherW(cell: cell, home: home, open: open))
        case "zone-dial": return AnyView(ZoneW(cell: cell, home: home))
        case "health": return AnyView(HealthW(cell: cell, home: home, open: open))
        case "album": return AnyView(AlbumW(cell: cell, home: home, open: open))
        case "love": return AnyView(LoveW(cell: cell, home: home))
        default: return nil
        }
    }

    // MARK: - 读设置（网页版 { ...defaults, ...config }）

    /// 这一项的字符串；没写过用 def（写过空串就是空串）
    static func conf(_ cell: Shell.Cell, _ key: String, _ def: String = "") -> String {
        cell.config[key]?.string ?? def
    }

    /// 开关：没写过、写的不是 false 都算开着
    static func confOn(_ cell: Shell.Cell, _ key: String) -> Bool { cell.config[key]?.bool != false }

    /// 选项里的一项。on 是多选时没设过就选上的那几项
    struct Opt: Hashable {
        var value: String
        var label: String
        var on: Bool
    }

    /// 「值:标签|值:标签」拆开。值前面带 * 的是多选时默认选上的
    static func choices(_ spec: String) -> [Opt] {
        spec.split(separator: "|", omittingEmptySubsequences: true).map { part -> Opt in
            let s = String(part)
            var value = s
            var label = s
            if let i = s.firstIndex(of: ":") {
                value = String(s[s.startIndex..<i])
                label = String(s[s.index(after: i)...])
            }
            let on = value.hasPrefix("*")
            if on { value = String(value.dropFirst()) }
            return Opt(value: value, label: label, on: on)
        }
    }

    /// 这一项要不要显示：when 写成「键=值」，空的总是显示
    static func shows(_ f: Field, _ values: [String: String], defaults: [Field]) -> Bool {
        guard let eq = f.when.firstIndex(of: "=") else { return true }
        let key = String(f.when[f.when.startIndex..<eq])
        let want = String(f.when[f.when.index(after: eq)...])
        let def = defaults.first(where: { $0.key == key }).map { d in d.kind == "choice" ? (choices(d.placeholder).first?.value ?? "") : "" } ?? ""
        let cur = values[key] ?? def
        return cur == want
    }
}

// MARK: - 纯算的那几样（各组件共用，测试也读这里）

extension MoreWidgets {
    enum Calc {
        static let dayMs: Double = 86_400_000
        static let monthEN = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                              "November", "December"]
        static let monthShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        static let weekEN = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        static let weekZhFull = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]

        /// decoText.js 的 LINES_ZH，一字不改、顺序不改
        static let linesZH: [Line] = [
            Line(t: "身无彩凤双飞翼，心有灵犀一点通。", by: "李商隐"),
            Line(t: "两情若是久长时，又岂在朝朝暮暮。", by: "秦观"),
            Line(t: "但愿人长久，千里共婵娟。", by: "苏轼"),
            Line(t: "海上生明月，天涯共此时。", by: "张九龄"),
            Line(t: "执子之手，与子偕老。", by: "诗经"),
            Line(t: "蒹葭苍苍，白露为霜。所谓伊人，在水一方。", by: "诗经"),
            Line(t: "人生若只如初见。", by: "纳兰性德"),
            Line(t: "此情无计可消除，才下眉头，却上心头。", by: "李清照"),
            Line(t: "行到水穷处，坐看云起时。", by: "王维"),
            Line(t: "一蓑烟雨任平生。", by: "苏轼"),
            Line(t: "玲珑骰子安红豆，入骨相思知不知。", by: "温庭筠"),
            Line(t: "愿得一心人，白头不相离。", by: "卓文君"),
            Line(t: "采菊东篱下，悠然见南山。", by: "陶渊明"),
            Line(t: "长风破浪会有时，直挂云帆济沧海。", by: "李白"),
            Line(t: "春风十里扬州路，卷上珠帘总不如。", by: "杜牧"),
            Line(t: "曾经沧海难为水，除却巫山不是云。", by: "元稹"),
        ]

        /// decoText.js 的 KAOMOJI。只用不落在 emoji 区段里的字符
        static let kaomoji = [
            "(｡•ᴗ•｡)", "( ˘ω˘ )", "٩(ˊᗜˋ*)و", "(˶ᵔ ᵕ ᵔ˶)", "₍ᐢ. .ᐢ₎", "(=^･ω･^=)",
            "( ´ ▽ ` )", "(っ˘ڡ˘ς)", "(・∀・)", "o_O", "^_^", ":3", "(-_-) zzz", "( ･ᴗ･ )",
        ]

        /// decoText.js 的 lineOfDay(lang, salt)：zh、en，其余按中文在前、英文在后混排
        static func line(_ lang: String, _ salt: Int, _ d: Date = Date()) -> Line {
            let list = lang == "zh" ? linesZH : lang == "en" ? MoreWidgets.linesEN : linesZH + MoreWidgets.linesEN
            let n = MoreWidgets.seed(salt, d) % list.count
            return list[n < 0 ? n + list.count : n]
        }

        static func kaomojiOfDay(_ salt: Int, _ d: Date = Date()) -> String {
            let n = MoreWidgets.seed(salt, d) % kaomoji.count
            return kaomoji[n < 0 ? n + kaomoji.count : n]
        }

        static func pad(_ n: Int) -> String { n < 10 && n >= 0 ? "0\(n)" : "\(n)" }

        /// 1,234（en-US 的千分位）
        static func grouped(_ n: Int) -> String {
            let f = NumberFormatter()
            f.locale = Locale(identifier: "en_US")
            f.numberStyle = .decimal
            return f.string(from: NSNumber(value: n)) ?? String(n)
        }

        /// 资料卡的数字：一万起写「1.2万」（decorWidgets.js 的 short）
        static func shortWan(_ n: Int) -> String {
            n >= 10000 ? String(format: "%.1f万", Double(n) / 10000) : grouped(n)
        }

        /// 推文的数字：一千起写 K，一万起写万（mimicWidgets.js 的 short）
        static func shortK(_ n: Int) -> String {
            if n >= 10000 { return String(format: "%.1f万", Double(n) / 10000) }
            if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
            return String(n)
        }

        /// 自己填的那几条没有真的计数：按文字算一个固定的数（mimicWidgets.js 的 fakeCount，按 UTF-16 码元）
        static func fakeCount(_ text: String, _ k: Int, _ max: Int) -> Int {
            var h = k * 7919
            for u in text.utf16 { h = (h * 31 + Int(u)) % 100003 }
            return max > 0 ? h % max : 0
        }

        /// 推特那样的相对时间：now、5m、3h、2d，再久写 Oct 3
        static func ago(_ t: Double, now: Date = Date()) -> String {
            guard t > 0 else { return "" }
            let m = Int(floor((now.timeIntervalSince1970 * 1000 - t) / 60000))
            if m < 1 { return "now" }
            if m < 60 { return "\(m)m" }
            if m < 1440 { return "\(m / 60)h" }
            if m < 7 * 1440 { return "\(m / 1440)d" }
            let p = Day.parts(Date(millis: t))
            return "\(monthShort[p.m]) \(p.d)"
        }

        static func hhmm(_ t: Double) -> String {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date(millis: t))
            return "\(pad(c.hour ?? 0)):\(pad(c.minute ?? 0))"
        }

        /// 「2024-05-01」那天零点（本地时间），认不出来是 nil
        static func localDay(_ s: String) -> Date? {
            let p = s.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
            return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        }

        /// 这段对话从哪天开始：自己填了就按填的，否则按对话建立的那天（decorWidgets.js 的 startOf）。毫秒
        static func start(since: String, chatCreated: Double?) -> Double? {
            if !since.isEmpty, let d = localDay(since) { return d.timeIntervalSince1970 * 1000 }
            guard let c = chatCreated, c > 0 else { return nil }
            return c
        }

        /// 第几天：开始那天算第一天，没有开始的日子是 0（decorWidgets.js 的 daysFrom）
        static func daysFrom(_ start: Double?, now: Date = Date()) -> Int {
            guard let start else { return 0 }
            return Int(floor((now.timeIntervalSince1970 * 1000 - start) / dayMs)) + 1
        }

        /// 对话里能放上主屏的几条：双方的文字消息，出错的、撤回的、方括号标记开头的不要，取最后 n 条（mimicWidgets.js 的 chatLines）
        static func talkLines(_ all: [Message], _ n: Int, now: Date = Date()) -> [Message] {
            let ok = all.filter { m in
                m.kind == "text" && !m.isError && !m.isRecalled(at: now) && !m.content.isEmpty && !m.content.hasPrefix("[")
            }
            return Array(ok.suffix(max(0, n)))
        }

        /// 对话一次显示几条：三格高 5 条，四格宽 3 条，其余 2 条
        static func talkCount(w: Int, h: Int) -> Int { h >= 3 ? 5 : w >= 4 ? 3 : 2 }

        struct CalDay: Equatable {
            var n: Int
            var out: Bool
            var today: Bool
        }

        private static func daysIn(_ d: Date) -> Int {
            Calendar.current.range(of: .day, in: .month, for: d)?.count ?? 30
        }

        /// 月历（decorWidgets.js 的 CalendarBody）：周日开头，前后用上个月、下个月的日子补满整行
        static func monthGrid(_ now: Date) -> (rows: Int, cells: [CalDay]) {
            let t = Day.parts(now)
            let first1 = Day.date(t.y, t.m, 1)
            let first = Day.parts(first1).wd
            let days = daysIn(first1)
            let prevDay = Calendar.current.date(byAdding: .day, value: -1, to: first1) ?? first1
            let prev = daysIn(prevDay)
            let rows = (first + days + 6) / 7
            let cells = (0..<(rows * 7)).map { i -> CalDay in
                let d = i - first + 1
                if d < 1 { return CalDay(n: prev + d, out: true, today: false) }
                if d > days { return CalDay(n: d - days, out: true, today: false) }
                return CalDay(n: d, out: false, today: d == t.d)
            }
            return (rows, cells)
        }

        /// Love 日历（widgets.js 的 LoveBody）：小号只铺本周与下周两行，大号铺整月，空格是 nil
        static func loveDays(_ now: Date, compact: Bool) -> (rows: Int, cells: [CalDay?]) {
            let t = Day.parts(now)
            if compact {
                let today0 = Calendar.current.startOfDay(for: now)
                let sunday = Calendar.current.date(byAdding: .day, value: -t.wd, to: today0) ?? today0
                let cells = (0..<14).map { i -> CalDay? in
                    let d = Calendar.current.date(byAdding: .day, value: i, to: sunday) ?? sunday
                    let p = Day.parts(d)
                    return CalDay(n: p.d, out: p.m != t.m, today: p.m == t.m && p.d == t.d)
                }
                return (2, cells)
            }
            let first1 = Day.date(t.y, t.m, 1)
            let first = Day.parts(first1).wd
            let total = daysIn(first1)
            let rows = (first + total + 6) / 7
            var cells: [CalDay?] = Array(repeating: nil, count: first)
            for d in 1...max(1, total) { cells.append(CalDay(n: d, out: false, today: d == t.d)) }
            while cells.count < rows * 7 { cells.append(nil) }
            return (rows, cells)
        }

        /// 03:25（listen.js 的 clock）
        static func clock(_ sec: Double) -> String {
            let n = max(0, Int(sec.rounded()))
            return "\(pad(n / 60)):\(pad(n % 60))"
        }

        /// 挂件上写不下「7 小时 30 分」，缩成 7h30（widgets.js 的 shortSleep）
        static func shortSleep(_ min: Double) -> String {
            let m = max(0, Int(min.rounded()))
            guard m > 0 else { return "—" }
            let h = m / 60
            return h > 0 ? "\(h)h" + (m % 60 > 0 ? pad(m % 60) : "") : "\(m)m"
        }

        static let healthStats: [(id: String, label: String)] = [
            ("sleep", "睡眠"), ("steps", "步数"), ("water", "喝水"), ("weight", "体重"), ("mood", "心情"), ("poop", "排便"),
        ]
        static let healthDefault = ["sleep", "steps", "water"]

        /// 健康挂件上每一项的读数（widgets.js 的 healthValue）
        static func healthValue(_ id: String, _ d: Health.Day, weight: (Double) -> Double = { Health.toDisplay($0) }) -> String {
            switch id {
            case "sleep": return shortSleep(d.sleepMin)
            case "steps": return d.steps > 0 ? grouped(Int(d.steps.rounded())) : "—"
            case "water": return Weather.fmt(d.water)
            case "weight": return d.weight > 0 ? Weather.fmt(weight(d.weight)) : "—"
            case "mood":
                let l = Health.label(Health.moods, d.mood)
                return l.isEmpty ? "—" : l
            case "poop": return String(d.poops.count)
            default: return "—"
            }
        }

        // 时差旋钮（zoneWidget.js）

        /// 快 3 小时 30 分；同一时区是空串
        static func diffWord(_ m: Int) -> String {
            guard m != 0 else { return "" }
            let h = abs(m) / 60, mm = abs(m) % 60
            return "\(m > 0 ? "快" : "慢") \(h > 0 ? "\(h) 小时" : "")\(mm > 0 ? "\(mm) 分" : "")"
        }

        static func dayWord(_ d: Int) -> String { d > 0 ? "次日" : d < 0 ? "前一日" : "" }

        /// 表盘中间那行小字：没拨是「现在」，拨过是 +1:30 / -0:45
        static func dialOffset(_ value: Int) -> String {
            guard value != 0 else { return "现在" }
            return "\(value > 0 ? "+" : "-")\(abs(value) / 60):\(pad(abs(value) % 60))"
        }

        /// 拨过之后表盘上是当天第几分钟
        static func dialMinute(base: Int, value: Int) -> Int { (((base + value) % 1440) + 1440) % 1440 }

        /// 拖过的角度换成拨了几分钟：一圈 24 小时，按 15 分钟一档
        static func minutes(fromDegrees total: Double) -> Int {
            Int((total / 360 * 1440 / 15).rounded()) * 15
        }

        /// 时区的短名：「日本 · 东京」取「东京」，没登记的取 IANA 名最后一段
        static func shortZone(_ id: String) -> String {
            let real = Clock.resolve(id)
            let full = Clock.label(id)
            if full != real {
                let tail = full.components(separatedBy: "·").last ?? full
                let first = tail.trimmingCharacters(in: .whitespaces).components(separatedBy: "、").first ?? ""
                let s = first.trimmingCharacters(in: .whitespaces)
                return s.isEmpty ? full : s
            }
            return (real.components(separatedBy: "/").last ?? real).replacingOccurrences(of: "_", with: " ")
        }

        struct ZoneParts { var ymd: Int; var hour: Int; var minute: Int; var weekday: String }

        static func parts(_ at: Date, zone id: String) -> ZoneParts {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = Clock.zone(id)
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: at)
            let wd = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(0, min(6, (c.weekday ?? 1) - 1))]
            return ZoneParts(ymd: (c.year ?? 2000) * 10000 + (c.month ?? 1) * 100 + (c.day ?? 1), hour: c.hour ?? 0, minute: c.minute ?? 0, weekday: wd)
        }

        struct ZoneRow: Identifiable {
            var zone: String
            var me: Bool
            var chars: [Character]
            var place: String
            var time: String
            var night: Bool
            var day: Int
            var diff: Int
            var id: String { zone }
        }

        /// 要列的角色：挑了就是挑的那几个，没挑就是全部（不含 NPC 与分身）
        static func pickChars(_ ids: [String], all: [Character]) -> [Character] {
            let pool = all.filter { ($0.parentId ?? "").isEmpty && !$0.isNpc }
            guard !ids.isEmpty else { return pool }
            return ids.compactMap { id in pool.first(where: { $0.id == id }) }
        }

        /// 按时区分组：同一时刻钟面相同的放在一行。本人那一行总在最前，其余按时差从慢到快
        static func zoneRows(at: Date, chars: [Character], settings s: AppSettings) -> [ZoneRow] {
            let uz = Clock.userZone(s)
            let me = parts(at, zone: uz)
            var groups: [(zone: String, me: Bool, chars: [Character])] = [(uz, true, [])]
            for c in chars {
                let z = Clock.charZone(c, s)
                if let gi = groups.firstIndex(where: { Clock.zoneDiff($0.zone, z, at: at) == 0 }) {
                    groups[gi].chars.append(c)
                } else {
                    groups.append((z, false, [c]))
                }
            }
            let rows = groups.map { g -> ZoneRow in
                let p = parts(at, zone: g.zone)
                let d = p.ymd == me.ymd ? 0 : p.ymd > me.ymd ? 1 : -1
                return ZoneRow(zone: g.zone, me: g.me, chars: g.chars, place: shortZone(g.zone), time: "\(pad(p.hour)):\(pad(p.minute))",
                               night: p.hour < 6 || p.hour >= 19, day: d, diff: Clock.zoneDiff(g.zone, uz, at: at))
            }
            return rows.enumerated().sorted { a, b in
                if a.element.me != b.element.me { return a.element.me }
                if a.element.diff != b.element.diff { return a.element.diff < b.element.diff }
                return a.offset < b.offset
            }.map { $0.element }
        }
    }
}

// MARK: - 共用的小件

extension MoreWidgets {
    /// --dw-ring：照片外那一圈白边
    static func ring2(_ h: HomeLook) -> Color {
        switch (h.wallpaper, h.dark) {
        case (false, false): return .white
        case (false, true): return Color(white: 0.102)
        case (true, false): return Color.white.opacity(0.75)
        case (true, true): return Color.white.opacity(0.18)
        }
    }

    /// 借用界面那一组的三种底（tokens.css 的 --dc-*、--mm-*）。「半透明」只是半透明的底与一道细边，不做模糊
    struct Tone {
        var bg: Color
        var fg: Color
        var fg2: Color
        var line: Color
        var bubIn: Color
        var bubOut: Color
        var onOut: Color
        var border: Color

        static func of(_ name: String, _ h: HomeLook) -> Tone {
            let paper = h.dark
                ? Tone(bg: Color(white: 0.102), fg: .white, fg2: Color.white.opacity(0.55), line: Color.white.opacity(0.10),
                       bubIn: Color(white: 0.149), bubOut: .white, onOut: Color(white: 0.067), border: .clear)
                : Tone(bg: .white, fg: Color(white: 0.067), fg2: Color.black.opacity(0.46), line: Color.black.opacity(0.08),
                       bubIn: Color(white: 0.937), bubOut: Color(white: 0.067), onOut: .white, border: .clear)
            switch name {
            case "ink":
                return Tone(bg: h.dark ? .black : Color(white: 0.078), fg: .white, fg2: Color.white.opacity(0.58),
                            line: Color.white.opacity(0.12), bubIn: Color.white.opacity(0.12), bubOut: .white,
                            onOut: h.dark ? .black : Color(white: 0.078), border: h.dark ? Color(white: 0.122) : .clear)
            case "glass":
                var t = paper
                t.bg = h.dark ? Color(white: 0.078).opacity(0.55) : Color.white.opacity(0.62)
                t.border = h.dark ? Color.white.opacity(0.10) : Color.white.opacity(0.80)
                return t
            default:
                return paper
            }
        }
    }

    /// 借用界面那一组的卡（.mm-card）
    struct ToneCard: View {
        let tone: Tone
        var body: some View {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(tone.bg)
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(tone.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 11, y: 6)
        }
    }

    /// 一处平铺的小图，没有图时是一块淡底（ins 组的格子、相册的缩略图）
    struct Tile: View {
        let id: String
        let empty: Color
        var maxPixel: CGFloat = 300

        var body: some View {
            Color.clear
                .overlay {
                    if !id.isEmpty, MediaStore.url(.images, id: id) != nil {
                        LocalImage(id: id, maxPixel: maxPixel)
                    } else {
                        empty
                    }
                }
                .clipped()
        }
    }

    /// 本人：网页版 accounts.current 的名字，没起名时写「我」
    static func meName(_ p: Persona?) -> String {
        guard let p else { return "" }
        return p.row.string("name").isEmpty ? "我" : p.name
    }

    /// 'me' 是自己；'' 是最近聊过的角色；其余是角色 id（mimicWidgets.js 的 personOf）
    struct Who { var id: String; var name: String; var avatar: String }

    static func person(_ who: String, me: Persona?) -> Who? {
        if who == "me" {
            guard let me else { return nil }
            return Who(id: "me", name: meName(me), avatar: me.avatar)
        }
        guard let ch = Source.charOf(who, me: me?.id ?? "") else { return nil }
        return Who(id: ch.id, name: ch.displayName, avatar: ch.avatar)
    }

    /// 某人最新的一条动态（撤回的不算）
    static func latestMoment(_ authorId: String, withImage: Bool = false) -> Moments.Moment? {
        Moments.all().first(where: { $0.authorId == authorId && !$0.recalled && (!withImage || !$0.images.isEmpty) })
    }

    /// 朋友圈或相册里最近的几张图
    static func recentImages(fromMoments: Bool, _ n: Int) -> [String] {
        let ids: [String]
        if fromMoments {
            ids = Moments.all().filter { !$0.recalled }.flatMap(\.images)
        } else {
            ids = Album.all().map(\.imageId).filter { !$0.isEmpty }
        }
        return Array(ids.prefix(max(0, n)))
    }
}

fileprivate extension View {
    /// 网页版 .dw-card：铺满一格，圆角 24，--dw-card 的底与 --dw-shadow
    func dwCard2(_ home: HomeLook) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(MoreWidgets.DW.card(home))
                    .shadow(color: MoreWidgets.DW.shadow(home), radius: 5, y: 2)
            )
    }

    /// 带白边与淡影的照片框（.dw-pile-back、.dw-arch-pic 那一圈 3px 的 --dw-ring）
    func ringed<S: Shape>(_ shape: S, _ home: HomeLook) -> some View {
        self
            .clipShape(shape)
            .overlay(shape.stroke(MoreWidgets.ring2(home), lineWidth: 6).clipShape(shape))
            .background(shape.fill(MoreWidgets.ring2(home)).shadow(color: MoreWidgets.DW.shadow(home), radius: 5, y: 2))
    }
}

// MARK: - 资料卡（ins-profile）：ins 主页的头部，或 X 主页的头部

extension MoreWidgets {
    struct ProfileW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void
        var openChat: (String) -> Void

        struct Info {
            var name: String
            var sign: String
            var avatar: String
            var region: String
            var posts: Int
            var days: Int
            var msgs: Int
            var start: Double?
            var chatId: String
        }
        @State private var info: Info?
        @State private var loaded = false

        var body: some View {
            GeometryReader { g in
                let compact = g.size.height <= 160
                Group {
                    if let info {
                        if MoreWidgets.conf(cell, "style") == "x" {
                            xBody(info, compact: compact, w: g.size.width, h: g.size.height)
                        } else {
                            insBody(info, compact: compact)
                        }
                    } else if loaded {
                        Text("还没有角色").font(.system(size: 12)).foregroundStyle(DW.text3(home))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
            .dwCard2(home)
            .contentShape(Rectangle())
            .onTapGesture { if info != nil { open("chat") } }
            .task(id: cell) { load() }
            .onReceive(NotificationCenter.chatChangesSettled) { _ in load() }
            .onReceive(NotificationCenter.default.publisher(for: .eiraMomentsChanged)) { _ in load() }
        }

        private func insBody(_ i: Info, compact: Bool) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 18) {
                    RoundFace(id: i.avatar, size: compact ? 44 : 54)
                        .padding(3)
                        .overlay(Circle().strokeBorder(home.text, lineWidth: 1.5))
                    HStack(spacing: 0) {
                        stat(Calc.shortWan(i.posts), "动态", compact: compact)
                        stat(Calc.shortWan(i.days), "天", compact: compact)
                        stat(Calc.shortWan(i.msgs), "消息", compact: compact)
                    }
                }
                Text(i.name).font(.system(size: compact ? 13 : 14, weight: .semibold)).foregroundStyle(home.text)
                    .lineLimit(1).padding(.top, compact ? 4 : 6)
                if !i.sign.isEmpty {
                    Text(i.sign).font(.system(size: compact ? 11 : 12)).foregroundStyle(home.text).lineLimit(1).padding(.top, 2)
                }
                HStack(spacing: 6) {
                    pill("发消息", compact: compact) { if i.chatId.isEmpty { open("chat") } else { openChat(i.chatId) } }
                    pill("主页", compact: compact) { open("chat") }
                }
                .padding(.top, compact ? 6 : 8)
            }
            .padding(.horizontal, compact ? 16 : 18)
            .padding(.vertical, compact ? 10 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }

        private func stat(_ n: String, _ label: String, compact: Bool) -> some View {
            VStack(spacing: 0) {
                Text(n).font(.system(size: compact ? 15 : 17, weight: .semibold)).foregroundStyle(home.text).lineLimit(1)
                Text(label).font(.system(size: 11)).foregroundStyle(DW.text2(home)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }

        private func pill(_ title: String, compact: Bool, _ action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(title).font(.system(size: compact ? 11 : 12, weight: .semibold)).foregroundStyle(home.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 22 : 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DW.chip(home)))
            }
            .buttonStyle(.plain)
        }

        private func xBody(_ i: Info, compact: Bool, w: CGFloat, h: CGFloat) -> some View {
            let handle = MoreWidgets.conf(cell, "handle").replacingOccurrences(of: "^@", with: "", options: .regularExpression)
            let banner: CGFloat = compact ? 38 : 46
            let face: CGFloat = compact ? 40 : 46
            return ZStack(alignment: .topLeading) {
                PhotoFill(id: MoreWidgets.conf(cell, "banner"))
                    .frame(width: w, height: banner)
                RoundFace(id: i.avatar, size: face)
                    .padding(3)
                    .background(Circle().fill(DW.card(home)))
                    .offset(x: 14, y: compact ? 16 : 22)
                Text("已关注")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold)).foregroundStyle(home.text)
                    .padding(.horizontal, 14)
                    .frame(height: compact ? 22 : 26)
                    .overlay(Capsule().strokeBorder(DW.line(home), lineWidth: 1))
                    .padding(.trailing, 14)
                    .padding(.top, compact ? 44 : 54)
                    .frame(width: w, height: h, alignment: .topTrailing)
                VStack(alignment: .leading, spacing: 0) {
                    Text(i.name).font(.system(size: 15, weight: .bold)).foregroundStyle(home.text).lineLimit(1)
                    if !handle.isEmpty {
                        Text("@\(handle)").font(.system(size: 11)).foregroundStyle(DW.text2(home)).lineLimit(1)
                    }
                    if !compact && !i.sign.isEmpty {
                        Text(i.sign).font(.system(size: 12)).foregroundStyle(home.text).lineLimit(1).padding(.top, 2)
                    }
                    HStack(spacing: 12) {
                        if !i.region.isEmpty {
                            HStack(spacing: 3) { SvgIcon(name: "pin", size: 11, lineWidth: 2, color: DW.text2(home)); Text(i.region) }
                        }
                        if let s = i.start {
                            let p = Day.parts(Date(millis: s))
                            HStack(spacing: 3) {
                                SvgIcon(name: "calendar", size: 11, lineWidth: 2, color: DW.text2(home))
                                Text("\(String(p.y)) 年 \(p.m + 1) 月认识")
                            }
                        }
                        (Text(Calc.shortWan(i.posts)).fontWeight(.semibold).foregroundColor(home.text) + Text(" 动态"))
                    }
                    .font(.system(size: 11)).foregroundStyle(DW.text2(home)).lineLimit(1)
                    .padding(.top, 3)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
                .frame(width: w, height: h, alignment: .bottomLeading)
            }
            .frame(width: w, height: h, alignment: .topLeading)
        }

        private func load() {
            loaded = true
            let meId = Source.me()?.id ?? ""
            guard let ch = Source.charOf(MoreWidgets.conf(cell, "charId"), me: meId) else { info = nil; return }
            let chat = Source.chatWith(ch.id, me: meId)
            let posts = Moments.all().filter { $0.authorId == ch.id && !$0.recalled }.count
            let start = chat?.row.created
            let msgs = chat.map { c in (try? Database.shared.count(Collections.messages, where: c.id)) ?? 0 } ?? 0
            // 只用签名，不露人设（网页版第 6 条）
            info = Info(name: ch.displayName, sign: ch.signature, avatar: ch.avatar, region: ch.row.string("region"),
                        posts: posts, days: Calc.daysFrom(start), msgs: msgs, start: start, chatId: chat?.id ?? "")
        }
    }
}

// MARK: - 圆窗（dw-moon）：一张图羽化成圆，一句原句，一个颜文字

extension MoreWidgets {
    struct MoonW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            let custom = MoreWidgets.conf(cell, "text")
            let line = custom.isEmpty ? MoreWidgets.lineOfDay(MoreWidgets.saltOf(cell.id, 1)).t : custom
            let kao = MoreWidgets.confOn(cell, "kaomoji") ? Calc.kaomojiOfDay(MoreWidgets.saltOf(cell.id, 2)) : ""
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let d = w * (h <= 160 ? 0.68 : 0.76)
                ZStack {
                    PhotoFill(id: MoreWidgets.conf(cell, "img"))
                        .frame(width: d, height: d)
                        .clipShape(Circle())
                        .mask {
                            RadialGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.79),
                                                   .init(color: .clear, location: 1)],
                                           center: .center, startRadius: 0, endRadius: d / 2)
                        }
                        .position(x: w / 2, y: 2 + d / 2)
                    Spark(size: 14, x: w * 0.06 + 7, y: h * 0.06 + 7, color: home.text)
                    Spark(size: 9, x: w * 0.93 - 4.5, y: h * 0.12 + 4.5, color: home.text)
                    Spark(size: 10, x: w * 0.88 - 5, y: h * 0.60 + 5, color: home.text)
                    VStack(spacing: 1) {
                        Text(line).font(DW.italic(12)).foregroundStyle(DW.text2(home)).lineLimit(1)
                            .frame(maxWidth: w * 0.92)
                        if !kao.isEmpty {
                            Text(kao).font(.system(size: 11)).foregroundStyle(DW.text3(home)).lineLimit(1)
                        }
                    }
                    .frame(width: w, height: h, alignment: .bottom)
                }
                .frame(width: w, height: h)
            }
        }
    }
}

// MARK: - 唱片（dw-record）：一起听最近的那一首

extension MoreWidgets {
    struct RecordW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void
        var openChat: (String) -> Void

        @ObservedObject private var player = MusicPlayer.shared

        struct Last { var song: MusicLibrary.Song?; var at: Double; var chatId: String; var live: Bool }
        struct Who { var name: String; var meFace: String; var chFace: String }
        @State private var resume: Last?
        @State private var who: Who?

        /// 正在一起听就是这一首、这一秒；没在听就是上次停下的地方（哪段对话最近停的取哪段）。
        /// 播放器的几项只在 body 里读，再当参数往下传
        static func pick(liveChat: String?, current: MusicLibrary.Song?, seconds: Double, resume: Last?) -> Last? {
            if let liveChat, let current { return Last(song: current, at: seconds, chatId: liveChat, live: true) }
            return resume
        }

        var body: some View {
            let l = Self.pick(liveChat: player.listenChat, current: player.current, seconds: player.seconds, resume: resume)
            let spinning = l?.live == true && player.playing
            let duration = player.duration
            let wide = cell.w >= 4
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let compact = h <= 160
                ZStack(alignment: .topLeading) {
                    if wide {
                        let d = max(0, h - 32)
                        disc(l, size: d, spinning: spinning).position(x: 16 + d / 2, y: h / 2)
                        RecordArm(card: DW.card(home), ink: home.text)
                            .frame(width: 44, height: 60)
                            .position(x: w * 0.38 + 22, y: 6 + 30)
                        wideInfo(l, w: w, duration: duration)
                        if let who, l != nil {
                            HStack(spacing: 0) {
                                Text("和\(who.name)一起听").font(.system(size: 11)).foregroundStyle(DW.text3(home)).lineLimit(1)
                                    .padding(.trailing, 8)
                                face(who.meFace)
                                face(who.chFace).padding(.leading, -7)
                            }
                            .padding(.trailing, 16).padding(.bottom, 12)
                            .frame(width: w, height: h, alignment: .bottomTrailing)
                        }
                    } else {
                        let d = compact ? max(0, h - 58 - 10) : w * 0.62
                        disc(l, size: d, spinning: spinning).position(x: w / 2, y: (compact ? 10 : 14) + d / 2)
                        VStack(spacing: 0) {
                            Text(l?.song?.title ?? "一起听").font(.system(size: 15, design: .serif)).foregroundStyle(home.text).lineLimit(1)
                            Text(l?.song.map { $0.artist } ?? "还没有一起听过歌").font(DW.italic(11)).foregroundStyle(DW.text2(home)).lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, compact ? 8 : 12)
                        .frame(width: w, height: h, alignment: .bottom)
                    }
                }
                .frame(width: w, height: h)
            }
            .dwCard2(home)
            .contentShape(Rectangle())
            .onTapGesture { if let l, !l.chatId.isEmpty { openChat(l.chatId) } }
            .onAppear { load(liveChat: player.listenChat) }
            .onChange(of: cell) { _, _ in load(liveChat: player.listenChat) }
            .onChange(of: player.listenChat) { _, v in load(liveChat: v) }
            .onReceive(NotificationCenter.chatChangesSettled) { _ in load(liveChat: player.listenChat) }
        }

        private func face(_ id: String) -> some View {
            RoundFace(id: id, size: 22).overlay(Circle().strokeBorder(DW.card(home), lineWidth: 2))
        }

        @ViewBuilder private func wideInfo(_ l: Last?, w: CGFloat, duration: Double) -> some View {
            let secs = Double(l?.song?.seconds ?? 0)
            let tot = secs > 0 ? secs : (l?.live == true ? duration : 0)
            let at = min(tot > 0 ? tot : Double.greatestFiniteMagnitude, l?.at ?? 0)
            let pct = tot > 0 ? max(0, min(1, at / tot)) : 0
            VStack(alignment: .leading, spacing: 0) {
                Text(l?.live == true ? "NOW PLAYING" : "LAST PLAYED").font(.system(size: 9)).tracking(2).foregroundStyle(DW.text3(home))
                Text(l?.song?.title ?? "一起听").font(.system(size: 20, design: .serif)).foregroundStyle(home.text)
                    .lineLimit(1).padding(.top, 8)
                Text(l?.song.map { $0.artist } ?? "还没有一起听过歌").font(DW.italic(12)).foregroundStyle(DW.text2(home))
                    .lineLimit(1).padding(.top, 2)
                if l?.song != nil {
                    GeometryReader { b in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(DW.line(home)).frame(height: 2)
                            Rectangle().fill(home.text).frame(width: b.size.width * CGFloat(pct), height: 2)
                            Circle().fill(home.text).frame(width: 8, height: 8).offset(x: b.size.width * CGFloat(pct) - 4)
                        }
                        .frame(width: b.size.width, height: 8, alignment: .leading)
                    }
                    .frame(height: 8)
                    .padding(.top, 15)
                    HStack {
                        Text(Calc.clock(at))
                        Spacer(minLength: 0)
                        Text(Calc.clock(tot))
                    }
                    .font(.system(size: 9, design: .serif)).foregroundStyle(DW.text3(home))
                    .padding(.top, 3)
                }
            }
            .frame(width: max(0, w * 0.46 - 18), alignment: .leading)
            .padding(.top, 22)
            .offset(x: w * 0.54)
        }

        /// 黑胶：一圈圈细纹，中间一张图，正中一个小孔。正在一起听且在放时慢慢转
        private func disc(_ l: Last?, size d: CGFloat, spinning: Bool) -> some View {
            let custom = MoreWidgets.conf(cell, "img")
            let label = custom.isEmpty ? (l?.song?.row.string("coverId") ?? "") : custom
            return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning)) { ctx in
                let deg = spinning ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12) / 12 * 360 : 0
                ZStack {
                    Canvas { c, size in
                        let r = min(size.width, size.height) / 2
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        c.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                               with: .color(Color(white: 0.11)))
                        var k: CGFloat = 3
                        while k < r {
                            c.stroke(Path(ellipseIn: CGRect(x: center.x - k, y: center.y - k, width: k * 2, height: k * 2)),
                                     with: .color(Color(white: 0.165)), lineWidth: 1.5)
                            k += 3
                        }
                    }
                    PhotoFill(id: label, maxPixel: 300)
                        .frame(width: d * 0.42, height: d * 0.42)
                        .clipShape(Circle())
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                }
                .frame(width: d, height: d)
                .rotationEffect(.degrees(deg))
            }
            .frame(width: d, height: d)
            .shadow(color: .black.opacity(0.14), radius: 7, y: 4)
        }

        private func load(liveChat: String?) {
            resume = Self.lastResume()
            let chatId = liveChat ?? resume?.chatId ?? ""
            let chat = chatId.isEmpty ? nil : (try? Repo.chat(chatId)) ?? nil
            let ch = chat?.characterIds.first.flatMap { (try? Repo.character($0)) ?? nil }
            if let ch {
                who = Who(name: ch.displayName, meFace: Source.me()?.avatar ?? "", chFace: ch.avatar)
            } else {
                who = nil
            }
        }

        /// 上次停下的地方：网页版存在各段会话的 listenResume 里（备份导进来的也在），取最近存的那一份
        static func lastResume() -> Last? {
            var best: (row: [String: JSONValue], chatId: String, saved: Double)?
            for c in (try? Repo.chats()) ?? [] {
                guard let r = c.row["listenResume"]?.object, let sid = r["songId"]?.string, !sid.isEmpty else { continue }
                let saved = r["savedAt"]?.number ?? 0
                if best == nil || saved > (best?.saved ?? 0) { best = (r, c.id, saved) }
            }
            guard let best else { return nil }
            let sid = best.row["songId"]?.string ?? ""
            return Last(song: MusicLibrary.song(sid), at: best.row["at"]?.number ?? 0, chatId: best.chatId, live: false)
        }
    }

    /// 唱臂（decorWidgets.js 那段 svg，viewBox 48 x 64）
    struct RecordArm: View {
        let card: Color
        let ink: Color

        var body: some View {
            Canvas { c, size in
                let k = min(size.width / 48, size.height / 64)
                let ox = (size.width - 48 * k) / 2, oy = (size.height - 64 * k) / 2
                func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * k, y: oy + y * k) }
                var arm = Path()
                arm.move(to: pt(38, 8)); arm.addLine(to: pt(33, 42)); arm.addLine(to: pt(23, 53))
                c.stroke(arm, with: .color(ink), style: StrokeStyle(lineWidth: 2 * k, lineCap: .round, lineJoin: .round))
                let knob = Path(ellipseIn: CGRect(x: ox + 33 * k, y: oy + 3 * k, width: 10 * k, height: 10 * k))
                c.fill(knob, with: .color(card))
                c.stroke(knob, with: .color(ink), lineWidth: 1.6 * k)
                var head = c
                head.translateBy(x: ox + 21.5 * k, y: oy + 53 * k)
                head.rotate(by: .degrees(35))
                head.fill(Path(roundedRect: CGRect(x: -4.5 * k, y: -3 * k, width: 9 * k, height: 6 * k), cornerRadius: 1.5 * k),
                          with: .color(ink))
            }
            .accessibilityHidden(true)
        }
    }
}

// MARK: - 月历（dw-cal）：一张照片，月份，整月日历，今天加黑点

extension MoreWidgets {
    struct CalW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void

        var body: some View {
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                let t = Day.parts(ctx.date)
                let grid = Calc.monthGrid(ctx.date)
                GeometryReader { g in
                    let compact = g.size.height <= 160
                    HStack(spacing: 14) {
                        PhotoFill(id: MoreWidgets.conf(cell, "img"))
                            .frame(width: max(0, (g.size.width - 26) * 0.40))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(spacing: 0) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(Calc.monthEN[t.m]).font(.system(size: 20, design: .serif)).foregroundStyle(home.text).lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Spacer(minLength: 4)
                                Text(String(t.y)).font(.system(size: 11, design: .serif)).foregroundStyle(DW.text3(home))
                            }
                            .padding(.horizontal, 4).padding(.top, 2)
                            days(grid, compact: compact).padding(.top, compact ? 2 : 6)
                        }
                    }
                    .padding(.top, 12).padding(.bottom, 12).padding(.leading, 12).padding(.trailing, 14)
                    .frame(width: g.size.width, height: g.size.height)
                }
                .dwCard2(home)
            }
            .contentShape(Rectangle())
            .onTapGesture { open("daily") }
        }

        private func days(_ grid: (rows: Int, cells: [Calc.CalDay]), compact: Bool) -> some View {
            let dot: CGFloat = compact ? 16 : 18
            return VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(["S", "M", "T", "W", "T", "F", "S"][i]).font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DW.text3(home)).frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 2)
                ForEach(0..<grid.rows, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { c in
                            let i = r * 7 + c
                            let d = grid.cells.indices.contains(i) ? grid.cells[i] : Calc.CalDay(n: 0, out: true, today: false)
                            Text(String(d.n))
                                .font(.system(size: 11, design: .serif))
                                .foregroundStyle(d.today ? DW.card(home) : (d.out ? DW.text3(home) : DW.text2(home)))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: dot, height: dot)
                                .background(Circle().fill(d.today ? home.text : Color.clear))
                                .opacity(d.out ? 0.5 : 1)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 照片堆（dw-pile）：一大一小两张错开叠放，下面一行字

extension MoreWidgets {
    struct PileW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            let t = Day.parts(Date())
            let custom = MoreWidgets.conf(cell, "text")
            let text = custom.isEmpty ? "\(Calc.pad(t.d)) . \(Calc.pad(t.m + 1)) . \(String(t.y))" : custom
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let back = w * 0.66, front = w * 0.56
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                ZStack {
                    PhotoFill(id: MoreWidgets.conf(cell, "img"), maxPixel: 500)
                        .frame(width: back, height: back)
                        .ringed(shape, home)
                        .position(x: w * 0.04 + back / 2, y: h * 0.02 + back / 2)
                    PhotoFill(id: MoreWidgets.conf(cell, "img2"), maxPixel: 500)
                        .frame(width: front, height: front)
                        .ringed(shape, home)
                        .shadow(color: .black.opacity(0.10), radius: 7, y: 4)
                        .position(x: w * 0.96 - front / 2, y: h * 0.27 + front / 2)
                    Text(text).font(DW.italic(11)).foregroundStyle(DW.text2(home)).lineLimit(1)
                        .padding(.horizontal, w * 0.08)
                        .padding(.bottom, 4)
                        .frame(width: w, height: h, alignment: .bottomLeading)
                }
                .frame(width: w, height: h)
            }
        }
    }
}

// MARK: - 照片与时间（dw-time）：照片铺满，左上角白色的时间与日期

extension MoreWidgets {
    struct PhotoTimeW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                let t = Day.parts(ctx.date)
                let c = Calendar.current.dateComponents([.hour, .minute], from: ctx.date)
                let wide = cell.w >= 4
                ZStack(alignment: .topLeading) {
                    PhotoFill(id: MoreWidgets.conf(cell, "img"))
                    LinearGradient(stops: [.init(color: .black.opacity(0.30), location: 0), .init(color: .clear, location: 0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Calc.pad(c.hour ?? 0)):\(Calc.pad(c.minute ?? 0))")
                            .font(DW.thin(wide ? 56 : 40).monospacedDigit()).tracking(-1)
                            .foregroundStyle(.white).lineLimit(1)
                        Text("\(Calc.weekEN[t.wd]), \(Calc.monthEN[t.m]) \(t.d)")
                            .font(DW.italic(wide ? 12 : 11)).foregroundStyle(.white).lineLimit(1)
                            .padding(.leading, 2)
                    }
                    .padding(.leading, wide ? 18 : 14)
                    .padding(.top, wide ? 10 : 8)
                }
                .dwCard2(home)
            }
        }
    }
}

// MARK: - 对望（ins-days）：两个头像相交，名字，在一起的天数

extension MoreWidgets {
    struct PairW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void

        @State private var meName = "我"
        @State private var chName = "角色"
        @State private var left = ""
        @State private var right = ""
        @State private var start: Double?
        @State private var hasChar = false

        var body: some View {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let n = Calc.daysFrom(start, now: ctx.date)
                let zh = MoreWidgets.conf(cell, "lang", "en") == "zh"
                GeometryReader { g in
                    let compact = g.size.height <= 160
                    let f: CGFloat = compact ? 50 : 64
                    VStack(spacing: 0) {
                        HStack(spacing: -14) {
                            face(left, f)
                            face(right, f)
                        }
                        (Text(meName) + Text(" & ").italic().foregroundColor(DW.text3(home)) + Text(chName))
                            .font(.system(size: compact ? 11 : 12, design: .serif)).foregroundStyle(DW.text2(home))
                            .lineLimit(1)
                            .padding(.top, compact ? 4 : 6)
                        Text(n != 0 ? String(n) : "—").font(DW.thin(compact ? 28 : 40)).foregroundStyle(home.text).lineLimit(1)
                            .padding(.top, compact ? 2 : 4)
                        Text(zh ? "在一起的天数" : "days together").font(DW.italic(11)).foregroundStyle(DW.text3(home)).lineLimit(1)
                            .padding(.top, 3)
                    }
                    .padding(10)
                    .frame(width: g.size.width, height: g.size.height)
                }
                .dwCard2(home)
            }
            .contentShape(Rectangle())
            .onTapGesture { if hasChar { open("chat") } }
            .task(id: cell) { load() }
            .onReceive(NotificationCenter.chatChangesSettled) { _ in load() }
        }

        private func face(_ id: String, _ size: CGFloat) -> some View {
            RoundFace(id: id, size: size)
                .overlay(Circle().strokeBorder(MoreWidgets.ring2(home), lineWidth: 3))
                .shadow(color: DW.shadow(home), radius: 5, y: 2)
        }

        private func load() {
            let me = Source.me()
            let ch = Source.charOf(MoreWidgets.conf(cell, "charId"), me: me?.id ?? "")
            hasChar = ch != nil
            meName = me.map { MoreWidgets.meName($0) } ?? "我"
            chName = ch?.displayName ?? "角色"
            let a = MoreWidgets.conf(cell, "imgA"), b = MoreWidgets.conf(cell, "imgB")
            left = a.isEmpty ? (me?.avatar ?? "") : a
            right = b.isEmpty ? (ch?.avatar ?? "") : b
            let chat = ch.flatMap { Source.chatWith($0.id, me: me?.id ?? "") }
            start = Calc.start(since: MoreWidgets.conf(cell, "since"), chatCreated: chat?.row.created)
        }
    }
}

// MARK: - 拱窗（dw-arch）：拱形照片，一行字

extension MoreWidgets {
    struct ArchW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            let custom = MoreWidgets.conf(cell, "text")
            let line = custom.isEmpty ? MoreWidgets.lineOfDay(MoreWidgets.saltOf(cell.id, 3)).t : custom
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let pw = w * 0.70
                let ph = max(0, h - (h <= 160 ? 22 : 24))
                let top = max(0, min(pw / 2, ph - 8))
                let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: 8, bottomTrailingRadius: 8,
                                                   topTrailingRadius: top, style: .continuous)
                ZStack {
                    PhotoFill(id: MoreWidgets.conf(cell, "img"))
                        .frame(width: pw, height: ph)
                        .ringed(shape, home)
                        .position(x: w / 2, y: ph / 2)
                    Spark(size: 13, x: w * 0.04 + 6.5, y: h * 0.14 + 6.5, color: home.text)
                    Spark(size: 9, x: w * 0.94 - 4.5, y: h * 0.64 + 4.5, color: home.text)
                    Text(line).font(DW.italic(12)).foregroundStyle(DW.text2(home)).lineLimit(1)
                        .frame(maxWidth: w * 0.92)
                        .padding(.bottom, 4)
                        .frame(width: w, height: h, alignment: .bottom)
                }
                .frame(width: w, height: h)
            }
        }
    }
}

// MARK: - 推文（mm-post）

extension MoreWidgets {
    struct PostW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void

        struct Got {
            var name = ""
            var handle = ""
            var when = ""
            var text = ""
            var face = ""
            var img = ""
            var counts = [0, 0, 0, 0]
            var tappable = false
        }
        @State private var got = Got()

        var body: some View {
            let tone = Tone.of(MoreWidgets.conf(cell, "tone", "paper"), home)
            let tall = cell.h >= 3
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    RoundFace(id: got.face, size: 36)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(got.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(tone.fg).lineLimit(1)
                        if !got.handle.isEmpty {
                            Text("@\(got.handle)").font(.system(size: 14)).foregroundStyle(tone.fg2).lineLimit(1)
                        }
                        Text("· \(got.when)").font(.system(size: 14)).foregroundStyle(tone.fg2).lineLimit(1).fixedSize()
                    }
                }
                Text(got.text).font(.system(size: 14)).foregroundStyle(tone.fg).lineSpacing(3)
                    .lineLimit(tall ? 3 : 2).padding(.top, 6)
                if tall && !got.img.isEmpty {
                    PhotoFill(id: got.img)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tone.line, lineWidth: 1))
                        .padding(.top, 8)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    item("message", got.counts[0], tone)
                    Spacer(minLength: 0)
                    item("refresh", got.counts[1], tone)
                    Spacer(minLength: 0)
                    item("heart", got.counts[2], tone)
                    Spacer(minLength: 0)
                    item("eye", got.counts[3], tone)
                }
                .padding(.top, 8)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(ToneCard(tone: tone))
            .contentShape(Rectangle())
            .onTapGesture { if got.tappable { open("chat") } }
            .task(id: cell) { load() }
            .onReceive(NotificationCenter.default.publisher(for: .eiraMomentsChanged)) { _ in load() }
            .onReceive(NotificationCenter.chatChangesSettled) { _ in load() }
        }

        private func item(_ icon: String, _ n: Int, _ tone: Tone) -> some View {
            HStack(spacing: 5) {
                SvgIcon(name: icon, size: 14, color: tone.fg2)
                Text(n > 0 ? Calc.shortK(n) : "").font(.system(size: 12)).foregroundStyle(tone.fg2).lineLimit(1)
            }
            .frame(minWidth: 40, alignment: .leading)
        }

        private func load() {
            let me = Source.me()
            let p = MoreWidgets.person(MoreWidgets.conf(cell, "who"), me: me)
            let mine = MoreWidgets.conf(cell, "source", "data") == "custom"
            let mo = !mine ? p.flatMap { MoreWidgets.latestMoment($0.id) } : nil
            var g = Got()
            if mine {
                let own = MoreWidgets.conf(cell, "text")
                g.text = own.isEmpty ? Calc.line(MoreWidgets.conf(cell, "lang", "mix"), MoreWidgets.saltOf(cell.id, 11)).t : own
                g.img = MoreWidgets.conf(cell, "img")
                g.counts = [Calc.fakeCount(g.text, 1, 90), Calc.fakeCount(g.text, 2, 300), Calc.fakeCount(g.text, 3, 3000),
                            Calc.fakeCount(g.text, 4, 40000)]
                let w = MoreWidgets.conf(cell, "when")
                g.when = w.isEmpty ? "now" : w
                let n = MoreWidgets.conf(cell, "name")
                g.name = n.isEmpty ? (p?.name ?? "") : n
                let a = MoreWidgets.conf(cell, "avatar")
                g.face = a.isEmpty ? (p?.avatar ?? "") : a
            } else {
                if let mo, !mo.text.isEmpty { g.text = mo.text } else { g.text = p != nil ? "还没有发过动态" : "还没有角色" }
                g.img = mo?.images.first ?? ""
                let repost = mo.map { m in m.row["repost"].map { $0 != .null && $0 != .bool(false) } ?? false } ?? false
                g.counts = [mo?.comments.count ?? 0, repost ? 1 : 0, mo?.likes.count ?? 0, 0]
                g.when = Calc.ago(mo?.createdAt ?? 0)
                g.name = p?.name ?? ""
                g.face = p?.avatar ?? ""
                g.tappable = mo != nil
            }
            g.handle = MoreWidgets.conf(cell, "handle").replacingOccurrences(of: "^@", with: "", options: .regularExpression)
            got = g
        }
    }
}

// MARK: - 帖子（mm-gram）

extension MoreWidgets {
    struct GramW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void

        struct Got { var name = ""; var face = ""; var img = ""; var caption = ""; var likes = 0; var tappable = false }
        @State private var got = Got()

        var body: some View {
            let tone = Tone.of(MoreWidgets.conf(cell, "tone", "paper"), home)
            let big = cell.w >= 4
            let icon: CGFloat = big ? 20 : 16
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    RoundFace(id: got.face, size: big ? 28 : 22)
                    Text(got.name).font(.system(size: big ? 13 : 12, weight: .semibold)).foregroundStyle(tone.fg).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SvgIcon(name: "more", size: 16, color: tone.fg2)
                }
                .padding(.horizontal, big ? 12 : 10)
                .padding(.vertical, big ? 10 : 7)
                PhotoFill(id: got.img)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: big ? 12 : 10) {
                    SvgIcon(name: "heart", size: icon, color: tone.fg)
                    SvgIcon(name: "message", size: icon, color: tone.fg)
                    SvgIcon(name: "send", size: icon, color: tone.fg)
                    Spacer(minLength: 0)
                    SvgIcon(name: "bookmark", size: icon, color: tone.fg)
                }
                .padding(.horizontal, big ? 12 : 10)
                .padding(.top, big ? 10 : 7)
                .padding(.bottom, big ? 4 : 2)
                Text("\(Calc.grouped(got.likes)) likes").font(.system(size: big ? 13 : 12, weight: .semibold)).foregroundStyle(tone.fg)
                    .lineLimit(1)
                    .padding(.horizontal, big ? 12 : 10)
                    .padding(.bottom, big && !got.caption.isEmpty ? 0 : 8)
                if big && !got.caption.isEmpty {
                    (Text(got.name).fontWeight(.semibold) + Text(" " + got.caption))
                        .font(.system(size: 13)).foregroundStyle(tone.fg).lineLimit(1)
                        .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(ToneCard(tone: tone))
            .contentShape(Rectangle())
            .onTapGesture { if got.tappable { open("chat") } }
            .task(id: cell) { load() }
            .onReceive(NotificationCenter.default.publisher(for: .eiraMomentsChanged)) { _ in load() }
            .onReceive(NotificationCenter.chatChangesSettled) { _ in load() }
        }

        private func load() {
            let p = MoreWidgets.person(MoreWidgets.conf(cell, "who"), me: Source.me())
            let mine = MoreWidgets.conf(cell, "source", "data") == "custom"
            var g = Got()
            if mine {
                let own = MoreWidgets.conf(cell, "caption")
                g.caption = own.isEmpty ? Calc.line(MoreWidgets.conf(cell, "lang", "en"), MoreWidgets.saltOf(cell.id, 12)).t : own
                g.img = MoreWidgets.conf(cell, "img")
                g.likes = Calc.fakeCount(g.caption, 5, 5000)
                let n = MoreWidgets.conf(cell, "name")
                g.name = n.isEmpty ? (p?.name ?? "") : n
                let a = MoreWidgets.conf(cell, "avatar")
                g.face = a.isEmpty ? (p?.avatar ?? "") : a
            } else {
                let mo = p.flatMap { MoreWidgets.latestMoment($0.id, withImage: true) }
                g.img = mo?.images.first ?? ""
                g.caption = mo?.text ?? ""
                g.likes = mo?.likes.count ?? 0
                g.name = p?.name ?? ""
                g.face = p?.avatar ?? ""
                g.tappable = mo != nil
            }
            got = g
        }
    }
}

// MARK: - 对话（mm-talk）：Telegram 那样的顶栏与最近几条气泡

extension MoreWidgets {
    struct TalkW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var openChat: (String) -> Void

        struct Bubble: Identifiable { var id: Int; var me: Bool; var text: String; var at: Double }
        @State private var name = ""
        @State private var face = ""
        @State private var chatId = ""
        @State private var lines: [Bubble] = []

        var body: some View {
            let tone = Tone.of(MoreWidgets.conf(cell, "tone", "glass"), home)
            let wide = cell.w >= 4
            let status = MoreWidgets.conf(cell, "status")
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    RoundFace(id: face, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name.isEmpty ? "对话" : name).font(.system(size: 13, weight: .semibold)).foregroundStyle(tone.fg).lineLimit(1)
                        Text(status.isEmpty ? "last seen recently" : status).font(.system(size: 11)).foregroundStyle(tone.fg2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Rectangle().fill(tone.line).frame(height: 1)
                VStack(spacing: 5) {
                    Spacer(minLength: 0)
                    ForEach(lines) { l in bubble(l, tone: tone, wide: wide) }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(ToneCard(tone: tone))
            .contentShape(Rectangle())
            .onTapGesture { if !chatId.isEmpty { openChat(chatId) } }
            .task(id: cell) { load() }
            .onReceive(NotificationCenter.chatChangesSettled) { _ in load() }
        }

        private func bubble(_ l: Bubble, tone: Tone, wide: Bool) -> some View {
            let shape = UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: l.me ? 14 : 4,
                                               bottomTrailingRadius: l.me ? 4 : 14, topTrailingRadius: 14, style: .continuous)
            return HStack(alignment: .bottom, spacing: 6) {
                Text(l.text).font(.system(size: wide ? 13 : 12)).lineLimit(2)
                HStack(spacing: 2) {
                    Text(Calc.hhmm(l.at)).font(.system(size: 9))
                    if l.me { SvgIcon(name: "check", size: 11, color: tone.onOut) }
                }
                .opacity(0.6)
                .fixedSize()
            }
            .foregroundStyle(l.me ? tone.onOut : tone.fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(shape.fill(l.me ? tone.bubOut : tone.bubIn))
            .padding(l.me ? .leading : .trailing, wide ? 44 : 10)
            .frame(maxWidth: .infinity, alignment: l.me ? .trailing : .leading)
        }

        private func load() {
            let meId = Source.me()?.id ?? ""
            let ch = Source.charOf(MoreWidgets.conf(cell, "charId"), me: meId)
            let chat = ch.flatMap { Source.chatWith($0.id, me: meId) }
            name = ch?.displayName ?? ""
            face = ch?.avatar ?? ""
            chatId = chat?.id ?? ""
            let all = chat.map { c in (try? Repo.messages(chatId: c.id)) ?? [] } ?? []
            let got = Calc.talkLines(all, Calc.talkCount(w: cell.w, h: cell.h))
            if got.isEmpty {
                // 还没有聊过：两个颜文字占住位置
                let now = Date().timeIntervalSince1970 * 1000
                lines = [Bubble(id: 0, me: false, text: Calc.kaomojiOfDay(MoreWidgets.saltOf(cell.id, 13)), at: now),
                         Bubble(id: 1, me: true, text: Calc.kaomojiOfDay(MoreWidgets.saltOf(cell.id, 14)), at: now)]
            } else {
                lines = got.enumerated().map { i, m in Bubble(id: i, me: m.role == .user, text: m.content, at: m.createdAt) }
            }
        }
    }
}

// MARK: - 日记（mm-diary）：大号日期、正文、一张小图、署名

extension MoreWidgets {
    struct DiaryW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void

        struct Got { var date = Date(); var title = ""; var text = ""; var locked = false; var by = ""; var tappable = false }
        @State private var got = Got()

        var body: some View {
            let tone = Tone.of(MoreWidgets.conf(cell, "tone", "paper"), home)
            let wide = cell.w >= 4
            let p = Day.parts(got.date)
            let img = MoreWidgets.conf(cell, "img")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(Calc.pad(p.d)).font(Theme.serif(wide ? 40 : 28)).foregroundStyle(tone.fg).lineLimit(1)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Calc.monthShort[p.m].uppercased()) \(String(p.y))").font(.system(size: 11)).tracking(0.5)
                            .foregroundStyle(tone.fg).lineLimit(1)
                        Text(Calc.weekZhFull[p.wd] + (!got.title.isEmpty && !got.locked ? " · \(got.title)" : ""))
                            .font(.system(size: 11)).tracking(0.5).foregroundStyle(tone.fg2).lineLimit(1)
                    }
                }
                .padding(.bottom, 8)
                Rectangle().fill(tone.line).frame(height: 1)
                HStack(alignment: .top, spacing: 12) {
                    Text(got.text).font(Theme.serif(wide ? 13 : 12)).foregroundStyle(got.locked ? tone.fg2 : tone.fg)
                        .lineSpacing(wide ? 8 : 7).lineLimit(wide ? 2 : 3)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    if wide && !img.isEmpty {
                        PhotoFill(id: img, maxPixel: 300)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(.top, 8)
                Spacer(minLength: 0)
                if !got.by.isEmpty {
                    Text("— \(got.by)").font(.system(size: 11)).foregroundStyle(tone.fg2).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(ToneCard(tone: tone))
            .contentShape(Rectangle())
            .onTapGesture { if got.tappable { open("diary") } }
            .task(id: cell) { load() }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in load() }
        }

        private func load() {
            let me = Source.me()
            let mine = MoreWidgets.conf(cell, "source", "data") == "custom"
            let who = MoreWidgets.conf(cell, "who")
            let ch = !mine && who != "me" ? Source.charOf(who, me: me?.id ?? "") : nil
            var list: [Diary.Entry] = []
            if !mine {
                if who == "me" {
                    list = (try? Diary.mine()) ?? []
                } else if let ch {
                    list = (try? Diary.ofChar(ch.id)) ?? []
                }
            }
            let d = list.first
            var g = Got()
            g.locked = d?.locked ?? false
            g.date = d.flatMap { Calc.localDay($0.date) } ?? Date()
            g.title = d?.title ?? ""
            if mine {
                let own = MoreWidgets.conf(cell, "text")
                g.text = own.isEmpty ? Calc.line(MoreWidgets.conf(cell, "lang", "zh"), MoreWidgets.saltOf(cell.id, 15)).t : own
                g.by = MoreWidgets.conf(cell, "by")
            } else {
                g.text = d == nil ? "还没有写过日记" : g.locked ? "这一篇已上锁" : (d?.text ?? "")
                g.by = who == "me" ? MoreWidgets.meName(me) : (ch?.displayName ?? "")
                g.tappable = d != nil
            }
            got = g
        }
    }
}

// MARK: - 拍立得（ins-polaroid）

extension MoreWidgets {
    struct PolaroidW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            let id = MoreWidgets.conf(cell, "cover")
            let has = !id.isEmpty && MediaStore.url(.images, id: id) != nil
            let caption = MoreWidgets.conf(cell, "caption")
            let shown = caption.isEmpty ? (has ? "" : "长按主屏编辑，放一张照片") : caption
            let tall = cell.h >= 3
            let tilt = MoreWidgets.conf(cell, "tilt")
            let at = cell.config["at"]?.number ?? Date().timeIntervalSince1970 * 1000
            let p = Day.parts(Date(millis: at))
            GeometryReader { g in
                let pw = g.size.width, ph = g.size.height
                VStack(spacing: 0) {
                    Color(white: 0.937)
                        .overlay {
                            if has {
                                LocalImage(id: id, maxPixel: 900)
                            } else {
                                SvgIcon(name: "image", size: 22, color: Color.black.opacity(0.45))
                            }
                        }
                        .clipped()
                    VStack(spacing: 1) {
                        Text(shown).font(.system(size: 14, design: .serif).italic()).foregroundStyle(Color.black)
                            .multilineTextAlignment(.center).lineLimit(tall ? 2 : 1)
                            .frame(maxWidth: .infinity)
                        if MoreWidgets.confOn(cell, "date") {
                            Text("\(String(p.y)).\(Calc.pad(p.m + 1)).\(Calc.pad(p.d))").font(.system(size: 9)).tracking(0.5)
                                .foregroundStyle(Color.black.opacity(0.45))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .frame(height: max(34, ph * 0.26))
                }
                .padding(.top, pw * 0.07)
                .padding(.horizontal, pw * 0.07)
                .frame(width: pw, height: ph)
                .background(Color.white)
                .shadow(color: .black.opacity(home.dark ? 0.5 : 0.12), radius: 6, y: 3)
                .rotationEffect(.degrees(tilt == "l" ? -2.5 : tilt == "r" ? 2.5 : 0))
                .scaleEffect(tilt == "l" || tilt == "r" ? 0.96 : 1)
            }
            .padding(12)
        }
    }
}

// MARK: - 胶片（ins-film）：最近的几张照片排成一条底片

extension MoreWidgets {
    struct FilmW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void

        @State private var shots: [String] = []

        private static let edge = Color.white.opacity(0.55)

        var body: some View {
            let n = cell.w >= 4 ? 4 : 2
            let label = String(MoreWidgets.conf(cell, "label", "FILM 400").prefix(16))
            ZStack(alignment: .topTrailing) {
                Color.black
                VStack(spacing: 0) {
                    holes
                    HStack(spacing: 6) {
                        ForEach(0..<n, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 2) {
                                if shots.indices.contains(i) {
                                    Tile(id: shots[i], empty: Self.edge)
                                } else {
                                    Self.edge.opacity(0.25)
                                }
                                Text("\(Calc.pad(i + 1))A").font(.system(size: 9, design: .monospaced)).tracking(1)
                                    .foregroundStyle(Self.edge).lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(maxHeight: .infinity)
                    holes
                }
                if !label.isEmpty {
                    Text(label).font(.system(size: 9, design: .monospaced)).tracking(2).foregroundStyle(Self.edge).lineLimit(1)
                        .padding(.horizontal, 4)
                        .frame(height: 12)
                        .background(Color.black)
                        .padding(.trailing, 14)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { open(MoreWidgets.conf(cell, "source", "album") == "moments" ? "chat" : "album") }
            .task(id: cell) { load() }
            .onReceive(NotificationCenter.default.publisher(for: .eiraMomentsChanged)) { _ in load() }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in load() }
        }

        /// 一排齿孔：每 18 点一个 6 x 6 的小方孔
        private var holes: some View {
            Canvas { c, size in
                var x: CGFloat = 6
                while x + 6 <= size.width {
                    c.fill(Path(roundedRect: CGRect(x: x, y: 3, width: 6, height: 6), cornerRadius: 1), with: .color(Self.edge.opacity(0.8)))
                    x += 18
                }
            }
            .frame(height: 12)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
        }

        private func load() {
            let n = cell.w >= 4 ? 4 : 2
            shots = MoreWidgets.recentImages(fromMoments: MoreWidgets.conf(cell, "source", "album") == "moments", n)
        }
    }
}

// MARK: - 快拍（ins-stories）：一排头像，二十四小时内发过动态的带一圈

extension MoreWidgets {
    struct StoriesW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void

        struct One: Identifiable { var id: String; var name: String; var face: String; var fresh: Bool }
        @State private var people: [One] = []

        var body: some View {
            HStack(spacing: 8) {
                ForEach(people) { p in
                    VStack(spacing: 4) {
                        RoundFace(id: p.face, size: 42)
                            .padding(2)
                            .overlay(Circle().strokeBorder(p.fresh ? home.text : DW.line(home), lineWidth: p.fresh ? 1.5 : 1))
                        Text(p.name).font(.system(size: 11)).foregroundStyle(DW.text2(home)).lineLimit(1)
                    }
                    .frame(width: 58)
                    .contentShape(Rectangle())
                    .onTapGesture { open("chat") }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
            .task(id: cell) { load() }
            .onReceive(NotificationCenter.default.publisher(for: .eiraMomentsChanged)) { _ in load() }
            .onReceive(NotificationCenter.chatChangesSettled) { _ in load() }
        }

        private func load() {
            let me = Source.me()
            let since = Date().timeIntervalSince1970 * 1000 - 24 * 3600 * 1000
            let fresh = Set(Moments.all().filter { $0.createdAt >= since }.map(\.authorId))
            let n = max(3, Int((Double(cell.w) * 1.25).rounded()))
            let meId = me?.id ?? ""
            let chars = (try? Repo.characters()) ?? []
            let last = Dictionary(chars.map { ($0.id, Source.chatWith($0.id, me: meId)?.lastMessageAt ?? 0) }, uniquingKeysWith: { a, _ in a })
            let sorted = chars.enumerated().sorted { a, b in
                let fa = fresh.contains(a.element.id), fb = fresh.contains(b.element.id)
                if fa != fb { return fa }
                let la = last[a.element.id] ?? 0, lb = last[b.element.id] ?? 0
                if la != lb { return la > lb }
                return a.offset < b.offset
            }.map { $0.element }
            var out = [One(id: "me", name: "你的快拍", face: me?.avatar ?? "", fresh: fresh.contains("me"))]
            for c in sorted.prefix(max(0, n - 1)) {
                out.append(One(id: c.id, name: c.name, face: c.avatar, fresh: fresh.contains(c.id)))
            }
            people = out
        }
    }
}

// MARK: - 九宫格（ins-grid）

extension MoreWidgets {
    struct GridW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void

        @State private var ids: [String] = []

        var body: some View {
            GeometryReader { g in
                let side = max(0, (g.size.width - 4) / 3)
                let tall = max(0, (g.size.height - 4) / 3)
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { r in
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { c in
                                let i = r * 3 + c
                                Tile(id: ids.indices.contains(i) ? ids[i] : "", empty: DW.chip(home))
                                    .frame(width: side, height: tall)
                            }
                        }
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
            .contentShape(Rectangle())
            .onTapGesture { open(MoreWidgets.conf(cell, "source", "moments") == "album" ? "album" : "chat") }
            .task(id: cell) { load() }
            .onReceive(NotificationCenter.default.publisher(for: .eiraMomentsChanged)) { _ in load() }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in load() }
        }

        private func load() {
            ids = MoreWidgets.recentImages(fromMoments: MoreWidgets.conf(cell, "source", "moments") != "album", 9)
        }
    }
}

// MARK: - 天气（ins-weather）：角色那座城市今天的天气，读当天日程里存下的那一份，不发请求

extension MoreWidgets {
    struct WeatherW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void

        @State private var w: Weather.Forecast?
        @State private var who = ""
        @State private var empty = ""

        var body: some View {
            let flat = cell.h == 1
            Group {
                if let w {
                    let text = !w.textNight.isEmpty && w.textNight != w.textDay ? "\(w.textDay) / \(w.textNight)" : w.textDay
                    if flat {
                        HStack(spacing: 12) {
                            temps(w, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.city).font(.system(size: 12)).tracking(0.3).foregroundStyle(DW.text2(home)).lineLimit(1)
                                Text(w.textDay).font(.system(size: 13)).foregroundStyle(DW.text2(home)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            (Text(w.city).foregroundColor(DW.text2(home)) + Text(" · \(who)").foregroundColor(DW.text3(home)))
                                .font(.system(size: 12)).tracking(0.3).lineLimit(1)
                            temps(w, size: 40)
                            Text(text).font(.system(size: 13)).foregroundStyle(DW.text2(home)).lineLimit(1)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                } else {
                    Text(empty).font(.system(size: 12)).foregroundStyle(home.subText).multilineTextAlignment(.center)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if w != nil { open("daily") } }
            .task(id: cell) { load() }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in load() }
        }

        private func temps(_ w: Weather.Forecast, size: CGFloat) -> some View {
            (Text("\(Weather.fmt(w.tempMin))°") + Text("/").foregroundColor(DW.text3(home)) + Text("\(Weather.fmt(w.tempMax))°"))
                .font(.system(size: size, weight: .ultraLight)).tracking(-1).foregroundStyle(home.text).lineLimit(1)
                .minimumScaleFactor(0.6)
        }

        private func load() {
            let ch = Source.charOf(MoreWidgets.conf(cell, "charId"), me: Source.me()?.id ?? "")
            who = ch?.name ?? ""
            if let ch, let r = try? DayPlan.today(ch), let f = Weather.Forecast(r["weather"]) {
                w = f
                empty = ""
                return
            }
            w = nil
            empty = !Weather.ready() ? "在「设置 - 和风天气」中配置后显示"
                : DayPlan.region(ch).isEmpty ? "在角色卡中填写「所在地区」后显示" : "角色今天的日程安排后显示"
        }
    }
}

// MARK: - 时差旋钮（zone-dial）：拨动表盘看同一时刻各时区几点

extension MoreWidgets {
    struct ZoneW: View {
        let cell: Shell.Cell
        let home: HomeLook

        @State private var value = 0
        @State private var drag: (last: Double, total: Double)?
        @State private var chars: [Character] = []
        @State private var settings = AppSettings(raw: [:])
        /// 只挑了一个角色时，它的各天日程（按日期找当天那一行）
        @State private var days: [Row] = []

        var body: some View {
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                let now = Clock.now(settings, real: ctx.date)
                let nowMs = floor(now.timeIntervalSince1970 * 1000 / 60000) * 60000
                let at = Date(millis: nowMs + Double(value) * 60000)
                let p = Calc.parts(now, zone: Clock.userZone(settings))
                let base = p.hour * 60 + p.minute
                let big = cell.h >= 4
                let narrow = cell.w <= 2
                GeometryReader { g in
                    let inner = CGSize(width: max(0, g.size.width - 24), height: max(0, g.size.height - 24))
                    Group {
                        if big {
                            VStack(spacing: 12) {
                                dial(base: base, big: true).frame(width: inner.width * 0.56, height: inner.width * 0.56)
                                side(at)
                            }
                        } else {
                            HStack(spacing: 12) {
                                dial(base: base, big: false).frame(width: inner.height, height: inner.height)
                                if !narrow { side(at) }
                            }
                            .frame(maxWidth: .infinity, alignment: narrow ? .center : .leading)
                        }
                    }
                    .padding(12)
                    .frame(width: g.size.width, height: g.size.height)
                }
            }
            .task(id: cell) { load() }
        }

        // MARK: 表盘

        private func dial(base: Int, big: Bool) -> some View {
            let m = Calc.dialMinute(base: base, value: value)
            return GeometryReader { g in
                let size = min(g.size.width, g.size.height)
                ZStack {
                    DialFace(deg: Double(m) / 1440 * 360, ring: DW.line(home), tick: DW.text3(home), major: DW.text2(home),
                             hand: home.text, knob: home.widgetBg)
                        .frame(width: size, height: size)
                        .contentShape(Circle())
                        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .local)
                            .onChanged { v in turn(v.location, size: size) }
                            .onEnded { _ in drag = nil })
                    Button { value = 0 } label: {
                        VStack(spacing: 2) {
                            Text("\(Calc.pad(m / 60)):\(Calc.pad(m % 60))")
                                .font(.system(size: big ? 20 : 15, weight: .semibold).monospacedDigit()).foregroundStyle(home.text)
                            Text(Calc.dialOffset(value)).font(.system(size: 11).monospacedDigit()).foregroundStyle(DW.text3(home))
                        }
                        .frame(width: size * 0.42, height: size * 0.42)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到现在")
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }

        /// 正上方 0 度，顺时针为正；转过的角度累加，一圈 24 小时
        private func turn(_ pt: CGPoint, size: CGFloat) {
            let x = Double(pt.x - size / 2), y = Double(pt.y - size / 2)
            let a = atan2(x, -y) * 180 / Double.pi
            guard var d = drag else {
                drag = (a, Double(value) / 1440 * 360)
                return
            }
            var step = a - d.last
            if step > 180 { step -= 360 } else if step < -180 { step += 360 }
            d.last = a
            d.total += step
            drag = d
            let next = Calc.minutes(fromDegrees: d.total)
            if next != value { value = next }
        }

        // MARK: 右边

        @ViewBuilder private func side(_ at: Date) -> some View {
            if chars.count == 1, let one = chars.first {
                oneSide(one, at)
            } else {
                rowsSide(Calc.zoneRows(at: at, chars: chars, settings: settings))
            }
        }

        private func rowsSide(_ rows: [Calc.ZoneRow]) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { r in
                    HStack(spacing: 8) {
                        SvgIcon(name: r.night ? "moon" : "sun", size: 13, color: DW.text3(home))
                        HStack(spacing: 6) {
                            Text(r.me ? "本人" : r.place).font(.system(size: 13)).foregroundStyle(r.me ? DW.text2(home) : home.text)
                                .lineLimit(1)
                            if r.day != 0 {
                                Text(Calc.dayWord(r.day)).font(.system(size: 11)).foregroundStyle(DW.text3(home)).lineLimit(1).fixedSize()
                            }
                            if !r.chars.isEmpty {
                                HStack(spacing: 2) {
                                    ForEach(Array(r.chars.prefix(4)), id: \.id) { c in RoundFace(id: c.avatar, size: 18) }
                                    if r.chars.count > 4 {
                                        Text("+\(r.chars.count - 4)").font(.system(size: 11)).foregroundStyle(DW.text3(home)).fixedSize()
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(r.time).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(home.text).fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
        }

        private func oneSide(_ one: Character, _ at: Date) -> some View {
            let z = Clock.charZone(one, settings)
            let uz = Clock.userZone(settings)
            let q = Calc.parts(at, zone: z)
            let mine = Calc.parts(at, zone: uz)
            let d = q.ymd == mine.ymd ? 0 : q.ymd > mine.ymd ? 1 : -1
            let diff = Clock.zoneDiff(z, uz, at: at)
            let slot = DayPlan.slotNow(one, at)
            let on = DayPlan.isOn(one)
            let key = DayPlan.dateKey(one, at)
            let rec = on ? days.last(where: { $0.string("date") == key }) : nil
            let items = (rec?["items"]?.array ?? []).filter { $0["slot"]?.string == slot.id }
            let sub = "\(Calc.shortZone(z))\(diff != 0 ? " · \(Calc.diffWord(diff))" : " · 与本人同一时区") · \(slot.label)"
            return VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    RoundFace(id: one.avatar, size: 18)
                    Text(one.displayName).font(.system(size: 13)).foregroundStyle(DW.text2(home)).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Calc.pad(q.hour)):\(Calc.pad(q.minute))").font(.system(size: 28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(home.text).lineLimit(1)
                    Text([Calc.dayWord(d), q.weekday].filter { !$0.isEmpty }.joined(separator: " "))
                        .font(.system(size: 12)).foregroundStyle(DW.text3(home)).lineLimit(1)
                }
                Text(sub).font(.system(size: 12)).foregroundStyle(DW.text3(home)).lineLimit(1)
                VStack(alignment: .leading, spacing: 3) {
                    if !on {
                        none("未开启日程")
                    } else if rec == nil {
                        none("这一天还没有日程")
                    } else if items.isEmpty {
                        none("\(slot.label)没有安排")
                    } else {
                        ForEach(items.indices, id: \.self) { idx in
                            let it = items[idx]
                            let state = it["state"]?.string ?? ""
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle().fill(DW.text3(home)).frame(width: 5, height: 5).offset(y: -2)
                                Text(it["text"]?.string ?? "").font(.system(size: 13))
                                    .strikethrough(state == DayPlan.drop)
                                    .foregroundStyle(state == DayPlan.drop ? DW.text3(home) : state == DayPlan.done ? DW.text2(home) : home.text)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
        }

        private func none(_ s: String) -> some View {
            Text(s).font(.system(size: 12)).foregroundStyle(DW.text3(home)).lineLimit(1)
        }

        private func load() {
            settings = AppSettings.load()
            let ids = (cell.config["chars"]?.array ?? []).compactMap(\.string)
            chars = Calc.pickChars(ids, all: (try? Repo.characters()) ?? [])
            if chars.count == 1, let one = chars.first {
                days = (try? Database.shared.all("days", where: one.id)) ?? []
            } else {
                days = []
            }
        }
    }

    /// 24 小时的表盘：一圈细线、24 道刻度、0 6 12 18 四个数、一根指针（zoneWidget.js 那段 svg，viewBox 100 x 100）
    struct DialFace: View {
        let deg: Double
        let ring: Color
        let tick: Color
        let major: Color
        let hand: Color
        let knob: Color

        var body: some View {
            Canvas { c, size in
                let k = min(size.width, size.height) / 100
                let ox = (size.width - 100 * k) / 2, oy = (size.height - 100 * k) / 2
                func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + CGFloat(x) * k, y: oy + CGFloat(y) * k) }
                c.stroke(Path(ellipseIn: CGRect(x: ox + 4 * k, y: oy + 4 * k, width: 92 * k, height: 92 * k)), with: .color(ring), lineWidth: 1)
                for i in 0..<24 {
                    let isMajor = i % 6 == 0
                    let a = Double(i) / 24 * 2 * Double.pi
                    let r1: Double = isMajor ? 38 : 41
                    var p = Path()
                    p.move(to: pt(50 + sin(a) * r1, 50 - cos(a) * r1))
                    p.addLine(to: pt(50 + sin(a) * 44, 50 - cos(a) * 44))
                    c.stroke(p, with: .color(isMajor ? major : tick.opacity(0.5)),
                             style: StrokeStyle(lineWidth: (isMajor ? 1.4 : 0.8) * k, lineCap: .round))
                }
                for h in [0, 6, 12, 18] {
                    let a = Double(h) / 24 * 2 * Double.pi
                    c.draw(Text(String(h)).font(.system(size: max(6, 7.5 * k)).monospacedDigit()).foregroundColor(tick),
                           at: pt(50 + sin(a) * 31, 50 - cos(a) * 31))
                }
                let a = deg / 180 * Double.pi
                let tip = pt(50 + sin(a) * 38, 50 - cos(a) * 38)
                var line = Path()
                line.move(to: pt(50, 50))
                line.addLine(to: tip)
                c.stroke(line, with: .color(hand), style: StrokeStyle(lineWidth: 1.4 * k, lineCap: .round))
                let kr = 5 * k
                let knobPath = Path(ellipseIn: CGRect(x: tip.x - kr, y: tip.y - kr, width: kr * 2, height: kr * 2))
                c.fill(knobPath, with: .color(knob))
                c.stroke(knobPath, with: .color(hand), lineWidth: 1.6 * k)
            }
            .accessibilityHidden(true)
        }
    }
}

// MARK: - 健康（health）：显示哪几项由用户挑，默认不含体重

extension MoreWidgets {
    struct HealthW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void

        struct Stat: Identifiable { var id: String; var label: String; var value: String }
        @State private var stats: [Stat] = []
        @State private var due: [String] = []
        @State private var loaded = false

        var body: some View {
            let flat = cell.h == 1
            let cols = max(1, min(stats.count, cell.w >= 4 ? 6 : 3))
            Group {
                if flat {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        if stats.isEmpty && loaded { emptyText }
                        ForEach(stats) { s in one(s, size: 18) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Head(icon: "pulse", title: "今天", home: home)
                        Spacer(minLength: 0)
                        if stats.isEmpty {
                            if loaded { emptyText.frame(maxWidth: .infinity) }
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: cols),
                                      alignment: .leading, spacing: 10) {
                                ForEach(stats) { s in one(s, size: 22) }
                            }
                        }
                        Spacer(minLength: 0)
                        if !due.isEmpty {
                            Text("\(due.joined(separator: "、")) 还没有记上").font(.system(size: 12)).foregroundStyle(home.subText).lineLimit(1)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { open("health") }
            .task(id: cell) { load() }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in load() }
        }

        private var emptyText: some View {
            Text("尚未选择要显示的项目").font(.system(size: 12)).foregroundStyle(home.subText).lineLimit(1)
        }

        private func one(_ s: Stat, size: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                Text(s.value).font(.system(size: size, weight: .semibold).monospacedDigit()).tracking(-0.5)
                    .foregroundStyle(home.text).lineLimit(1).minimumScaleFactor(0.6)
                Text(s.label).font(.system(size: 11)).foregroundStyle(DW.text3(home)).lineLimit(1)
            }
        }

        private func load() {
            loaded = true
            let show = cell.config["show"]?.array.map { $0.compactMap(\.string) } ?? Calc.healthDefault
            let d = Health.day(Health.me)
            stats = Calc.healthStats.filter { show.contains($0.id) }.map { Stat(id: $0.id, label: $0.label, value: Calc.healthValue($0.id, d)) }
            // 到了时间还没记上的药（health.js 的 dueMeds）
            let s = AppSettings.load()
            let now = Health.hhmm(Clock.now(s))
            let took = Health.day(Health.me, Health.dateKey(Clock.now(s))).took
            due = Health.activeMeds().filter { m in !took.contains(m.id) && m.strings("times").contains(where: { $0 <= now }) }
                .map { $0.string("name") }
        }
    }
}

// MARK: - 相册（album）：最近存的几张铺成一格

extension MoreWidgets {
    struct AlbumW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void

        @State private var tiles: [String] = []
        @State private var total = 0
        @State private var loaded = false

        var body: some View {
            let flat = cell.h == 1
            let wide = cell.w >= 4
            let cols = flat ? 3 : wide ? 4 : 2
            GeometryReader { g in
                let innerW = max(0, g.size.width - 32)
                let innerH = max(0, g.size.height - (flat ? 24 : 32))
                let rows = max(1, (tiles.count + cols - 1) / cols)
                let reserved: CGFloat = flat ? 0 : (23 + (total > 0 ? 24 : 0))
                let byW = (innerW - CGFloat(cols - 1) * 3) / CGFloat(cols)
                let byH = (innerH - reserved - CGFloat(rows - 1) * 3) / CGFloat(rows)
                let side = max(0, min(byW, byH))
                VStack(alignment: .leading, spacing: 8) {
                    if !flat { Head(icon: "camera", title: "相册", home: home) }
                    Spacer(minLength: 0)
                    if tiles.isEmpty {
                        if loaded {
                            Text("还没有存过图片").font(.system(size: 12)).foregroundStyle(home.subText).frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(0..<rows, id: \.self) { r in
                                HStack(spacing: 3) {
                                    ForEach(0..<cols, id: \.self) { c in
                                        let i = r * cols + c
                                        if tiles.indices.contains(i) {
                                            Tile(id: tiles[i], empty: DW.chip(home))
                                                .frame(width: side, height: side)
                                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if !flat && total > 0 {
                        Text("共 \(total) 张").font(.system(size: 12)).foregroundStyle(home.subText).lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, flat ? 12 : 16)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            }
            .contentShape(Rectangle())
            .onTapGesture { open("album") }
            .task(id: cell) { load() }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in load() }
        }

        private func load() {
            loaded = true
            let all = Album.all()
            let n = cell.h == 1 ? 3 : cell.w >= 4 ? 8 : 4
            // 没有图的卡片（光栅没成的那些）不铺进来
            tiles = Array(all.map(\.imageId).filter { !$0.isEmpty }.prefix(n))
            total = all.count
        }
    }
}

// MARK: - Love 日历（love）：头像、一行字、均衡器、日历

extension MoreWidgets {
    struct LoveW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let compact = cell.w <= 2
                let mid = !compact && cell.h == 3
                let ink = cell.config["color"]?.string.flatMap { Color(hex: $0) } ?? home.text
                GeometryReader { g in
                    let pad: CGFloat = compact ? 16 : 20
                    let innerW = max(0, g.size.width - pad * 2)
                    let innerH = max(0, g.size.height - pad * 2)
                    VStack(spacing: compact ? 12 : (mid ? 8 : 16)) {
                        top(innerW: innerW, innerH: innerH, compact: compact, mid: mid, ink: ink)
                        calendar(ctx.date, compact: compact, mid: mid, ink: ink)
                    }
                    .padding(pad)
                    .frame(width: g.size.width, height: g.size.height)
                }
            }
        }

        private var serif: Bool { MoreWidgets.confOn(cell, "serif") }

        private func font(_ size: CGFloat) -> Font { serif ? Theme.serif(size) : .system(size: size) }

        private func top(innerW: CGFloat, innerH: CGFloat, compact: Bool, mid: Bool, ink: Color) -> some View {
            let gap: CGFloat = compact || mid ? 12 : 16
            let av = max(0, (innerW - gap) * (compact ? 0.32 : mid ? 0.20 : 0.34))
            let word = cell.config["word"]?.string ?? "Love"
            let size = compact ? max(17, min(28, innerW * 0.15)) : max(24, min(56, innerW * 0.09))
            let eqH = max(6, innerH * (compact ? 0.09 : 0.11))
            let cover = MoreWidgets.conf(cell, "cover")
            let has = !cover.isEmpty && MediaStore.url(.images, id: cover) != nil
            return HStack(spacing: gap) {
                ZStack {
                    if has {
                        LocalImage(id: cover, maxPixel: 400)
                    } else {
                        SvgIcon(name: "user", size: compact ? 16 : 20, color: ink)
                    }
                }
                .frame(width: av, height: av)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(ink, lineWidth: compact ? 1.5 : 2))
                .opacity(has ? 0.92 : 0.34)
                VStack(alignment: .leading, spacing: 8) {
                    Text(word).font(font(size)).foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.6)
                    HStack(spacing: compact ? 2 : 3) {
                        ForEach(0..<(compact ? 14 : 26), id: \.self) { i in
                            Capsule().fill(ink.opacity(0.82))
                                .frame(width: compact ? 2 : 3, height: eqH * CGFloat(0.35 + 0.65 * abs(sin(Double(i) * 1.7))))
                        }
                    }
                    .frame(height: eqH)
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private func calendar(_ now: Date, compact: Bool, mid: Bool, ink: Color) -> some View {
            let t = Day.parts(now)
            let zh = MoreWidgets.conf(cell, "lang", "en") == "zh"
            let month = zh ? "\(t.m + 1)月" : Calc.monthEN[t.m]
            let week = zh ? Day.zhWeek : compact ? ["S", "M", "T", "W", "T", "F", "S"] : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let grid = Calc.loveDays(now, compact: compact)
            let dayFont: CGFloat = compact || mid ? 12 : 13
            return VStack(spacing: 0) {
                Rectangle().fill(ink.opacity(0.16)).frame(height: 1)
                HStack(alignment: .firstTextBaseline) {
                    Text(month).font(font(compact ? 13 : 17)).foregroundStyle(ink).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(String(t.y)).font(.system(size: compact ? 9 : 11)).tracking(compact ? 0.4 : 1.3).foregroundStyle(ink.opacity(0.45))
                }
                .padding(.top, mid ? 8 : 12)
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(week[i]).font(.system(size: compact ? 9 : 11)).foregroundStyle(ink.opacity(0.48)).lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, compact ? 6 : (mid ? 4 : 12))
                .padding(.bottom, compact ? 4 : (mid ? 2 : 8))
                VStack(spacing: 0) {
                    ForEach(0..<grid.rows, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { c in
                                let i = r * 7 + c
                                let d: Calc.CalDay? = grid.cells.indices.contains(i) ? grid.cells[i] : nil
                                ZStack {
                                    if let d {
                                        if d.today {
                                            SvgIcon(name: "music", size: compact ? 12 : 14, color: ink)
                                        } else {
                                            Text(String(d.n)).font(.system(size: dayFont)).foregroundStyle(ink).lineLimit(1)
                                                .opacity(d.out ? 0.3 : 1)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }
}
