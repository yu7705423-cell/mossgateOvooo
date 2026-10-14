import Foundation

/// 转发聊天记录（网页版 system/forward.js，ARCHITECTURE 4.260、4.367）。
///
/// 多选几条，转发给另一段会话。存的是冻起来的副本：谁说的、说了什么、什么时候说的、图片的 id。
/// 原会话删了、消息撤了，这一条仍是转发那一刻的样子。对模型只是一条普通的用户消息，正文就是那几行记录。
/// 不触发回复：对方下一次回复时自然读到它，不多调接口。
enum Forward {
    static let kind = "forward"
    static let maxText = 500

    struct Item: Equatable {
        var who: String
        var mine: Bool
        var kind: String
        var text: String
        var imageId: String
        var at: Double
    }

    private static func clip(_ s: String) -> String {
        let flat = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(flat.prefix(maxText))
    }

    /// 这一段会话叫什么：群用群名，单聊用角色本名
    static func titleOf(_ chat: Chat) -> String {
        let ids = chat.characterIds
        if ids.count > 1 { return chat.title.isEmpty ? "群聊" : chat.title }
        if let c = ids.first.flatMap({ try? Repo.character($0) }) { return c.name }
        return chat.title.isEmpty ? "对话" : chat.title
    }

    /// 把选中的几条冻成副本。按时间排好；名字用本名，自己用这段会话所用身份的名字
    static func snapshot(_ chat: Chat, _ list: [Message]) -> [Item] {
        let me = ((try? Repo.personas()) ?? []).first { $0.id == chat.personaId }?.name ?? "我"
        return list.sorted { $0.createdAt < $1.createdAt }.map { m in
            let mine = m.role == .user
            let who = mine ? me : ((try? Repo.character(m.authorId))?.name ?? "对方")
            return Item(who: who, mine: mine, kind: m.kind.isEmpty ? "text" : m.kind,
                        text: clip(m.isRecalled ? "[已撤回]" : m.content),
                        imageId: m.kind == "image" ? m.imageId : "", at: m.createdAt)
        }
    }

    /// 给模型看的正文。标记是协议，名字与内容是数据
    static func textOf(title: String, items: [Item]) -> String {
        (["[转发的聊天记录：\(title)，共 \(items.count) 条]"] + items.map { "\($0.who)：\($0.text)" }).joined(separator: "\n")
    }

    /// 能转发到哪几段：当前身份名下的全部会话，说话的角色本人的会话也列（4.367），当前这一段排在最前
    static func targets(from chatId: String, personaId: String) throws -> [Chat] {
        try Repo.chats()
            .filter { personaId.isEmpty || $0.personaId.isEmpty || $0.personaId == personaId }
            .sorted { a, b in
                if (a.id == chatId) != (b.id == chatId) { return a.id == chatId }
                return a.lastMessageAt > b.lastMessageAt
            }
    }

    /// 转发：在目标会话里落一条自己发的记录消息，不触发回复。回那条新消息
    @discardableResult
    static func send(from: String, to: String, list: [Message]) throws -> Message {
        guard let src = try Repo.chat(from), var dst = try Repo.chat(to) else { throw ForwardError.noChat }
        let items = snapshot(src, list)
        guard !items.isEmpty else { throw ForwardError.empty }
        let title = "\(titleOf(src))的聊天记录"
        let fw: JSONValue = .object([
            "title": .string(title), "from": .string(from), "count": .number(Double(items.count)),
            "items": .array(items.map { i in
                var o: [String: JSONValue] = ["who": .string(i.who), "mine": .bool(i.mine), "kind": .string(i.kind),
                                              "text": .string(i.text), "at": .number(i.at)]
                if !i.imageId.isEmpty { o["imageId"] = .string(i.imageId) }
                return .object(o)
            }),
        ])
        var m = Message.new(chatId: to, role: .user, authorId: "me", content: textOf(title: title, items: items), kind: kind)
        m.row["forward"] = fw
        m = try Repo.append(m)
        dst.row["lastMessageAt"] = .number(m.createdAt)
        try Repo.save(dst)
        return m
    }

    /// 读回一条转发消息里的副本
    static func items(of m: Message) -> (title: String, items: [Item]) {
        guard case .object(let o)? = m.row["forward"] else { return ("聊天记录", []) }
        let title = o["title"]?.string ?? "聊天记录"
        guard case .array(let arr)? = o["items"] else { return (title, []) }
        let items: [Item] = arr.compactMap { v in
            guard case .object(let i) = v else { return nil }
            return Item(who: i["who"]?.string ?? "", mine: i["mine"]?.bool == true, kind: i["kind"]?.string ?? "text",
                        text: i["text"]?.string ?? "", imageId: i["imageId"]?.string ?? "", at: i["at"]?.number ?? 0)
        }
        return (title, items)
    }

    enum ForwardError: LocalizedError {
        case noChat, empty
        var errorDescription: String? {
            switch self {
            case .noChat: return "会话不存在"
            case .empty: return "没有可转发的消息"
            }
        }
    }
}
