import Foundation

/// 总结记忆（网页版 ai/tasks/memory-extract.js，ARCHITECTURE 4.441）。原生版先做一对一的会话。
///
/// 模型交回四组操作：新事件、新事实（可以取代旧的）、失效的事实、新的进行中的事、了结的事，外加整块重写的现状。
/// 更新不原地改写：新条顶旧条，旧条标 supersededBy 留在库里。
///
/// 花钱（网页版第 15 条）：手动「立即总结」调一次；自动总结默认关，三个门槛（轮数、条数、字数）都填 0。
/// 自动那一档**发请求之前**先记「试过到哪一条」，失败也算试过，要再攒够一个间隔才重试。
enum MemorySummary {
    struct Counts: Equatable, Sendable {
        var added = 0, updated = 0, closed = 0, state = 0
        var total: Int { added + updated + closed }
    }

    // MARK: - 积压

    /// 水位线之后的消息。标记所指的那一条不在了就按时间接（网页版 after）。
    private static func after(_ list: [Message], mark: String, at: Double) -> [Message] {
        guard !mark.isEmpty else { return list }
        if let i = list.firstIndex(where: { $0.id == mark }) { return Array(list[(i + 1)...]) }
        return at > 0 ? list.filter { $0.createdAt > at } : list
    }

    /// 线上的消息，加上线下各场的正文（按时间排在一起，网页版 4.375）：见面发生的事也要进记忆
    private static func usable(_ chatId: String) throws -> [Message] {
        let online = try Repo.messages(chatId: chatId).filter { !$0.isError && !$0.content.isEmpty }
        let beats = Scenes.beatsAsMessages(chatId: chatId)
        guard !beats.isEmpty else { return online }
        return (online + beats).enumerated().sorted { a, b in
            a.element.createdAt != b.element.createdAt ? a.element.createdAt < b.element.createdAt : a.offset < b.offset
        }.map(\.element)
    }

    /// 还没总结过的。
    static func pending(chatId: String) throws -> [Message] {
        guard let chat = try Repo.chat(chatId) else { return [] }
        return after(try usable(chatId), mark: chat.row.string("memoryUpTo"), at: chat.row.number("memoryUpToAt") ?? 0)
    }

    /// 上次试过之后积压的。
    static func sinceTried(chatId: String) throws -> [Message] {
        guard let chat = try Repo.chat(chatId) else { return [] }
        return after(try pending(chatId: chatId), mark: chat.row.string("memoryTriedId"), at: chat.row.number("memoryTriedAt") ?? 0)
    }

    /// 一次生成算一轮（turnId）；没有 turnId 的旧消息一条算一轮。
    static func roundsIn(_ list: [Message]) -> Int {
        Set(list.filter { $0.role == .char }.map { $0.turnId.isEmpty ? $0.id : $0.turnId }).count
    }

    /// 最近的 n 轮，不够 n 轮就全部。
    static func lastRounds(_ list: [Message], _ n: Int) -> [Message] {
        var keys = Set<String>()
        for i in stride(from: list.count - 1, through: 0, by: -1) where list[i].role == .char {
            let k = list[i].turnId.isEmpty ? list[i].id : list[i].turnId
            if !keys.contains(k) {
                if keys.count >= n { return Array(list[(i + 1)...]) }
                keys.insert(k)
            }
        }
        return list
    }

    /// 最早的 n 轮（网页版 4.606）：从头数 n 轮角色回复，连同它们前面你说的话；不够 n 轮就全部。
    /// 第 n 轮之后、下一轮角色回复之前你说的话属于下一轮，不切进来
    static func firstRounds(_ list: [Message], _ n: Int) -> [Message] {
        var keys = Set<String>()
        var end = -1
        for (i, m) in list.enumerated() where m.role == .char {
            let k = m.turnId.isEmpty ? m.id : m.turnId
            if !keys.contains(k) {
                if keys.count >= n { return end >= 0 ? Array(list[...end]) : [] }
                keys.insert(k)
            }
            end = i
        }
        return list
    }

    /// 从这一条起改回未总结（网页版 4.606）：水位线退到这一条的前一条，下一次总结从这里接着吃。
    /// 已经提取过的记忆不删，再总结时与已有记忆比对去重。不调接口。回改回了几条
    @discardableResult
    static func rewind(chatId: String, to msgId: String) throws -> Int {
        let all = try usable(chatId)
        guard let i = all.firstIndex(where: { $0.id == msgId }), var chat = try Repo.chat(chatId) else {
            throw StoreError(message: "这条消息已经不在了")
        }
        let before = try pending(chatId: chatId).count
        let prev = i > 0 ? all[i - 1] : nil
        chat.row["memoryUpTo"] = prev.map { .string($0.id) } ?? .null
        chat.row["memoryUpToAt"] = .number(prev?.createdAt ?? 0)
        chat.row["memoryTriedId"] = .null
        chat.row["memoryTriedAt"] = .number(0)
        chat.row.touch()
        try Repo.save(chat)
        return try pending(chatId: chatId).count - before
    }

    /// 这条消息是不是已经算作总结过（消息菜单上「从这条起重新总结」只给这些）
    static func summarized(chatId: String, msgId: String) -> Bool {
        guard let all = try? usable(chatId), all.contains(where: { $0.id == msgId }) else { return false }
        return !((try? pending(chatId: chatId)) ?? []).contains { $0.id == msgId }
    }

    private static func int(_ s: AppSettings, _ key: String, _ def: Double = 0) -> Int {
        max(0, Int((s.raw[key]?.number ?? def).rounded()))
    }

    /// 哪一条门槛到了。没有就是空串。记忆整个关掉时不自动总结。
    static func dueReason(chatId: String, settings s: AppSettings = .load()) throws -> String {
        guard s.raw["memoryEnabled"]?.bool ?? true else { return "" }
        let since = try sinceTried(chatId: chatId)
        guard since.count >= 2 else { return "" }
        let every = int(s, "autoSummarizeInterval")
        if every > 0 && roundsIn(since) >= every { return "rounds" }
        let msgs = int(s, "autoSummarizeMessages")
        if msgs > 0 && since.count >= msgs { return "messages" }
        let chars = int(s, "autoSummarizeChars")
        if chars > 0 && since.reduce(0, { $0 + $1.content.count }) >= chars { return "chars" }
        return ""
    }

    /// 不调接口，直接把积压标成已总结。迁进来一大堆历史、又不想为它们付钱时用。
    @discardableResult
    static func markCaughtUp(chatId: String) throws -> Int {
        let all = try pending(chatId: chatId)
        guard let last = all.last, var chat = try Repo.chat(chatId) else { return 0 }
        chat.row["memoryUpTo"] = .string(last.id)
        chat.row["memoryUpToAt"] = .number(last.createdAt)
        chat.row["memoryTriedId"] = .null
        chat.row["memoryTriedAt"] = .number(0)
        chat.row.touch()
        try Repo.save(chat)
        return all.count
    }

    // MARK: - 时间线

    private static func dayKey(_ t: Double) -> String { TimeText.day(Date(timeIntervalSince1970: t / 1000)) }

    private static func weekday(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE"
        return f.string(from: Date(timeIntervalSince1970: t / 1000))
    }

    private static func clock(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t / 1000))
    }

    static func todayText(_ now: Date = Date()) -> String {
        let t = now.millis
        return "\(dayKey(t)) (\(weekday(t))), \(clock(t))"
    }

    /// 对话摆成带时间线的文字：换一天插一行日期，隔半小时以上插时刻。
    static func timeline(_ list: [Message], who: (Message) -> String) -> String {
        var out: [String] = []
        var day = ""
        var last: Double = 0
        for m in list {
            let t = m.createdAt
            if t > 0 {
                let d = dayKey(t)
                if d != day { out.append("[\(d) \(weekday(t))]"); day = d; last = 0 }
            }
            let stamp = t > 0 && last > 0 && t - last >= 30 * 60_000 ? "[\(clock(t))] " : ""
            out.append("\(stamp)\(who(m))：\(m.content)")
            if t > 0 { last = t }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - 现状（网页版 mind.js）

    static let stateBlocks: [(id: String, head: String)] = [
        ("user", "About the user"), ("self", "About the character"), ("us", "Between the two of them"), ("recent", "Lately"),
    ]

    static func stateKey(_ personaId: String) throws -> String {
        let root = Repo.rootId(of: personaId, in: try Repo.personas())
        return root.isEmpty ? "root" : root
    }

    static func stateText(char: Character, key: String) -> String {
        let blocks = char.row["states"]?[key]?["blocks"]
        let bond = (char.row["bonds"]?[key]?["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return stateBlocks.map { b in
            var v = (blocks?[b.id]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if b.id == "us" && v.isEmpty { v = bond }
            return "\(b.head):\n\(v.isEmpty ? "(empty)" : v)"
        }.joined(separator: "\n\n")
    }

    static let stateLabels = ["user": "关于你", "self": "关于角色自己", "us": "你们之间", "recent": "最近"]

    /// 四块的当前内容（「你们之间」没写过时读关系底色）与哪几块锁着
    static func stateOf(char: Character, key: String) -> (blocks: [String: String], locks: Set<String>) {
        let cur = char.row["states"]?[key]
        var blocks: [String: String] = [:]
        for b in stateBlocks { blocks[b.id] = (cur?["blocks"]?[b.id]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if blocks["us", default: ""].isEmpty {
            blocks["us"] = (char.row["bonds"]?[key]?["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let locks = Set((cur?["locks"]?.object ?? [:]).filter { $0.value.bool == true }.map(\.key))
        return (blocks, locks)
    }

    private static func writeState(charId: String, key: String, _ change: (inout [String: JSONValue]) -> Void) throws {
        guard var char = try Repo.character(charId) else { throw StoreError(message: "该角色已不存在") }
        var states = char.row["states"]?.object ?? [:]
        var cur = states[key]?.object ?? ["blocks": .object([:]), "locks": .object([:])]
        change(&cur)
        states[key] = .object(cur)
        char.row["states"] = .object(states)
        char.row.touch()
        try Database.shared.put(Collections.characters, char.row)
    }

    /// 手写一块（网页版 mind.set）：写完那一块锁住，模型之后不再改写
    static func setState(charId: String, key: String, block: String, text: String) throws {
        try writeState(charId: charId, key: key) { cur in
            var blocks = cur["blocks"]?.object ?? [:]
            var locks = cur["locks"]?.object ?? [:]
            blocks[block] = .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
            locks[block] = .bool(true)
            cur["blocks"] = .object(blocks)
            cur["locks"] = .object(locks)
            cur["at"] = .number(Date().millis)
        }
    }

    static func lockState(charId: String, key: String, block: String, on: Bool) throws {
        try writeState(charId: charId, key: key) { cur in
            var locks = cur["locks"]?.object ?? [:]
            locks[block] = .bool(on)
            cur["locks"] = .object(locks)
        }
    }

    /// 模型交回来的几块。锁住的不动；没给的不动；给了空串照写。
    static func applyState(charId: String, key: String, _ incoming: [String: JSONValue]) throws -> Int {
        guard var char = try Repo.character(charId) else { return 0 }
        var states = char.row["states"]?.object ?? [:]
        var cur = states[key]?.object ?? ["blocks": .object([:]), "locks": .object([:])]
        var blocks = cur["blocks"]?.object ?? [:]
        let locks = cur["locks"]?.object ?? [:]
        var n = 0
        for b in stateBlocks {
            guard locks[b.id]?.bool != true, let v = incoming[b.id]?.string else { continue }
            let clean = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean == (blocks[b.id]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) { continue }
            blocks[b.id] = .string(clean)
            n += 1
        }
        guard n > 0 else { return 0 }
        cur["blocks"] = .object(blocks)
        cur["at"] = .number(Date().millis)
        states[key] = .object(cur)
        char.row["states"] = .object(states)
        char.row.touch()
        try Database.shared.put(Collections.characters, char.row)
        return n
    }

    // MARK: - 总结

    private static let pronoun = try! NSRegularExpression(pattern: "^(我|你|他|她|它|自己|本人|用户|user|me|i|you)$", options: [.caseInsensitive])

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard chars.count > 1 else { return Set(chars.map(String.init)) }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
    }

    /// 总结时发的那几条已有记忆：相关的 N 条与最近的 M 条，去重后按记下的先后排（网页版 sentOf）。
    private static func sent(_ existing: [Memory], text: String, settings s: AppSettings) -> [Memory] {
        if s.raw["memoryDedupeAll"]?.bool == true { return existing }
        let n = int(s, "memoryDedupeRelevant", 30)
        let m = int(s, "memoryDedupeRecent", 10)
        let grams = bigrams(text)
        func score(_ x: Memory) -> Int {
            x.keywords.filter { !$0.isEmpty && text.contains($0) }.count * 3 + bigrams(x.content).intersection(grams).count
        }
        let scored = existing.map { ($0, score($0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        var pick = Set((n > 0 ? Array(scored.prefix(n)) : scored).map { $0.0.id })
        if m > 0 { existing.sorted { $0.at > $1.at }.prefix(m).forEach { pick.insert($0.id) } }
        return existing.filter { pick.contains($0.id) }
    }

    private static func dayOf(_ t: Double) -> String { t > 0 ? dayKey(t) : "" }

    /// 模型给的 YYYY-MM-DD 读成当天正午（本地时区）。认不出回 0。
    static func dateAt(_ v: JSONValue?) -> Double {
        guard let s = v?.string?.trimmingCharacters(in: .whitespaces),
              s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return 0 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s + " 12:00")?.millis ?? 0
    }

    private static func dayStr(_ v: JSONValue?) -> String {
        let s = (v?.string ?? "").trimmingCharacters(in: .whitespaces)
        return s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? s : ""
    }

    /// 总结一次。只吃最早的一批（memoryBatch，默认 200，0 为全部）；设了「每 N 轮」就总结最近这 N 轮，更早的一并标为已总结。
    static func extract(chatId: String) async throws -> Counts {
        let s = AppSettings.load()
        guard let chat = try Repo.chat(chatId) else { throw StoreError(message: "会话不存在") }
        guard !chat.isGroup else { throw StoreError(message: "群聊的记忆总结原生版尚未提供") }
        guard let charId = chat.characterIds.first, let char = try Repo.character(charId) else { throw StoreError(message: "这段会话的角色不存在") }
        let all = try pending(chatId: chatId)
        guard all.count >= 2, let lastMsg = all.last else { throw StoreError(message: "对话太短，暂时不需要总结") }
        let every = int(s, "autoSummarizeInterval")
        let cap = int(s, "memoryBatch", 200)
        // 设了「每 N 轮」：一次总结 N 轮。积压比 N 轮多时（开启之前攒下的、改回未总结的）从最早的 N 轮开始，只标这一段。
        // 从前取的是最近 N 轮、把更早的整批标成已总结：一开开关，几百条积压一下变成 0 条，实际一条都没总结（网页版 4.606）
        let batch = every > 0 ? firstRounds(all, every) : (cap > 0 ? Array(all.prefix(cap)) : all)
        let markList = batch

        let personas = try Repo.personas()
        let me = try personas.first { $0.id == chat.personaId } ?? Repo.activePersona(s)
        let personaId = me?.id ?? ""
        let rootId = Repo.rootId(of: personaId, in: personas)
        let key = rootId.isEmpty ? "root" : rootId
        let existing = try ChatPrompt.visibleMemories(char: char, chat: chat, rootId: rootId, personas: personas)
            .filter { $0.supersededBy.isEmpty && $0.charId == char.id }

        let pname = (me?.row.string("name") ?? "").trimmingCharacters(in: .whitespaces)
        let isPronoun = pronoun.firstMatch(in: pname, range: NSRange(pname.startIndex..., in: pname)) != nil
        let userLabel = !pname.isEmpty && pname.count <= 24 && !isPronoun ? pname : "User"
        let who = Templates.render("task.memory-who", ["user": userLabel, "chars": "\"\(char.name)\""], settings: s)
        // 线下正文前面标一下是见面时的事；群戏里别的角色写的那段署它自己的名字
        let dialogue = timeline(batch) { m in
            let name = m.role == .user ? userLabel
                : (m.authorId == char.id || m.authorId.isEmpty ? char.name : (((try? Repo.character(m.authorId)) ?? nil)?.name ?? char.name))
            return m.kind == "beat" ? "\(name)（线下）" : name
        }

        let opens = existing.filter { $0.kind == .open && $0.status == "open" }
        let openText = opens.isEmpty ? "(none)" : opens.map { m in
            let due = m.row.string("dueAt")
            return "(id:\(m.id)) [since \(dayOf(m.at).isEmpty ? "?" : dayOf(m.at))\(due.isEmpty ? "" : ", due \(due)")] \(m.content)"
        }.joined(separator: "\n")
        let others = sent(existing.filter { m in !opens.contains { $0.id == m.id } },
                          text: batch.map(\.content).joined(separator: "\n"), settings: s)
        let existingText = others.isEmpty ? "(no other memories)" : others.map { m in
            let day = dayOf(m.at)
            let tag: String
            switch m.kind {
            case .fact:
                let to = m.row.number("validTo").map { dayOf($0) } ?? ""
                tag = "fact\(day.isEmpty ? "" : ", since \(day)")\(to.isEmpty ? "" : ", until \(to)")"
            case .open: tag = "settled\(day.isEmpty ? "" : ", \(day)")"
            case .event: tag = "event\(day.isEmpty ? "" : ", \(day)")"
            }
            return "(id:\(m.id)) [\(tag)] \(m.content)"
        }.joined(separator: "\n")

        // 自定义互动标识里「模型判断」的那几个搭在这一次上（网页版 4.320），不多调接口
        let badgeSent = BadgeDefs.inSummary(s) ? BadgeDefs.judgeFor(chat) : []
        let system = Templates.render("task.memory-extract", [
            "today": todayText(), "who": who, "state": stateText(char: char, key: key),
            "open": openText, "existing": existingText, "dialogue": dialogue,
        ], settings: s) + (badgeSent.isEmpty ? "" : "\n\n" + Templates.render("task.badge-check", ["badges": BadgeDefs.judgeText(badgeSent)], settings: s))

        // 先记「试过到哪一条」再发：失败也算试过，自动那一档要再攒够一个间隔才重试
        var tried = chat
        tried.row["memoryTriedId"] = .string(lastMsg.id)
        tried.row["memoryTriedAt"] = .number(lastMsg.createdAt)
        tried.row.touch()
        try Repo.save(tried)

        let cap2 = int(s, "memoryExtractMaxTokens")
        let r = try await AIService.shared.send(task: "memory.extract", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: cap2)
        guard let result = JSONReply.parse(r.text)?.object else { throw StoreError(message: JSONReply.failure(r.text)) }

        let at = batch.last?.createdAt ?? Date().millis
        let counts = try apply(result, charId: char.id, personaId: personaId, key: key, at: at, existing: existing)
        BadgeDefs.applyJudged(result["badgesEarned"], sent: badgeSent, chatId: chatId)

        guard var done = try Repo.chat(chatId) else { return counts }
        if let lastMark = markList.last {
            done.row["memoryUpTo"] = .string(lastMark.id)
            done.row["memoryUpToAt"] = .number(lastMark.createdAt)
        }
        done.row.touch()
        try Repo.save(done)
        Diagnostics.shared.record("memory-extract", ["added": counts.added, "updated": counts.updated, "closed": counts.closed])
        return counts
    }

    /// 把模型交回来的操作落库（网页版 applyOps，一对一那一半）。
    static func apply(_ result: [String: JSONValue], charId: String, personaId: String, key: String, at: Double,
                      existing: [Memory]) throws -> Counts {
        // 改写之前先把整份记忆存一份，改坏了能退回去（网页版 4.560）。和上一份相同不存
        do { try MemHistory.take(charId, why: "总结记忆") } catch { Diagnostics.shared.record("memhistory-failed", ["error": error.localizedDescription]) }
        var n = Counts()
        let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func keywords(_ r: JSONValue) -> JSONValue { .array((r["keywords"]?.array ?? []).compactMap(\.string).filter { !$0.isEmpty }.map { JSONValue.string($0) }) }
        func rank(_ r: JSONValue, _ def: String) -> String { ["S", "A", "B", "C"].contains(r["rank"]?.string ?? "") ? r["rank"]!.string! : def }
        func about(_ r: JSONValue) -> String { ["user", "char", "both"].contains(r["about"]?.string ?? "") ? r["about"]!.string! : "" }
        func weight(_ r: JSONValue) -> Double { min(2, max(0, r["weight"]?.number ?? 0)) }
        func add(_ fields: [String: JSONValue]) throws -> Row {
            var f: [String: JSONValue] = ["charId": .string(charId), "source": .string("auto"), "personaId": .string(personaId)]
            f.merge(fields) { _, new in new }
            var row = Row.new(prefix: "mem", f)
            // 记的时间是这批消息发生的时间，不是总结的时间
            row["createdAt"] = .number(at)
            row["updatedAt"] = .number(at)
            try Database.shared.put(Collections.memories, row)
            n.added += 1
            return row
        }
        func update(_ id: String, _ patch: [String: JSONValue]) throws {
            guard var row = try Database.shared.get(Collections.memories, id: id) else { return }
            for (k, v) in patch { row[k] = v }
            row.touch()
            try Database.shared.put(Collections.memories, row)
        }
        func content(_ r: JSONValue) -> String? {
            let c = (r["content"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return c.isEmpty ? nil : c
        }

        for r in result["events"]?.array ?? [] {
            guard let c = content(r) else { continue }
            _ = try add(["content": .string(c), "category": .string("event"), "kind": .string("event"), "rank": .string(rank(r, "B")),
                         "keywords": keywords(r), "weight": .number(weight(r)), "about": .string(about(r)),
                         "at": .number(dateAt(r["at"]) > 0 ? dateAt(r["at"]) : at)])
        }
        for r in result["facts"]?.array ?? [] {
            guard let c = content(r) else { continue }
            let since = dateAt(r["since"]) > 0 ? dateAt(r["since"]) : at
            let slot = ["occupation", "location", "birthday", "school", "family", "contact"].contains(r["slot"]?.string ?? "") ? r["slot"]!.string! : ""
            var fields: [String: JSONValue] = ["content": .string(c), "category": .string("fact"), "kind": .string("fact"),
                                               "rank": .string(rank(r, "A")), "keywords": keywords(r), "slot": .string(slot),
                                               "weight": .number(weight(r)), "about": .string(about(r)), "at": .number(since)]
            let replaces = r["replaces"]?.string ?? ""
            let old = byId[replaces]
            if old != nil { fields["replaces"] = .string(replaces) }
            let row = try add(fields)
            if old != nil {
                try update(replaces, ["supersededBy": .string(row.id), "validTo": .number(since)])
                n.updated += 1
            }
        }
        for r in result["ended"]?.array ?? [] {
            guard let id = r["id"]?.string, let old = byId[id], old.kind == .fact else { continue }
            try update(id, ["validTo": .number(dateAt(r["on"]) > 0 ? dateAt(r["on"]) : at)])
            n.updated += 1
        }
        for r in result["open"]?.array ?? [] {
            guard let c = content(r) else { continue }
            _ = try add(["content": .string(c), "category": .string("pending"), "kind": .string("open"), "status": .string("open"),
                         "rank": .string(rank(r, "B")), "keywords": keywords(r), "about": .string(about(r)),
                         "at": .number(dateAt(r["since"]) > 0 ? dateAt(r["since"]) : at), "dueAt": .string(dayStr(r["due"]))])
        }
        for r in result["closed"]?.array ?? [] {
            guard let id = r["id"]?.string, let old = byId[id], old.kind == .open else { continue }
            try update(id, ["status": .string("done"), "doneAt": .number(dateAt(r["on"]) > 0 ? dateAt(r["on"]) : at),
                            "result": .string(String((r["result"]?.string ?? "").trimmingCharacters(in: .whitespaces).prefix(300))),
                            "vec": .null, "vecModel": .string("")])
            n.closed += 1
        }
        if let state = result["state"]?.object {
            n.state = try applyState(charId: charId, key: key, state)
        }
        return n
    }

    /// 自动总结：门槛到了就总结一次（autoSummarizeCatchUp 默认 1：触发一次只调一次接口）。失败只记日志，不打断聊天。
    static func autoRun(chatId: String) async -> Counts? {
        guard (try? dueReason(chatId: chatId)).map({ !$0.isEmpty }) == true else { return nil }
        let s = AppSettings.load()
        let catchUp = int(s, "autoSummarizeCatchUp", 1)
        var sum = Counts()
        var runs = 0
        do {
            while try pending(chatId: chatId).count >= 2 && (catchUp == 0 || runs < catchUp) {
                let r = try await extract(chatId: chatId)
                runs += 1
                sum.added += r.added; sum.updated += r.updated; sum.closed += r.closed; sum.state += r.state
                if int(s, "memoryBatch", 200) == 0 || int(s, "autoSummarizeInterval") > 0 { break }
            }
        } catch {
            Diagnostics.shared.record("memory-extract-failed", ["error": error.localizedDescription])
            return nil
        }
        return sum
    }
}
