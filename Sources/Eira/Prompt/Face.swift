import Foundation

/// 会话页上的线上 / 线下切换（网页版 system/face.js，ARCHITECTURE 4.269）。
///
/// 不另开页面、不另开会话、不写长文：还是这条消息流、还是气泡，只是切过去之后两个人在同一处，每轮带旁白。
/// 存法：会话上一个 face 对象记着现在是不是线下、在哪、几点、什么情境；切换那一刻落一条 kind 为 side 的消息当分隔线；
/// 之后发出和生成的每条消息记 side 为 face。老消息没有这个字段，一律视为线上。
/// 历史进提示词时按 side 的变化插「以下当面」「以下在手机上」两种标记。和「线下」长文（Scenes）互不影响。
enum Face {
    static let FACE = "face", PHONE = "phone"

    static func on(_ chat: Chat?) -> Bool { chat?.row["face"]?["on"]?.bool == true }
    static func info(_ chat: Chat?) -> [String: JSONValue] { chat?.row["face"]?.object ?? [:] }
    static func sideOf(_ m: Message) -> String { m.row.string("side") == FACE ? FACE : PHONE }
    static func isMark(_ m: Message) -> Bool { m.kind == "side" }

    private static func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 分隔线上写的那几个字：线下 · 地点 · 时刻
    static func label(_ info: [String: JSONValue]) -> String {
        let t = [clean(info["place"]?.string ?? ""), clean(info["at"]?.string ?? "")].filter { !$0.isEmpty }.joined(separator: " · ")
        return t.isEmpty ? "线下" : "线下 · \(t)"
    }

    /// 切到线下。落一条分隔线，之后的消息都算当面。已经在线下时只改这几项
    @discardableResult
    static func enter(_ chatId: String, place: String, at: String, note: String) throws -> Message? {
        guard var chat = try Repo.chat(chatId) else { return nil }
        var fresh: [String: JSONValue] = ["on": .bool(true), "place": .string(clean(place)), "at": .string(clean(at)),
                                          "note": .string(clean(note)), "since": .number(Date().millis)]
        var cur = info(chat)
        if on(chat) {
            fresh["since"] = cur["since"] ?? fresh["since"]
            for (k, v) in fresh { cur[k] = v }
            chat.row["face"] = .object(cur)
            try Repo.save(chat)
            try relabel(chatId, cur)
            return nil
        }
        for (k, v) in fresh { cur[k] = v }
        chat.row["face"] = .object(cur)
        chat.row["lastMessageAt"] = .number(Date().millis)
        chat.row.touch()
        try Repo.save(chat)
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: "[\(label(cur))]", kind: "side")
        m.row["side"] = .string(FACE)
        m.row["face"] = .object(["place": cur["place"] ?? .string(""), "at": cur["at"] ?? .string(""), "note": cur["note"] ?? .string("")])
        return try Repo.append(m)
    }

    /// 分隔线上那条跟着改，历史里读到的才是改后的
    private static func relabel(_ chatId: String, _ info: [String: JSONValue]) throws {
        let recent = try Repo.messages(chatId: chatId, limit: 400)
        guard var line = recent.last(where: { $0.kind == "side" && $0.row.string("side") == FACE }) else { return }
        line.row["face"] = .object(["place": info["place"] ?? .string(""), "at": info["at"] ?? .string(""), "note": info["note"] ?? .string("")])
        line.row["content"] = .string("[\(label(info))]")
        try Repo.save(line)
    }

    /// 切回线上。落一条分隔线；地点那几项留在 chat.face 里当下次的预填
    @discardableResult
    static func leave(_ chatId: String) throws -> Message? {
        guard var chat = try Repo.chat(chatId), on(chat) else { return nil }
        var cur = info(chat)
        cur["on"] = .bool(false)
        cur["since"] = .number(0)
        chat.row["face"] = .object(cur)
        chat.row["lastMessageAt"] = .number(Date().millis)
        chat.row.touch()
        try Repo.save(chat)
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: "[回到线上]", kind: "side")
        m.row["side"] = .string(PHONE)
        return try Repo.append(m)
    }

    /// 线下期间顶上那一条提示条显示不显示（只管界面）
    static func barShown(_ chat: Chat?) -> Bool { chat?.row["faceBar"]?.bool != false }

    /// 线下时的世界书：关掉的、额外挂上的（记在会话上）
    static func books(_ chat: Chat) -> (off: [String], on: [String]) {
        (chat.row.strings("faceOffBookIds"), chat.row.strings("faceBookIds"))
    }

    /// 文风：和线下长文同一份预设库，可以多选
    static func toneText(_ chat: Chat, _ s: AppSettings) -> String {
        var row = Row(fields: ["tones": chat.row["faceTones"] ?? .array([]), "toneText": .string(chat.row.string("faceToneText"))])
        row["id"] = .string(chat.id)
        return Tone.forScene(row, s)
    }

    /// 线下时给哪些能力：面对面说得通的那几样（转账、外卖、表情、图片、语音、打电话九成不成立）
    static let caps: Set<String> = ["narration", "inner", "time", "translate", "quote", "dice", "gift", "award",
                                    "closetact", "remark", "recall", "card", "mcp"]

    /// 历史里「以下当面」那一行：带着地点、时刻
    static func markText(_ info: [String: JSONValue], settings s: AppSettings) -> String {
        var lines: [String] = []
        if let p = info["place"]?.string, !p.isEmpty { lines.append("地点：\(p)") }
        if let a = info["at"]?.string, !a.isEmpty { lines.append("时刻：\(a)") }
        return Templates.render("skeleton.face-mark", ["lines": lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")], settings: s)
    }
}
