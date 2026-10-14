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
}
