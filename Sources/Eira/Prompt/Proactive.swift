import Foundation

/// 角色主动发起对话（网页版 system/ai/proactive.js）。
///
/// 开关在角色身上（会话设置里），默认关。应用开着时本机按间隔发；退到后台交给后台消息服务器（BgPush），
/// 同一次开口只能扣一次钱：服务器管着的时候本机不发，落点也不动。
/// **先排下一次再发**：落点在发请求之前就挪走，失败也要再等一个完整的间隔（网页版第 15 条）。
enum Proactive {
    struct Config: Equatable {
        var on = false
        var minutes = 60.0
        var quietFrom = 0
        var quietTo = 8
        // 深夜那一档（网页版 emo）：夜里睡不着时才会冒出来的那种话。只在这个时段之间、距上次至少隔几天。
        // 和平常的主动消息是两件事，各有各的开关；不受免打扰限制（它本来就在夜里）
        var emo = false
        var emoFrom = 1
        var emoTo = 4
        var emoDays = 5
    }

    /// 对话末尾那一句：这一轮没有新消息，由角色开口（后台消息服务器接着发第二条时也用它）。
    static let closing = "(No new messages. You are the one opening this time.)"

    static func config(_ char: Character?) -> Config {
        guard let c = char?.row else { return Config() }
        func hour(_ k: String, _ d: Int) -> Int {
            guard let n = c[k]?.number else { return d }
            return min(23, max(0, Int(n.rounded())))
        }
        let m = c["proactiveMinutes"]?.number ?? 60
        // 封存的角色不再主动发起对话（网页版 4.557）
        // 填 0 是「每晚都可能」，是个合法值
        let days = c["emoDays"]?.number.map { max(0, Int($0.rounded())) } ?? 5
        return Config(on: c["proactive"]?.bool == true && char?.archived != true, minutes: max(1, m > 0 ? m : 60),
                      quietFrom: hour("proactiveQuietFrom", 0), quietTo: hour("proactiveQuietTo", 8),
                      emo: c["emo"]?.bool == true, emoFrom: hour("emoFrom", 1), emoTo: hour("emoTo", 4), emoDays: days)
    }

    // MARK: - 落点（本机的临时状态，不进库，不进备份）

    private static let key = "phone.proactive.next"
    private static let lock = NSLock()

    static func map() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
    }

    static func nextAt(_ charId: String) -> Double { map()[charId] ?? 0 }

    static func setNext(_ charId: String, _ t: Double) {
        lock.lock(); defer { lock.unlock() }
        var m = map()
        if t > 0 { m[charId] = t } else { m[charId] = nil }
        UserDefaults.standard.set(m, forKey: key)
    }

    // 深夜那一档上次是什么时候：单独记，「不要反复触发」（本机的临时状态，不进库）
    private static let emoKey = "phone.proactive.emo"
    static func emoAt(_ charId: String) -> Double {
        ((UserDefaults.standard.dictionary(forKey: emoKey) as? [String: Double]) ?? [:])[charId] ?? 0
    }
    static func setEmoAt(_ charId: String, _ t: Double) {
        lock.lock(); defer { lock.unlock() }
        var m = (UserDefaults.standard.dictionary(forKey: emoKey) as? [String: Double]) ?? [:]
        m[charId] = t
        UserDefaults.standard.set(m, forKey: emoKey)
    }

    static func inEmoHours(_ c: Config, _ d: Date = Date()) -> Bool {
        let a = c.emoFrom, b = c.emoTo
        if a == b { return false }
        let h = Calendar.current.component(.hour, from: d)
        return a < b ? (h >= a && h < b) : (h >= a || h < b)
    }

    /// 今晚这一条该不该来：开着、到点、距上次够久
    static func emoDue(_ charId: String, _ c: Config, now: Double) -> Bool {
        guard c.emo, inEmoHours(c, Date(millis: now)) else { return false }
        return now - emoAt(charId) >= Double(c.emoDays) * 86_400_000
    }

    /// 0.5 到 1.5 倍间隔之间随机掷一个。定死的间隔像闹钟。
    static func roll(_ minutes: Double) -> Double { (max(1, minutes) * 60000 * (0.5 + Double.random(in: 0..<1))).rounded() }

    static func inQuiet(_ c: Config, _ d: Date = Date()) -> Bool {
        if c.quietFrom == c.quietTo { return false }
        let h = Calendar.current.component(.hour, from: d)
        return c.quietFrom < c.quietTo ? (h >= c.quietFrom && h < c.quietTo) : (h >= c.quietFrom || h < c.quietTo)
    }

    static func quietEndsAt(_ c: Config, _ d: Date = Date()) -> Double {
        var end = Calendar.current.date(bySettingHour: c.quietTo, minute: 0, second: 0, of: d) ?? d
        if end <= d { end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end }
        return end.millis
    }

    /// 改了设置之后重新掷一次。
    static func reschedule(_ charId: String, now: Double = Date().millis) {
        let c = config(try? Repo.character(charId))
        setNext(charId, c.on ? now + roll(c.minutes) : 0)
    }

    /// 落点已经过了的，全部重新掷。回到前台、取回服务器结果之后调：离开期间到点的那几次归服务器，本机不补。
    @discardableResult
    static func rescheduleOverdue(now: Double = Date().millis) -> Int {
        let ids = map().filter { !$0.key.hasPrefix("g:") && $0.value > 0 && $0.value <= now }.map(\.key)
        ids.forEach { reschedule($0, now: now) }
        return ids.count
    }

    // MARK: - 会话

    /// 当前身份与这个角色的单人会话。
    static func soloChat(_ charId: String) -> Chat? {
        let me = (try? Repo.activePersona())?.id ?? ""
        return ((try? Repo.chats()) ?? []).first { c in
            c.characterIds == [charId] && !c.isGroup && (c.personaId.isEmpty || c.personaId == me)
        }
    }

    /// 还能再堆几条未读。0 表示不设上限。
    static func roomLeft(_ chat: Chat, _ s: AppSettings = .load()) -> Int {
        let cap = Int(s.raw["proactiveMaxUnread"]?.number ?? 3)
        return cap > 0 ? max(0, cap - chat.unread) : 0
    }

    /// 这个角色现在能不能被发：有单人会话、未读没堆满、没在生成。
    static func chatReady(_ charId: String, _ s: AppSettings = .load()) -> Chat? {
        guard let chat = soloChat(charId) else { return nil }
        let cap = Int(s.raw["proactiveMaxUnread"]?.number ?? 3)
        if cap > 0 && chat.unread >= cap { return nil }
        if Running.has(chat.id) { return nil }
        return chat
    }

    /// 正在聊的时候不插话：最后一条消息离现在不到平均间隔的一半，落点从那条消息起重新掷。
    static func holdUntil(_ chat: Chat?, _ minutes: Double, now: Double) -> Double {
        guard let chat else { return 0 }
        let last = max(chat.row.number("lastMessageAt") ?? 0, ((try? Repo.messages(chatId: chat.id, limit: 1)) ?? []).last?.row.number("createdAt") ?? 0)
        if last > 0 && now - last < max(1, minutes) * 60000 * 0.5 { return last + roll(minutes) }
        return 0
    }

    /// 后台消息用：接下来 count 次开口的时间。落进免打扰的挪到免打扰结束那一刻。
    static func upcoming(_ charId: String, count: Int, now: Double = Date().millis) -> [Double] {
        let c = config(try? Repo.character(charId))
        guard c.on, count > 0 else { return [] }
        var t = nextAt(charId)
        if t <= 0 { t = now + roll(c.minutes) }
        if t < now + 60000 { t = now + 60000 }
        let held = holdUntil(soloChat(charId), c.minutes, now: t)
        if held > 0 { t = held }
        var out: [Double] = []
        while out.count < count {
            if inQuiet(c, Date(millis: t)) { t = quietEndsAt(c, Date(millis: t)) }
            out.append(t)
            t += roll(c.minutes)
        }
        return out
    }

    // MARK: - 发

    static func gapText(_ ms: Double) -> String {
        if ms <= 0 { return "a long time" }
        let m = Int((ms / 60000).rounded())
        if m < 60 { return "\(max(1, m)) minutes" }
        let h = Int((Double(m) / 60).rounded())
        if h < 24 { return "\(h) hours" }
        return "\(Int((Double(h) / 24).rounded())) days"
    }

    static func timeText(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy/M/d HH:mm:ss"
        return f.string(from: d)
    }

    struct Payload {
        var system: String
        var messages: [AIMessage]
        var maxTokens = 800
    }

    /// 主动开口那一次请求的内容。带着聊天记录发；time 与 gap 可以留记号，由服务器到点按那一刻填。
    static func payload(chat: Chat, char: Character, time: String? = nil, gap: String? = nil, mood: Bool = false) throws -> Payload {
        let s = AppSettings.load().forChat(chat)
        let built = try ChatPrompt.build(chat: chat, char: char, settings: s)
        let last = try Repo.messages(chatId: chat.id).filter { !$0.isError }.last
        let instruction = Templates.render(mood ? "task.emo" : "task.proactive", [
            "charName": char.name.isEmpty ? "你" : char.name,
            "time": time ?? timeText(),
            "gap": gap ?? gapText(last.map { Date().millis - ($0.row.number("createdAt") ?? 0) } ?? 0),
        ], settings: s)
        return Payload(system: [built.system, instruction].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                       messages: CallEngine.mergeAdjacent(built.messages + [AIMessage(role: .user, content: closing)]))
    }

    /// 这一次由角色开口：一次请求，落成一轮，未读加上这几条。
    @discardableResult
    static func send(chatId: String, charId: String, mood: Bool = false, onRow: @escaping ChatEngine.OnRow = { _ in }) async throws -> [Message] {
        guard let chat = try Repo.chat(chatId), let char = try Repo.character(charId) else { throw StoreError(message: "会话或角色不存在") }
        guard Running.claim(chatId) else { return [] }
        defer { Running.release(chatId) }
        // 生成中这段会话的标题写「正在输入」（网页版 4.533）
        await MainActor.run { Typing.shared.begin(chatId) }
        do {
            let made = try await speak(chat: chat, char: char, mood: mood, onRow: onRow)
            await MainActor.run { Typing.shared.end(chatId) }
            return made
        } catch {
            await MainActor.run { Typing.shared.end(chatId) }
            throw error
        }
    }

    private static func speak(chat: Chat, char: Character, mood: Bool = false, onRow: @escaping ChatEngine.OnRow) async throws -> [Message] {
        let chatId = chat.id
        let p = try payload(chat: chat, char: char, mood: mood)
        let r = try await AIService.shared.send(task: "chat.proactive", system: p.system, messages: p.messages, maxTokens: p.maxTokens)
        let raw = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw StoreError(message: "模型返回了空内容") }
        let served: JSONValue = .object(["id": .string(r.presetId), "name": .string(r.presetName)])
        let made = try await ChatEngine.write(raw: raw, chat: chat, char: char, turnId: "p-\(Int(Date().millis))",
                                              versions: .init(swipes: [raw], index: 0, served: [served]), onRow: onRow)
        try bumpUnread(chatId, made.count)
        Notifier.post(chatId: chatId, title: char.displayName, text: raw)
        // 我的自动回复：角色主动来的这几条，同样替我回一句固定的
        _ = try? AutoReply.fire(chatId, AutoReply.mine)
        return made
    }

    static func bumpUnread(_ chatId: String, _ n: Int) throws {
        guard n > 0, var c = try Repo.chat(chatId) else { return }
        c.row["unread"] = .number(Double(c.unread + n))
        c.row.touch()
        try Repo.save(c)
    }

    /// 巡检一轮。holds 为真时这一次归服务器（退到后台了，或者服务器发过的还没取回来）：本机不发，落点也不动。
    /// 返回这一轮发出去的那几个角色。
    @discardableResult
    static func tick(now: Double = Date().millis, holds: Bool = false) async -> [String] {
        let s = AppSettings.load()
        guard !AIService.chain(task: "chat.proactive", group: RouteGroup.of(task: "chat.proactive"), settings: s).isEmpty else { return [] }
        var fired: [String] = []
        for char in (try? Repo.characters()) ?? [] {
            let c = config(char)
            if !c.on { if nextAt(char.id) > 0 { setNext(char.id, 0) }; continue }
            let next = nextAt(char.id)
            if next <= 0 { setNext(char.id, now + roll(c.minutes)); continue }
            if now < next { continue }
            let chat = chatReady(char.id, s)
            let held = holdUntil(chat, c.minutes, now: now)
            if held > 0 { if !holds { setNext(char.id, held) }; continue }
            // 深夜那一档排在免打扰前面：它本来就在夜里，默认免打扰正好是 0 点到 8 点。
            // 先记「试过」再发：落点挪走、深夜的时刻记上，失败也要再等够天数。只在应用开着时发，后台消息服务器不代发
            if !holds, let chat, emoDue(char.id, c, now: now), Ties.canReachUser(char.id, personaId: chat.personaId) {
                setNext(char.id, now + roll(c.minutes))
                setEmoAt(char.id, now)
                fired.append(char.id)
                do { try await send(chatId: chat.id, charId: char.id, mood: true) }
                catch {
                    Diagnostics.shared.record("emo-failed", ["error": error.localizedDescription])
                    Problems.report("\(char.displayName) 深夜主动发起对话失败：\(error.localizedDescription)。过了设定的天数再试。")
                }
                continue
            }
            if inQuiet(c, Date(millis: now)) { setNext(char.id, quietEndsAt(c, Date(millis: now))); continue }
            if holds { continue }
            // 先排下一次，再发：失败也要再等一个完整的间隔
            setNext(char.id, now + roll(c.minutes))
            guard let chat else { continue }
            // 它把你从联系人里删了：发不出来，不调接口（网页版 ties.canReachUser）
            if !Ties.canReachUser(char.id, personaId: chat.personaId) { continue }
            fired.append(char.id)
            do { try await send(chatId: chat.id, charId: char.id) }
            catch {
                Diagnostics.shared.record("proactive-failed", ["error": error.localizedDescription])
                Problems.report("\(char.displayName) 主动发起对话失败：\(error.localizedDescription)。下一次按间隔再试。")
            }
        }
        return fired
    }
}

/// 正在生成主动消息的会话。点「请角色回复」时不和它撞在一起。
enum Running {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var set: Set<String> = []

    static func claim(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return set.insert(id).inserted }
    static func release(_ id: String) { lock.lock(); defer { lock.unlock() }; set.remove(id) }
    static func has(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return set.contains(id) }
}
