import Foundation

/// 朋友圈（网页版 db.moments、system/ai/tasks/moments.js、context/moments.js）。
///
/// 一条动态：authorId（'me' 或角色 id）、text、images、likes（谁点了赞）、comments（{id, authorId, text, replyTo, createdAt}）、
/// visibleTo（我发的才有：'all' 或没有这一项为所有角色可见，[id…] 为这几位，[] 为仅自己）、recalled（角色撤回了）。
///
/// 接口只在用户点了才调：刷新（随机一位角色写一条）、请某位角色评论、评论角色的动态时它回一句、
/// 发布时看得见的角色各写一条评论（发布页上写明共几次）。没有定时、没有每 N 次（网页版第 15、22 条）。
enum Moments {
    static let collection = "moments"

    struct Comment: Identifiable, Equatable, Sendable {
        var id: String
        var authorId: String
        var text: String
        var replyTo: String
        var createdAt: Double

        init(_ v: JSONValue) {
            let o = v.object ?? [:]
            id = o["id"]?.string ?? ""
            authorId = o["authorId"]?.string ?? ""
            text = o["text"]?.string ?? ""
            replyTo = o["replyTo"]?.string ?? ""
            createdAt = o["createdAt"]?.number ?? 0
        }
    }

    struct Moment: Identifiable, Equatable, Sendable {
        var row: Row
        var id: String { row.id }
        var authorId: String { row.string("authorId") }
        var text: String { row.string("text") }
        var images: [String] { row.strings("images") }
        var likes: [String] { row.strings("likes") }
        var comments: [Comment] { (row["comments"]?.array ?? []).map(Comment.init) }
        var createdAt: Double { row.number("createdAt") ?? row.created ?? 0 }
        var recalled: Bool { row["recalled"].map { $0 != .null && $0 != .bool(false) } ?? false }
        var editedAt: Double { row.number("editedAt") ?? 0 }
        var isMine: Bool { authorId == "me" }
        /// 我发的那条的可见范围：nil 为所有角色，其余为这几位（空为仅自己）
        var visibleTo: [String]? { row["visibleTo"]?.array.map { $0.compactMap(\.string) } }
    }

    // MARK: - 读写

    static func all() -> [Moment] {
        ((try? Database.shared.all(collection)) ?? []).map(Moment.init(row:)).sorted { $0.createdAt > $1.createdAt }
    }

    static func get(_ id: String) -> Moment? {
        (try? Database.shared.get(collection, id: id)).flatMap { $0 }.map(Moment.init(row:))
    }

    static func by(_ authorId: String) -> [Moment] { all().filter { $0.authorId == authorId } }

    @discardableResult
    static func create(authorId: String, text: String, images: [String] = [], visibleTo: [String]? = nil,
                       extra: [String: JSONValue] = [:]) throws -> Moment {
        var fields: [String: JSONValue] = [
            "authorId": .string(authorId), "text": .string(text),
            "images": .array(images.map(JSONValue.string)), "likes": .array([]), "comments": .array([]),
            "createdAt": .number(Date().millis),
        ]
        if let visibleTo { fields["visibleTo"] = .array(visibleTo.map(JSONValue.string)) }
        for (k, v) in extra { fields[k] = v }
        let row = Row.new(prefix: "mo", fields)
        try Database.shared.put(collection, row)
        changed()
        return Moment(row: row)
    }

    static func update(_ id: String, _ patch: [String: JSONValue]) throws {
        guard var row = try Database.shared.get(collection, id: id) else { return }
        for (k, v) in patch { row[k] = v }
        row.touch()
        try Database.shared.put(collection, row)
        changed()
    }

    /// 删一条动态。图片不跟着删：同一张图可能还挂在别处（网页版第 20 条，删图先核引用）
    static func remove(_ id: String) throws {
        try Database.shared.delete(collection, id: id)
        changed()
    }

    static func toggleLike(_ id: String, who: String = "me") throws {
        guard let mo = get(id) else { return }
        let likes = mo.likes.contains(who) ? mo.likes.filter { $0 != who } : mo.likes + [who]
        try update(id, ["likes": .array(likes.map(JSONValue.string))])
    }

    @discardableResult
    static func addComment(_ id: String, authorId: String, text: String, replyTo: String = "") throws -> Comment? {
        guard let mo = get(id) else { return nil }
        var c: [String: JSONValue] = [
            "id": .string(Ids.make("cm")), "authorId": .string(authorId), "text": .string(text),
            "replyTo": replyTo.isEmpty ? .null : .string(replyTo), "createdAt": .number(Date().millis),
        ]
        if replyTo.isEmpty { c["replyTo"] = .null }
        try update(id, ["comments": .array((mo.row["comments"]?.array ?? []) + [.object(c)])])
        return Comment(.object(c))
    }

    /// 删一条评论。回复它的那几条留着，显示时不再写「回复谁」
    static func removeComment(_ id: String, commentId: String) throws {
        guard let mo = get(id) else { return }
        try update(id, ["comments": .array((mo.row["comments"]?.array ?? []).filter { $0.object?["id"]?.string != commentId })])
    }

    /// 改我自己那条的文字。记下改过的时刻，界面上写「已编辑」
    static func edit(_ id: String, text: String) throws {
        guard let mo = get(id), mo.isMine else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !mo.images.isEmpty else { throw StoreError(message: "动态不能为空") }
        guard t != mo.text else { return }
        try update(id, ["text": .string(t), "editedAt": .number(Date().millis), "translation": .string("")])
    }

    static func changed() {
        NotificationCenter.default.post(name: .eiraMomentsChanged, object: nil)
    }

    // MARK: - 谁看得见

    static func canSee(_ mo: Moment, _ charId: String) -> Bool {
        guard mo.isMine, let v = mo.visibleTo else { return true }
        return v.contains(charId)
    }

    /// 发布时看得见的那几位（封存的不来，网页版 viewersOf）
    static func viewers(visibleTo: [String]?) -> [Character] {
        ((try? Repo.characters()) ?? []).filter { !$0.archived && !$0.row.bool("isNpc") && (visibleTo == nil || visibleTo!.contains($0.id)) }
    }

    // MARK: - 角色写动态、评论、回复（网页版 tasks/moments.js）

    private static func userName() -> String {
        (try? Repo.activePersona())?.name ?? "the user"
    }

    /// 人设加最近的 S、A 级记忆（最多十二条）
    private static func charContext(_ c: Character) -> String {
        let mems = ((try? Database.shared.all(Collections.memories, where: c.id)) ?? [])
            .map(Memory.init(row:))
            .filter { $0.rank == "S" || $0.rank == "A" }
            .sorted { ($0.row.number("createdAt") ?? 0) > ($1.row.number("createdAt") ?? 0) }
            .prefix(12)
            .map { "- \($0.content)" }
            .joined(separator: "\n")
        return [c.persona, mems.isEmpty ? "" : "What you remember lately:\n\(mems)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// 与对方私聊的最近几条（「用量与上限」的 momentChatRecent，0 为全部）
    private static func recentChat(_ charId: String, _ user: String) -> String {
        guard let chat = Diary.chatWith(charId) else { return "" }
        let n = max(0, Int(AppSettings.load().num("momentChatRecent", 20)))
        let rows = ((try? Repo.messages(chatId: chat.id)) ?? []).filter {
            !$0.content.isEmpty && !$0.isError && $0.kind != "typing" && $0.kind != "notice" && !$0.isRecalled
        }
        let lines = (n > 0 ? Array(rows.suffix(n)) : rows).map { m in
            "\(m.role == .user ? user : "you"): \(String(m.content.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(300)))"
        }
        return lines.isEmpty ? "" : "\n\n## Your recent private conversation with \(user), oldest first\n\(lines.joined(separator: "\n"))"
    }

    private static func nameOf(_ id: String, charId: String, user: String) -> String {
        if id == "me" { return user }
        if id == charId { return "you" }
        return (try? Repo.character(id))?.name ?? "someone"
    }

    /// 这条动态下已有的整串评论
    private static func thread(_ mo: Moment, charId: String, user: String) -> String {
        let byId = Dictionary(mo.comments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let lines = mo.comments.sorted { $0.createdAt < $1.createdAt }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { c -> String in
                let who: String
                if let to = byId[c.replyTo] {
                    who = "\(nameOf(c.authorId, charId: charId, user: user)) replying to \(nameOf(to.authorId, charId: charId, user: user))"
                } else {
                    who = nameOf(c.authorId, charId: charId, user: user)
                }
                return "\(who): \(c.text.trimmingCharacters(in: .whitespaces))"
            }
        return lines.isEmpty ? "" : "\n\n## Comments under this post so far, oldest first\n\(lines.joined(separator: "\n"))"
    }

    private static func runJSON(_ task: String, _ system: String, maxTokens: Int) async throws -> JSONValue {
        let r = try await AIService.shared.send(task: task, system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: maxTokens, retries: 1)
        guard let j = JSONReply.parse(r.text), j.object != nil else { throw StoreError(message: JSONReply.failure(r.text)) }
        return j
    }

    /// 角色发一条动态（朋友圈页右上角「刷新」，一次调用）
    @discardableResult
    static func createMoment(charId: String) async throws -> Moment {
        guard let c = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        let s = AppSettings.load()
        let user = userName()
        let system = Templates.render("task.moment-create", ["charName": c.name], settings: s)
            + "\n\n## Your own settings\n\(charContext(c))" + recentChat(charId, user)
        let j = try await runJSON("moment.create", system, maxTokens: 500)
        let text = (j["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StoreError(message: "模型没有返回动态内容") }
        var extra: [String: JSONValue] = ["mood": .string(j["mood"]?.string ?? "")]
        let prompt = (j["imagePrompt"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty && prompt != "null" { extra["imagePrompt"] = .string(prompt) }
        return try create(authorId: charId, text: text, extra: extra)
    }

    /// 角色评论一条动态，并点赞（一次调用）
    static func comment(momentId: String, charId: String) async throws {
        guard let mo = get(momentId), let c = try Repo.character(charId) else { throw StoreError(message: "数据不存在") }
        let user = userName()
        let author = mo.isMine ? user : ((try? Repo.character(mo.authorId))?.name ?? "对方")
        let system = Templates.render("task.moment-comment",
                                      ["charName": c.name, "authorName": author, "momentText": mo.text], settings: .load())
            + "\n\n## Your own settings\n\(charContext(c))" + thread(mo, charId: charId, user: user) + recentChat(charId, user)
        let j = try await runJSON("moment.comment", system, maxTokens: 300)
        let text = (j["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StoreError(message: "模型没有返回评论") }
        try addComment(momentId, authorId: charId, text: text)
        if get(momentId)?.likes.contains(charId) == false { try toggleLike(momentId, who: charId) }
    }

    /// 我发布之后：看得见的角色逐个来写评论。一位一次调用；一位失败不拦着后面的
    static func reactToMine(_ momentId: String) async -> (done: Int, failed: [String]) {
        guard let mo = get(momentId), mo.isMine else { return (0, []) }
        var done = 0
        var failed: [String] = []
        for c in viewers(visibleTo: mo.visibleTo) {
            guard get(momentId) != nil else { break }
            do { try await comment(momentId: momentId, charId: c.id); done += 1 }
            catch { failed.append("\(c.displayName)：\(error.localizedDescription)") }
        }
        return (done, failed)
    }

    /// 我写一条评论。回复的是角色的评论就叫那个角色回一句；否则动态作者是角色时叫作者。没配接口时谁都不叫
    static func send(comment text: String, on momentId: String, replyTo: String = "") async throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let mo = get(momentId) else { return }
        let to = mo.comments.first { $0.id == replyTo }
        let mine = try addComment(momentId, authorId: "me", text: t, replyTo: to?.id ?? "")
        let who = to.map { $0.authorId != "me" ? $0.authorId : "" } ?? (mo.isMine ? "" : mo.authorId)
        guard !who.isEmpty, (try? Repo.character(who)) != nil, AppSettings.load().mainPreset != nil else { return }
        try await reply(momentId: momentId, charId: who, commentText: t, replyTo: mine?.id ?? "")
    }

    /// 角色回我一条评论（一次调用）。角色是作者时可以顺带撤回这条动态（网页版 recall）
    static func reply(momentId: String, charId: String, commentText: String, replyTo: String) async throws {
        guard let mo = get(momentId), let c = try Repo.character(charId) else { throw StoreError(message: "数据不存在") }
        let s = AppSettings.load()
        let user = userName()
        let own = mo.authorId == charId
        let canTake = own && c.row["canRecall"]?.bool != false && !mo.recalled
        let system: String
        if own {
            system = Templates.render("task.moment-reply", ["charName": c.name, "userName": user, "momentText": mo.text,
                                                            "commentText": commentText], settings: s)
                + (canTake ? "\n\n" + Templates.render("task.moment-recall", [:], settings: s) : "")
        } else {
            let author = mo.isMine ? user : ((try? Repo.character(mo.authorId))?.name ?? "someone")
            system = Templates.render("task.moment-reply-thread", ["charName": c.name, "userName": user, "authorName": author,
                                                                   "momentText": mo.text, "commentText": commentText], settings: s)
        }
        let full = system + "\n\n## Your own settings\n\(charContext(c))" + thread(mo, charId: charId, user: user) + recentChat(charId, user)
        let j = try await runJSON("moment.reply", full, maxTokens: 300)
        let text = (j["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StoreError(message: "模型没有返回回复") }
        try addComment(momentId, authorId: charId, text: text, replyTo: replyTo)
        if canTake && j["recall"]?.bool == true { try update(momentId, ["recalled": .number(Date().millis)]) }
    }

    // MARK: - 聊天时角色读到的（网页版 context/moments.js，区块 moments）

    /// 今天 14:30 / 昨天 09:00 / 2026-01-01 08:00（网页版 when.show）
    static func show(_ ms: Double, now: Date = Date()) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let day = days == 0 ? "今天" : days == 1 ? "明天" : days == 2 ? "后天" : days == -1 ? "昨天" : f.string(from: d)
        f.dateFormat = "HH:mm"
        return "\(day) \(f.string(from: d))"
    }

    static func block(char: Character, userName: String, now: Date = Date()) -> String {
        let s = AppSettings.load()
        let list = all()
        return mineBlock(list, char: char, who: userName, n: Int(s.num("momentsCount", 3)), now: now)
            + ownBlock(list, char: char, userName: userName, n: Int(s.num("ownMomentsCount", 3)), now: now)
    }

    private static func head(_ m: Moment, now: Date) -> [String] {
        var parts = ["\(show(m.createdAt, now: now))　\(m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "（没有文字）" : m.text.trimmingCharacters(in: .whitespacesAndNewlines))"]
        if !m.images.isEmpty { parts.append("[图片 \(m.images.count) 张]") }
        return parts
    }

    private static func mineBlock(_ list: [Moment], char: Character, who: String, n: Int, now: Date) -> String {
        let rows = list.filter { $0.isMine && canSee($0, char.id) }
        let picked = n > 0 ? Array(rows.prefix(n)) : rows
        guard !picked.isEmpty else { return "" }
        let lines = picked.map { m -> String in
            var parts = head(m, now: now)
            if m.likes.contains(char.id) { parts.append("[你已点赞]") }
            let mine = m.comments.filter { $0.authorId == char.id }.map(\.text).filter { !$0.isEmpty }
            if !mine.isEmpty { parts.append("[你的评论：\(mine.joined(separator: " / "))]") }
            let others = m.comments.filter { $0.authorId != "me" && $0.authorId != char.id }
                .map { "\((try? Repo.character($0.authorId))?.name ?? "某人")：\($0.text)" }
            if !others.isEmpty { parts.append("[其他人的评论：\(others.joined(separator: " / "))]") }
            return parts.joined(separator: " ")
        }
        return "\n\n[对方的朋友圈]\n\(lines.joined(separator: "\n"))\n"
            + "These are the most recent posts \(who) published on their moments feed, newest first, "
            + "with the time, the text, how many photos were attached, and whether you have liked or commented.\n"
    }

    private static func ownBlock(_ list: [Moment], char: Character, userName: String, n: Int, now: Date) -> String {
        let rows = list.filter { $0.authorId == char.id && !$0.recalled }
        let picked = n > 0 ? Array(rows.prefix(n)) : rows
        guard !picked.isEmpty else { return "" }
        func name(_ id: String) -> String {
            id == "me" ? userName : id == char.id ? "你" : ((try? Repo.character(id))?.name ?? "某人")
        }
        let lines = picked.map { m -> String in
            var parts = head(m, now: now)
            if m.likes.contains("me") { parts.append("[\(userName)已点赞]") }
            let byId = Dictionary(m.comments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let thread = m.comments.sorted { $0.createdAt < $1.createdAt }
                .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { c in "\(name(c.authorId))\(byId[c.replyTo].map { "回复\(name($0.authorId))" } ?? "")：\(c.text.trimmingCharacters(in: .whitespaces))" }
            if !thread.isEmpty { parts.append("[评论：\(thread.joined(separator: " / "))]") }
            return parts.joined(separator: " ")
        }
        return "\n\n[你的朋友圈]\n\(lines.joined(separator: "\n"))\n"
            + "These are the most recent posts you published on your own moments feed, newest first, with the time, the text, "
            + "how many photos were attached, whether \(userName) liked it, and every comment under it in order with who wrote it.\n"
    }
}

extension Notification.Name {
    static let eiraMomentsChanged = Notification.Name("eira.momentsChanged")
}
