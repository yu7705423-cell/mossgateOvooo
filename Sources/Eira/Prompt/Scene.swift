import Foundation

/// 线下：一场戏 + 一段段正文（网页版 system/scene.js，ARCHITECTURE 4.107）。
///
/// 和线上共用角色卡、世界书、记忆、人设 —— 那是同一段关系的两面，所以一场戏挂在一段会话上（scenes，按 chatId 查）。
/// 正文一段一行（beats，按 sceneId 查）。role 是 char / me / director（场外指示：作为指令进提示词，不占一张）。
/// 一段有几个版本（swipes）：重写不删旧的，往后添一版。字段与网页版一致，两边导入导出互通。
enum Scene {
    static let scenes = "scenes"
    static let beats = "beats"
    static let CHAR = "char", ME = "me", DIRECTOR = "director"

    // MARK: - 场次

    static func get(_ id: String) -> Row? { (try? Database.shared.get(scenes, id: id)) ?? nil }

    static func ofChat(_ chatId: String) -> [Row] {
        ((try? Database.shared.all(scenes, where: chatId)) ?? [])
            .sorted { ($0.number("updatedAt") ?? $0.created ?? 0) > ($1.number("updatedAt") ?? $1.created ?? 0) }
    }

    private static func ids(_ v: [String]) -> [String] {
        var seen = Set<String>()
        return v.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    struct Draft {
        var title = "", place = "", at = "", note = ""
        var castIds: [String] = []
        var opening = CHAR
        var tones: [String] = []
        var toneText = ""
        var offBookIds: [String] = []
        var bookIds: [String] = []
        var autoEnter = true
        var enterIds: [String]?
        var withTrans = false
    }

    @discardableResult
    static func create(chatId: String, _ d: Draft) throws -> Row {
        let chat = try Repo.chat(chatId)
        let cast = d.castIds.isEmpty ? (chat?.characterIds ?? []) : d.castIds
        // 记住这一次挑的文风、关掉的书，下次新建时预填（只是默认值，开关仍在这一场自己身上）
        var s = try AppSettings.loadForWrite()
        s.raw["sceneToneLast"] = .array(ids(d.tones).map { .string($0) })
        s.raw["sceneBooksOffLast"] = .array(ids(d.offBookIds).map { .string($0) })
        s.raw["sceneBooksOnLast"] = .array(ids(d.bookIds).map { .string($0) })
        try s.save()
        var f: [String: JSONValue] = [
            "chatId": .string(chatId), "title": .string(d.title.trimmingCharacters(in: .whitespacesAndNewlines)),
            "place": .string(d.place.trimmingCharacters(in: .whitespacesAndNewlines)),
            "at": .string(d.at.trimmingCharacters(in: .whitespacesAndNewlines)),
            "castIds": .array(ids(cast).map { .string($0) }), "note": .string(d.note.trimmingCharacters(in: .whitespacesAndNewlines)),
            "opening": .string(d.opening == ME ? ME : CHAR),
            "tones": .array(ids(d.tones).map { .string($0) }), "toneText": .string(d.toneText),
            "offBookIds": .array(ids(d.offBookIds).map { .string($0) }), "bookIds": .array(ids(d.bookIds).map { .string($0) }),
            "inline": .bool(false), "endedAt": .number(0),
            "left": .object([:]), "autoEnter": .bool(d.autoEnter),
            "summary": .string(""), "stage": .null, "withTrans": .bool(d.withTrans),
        ]
        f["enterIds"] = d.enterIds.map { .array(ids($0).map { .string($0) }) } ?? .null
        let row = Row.new(prefix: "sc", f)
        try Database.shared.put(scenes, row)
        return row
    }

    @discardableResult
    static func update(_ id: String, _ patch: [String: JSONValue]) throws -> Row? {
        guard var row = try Database.shared.get(scenes, id: id) else { return nil }
        for (k, v) in patch { row[k] = v }
        row.touch()
        try Database.shared.put(scenes, row)
        return row
    }

    /// 删一场，连着它的正文一起
    static func remove(_ id: String) throws {
        for b in beatsOf(id) { try Database.shared.delete(beats, id: b.id) }
        try Database.shared.delete(scenes, id: id)
    }

    static func end(_ id: String) throws { try update(id, ["endedAt": .number(Date().millis)]) }

    // MARK: - 谁在场（4.439）

    static func castOf(_ scene: Row) -> [Character] {
        scene.strings("castIds").compactMap { (try? Repo.character($0)) ?? nil }
    }

    static func leftMap(_ scene: Row) -> [String: JSONValue] { scene["left"]?.object ?? [:] }

    static func presentOf(_ scene: Row) -> [Character] {
        let left = leftMap(scene)
        return castOf(scene).filter { left[$0.id] == nil || left[$0.id] == .null }
    }

    static func leftOf(_ scene: Row) -> [Character] {
        let left = leftMap(scene)
        return castOf(scene).filter { left[$0.id] != nil && left[$0.id] != .null }
    }

    /// 可以自行进场的：离开了的，加上名单上的（名单没填过就是会话里尚未在场的成员）。关着「角色可以自行进场」时只有离开了的
    static func enterable(_ scene: Row) -> [Character] {
        let present = Set(presentOf(scene).map(\.id))
        let back = leftOf(scene)
        if scene["autoEnter"]?.bool == false { return back }
        let pool: [String]
        if let list = scene["enterIds"]?.array {
            pool = list.compactMap(\.string)
        } else {
            let cast = scene.strings("castIds")
            pool = (((try? Repo.chat(scene.string("chatId"))) ?? nil)?.characterIds ?? []).filter { !cast.contains($0) }
        }
        let more = pool.compactMap { (try? Repo.character($0)) ?? nil }
            .filter { c in !present.contains(c.id) && !back.contains { $0.id == c.id } }
        return back + more
    }

    /// 这个角色在这一场里的身份（按人各存一份；旧的 charAs 只对第一位生效）
    static func castAs(_ scene: Row, _ charId: String) -> (name: String, persona: String)? {
        if let own = scene["castAs"]?[charId]?.object {
            let n = own["name"]?.string ?? "", p = own["persona"]?.string ?? ""
            if !n.isEmpty || !p.isEmpty { return (n, p) }
        }
        if charId == scene.strings("castIds").first, let o = scene["charAs"]?.object {
            let n = o["name"]?.string ?? "", p = o["persona"]?.string ?? ""
            if !n.isEmpty || !p.isEmpty { return (n, p) }
        }
        return nil
    }

    static func nameIn(_ scene: Row, _ c: Character) -> String {
        let n = castAs(scene, c.id)?.name ?? ""
        return n.isEmpty ? c.name : n
    }

    @discardableResult
    static func leave(_ sceneId: String, _ charId: String) throws -> Row? {
        guard let row = get(sceneId), row.strings("castIds").contains(charId) else { return nil }
        var left = leftMap(row)
        if let v = left[charId], v != .null { return nil }
        left[charId] = .number(Date().millis)
        return try update(sceneId, ["left": .object(left)])
    }

    @discardableResult
    static func enter(_ sceneId: String, _ charId: String) throws -> Row? {
        guard let row = get(sceneId), ((try? Repo.character(charId)) ?? nil) != nil else { return nil }
        var left = leftMap(row)
        left[charId] = nil
        var cast = row.strings("castIds")
        if !cast.contains(charId) { cast.append(charId) }
        return try update(sceneId, ["castIds": .array(cast.map { .string($0) }), "left": .object(left)])
    }

    /// 这一段里谁来了、谁走了，正文下面一行小字
    static func castLine(_ beat: Row) -> String {
        guard let c = beat["cast"]?.object else { return "" }
        func n(_ id: String) -> String { ((try? Repo.character(id)) ?? nil)?.name ?? "某人" }
        let came = (c["entered"]?.array ?? []).compactMap(\.string).map { "\(n($0))来了" }
        let gone = (c["left"]?.array ?? []).compactMap(\.string).map { "\(n($0))离开了" }
        return (came + gone).joined(separator: "，")
    }

    // MARK: - 正文

    static func beatsOf(_ sceneId: String) -> [Row] {
        let list = (try? Database.shared.all(beats, where: sceneId)) ?? []
        return list.enumerated().sorted { a, b in
            let x = a.element.created ?? 0, y = b.element.created ?? 0
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    static func told(_ sceneId: String) -> [Row] { beatsOf(sceneId).filter { $0.string("role") != DIRECTOR } }

    /// 一段的几个版本。老的行里 swipes 存的是裸字符串，统一收成对象
    static func versions(_ beat: Row) -> [[String: JSONValue]] {
        (beat["swipes"]?.array ?? []).map { v in
            if let t = v.string { return ["text": .string(t), "raw": .string(t), "think": .string(""), "at": .string("")] }
            var o = v.object ?? [:]
            for k in ["text", "raw", "think", "at"] where o[k]?.string == nil { o[k] = .string("") }
            return o
        }
    }

    static func swipeIndex(_ beat: Row) -> Int {
        let n = versions(beat).count
        return max(0, min(n - 1, Int(beat.number("swipeIndex") ?? 0)))
    }

    private static func face(_ v: [String: JSONValue]) -> [String: JSONValue] {
        ["text": v["text"] ?? .string(""), "raw": v["raw"] ?? .string(""), "think": v["think"] ?? .string(""),
         "at": v["at"] ?? .string(""), "trans": v["trans"] ?? .array([])]
    }

    private static func touchScene(_ sceneId: String) { _ = try? update(sceneId, [:]) }

    @discardableResult
    static func addBeat(sceneId: String, role: String, authorId: String = "", text: String, raw: String = "", think: String = "",
                        at: String = "", hold: Bool = false, now: Date = Date()) throws -> Row {
        let one: [String: JSONValue] = ["text": .string(text), "raw": .string(raw), "think": .string(think), "at": .string(at), "trans": .array([])]
        // 同一毫秒写进去的两段按随机 id 排就乱了：比这一场最后一段至少晚一毫秒
        let last = beatsOf(sceneId).last?.created ?? 0
        var f = one
        f["sceneId"] = .string(sceneId); f["role"] = .string(role); f["authorId"] = .string(authorId)
        f["swipes"] = .array([.object(one)]); f["swipeIndex"] = .number(0); f["pinned"] = .bool(false)
        if role == DIRECTOR { f["hold"] = .bool(hold) }
        var row = Row.new(prefix: "bt", f)
        row["createdAt"] = .number(max(now.millis, last + 1))
        try Database.shared.put(beats, row)
        touchScene(sceneId)
        return row
    }

    @discardableResult
    static func updateBeat(_ id: String, _ patch: [String: JSONValue]) throws -> Row? {
        guard var row = try Database.shared.get(beats, id: id) else { return nil }
        for (k, v) in patch { row[k] = v }
        row.touch()
        try Database.shared.put(beats, row)
        touchScene(row.string("sceneId"))
        return row
    }

    /// 添一版，并切到它
    @discardableResult
    static func addSwipe(_ id: String, text: String, raw: String, think: String, at: String) throws -> Row? {
        guard let row = try Database.shared.get(beats, id: id) else { return nil }
        let one: [String: JSONValue] = ["text": .string(text), "raw": .string(raw), "think": .string(think), "at": .string(at), "trans": .array([])]
        let list = versions(row) + [one]
        var patch = face(one)
        patch["swipes"] = .array(list.map { .object($0) })
        patch["swipeIndex"] = .number(Double(list.count - 1))
        return try updateBeat(id, patch)
    }

    @discardableResult
    static func pickSwipe(_ id: String, _ i: Int) throws -> Row? {
        guard let row = try Database.shared.get(beats, id: id) else { return nil }
        let list = versions(row)
        guard !list.isEmpty else { return nil }
        let n = max(0, min(list.count - 1, i))
        var patch = face(list[n])
        patch["swipeIndex"] = .number(Double(n))
        return try updateBeat(id, patch)
    }

    /// 删掉当前这一版。只剩一版时不动
    @discardableResult
    static func dropSwipe(_ id: String) throws -> Row? {
        guard let row = try Database.shared.get(beats, id: id) else { return nil }
        var list = versions(row)
        guard list.count > 1 else { return nil }
        let at = swipeIndex(row)
        list.remove(at: at)
        let n = min(at, list.count - 1)
        var patch = face(list[n])
        patch["swipes"] = .array(list.map { .object($0) })
        patch["swipeIndex"] = .number(Double(n))
        return try updateBeat(id, patch)
    }

    /// 接着这一段往下写。续的是当前这一版
    @discardableResult
    static func appendBeat(_ id: String, text: String, raw: String, at: String) throws -> Row? {
        guard let row = try Database.shared.get(beats, id: id) else { return nil }
        let add = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !add.isEmpty else { return row }
        let merged: [String: JSONValue] = [
            "text": .string("\(row.string("text"))\n\(add)".trimmingCharacters(in: .whitespacesAndNewlines)),
            "raw": .string("\(row.string("raw"))\n\(raw)".trimmingCharacters(in: .whitespacesAndNewlines)),
            "think": .string(row.string("think")),
            "at": .string(row.string("at").isEmpty ? at : row.string("at")),
            "trans": row["trans"] ?? .array([]),
        ]
        var list = versions(row)
        if list.isEmpty { list = [merged] } else {
            let i = swipeIndex(row)
            list[i].merge(merged) { _, n in n }
        }
        var patch = merged
        patch["swipes"] = .array(list.map { .object($0) })
        return try updateBeat(id, patch)
    }

    /// 改写这一段的正文。改的是当前这一版
    @discardableResult
    static func editBeat(_ id: String, _ text: String) throws -> Row? {
        guard let row = try Database.shared.get(beats, id: id) else { return nil }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = versions(row)
        if list.isEmpty { list = [["text": .string(body), "raw": .string(""), "think": .string(""), "at": .string(row.string("at"))]] }
        else { list[swipeIndex(row)]["text"] = .string(body) }
        return try updateBeat(id, ["text": .string(body), "swipes": .array(list.map { .object($0) })])
    }

    static func dropBeat(_ id: String) throws {
        guard let row = try Database.shared.get(beats, id: id) else { return }
        try Database.shared.delete(beats, id: id)
        touchScene(row.string("sceneId"))
    }

    /// 从这一段起往后全删。回到某一段重新分叉时用
    @discardableResult
    static func dropFrom(_ id: String) throws -> Int {
        guard let row = try Database.shared.get(beats, id: id) else { return 0 }
        let list = beatsOf(row.string("sceneId"))
        guard let at = list.firstIndex(where: { $0.id == id }) else { return 0 }
        for b in list[at...] { try Database.shared.delete(beats, id: b.id) }
        touchScene(row.string("sceneId"))
        return list.count - at
    }

    @discardableResult
    static func togglePin(_ id: String) throws -> Bool {
        guard let row = try Database.shared.get(beats, id: id) else { return false }
        try updateBeat(id, ["pinned": .bool(!row.bool("pinned"))])
        return !row.bool("pinned")
    }

    /// 这一场现在几点：最后一段写了时刻就用它，没有就退回开场填的那个
    static func timeOf(_ sceneId: String) -> String {
        for b in beatsOf(sceneId).reversed() where !b.string("at").isEmpty { return b.string("at") }
        return get(sceneId)?.string("at") ?? ""
    }

    // MARK: - 署名

    struct Sign {
        var name = "", place = "", time = "", face = ""
        var mine = false
    }

    static func signOf(_ beat: Row, scene: Row, chat: Chat?, me: Persona?) -> Sign {
        let mine = beat.string("role") == ME
        var out = Sign()
        out.mine = mine
        out.place = beat.string("place").isEmpty ? scene.string("place") : beat.string("place")
        out.time = beat.string("at")
        if mine {
            let asName = scene["meAs"]?["name"]?.string ?? ""
            out.name = asName.isEmpty ? (me?.name ?? "我") : asName
            out.face = ChatFaces.of(chat, key: ChatFaces.me, fallback: me?.avatar ?? "")
        } else if let who = (try? Repo.character(beat.string("authorId"))) ?? nil {
            out.name = nameIn(scene, who)
            out.face = ChatFaces.of(chat, key: who.id, fallback: who.avatar)
        }
        return out
    }

    // MARK: - 线下正文进线上历史（网页版 4.375）

    /// 这段会话里各场的正文，排成消息的样子（kind 为 beat），按时间和线上消息排在一起。场外指示不进
    static func beatsAsMessages(chatId: String) -> [Message] {
        var out: [Message] = []
        for sc in ofChat(chatId) {
            for b in beatsOf(sc.id) where b.string("role") != DIRECTOR {
                let text = b.string("text").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let mine = b.string("role") == ME
                out.append(Message(row: Row(fields: [
                    "id": .string(b.id), "chatId": .string(chatId), "kind": .string("beat"), "status": .string("done"),
                    "sceneId": .string(sc.id), "role": .string(mine ? "user" : "char"),
                    "authorId": .string(mine ? "me" : b.string("authorId")), "content": .string(b.string("text")),
                    "createdAt": .number(b.created ?? 0),
                ])))
            }
        }
        return out
    }

    /// 线下那一段的开头：哪一场、在场的人、在哪、几点
    static func markText(_ sceneId: String, settings s: AppSettings) -> String {
        var lines: [String] = []
        if let row = get(sceneId) {
            let cast = castOf(row).map(\.name)
            if !cast.isEmpty { lines.append("在场：\(cast.joined(separator: "、"))") }
            let title = row.string("title"), place = row.string("place")
            if !title.isEmpty && title != place { lines.append("题：\(title)") }
            if !place.isEmpty { lines.append("地点：\(place)") }
            let t = timeOf(sceneId)
            if !t.isEmpty { lines.append("时刻：\(t)") }
        }
        return Templates.render("skeleton.scene-mark", ["lines": lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")], settings: s)
    }
}
