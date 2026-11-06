import Foundation

/// 角色自行进出线下（网页版 system/meet.js，ARCHITECTURE 4.721、4.723）。
///
/// 角色在回复里写 [见面：地点]：聊天里落一张见面卡片（kind 为 meet），由你选
///   here  就在聊天里（面对面，Face.enter）
///   page  单独一个页面（线下长文那一页，Scenes.create，不内嵌）
///   no    不去：卡片改为未答应，聊天里落一行，角色下一轮读到
/// 角色在面对面期间写 [回到线上]：直接回到线上（Face.leave），和你点「回到线上」一样。
/// 线下长文里角色单独一行写 [回到线上]：这一场收场（SceneRun.settle）。
/// 什么时候提、什么时候走，由角色自己的动机决定（第 22 条）；这里只把标记落成状态、检查状态允不允许。
/// 开关只有一处：新功能 meet（按角色）开着、能力开关里没关。提示词与执行两头都只认它。
enum Meet {
    static let kind = "meet"
    static let pending = "pending"

    static func capOn(_ char: Character?, _ s: AppSettings = .load()) -> Bool {
        let off = Set((s.raw["capsOff"]?.array ?? []).compactMap(\.string))
        return NewFeat.isOn("meet", s, char: char) && !off.contains("meet")
    }

    /// 这段会话还挂着、没选的那张见面卡片
    static func pendingOf(_ chatId: String) -> Message? {
        ((try? Repo.messages(chatId: chatId, limit: 200)) ?? []).last {
            $0.kind == kind && $0.row["meet"]?["state"]?.string == pending
        }
    }

    /// 会话里内嵌的、还没收场的那一场（网页版 scene.openInline）
    static func openInline(_ chatId: String) -> Row? {
        Scenes.ofChat(chatId).first { $0.bool("inline") && ($0.number("endedAt") ?? 0) == 0 }
    }

    /// 此刻能不能再提见面：已经在面对面、正演着一场内嵌的线下、还有一张没选的卡片，都不能
    static func canPropose(_ chatId: String) -> Bool {
        guard let chat = try? Repo.chat(chatId) else { return false }
        return !Face.on(chat) && openInline(chatId) == nil && pendingOf(chatId) == nil
    }

    /// 角色写了 [见面：地点]。回要落下的那张卡片（不入库，由调用方 append）；此刻不允许就回 nil，那一行不落
    static func propose(_ chatId: String, charId: String, place: String, turnId: String) throws -> Message? {
        guard canPropose(chatId) else { return nil }
        let p = place.trimmingCharacters(in: .whitespaces)
        var m = Message.new(chatId: chatId, role: .char, authorId: charId, content: p.isEmpty ? "[见面]" : "[见面：\(p)]",
                            kind: kind, turnId: turnId)
        m.row["meet"] = .object(["place": .string(p), "state": .string(pending)])
        return m
    }

    /// 你在卡片上选了一项。page 回新建的那一场的 id（调用方打开它），其余回空串。已经选过的、此刻已在线下的不再动
    @discardableResult
    static func decide(_ msgId: String, _ how: String) throws -> String {
        guard var m = (try Database.shared.get(Collections.messages, id: msgId)).map(Message.init(row:)),
              m.kind == kind, m.row["meet"]?["state"]?.string == pending,
              let chat = try Repo.chat(m.chatId) else { return "" }
        var meet = m.row["meet"]?.object ?? [:]
        let place = meet["place"]?.string ?? ""
        func save(_ state: String, _ extra: [String: JSONValue] = [:]) throws {
            meet["state"] = .string(state)
            for (k, v) in extra { meet[k] = v }
            m.row["meet"] = .object(meet)
            m.row.touch()
            try Repo.save(m)
        }
        if how == "no" {
            try save("declined")
            var n = Message.new(chatId: m.chatId, role: .user, authorId: "me", content: "[未答应见面]", kind: "notice")
            n.row["meetNo"] = .bool(true)
            try Repo.append(n)
            return ""
        }
        if Face.on(chat) || openInline(m.chatId) != nil { return "" }
        if how == "here" {
            try save("here")
            try Face.enter(m.chatId, place: place, at: "", note: "")
            return ""
        }
        if how == "page" {
            let members = chat.characterIds.filter { ((try? Repo.character($0)) ?? nil) != nil }
            var d = Scenes.Draft()
            d.place = place
            d.castIds = members.count > 1 ? members : [m.authorId]
            let row = try Scenes.create(chatId: m.chatId, d)
            try save("page", ["sceneId": .string(row.id)])
            return row.id
        }
        return ""
    }

    /// 角色写了 [回到线上]：面对面时回到线上，否则不动
    static func partWays(_ chatId: String) throws {
        guard let chat = try Repo.chat(chatId), Face.on(chat) else { return }
        try Face.leave(chatId)
    }

    /// 卡片上写的那一行状态
    static func stateText(_ m: Message) -> String {
        switch m.row["meet"]?["state"]?.string ?? pending {
        case "here": return "已在聊天里见面"
        case "page": return "已在单独页面中见面"
        case "declined": return "未答应"
        default: return ""
        }
    }

    // MARK: - 线下长文里角色自己收场（网页版 scenerun 的 PART_LINE，4.723）

    private static let sceneEnd = try! NSRegularExpression(pattern: #"^[ \t]*[\[【(（]\s*回到线上\s*[\]】)）][ \t]*$"#, options: [.anchorsMatchLines])

    /// 正文里单独一行的 [回到线上]：一律摘掉（功能关着也摘），回摘过的正文与有没有这一行
    static func takeSceneEnd(_ text: String) -> (text: String, ending: Bool) {
        let ns = text as NSString
        guard sceneEnd.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil else { return (text, false) }
        let out = sceneEnd.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out, true)
    }

    /// 线下规则后面那一段收场写法：这一场有一名角色开着这项才给（网页版 sceneExits 的 end）
    static func sceneEndPiece(_ scene: Row, _ s: AppSettings) -> String {
        Scenes.castOf(scene).contains { capOn($0, s) } ? "\n\n" + Templates.get("skeleton.scene-end", settings: s) : ""
    }
}
