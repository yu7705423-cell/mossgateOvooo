import Foundation

/// 自动回复（网页版 system/autoreply.js，ARCHITECTURE 4.319）。两个方向，存在会话上（chat.autoReply.mine / hers），与网页版同一格式：
///
///     mine  我不在：角色发来消息时，替我回一句固定的话
///     hers  角色那边：角色此刻在忙（日常里当前时段有事项）或在休息，我发消息就先收到一条自动回复。
///           那一句随每天的日程一并生成（items[].auto / sleepAuto），不另调接口；每段忙碌或休息只回一次。
///           当天日程里没有这一句时，用从前自己填的那一句；也没有就不回
///
/// 最容易出的毛病是忘了自己开着。我这边两道闸：条数到了、时限到了都自动关掉，并在对话里落一行提示。
/// 都是固定的话，不经过模型，一次接口都不调。
enum AutoReply {
    static let mine = "mine", hers = "hers"

    struct Config: Equatable {
        var on = false
        var text = ""
        var max = 3
        var used = 0
        var until: Double = 0
        var window = ""
    }

    static func config(_ chat: Chat, _ side: String) -> Config {
        let o = chat.row["autoReply"]?.object?[side]?.object ?? [:]
        var c = Config()
        c.on = o["on"]?.bool == true
        c.text = String((o["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        if let m = o["max"]?.number, m.isFinite { c.max = max(0, Int(m.rounded())) }
        c.used = max(0, Int((o["used"]?.number ?? 0).rounded()))
        c.until = max(0, o["until"]?.number ?? 0)
        c.window = o["window"]?.string ?? ""
        return c
    }

    private static func write(_ chatId: String, _ side: String, _ change: (inout [String: JSONValue]) -> Void) throws {
        guard var chat = try Repo.chat(chatId) else { return }
        var all = chat.row["autoReply"]?.object ?? [:]
        var cur = all[side]?.object ?? [:]
        change(&cur)
        all[side] = .object(cur)
        chat.row["autoReply"] = .object(all)
        chat.row.touch()
        try Repo.save(chat)
    }

    /// 改配置。开启时把用过的条数清零：新开一个窗口就是新的一轮
    static func set(_ chatId: String, _ side: String, _ patch: [String: JSONValue]) throws {
        try write(chatId, side) { cur in
            for (k, v) in patch {
                switch k {
                case "text": cur[k] = .string(String((v.string ?? "").prefix(200)))
                case "max": cur[k] = .number(Double(max(0, Int((v.number ?? 0).rounded()))))
                case "until": cur[k] = .number(max(0, v.number ?? 0))
                default: cur[k] = v
                }
            }
            if patch["on"]?.bool == true { cur["used"] = .number(0) }
        }
    }

    static func isOn(_ chat: Chat, _ side: String) -> Bool {
        let c = config(chat, side)
        return side == hers ? c.on : (c.on && !c.text.isEmpty)
    }

    /// 角色那边这一刻该回什么。不忙、不在休息、这一段已经回过、没有可回的话，都回 nil
    static func stateReply(_ chat: Chat, at real: Date = Date()) -> (text: String, key: String)? {
        guard isOn(chat, hers), let charId = chat.characterIds.first, let char = try? Repo.character(charId) else { return nil }
        let world = Clock.now(AppSettings.load(), real: real)
        let st = Pace.state(chat, char: char, at: world.millis)
        guard st.kind == "busy" || st.kind == "asleep" else { return nil }
        let key = "\(st.kind):\(Int(st.until / 60_000)):\(st.what)"
        guard config(chat, hers).window != key else { return nil }
        var text = ""
        if DayPlan.isOn(char), let d = try? DayPlan.day(char.id, date: DayPlan.dateKey(char, world)) {
            if st.kind == "asleep" {
                text = d.string("sleepAuto")
            } else {
                let cur = DayPlan.slotNow(char, world)
                let item = (d["items"]?.array ?? []).first(where: {
                    $0["slot"]?.string == cur.id && $0["state"]?.string == DayPlan.plan && !($0["auto"]?.string ?? "").isEmpty
                })
                text = item?["auto"]?.string ?? ""
            }
        }
        if text.isEmpty { text = config(chat, hers).text }
        return text.isEmpty ? nil : (text, key)
    }

    /// 到期或者用完了就关掉，并落一行提示说清楚为什么停
    private static func stop(_ chatId: String, _ side: String, _ why: String) throws -> Message? {
        guard let chat = try Repo.chat(chatId) else { return nil }
        try write(chatId, side) { $0["on"] = .bool(false); $0["used"] = .number(0) }
        let charName = (try? chat.characterIds.first.flatMap { try Repo.character($0) })?.name ?? "对方"
        let who = side == mine ? "你的" : "\(charName)的"
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: "[\(who)自动回复已停止：\(why)]", kind: "notice")
        m = try Repo.append(m)
        return m
    }

    /// 回一条。判断和收尾放在一处：到期、用完都在这里关掉，回完正好到顶也当场关掉。回落下的那几条（含停止的提示）
    @discardableResult
    static func fire(_ chatId: String, _ side: String, at real: Date = Date()) throws -> [Message] {
        guard let chat = try Repo.chat(chatId), isOn(chat, side) else { return [] }
        let char = try chat.characterIds.first.flatMap { try Repo.character($0) }
        if side == hers {
            guard let r = stateReply(chat, at: real) else { return [] }
            var m = Message.new(chatId: chatId, role: .char, authorId: char?.id ?? "", content: r.text)
            m.row["auto"] = .bool(true)
            m = try Repo.append(m)
            try write(chatId, hers) { $0["window"] = .string(r.key) }
            try touchChat(chatId)
            return [m]
        }
        let c = config(chat, mine)
        if c.until > 0 && real.millis >= c.until { return try stop(chatId, mine, "已到设定的结束时间").map { [$0] } ?? [] }
        if c.max > 0 && c.used >= c.max { return try stop(chatId, mine, "已达设定的条数上限").map { [$0] } ?? [] }
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: c.text)
        m.row["auto"] = .bool(true)
        m = try Repo.append(m)
        var out = [m]
        let used = c.used + 1
        try write(chatId, mine) { $0["used"] = .number(Double(used)) }
        if c.max > 0 && used >= c.max, let s = try stop(chatId, mine, "已达设定的条数上限") { out.append(s) }
        try touchChat(chatId)
        return out
    }

    private static func touchChat(_ chatId: String) throws {
        guard var c = try Repo.chat(chatId) else { return }
        c.row["lastMessageAt"] = .number(Date().millis)
        c.row.touch()
        try Repo.save(c)
    }

    /// 会话列表上名字旁的小字：对方的自动回复开着写「忙碌」或「休息」，只开了我的写「自动回复」
    static func listTag(_ chat: Chat) -> String {
        if isOn(chat, hers) {
            let char = chat.characterIds.first.flatMap { try? Repo.character($0) }
            return Pace.state(chat, char: char, at: Clock.now(AppSettings.load()).millis).kind == "asleep" ? "休息" : "忙碌"
        }
        return isOn(chat, mine) ? "自动回复" : ""
    }
}
