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

    // MARK: - 群聊：按成员各自设置（网页版 4.649）
    //
    // 从前群里那一页照单聊画，只有第一个成员；群聊发消息也不走自动回复。现在每个成员一份，存在 chat.autoReply.members[角色 id]：
    // on 与 window（同一段忙碌只回一次），和单聊那份同一个规矩：不调接口，内容取该成员当天日程里的那一句。

    struct Member: Equatable {
        var on = false
        var window = ""
    }

    static func member(_ chat: Chat, _ charId: String) -> Member {
        let o = chat.row["autoReply"]?.object?["members"]?.object?[charId]?.object ?? [:]
        return Member(on: o["on"]?.bool == true, window: o["window"]?.string ?? "")
    }

    /// 改某个成员的那一份。其余成员、单聊那两份原样留着
    static func setMember(_ chatId: String, _ charId: String, _ patch: [String: JSONValue]) throws {
        guard !charId.isEmpty, var chat = try Repo.chat(chatId) else { return }
        var all = chat.row["autoReply"]?.object ?? [:]
        var members = all["members"]?.object ?? [:]
        var cur = members[charId]?.object ?? [:]
        let base = member(chat, charId)
        if cur["on"] == nil { cur["on"] = .bool(base.on) }
        if cur["window"] == nil { cur["window"] = .string(base.window) }
        for (k, v) in patch { cur[k] = v }
        members[charId] = .object(cur)
        all["members"] = .object(members)
        chat.row["autoReply"] = .object(all)
        chat.row.touch()
        try Repo.save(chat)
    }

    /// 群里开着自动回复的成员有几位（菜单那一行用）
    static func membersOn(_ chat: Chat) -> Int {
        guard chat.isGroup else { return 0 }
        return chat.characterIds.filter { member(chat, $0).on }.count
    }

    private static func memberState(_ chat: Chat, _ charId: String, at real: Date) -> (state: Pace.State, key: String)? {
        guard member(chat, charId).on, let char = try? Repo.character(charId) else { return nil }
        let world = Clock.now(AppSettings.load(), real: real)
        let st = Pace.state(chat, char: char, at: world.millis)
        guard st.kind == "busy" || st.kind == "asleep" else { return nil }
        return (st, "\(st.kind):\(Int(st.until / 60_000)):\(st.what)")
    }

    /// 这个成员此刻该不该回、回什么。和 stateReply 同一个判断，按这个成员的作息与日程；没有当天日程里的那一句就不回
    static func memberReply(_ chat: Chat, _ charId: String, at real: Date = Date()) -> (text: String, key: String)? {
        guard let ms = memberState(chat, charId, at: real), member(chat, charId).window != ms.key,
              let char = try? Repo.character(charId), DayPlan.isOn(char) else { return nil }
        let st = ms.state, key = ms.key
        let world = Clock.now(AppSettings.load(), real: real)
        guard let d = try? DayPlan.day(char.id, date: DayPlan.dateKey(char, world)) else { return nil }
        var text = ""
        if st.kind == "asleep" {
            text = d.string("sleepAuto")
        } else {
            let cur = DayPlan.slotNow(char, world)
            text = (d["items"]?.array ?? []).first(where: {
                $0["slot"]?.string == cur.id && $0["state"]?.string == DayPlan.plan && !($0["auto"]?.string ?? "").isEmpty
            })?["auto"]?.string ?? ""
        }
        return text.isEmpty ? nil : (text, key)
    }

    /// 这个成员此刻是不是「已经回过自动回复、人还在忙」。群里这一轮写给他的话不落（和禁言同一个机制），群内身份那一块写明他不在
    static func memberAway(_ chat: Chat, _ charId: String, at real: Date = Date()) -> Pace.State? {
        guard let ms = memberState(chat, charId, at: real), member(chat, charId).window == ms.key else { return nil }
        return ms.state
    }

    /// 你在群里发了一条：在忙或在休息、开着的成员各回一句。回落下来的那几条
    @discardableResult
    static func fireGroup(_ chatId: String, at real: Date = Date()) throws -> [Message] {
        guard let chat = try Repo.chat(chatId), chat.isGroup else { return [] }
        var out: [Message] = []
        for id in chat.characterIds {
            guard let fresh = try Repo.chat(chatId), let r = memberReply(fresh, id, at: real) else { continue }
            var m = Message.new(chatId: chatId, role: .char, authorId: id, content: tag + r.text)
            m.row["auto"] = .bool(true)
            m = try Repo.append(m)
            try setMember(chatId, id, ["window": .string(r.key)])
            out.append(m)
        }
        if !out.isEmpty { try touchChat(chatId) }
        return out
    }

    /// 你在群里发了一条之后：各成员的自动回复落下来，以及这一条还要不要立即让群里回（网页版 afterSend 的群聊那一段）。
    /// 能发言的成员都回过自动回复时不再立即回，延迟回复档照常排到忙完之后
    static func afterGroupSend(_ chatId: String, at real: Date = Date()) throws -> (rows: [Message], hold: Bool) {
        let rows = try fireGroup(chatId, at: real)
        guard !rows.isEmpty, let chat = try Repo.chat(chatId) else { return (rows, false) }
        let speaking = GroupChat.speaking(chat, members: GroupChat.members(chat))
        return (rows, rows.count >= speaking.count)
    }

    // MARK: - 自动回复的标记（网页版 4.586）：自动回的那一条带 [自动回复]，停止的提示只给你看

    static let tag = "[自动回复] "
    private static let tagged = try! NSRegularExpression(pattern: #"^\s*[\[【]\s*自动回复\s*[\]】]"#)
    private static let stopped = try! NSRegularExpression(pattern: #"^\[[^\]]*自动回复已停止："#)
    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// 只给你看、不进提示词与记忆的那几行
    static func localOnly(_ m: Message) -> Bool {
        m.row.bool("local") || (m.kind == "notice" && matches(stopped, m.content))
    }

    /// 进提示词与记忆时的写法：从前没带标记的自动回复补上
    static func forPrompt(_ m: Message) -> Message {
        guard m.row.bool("auto"), !matches(tagged, m.content) else { return m }
        var out = m
        out.row["content"] = .string(tag + m.content)
        return out
    }

    /// 到期或者用完了就关掉，并落一行提示说清楚为什么停
    private static func stop(_ chatId: String, _ side: String, _ why: String) throws -> Message? {
        guard let chat = try Repo.chat(chatId) else { return nil }
        try write(chatId, side) { $0["on"] = .bool(false); $0["used"] = .number(0) }
        let charName = (try? chat.characterIds.first.flatMap { try Repo.character($0) })?.name ?? "对方"
        let who = side == mine ? "你的" : "\(charName)的"
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: "[\(who)自动回复已停止：\(why)]", kind: "notice")
        // 只给你看，不进提示词（网页版 4.586）
        m.row["local"] = .bool(true)
        m = try Repo.append(m)
        return m
    }

    /// 回一条。判断和收尾放在一处：到期、用完都在这里关掉，回完正好到顶也当场关掉。回落下的那几条（含停止的提示）
    @discardableResult
    static func fire(_ chatId: String, _ side: String, at real: Date = Date()) throws -> [Message] {
        guard let chat = try Repo.chat(chatId), isOn(chat, side) else { return [] }
        let char = try chat.characterIds.first.flatMap { try Repo.character($0) }
        if side == hers {
            // 群里角色那边按成员各一份（fireGroup），旧版在群里存下的这一份不算（网页版 4.649）
            guard !chat.isGroup, let r = stateReply(chat, at: real) else { return [] }
            var m = Message.new(chatId: chatId, role: .char, authorId: char?.id ?? "", content: tag + r.text)
            m.row["auto"] = .bool(true)
            m = try Repo.append(m)
            try write(chatId, hers) { $0["window"] = .string(r.key) }
            try touchChat(chatId)
            return [m]
        }
        let c = config(chat, mine)
        if c.until > 0 && real.millis >= c.until { return try stop(chatId, mine, "已到设定的结束时间").map { [$0] } ?? [] }
        if c.max > 0 && c.used >= c.max { return try stop(chatId, mine, "已达设定的条数上限").map { [$0] } ?? [] }
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: tag + c.text)
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
