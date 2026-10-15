import Foundation

/// 按类型取记录的几个常用入口。界面与提示词拼装都从这里取，不直接写 SQL。
enum Repo {
    static var db: Database { .shared }

    static func characters() throws -> [Character] {
        try db.all(Collections.characters).map(Character.init(row:))
    }

    static func character(_ id: String) throws -> Character? {
        try db.get(Collections.characters, id: id).map(Character.init(row:))
    }

    /// 消息列表的顺序：置顶的在前，其余按最后一条消息的时间倒排。
    static func chats() throws -> [Chat] {
        try db.all(Collections.chats).map(Chat.init(row:)).sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.lastMessageAt > $1.lastMessageAt
        }
    }

    static func chat(_ id: String) throws -> Chat? {
        try db.get(Collections.chats, id: id).map(Chat.init(row:))
    }

    /// 一段会话的消息，按时间升序。limit 为 nil 时全部取出。
    static func messages(chatId: String, limit: Int? = nil) throws -> [Message] {
        let rows = try limit.map { try db.last(Collections.messages, where: chatId, limit: $0) }
            ?? db.all(Collections.messages, where: chatId)
        return rows.map(Message.init(row:)).filter { $0.kind != "typing" }
    }

    static func save(_ m: Message) throws { try db.put(Collections.messages, m.row) }

    /// 新加一条消息。createdAt 至少比这段会话里最后一条晚一毫秒：消息按 createdAt 排，
    /// 同一毫秒的两条会按随机的 id 排，一次发几张图、发图后紧跟着打字时顺序就乱了。
    @discardableResult
    static func append(_ m: Message) throws -> Message {
        var out = m
        // 会话切到线下时（见面模式，网页版 4.269）发出与生成的每条都记 side：历史里靠它分出哪段是当面
        if out.row["side"] == nil, out.kind != "side", let c = try chat(m.chatId), Face.on(c) { out.row["side"] = .string(Face.FACE) }
        let last = try db.last(Collections.messages, where: m.chatId, limit: 1).first?.created ?? 0
        let at = max(Date().millis, last + 1)
        out.row["createdAt"] = .number(at)
        out.row["updatedAt"] = .number(at)
        try db.put(Collections.messages, out.row)
        return out
    }
    static func save(_ c: Chat) throws { try db.put(Collections.chats, c.row) }

    static func personas() throws -> [Persona] {
        try db.all(Collections.personas).map(Persona.init(row:))
    }

    /// 当前身份：settings.activePersonaId，找不到就取第一个大号。
    static func activePersona(_ s: AppSettings = .load()) throws -> Persona? {
        let all = try personas()
        if let id = s.raw["activePersonaId"]?.string, let p = all.first(where: { $0.id == id }) { return p }
        return all.first { ($0.parentId ?? "").isEmpty } ?? all.first
    }

    /// 某个身份的根账号 id。记忆按根账号隔离。
    static func rootId(of personaId: String, in all: [Persona]) -> String {
        var id = personaId
        var seen = Set<String>()
        while let p = all.first(where: { $0.id == id }), let parent = p.parentId, !parent.isEmpty, !seen.contains(id) {
            seen.insert(id)
            id = parent
        }
        return id
    }

    static func memories(charId: String) throws -> [Memory] {
        try db.all(Collections.memories, where: charId).map(Memory.init(row:))
    }

    static func lorebooks() throws -> [Lorebook] {
        try db.all(Collections.lorebooks).map(Lorebook.init(row:))
    }
}
