import Foundation

/// 群聊（网页版 system/group.js 与 ai/reply.js 的 splitSpeakers，ARCHITECTURE 4.162）。
///
/// **群是一段会话，不是另一种东西。** chats.characterIds 里放了不止一个人，外加 group: true。
/// 成员不许少于两人。一轮默认一次调用：模型按「名字：」写出这一轮开口的几个人，本地按名字拆回各人。
enum GroupChat {
    static let minMembers = 2
    static let me = "me"

    static func members(_ chat: Chat) -> [Character] {
        chat.characterIds.compactMap { try? Repo.character($0) }
    }

    static func nick(_ chat: Chat, _ id: String) -> String {
        (chat.row["nicks"]?[id]?.string ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// 群里显示的名字：群昵称，没有就是原名。
    static func nameIn(_ chat: Chat, _ c: Character) -> String {
        let n = nick(chat, c.id)
        return n.isEmpty ? c.name : n
    }

    static func title(_ chat: Chat, members: [Character]) -> String {
        let t = chat.title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        let names = members.map(\.name).joined(separator: "、")
        return names.isEmpty ? "群聊" : names
    }

    // MARK: - 身份与禁言（读网页版存下的，原生版暂不提供管理界面）

    static func role(_ chat: Chat, _ id: String) -> String {
        if id == me { return "owner" }
        return (chat.row["admins"]?.array ?? []).contains { $0.string == id } ? "admin" : "member"
    }

    /// 现在说不说得了话：自己被禁言，或全员禁言而自己只是成员。mutes[id] 为 0 是一直禁到解除。
    static func isMuted(_ chat: Chat, _ id: String, now: Double = Date().millis) -> Bool {
        if id == me { return false }
        if let until = chat.row["mutes"]?[id]?.number, until == 0 || until > now { return true }
        return chat.row.bool("muteAll") && role(chat, id) == "member"
    }

    /// 这一刻说得了话的成员。封存的角色在群里也不再发言（网页版 4.557）
    static func speaking(_ chat: Chat, members: [Character]) -> [Character] {
        members.filter { !isMuted(chat, $0.id) && !$0.archived }
    }

    // MARK: - 你来管（网页版 setAdmin / setNick / mute / unmute / setMuteAll；你是群主）

    static let roleLabel = ["owner": "群主", "admin": "管理员", "member": ""]
    /// 禁言时长档（分钟），0 为一直禁到解除
    static let muteSteps: [(minutes: Int, label: String)] = [(10, "10 分钟"), (60, "1 小时"), (720, "12 小时"), (1440, "1 天"), (0, "一直禁言")]

    static func durationText(_ m: Int) -> String {
        if m == 0 { return "" }
        if m % 1440 == 0 { return "\(m / 1440) 天" }
        if m % 60 == 0 { return "\(m / 60) 小时" }
        return "\(m) 分钟"
    }

    private static func meName(_ chat: Chat) -> String {
        let n = nick(chat, me)
        if !n.isEmpty { return n }
        let personas = (try? Repo.personas()) ?? []
        return personas.first(where: { $0.id == chat.personaId })?.name ?? ((try? Repo.activePersona())?.name ?? "我")
    }

    private static func nameOf(_ chat: Chat, _ id: String) -> String {
        if id == me { return meName(chat) }
        guard let c = try? Repo.character(id) else { return "某人" }
        return nameIn(chat, c)
    }

    /// 改一处，落一行提示（你点的，记在你名下）
    private static func change(_ chatId: String, _ note: (Chat) -> String, _ edit: (inout Row) -> Void) throws {
        guard let chat = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
        let text = note(chat)
        var c = chat
        edit(&c.row)
        c.row.touch()
        try Repo.save(c)
        if !text.isEmpty {
            _ = try Repo.append(Message.new(chatId: chatId, role: .user, authorId: me, content: "[\(text)]", kind: "notice"))
        }
        NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
    }

    static func setAdmin(_ chatId: String, _ id: String, _ on: Bool) throws {
        try change(chatId, { c in on ? "\(meName(c))将\(nameOf(c, id))设为管理员" : "\(meName(c))取消了\(nameOf(c, id))的管理员身份" }) { r in
            var list = (r["admins"]?.array ?? []).filter { $0.string != id }
            if on { list.append(.string(id)) }
            r["admins"] = .array(list)
        }
    }

    /// 改群昵称，空串是清掉。你的自己的也在这里改（id 为 me）
    static func setNick(_ chatId: String, _ id: String, _ value: String) throws {
        let v = String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(20))
        guard let chat = try Repo.chat(chatId), v != nick(chat, id) else { return }
        try change(chatId, { c in
            let who = meName(c)
            if id == me { return v.isEmpty ? "\(who)清除了自己的群昵称" : "\(who)将群昵称改为「\(v)」" }
            return v.isEmpty ? "\(who)清除了\(nameOf(c, id))的群昵称" : "\(who)将\(nameOf(c, id))的群昵称改为「\(v)」"
        }) { r in
            var nicks = r["nicks"]?.object ?? [:]
            if v.isEmpty { nicks.removeValue(forKey: id) } else { nicks[id] = .string(v) }
            r["nicks"] = .object(nicks)
        }
    }

    static func mute(_ chatId: String, _ id: String, minutes: Int) throws {
        let m = max(0, minutes)
        try change(chatId, { c in "\(meName(c))将\(nameOf(c, id))禁言" + (m > 0 ? " " + durationText(m) : "") }) { r in
            var mutes = r["mutes"]?.object ?? [:]
            mutes[id] = .number(m > 0 ? Date().millis + Double(m) * 60_000 : 0)
            r["mutes"] = .object(mutes)
        }
    }

    static func unmute(_ chatId: String, _ id: String) throws {
        guard let chat = try Repo.chat(chatId), chat.row["mutes"]?[id] != nil else { return }
        try change(chatId, { c in "\(meName(c))解除了\(nameOf(c, id))的禁言" }) { r in
            var mutes = r["mutes"]?.object ?? [:]
            mutes.removeValue(forKey: id)
            r["mutes"] = .object(mutes)
        }
    }

    static func setMuteAll(_ chatId: String, _ on: Bool) throws {
        guard let chat = try Repo.chat(chatId), chat.row.bool("muteAll") != on else { return }
        try change(chatId, { c in "\(meName(c))\(on ? "开启" : "关闭")了全员禁言" }) { $0["muteAll"] = .bool(on) }
    }

    // MARK: - 角色来管（回复里的 [禁言：…]、[解除禁言：…]、[全员禁言]、[改群昵称：…]，网页版 4.301）

    private static let rank = ["owner": 2, "admin": 1, "member": 0]

    /// 管得了对方吗：比对方高一级才行，不能管自己
    static func canManage(_ chat: Chat, _ actor: String, _ target: String) -> Bool {
        actor != target && (rank[role(chat, actor)] ?? 0) > (rank[role(chat, target)] ?? 0)
    }

    /// 按名字认人：原名、群昵称都认；你的名字认成 me
    static func whoByName(_ chat: Chat, _ name: String) -> String? {
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.hasPrefix("@") { n.removeFirst() }
        guard !n.isEmpty else { return nil }
        if let hit = members(chat).first(where: { $0.name == n || nick(chat, $0.id) == n }) { return hit.id }
        if n == meName(chat) || n == nick(chat, me) { return me }
        return nil
    }

    /// 角色做的一件事：身份够才生效，改之前的那一份存在提示上，重新生成那一轮时放回去。管不了的不生效、也不落提示
    static func charAct(_ chat: Chat, actor: String, part p: ReplyParser.Part, turnId: String) throws -> Message? {
        guard chat.isGroup else { return nil }
        let target: String
        if p.type == .muteAll { target = "" }
        else if p.text.isEmpty && p.type == .nick { target = actor }
        else { guard let t = whoByName(chat, p.text) else { return nil }; target = t }
        let who = nameOf(chat, actor), whom = target.isEmpty ? "" : nameOf(chat, target)
        var row = chat.row
        let text: String
        let key: String
        switch p.type {
        case .mute:
            guard canManage(chat, actor, target) else { return nil }
            key = "mutes"
            let m = max(0, Int((p.amount ?? 0).rounded()))
            var mutes = row["mutes"]?.object ?? [:]
            mutes[target] = .number(m > 0 ? Date().millis + Double(m) * 60_000 : 0)
            row["mutes"] = .object(mutes)
            text = "\(who)将\(whom)禁言" + (m > 0 ? " " + durationText(m) : "")
        case .unmute:
            guard canManage(chat, actor, target), chat.row["mutes"]?[target] != nil else { return nil }
            key = "mutes"
            var mutes = row["mutes"]?.object ?? [:]
            mutes.removeValue(forKey: target)
            row["mutes"] = .object(mutes)
            text = "\(who)解除了\(whom)的禁言"
        case .muteAll:
            guard (rank[role(chat, actor)] ?? 0) >= 1, chat.row.bool("muteAll") != p.flag else { return nil }
            key = "muteAll"
            row["muteAll"] = .bool(p.flag)
            text = "\(who)\(p.flag ? "开启" : "关闭")了全员禁言"
        case .nick:
            guard actor == target || canManage(chat, actor, target) else { return nil }
            let v = String((p.extra ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(20))
            guard v != nick(chat, target) else { return nil }
            key = "nicks"
            var nicks = row["nicks"]?.object ?? [:]
            if v.isEmpty { nicks.removeValue(forKey: target) } else { nicks[target] = .string(v) }
            row["nicks"] = .object(nicks)
            text = actor == target ? (v.isEmpty ? "\(who)清除了自己的群昵称" : "\(who)将群昵称改为「\(v)」")
                : (v.isEmpty ? "\(who)清除了\(whom)的群昵称" : "\(who)将\(whom)的群昵称改为「\(v)」")
        default:
            return nil
        }
        var c = chat
        c.row = row
        c.row.touch()
        try Repo.save(c)
        var m = Message.new(chatId: chat.id, role: .char, authorId: actor, content: "[\(text)]", kind: "notice", turnId: turnId)
        m.row["groupUndo"] = .object(["key": .string(key), "prev": chat.row[key] ?? .null])
        return m
    }

    /// 删掉角色那一行提示（重新生成那一轮）：放回改之前那一份
    static func undo(_ notice: Message) throws {
        guard let u = notice.row["groupUndo"]?.object, let key = u["key"]?.string, var c = try Repo.chat(notice.chatId) else { return }
        c.row[key] = u["prev"] == .null ? nil : u["prev"]
        c.row.touch()
        try Repo.save(c)
    }

    /// 还要禁多久的说明：没禁言为空
    static func muteText(_ chat: Chat, _ id: String, now: Double = Date().millis) -> String {
        guard let until = chat.row["mutes"]?[id]?.number else {
            return chat.row.bool("muteAll") && role(chat, id) == "member" ? "全员禁言中" : ""
        }
        if until == 0 { return "禁言中" }
        guard until > now else { return "" }
        let mins = Int(((until - now) / 60_000).rounded(.up))
        return "禁言中，还有 " + (mins >= 60 ? "\(mins / 60) 小时" : "\(mins) 分钟")
    }

    /// 单独调用那一档：模型照群里的写法在行首写了自己的名字（「林：在」），落气泡前摘掉。一对一的会话不动
    static func stripOwnName(_ raw: String, char: Character, chat: Chat) -> String {
        guard chat.isGroup else { return raw }
        let names = [char.name, nick(chat, char.id)].filter { !$0.isEmpty }.map { NSRegularExpression.escapedPattern(for: $0) }
        guard !names.isEmpty else { return raw }
        let p = "(?m)^\\s*(?:\\*\\*)?[【\\[]?(?:" + names.joined(separator: "|") + ")[】\\]]?(?:\\*\\*)?\\s*[:：]\\s*"
        return raw.replacingOccurrences(of: p, with: "", options: .regularExpression)
    }

    // MARK: - @

    /// 用户这一段连着发的消息里 @ 了谁（网页版 pendingMentions）。
    static func pendingMentions(_ msgs: [Message]) -> [String] {
        var ids: [String] = []
        for m in msgs.reversed() {
            guard m.role == .user else { break }
            for id in (m.row["mentions"]?.array ?? []).compactMap(\.string) where !ids.contains(id) { ids.insert(id, at: 0) }
        }
        return ids
    }

    /// 文字里写了「@名字」的成员。原名、群昵称都认，长的先认。
    static func mentions(in text: String, chat: Chat, members: [Character]) -> [String] {
        var names: [(String, String)] = []
        for c in members {
            names.append((c.name, c.id))
            let n = nick(chat, c.id)
            if !n.isEmpty { names.append((n, c.id)) }
        }
        names.sort { $0.0.count > $1.0.count }
        var ids: [String] = []
        for (name, id) in names where !name.isEmpty && text.contains("@" + name) && !ids.contains(id) { ids.append(id) }
        return ids
    }

    /// 正在输入的「@」：草稿末尾一个 @ 后面还没打空格的那一截。没有就是 nil
    static func pendingAt(_ draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let tail = draft[draft.index(after: at)...]
        guard !tail.contains(where: { $0.isWhitespace }) else { return nil }
        return String(tail)
    }

    /// @ 补全的候选：名字或群昵称以已打的那一截开头的成员
    static func mentionCandidates(_ draft: String, chat: Chat, members: [Character]) -> [Character] {
        guard let key = pendingAt(draft) else { return [] }
        return members.filter { c in
            key.isEmpty || c.name.lowercased().hasPrefix(key.lowercased()) || nameIn(chat, c).lowercased().hasPrefix(key.lowercased())
        }
    }

    /// 选中一位：把末尾那一截换成「@名字 」
    static func completeMention(_ draft: String, chat: Chat, _ c: Character) -> String {
        guard let at = draft.lastIndex(of: "@") else { return draft + "@\(nameIn(chat, c)) " }
        return String(draft[..<at]) + "@\(nameIn(chat, c)) "
    }

    // MARK: - 建群与成员

    static func create(memberIds: [String], title: String, personaId: String) throws -> Chat {
        var seen = Set<String>()
        let ids = memberIds.filter { seen.insert($0).inserted && (try? Repo.character($0)) != nil }
        guard ids.count >= minMembers else { throw StoreError(message: "群聊至少需要 \(minMembers) 名成员") }
        let row = Row.new(prefix: "chat", [
            "group": .bool(true), "characterIds": .array(ids.map { .string($0) }), "personaId": .string(personaId),
            "title": .string(title.trimmingCharacters(in: .whitespaces)), "lastMessageAt": .number(Date().millis),
            "unread": .number(0), "summary": .string(""),
        ])
        try Database.shared.put(Collections.chats, row)
        return Chat(row: row)
    }

    static func setMembers(_ chatId: String, _ ids: [String]) throws {
        guard ids.count >= minMembers else { throw StoreError(message: "群聊至少需要 \(minMembers) 名成员") }
        guard var chat = try Repo.chat(chatId) else { return }
        chat.row["characterIds"] = .array(ids.map { .string($0) })
        chat.row["group"] = .bool(true)
        chat.row.touch()
        try Repo.save(chat)
    }

    // MARK: - 按名字拆回各人

    /// 模型一次写整轮，每行开头是「名字：」。没带名字的行接在上一个说话的人后面。
    /// 认名字要宽一点：加粗（**小林**：）、套括号（【小林】：）都认。写成用户名字的那几段整段丢掉（替用户说话）。
    /// 一个名字都没认出来就整段算 fallback（这一轮第一个被 @ 的）或第一个成员。
    static func splitSpeakers(_ raw: String, members: [Character], chat: Chat, userName: String, fallback: String = "") -> [(charId: String, text: String)] {
        let spoken = ReplyParser.stripThink(raw).0
        let (text, stamp) = ReplyParser.stripStamps(spoken.trimmingCharacters(in: .whitespacesAndNewlines))
        var names: [(name: String, id: String)] = []
        for c in members {
            names.append((c.name.trimmingCharacters(in: .whitespaces), c.id))
            let n = nick(chat, c.id)
            if !n.isEmpty { names.append((n, c.id)) }
        }
        let myNick = nick(chat, me)
        if !userName.isEmpty && !myNick.isEmpty { names.append((myNick, "__user")) }
        if !userName.isEmpty { names.append((userName.trimmingCharacters(in: .whitespaces), "__user")) }
        names = names.filter { !$0.name.isEmpty }.sorted { $0.name.count > $1.name.count }
        let alt = names.map { NSRegularExpression.escapedPattern(for: $0.name) }.joined(separator: "|")
        let head = alt.isEmpty ? nil : try? NSRegularExpression(
            pattern: #"^\s*(?:[*_]{1,2})?[【\[(（]?\s*("# + alt + #")\s*[】\])）]?(?:[*_]{1,2})?\s*[:：]\s*(.*)$"#)

        var segs: [(id: String, lines: [String])] = []
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            if let head, let m = head.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                let rest = ns.substring(with: m.range(at: 2))
                segs.append((names.first { $0.name == name }?.id ?? "", rest.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [rest]))
                continue
            }
            if segs.isEmpty { segs.append(("", [])) }
            segs[segs.count - 1].lines.append(line)
        }
        let first = fallback.isEmpty ? (members.first?.id ?? "") : fallback
        var out = segs.filter { $0.id != "__user" }
            .map { (charId: $0.id.isEmpty ? first : $0.id, text: $0.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        // 时间只写一次，在最前面，挂回第一段上
        if let stamp, !out.isEmpty { out[0].text = "[时间：\(stamp)]\n" + out[0].text }
        return out
    }
}
