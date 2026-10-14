import Foundation

/// 只在这段会话里换头像（网页版 avatar.js 的 faceOf / setChatFace / clearChatFace，ARCHITECTURE 4.437）。
///
/// 会话上记 `faces: { 角色id: 图片id, me: 图片id }`，与网页版同一格式。只有这段会话的气泡、摞起来的图、
/// 消息列表这一行读它；联系人、朋友圈、资料页、角色卡仍是角色自己的那张。
/// 网页版换我的专用头像时会另调一次接口描述新头像给角色看；原生版不做这一步，不多调接口。
enum ChatFaces {
    static let me = "me"

    static func faces(_ chat: Chat) -> [String: String] {
        (chat.row["faces"]?.object ?? [:]).compactMapValues { $0.string?.isEmpty == false ? $0.string : nil }
    }

    /// 这段会话里该显示的头像（图片 id）：专用的优先，否则角色（或我）自己的
    static func of(_ chat: Chat?, key: String, fallback: String) -> String {
        guard let chat, let own = faces(chat)[key] else { return fallback }
        return own
    }

    /// 只给这段会话换一张。key 是角色 id 或 me。换下来的那张不删：原生版尚无引用表，宁可留着
    static func set(_ chatId: String, key: String, imageId: String) throws {
        guard !key.isEmpty, var c = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
        var f = c.row["faces"]?.object ?? [:]
        f[key] = .string(imageId)
        c.row["faces"] = .object(f)
        if key == me { c.row["faceNote"] = .string("") }
        c.row.touch()
        try Repo.save(c)
    }

    /// 恢复成角色（或我）自己的那张。没设过回 false
    @discardableResult
    static func clear(_ chatId: String, key: String) throws -> Bool {
        guard var c = try Repo.chat(chatId), var f = c.row["faces"]?.object, f[key] != nil else { return false }
        f.removeValue(forKey: key)
        c.row["faces"] = .object(f)
        if key == me { c.row["faceNote"] = .string("") }
        c.row.touch()
        try Repo.save(c)
        return true
    }
}
