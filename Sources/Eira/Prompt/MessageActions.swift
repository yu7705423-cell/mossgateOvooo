import Foundation

/// 长按菜单里那几件事。规矩照网页版：撤回不是删除；删除整条抹掉，且不能撤销。
enum MessageActions {
    /// 能不能由我撤回：只能撤回自己说的话，居中的提示不算（网页版 recall.js 的 canRecall）。
    static func canRecall(_ m: Message) -> Bool {
        m.role == .user && m.row["recalled"] == nil && m.kind != "notice" && m.kind != "scene"
    }

    /// 我撤回一条。seen 记的是撤回时角色是不是已经回过话：回过就说明它读到了，进上下文时带原文。
    static func recall(_ m: Message) throws -> Message {
        guard canRecall(m) else { throw StoreError(message: "这条消息不能撤回") }
        let seen = try Repo.messages(chatId: m.chatId).contains {
            $0.role == .char && $0.kind != "notice" && $0.createdAt > m.createdAt
        }
        var out = m
        out.row["recalled"] = .object(["at": .number(Date().millis), "by": .string("user"), "seen": .bool(seen)])
        out.row.touch()
        try Repo.save(out)
        return out
    }

    static func canEdit(_ m: Message) -> Bool { m.kind == "text" && !m.isError }

    /// 改一条文字消息的正文。
    static func edit(_ m: Message, text: String) throws -> Message {
        guard canEdit(m) else { throw StoreError(message: "这条消息不能编辑") }
        var out = m
        out.row["content"] = .string(text)
        out.row.touch()
        try Repo.save(out)
        return out
    }

    /// 删一条。它若是一轮的第一条（带着原文与各个版本），把这些挪到同一轮剩下的下一条上，
    /// 不然这一轮就再也切不了版本、也没法重新生成成同一轮。
    static func delete(_ m: Message) throws {
        let headKeys = ["raw", "think", "swipes", "swipeIndex", "served"]
        if !m.turnId.isEmpty, headKeys.contains(where: { m.row[$0] != nil }),
           var next = try Repo.messages(chatId: m.chatId).first(where: { $0.turnId == m.turnId && $0.id != m.id }) {
            for k in headKeys where next.row[k] == nil { next.row[k] = m.row[k] }
            try Repo.save(next)
        }
        try Interact.drop(m)
    }

    /// 引用这一条时存的四个字段（网页版 reply.js 的 quoteFields）。
    static func quoteFields(of q: Message) -> [String: JSONValue] {
        let flat = q.content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return [
            "quoteId": .string(q.id),
            "quoteText": .string(String(flat.prefix(40))),
            "quoteRole": .string(q.role.rawValue),
            "quoteAuthorId": .string(q.authorId),
        ]
    }

    /// 这一条的正文（记住这句、收进示例用）：文字原样，语音取说的话，旁白取旁白
    static func bodyText(_ m: Message) -> String {
        switch m.kind {
        case "text": return m.content.trimmingCharacters(in: .whitespacesAndNewlines)
        case "narration":
            let n = m.row.string("narration")
            return (n.isEmpty ? m.content : n).trimmingCharacters(in: .whitespacesAndNewlines)
        case "voice":
            var t = m.row.string("voiceText")
            if t.isEmpty, let r = m.content.range(of: #"^[\[【]\s*语音\s*[:：]\s*"#, options: .regularExpression) {
                t = String(m.content[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "]】 "))
            }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return ""
        }
    }

    /// 记住这句：存成这个角色的一条 A 级记忆，来源记成手写（网页版 MsgMenu 的 remember）。不调接口。返回新记忆的 id
    static func remember(_ m: Message, chat: Chat, char: Character?) throws -> (memoryId: String, charId: String) {
        let body = bodyText(m)
        guard !body.isEmpty else { throw StoreError(message: "这一条没有可记的正文") }
        let charId = m.role == .user ? (char?.id ?? "") : (m.authorId.isEmpty ? (char?.id ?? "") : m.authorId)
        guard !charId.isEmpty else { throw StoreError(message: "这段对话还没有角色") }
        let who = m.role == .user ? "我" : ((try? Repo.character(charId))?.name ?? char?.name ?? "对方")
        let at = m.createdAt > 0 ? m.createdAt : Date().millis
        let row = Row.new(prefix: "mem", [
            "charId": .string(charId), "personaId": .string(chat.personaId),
            "content": .string(String("\(who)说：\(body)".prefix(300))),
            "category": .string("event"), "kind": .string("event"), "rank": .string("A"), "keywords": .array([]),
            "source": .string("manual"), "at": .number(at), "updatedAt": .number(Date().millis),
        ])
        try Database.shared.put(Collections.memories, row)
        return (row.id, charId)
    }

    /// 收进说话示例：把角色这句话接在角色卡的说话示例后面（网页版 addExample）。已有就不重复
    @discardableResult
    static func addExample(_ m: Message) throws -> Bool {
        let body = bodyText(m)
        guard m.role == .char, !body.isEmpty, var c = try Repo.character(m.authorId) else { throw StoreError(message: "这一条没有可收的正文") }
        let cur = c.row.string("exampleDialogue").trimmingCharacters(in: .whitespacesAndNewlines)
        if cur.contains(body) { return false }
        c.row["exampleDialogue"] = .string((cur.isEmpty ? "" : cur + "\n") + "\(c.name)：\(body)")
        c.row.touch()
        try Database.shared.put(Collections.characters, c.row)
        return true
    }

    /// 生成信息：这一轮当前那一版由哪套接口、哪个模型、什么时候写的（记在这一轮第一条的 served 上）
    static func servedText(_ m: Message) throws -> String {
        guard !m.turnId.isEmpty else { return "这一条生成时尚未记录模型" }
        let rows = try Repo.messages(chatId: m.chatId).filter { $0.turnId == m.turnId }
        guard let head = rows.first(where: { $0.row["served"] != nil }) ?? rows.first else { return "这一条生成时尚未记录模型" }
        let list = head.row["served"]?.array ?? []
        let i = Int(head.row.number("swipeIndex") ?? Double(list.count - 1))
        guard list.indices.contains(i), let o = list[i].object else { return "这一条生成时尚未记录模型" }
        let name = o["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "接口"
        let model = o["model"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "未知模型"
        var when = ""
        if let at = o["at"]?.number {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "yyyy/M/d HH:mm:ss"
            when = "，" + f.string(from: Date(timeIntervalSince1970: at / 1000))
        }
        return "由「\(name)」的 \(model) 生成\(when)"
    }
}
