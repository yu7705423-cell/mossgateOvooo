import Foundation

/// 互动标识（网页版 system/badges.js，ARCHITECTURE 4.164）。
///
/// 全部在本机按聊天记录算，一次接口都不调：连续互发、相识多久、说了多少、通话时长、隐藏成就、节日限定、亲密度等级。
/// 统计存在会话自己身上（chat.stats），解锁过的存在 chat.unlocked，限定款存在 chat.limited。格式与网页版一致，
/// 两边导入导出接着算。增量：upTo 记着算到哪一刻，之后只看比它新的；「重新统计」才整段过一遍。
/// 一天按这台设备的本地日期算，一天里你和对方都至少发过一条，这一天才算「互发」。提示行与失败的不算。
enum Badges {
    static let version = 2.0

    /// 本地日期的天序号
    static func dayNo(_ t: Double) -> Int {
        let off = Double(TimeZone.current.secondsFromGMT(for: Date(millis: t))) * 1000
        return Int(((t + off) / 86_400_000).rounded(.down))
    }

    private static func md(_ t: Double) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: Date(millis: t))
        return String(format: "%02d-%02d", c.month ?? 0, c.day ?? 0)
    }

    private static func year(_ t: Double) -> Int { Calendar.current.component(.year, from: Date(millis: t)) }
    private static func hour(_ t: Double) -> Int { Calendar.current.component(.hour, from: Date(millis: t)) }

    /// 「1998-03-12」「3月12日」「03/12」都认
    static func birthdayMd(_ raw: String) -> String {
        guard let m = raw.range(of: #"(\d{1,2})\s*[月\-/.]\s*(\d{1,2})\s*日?\s*$"#, options: .regularExpression) else { return "" }
        let nums = raw[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 2, (1...12).contains(nums[0]), (1...31).contains(nums[1]) else { return "" }
        return String(format: "%02d-%02d", nums[0], nums[1])
    }

    // MARK: - 标识表（界面文案，书面语）

    struct Streak { let at: Int; let form: String; let name: String }
    static let streakTiers = [Streak(at: 3, form: "spark", name: "火苗"), Streak(at: 7, form: "flame", name: "火焰"),
                              Streak(at: 30, form: "torch", name: "火把"), Streak(at: 100, form: "star", name: "星"),
                              Streak(at: 365, form: "sun", name: "太阳")]

    struct Tier {
        let id: String, icon: String, name: String, unit: String
        let steps: [Int]
        var names: [String]? = nil
        var onlyLove = false
    }

    static let tiers = [
        Tier(id: "together", icon: "heart", name: "在一起", unit: "天", steps: [100, 365, 1000], onlyLove: true),
        Tier(id: "known", icon: "calendar", name: "相识", unit: "天", steps: [100, 365, 1000]),
        Tier(id: "count", icon: "boat", name: "消息", unit: "条", steps: [1000, 10000], names: ["小船", "巨轮"]),
        Tier(id: "call", icon: "phone", name: "通话", unit: "小时", steps: [1, 10, 50]),
        Tier(id: "listen", icon: "headphone", name: "一起听", unit: "小时", steps: [1, 10]),
    ]

    struct Achievement { let id: String; let icon: String; let name: String; let hint: String; let desc: String }
    static let achievements = [
        Achievement(id: "night3", icon: "moon", name: "凌晨三点", hint: "与夜晚有关", desc: "在凌晨三点到四点之间互发过消息"),
        Achievement(id: "burst", icon: "sparkle", name: "连珠炮", hint: "与速度有关", desc: "一分钟内同一方连续发出十条消息"),
        Achievement(id: "collide", icon: "heart", name: "撞车", hint: "与默契有关", desc: "同一分钟内双方发出了同一个表情"),
        Achievement(id: "firstCall", icon: "phone", name: "第一通电话", hint: "与声音有关", desc: "第一次接通电话"),
        Achievement(id: "longCall", icon: "clock", name: "长谈", hint: "与声音有关", desc: "单次通话超过一小时"),
        Achievement(id: "pact10", icon: "bookmark", name: "守约", hint: "与承诺有关", desc: "完成的约定达到十个"),
        Achievement(id: "520", icon: "wallet", name: "五二零", hint: "与数字有关", desc: "一笔转账的金额正好是 520"),
        Achievement(id: "greet7", icon: "sun", name: "早安晚安", hint: "与问候有关", desc: "连续七天互道早安与晚安"),
        Achievement(id: "letters5", icon: "mail", name: "书信往来", hint: "与纸笔有关", desc: "双方各寄出五封信"),
        Achievement(id: "rescue", icon: "flame", name: "救火", hint: "与火有关", desc: "火花熄灭的第二天，由对方先开口并互发，火花接续"),
        Achievement(id: "owl", icon: "moon", name: "夜谈", hint: "与夜晚有关", desc: "消息满两百条，其中零点到五点之间的占两成以上"),
    ]

    static let limited: [(id: String, name: String)] = [
        ("newyear", "新年第一天"), ("valentine", "情人节"), ("xmas", "圣诞节"), ("bdayChar", "对方的生日"),
        ("bdayMe", "我的生日"), ("anniv", "相识纪念日"), ("love", "在一起纪念日"),
    ]

    static func limitedName(_ id: String) -> String {
        let key = String(id.split(separator: ":").first ?? "")
        if key.hasPrefix("day-") {
            let row = (try? Database.shared.get("spaceItems", id: String(key.dropFirst(4)))) ?? nil
            return row?.string("title").isEmpty == false ? row!.string("title") : "纪念日"
        }
        return limited.first { $0.id == key }?.name ?? ""
    }

    /// 任何一种解锁记录写成一句给人看的名字
    static func label(_ id: String) -> String {
        if let a = achievements.first(where: { $0.id == id }) { return "\(a.name)（\(a.desc)）" }
        if id.contains(":") { return "\(id.split(separator: ":").last ?? "") \(limitedName(id))" }
        guard let r = id.range(of: #"^([a-z]+)-(\d+)$"#, options: .regularExpression) else { return "" }
        let parts = id[r].split(separator: "-")
        let kind = String(parts[0]), n = Int(parts[1]) ?? 0
        if kind == "streak" { return streakTiers.first { $0.at == n }.map { "连续互发 \($0.at) 天：\($0.name)" } ?? "" }
        guard let t = tiers.first(where: { $0.id == kind }), let i = t.steps.firstIndex(of: n) else { return "" }
        if let names = t.names { return "\(names[i])（\(t.name) \(n) \(t.unit)）" }
        return "\(t.name) \(n) \(t.unit)"
    }

    // MARK: - 统计（与网页版 chat.stats 同一种写法）

    private static func blank() -> [String: JSONValue] {
        [
            "v": .number(version), "upTo": .number(0), "edge": .array([]),
            "n": .number(0), "nU": .number(0), "nC": .number(0), "first": .number(0), "late": .number(0),
            "day": .null, "lastBoth": .null, "streak": .number(0), "best": .number(0), "rescued": .number(0),
            "callSec": .number(0), "calls": .number(0), "listenSec": .number(0), "pacts": .number(0),
            "letters": .object(["u": .number(0), "c": .number(0)]),
            "greet": .null, "greetRun": .number(0), "greetLast": .null,
            "stick": .object(["u": .null, "c": .null]), "burst": .object(["u": .array([]), "c": .array([])]),
        ]
    }

    private struct Ctx { var charBday = "", myBday = "", love = "", loveYear = 0; var days: [(id: String, md: String)] = [] }

    private static func ctx(_ chat: Chat) -> Ctx {
        var c = Ctx()
        if !chat.isGroup, let id = chat.characterIds.first, let ch = (try? Repo.character(id)) ?? nil {
            c.charBday = birthdayMd(ch.row.string("birthday"))
        }
        let ps = (try? Repo.personas()) ?? []
        if let me = ps.first(where: { $0.id == chat.personaId }) ?? ((try? Repo.activePersona()) ?? nil) {
            c.myBday = birthdayMd(me.row.string("birthday"))
        }
        if let love = chat.row.number("loveStartAt"), love > 0 { c.love = md(love); c.loveYear = year(love) }
        c.days = ((try? Database.shared.all("spaceItems", where: chat.id)) ?? []).compactMap { r in
            let d = r.string("date")
            guard r.string("type") == "day", r.bool("yearly"), d.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
            return (r.id, String(d.dropFirst(5)))
        }
        return c
    }

    private static let morning = try! NSRegularExpression(pattern: #"早安|早上好|good\s*morning"#, options: .caseInsensitive)
    private static let night = try! NSRegularExpression(pattern: #"晚安|good\s*night"#, options: .caseInsensitive)

    /// 过一条消息
    private static func step(_ st: inout [String: JSONValue], _ m: Message, _ c: Ctx, _ got: (String, Double, Bool) -> Void) {
        func n(_ k: String) -> Double { st[k]?.number ?? 0 }
        let t = m.createdAt
        if m.kind == "notice" {
            if m.row.string("settledKind") == "pact" {
                st["pacts"] = .number(n("pacts") + 1)
                if n("pacts") >= 10 { got("pact10", t, false) }
            }
            return
        }
        guard !m.isError else { return }
        let side = m.role == .user ? "u" : "c"
        let opp = side == "u" ? "c" : "u"
        st["n"] = .number(n("n") + 1)
        st[side == "u" ? "nU" : "nC"] = .number(n(side == "u" ? "nU" : "nC") + 1)
        if n("first") == 0 { st["first"] = .number(t) }
        let K = Double(dayNo(t))
        var day = st["day"]?.object ?? [:]
        if day["key"]?.number != K {
            day = ["key": .number(K), "u": .bool(false), "c": .bool(false), "first": .string(side), "h3u": .bool(false), "h3c": .bool(false)]
        }
        day[side] = .bool(true)
        let h = hour(t)
        if h < 5 { st["late"] = .number(n("late") + 1) }
        if h == 3 {
            day["h3\(side)"] = .bool(true)
            if day["h3u"]?.bool == true && day["h3c"]?.bool == true { got("night3", t, false) }
        }
        st["day"] = .object(day)

        // 连续互发。断了正好一天、今天又是对方先开的口，算接上
        if day["u"]?.bool == true, day["c"]?.bool == true, st["lastBoth"]?.number != K {
            let last = st["lastBoth"]?.number
            let gap = last.map { K - $0 }
            if gap == 1 { st["streak"] = .number(n("streak") + 1) }
            else if gap == 2 && day["first"]?.string == "c" {
                st["streak"] = .number(n("streak") + 1)
                st["rescued"] = .number(n("rescued") + 1)
                got("rescue", t, false)
            } else { st["streak"] = .number(1) }
            st["lastBoth"] = .number(K)
            st["best"] = .number(max(n("best"), n("streak")))
            for x in streakTiers where Int(n("streak")) >= x.at { got("streak-\(x.at)", t, false) }
            // 限定款：互发的那一天正好是那个日子
            let today = md(t), y = year(t)
            let anniv = year(n("first")) < y ? md(n("first")) : ""
            let love = c.loveYear > 0 && c.loveYear < y ? c.love : ""
            let dates: [String: String] = ["newyear": "01-01", "valentine": "02-14", "xmas": "12-25", "bdayChar": c.charBday,
                                           "bdayMe": c.myBday, "anniv": anniv, "love": love]
            for x in limited { if let d = dates[x.id], !d.isEmpty, d == today { got("\(x.id):\(y)", t, true) } }
            for d in c.days where d.md == today { got("day-\(d.id):\(y)", t, true) }
        }

        // 早安晚安：同一天里四句都有
        let text = m.content
        let ns = NSRange(location: 0, length: (text as NSString).length)
        var g = st["greet"]?.object ?? [:]
        if g["key"]?.number != K { g = ["key": .number(K), "mu": .bool(false), "mc": .bool(false), "nu": .bool(false), "nc": .bool(false), "done": .bool(false)] }
        if morning.firstMatch(in: text, range: ns) != nil { g["m\(side)"] = .bool(true) }
        if night.firstMatch(in: text, range: ns) != nil { g["n\(side)"] = .bool(true) }
        if g["done"]?.bool != true, ["mu", "mc", "nu", "nc"].allSatisfy({ g[$0]?.bool == true }) {
            g["done"] = .bool(true)
            st["greetRun"] = .number(st["greetLast"]?.number == K - 1 ? n("greetRun") + 1 : 1)
            st["greetLast"] = .number(K)
            if n("greetRun") >= 7 { got("greet7", t, false) }
        }
        st["greet"] = .object(g)

        // 一分钟十条
        var burst = st["burst"]?.object ?? [:]
        var b = (burst[side]?.array ?? []).compactMap(\.number)
        b.append(t)
        if b.count > 10 { b.removeFirst() }
        if b.count == 10, t - b[0] <= 60_000 { got("burst", t, false) }
        burst[side] = .array(b.map { .number($0) })
        st["burst"] = .object(burst)

        // 同一分钟里双方发了同一个表情
        let sid = m.row.string("stickerId")
        if m.kind == "sticker", !sid.isEmpty {
            var stick = st["stick"]?.object ?? [:]
            if let o = stick[opp]?.object, o["id"]?.string == sid, t - (o["at"]?.number ?? 0) <= 60_000 { got("collide", t, false) }
            stick[side] = .object(["id": .string(sid), "at": .number(t)])
            st["stick"] = .object(stick)
        }
        let secs = m.row.number("seconds") ?? 0
        if m.kind == "call", m.row.string("outcome") == "done", secs > 0 {
            st["callSec"] = .number(n("callSec") + secs)
            st["calls"] = .number(n("calls") + 1)
            got("firstCall", t, false)
            if secs >= 3600 { got("longCall", t, false) }
        }
        if m.kind == "listen" { st["listenSec"] = .number(n("listenSec") + secs) }
        if m.kind == "transfer", m.row.number("amount") == 520 { got("520", t, false) }
        if m.kind == "letter" {
            var l = st["letters"]?.object ?? [:]
            l[side] = .number((l[side]?.number ?? 0) + 1)
            st["letters"] = .object(l)
            if (l["u"]?.number ?? 0) >= 5 && (l["c"]?.number ?? 0) >= 5 { got("letters5", t, false) }
        }
        if n("n") >= 200, n("late") / n("n") >= 0.2 { got("owl", t, false) }
    }

    static func tierValue(_ t: Tier, _ st: [String: JSONValue], chat: Chat, now: Double) -> Int {
        switch t.id {
        case "together":
            guard let love = chat.row.number("loveStartAt"), love > 0 else { return 0 }
            return dayNo(now) - dayNo(love) + 1
        case "known":
            let f = st["first"]?.number ?? 0
            return f > 0 ? dayNo(now) - dayNo(f) + 1 : 0
        case "count": return Int(st["n"]?.number ?? 0)
        case "call": return Int((st["callSec"]?.number ?? 0) / 3600)
        case "listen": return Int((st["listenSec"]?.number ?? 0) / 3600)
        default: return 0
        }
    }

    private static func tierUnlocks(_ st: [String: JSONValue], chat: Chat, now: Double, _ got: (String, Double, Bool) -> Void) {
        for t in tiers {
            if t.onlyLove && (chat.row.number("loveStartAt") ?? 0) <= 0 { continue }
            let v = tierValue(t, st, chat: chat, now: now)
            for x in t.steps where v >= x { got("\(t.id)-\(x)", now, false) }
        }
    }

    /// 同步一段会话的统计。有变化才写库。返回这一次新解锁的 id。full：整段重算（「重新统计」）
    @discardableResult
    static func sync(_ chatId: String, full: Bool = false, now: Date = Date()) throws -> [String] {
        guard var chat = try Repo.chat(chatId) else { return [] }
        let nowMs = now.millis
        let stored = chat.row["stats"]?.object
        let redo = full || stored == nil || stored?["v"]?.number != version
        var st = redo ? blank() : stored!
        var unlocked = redo && full ? [:] : (chat.row["unlocked"]?.object ?? [:])
        var lim = redo && full ? [:] : (chat.row["limited"]?.object ?? [:])
        var news: [String] = []
        func got(_ id: String, _ at: Double, _ isLimited: Bool) {
            if isLimited { if lim[id] == nil { lim[id] = .number(at); news.append(id) } }
            else if unlocked[id] == nil { unlocked[id] = .number(at); news.append(id) }
        }
        let c = ctx(chat)
        let upTo = st["upTo"]?.number ?? 0
        var edge = Set((st["edge"]?.array ?? []).compactMap(\.string))
        // 只读需要的那一段：先读末尾一截，没盖住 upTo 再读整段
        var list = try Repo.messages(chatId: chatId, limit: 300)
        if list.count >= 300, let first = list.first, first.createdAt > upTo { list = try Repo.messages(chatId: chatId) }
        var moved = false
        var mark = upTo
        for m in list {
            let t = m.createdAt
            if t < mark || (t == mark && edge.contains(m.id)) { continue }
            if m.role != .user && m.role != .char { continue }
            step(&st, m, c, got)
            if t > mark { mark = t; edge.removeAll() }
            edge.insert(m.id)
            moved = true
        }
        st["upTo"] = .number(mark)
        st["edge"] = .array(edge.sorted().map { .string($0) })
        tierUnlocks(st, chat: chat, now: nowMs, got)
        guard moved || !news.isEmpty || redo else { return [] }
        chat.row["stats"] = .object(st)
        chat.row["unlocked"] = .object(unlocked)
        chat.row["limited"] = .object(lim)
        try Repo.save(chat)
        return redo ? [] : news
    }

    // MARK: - 读

    /// 这段对话显不显示标识（默认显示）
    static func shown(_ chat: Chat?) -> Bool { chat?.row["badgeShow"]?.bool != false }
    /// 让角色知道（默认关：它会进提示词）
    static func aware(_ chat: Chat?) -> Bool { chat?.row["badgeAware"]?.bool == true }

    struct StreakState { var state: String; var n: Int; var best: Int; var form: Streak? }

    static func formOf(_ n: Int) -> Streak? { streakTiers.last { n >= $0.at } }

    /// 火花：lit 今天已经互发；risk 昨天互发了今天还没有；ember 断了正好一天；out 熄了
    static func streak(_ chat: Chat?, now: Date = Date()) -> StreakState {
        guard let s = chat?.row["stats"]?.object, let last = s["lastBoth"]?.number else { return StreakState(state: "none", n: 0, best: 0, form: nil) }
        let n = Int(s["streak"]?.number ?? 0), best = Int(s["best"]?.number ?? 0)
        let gap = dayNo(now.millis) - Int(last)
        if gap <= 0 { return StreakState(state: "lit", n: n, best: best, form: formOf(n)) }
        if gap == 1 { return StreakState(state: "risk", n: n, best: best, form: formOf(n)) }
        if gap == 2 { return StreakState(state: "ember", n: n, best: best, form: formOf(n)) }
        return StreakState(state: "out", n: 0, best: best, form: nil)
    }

    static let levels: [Double] = [0, 60, 200, 500, 1200, 3000]

    static func score(_ chat: Chat, now: Date = Date()) -> Int {
        guard let s = chat.row["stats"]?.object else { return 0 }
        let first = s["first"]?.number ?? 0
        let known = first > 0 ? Double(dayNo(now.millis) - dayNo(first)) : 0
        let v = (s["best"]?.number ?? 0) * 3 + (s["n"]?.number ?? 0) / 40 + (s["callSec"]?.number ?? 0) / 600
            + (s["listenSec"]?.number ?? 0) / 900 + known / 10
            + Double((chat.row["unlocked"]?.object ?? [:]).count) * 8 + Double((chat.row["limited"]?.object ?? [:]).count) * 10
            + Double((chat.row["awards"]?.array ?? []).count) * 10
        return Int(v.rounded())
    }

    struct Level { var level: Int; var max: Int; var name: String; var progress: Double; var next: Int? }

    /// 每一级叫什么由用户自己填（chat.levelNames），系统不替人定义关系
    static func level(_ chat: Chat, now: Date = Date()) -> Level {
        let sc = Double(score(chat, now: now))
        var i = 0
        while i + 1 < levels.count && sc >= levels[i + 1] { i += 1 }
        let names = (chat.row["levelNames"]?.array ?? []).compactMap(\.string)
        let name = i < names.count && !names[i].trimmingCharacters(in: .whitespaces).isEmpty ? names[i] : "第 \(i + 1) 级"
        let hi: Double? = i + 1 < levels.count ? levels[i + 1] : nil
        return Level(level: i + 1, max: levels.count, name: name,
                     progress: hi.map { min(1, (sc - levels[i]) / ($0 - levels[i])) } ?? 1, next: hi.map { Int($0) })
    }

    /// 注入的那一段（区块抬头 [互动标识] 是协议）。只给事实：数字、状态、名字（第 16 条）。开关默认关
    static func block(_ chat: Chat, msgs: [Message], now: Date = Date()) -> String {
        guard aware(chat), chat.row["stats"] != nil else { return "" }
        var lines: [String] = []
        let s = streak(chat, now: now)
        switch s.state {
        case "lit": lines.append("Days in a row on which both sides have messaged: \(s.n). Today counts.")
        case "risk": lines.append("Days in a row on which both sides have messaged: \(s.n). Today does not count yet; the run ends at midnight unless both sides message today.")
        case "ember": lines.append("A run of \(s.n) days ended yesterday. It resumes if the character opens today's conversation and both sides message.")
        default: if s.best > 0 { lines.append("The longest run of days on which both sides messaged was \(s.best).") }
        }
        let lv = level(chat, now: now)
        lines.append("Level: \(lv.name) (\(lv.level) of \(lv.max)).")
        // 上一次角色开口之后才解锁的，算「刚刚」
        let since = msgs.last(where: { $0.role == .char && !$0.isError })?.createdAt ?? 0
        var all = chat.row["unlocked"]?.object ?? [:]
        for (k, v) in chat.row["limited"]?.object ?? [:] { all[k] = v }
        let fresh = all.filter { ($0.value.number ?? 0) > since }.keys.sorted().map(label).filter { !$0.isEmpty }
        if !fresh.isEmpty { lines.append("Unlocked just now: \(fresh.joined(separator: "; ")).") }
        return "\n\n[互动标识]\n" + lines.joined(separator: "\n")
    }
}
