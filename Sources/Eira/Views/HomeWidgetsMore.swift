import SwiftUI

/// 主屏的又一批小组件，照网页版搬：
/// - src/screens/home/widgets.js：时间（clock）、朋友圈（moments-peek）、记忆统计（memory-count）
/// - src/screens/home/decorWidgets.js：装饰组（dw-*）与「一句」（ins-quote）
/// - src/screens/home/decoText.js：每天一句的英文原句、按日期取句的算法（同一天与网页版是同一句）
/// - src/screens/home/widgetData.js：选了哪个角色、和它的那段单聊（charOf、chatWith）
/// 样子照 styles/shell.css 的 .dw-*、.wg-* 与 tokens.css 的 --dw-*：只有黑白灰，形状只用圆、拱、圆角方，
/// 大号细衬线数字配一行小斜体，没放图时是那只猫（CatFill）。
///
/// framed 为 false 的（网页版 frameless: true）不垫主屏的卡片，自己画形状；其中月相、今年、这一周、节气、一句
/// 自己画一张 dw-card。数据在各自的小视图里 .task 读一次，会话或朋友圈变了再读，不在 body 里每次重读。
enum MoreWidgets {
    struct Field { let key: String; let kind: String /* "image" | "text" | "char" | "lang" */; let label: String; let placeholder: String }
    struct Def { let id: String; let label: String; let desc: String; let sizes: [(Int, Int)]; let fields: [Field]; let framed: Bool /* false = web frameless: true (no card background) */ }

    // MARK: - 登记（网页版 registerWidget / deco 的 id、label、desc、sizes、fields、frameless）

    private static func img(_ key: String, _ label: String, _ desc: String = "") -> Field {
        Field(key: key, kind: "image", label: label, placeholder: desc)
    }
    private static func text(_ key: String, _ label: String, _ placeholder: String) -> Field {
        Field(key: key, kind: "text", label: label, placeholder: placeholder)
    }
    private static let charField = Field(key: "charId", kind: "char", label: "角色", placeholder: "不选则跟随最近聊过的角色")

    /// 网页版月相、今年、这一周、节气的「文字」：中文 / English（config.lang）。placeholder 是没设时的那一档
    private static func lang(_ def: String) -> Field { Field(key: "lang", kind: "lang", label: "文字", placeholder: def) }
    static let all: [Def] = [
        Def(id: "clock", label: "时间", desc: "当前的时间与日期",
            sizes: [(2, 1), (2, 2), (4, 1)], fields: [], framed: true),
        Def(id: "moments-peek", label: "朋友圈", desc: "朋友圈里最近的一条动态",
            sizes: [(2, 2), (4, 2)], fields: [], framed: true),
        Def(id: "memory-count", label: "记忆统计", desc: "记忆的总条数，以及其中自动提取的条数",
            sizes: [(2, 2), (2, 1)], fields: [], framed: true),
        Def(id: "dw-orbit", label: "圆心", desc: "中间的圆放一张照片，四周几枚字条，底下一行长的",
            sizes: [(4, 4), (4, 3)],
            fields: [img("img", "圆里的照片"), text("t1", "左上", "留空则写今天的日期"), text("t2", "右上", "留空则写星期"),
                     text("t3", "左边", "留空则写年份"), text("t4", "右下", "留空则写今年第几天"), text("t5", "底下一行", "留空则每天换一句英文原句")],
            framed: true),
        Def(id: "dw-square", label: "照片", desc: "一张照片铺满一张卡",
            sizes: [(2, 2), (4, 2), (4, 4)], fields: [img("img", "照片")], framed: true),
        Def(id: "dw-tilt", label: "两张相框", desc: "两张照片，一张歪着在后，一张正着压在前面",
            sizes: [(4, 4), (2, 2)], fields: [img("img", "歪着的那张"), img("img2", "正着的那张")], framed: false),
        Def(id: "dw-notes", label: "两句", desc: "角色最近说的一句与自己最近说的一句，各带头像；点一下进入那段对话",
            sizes: [(2, 2), (4, 2)], fields: [charField], framed: true),
        Def(id: "dw-ribbon", label: "长条", desc: "一张横着的长卡，底下垫着两层；左边一张小圆图，右边一句话",
            sizes: [(4, 2), (4, 1)], fields: [img("img", "左边的小圆图"), text("text", "一句话", "留空则每天换一句英文原句")], framed: false),
        Def(id: "dw-round", label: "圆", desc: "一张圆形照片",
            sizes: [(2, 2), (4, 4)], fields: [img("img", "照片")], framed: false),
        Def(id: "dw-duo", label: "双圆", desc: "一句英文、两个圆、今天的日期；两个圆可以各放一张图，不放则用自己与角色的头像",
            sizes: [(2, 2)],
            fields: [charField, img("imgA", "左边的圆", "不放则用我的头像"), img("imgB", "右边的圆", "不放则用角色的头像"),
                     text("text", "一句英文", "留空则每天换一句原句")],
            framed: true),
        Def(id: "dw-pillars", label: "四柱", desc: "四张照片裁成竖着的长条",
            sizes: [(4, 4), (4, 3), (4, 2)],
            fields: [img("img", "第一张"), img("img2", "第二张"), img("img3", "第三张"), img("img4", "第四张")], framed: false),
        Def(id: "ins-quote", label: "一句", desc: "每天从聊天记录里摘一句角色说过的话",
            sizes: [(2, 2), (4, 2)], fields: [charField], framed: false),
        Def(id: "dw-phase", label: "月相", desc: "今晚的月亮是什么样子，按日期算，不用填任何东西",
            sizes: [(2, 2), (4, 2), (2, 1)], fields: [lang("en")], framed: false),
        Def(id: "dw-year", label: "今年", desc: "今天是这一年的第几天，下面一条细线是过了多少",
            sizes: [(2, 2), (4, 1), (2, 1)], fields: [lang("en")], framed: false),
        Def(id: "dw-week", label: "这一周", desc: "七个小圆，过去的几天浅一些，今天是实心的",
            sizes: [(4, 1), (2, 1)], fields: [lang("en")], framed: false),
        Def(id: "dw-term", label: "节气", desc: "今天落在哪个节气，离下一个还有几天，按日期算，不用填任何东西",
            sizes: [(2, 2), (4, 2), (2, 1), (4, 1)], fields: [lang("zh")], framed: false),
    ]

    static func has(_ id: String) -> Bool { all.contains { $0.id == id } }

    /// 组件本体。config 里没写的项按网页版的 defaults 补（图片 null、文字空串、lang 各自的默认）
    static func view(_ cell: Shell.Cell, home: HomeLook, open: @escaping (String) -> Void, openChat: @escaping (String) -> Void) -> AnyView {
        switch cell.ref {
        case "clock": return AnyView(ClockW(cell: cell, home: home))
        case "moments-peek": return AnyView(MomentsPeekW(home: home, open: open))
        case "memory-count": return AnyView(MemoryCountW(cell: cell, home: home, open: open))
        case "dw-orbit": return AnyView(OrbitW(cell: cell, home: home))
        case "dw-square": return AnyView(PhotoFill(id: MoreWidgets.str(cell, "img")))
        case "dw-tilt": return AnyView(TiltW(cell: cell, home: home))
        case "dw-notes": return AnyView(NotesW(cell: cell, home: home, open: open, openChat: openChat))
        case "dw-ribbon": return AnyView(RibbonW(cell: cell, home: home))
        case "dw-round": return AnyView(RoundW(cell: cell, home: home))
        case "dw-duo": return AnyView(DuoW(cell: cell, home: home))
        case "dw-pillars": return AnyView(PillarsW(cell: cell, home: home))
        case "ins-quote": return AnyView(QuoteW(cell: cell, home: home, openChat: openChat))
        case "dw-phase": return AnyView(PhaseW(cell: cell, home: home))
        case "dw-year": return AnyView(YearW(cell: cell, home: home))
        case "dw-week": return AnyView(WeekW(cell: cell, home: home))
        case "dw-term": return AnyView(TermW(cell: cell, home: home))
        default: return AnyView(EmptyView())
        }
    }

    fileprivate static func str(_ cell: Shell.Cell, _ key: String) -> String { cell.config[key]?.string ?? "" }
}

// MARK: - 每天一句（decoText.js）

extension MoreWidgets {
    struct Line { let t: String; let by: String }

    /// decoText.js 的 LINES_EN，一字不改、顺序不改：按下标取句，改了就和网页版不是同一句
    static let linesEN: [Line] = [
        Line(t: "Midway upon the journey of our life I found myself within a forest dark.", by: "Dante"),
        Line(t: "The Love which moves the sun and the other stars.", by: "Dante"),
        Line(t: "Shall I compare thee to a summer's day?", by: "Shakespeare"),
        Line(t: "Love is not love which alters when it alteration finds.", by: "Shakespeare"),
        Line(t: "My bounty is as boundless as the sea, my love as deep.", by: "Shakespeare"),
        Line(t: "A thing of beauty is a joy for ever.", by: "Keats"),
        Line(t: "Bright star, would I were stedfast as thou art.", by: "Keats"),
        Line(t: "Hope is the thing with feathers that perches in the soul.", by: "Dickinson"),
        Line(t: "Forever is composed of Nows.", by: "Dickinson"),
        Line(t: "Whatever our souls are made of, his and mine are the same.", by: "Bronte"),
        Line(t: "You pierce my soul. I am half agony, half hope.", by: "Austen"),
        Line(t: "I wandered lonely as a cloud.", by: "Wordsworth"),
        Line(t: "Tread softly because you tread on my dreams.", by: "Yeats"),
        Line(t: "So we beat on, boats against the current.", by: "Fitzgerald"),
        Line(t: "'Tis better to have loved and lost than never to have loved at all.", by: "Tennyson"),
        Line(t: "I am large, I contain multitudes.", by: "Whitman"),
    ]

    /// 年 * 400 + 月（0 起） * 32 + 日 + salt * 3，本地时间（decoText.js 的 seed）
    static func seed(_ salt: Int, _ d: Date = Date()) -> Int {
        let t = Day.parts(d)
        return t.y * 400 + t.m * 32 + t.d + salt * 3
    }

    static func lineOfDay(_ salt: Int, _ d: Date = Date()) -> Line {
        let n = seed(salt, d) % linesEN.count
        return linesEN[n < 0 ? n + linesEN.count : n]
    }

    /// 格子 id 每个 UTF-16 码元相加再加 n（decorWidgets.js 的 saltOf；JS 的 charCodeAt 就是 UTF-16）
    static func saltOf(_ cellId: String, _ n: Int) -> Int {
        cellId.utf16.reduce(0) { $0 + Int($1) } + n
    }
}

// MARK: - 日期（本地时间，同网页版 new Date()）

extension MoreWidgets {
    enum Day {
        static let ms: Double = 86_400_000

        /// 年、月（0 起）、日、星期（0 为周日），同 JS 的 getFullYear / getMonth / getDate / getDay
        static func parts(_ d: Date) -> (y: Int, m: Int, d: Int, wd: Int) {
            let c = Calendar.current.dateComponents([.year, .month, .day, .weekday], from: d)
            return (c.year ?? 2000, (c.month ?? 1) - 1, c.day ?? 1, (c.weekday ?? 1) - 1)
        }

        /// new Date(y, m, d)：月从 0 起，日超出范围按日历顺延
        static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: y, month: m + 1, day: d)) ?? Date()
        }

        static let zhWeek = ["日", "一", "二", "三", "四", "五", "六"]
        static let enWeek = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

        static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

        /// 今天是今年的第几天（decorWidgets.js 的 YearBody / OrbitBody）
        static func dayOfYear(_ now: Date) -> Int {
            let t = parts(now)
            let start = date(t.y, 0, 1)
            return Int(floor(now.timeIntervalSince(start) * 1000 / ms)) + 1
        }

        // 月相（decorWidgets.js 的 moonPhase）。NEW_MOON = Date.UTC(2000, 0, 6, 18, 14)
        static let synodic = 29.530588853
        static let newMoon: Double = 947_182_440_000
        static let phases: [(upto: Double, en: String, zh: String)] = [
            (0.03, "New Moon", "新月"), (0.22, "Waxing Crescent", "蛾眉月"), (0.28, "First Quarter", "上弦月"),
            (0.47, "Waxing Gibbous", "盈凸月"), (0.53, "Full Moon", "满月"), (0.72, "Waning Gibbous", "亏凸月"),
            (0.78, "Last Quarter", "下弦月"), (0.97, "Waning Crescent", "残月"), (1.01, "New Moon", "新月"),
        ]

        static func moon(_ d: Date) -> (p: Double, en: String, zh: String, lit: Int) {
            let days = (d.timeIntervalSince1970 * 1000 - newMoon) / ms
            let r = (days.truncatingRemainder(dividingBy: synodic) + synodic).truncatingRemainder(dividingBy: synodic)
            let p = r / synodic
            let ph = phases.first(where: { p < $0.upto }) ?? phases[phases.count - 1]
            let lit = Int(((1 - cos(2 * Double.pi * p)) / 2 * 100).rounded())
            return (p, ph.en, ph.zh, lit)
        }

        // 节气（decorWidgets.js 的 solarTerm）：二十一世纪的通式
        static let termC: [Double] = [5.4055, 20.12, 3.87, 18.73, 5.63, 20.646, 4.81, 20.1, 5.52, 21.04, 5.678, 21.37,
                                      7.108, 22.83, 7.5, 23.13, 7.646, 23.042, 8.318, 23.438, 7.438, 22.36, 7.18, 21.94]
        static let termZh = ["小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨", "立夏", "小满", "芒种", "夏至",
                             "小暑", "大暑", "立秋", "处暑", "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至"]
        static let termEn = ["Minor Cold", "Major Cold", "Start of Spring", "Rain Water", "Awakening of Insects", "Spring Equinox",
                             "Clear and Bright", "Grain Rain", "Start of Summer", "Grain Buds", "Grain in Ear", "Summer Solstice",
                             "Minor Heat", "Major Heat", "Start of Autumn", "End of Heat", "White Dew", "Autumn Equinox",
                             "Cold Dew", "Frost's Descent", "Start of Winter", "Minor Snow", "Major Snow", "Winter Solstice"]

        static func termDate(_ y: Int, _ i: Int) -> Date {
            let yy = y % 100
            // JS 的 Math.floor：负数也向下取整（2000 年 (0 - 1) / 4 是 -1），Swift 的整数除法向零取整，所以走浮点
            let leap = i < 4 ? Int(floor(Double(yy - 1) / 4)) : Int(floor(Double(yy) / 4))
            let day = Int(floor(Double(yy) * 0.2422 + termC[i])) - leap
            return date(y, i / 2, day)
        }

        static func term(_ d: Date) -> (i: Int, zh: String, en: String, nextZh: String, nextEn: String, left: Int) {
            let t = parts(d)
            let today = date(t.y, t.m, t.d)
            var list: [(i: Int, at: Date)] = []
            for k in [-1, 0, 1] {
                for i in 0..<24 { list.append((i: i, at: termDate(t.y + k, i))) }
            }
            let idx = list.lastIndex(where: { $0.at <= today }) ?? 0
            let cur = list[idx]
            let next = list[min(idx + 1, list.count - 1)]
            let left = Int((next.at.timeIntervalSince(today) * 1000 / ms).rounded())
            return (cur.i, termZh[cur.i], termEn[cur.i], termZh[next.i], termEn[next.i], left)
        }
    }
}

// MARK: - 取数（widgetData.js）

extension MoreWidgets {
    enum Source {
        /// 当前账号（网页版 accounts.current）
        static func me() -> Persona? { try? Repo.activePersona() }

        /// 选了哪个角色；没选就用当前账号最近聊过的那段单聊的角色，一段都没有就取第一个不是 NPC 的角色
        static func charOf(_ id: String, me: String) -> Character? {
            if !id.isEmpty { return try? Repo.character(id) }
            let chats = (try? Repo.chats()) ?? []
            let mine = chats.filter { ($0.personaId.isEmpty || $0.personaId == me) && $0.characterIds.count == 1 }
            var last: Chat?
            for c in mine where last == nil || c.lastMessageAt > (last?.lastMessageAt ?? 0) { last = c }
            if let last {
                return last.characterIds.first.flatMap { try? Repo.character($0) }
            }
            let all = (try? Repo.characters()) ?? []
            return all.first(where: { !$0.isNpc })
        }

        /// 当前账号和这个角色的那段单聊
        static func chatWith(_ charId: String, me: String) -> Chat? {
            let chats = (try? Repo.chats()) ?? []
            return chats.first(where: { c in
                c.characterIds.count == 1 && c.characterIds.first == charId && (c.personaId.isEmpty || c.personaId == me)
            })
        }
    }
}

// MARK: - 共用的颜色与小件（tokens.css 的 --dw-*）

extension MoreWidgets {
    enum DW {
        /// --dw-card：浅色白、深色 #1A1A1A，铺了壁纸时与其他小组件同一层半透明
        static func card(_ h: HomeLook) -> Color { h.wallpaper ? h.widgetBg : (h.dark ? Color(white: 0.102) : .white) }
        /// --dw-chip：字条、对话泡的底
        static func chip(_ h: HomeLook) -> Color {
            switch (h.wallpaper, h.dark) {
            case (false, false): return Color(white: 0.937)
            case (false, true): return Color(white: 0.165)
            case (true, false): return Color.white.opacity(0.45)
            case (true, true): return Color.white.opacity(0.12)
            }
        }
        /// --dw-shadow
        static func shadow(_ h: HomeLook) -> Color { .black.opacity(h.wallpaper ? 0.06 : (h.dark ? 0.40 : 0.08)) }
        static func text2(_ h: HomeLook) -> Color { h.text.opacity(0.56) }
        static func text3(_ h: HomeLook) -> Color { h.text.opacity(0.36) }
        /// --border-2：细线
        static func line(_ h: HomeLook) -> Color { h.text.opacity(0.14) }
        /// --dw-serif 的斜体小字
        static func italic(_ size: CGFloat) -> Font { .system(size: size, design: .serif).italic() }
        /// 大号细衬线数字
        static func thin(_ size: CGFloat) -> Font { .system(size: size, weight: .light, design: .serif) }
    }

    /// 有图显示图，没有就是那只猫（网页版 Photo：cat-full）。外面定好大小再放进来，自己会裁掉多出来的部分
    struct PhotoFill: View {
        let id: String
        var maxPixel: CGFloat = 900

        var body: some View {
            Color.clear
                .overlay {
                    if !id.isEmpty, MediaStore.url(.images, id: id) != nil {
                        LocalImage(id: id, maxPixel: maxPixel)
                    } else {
                        CatFill(full: true)
                    }
                }
                .clipped()
        }
    }

    /// 圆形头像（网页版 Face：没有图时是 cat-face）
    struct RoundFace: View {
        let id: String
        let size: CGFloat

        var body: some View {
            Group {
                if !id.isEmpty, MediaStore.url(.images, id: id) != nil {
                    LocalImage(id: id, maxPixel: size * 3)
                } else {
                    CatFill()
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        }
    }

    /// 小星（twinkle 那个四角星，实心）。纯装饰
    struct SparkShape: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            let cx = r.midX, cy = r.midY
            let kx = r.width * 0.05, ky = r.height * 0.05
            p.move(to: CGPoint(x: cx, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: cy), control: CGPoint(x: cx + kx, y: cy - ky))
            p.addQuadCurve(to: CGPoint(x: cx, y: r.maxY), control: CGPoint(x: cx + kx, y: cy + ky))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: cy), control: CGPoint(x: cx - kx, y: cy + ky))
            p.addQuadCurve(to: CGPoint(x: cx, y: r.minY), control: CGPoint(x: cx - kx, y: cy - ky))
            p.closeSubpath()
            return p
        }
    }

    /// 一颗小星，按中心点摆
    struct Spark: View {
        let size: CGFloat
        let x: CGFloat
        let y: CGFloat
        let color: Color

        var body: some View {
            SparkShape().fill(color).frame(width: size, height: size).position(x: x, y: y)
                .accessibilityHidden(true)
        }
    }

    /// 小组件左上角的灰色小标题（.wg-head）
    struct Head: View {
        let icon: String
        let title: String
        let home: HomeLook

        var body: some View {
            HStack(spacing: 6) {
                SvgIcon(name: icon, size: 15, color: home.subText)
                Text(title).font(.system(size: 12)).foregroundStyle(home.subText).lineLimit(1)
            }
        }
    }

    /// 自己画的那几层卡（.dw-sf）：与主屏小组件同一种底，没有壁纸时一层淡影，有壁纸时一道细边
    struct SolidCard: View {
        let home: HomeLook
        var radius: CGFloat = 18

        var body: some View {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(home.widgetBg)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(home.capsuleBorder, lineWidth: 1))
                .shadow(color: .black.opacity(home.wallpaper ? 0 : (home.dark ? 0.6 : 0.10)), radius: 8, y: 4)
        }
    }
}

private extension View {
    /// 网页版 .dw-card：铺满一格，圆角 24，--dw-card 的底与 --dw-shadow
    func moreCard(_ home: HomeLook) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(MoreWidgets.DW.card(home))
                    .shadow(color: MoreWidgets.DW.shadow(home), radius: 5, y: 2)
            )
    }
}

// MARK: - 时间（widgets.js 的 clock）

extension MoreWidgets {
    struct ClockW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                let t = Day.parts(ctx.date)
                let c = Calendar.current.dateComponents([.hour, .minute], from: ctx.date)
                let time = "\(Day.pad(c.hour ?? 0)):\(Day.pad(c.minute ?? 0))"
                let date = "\(t.m + 1)月\(t.d)日 星期\(Day.zhWeek[t.wd])"
                let low = cell.h < 2
                VStack(alignment: .leading, spacing: low ? 2 : 6) {
                    Text(time)
                        .font(.system(size: low ? 34 : 56, weight: .thin).monospacedDigit())
                        .foregroundStyle(home.text)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text(date).font(.system(size: 12)).foregroundStyle(home.subText).lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, low ? 8 : 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - 朋友圈（widgets.js 的 moments-peek）

extension MoreWidgets {
    struct MomentsPeekW: View {
        let home: HomeLook
        var open: (String) -> Void

        struct Peek { var author: String; var text: String; var when: String }
        @State private var peek: Peek?
        @State private var loaded = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Head(icon: "moments", title: "朋友圈", home: home)
                if let peek {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(peek.author).font(.system(size: 14, weight: .medium)).foregroundStyle(home.text).lineLimit(1)
                        Text(peek.text).font(.system(size: 13)).foregroundStyle(DW.text2(home)).lineSpacing(3).lineLimit(3)
                        Text(peek.when).font(.system(size: 12)).foregroundStyle(home.subText).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                } else if loaded {
                    Text("还没有动态").font(.system(size: 12)).foregroundStyle(home.subText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { open("chat") }
            .task { load() }
            .onReceive(NotificationCenter.default.publisher(for: .eiraMomentsChanged)) { _ in load() }
        }

        private func load() {
            loaded = true
            // 角色撤回了的不算：它已经不在朋友圈上了
            guard let mo = Moments.all().first(where: { !$0.recalled }) else { peek = nil; return }
            let author: String
            if mo.authorId == "me" {
                author = Source.me()?.name ?? "某人"
            } else {
                author = (try? Repo.character(mo.authorId))?.name ?? "某人"
            }
            peek = Peek(author: author, text: mo.text, when: Self.relTime(mo.createdAt))
        }

        /// widgets.js 的 relTime
        static func relTime(_ ts: Double) -> String {
            guard ts > 0 else { return "" }
            let mins = Int(floor((Date().timeIntervalSince1970 * 1000 - ts) / 60000))
            if mins < 1 { return "刚刚" }
            if mins < 60 { return "\(mins)分钟前" }
            if mins < 1440 { return "\(mins / 60)小时前" }
            return "\(mins / 1440)天前"
        }
    }
}

// MARK: - 记忆统计（widgets.js 的 memory-count）

extension MoreWidgets {
    struct MemoryCountW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void

        @State private var total = 0
        @State private var auto = 0

        var body: some View {
            Group {
                if cell.h < 2 {
                    // 一行高：小标题在左、数字在右，下面那行说明放不下就不放
                    HStack {
                        Head(icon: "brain", title: "记忆", home: home)
                        Spacer(minLength: 8)
                        Text(String(total)).font(.system(size: 40, weight: .bold)).tracking(-2)
                            .foregroundStyle(home.text).lineLimit(1).minimumScaleFactor(0.5)
                    }
                    .padding(.horizontal, 16)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Head(icon: "brain", title: "记忆", home: home)
                        Spacer(minLength: 0)
                        Text(String(total)).font(.system(size: 56, weight: .bold)).tracking(-2)
                            .foregroundStyle(home.text).lineLimit(1).minimumScaleFactor(0.5)
                        Text("其中 \(String(auto)) 条自动提取").font(.system(size: 12)).foregroundStyle(home.subText).lineLimit(1)
                    }
                    .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { open("preset") }
            .task { load() }
        }

        private func load() {
            let rows = (try? Database.shared.all(Collections.memories)) ?? []
            total = rows.count
            auto = rows.filter { $0.string("source") == "auto" }.count
        }
    }
}

// MARK: - 圆心（dw-orbit）：中间一个圆放照片，四周几枚字条，底下一行长的

extension MoreWidgets {
    struct OrbitW: View {
        let cell: Shell.Cell
        let home: HomeLook

        /// 五枚字条的位置（shell.css 的 .dw-orbit-t1 … t5：左、上、宽、高）
        private static let spots: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] = [
            (0.076, 0.147, 0.317, 0.114), (0.729, 0.345, 0.182, 0.08), (0.076, 0.504, 0.182, 0.08),
            (0.638, 0.585, 0.317, 0.116), (0.084, 0.81, 0.826, 0.082),
        ]

        var body: some View {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                GeometryReader { g in
                    let w = g.size.width, h = g.size.height
                    let labels = self.tags(ctx.date)
                    ZStack {
                        Circle()
                            .strokeBorder(DW.line(home), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: w * 0.52, height: w * 0.52)
                            .position(x: w * 0.49, y: h * 0.44)
                        PhotoFill(id: MoreWidgets.str(cell, "img"))
                            .frame(width: w * 0.38, height: w * 0.38)
                            .clipShape(Circle())
                            .position(x: w * 0.49, y: h * 0.44)
                        ForEach(0..<5, id: \.self) { i in
                            let s = Self.spots[i]
                            let tw: CGFloat = w * s.w
                            let th: CGFloat = h * s.h
                            Text(labels[i])
                                .font(i == 0 ? Theme.serif(15) : Font.system(size: 12))
                                .foregroundStyle(i == 0 ? home.text : DW.text2(home))
                                .lineLimit(1)
                                .padding(.horizontal, i == 1 || i == 2 ? 4 : 10)
                                .frame(width: tw, height: th)
                                .background(Capsule().fill(DW.chip(home)))
                                .position(x: w * s.x + tw / 2, y: h * s.y + th / 2)
                        }
                    }
                    .frame(width: w, height: h)
                }
            }
        }

        private func tags(_ now: Date) -> [String] {
            let t = Day.parts(now)
            let given = ["t1", "t2", "t3", "t4", "t5"].map { MoreWidgets.str(cell, $0) }
            let fallback = [
                "\(t.m + 1)月\(t.d)日",
                "周\(Day.zhWeek[t.wd])",
                String(t.y),
                "今年第 \(Day.dayOfYear(now)) 天",
                MoreWidgets.lineOfDay(MoreWidgets.saltOf(cell.id, 5), now).t,
            ]
            return (0..<5).map { given[$0].isEmpty ? fallback[$0] : given[$0] }
        }
    }
}

// MARK: - 两张相框（dw-tilt）：一张歪着在后，一张正着压在前面

extension MoreWidgets {
    struct TiltW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            GeometryReader { g in
                ZStack {
                    photoFrame(MoreWidgets.str(cell, "img"))
                        .frame(width: g.size.width * 0.50, height: g.size.height * 0.47)
                        .rotationEffect(.degrees(-12))
                        .position(x: g.size.width * (0.06 + 0.25), y: g.size.height * (0.08 + 0.235))
                    photoFrame(MoreWidgets.str(cell, "img2"))
                        .frame(width: g.size.width * 0.54, height: g.size.height * 0.60)
                        .position(x: g.size.width * (0.42 + 0.27), y: g.size.height * (0.36 + 0.30))
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }

        private func photoFrame(_ id: String) -> some View {
            PhotoFill(id: id)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(6)
                .background(SolidCard(home: home))
        }
    }
}

// MARK: - 两句（dw-notes）：角色最近说的一句在左，自己最近说的一句在右

extension MoreWidgets {
    struct NotesW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var open: (String) -> Void
        var openChat: (String) -> Void

        struct NoteRow: Identifiable { var id: Int; var face: String; var text: String; var mine: Bool }
        @State private var title = "两句"
        @State private var rows: [NoteRow] = []
        @State private var chatId = ""
        @State private var loaded = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Head(icon: "message", title: title, home: home)
                if !rows.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(rows) { r in
                            Spacer(minLength: 0)
                            HStack(spacing: 8) {
                                if r.mine { Spacer(minLength: 0) }
                                if !r.mine { RoundFace(id: r.face, size: 30) }
                                Text(r.text)
                                    .font(.system(size: 13)).foregroundStyle(home.text).lineLimit(1)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DW.chip(home)))
                                if r.mine { RoundFace(id: r.face, size: 30) }
                                if !r.mine { Spacer(minLength: 0) }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity)
                } else if loaded {
                    Text("还没有会话").font(.system(size: 12)).foregroundStyle(home.subText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { if chatId.isEmpty { open("chat") } else { openChat(chatId) } }
            .task { load() }
            .onReceive(NotificationCenter.chatChangesSettled) { _ in load() }
        }

        private func load() {
            loaded = true
            let me = Source.me()
            let meId = me?.id ?? ""
            let ch = Source.charOf(MoreWidgets.str(cell, "charId"), me: meId)
            let chat = ch.flatMap { Source.chatWith($0.id, me: meId) }
            title = ch?.displayName ?? "两句"
            chatId = chat?.id ?? ""
            var out: [NoteRow] = []
            if let chat {
                let all = (try? Repo.messages(chatId: chat.id)) ?? []
                let theirs = Self.lastOf(all, .char)
                let mine = Self.lastOf(all, .user)
                if !theirs.isEmpty { out.append(NoteRow(id: 0, face: ch?.avatar ?? "", text: theirs, mine: false)) }
                if !mine.isEmpty { out.append(NoteRow(id: 1, face: me?.avatar ?? "", text: mine, mine: true)) }
            }
            rows = out
        }

        /// 最近的一条文字消息；出错的、方括号标记开头的（图片、转账这类）跳过（decorWidgets.js 的 lastOf）
        static func lastOf(_ all: [Message], _ role: Message.Role) -> String {
            for m in all.reversed() where m.role == role && m.kind == "text" && !m.isError && !m.content.isEmpty && !m.content.hasPrefix("[") {
                return m.content
            }
            return ""
        }
    }
}

// MARK: - 长条（dw-ribbon）：一张横着的长卡，底下垫两层

extension MoreWidgets {
    struct RibbonW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            let low = cell.h < 2
            let custom = MoreWidgets.str(cell, "text")
            let line = MoreWidgets.lineOfDay(MoreWidgets.saltOf(cell.id, 7))
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack {
                    layer(opacity: 0.4)
                        .frame(width: w * 0.80, height: h * (low ? 0.70 : 0.58))
                        .position(x: w / 2, y: h * (low ? 0.14 + 0.35 : 0.18 + 0.29))
                    layer(opacity: 0.7)
                        .frame(width: w * 0.88, height: h * (low ? 0.70 : 0.56))
                        .position(x: w / 2, y: h * (low ? 0.10 + 0.35 : 0.14 + 0.28))
                    let topH = h * (low ? 0.70 : 0.54)
                    HStack(spacing: 12) {
                        PhotoFill(id: MoreWidgets.str(cell, "img"), maxPixel: 300)
                            .frame(width: topH * 0.72, height: topH * 0.72)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(custom.isEmpty ? line.t : custom)
                                .font(.system(size: 14)).foregroundStyle(home.text).lineLimit(1)
                            if custom.isEmpty {
                                Text(line.by).font(.system(size: 12)).foregroundStyle(DW.text3(home)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(width: max(0, w - 8), height: topH)
                    .background(layer(opacity: 1))
                    .position(x: w / 2, y: h * (low ? 0.06 : 0.10) + topH / 2)
                }
                .frame(width: w, height: h)
            }
        }

        private func layer(opacity: Double) -> some View {
            Capsule(style: .continuous)
                .fill(home.widgetBg)
                .overlay(Capsule(style: .continuous).strokeBorder(home.capsuleBorder, lineWidth: 1))
                .shadow(color: DW.shadow(home), radius: 5, y: 2)
                .opacity(opacity)
        }
    }
}

// MARK: - 圆（dw-round）：一张圆形照片，往里收一圈，阴影落在格子里

extension MoreWidgets {
    struct RoundW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            GeometryReader { g in
                let d = max(0, min(g.size.width, g.size.height) - 24)
                PhotoFill(id: MoreWidgets.str(cell, "img"))
                    .frame(width: d, height: d)
                    .clipShape(Circle())
                    .background(Circle().fill(home.widgetBg).shadow(color: DW.shadow(home), radius: 5, y: 2))
                    .position(x: g.size.width / 2, y: g.size.height / 2)
            }
        }
    }
}

// MARK: - 双圆（dw-duo）：上面一句英文，中间两个头像，下面日期

extension MoreWidgets {
    struct DuoW: View {
        let cell: Shell.Cell
        let home: HomeLook

        @State private var left = ""
        @State private var right = ""

        var body: some View {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let t = Day.parts(ctx.date)
                let custom = MoreWidgets.str(cell, "text")
                VStack(spacing: 8) {
                    Text(custom.isEmpty ? MoreWidgets.lineOfDay(MoreWidgets.saltOf(cell.id, 11), ctx.date).t : custom)
                        .font(.system(size: 12)).foregroundStyle(DW.text3(home)).lineLimit(1)
                    HStack(spacing: 6) {
                        RoundFace(id: left, size: 52)
                        RoundFace(id: right, size: 52)
                    }
                    Text("\(t.m + 1)月\(t.d)日")
                        .font(Theme.serif(24)).foregroundStyle(home.text).lineLimit(1)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task { load() }
        }

        private func load() {
            let me = Source.me()
            let a = MoreWidgets.str(cell, "imgA"), b = MoreWidgets.str(cell, "imgB")
            left = a.isEmpty ? (me?.avatar ?? "") : a
            if b.isEmpty {
                right = Source.charOf(MoreWidgets.str(cell, "charId"), me: me?.id ?? "")?.avatar ?? ""
            } else {
                right = b
            }
        }
    }
}

// MARK: - 四柱（dw-pillars）：四张照片裁成竖着的长条

extension MoreWidgets {
    struct PillarsW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            HStack(spacing: 12) {
                ForEach(["img", "img2", "img3", "img4"], id: \.self) { k in
                    PhotoFill(id: MoreWidgets.str(cell, k), maxPixel: 600)
                        .clipShape(Capsule(style: .continuous))
                        .background(Capsule(style: .continuous).fill(home.widgetBg).shadow(color: DW.shadow(home), radius: 5, y: 2))
                }
            }
            .padding(.top, 8).padding(.horizontal, 4).padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 一句（ins-quote）：角色说过的一句话，每天换一句

extension MoreWidgets {
    struct QuoteW: View {
        let cell: Shell.Cell
        let home: HomeLook
        var openChat: (String) -> Void

        struct Got { var text: String; var by: String; var chatId: String }
        @State private var hasChar = false
        @State private var face = ""
        @State private var got: Got?

        var body: some View {
            GeometryReader { g in
                let compact = g.size.height <= 160
                let wide = cell.w >= 4
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\u{201C}")
                            .font(.system(size: 40, design: .serif)).foregroundStyle(home.text)
                            .frame(height: 22, alignment: .top)
                        Text(got?.text ?? "与角色聊过之后，这里每天摘录一句角色说过的话")
                            .font(.system(size: compact ? 14 : (wide ? 17 : 15), design: .serif))
                            .foregroundStyle(home.text)
                            .lineSpacing(compact ? 3 : 5)
                            .lineLimit(compact ? 2 : 3)
                            .padding(.top, compact ? 8 : 14)
                        Spacer(minLength: 0)
                        if let got {
                            Text(got.by).font(.system(size: 11)).foregroundStyle(DW.text3(home)).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, compact ? 12 : 16)
                    .padding(.bottom, compact ? 10 : 14)
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                    if hasChar {
                        RoundFace(id: face, size: 30)
                            .position(x: g.size.width - 16 - 15, y: 14 + 15)
                    }
                }
            }
            .moreCard(home)
            .contentShape(Rectangle())
            .onTapGesture { if let got { openChat(got.chatId) } }
            .task { load() }
            .onReceive(NotificationCenter.chatChangesSettled) { _ in load() }
        }

        private func load() {
            let meId = Source.me()?.id ?? ""
            let ch = Source.charOf(MoreWidgets.str(cell, "charId"), me: meId)
            hasChar = ch != nil
            face = ch?.avatar ?? ""
            guard let ch, let chat = Source.chatWith(ch.id, me: meId) else { got = nil; return }
            // 本地挑，不调接口。太短的（嗯、好）和太长的（放不下）不挑；长度按 UTF-16 算，同 JS 的 length
            let pool = ((try? Repo.messages(chatId: chat.id)) ?? []).filter { m in
                let n = m.content.utf16.count
                return m.role == .char && m.kind == "text" && !m.isError && !m.content.hasPrefix("[") && n >= 6 && n <= 60
            }
            guard !pool.isEmpty else { got = nil; return }
            // 按日期取，同一天是同一句（decorWidgets.js 的 pickLine，不加 salt）
            let t = Day.parts(Date())
            let seed = t.y * 400 + t.m * 32 + t.d
            let m = pool[seed % pool.count]
            got = Got(text: m.content, by: "— \(ch.displayName)，\(Self.whenOf(m.createdAt))", chatId: chat.id)
        }

        /// 今天、昨天，再早写几月几日（decorWidgets.js 的 whenOf）
        static func whenOf(_ ms: Double) -> String {
            let cal = Calendar.current
            let d = Date(timeIntervalSince1970: ms / 1000)
            let diff = Int(floor(cal.startOfDay(for: Date()).timeIntervalSince(cal.startOfDay(for: d)) / 86400))
            if diff <= 0 { return "今天" }
            if diff == 1 { return "昨天" }
            let t = Day.parts(d)
            return "\(t.m + 1) 月 \(t.d) 日"
        }
    }
}

// MARK: - 月相（dw-phase）

extension MoreWidgets {
    /// 一个虚线圆，亮的那一块按相位画（盈月亮在右，亏月亮在左）。只有一种颜色
    struct MoonDisc: View {
        let p: Double
        let lit: Color
        let dark: Color

        var body: some View {
            Canvas { ctx, size in
                let s = min(size.width, size.height) / 88
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = 40 * s
                let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.stroke(ring, with: .color(dark), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                guard p > 0.03 && p < 0.97 else { return }
                let rx = CGFloat(abs(cos(2 * Double.pi * p))) * r
                let waxing = p < 0.5
                let gibbous = p > 0.25 && p < 0.75
                // 亮的一侧的半圆，加上明暗分界那半个椭圆：凸月往暗的一侧鼓，蛾眉月往亮的一侧收
                let sx: CGFloat = waxing ? 1 : -1
                let tx: CGFloat = gibbous ? -sx : sx
                let n = 40
                var path = Path()
                for k in 0...n {
                    let th = -Double.pi / 2 + Double.pi * Double(k) / Double(n)
                    let pt = CGPoint(x: c.x + sx * r * CGFloat(cos(th)), y: c.y + r * CGFloat(sin(th)))
                    if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                for k in 0...n {
                    let th = Double.pi / 2 - Double.pi * Double(k) / Double(n)
                    path.addLine(to: CGPoint(x: c.x + tx * rx * CGFloat(cos(th)), y: c.y + r * CGFloat(sin(th))))
                }
                path.closeSubpath()
                ctx.fill(path, with: .color(lit))
            }
            .accessibilityHidden(true)
        }
    }

    struct PhaseW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let m = Day.moon(ctx.date)
                let zh = MoreWidgets.str(cell, "lang") == "zh"
                let low = cell.h < 2
                let wide = cell.w >= 4 && !low
                let name = zh ? m.zh : m.en
                let sub = zh ? "今晚亮着 \(m.lit)%" : "\(m.lit)% illuminated"
                GeometryReader { g in
                    let w = g.size.width, h = g.size.height
                    ZStack {
                        if low || wide {
                            let d = h * (low ? 0.64 : 0.70)
                            let left: CGFloat = low ? 0.42 : 0.48
                            let gap: CGFloat = low ? 10 : 16
                            let tw: CGFloat = max(0, w * (1 - left) - gap)
                            MoonDisc(p: m.p, lit: home.text, dark: DW.text3(home))
                                .frame(width: d, height: d)
                                .position(x: w * (low ? 0.20 : 0.24), y: h / 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).font(DW.italic(low ? 14 : 24)).foregroundStyle(home.text).lineLimit(1).minimumScaleFactor(0.7)
                                Text(sub).font(.system(size: 11)).foregroundStyle(DW.text3(home)).lineLimit(1)
                            }
                            .frame(width: tw, alignment: .leading)
                            .position(x: w * left + tw / 2, y: h / 2)
                        } else {
                            let d = min(w * 0.52, 92)
                            MoonDisc(p: m.p, lit: home.text, dark: DW.text3(home))
                                .frame(width: d, height: d)
                                .position(x: w / 2, y: h * 0.40)
                            VStack(spacing: 1) {
                                Text(name).font(DW.italic(14)).foregroundStyle(home.text).lineLimit(1)
                                Text(sub).font(.system(size: 11)).foregroundStyle(DW.text3(home)).lineLimit(1)
                            }
                            .frame(width: w)
                            .position(x: w / 2, y: h - 12 - 16)
                        }
                        Spark(size: 12, x: w * 0.10 + 6, y: h * 0.12 + 6, color: home.text)
                        Spark(size: 8, x: w * 0.88 - 4, y: h * 0.22 + 4, color: home.text)
                        if !low { Spark(size: 7, x: w * 0.20 + 3.5, y: h * 0.58 + 3.5, color: home.text) }
                    }
                    .frame(width: w, height: h)
                }
                .moreCard(home)
            }
        }
    }
}

// MARK: - 今年（dw-year）：今天是这一年的第几天

extension MoreWidgets {
    struct YearW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let t = Day.parts(ctx.date)
                let n = Day.dayOfYear(ctx.date)
                let total = Int((Day.date(t.y + 1, 0, 1).timeIntervalSince(Day.date(t.y, 0, 1)) / 86400).rounded())
                let pct = total > 0 ? Int(floor(Double(n) / Double(total) * 100)) : 0
                let zh = MoreWidgets.str(cell, "lang") == "zh"
                let k = zh ? "\(t.y) 年" : String(t.y)
                let sub = zh ? "第 \(n) 天，已过 \(pct)%" : "days into the year · \(pct)%"
                let low = cell.h < 2
                GeometryReader { g in
                    ZStack(alignment: .topLeading) {
                        if low {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(k).font(.system(size: 11)).tracking(1.3).foregroundStyle(DW.text3(home)).lineLimit(1)
                                    Text(String(n)).font(DW.thin(28).monospacedDigit()).foregroundStyle(home.text).lineLimit(1)
                                    Text(sub).font(DW.italic(12)).foregroundStyle(DW.text2(home)).lineLimit(1).minimumScaleFactor(0.8)
                                }
                                bar(pct)
                            }
                            .padding(.horizontal, 14)
                            .frame(width: g.size.width, height: g.size.height, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(k).font(.system(size: 11)).tracking(1.3).foregroundStyle(DW.text3(home)).lineLimit(1)
                                Text(String(n)).font(DW.thin(56).monospacedDigit()).foregroundStyle(home.text)
                                    .lineLimit(1).minimumScaleFactor(0.5)
                                Text(sub).font(DW.italic(12)).foregroundStyle(DW.text2(home)).lineLimit(1).minimumScaleFactor(0.8)
                                bar(pct).padding(.top, 6)
                            }
                            .padding(.horizontal, 16)
                            .frame(width: g.size.width, height: g.size.height, alignment: .leading)
                        }
                        Spark(size: 12, x: g.size.width - 14 - 6, y: 14 + 6, color: home.text)
                        if !low { Spark(size: 7, x: g.size.width - 30 - 3.5, y: 34 + 3.5, color: home.text) }
                    }
                }
                .moreCard(home)
            }
        }

        /// 一条细线，过了的那一段粗一点
        private func bar(_ pct: Int) -> some View {
            GeometryReader { b in
                ZStack(alignment: .leading) {
                    Rectangle().fill(DW.line(home)).frame(height: 1)
                    Capsule().fill(home.text).frame(width: b.size.width * CGFloat(max(0, min(100, pct))) / 100, height: 3)
                }
                .frame(width: b.size.width, height: 3, alignment: .leading)
            }
            .frame(height: 3)
        }
    }
}

// MARK: - 这一周（dw-week）：七个小圆，今天是实心的

extension MoreWidgets {
    struct WeekW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let t = Day.parts(ctx.date)
                let today = (t.wd + 6) % 7   // 周一开头
                let zh = MoreWidgets.str(cell, "lang") == "zh"
                let marks = zh ? ["一", "二", "三", "四", "五", "六", "日"] : ["M", "T", "W", "T", "F", "S", "S"]
                let name = zh ? "星期\(Day.zhWeek[t.wd])" : Day.enWeek[t.wd]
                let wide = cell.w >= 4
                Group {
                    if wide {
                        HStack(spacing: 12) {
                            Text(name).font(DW.italic(17)).foregroundStyle(home.text).lineLimit(1)
                            Spacer(minLength: 0)
                            dots(today: today, marks: marks, gap: 6, labels: true)
                        }
                        .padding(.horizontal, 16)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(DW.italic(13)).foregroundStyle(home.text).lineLimit(1)
                            dots(today: today, marks: marks, gap: 4, labels: false)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .moreCard(home)
            }
        }

        private func dots(today: Int, marks: [String], gap: CGFloat, labels: Bool) -> some View {
            HStack(spacing: gap) {
                ForEach(0..<7, id: \.self) { i in
                    VStack(spacing: 3) {
                        ZStack {
                            if i == today {
                                Circle().fill(home.text)
                            } else if i < today {
                                Circle().fill(DW.line(home))
                            } else {
                                Circle().strokeBorder(DW.text3(home), lineWidth: 1)
                            }
                        }
                        .frame(width: 9, height: 9)
                        if labels {
                            Text(marks[i])
                                .font(.system(size: 9, weight: i == today ? .semibold : .regular))
                                .foregroundStyle(i == today ? home.text : DW.text3(home))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 节气（dw-term）：今天落在哪个节气，离下一个还有几天

extension MoreWidgets {
    /// 一圈二十四道刻度，今天所在的节气那一道上一个实心点。小寒在最上面，顺时针走
    struct TermWheel: View {
        let i: Int
        let ring: Color
        let tick: Color
        let dot: Color

        var body: some View {
            Canvas { ctx, size in
                let s = min(size.width, size.height) / 92
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = 40 * s
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(ring), lineWidth: 1)
                var ticks = Path()
                for k in 0..<24 {
                    let a = Double(k) / 24 * Double.pi * 2 - Double.pi / 2
                    let r1 = (k % 6 == 0 ? 33 : 36) * s
                    ticks.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * r1, y: c.y + CGFloat(sin(a)) * r1))
                    ticks.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r))
                }
                ctx.stroke(ticks, with: .color(tick), lineWidth: 1)
                let at = Double(i) / 24 * Double.pi * 2 - Double.pi / 2
                let dr = 3.4 * s
                let p = CGPoint(x: c.x + CGFloat(cos(at)) * r, y: c.y + CGFloat(sin(at)) * r)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - dr, y: p.y - dr, width: dr * 2, height: dr * 2)), with: .color(dot))
            }
            .accessibilityHidden(true)
        }
    }

    struct TermW: View {
        let cell: Shell.Cell
        let home: HomeLook

        var body: some View {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let t = Day.term(ctx.date)
                // 这一块默认中文，填了 en 才写英文（defaults.lang = 'zh'）
                let zh = MoreWidgets.str(cell, "lang") != "en"
                let next = zh ? "距\(t.nextZh)还有 \(t.left) 天" : "\(t.left) days to \(t.nextEn)"
                let low = cell.h < 2
                let wide = cell.w >= 4
                GeometryReader { g in
                    let w = g.size.width, h = g.size.height
                    ZStack(alignment: .topLeading) {
                        if low {
                            // 一行高：只有字
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(t.zh).font(Theme.serif(24)).tracking(1).foregroundStyle(home.text).lineLimit(1)
                                if wide {
                                    Text(t.en).font(DW.italic(13)).foregroundStyle(DW.text2(home)).lineLimit(1)
                                }
                                Text(next).font(.system(size: 11)).foregroundStyle(DW.text3(home)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .padding(.horizontal, 14)
                            .frame(width: w, height: h, alignment: .leading)
                            Spark(size: 11, x: w - 12 - 5.5, y: 10 + 5.5, color: home.text)
                        } else if wide {
                            let d = h * 0.62
                            TermWheel(i: t.i, ring: DW.line(home), tick: DW.text3(home), dot: home.text)
                                .frame(width: d, height: d)
                                .position(x: w * 0.90 - d / 2, y: h / 2)
                            text(t, next: next, size: 44)
                                .padding(.horizontal, 18)
                                .frame(width: w, height: h, alignment: .leading)
                            Spark(size: 11, x: w * 0.52 + 5.5, y: h * 0.16 + 5.5, color: home.text)
                            Spark(size: 7, x: w * 0.46 + 3.5, y: h * 0.82 - 3.5, color: home.text)
                        } else {
                            // 两格见方：圆环在右上，字在左下
                            let d = h * 0.46
                            TermWheel(i: t.i, ring: DW.line(home), tick: DW.text3(home), dot: home.text)
                                .frame(width: d, height: d)
                                .position(x: w - 12 - d / 2, y: 14 + d / 2)
                            text(t, next: next, size: 34)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 14)
                                .frame(width: w, height: h, alignment: .bottomLeading)
                            Spark(size: 11, x: 14 + 5.5, y: 16 + 5.5, color: home.text)
                            Spark(size: 7, x: 34 + 3.5, y: 34 + 3.5, color: home.text)
                        }
                    }
                }
                .moreCard(home)
            }
        }

        private func text(_ t: (i: Int, zh: String, en: String, nextZh: String, nextEn: String, left: Int), next: String, size: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.zh).font(Theme.serif(size)).tracking(size * 0.04).foregroundStyle(home.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(t.en).font(DW.italic(13)).foregroundStyle(DW.text2(home)).lineLimit(1)
                Text(next).font(.system(size: 11)).tracking(0.2).foregroundStyle(DW.text3(home)).lineLimit(1)
                    .padding(.top, 4)
            }
        }
    }
}
