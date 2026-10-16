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

    /// 能编辑的：文字、图片描述、语音文字、旁白（网页版 MsgMenu 的 editMessage）。结构化的卡片不给改
    static func canEdit(_ m: Message) -> Bool {
        ["text", "image", "voice", "narration"].contains(m.kind) && !m.isError && !m.isRecalled
    }

    static func editTitle(_ m: Message) -> String {
        let mine = m.role == .user
        switch m.kind {
        case "image": return mine ? "修改角色读到的图片描述" : "修改图片描述"
        case "voice": return mine ? "修改语音转写" : "修改语音文本"
        case "narration": return "编辑旁白"
        default: return "编辑消息"
        }
    }

    /// 编辑框里一开始的那段：图片是描述，语音是说的话，旁白是摘掉标记的那一句
    static func editableText(_ m: Message) -> String {
        switch m.kind {
        case "image":
            let v = m.role == .user ? m.row.string("imageDesc") : m.row.string("prompt")
            if !v.isEmpty { return v }
            return unmark(m.content, "图片")
        case "voice", "narration": return bodyText(m)
        default: return m.content
        }
    }

    private static func unmark(_ s: String, _ tag: String) -> String {
        guard let r = s.range(of: #"^[\[【]\s*"# + tag + #"\s*[:：]\s*"#, options: .regularExpression) else { return s }
        return String(s[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "]】 "))
    }

    /// 角色发的图与语音按描述生成，改了描述要重新生成一份；我发的只改角色读到的文字，媒体不动
    static func needsRegen(_ m: Message) -> Bool { m.role != .user && (m.kind == "image" || m.kind == "voice") }

    /// 改一条。正文里的标记跟着改（历史里角色读到的是正文）
    static func edit(_ m: Message, text: String) throws -> Message {
        guard canEdit(m) else { throw StoreError(message: "这条消息不能编辑") }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw StoreError(message: "内容不能为空。如需移除请使用删除") }
        var out = m
        switch m.kind {
        case "image":
            if m.role == .user {
                out.row["imageDesc"] = .string(t)
                out.row["vision"] = .string("done")
            } else {
                out.row["prompt"] = .string(t)
            }
            out.row["content"] = .string("[图片：\(t)]")
        case "voice":
            out.row["voiceText"] = .string(t)
            if m.role == .user {
                out.row["asr"] = .string("done")
                let tone = m.row.string("tone").trimmingCharacters(in: .whitespaces)
                out.row["content"] = .string("[语音：\(t)]" + (tone.isEmpty ? "" : "（听起来\(tone)）"))
            } else {
                out.row["content"] = .string("[语音：\(t)]")
            }
        case "narration":
            let n = t.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "】", with: "").trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { throw StoreError(message: "内容不能为空。如需移除请使用删除") }
            out.row["narration"] = .string(n)
            out.row["content"] = .string("[旁白：\(n)]")
        default:
            out.row["content"] = .string(text)
        }
        out.row.touch()
        try Repo.save(out)
        return out
    }

    /// 改译文。清空即去掉译文
    static func setTranslation(_ m: Message, _ text: String) throws -> Message {
        var out = m
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        out.row["translation"] = t.isEmpty ? nil : .string(t)
        out.row.touch()
        try Repo.save(out)
        return out
    }

    /// 改译文页（网页版 4.438 的 TransEditSheet）：正文的译文一栏，有心声的多一栏（innerTrans 为 nil 即没有那一栏、不动它）。
    /// 保存写回消息，标 transEdited。清空即去掉那一份译文
    static func setTranslations(_ m: Message, translation: String, innerTrans: String?) throws -> Message {
        var out = m
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        out.row["translation"] = t.isEmpty ? nil : .string(t)
        if let innerTrans {
            let i = innerTrans.trimmingCharacters(in: .whitespacesAndNewlines)
            out.row["innerTrans"] = i.isEmpty ? nil : .string(i)
        }
        out.row["transEdited"] = .bool(true)
        out.row.touch()
        try Repo.save(out)
        return out
    }

    /// 旁白那一句：存着的 narration，没有就从正文摘掉标记（网页版 narrOf）
    static func narrationText(_ m: Message) -> String {
        let n = m.row.string("narration")
        if !n.isEmpty { return n }
        return m.content.replacingOccurrences(of: #"^[\[【]\s*旁白\s*[:：]\s*|[\]】]$"#, with: "", options: .regularExpression)
    }

    /// 译文显示方式（网页版 system/transview.js 的 pair，4.529）：main 画在正文位置，sub 画在下面那一行（空串不画）。
    /// 心声那一句用它：只显示译文时只有译文，没有点开看原文那一层
    static func transPair(_ orig: String, _ trans: String, mode: String) -> (main: String, sub: String) {
        let t = trans.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || mode == "orig" { return (orig, "") }
        if mode == "trans" { return (t, "") }
        return (orig, t)
    }

    /// 气泡与旁白的译文（网页版 Conversation.js 的 swap / trans）：只显示译文时正文换成译文，点一下看到的是原文；
    /// 只显示原文时不画译文。sub 是点一下展开的那一行
    static func transSwap(_ orig: String, _ trans: String, mode: String) -> (main: String, sub: String) {
        let t = trans.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || mode == "orig" { return (orig, "") }
        if mode == "trans" { return (t, orig.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return (orig, t)
    }

    /// 群聊旁白前面那个名字配哪一种颜色（网页版 4.648 的 narr-c1 到 narr-c8）：按成员在群里的顺序轮着配，
    /// 不在名单里的按第一位算。我写的回 nil（用次级文字色，narr-cme）
    static func narrTone(mine: Bool, memberIds: [String], authorId: String) -> Int? {
        if mine { return nil }
        let seat = memberIds.firstIndex(of: authorId) ?? 0
        return seat % 8
    }

    /// 旁白与「已读，未回复」那一行的长按菜单只有这几项（网页版 MsgMenu 的 narr / silent）。其余消息回 nil，用完整的菜单。
    /// 旁白：重新生成（角色写的、最新一轮）、编辑、复制、多选、删除；「已读，未回复」：重新生成、多选、删除。都没有回应、引用、翻译
    static func slimMenu(_ m: Message, canRegen: Bool) -> [String]? {
        switch m.kind {
        case "silence":
            return (canRegen ? ["regenerate"] : []) + ["select", "delete"]
        case "narration":
            return (canRegen && m.role != .user ? ["regenerate"] : []) + ["edit", "copy", "select", "delete"]
        default:
            return nil
        }
    }

    /// 选到这里（网页版 4.586，照 QQ）：从最后勾的那一条到长按的这一条，中间的全部选上。一条都没勾时只选这一条
    static func pickRange(ids: [String], picked: Set<String>, last: String?, to: String) -> Set<String> {
        guard let b = ids.firstIndex(of: to) else { return picked }
        let a = last.flatMap { picked.contains($0) ? ids.firstIndex(of: $0) : nil } ?? b
        var out = picked
        for id in ids[min(a, b)...max(a, b)] { out.insert(id) }
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

    /// 这一轮模型写在 <thinking> 里的思考（网页版 4.580 的 thinkOf）：存在这一轮第一条的 think 上。没有为空
    static func thinkText(_ m: Message) throws -> String {
        guard m.role == .char else { return "" }
        if !m.turnId.isEmpty {
            let rows = try Repo.messages(chatId: m.chatId).filter { $0.turnId == m.turnId }
            if let head = rows.first(where: { !$0.row.string("think").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return head.row.string("think").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }
        return m.row.string("think").trimmingCharacters(in: .whitespacesAndNewlines)
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
