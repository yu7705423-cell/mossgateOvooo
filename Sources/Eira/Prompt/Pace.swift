import Foundation

/// 角色什么时候回（网页版 system/pace.js，ARCHITECTURE 4.261）。三档，存在会话上（chat.paceMode），默认按按钮才回：
///
///     manual  按按钮才回
///     now     发完就回
///     paced   看角色这会儿在干什么：空闲几分钟内回；忙碌（日常里当前时段排着事）等这件事做完再回；
///             休息（免打扰时段里）起床后回
///
/// 忙碌、休息期间连发几条，角色回来只回一次，把几条一起读：到点时刻记在会话上（chat.pacePending），新消息不往后推。
/// 「多久」绝不问模型：状态全从本地数据推。到点的由会话页的定时器与全局巡检回掉，先清掉再生成，一次只调一次接口。
/// 应用不在前台时到点收不到，回到前台补上。
enum Pace {
    static let manual = "manual", now = "now", paced = "paced"
    static let modes = [manual, now, paced]

    static func mode(_ chat: Chat) -> String {
        let m = chat.row.string("paceMode")
        return modes.contains(m) ? m : manual
    }

    static func base(_ chat: Chat) -> Int {
        let n = Int((chat.row.number("paceBase") ?? 0).rounded())
        return n > 0 ? n : 60
    }

    /// 最长等多久（秒）。0 不封顶
    static func maxWait(_ chat: Chat) -> Int { max(0, Int((chat.row.number("paceMax") ?? 0).rounded())) }

    /// 休息时不回复（默认开）
    static func sleepOn(_ chat: Chat) -> Bool { chat.row["paceSleep"]?.bool != false }

    struct State: Equatable {
        var kind: String   // free / busy / asleep
        var what: String
        var until: Double
    }

    private static func clampHour(_ v: Double?, _ d: Int) -> Int {
        guard let v, v.isFinite else { return d }
        return min(23, max(0, Int(v.rounded())))
    }

    private static func inWindow(_ h: Int, _ from: Int, _ to: Int) -> Bool {
        from == to ? false : from < to ? (h >= from && h < to) : (h >= from || h < to)
    }

    /// 从 at 起，角色那边下一次到整点 hour 的时刻（毫秒）。当前正是那个小时就算下一天
    static func nextHourAt(_ char: Character, _ at: Double, _ hour: Int) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = DayPlan.zone(char)
        let d = Date(millis: at)
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        var dh = (hour - h + 24) % 24
        if dh == 0 { dh = 24 }
        return at + Double(dh * 60 - m) * 60_000
    }

    /// 角色这会儿在干什么。全从本地读：免打扰时段（休息）、日常（忙碌）。都不是就是空闲
    static func state(_ chat: Chat, char: Character?, at: Double) -> State {
        guard let char else { return State(kind: "free", what: "", until: 0) }
        let from = clampHour(char.row.number("proactiveQuietFrom"), 0)
        let to = clampHour(char.row.number("proactiveQuietTo"), 8)
        let h = DayPlan.hour(char, Date(millis: at))
        if sleepOn(chat) && inWindow(h, from, to) {
            return State(kind: "asleep", what: "休息中", until: nextHourAt(char, at, to))
        }
        if let b = DayPlan.brief(char, at: Date(millis: at)), let first = b.nowItems.first {
            return State(kind: "busy", what: first, until: nextHourAt(char, at, b.slot.to))
        }
        return State(kind: "free", what: "", until: 0)
    }

    /// 这一条该过多少秒再回。空闲：基准时长，带问号的减半，写得长的打七折，再乘 0.6 到 1.6 的抖动，运势差慢一点；
    /// 忙碌：这件事结束之后 0 到 15 分钟；休息：起床之后 0 到 20 分钟。最后按「最长等多久」封顶
    static func due(_ chat: Chat, char: Character?, text: String, at: Double, rng: () -> Double = { Double.random(in: 0..<1) })
        -> (secs: Int, state: State) {
        let st = state(chat, char: char, at: at)
        var dueAt: Double
        switch st.kind {
        case "asleep": dueAt = st.until + rng() * 20 * 60_000
        case "busy": dueAt = st.until + rng() * 15 * 60_000
        default:
            var secs = Double(base(chat))
            if let char, let b = DayPlan.brief(char, at: Date(millis: at)), b.luck < -0.4 { secs *= 1.3 }
            if text.contains("?") || text.contains("？") { secs *= 0.5 } else if text.count >= 30 { secs *= 0.7 }
            secs *= 0.6 + rng()
            dueAt = at + max(1, secs) * 1000
        }
        let cap = maxWait(chat)
        if cap > 0 { dueAt = min(dueAt, at + Double(cap) * 1000) }
        return (max(1, Int(((dueAt - at) / 1000).rounded())), st)
    }

    // MARK: - 待回复（记在会话上：页面关了也不取消）

    struct Pending: Equatable {
        var dueAt: Double
        var kind: String
        var what: String
    }

    static func pending(_ chat: Chat) -> Pending? {
        guard let p = chat.row["pacePending"]?.object, let at = p["dueAt"]?.number, at > 0 else { return nil }
        let st = p["state"]?.object ?? [:]
        return Pending(dueAt: at, kind: st["kind"]?.string ?? "free", what: st["what"]?.string ?? "")
    }

    /// 排一次。已经在等的取早的那个：忙碌、休息时角色回来一次把几条一起读，连发两条不该比只发一条回得更晚
    @discardableResult
    static func schedule(_ chatId: String, text: String, now real: Date = Date(),
                         rng: () -> Double = { Double.random(in: 0..<1) }) throws -> Pending? {
        guard var c = try Repo.chat(chatId) else { return nil }
        let char = try c.characterIds.first.flatMap { try Repo.character($0) }
        let world = Clock.now(AppSettings.load(), real: real).millis
        let d = due(c, char: char, text: text, at: world, rng: rng)
        let dueAt = real.millis + Double(d.secs) * 1000
        if let cur = pending(c), cur.dueAt <= dueAt { return cur }
        c.row["pacePending"] = .object(["dueAt": .number(dueAt), "secs": .number(Double(d.secs)),
                                        "state": .object(["kind": .string(d.state.kind), "what": .string(d.state.what)])])
        c.row.touch()
        try Repo.save(c)
        return pending(c)
    }

    static func clear(_ chatId: String) throws {
        guard var c = try Repo.chat(chatId), c.row["pacePending"] != nil, !(c.row["pacePending"]?.isNull ?? true) else { return }
        c.row["pacePending"] = .null
        c.row.touch()
        try Repo.save(c)
    }

    static func leftText(_ ms: Double) -> String {
        let s = Int((ms / 1000).rounded(.up))
        if s <= 0 { return "即将回复" }
        if s < 60 { return "约 \(s) 秒后回复" }
        if s < 3600 { return "约 \(Int((Double(s) / 60).rounded(.up))) 分钟后回复" }
        return "约 \(Int((Double(s) / 3600).rounded())) 小时后回复"
    }

    /// 连着状态一起写：「对方正在上课，约 2 小时后回复」
    static func pendingText(_ chat: Chat, now: Date = Date()) -> String {
        guard let p = pending(chat) else { return "" }
        let left = leftText(max(0, p.dueAt - now.millis))
        if p.kind == "busy" && !p.what.isEmpty { return "对方正在\(p.what)，\(left)" }
        if p.kind == "asleep" { return "对方在休息，\(left)" }
        return left
    }

    /// 到点的会话
    static func dueChats(now: Date = Date()) throws -> [Chat] {
        try Repo.chats().filter { c in (pending(c)?.dueAt ?? .infinity) <= now.millis }
    }

    /// 把到点的回掉。先清掉再生成：生成要好几秒，这期间巡检会再跑一轮。失败照常落一条失败的消息，不重试
    @discardableResult
    static func runDue(now: Date = Date()) async -> Int {
        guard let list = try? dueChats(now: now), !list.isEmpty else { return 0 }
        var done = 0
        for chat in list {
            // 这一段正在生成（会话页点的、主动消息）：下一次巡检再回，回复读得到它
            if await MainActor.run(body: { Typing.shared.isOn(chat.id) }) { continue }
            guard let fresh = try? Repo.chat(chat.id), pending(fresh) != nil else { continue }
            try? clear(chat.id)
            await MainActor.run { Typing.shared.begin(chat.id) }
            let before = (try? Repo.messages(chatId: chat.id).count) ?? 0
            do {
                try await ChatEngine.reply(chatId: chat.id) { _ in }
                done += 1
            } catch {
                Diagnostics.shared.record("pace-failed", ["error": error.localizedDescription])
            }
            let made = ((try? Repo.messages(chatId: chat.id).count) ?? 0) - before
            if made > 0 { try? Proactive.bumpUnread(chat.id, made) }
            await MainActor.run { Typing.shared.end(chat.id) }
        }
        return done
    }
}
