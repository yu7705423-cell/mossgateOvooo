import Foundation

/// 聊天草稿箱（网页版 system/drafts.js，ARCHITECTURE 4.335）：角色写了又没发出去的话。
///
/// 随回复一起：角色在同一次回复里单独写一行 [草稿：…]，这一行不落进聊天，存到这里。不多调接口（第 15 条）。
/// 写不写、写什么由角色自己定（第 22 条）；系统只在这段会话开了草稿箱时告诉它有这种写法。
/// 开关挂在会话上（chat.draftsOn），默认关。一行：chatId、charId、text、turnId（重新生成那一轮时撤回）。
enum Drafts {
    static let collection = "drafts"

    static func on(_ chat: Chat?) -> Bool { chat.map { !$0.isGroup && $0.row.bool("draftsOn") } ?? false }

    static func setOn(_ chatId: String, _ v: Bool) throws {
        guard var c = try Repo.chat(chatId) else { return }
        c.row["draftsOn"] = .bool(v)
        c.row.touch()
        try Repo.save(c)
    }

    /// 新的在前
    static func list(_ chatId: String) -> [Row] {
        ((try? Database.shared.all(collection, where: chatId)) ?? []).sorted { ($0.created ?? 0) > ($1.created ?? 0) }
    }

    @discardableResult
    static func add(chatId: String, charId: String, text: String, turnId: String) throws -> Row? {
        let t = String(text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !t.isEmpty else { return nil }
        let row = Row.new(prefix: "dr", ["chatId": .string(chatId), "charId": .string(charId), "text": .string(t), "turnId": .string(turnId)])
        try Database.shared.put(collection, row)
        return row
    }

    static func remove(_ id: String) throws { try Database.shared.delete(collection, id: id) }

    /// 重新生成那一轮：这一轮写下的草稿一起撤
    static func undoTurn(chatId: String, turnId: String) throws {
        guard !turnId.isEmpty else { return }
        for d in list(chatId) where d.string("turnId") == turnId { try remove(d.id) }
    }
}
