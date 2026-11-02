import Foundation

/// 查询消息记录（网页版 SearchPage）：「搜索聊天记录」与「在聊天记录中搜索」共用。只在本机找，不调接口。
///
/// 规则：正文或译文里不分大小写地含有这个词（`range(of:options: .caseInsensitive)`），失败的、撤回的、「正在输入」的不算，
/// 新的在前。词两头的空格不算。
///
/// 几十万条消息时不再逐条解析 JSON：先经 `Database.searchMessages` 在搜索索引里筛出候选，再按上面的规则逐条核对，
/// 所以结果和逐条读一样。索引还没补齐（老库刚升级、后台还在补）时照旧逐条读。
/// 不在主线程上调：界面经 `Task.detached` 调，并且每打一个字就取消上一次（见 SearchChatView）。
enum ChatSearch {
    struct Hit: Identifiable, Sendable {
        var id: String { message.id }
        var message: Message
        var chatTitle: String
    }

    struct Found: Sendable {
        var hits: [Hit]
        /// 角色 id 到显示名
        var names: [String: String]
    }

    static func searchable(_ m: Message) -> String {
        let tr = m.row.string("translation")
        return tr.isEmpty ? m.content : "\(m.content)\n\(tr)"
    }

    /// 在哪几段会话里找：给了 chatId 就是那一段；否则当前身份的全部会话，一段都对不上就全部
    static func scope(chatId: String?) throws -> [Chat] {
        if let chatId { return try Repo.chat(chatId).map { [$0] } ?? [] }
        let s = AppSettings.load()
        let active = s.raw["activePersonaId"]?.string ?? ""
        let all = try Repo.chats()
        let mine = all.filter { $0.personaId == active }
        return active.isEmpty || mine.isEmpty ? all : mine
    }

    /// 找到的消息，新的在前。所在的任务被取消时抛 CancellationError（每段会话之间看一次）
    static func run(_ key: String, chatId: String?, now: Date = Date()) throws -> [Message] {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return [] }
        let needle = Database.searchFold(k)
        var out: [Message] = []
        for c in try scope(chatId: chatId) {
            if Task.isCancelled { throw CancellationError() }
            let list: [Message]
            if let rows = try Database.shared.searchMessages(chatId: c.id, folded: needle) {
                list = rows.map(Message.init(row:))
            } else {
                list = try Repo.messages(chatId: c.id)
            }
            out += list.filter { m in
                !m.isError && !m.isRecalled(at: now) && m.kind != "typing" && searchable(m).range(of: k, options: .caseInsensitive) != nil
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    /// 找到的消息连同所在会话的标题与说话人的名字，界面直接摆
    static func found(_ key: String, chatId: String?) throws -> Found {
        let list = try run(key, chatId: chatId)
        let chars = Dictionary(try Repo.characters().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var titles: [String: String] = [:]
        let hits = try list.map { m -> Hit in
            if titles[m.chatId] == nil, let c = try Repo.chat(m.chatId) {
                titles[m.chatId] = c.isGroup ? (c.title.isEmpty ? "群聊" : c.title) : (c.characterIds.first.flatMap { chars[$0]?.displayName } ?? "会话")
            }
            return Hit(message: m, chatTitle: titles[m.chatId] ?? "会话")
        }
        return Found(hits: hits, names: chars.mapValues(\.displayName))
    }
}
