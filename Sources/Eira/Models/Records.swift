import Foundation

// 几类主要记录的视图。字段名与默认值照抄网页版（字段表见 docs/web-fields.md）。
//
// 每一类都只是包着一条 Row：认得的字段给一个属性，不认得的原样留在 row 里，写回去不丢。
// 网页版的记录没有固定结构，几乎每个字段都可能缺，缺了按网页版读的时候的默认值算。

/// 一个角色（characters，前缀 char）。
struct Character: Identifiable, Equatable, Sendable {
    var row: Row
    var id: String { row.id }

    var name: String { row.string("name").isEmpty ? "新角色" : row.string("name") }
    /// 一句话签名。列表里只许显示它，不许显示人设（CLAUDE.md 第 6 条）。
    var signature: String { row.string("signature") }
    /// 人设正文。只在编辑资料页出现。
    var persona: String { row.string("persona") }
    var scenario: String { row.string("scenario") }
    var firstMessage: String { row.string("firstMessage") }
    var exampleDialogue: String { row.string("exampleDialogue") }
    var core: String { row.string("core") }
    var remark: String { row.string("remark") }
    var avatar: String { row.string("avatar") }
    var lorebookIds: [String] { row.strings("lorebookIds") }
    var group: String { row.string("group") }
    var tags: [String] { row.strings("tags") }
    /// 不为空表示这是 parentId 那个角色的小号。
    var parentId: String? { row["parentId"]?.string }
    var isNpc: Bool { row.bool("isNpc") }
    var pinned: Bool { row.bool("pinned") }
    var archived: Bool { (row.number("archived") ?? 0) > 0 }

    /// 列表里显示的名字：用户写了备注就用备注。
    var displayName: String { remark.isEmpty ? name : remark }
}

/// 一段会话（chats，前缀 chat）。没有 type 字段：group 为 true 或成员多于一个就是群聊（网页版 group.js）。
/// 短信不在这里，在 smsThreads。
struct Chat: Identifiable, Equatable, Sendable {
    var row: Row
    var id: String { row.id }

    var characterIds: [String] { row.strings("characterIds") }
    var isGroup: Bool { row.bool("group") || characterIds.count > 1 }
    var personaId: String { row.string("personaId") }
    var title: String { row.string("title") }
    var lastMessageAt: Double { row.number("lastMessageAt") ?? row.created ?? 0 }
    var unread: Int { Int(row.number("unread") ?? 0) }
    var pinned: Bool { row.bool("pinned") }
    var muted: Bool { row.bool("muted") }
    var avatar: String { row.string("avatar") }
    var summary: String { row.string("summary") }
    /// 这段会话用的预设；空串是全局预设。
    var presetId: String { row.string("presetId") }
}

/// 一条消息（messages，前缀 msg，按 chatId 查）。
///
/// role 只有 user 与 char 两种；居中的系统提示也是这两种之一，靠额外字段区分。
/// content 是模型读到的那一份：图片、转账这类结构化消息存的是 `[图片：…]` 这种方括号标记，那是协议，一字不改。
struct Message: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, char }

    var row: Row
    var id: String { row.id }

    var chatId: String { row.string("chatId") }
    var role: Role { Role(rawValue: row.string("role")) ?? .user }
    /// 'me' 或角色 id。群聊里是说话的那个成员。
    var authorId: String { row.string("authorId") }
    /// 缺省按 text。
    var kind: String { row.string("kind").isEmpty ? "text" : row.string("kind") }
    var content: String { row.string("content") }
    var createdAt: Double { row.created ?? 0 }
    var isError: Bool { row.string("status") == "error" }
    var error: String { row.string("error") }
    var turnId: String { row.string("turnId") }
    var imageId: String { row.string("imageId") }
    var isRecalled: Bool { row["recalled"]?.object != nil }

    /// 新建一条。和网页版 reply.js 的 base 同样的几项。
    static func new(chatId: String, role: Role, authorId: String, content: String, kind: String = "text",
                    turnId: String? = nil) -> Message {
        var f: [String: JSONValue] = [
            "chatId": .string(chatId), "role": .string(role.rawValue), "authorId": .string(authorId),
            "kind": .string(kind), "content": .string(content), "status": .string("done"),
        ]
        if let turnId { f["turnId"] = .string(turnId) }
        return Message(row: .new(prefix: "msg", f))
    }
}

/// 我的一个身份（personas，前缀 me）。parentId 为空的是大号，否则是那个大号的小号。
/// 当前用的是 settings.activePersonaId。
struct Persona: Identifiable, Equatable, Sendable {
    var row: Row
    var id: String { row.id }

    var name: String { row.string("name").isEmpty ? "新账号" : row.string("name") }
    var parentId: String? { row["parentId"]?.string }
    var avatar: String { row.string("avatar") }
    var signature: String { row.string("signature") }
    var description: String { row.string("description") }
}

/// 一条记忆（memories，前缀 mem）。
///
/// kind、status、at 不要直接读字段：老记录没有这几项，要按网页版 context/memory.js 的 kindOf、statusOf、atOf 推。
struct Memory: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case event, fact, open }

    var row: Row
    var id: String { row.id }

    /// 空串是老的「全局」记忆，不注入。
    var charId: String { row.string("charId") }
    var personaId: String { row.string("personaId") }
    /// 只在这段群聊里有效。
    var scopeChat: String { row.string("scopeChat") }
    var content: String { row.string("content") }
    var rank: String { row.string("rank") }
    var keywords: [String] { row.strings("keywords") }
    var pinned: Bool { row.bool("pinned") }
    var taboo: Bool { row.bool("taboo") }
    var supersededBy: String { row.string("supersededBy") }
    var fateHidden: String { row.string("fateHidden") }

    var kind: Kind {
        if let k = Kind(rawValue: row.string("kind")) { return k }
        switch row.string("category") {
        case "pending": return .open
        case "emotion", "relation", "event": return .event
        default: return .fact
        }
    }

    var status: String {
        let s = row.string("status")
        if !s.isEmpty { return s }
        return content.contains("已完结") ? "done" : "open"
    }

    var at: Double { row.number("at") ?? row.created ?? 0 }

    /// 向量。备份里是 `{"__f32": base64}`，也认普通数组与老备份的下标对象（网页版 typed.js）。
    var vector: [Float]? {
        guard let v = row["vec"] else { return nil }
        if let b64 = v["__f32"]?.string, let data = Data(base64Encoded: b64), data.count % 4 == 0 {
            return data.withUnsafeBytes { buf in
                (0..<(buf.count / 4)).map { buf.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            }
        }
        if let arr = v.array { return arr.compactMap { $0.number.map(Float.init) } }
        if let obj = v.object, !obj.isEmpty {
            var out: [Float] = []
            for i in 0..<obj.count {
                guard let n = obj[String(i)]?.number else { return nil }
                out.append(Float(n))
            }
            return out
        }
        return nil
    }
}

/// 一本世界书（lorebooks，前缀 lb）。条目内嵌在书里。
struct Lorebook: Identifiable, Equatable, Sendable {
    var row: Row
    var id: String { row.id }

    var name: String { row.string("name") }
    var global: Bool { row.bool("global") }

    /// 用途：chat、image、voice、memory、forum，互不混用。四个标记都没有就是 chat。
    var purpose: String {
        if row.bool("forImage") { return "image" }
        if row.bool("forVoice") { return "voice" }
        if row.bool("forMemory") { return "memory" }
        if row.bool("forForum") { return "forum" }
        return "chat"
    }

    var entries: [LoreEntry] {
        (row["entries"]?.array ?? []).compactMap { $0.object.map(LoreEntry.init(json:)) }
    }
}

struct LoreEntry: Identifiable, Equatable, Sendable {
    var json: [String: JSONValue]
    var id: String { json["id"]?.string ?? "" }

    var comment: String { json["comment"]?.string ?? "" }
    var keys: [String] { json["keys"]?.array?.compactMap(\.string) ?? [] }
    var secondaryKeys: [String] { json["secondaryKeys"]?.array?.compactMap(\.string) ?? [] }
    var content: String { json["content"]?.string ?? "" }
    var enabled: Bool { json["enabled"]?.bool ?? true }
    var constant: Bool { json["constant"]?.bool ?? false }
    var caseSensitive: Bool { json["caseSensitive"]?.bool ?? false }
    var probability: Double { json["probability"]?.number ?? 100 }
    var priority: Double { json["priority"]?.number ?? 100 }
    var order: Double { json["order"]?.number ?? 0 }
    /// 'card' 是网页卡片条目，不当世界书注入。
    var isCard: Bool { json["type"]?.string == "card" }

    /// before：放在角色卡前面；after：后面。老数据的 position 按网页版迁移 4 换算。
    var part: String {
        if let p = json["part"]?.string, p == "before" || p == "after" { return p }
        if let pos = json["position"]?.string { return pos == "system" ? "before" : "after" }
        return "before"
    }

    /// 0 留在系统区；N 插在倒数第 N 条历史之前。
    var depth: Int { max(0, Int(json["depth"]?.number ?? 0)) }
}
