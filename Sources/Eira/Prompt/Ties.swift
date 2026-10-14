import Foundation

/// 好友与拉黑（网页版 system/ties.js，ARCHITECTURE 4.306、4.475）。像微信：一方的联系人里有没有另一方、有没有把另一方拉黑，
/// 是一方自己的状态。数据域 ties，与网页版同一格式：一行记「from 对 to」：removed、blocked；没有这一行就是好友、没拉黑。
/// 按身份（personaId）分。每一次改动开或关一段时间（spans），被拒收按「发出那一刻落在不在一段里」判。
///
/// 效果照微信：
///   · 角色拉黑了你 / 把你删了：你发的照常落下，标成被拒收，不调接口，也不进角色的历史
///   · 你拉黑了角色 / 把它删了：你照常能发、角色照常能回，角色发来的每一条标成被拒收；它从第一条被拒收起才知道
///   · 角色拉黑了你：会话设置里「强制解除」，不经过角色
///   · 角色把你删了：发好友申请，角色在那一次回复里写 [通过好友申请：名字] 才恢复，没写的那一轮不送达
///   · 群聊不受影响
/// 角色只写标记改自己这一方（规约第 22 条），名字只认你与它关系网里的人，认不出就当没写过。
enum Ties {
    static let me = "me"
    static let collection = "ties"

    struct State: Equatable { var blocked = false; var removed = false }

    static func row(_ from: String, _ to: String, _ personaId: String) -> Row? {
        ((try? Database.shared.all(collection)) ?? []).first {
            $0.string("from") == from && $0.string("to") == to && (($0["personaId"]?.string).map { $0.isEmpty ? personaId : $0 } ?? personaId) == personaId
        }
    }

    static func state(_ from: String, _ to: String, _ personaId: String) -> State {
        guard let r = row(from, to, personaId) else { return State() }
        return State(blocked: r.bool("blocked"), removed: r.bool("removed"))
    }

    private static func spans(_ r: Row?) -> [[String: JSONValue]] {
        (r?["spans"]?.array ?? []).compactMap(\.object)
    }

    /// 改 from 对 to 的状态。turnId 是角色那一轮写的，重新生成时退回
    @discardableResult
    static func set(_ from: String, _ to: String, _ personaId: String, blocked: Bool? = nil, removed: Bool? = nil,
                    turnId: String = "", now: Double = Date().millis) throws -> Row? {
        guard !from.isEmpty, !to.isEmpty, from != to else { return nil }
        let cur = row(from, to, personaId)
        let prev = State(blocked: cur?.bool("blocked") ?? false, removed: cur?.bool("removed") ?? false)
        let next = State(blocked: blocked ?? prev.blocked, removed: removed ?? prev.removed)
        guard next != prev else { return cur }
        var sp = spans(cur)
        for (kind, was, now_) in [("blocked", prev.blocked, next.blocked), ("removed", prev.removed, next.removed)] {
            if now_ && !was { sp.append(["kind": .string(kind), "at": .number(now), "until": .number(0)]) }
            if !now_ && was {
                for i in sp.indices where sp[i]["kind"]?.string == kind && (sp[i]["until"]?.number ?? 0) == 0 { sp[i]["until"] = .number(now) }
            }
        }
        var hist = cur?["hist"]?.array ?? []
        if !turnId.isEmpty {
            hist = Array(hist.suffix(9))
            hist.append(.object(["turnId": .string(turnId), "prev": .object([
                "blocked": .bool(prev.blocked), "removed": .bool(prev.removed), "spans": cur?["spans"] ?? .array([])])]))
        }
        var r = cur ?? Row.new(prefix: "tie", ["from": .string(from), "to": .string(to), "personaId": .string(personaId)])
        r["blocked"] = .bool(next.blocked)
        r["removed"] = .bool(next.removed)
        r["spans"] = .array(sp.map { .object($0) })
        r["hist"] = .array(hist)
        r.touch()
        try Database.shared.put(collection, r)
        return r
    }

    /// 重新生成那一轮：这一轮里角色改过的状态退回去
    static func undoTurn(_ turnId: String) throws {
        guard !turnId.isEmpty else { return }
        for var r in try Database.shared.all(collection) {
            let hist = r["hist"]?.array ?? []
            guard let h = hist.first(where: { $0["turnId"]?.string == turnId })?.object, let prev = h["prev"]?.object else { continue }
            r["blocked"] = .bool(prev["blocked"]?.bool == true)
            r["removed"] = .bool(prev["removed"]?.bool == true)
            r["spans"] = prev["spans"] ?? .array([])
            r["hist"] = .array(hist.filter { $0["turnId"]?.string != turnId })
            r.touch()
            try Database.shared.put(collection, r)
        }
    }

    // MARK: - 一对一的会话

    /// 一对一的那个角色；群聊为 nil
    static func pair(_ chat: Chat?) -> String? {
        guard let chat, !chat.isGroup, chat.characterIds.count == 1 else { return nil }
        return chat.characterIds[0]
    }

    private static func pid(_ chat: Chat) -> String {
        chat.personaId.isEmpty ? (AppSettings.load().raw["activePersonaId"]?.string ?? "") : chat.personaId
    }

    /// 角色这一方挡着你：blocked / removed / nil
    static func charRejects(_ chat: Chat?) -> String? {
        guard let chat, let c = pair(chat) else { return nil }
        let s = state(c, me, pid(chat))
        return s.blocked ? "blocked" : s.removed ? "removed" : nil
    }

    /// 你这一方挡着角色：blocked / removed / nil
    static func userRejects(_ chat: Chat?) -> String? {
        guard let chat, let c = pair(chat) else { return nil }
        let s = state(me, c, pid(chat))
        return s.blocked ? "blocked" : s.removed ? "removed" : nil
    }

    private static func hit(_ r: Row?, at t: Double) -> String {
        let span = spans(r).first(where: { s in
            let at = s["at"]?.number ?? 0, until = s["until"]?.number ?? 0
            return at <= t && (until == 0 || t < until)
        })
        return span?["kind"]?.string ?? ""
    }

    /// 我发的这条有没有被角色拒收：发出那一刻角色那一方是否挡着我
    static func rejectedOf(_ m: Message, chat: Chat?) -> String {
        guard m.role == .user, let chat, let c = pair(chat) else { return "" }
        return hit(row(c, me, pid(chat)), at: m.createdAt)
    }

    /// 角色发来的这条有没有被我拒收
    static func rejectedByMe(_ m: Message, chat: Chat?) -> String {
        guard m.role == .char, let chat, let c = pair(chat), m.authorId.isEmpty || m.authorId == c else { return "" }
        return hit(row(me, c, pid(chat)), at: m.createdAt)
    }

    /// 送进提示词之前滤掉我发的被角色拒收的。角色发的被我拒收的留着，那是它自己说过的话
    static func keepDelivered(_ chat: Chat, _ list: [Message]) -> [Message] {
        guard let c = pair(chat), let r = row(c, me, pid(chat)), !spans(r).isEmpty else { return list }
        return list.filter { $0.role != .user || hit(r, at: $0.createdAt).isEmpty }
    }

    /// 这个角色这一刻能不能主动给你发消息：它删了你不能；你拉黑或删了它照样能发，发来的被拒收
    static func canReachUser(_ charId: String, personaId: String) -> Bool {
        !state(charId, me, personaId).removed
    }

    private static func note(_ chat: Chat, _ content: String) throws -> Message {
        try Repo.append(Message.new(chatId: chat.id, role: .user, authorId: me, content: content, kind: "notice"))
    }

    // MARK: - 你这一方的动作（会话设置）

    static func userSet(_ chat: Chat, blocked: Bool? = nil, removed: Bool? = nil) throws {
        guard let c = pair(chat) else { return }
        try set(me, c, pid(chat), blocked: blocked, removed: removed)
    }

    /// 强制解除角色对你的拉黑。不经过角色本人；落一行提示，角色下一轮看得见
    @discardableResult
    static func forceUnblock(_ chat: Chat) throws -> Message? {
        guard let c = pair(chat), state(c, me, pid(chat)).blocked else { return nil }
        try set(c, me, pid(chat), blocked: false)
        return try note(chat, "[拉黑已解除]")
    }

    /// 发好友申请。角色把你删了才用得上；角色在下一次回复里决定通不通过
    @discardableResult
    static func request(_ chat: Chat, text: String) throws -> Message? {
        guard charRejects(chat) == "removed", var c = try Repo.chat(chat.id) else { return nil }
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        c.row["friendRequest"] = .object(["note": .string(t), "at": .number(Date().millis)])
        c.row.touch()
        try Repo.save(c)
        return try note(c, "[你发送了好友申请\(t.isEmpty ? "" : "：\(t)")]")
    }

    static func pendingRequest(_ chat: Chat) -> (note: String, at: Double)? {
        guard let o = chat.row["friendRequest"]?.object, let at = o["at"]?.number else { return nil }
        return (o["note"]?.string ?? "", at)
    }

    static func clearRequest(_ chatId: String) throws {
        guard var c = try Repo.chat(chatId), c.row["friendRequest"] != nil else { return }
        c.row["friendRequest"] = .null
        c.row.touch()
        try Repo.save(c)
    }

    // MARK: - 角色写的标记

    /// 名字认到谁：你（这段会话所用身份的名字，或写「你」）、它关系网里的人
    static func resolve(_ char: Character, _ name: String, personaId: String) -> String? {
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let meName = ((try? Repo.personas()) ?? []).first { $0.id == personaId }?.name ?? ""
        if q == "你" || q == meName { return me }
        let rel = (char.row["relations"]?.array ?? []).compactMap { $0["charId"]?.string }.compactMap { try? Repo.character($0) }
        if let hit = rel.first(where: { $0.name == q || $0.displayName == q }) { return hit.id }
        return rel.first { !$0.name.isEmpty && ($0.name.contains(q) || q.contains($0.name)) }?.id
    }

    static let kinds = ["拉黑": "block", "解除拉黑": "unblock", "删除好友": "remove", "添加好友": "add", "通过好友申请": "accept"]

    /// [拉黑：名字] [解除拉黑：名字] [删除好友：名字] [添加好友：名字] [通过好友申请：名字]。认不出名字就当没写过。
    /// 回认到的对象；通过了你的好友申请时另落一行提示
    @discardableResult
    static func fromMark(char: Character, chat: Chat, kind: String, name: String, turnId: String) throws -> (target: String, note: Message?)? {
        let personaId = pid(chat)
        guard let target = resolve(char, name, personaId: personaId) else { return nil }
        switch kind {
        case "accept":
            guard target == me, state(char.id, me, personaId).removed else { return nil }
            try set(char.id, me, personaId, removed: false, turnId: turnId)
            try clearRequest(chat.id)
            var m = Message.new(chatId: chat.id, role: .user, authorId: me,
                                content: "[\(char.displayName)通过了你的好友申请，现在可以开始聊天了]", kind: "notice", turnId: turnId)
            m.row["status"] = .string("done")
            return (target, m)
        case "block": try set(char.id, target, personaId, blocked: true, turnId: turnId)
        case "unblock": try set(char.id, target, personaId, blocked: false, turnId: turnId)
        case "remove": try set(char.id, target, personaId, removed: true, turnId: turnId)
        case "add": try set(char.id, target, personaId, removed: false, turnId: turnId)
        default: return nil
        }
        return (target, nil)
    }

    /// 这一轮回复里有没有通过对你的好友申请
    static func accepts(_ raw: String, char: Character, chat: Chat) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"[\[【]\s*通过好友申请\s*[:：]\s*([^\]】]+)[\]】]"#) else { return false }
        let ns = raw as NSString
        return re.matches(in: raw, range: NSRange(location: 0, length: ns.length)).contains {
            resolve(char, ns.substring(with: $0.range(at: 1)), personaId: pid(chat)) == me
        }
    }

    /// 写进提示词的那几句：这个角色这一方的状态、你那边来的好友申请。只陈述事实（第 16 条）
    static func facts(_ char: Character, chat: Chat, userName: String) -> [String] {
        let personaId = pid(chat)
        var out: [String] = []
        let toMe = state(char.id, me, personaId)
        if toMe.blocked { out.append("You have blocked \(userName). Messages \(userName) sends you do not reach you.") }
        if toMe.removed { out.append("You have removed \(userName) from your contacts. Messages \(userName) sends you do not reach you, and you cannot message \(userName) until you add them back.") }
        let others = ((try? Database.shared.all(collection)) ?? []).filter {
            $0.string("from") == char.id && $0.string("to") != me
                && (($0["personaId"]?.string).map { $0.isEmpty ? personaId : $0 } ?? personaId) == personaId
                && ($0.bool("blocked") || $0.bool("removed"))
        }
        let names: ([Row]) -> String = { rows in
            rows.compactMap { try? Repo.character($0.string("to")) }.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
        }
        let blocked = names(others.filter { $0.bool("blocked") })
        let removed = names(others.filter { $0.bool("removed") })
        if !blocked.isEmpty { out.append("You have blocked: \(blocked).") }
        if !removed.isEmpty { out.append("You have removed from your contacts: \(removed).") }
        // 你挡着它：照微信，它只有发过消息被拒收之后才知道
        let mine = state(me, char.id, personaId)
        if pair(chat) == char.id && (mine.blocked || mine.removed),
           ((try? Repo.messages(chatId: chat.id)) ?? []).contains(where: { $0.role == .char && !rejectedByMe($0, chat: chat).isEmpty }) {
            out.append(mine.blocked
                ? "\(userName) has blocked you. The messages you send \(userName) are not delivered."
                : "\(userName) has removed you from their contacts. The messages you send \(userName) are not delivered.")
        }
        if pair(chat) == char.id, toMe.removed, let req = pendingRequest(chat) {
            out.append("\(userName) has sent you a friend request\(req.note.isEmpty ? "" : " with the note 「\(req.note)」")."
                + " Accepting it restores \(userName) to your contacts: write [通过好友申请：\(userName)]."
                + " A reply that does not accept it is not delivered.")
        }
        return out
    }

    static func block(_ char: Character, chat: Chat, userName: String) -> String {
        let lines = facts(char, chat: chat, userName: userName)
        return lines.isEmpty ? "" : "\n\n[好友与拉黑]\n" + lines.joined(separator: "\n")
    }

    /// 一段会话里每条被拒收的消息下那一行，读一次 ties 算完（会话页一次画好几百条，不能每条读一遍库）
    static func notes(_ msgs: [Message], chat: Chat?) -> [String: String] {
        guard let chat, let c = pair(chat) else { return [:] }
        let p = pid(chat)
        let toMe = row(c, me, p), fromMe = row(me, c, p)
        guard !spans(toMe).isEmpty || !spans(fromMe).isEmpty else { return [:] }
        var out: [String: String] = [:]
        for m in msgs {
            if m.role == .user {
                switch hit(toMe, at: m.createdAt) {
                case "blocked": out[m.id] = "消息已发出，但被对方拒收了"
                case "removed": out[m.id] = "消息已发出，但对方已不是你的好友，未送达"
                default: break
                }
            } else if m.authorId.isEmpty || m.authorId == c {
                switch hit(fromMe, at: m.createdAt) {
                case "blocked": out[m.id] = "你已拉黑该角色，这条消息被拒收"
                case "removed": out[m.id] = "你已删除该角色，这条消息未送达"
                default: break
                }
            }
        }
        return out
    }

    /// 气泡下那一行
    static func rejectNote(_ m: Message, chat: Chat?) -> String {
        switch (rejectedOf(m, chat: chat), rejectedByMe(m, chat: chat)) {
        case ("blocked", _): return "消息已发出，但被对方拒收了"
        case ("removed", _): return "消息已发出，但对方已不是你的好友，未送达"
        case (_, "blocked"): return "你已拉黑该角色，这条消息被拒收"
        case (_, "removed"): return "你已删除该角色，这条消息未送达"
        default: return ""
        }
    }
}
