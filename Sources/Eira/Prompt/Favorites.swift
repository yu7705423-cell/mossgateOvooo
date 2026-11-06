import Foundation

/// 收藏消息（网页版 apps/chat/pages/FavoritesPage.js，ARCHITECTURE 4.853）。
///
/// 收藏是消息上的记号（fav、favAt），不另存一份：删掉消息或会话，收藏随之没有；备份随消息一起带，两边读得回。
/// 取消收藏照网页版写成 fav: false、favAt: 0。与「收藏馆」（藏品）是两回事。
enum Favorites {
    static func isOn(_ m: Message) -> Bool { m.row["fav"]?.bool == true }

    /// 收藏或取消。回改过的那一条
    @discardableResult
    static func set(_ m: Message, _ on: Bool, at: Double = Date().millis) throws -> Message {
        guard var row = try Database.shared.get(Collections.messages, id: m.id) else { throw StoreError(message: "这条消息已不存在") }
        row["fav"] = .bool(on)
        row["favAt"] = .number(on ? at : 0)
        row.touch()
        try Database.shared.put(Collections.messages, row)
        return Message(row: row)
    }

    /// 全部收藏，最近收藏的在前。按会话粗筛含 favAt 的，再逐条核对 fav
    static func all() throws -> [Message] {
        var out: [Message] = []
        for c in try Database.shared.all(Collections.chats) {
            let rows = try Database.shared.containing(Collections.messages, where: c.id, any: [["\"favAt\""]])
            out += rows.map(Message.init(row:)).filter(isOn)
        }
        return out.sorted { ($0.row.number("favAt") ?? 0) > ($1.row.number("favAt") ?? 0) }
    }

    /// 列表里显示的那一行字（网页版 lineOf）
    static func line(_ m: Message) -> String {
        switch m.kind {
        case "image":
            return m.imageId.isEmpty ? "[图片] " + (m.row.string("imageDesc").isEmpty ? m.row.string("prompt") : m.row.string("imageDesc")) : "[图片]"
        case "voice": return "[语音] " + m.row.string("voiceText")
        case "sticker": return m.content.isEmpty ? "[表情]" : m.content
        case "narration": return m.row.string("narration").isEmpty ? m.content : m.row.string("narration")
        default: return m.content
        }
    }
}
