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
        if id.hasPrefix("custom-") { return BadgeDefs.label(id) }
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
    ///
    /// 要过的消息多于 inlineMax 条时（导进来的大会话第一次打开、「重新统计」、落下太多）不在这里过：
    /// 交给后台分批过（startPass），这一次返回空，界面先显示原来的统计（没有就空着），过完发 didFinish
    @discardableResult
    static func sync(_ chatId: String, full: Bool = false, now: Date = Date()) throws -> [String] {
        // 后台正在过这一段：不另过一遍（要整段重算的记下来，那边过完这一批就从头来）
        if passBusy(chatId, full: full) { return [] }
        guard var chat = try Repo.chat(chatId) else { return [] }
        // 上一次没过完（中途应用被关掉）：接着过
        if let p = try savedPass(chatId) {
            if p.base == fingerprint(chat), p.full || !full {
                startPass(chatId, full: p.full)
                return []
            }
            // 统计已经被别处换掉了（导入、恢复备份）：那份进度作废
            if p.base != fingerprint(chat) { try Database.shared.setNativeMeta(metaKey(chatId), nil) }
        }
        let nowMs = now.millis
        let begin = initial(chat, full: full)
        let redo = begin.redo
        var st = begin.st
        var unlocked = begin.unlocked
        var lim = begin.lim
        var news: [String] = []
        func got(_ id: String, _ at: Double, _ isLimited: Bool) {
            if isLimited { if lim[id] == nil { lim[id] = .number(at); news.append(id) } }
            else if unlocked[id] == nil { unlocked[id] = .number(at); news.append(id) }
        }
        let c = ctx(chat)
        let upTo = st["upTo"]?.number ?? 0
        var edge = Set((st["edge"]?.array ?? []).compactMap(\.string))
        // 只读需要的那一段：先读末尾一截，没盖住 upTo 再读水位线之后的（upTo 为 0 时整段）；太多就交给后台
        var list = try Repo.messages(chatId: chatId, limit: 300)
        if list.count >= 300, let first = list.first, first.createdAt > upTo {
            let db = Database.shared
            let left = try upTo > 0 ? db.count(Collections.messages, where: chatId, since: upTo) : db.count(Collections.messages, where: chatId)
            if left > inlineMax {
                startPass(chatId, full: full)
                return []
            }
            // 水位线之前的下面也是跳过（t < mark），不读它们结果一样
            list = try upTo > 0 ? Repo.messages(chatId: chatId, since: upTo) : Repo.messages(chatId: chatId)
        }
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
        // 自定义标识里「按条件」的那几个（网页版 4.320）
        let scanFrom = scanSince(chat, st)
        let cu = BadgeDefs.reached(chat, &st, msgs: { (try? scanMessages(chatId, since: scanFrom)) ?? [] }, now: nowMs)
        for id in cu.hits { got(id, nowMs, false) }
        if cu.changed { moved = true }
        guard moved || !news.isEmpty || redo else { return [] }
        chat.row["stats"] = .object(st)
        chat.row["unlocked"] = .object(unlocked)
        chat.row["limited"] = .object(lim)
        try Repo.save(chat)
        return redo ? [] : news
    }

    /// 从哪一份统计开始：整段重算或者统计格式变了时从空白开始，否则接着存着的
    private static func initial(_ chat: Chat, full: Bool) -> (redo: Bool, st: [String: JSONValue], unlocked: [String: JSONValue], lim: [String: JSONValue]) {
        let stored = chat.row["stats"]?.object
        let redo = full || stored == nil || stored?["v"]?.number != version
        let st = redo ? blank() : stored!
        var unlocked = redo && full ? [:] : (chat.row["unlocked"]?.object ?? [:])
        // 重新统计时，手动颁发与模型判断给的那几枚不是按记录算出来的，留着（算不回来）
        if redo && full {
            for (k, v) in chat.row["unlocked"]?.object ?? [:] where k.hasPrefix("custom-") && BadgeDefs.get(BadgeDefs.defIdOf(k))?.how != "rule" {
                unlocked[k] = v
            }
        }
        let lim = redo && full ? [:] : (chat.row["limited"]?.object ?? [:])
        return (redo, st, unlocked, lim)
    }

    /// 自定义「按条件」里要数消息的那几项从哪一刻往后数（BadgeDefs.measure 只看比各自 upTo 新的）。
    /// 有一项要从头数（没数过、条件改过）时为 nil：整段都要
    private static func scanSince(_ chat: Chat, _ st: [String: JSONValue]) -> Double? {
        let defs = BadgeDefs.defsFor(chat).filter { $0.how == "rule" && BadgeDefs.metric($0.metricId).scan }
        guard !defs.isEmpty else { return nil }
        let cx = st["cx"]?.object ?? [:]
        var from = Double.infinity
        for d in defs {
            let c = cx[d.id]?.object
            // 写法与 BadgeDefs.measure 里的 sig 一致；那边改了写法这里对不上，退回整段读（只是慢，不会算错）
            guard c?["sig"]?.string == "\(d.metricId)|\(d.who)|\(d.word)|\(d.kind)", let up = c?["upTo"]?.number, up > 0 else { return nil }
            from = min(from, up)
        }
        return from
    }

    private static func scanMessages(_ chatId: String, since: Double?) throws -> [Message] {
        if let since { return try Repo.messages(chatId: chatId, since: since) }
        return try Repo.messages(chatId: chatId)
    }

    // MARK: - 从头过一遍放到后台

    /// 要过的消息多于这个数时放到后台分批过，打开会话不等它（10 万条从头过一遍要好几秒）
    nonisolated(unsafe) static var inlineMax = 2000
    /// 后台一批过多少条。每过完一批记一次进度，应用中途被关掉，下次打开接着过
    nonisolated(unsafe) static var chunk = 2000
    /// 后台过完一段会话时发出（在主线程），object 是 chatId；失败时 userInfo["error"] 是原因。界面收到后重读会话
    static let didFinish = Notification.Name("eira.badges.didFinish")

    private static let passLock = NSLock()
    nonisolated(unsafe) private static var passRunning: Set<String> = []
    nonisolated(unsafe) private static var passFullAsked: Set<String> = []

    /// 这段会话的统计是不是正在后台过
    static func passActive(_ chatId: String) -> Bool { passLock.withLock { passRunning.contains(chatId) } }

    private static func passBusy(_ chatId: String, full: Bool) -> Bool {
        passLock.withLock {
            guard passRunning.contains(chatId) else { return false }
            if full { passFullAsked.insert(chatId) }
            return true
        }
    }

    private static func metaKey(_ chatId: String) -> String { "badges.pass.\(chatId)" }

    /// 存着的统计的指纹。进度记下之后统计被别处换掉了（导入、恢复备份），进度作废
    private static func fingerprint(_ chat: Chat) -> String {
        let st = chat.row["stats"]?.object
        return "\(st?["v"]?.number ?? -1)|\(st?["upTo"]?.number ?? -1)|\(chat.row.created ?? 0)"
    }

    /// 生日、纪念日这些变了，已经过的那一段按旧的算过，从头来
    private static func ctxSig(_ c: Ctx) -> String {
        ([c.charBday, c.myBday, c.love, String(c.loveYear)] + c.days.map { "\($0.id)=\($0.md)" }).joined(separator: "|")
    }

    /// 后台那一遍的进度（存在原生版自己的记号里，不进备份）
    private struct Pass: Sendable {
        var full: Bool
        var base: String
        var sig: String
        var st: [String: JSONValue]
        var unlocked: [String: JSONValue]
        var lim: [String: JSONValue]
        /// 开始时会话上的 unlocked 与 limited：过完写回时，和这期间别处的改动（手动颁发、收回）合在一起
        var startUnlocked: [String: JSONValue]
        var startLim: [String: JSONValue]
        /// 过到哪一条了（含）。nil：从第一条起
        var cursor: Database.PageKey?

        var json: JSONValue {
            var cur = JSONValue.null
            if let k = cursor { cur = .object(["c": k.created.map { JSONValue.number($0) } ?? .null, "id": .string(k.id)]) }
            return .object(["v": .number(Badges.version), "full": .bool(full), "base": .string(base), "sig": .string(sig),
                            "st": .object(st), "unlocked": .object(unlocked), "lim": .object(lim),
                            "su": .object(startUnlocked), "sl": .object(startLim), "cursor": cur])
        }

        init(full: Bool, base: String, sig: String, st: [String: JSONValue], unlocked: [String: JSONValue], lim: [String: JSONValue],
             startUnlocked: [String: JSONValue], startLim: [String: JSONValue], cursor: Database.PageKey?) {
            self.full = full; self.base = base; self.sig = sig; self.st = st; self.unlocked = unlocked; self.lim = lim
            self.startUnlocked = startUnlocked; self.startLim = startLim; self.cursor = cursor
        }

        init?(_ v: JSONValue) {
            guard let o = v.object, o["v"]?.number == Badges.version, let st = o["st"]?.object else { return nil }
            full = o["full"]?.bool ?? false
            base = o["base"]?.string ?? ""
            sig = o["sig"]?.string ?? ""
            self.st = st
            unlocked = o["unlocked"]?.object ?? [:]
            lim = o["lim"]?.object ?? [:]
            startUnlocked = o["su"]?.object ?? [:]
            startLim = o["sl"]?.object ?? [:]
            if let c = o["cursor"]?.object, let id = c["id"]?.string { cursor = Database.PageKey(created: c["c"]?.number, id: id) }
            else { cursor = nil }
        }
    }

    private static func savedPass(_ chatId: String) throws -> Pass? {
        guard let s = try Database.shared.nativeMeta(metaKey(chatId)) else { return nil }
        guard let v = try? JSONValue.parse(Data(s.utf8)) else { return nil }
        return Pass(v)
    }

    /// 有没有存着一份没过完的进度（测试用）
    static func passSaved(_ chatId: String) -> Bool { ((try? savedPass(chatId)) ?? nil) != nil }

    private static func savePass(_ chatId: String, _ p: Pass) throws {
        try Database.shared.setNativeMeta(metaKey(chatId), String(decoding: try p.json.encoded(), as: UTF8.self))
    }

    private enum PassResult { case done(Pass), stopped, gone }

    /// 放到后台过。已经在过了就不另起；要整段重算的记下来，那边过完这一批从头来
    private static func startPass(_ chatId: String, full: Bool) {
        let fresh: Bool = passLock.withLock {
            if full { passFullAsked.insert(chatId) }
            return passRunning.insert(chatId).inserted
        }
        guard fresh else { return }
        let size = chunk
        Task.detached(priority: .utility) {
            var failure: String?
            do {
                while true {
                    let wantFull = passLock.withLock { passFullAsked.remove(chatId) != nil }
                    let r = try compute(chatId, full: wantFull, now: nil, size: size,
                                        stop: { passLock.withLock { passFullAsked.contains(chatId) } })
                    if case .stopped = r { continue }
                    if case .done(let p) = r {
                        // 写回会话在主线程做：和界面上别的改会话的写入排成一队，不互相盖掉
                        try await MainActor.run { try apply(p, chatId: chatId) }
                    }
                    break
                }
            } catch {
                failure = error.localizedDescription
                Diagnostics.shared.record("badges-sync-failed", ["error": error.localizedDescription])
            }
            passLock.withLock {
                passRunning.remove(chatId)
                passFullAsked.remove(chatId)
            }
            let info: [String: String]? = failure.map { ["error": $0] }
            await MainActor.run { NotificationCenter.default.post(name: didFinish, object: chatId, userInfo: info) }
        }
    }

    /// 在当前线程过完（或过 maxChunks 批就记下进度停下），过完写回。返回是否过完。
    /// 后台那一遍与这里是同一份做法；测试直接调它
    @discardableResult
    static func runPass(_ chatId: String, full: Bool = false, now: Date? = nil, chunk size: Int? = nil, maxChunks: Int? = nil) throws -> Bool {
        var n = 0
        let r = try compute(chatId, full: full, now: now, size: size ?? chunk, stop: {
            n += 1
            return maxChunks.map { n >= $0 } ?? false
        })
        switch r {
        case .done(let p):
            try apply(p, chatId: chatId)
            return true
        case .stopped: return false
        case .gone: return true
        }
    }

    /// 一批一批从前往后过（键集分页，每批读完就放开库），每批之后记进度、问一次 stop。
    /// 过法与 sync 里的一模一样：同样的起点、同样的跳过规则、同样的 step，最后同样补上档位与自定义标识
    private static func compute(_ chatId: String, full: Bool, now: Date?, size: Int, stop: () -> Bool) throws -> PassResult {
        guard let chat = try Repo.chat(chatId) else {
            try Database.shared.setNativeMeta(metaKey(chatId), nil)
            return .gone
        }
        let c = ctx(chat)
        let sig = ctxSig(c)
        var p: Pass
        if let saved = try savedPass(chatId), saved.base == fingerprint(chat), saved.sig == sig, saved.full || !full {
            p = saved
        } else {
            let begin = initial(chat, full: full)
            let upTo = begin.st["upTo"]?.number ?? 0
            // 水位线之前的过的时候也是跳过（t < mark），从水位线那一刻起读
            p = Pass(full: full, base: fingerprint(chat), sig: sig, st: begin.st, unlocked: begin.unlocked, lim: begin.lim,
                     startUnlocked: chat.row["unlocked"]?.object ?? [:], startLim: chat.row["limited"]?.object ?? [:],
                     cursor: upTo > 0 ? Database.PageKey(created: upTo, id: "") : nil)
        }
        var unlocked = p.unlocked
        var lim = p.lim
        func got(_ id: String, _ at: Double, _ isLimited: Bool) {
            if isLimited { if lim[id] == nil { lim[id] = .number(at) } }
            else if unlocked[id] == nil { unlocked[id] = .number(at) }
        }
        var mark = p.st["upTo"]?.number ?? 0
        var edge = Set((p.st["edge"]?.array ?? []).compactMap(\.string))
        let n = max(1, size)
        while true {
            let page = try Database.shared.page(Collections.messages, where: chatId, after: p.cursor, limit: n)
            for m in page.rows.map(Message.init(row:)) where m.kind != "typing" {
                let t = m.createdAt
                if t < mark || (t == mark && edge.contains(m.id)) { continue }
                if m.role != .user && m.role != .char { continue }
                step(&p.st, m, c, got)
                if t > mark { mark = t; edge.removeAll() }
                edge.insert(m.id)
            }
            if let e = page.edge { p.cursor = e }
            p.st["upTo"] = .number(mark)
            p.st["edge"] = .array(edge.sorted().map { .string($0) })
            p.unlocked = unlocked
            p.lim = lim
            if page.rows.count < n { break }
            try savePass(chatId, p)
            if stop() { return .stopped }
        }
        let nowMs = (now ?? Date()).millis
        // 档位与自定义标识按过完那一刻的会话算（这期间改过的定义、在一起的日子以它为准）
        let latest = try Repo.chat(chatId) ?? chat
        tierUnlocks(p.st, chat: latest, now: nowMs, got)
        let scanFrom = scanSince(latest, p.st)
        let cu = BadgeDefs.reached(latest, &p.st, msgs: { (try? scanMessages(chatId, since: scanFrom)) ?? [] }, now: nowMs)
        for id in cu.hits { got(id, nowMs, false) }
        p.unlocked = unlocked
        p.lim = lim
        return .done(p)
    }

    /// 过完写回会话。这期间别处加上、改过、去掉的那几枚照别处的
    private static func apply(_ p: Pass, chatId: String) throws {
        guard var chat = try Repo.chat(chatId) else {
            try Database.shared.setNativeMeta(metaKey(chatId), nil)
            return
        }
        func merged(_ mine: [String: JSONValue], start: [String: JSONValue], now: [String: JSONValue]) -> [String: JSONValue] {
            var out = mine
            for (k, v) in now where start[k] != v { out[k] = v }
            for k in start.keys where now[k] == nil { out[k] = nil }
            return out
        }
        chat.row["stats"] = .object(p.st)
        chat.row["unlocked"] = .object(merged(p.unlocked, start: p.startUnlocked, now: chat.row["unlocked"]?.object ?? [:]))
        chat.row["limited"] = .object(merged(p.lim, start: p.startLim, now: chat.row["limited"]?.object ?? [:]))
        try Repo.save(chat)
        try Database.shared.setNativeMeta(metaKey(chatId), nil)
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

    // MARK: - 颁发（网页版 addAward / dropAward）

    struct Award: Identifiable, Equatable {
        var id: String, name: String, reason: String, by: String, to: String, msgId: String, at: Double
    }

    static func awards(_ chat: Chat?) -> [Award] {
        (chat?.row["awards"]?.array ?? []).compactMap(\.object).map { o in
            Award(id: o["id"]?.string ?? "", name: o["name"]?.string ?? "", reason: o["reason"]?.string ?? "",
                  by: o["by"]?.string ?? "", to: o["to"]?.string ?? "", msgId: o["msgId"]?.string ?? "", at: o["at"]?.number ?? 0)
        }
    }

    /// 记一枚颁发的标识。by：谁颁的（me 或角色 id），to：颁给谁
    @discardableResult
    static func addAward(_ chatId: String, name: String, reason: String = "", by: String, to: String, msgId: String = "",
                         at: Double = Date().millis) throws -> Award? {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard !n.isEmpty, var chat = try Repo.chat(chatId) else { return nil }
        let a = Award(id: "aw_" + String(Int(at), radix: 36) + String(UUID().uuidString.prefix(4)).lowercased(), name: n,
                      reason: String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)), by: by, to: to, msgId: msgId, at: at)
        var list = chat.row["awards"]?.array ?? []
        list.append(.object(["id": .string(a.id), "name": .string(a.name), "reason": .string(a.reason), "by": .string(by),
                             "to": .string(to), "msgId": .string(msgId), "at": .number(at)]))
        chat.row["awards"] = .array(list)
        try Repo.save(chat)
        return a
    }

    static func dropAward(_ chatId: String, id: String? = nil, msgId: String? = nil) throws {
        guard var chat = try Repo.chat(chatId) else { return }
        let list = chat.row["awards"]?.array ?? []
        let kept = list.filter { v in
            if let id, v["id"]?.string == id { return false }
            if let msgId, !msgId.isEmpty, v["msgId"]?.string == msgId { return false }
            return true
        }
        guard kept.count != list.count else { return }
        chat.row["awards"] = .array(kept)
        try Repo.save(chat)
    }

    /// 每一级的名字由用户填，空着就是「第 n 级」
    static func setLevelNames(_ chatId: String, _ names: [String]) throws {
        guard var chat = try Repo.chat(chatId) else { return }
        chat.row["levelNames"] = .array(names.map { .string(String($0.trimmingCharacters(in: .whitespaces).prefix(12))) })
        try Repo.save(chat)
    }

    // MARK: - 年度回顾（网页版 yearOf，全部本地算）

    struct Year {
        var year: Int, n = 0, nU = 0, nC = 0, activeDays = 0, bothDays = 0
        var busiest: (at: Double, n: Int)?
        var latest: Double?
        var bestStreak = 0
        var words: [(w: String, n: Int)] = []
        var unlocked: [String] = [], limited: [String] = []
        var awards: [Award] = []
    }

    private static let stop: Set<String> = ["我们", "你们", "他们", "她们", "什么", "一个", "这个", "那个", "没有", "就是",
        "还是", "可以", "知道", "现在", "今天", "怎么", "不是", "已经", "因为", "所以", "然后", "但是",
        "自己", "这样", "真的", "一下", "时候", "觉得", "那么", "这么", "一点", "有点", "如果", "的话"]

    /// 最常说的几个词：系统分词，去掉方括号标记与虚词
    static func topWords(_ texts: [String], n: Int = 5) -> [(w: String, n: Int)] {
        var count: [String: Int] = [:]
        for raw in texts {
            let t = raw.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            t.enumerateSubstrings(in: t.startIndex..<t.endIndex, options: .byWords) { w, _, _, _ in
                guard let w, w.count >= 2, !stop.contains(w), w.rangeOfCharacter(from: .letters) != nil else { return }
                count[w, default: 0] += 1
            }
        }
        return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map { (w: $0.key, n: $0.value) }
    }

    static func yearOf(_ chat: Chat, msgs: [Message], year: Int, words: Bool = true) -> Year {
        let cal = Calendar.current
        let from = cal.date(from: DateComponents(year: year, month: 1, day: 1))?.millis ?? 0
        let to = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))?.millis ?? 0
        let list = msgs.filter { $0.createdAt >= from && $0.createdAt < to && !$0.isError && ($0.role == .user || $0.role == .char) && $0.kind != "notice" }
        var y = Year(year: year)
        y.n = list.count
        y.nU = list.filter { $0.role == .user }.count
        y.nC = list.count - y.nU
        var byDay: [Int: Int] = [:]
        var days: [Int: (u: Bool, c: Bool)] = [:]
        var latestMins = -1
        for m in list {
            let k = dayNo(m.createdAt)
            byDay[k, default: 0] += 1
            var d = days[k] ?? (false, false)
            if m.role == .user { d.u = true } else { d.c = true }
            days[k] = d
            // 「最晚」指一天里最晚的钟点：五点为一天的开始，凌晨四点比晚上十一点更晚
            let comp = cal.dateComponents([.hour, .minute], from: Date(millis: m.createdAt))
            let mins = (((comp.hour ?? 0) + 19) % 24) * 60 + (comp.minute ?? 0)
            if mins > latestMins { latestMins = mins; y.latest = m.createdAt }
        }
        var run = 0, last: Int?
        for k in days.keys.sorted() {
            guard let d = days[k], d.u && d.c else { continue }
            run = last == k - 1 ? run + 1 : 1
            last = k
            y.bestStreak = max(y.bestStreak, run)
        }
        y.activeDays = byDay.count
        y.bothDays = days.values.filter { $0.u && $0.c }.count
        if let b = byDay.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
           let first = list.first(where: { dayNo($0.createdAt) == b.key }) {
            y.busiest = (first.createdAt, b.value)
        }
        if words { y.words = topWords(list.filter { $0.kind == "text" }.map(\.content)) }
        let inYear = { (at: Double) in at >= from && at < to }
        y.unlocked = (chat.row["unlocked"]?.object ?? [:]).filter { inYear($0.value.number ?? 0) }.keys.sorted()
        y.limited = (chat.row["limited"]?.object ?? [:]).filter { inYear($0.value.number ?? 0) }.keys.sorted()
        y.awards = awards(chat).filter { inYear($0.at) }
        return y
    }

    // MARK: - 断火提醒（网页版 tick 的提醒那一半）

    /// 快断了提醒（默认开）；几点提醒（默认 21 点）
    static func remindOn(_ chat: Chat?) -> Bool { chat?.row["badgeRemind"]?.bool != false }
    static func remindHour(_ chat: Chat?) -> Int {
        let h = Int(chat?.row["badgeRemindHour"]?.number ?? 21)
        return (0...23).contains(h) ? h : 21
    }

    /// 本地通知，不调接口。火花连着三天以上、某天还没互发时，那天 remindHour 点提醒一次：
    /// 今天还没互发就排今天，今天已经互发就排明天（明天不打开应用也照样提醒）；熄了、关了提醒就不排。
    /// 系统按标识只留一条，排几次都只响一次
    static func remindPlan(_ chat: Chat, now: Date = Date()) -> (at: Date, n: Int)? {
        guard shown(chat), remindOn(chat) else { return nil }
        let s = streak(chat, now: now)
        guard s.n >= 3, s.state == "risk" || s.state == "lit" else { return nil }
        let cal = Calendar.current
        guard let day = s.state == "lit" ? cal.date(byAdding: .day, value: 1, to: now) : now,
              let at = cal.date(bySettingHour: remindHour(chat), minute: 0, second: 0, of: day), at > now else { return nil }
        return (at, s.n)
    }

    // MARK: - 群里的周榜（网页版 weeklyTitles）

    /// 本周（周一零点起）的起点
    static func weekStart(_ now: Date = Date()) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: now)?.start.millis ?? now.millis
    }

    /// 按自然周现算，不存。话痨：这周说得最多的；团宠：这周被你 @ 得最多的；夜猫子：这周零点到五点说得最多的。都有门槛，不够的空着
    static func weeklyTitles(_ chat: Chat, msgs: [Message], now: Date = Date()) -> [String: [String]] {
        guard chat.isGroup else { return [:] }
        let from = weekStart(now)
        var talk: [String: Int] = [:], pet: [String: Int] = [:], owl: [String: Int] = [:]
        for m in msgs where m.createdAt >= from && !m.isError {
            if m.role == .char {
                talk[m.authorId, default: 0] += 1
                if Calendar.current.component(.hour, from: Date(millis: m.createdAt)) < 5 { owl[m.authorId, default: 0] += 1 }
            } else if m.role == .user {
                for id in (m.row["mentions"]?.array ?? []).compactMap(\.string) { pet[id, default: 0] += 1 }
            }
        }
        var out: [String: [String]] = [:]
        func top(_ map: [String: Int], _ min: Int, _ title: String) {
            guard let best = map.filter({ $0.value >= min }).max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { return }
            out[best.key, default: []].append(title)
        }
        top(talk, 5, "话痨")
        top(pet, 2, "团宠")
        top(owl, 3, "夜猫子")
        return out
    }
}
