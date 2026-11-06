import Foundation

/// 群里的几样（网页版 system/group.js 与 remark.js）：角色自行退群（4.733）、角色自己改网名与群里名字的顺序（4.947）、
/// 我在本群的身份与画外音（4.1018）。
enum GroupMore {
    /// 退了之后群里至少还留几名角色
    static let minLeft = 2

    // MARK: - 网名（4.947）

    /// 角色自己的网名（编辑资料里「网名」那一栏，char.nick）。空白压成一个空格
    static func netName(_ c: Character) -> String { clean(c.row.string("nick")) }

    static func clean(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// 群里显示的名字（网页版 group.shownName）：群昵称、我给的备注、网名、角色名；我自己：群昵称、我的网名、昵称
    static func shownName(_ chat: Chat, _ id: String) -> String {
        let n = GroupChat.nick(chat, id)
        if !n.isEmpty { return n }
        if id == GroupChat.me {
            let personas = (try? Repo.personas()) ?? []
            let me = personas.first { $0.id == chat.personaId } ?? ((try? Repo.activePersona()) ?? nil)
            let nick = clean(me?.row.string("nick") ?? "")
            if !nick.isEmpty { return nick }
            let name = me?.row.string("name") ?? ""
            return name.isEmpty ? "我" : name
        }
        guard let c = (try? Repo.character(id)) ?? nil else { return "" }
        return shownName(chat, c)
    }

    static func shownName(_ chat: Chat, _ c: Character) -> String {
        let n = GroupChat.nick(chat, c.id)
        if !n.isEmpty { return n }
        let mine = clean(c.remark)
        if !mine.isEmpty { return mine }
        let net = netName(c)
        return net.isEmpty ? c.name : net
    }

    /// 「自己改网名」对这个角色开着吗：新功能开着、能力开关没关（网页版 selfNickCapOn）
    static func selfNickCapOn(_ char: Character, _ s: AppSettings) -> Bool {
        NewFeat.isOn("selfnick", s, char: char) && !GroupPay.capsOff(s).contains("selfnick")
    }

    /// 角色改自己的网名（网页版 remark.setOwnNick）：改角色身上的 nick，聊天里留一行提示，提示上记着改之前的网名（nickUndo），
    /// 那一行删掉（重新生成那一轮）时退回去。和现在的一样、或是空的，什么都不落
    static func setOwnNick(chat: Chat, char: Character, name: String, turnId: String?) throws -> Message? {
        let v = clean(name)
        guard !v.isEmpty, var cur = try Repo.character(char.id), v != netName(cur) else { return nil }
        let prev = netName(cur)
        cur.row["nick"] = .string(v)
        cur.row.touch()
        try Database.shared.put(Collections.characters, cur.row)
        let who = cur.row.string("name").isEmpty ? "对方" : cur.row.string("name")
        var m = Message.new(chatId: chat.id, role: .char, authorId: cur.id, content: "[\(who)把网名改为「\(v)」]", kind: "notice", turnId: turnId)
        m.row["nickUndo"] = .object(["charId": .string(cur.id), "prev": .string(prev)])
        return m
    }

    // MARK: - 退群（4.733）

    /// 这个群打开了「角色可以自行退群」吗（chat.charLeave，默认关）
    static func leaveOn(_ chat: Chat) -> Bool { chat.row["charLeave"]?.bool == true }

    static func setLeaveOn(_ chatId: String, _ on: Bool) throws {
        guard var c = try Repo.chat(chatId) else { return }
        c.row["charLeave"] = .bool(on)
        c.row.touch()
        try Repo.save(c)
    }

    /// 允不允许：开关开着、它还在群里、退了之后群里至少还留两名角色
    static func canLeave(_ chat: Chat, _ id: String) -> Bool {
        chat.isGroup && leaveOn(chat) && !id.isEmpty && chat.characterIds.contains(id) && chat.characterIds.count > minLeft
    }

    /// 「自行退群」对这个角色开着吗：新功能开着、能力开关没关（网页版 leaveCapOn）
    static func leaveCapOn(_ char: Character, _ s: AppSettings) -> Bool {
        NewFeat.isOn("groupleave", s, char: char) && !GroupPay.capsOff(s).contains("groupleave")
    }

    /// 移出成员（连同管理员身份、禁言），返回还没落库的那一行「某某退出了群聊」。提示上带着退之前的成员、管理员、禁言
    /// （groupUndo，网页版的写法），重新生成那一轮时一起退回去。不允许时什么都不改，回 nil
    static func leave(_ chat: Chat, charId: String, turnId: String?) throws -> Message? {
        guard let now = try Repo.chat(chat.id), canLeave(now, charId) else { return nil }
        let name = GroupPay.nameIn(now, charId)
        var prev: [String: JSONValue] = [:]
        for k in ["characterIds", "admins", "mutes"] { prev[k] = now.row[k] ?? .null }
        var c = now
        c.row["characterIds"] = .array(now.characterIds.filter { $0 != charId }.map { .string($0) })
        c.row["admins"] = .array((now.row["admins"]?.array ?? []).filter { $0.string != charId })
        var mutes = now.row["mutes"]?.object ?? [:]
        mutes.removeValue(forKey: charId)
        c.row["mutes"] = .object(mutes)
        c.row.touch()
        try Repo.save(c)
        var m = Message.new(chatId: chat.id, role: .char, authorId: charId, content: "[\(name)退出了群聊]", kind: "notice", turnId: turnId)
        m.row["groupUndo"] = .object(["chatId": .string(chat.id), "prev": .object(prev)])
        return m
    }

    // MARK: - 我在本群的身份（4.1018）

    /// member：成员，照常发言（缺省）；watch：旁观，不在群里、只看；voice：画外音，不在群里，可以发画外音
    static let modes = ["member", "watch", "voice"]
    static let modeLabel = ["member": "成员", "watch": "旁观", "voice": "画外音"]

    static func mode(_ chat: Chat?) -> String {
        let m = chat?.row.string("groupMode") ?? ""
        return modes.contains(m) ? m : "member"
    }

    static func setMode(_ chatId: String, _ mode: String) throws {
        guard modes.contains(mode), var c = try Repo.chat(chatId) else { return }
        c.row["groupMode"] = .string(mode)
        c.row.touch()
        try Repo.save(c)
    }

    /// 开场用哪一段：旁观、画外音时你不在群里（skeleton.group-opening-watch / -voice）
    static func openingTemplate(_ chat: Chat) -> String {
        switch mode(chat) {
        case "watch": return "skeleton.group-opening-watch"
        case "voice": return "skeleton.group-opening-voice"
        default: return "skeleton.group-opening"
        }
    }

    /// 画外音：居中一行，进历史为 [画外音：…]，不在群里显示成谁的消息
    static func sendVoiceover(_ text: String, chatId: String) throws -> Message? {
        let t = text.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "】", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var m = Message.new(chatId: chatId, role: .user, authorId: GroupChat.me, content: "[画外音：\(t)]", kind: "voiceover")
        m.row["voiceover"] = .string(t)
        m = try Repo.append(m)
        try GroupPay.touch(chatId)
        return m
    }

    /// 画外音那一行要显示的字
    static func voiceoverText(_ m: Message) -> String {
        let v = m.row.string("voiceover")
        if !v.isEmpty { return v }
        return m.content.replacingOccurrences(of: #"^[\[【]\s*画外音\s*[:：]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "]】 "))
    }

    private static let voiceoverLine = try! NSRegularExpression(pattern: #"^[ \t]*[\[【]\s*画外音\s*[:：][^\]】\n]*[\]】][ \t]*$"#,
                                                                options: [.anchorsMatchLines])

    /// 成员不能替用户写画外音：模型照着历史写出来的那几行去掉（网页版 renderGroupTurn）
    static func stripVoiceover(_ raw: String) -> String {
        voiceoverLine.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length), withTemplate: "")
    }

    // MARK: - 本群页面打开时接着聊（4.1018）

    struct Ambient: Equatable, Sendable {
        var page = false
        /// 间隔，分钟
        var pageMin = 3
        /// 每次打开最多几轮，0 为不限
        var perOpen = 10
    }

    static func ambient(_ chat: Chat?) -> Ambient {
        let a = chat?.row["groupAmbient"]?.object ?? [:]
        func n(_ k: String, _ d: Int, _ lo: Int) -> Int { a[k]?.number.map { max(lo, Int($0.rounded())) } ?? d }
        return Ambient(page: a["page"]?.bool == true, pageMin: n("pageMin", 3, 1), perOpen: n("perOpen", 10, 0))
    }

    static func setAmbient(_ chatId: String, _ v: Ambient) throws {
        guard var c = try Repo.chat(chatId) else { return }
        c.row["groupAmbient"] = .object(["page": .bool(v.page), "pageMin": .number(Double(max(1, v.pageMin))),
                                         "perOpen": .number(Double(max(0, v.perOpen)))])
        c.row.touch()
        try Repo.save(c)
    }
}
