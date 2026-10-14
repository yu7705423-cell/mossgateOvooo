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

    static func speaking(_ chat: Chat, members: [Character]) -> [Character] {
        members.filter { !isMuted(chat, $0.id) }
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
