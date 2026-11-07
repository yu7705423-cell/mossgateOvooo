import Foundation

/// 看完、读完之后角色写的那一篇（网页版 system/review.js）。每写一篇存一篇，不覆盖。
/// 一篇一次调用：手动点才写；收场时自动写要自己开（reviewAuto，默认关，登记在 ExtraCalls）。
enum Reviews {
    static let collection = "reviews"

    enum Kind: String, Sendable { case video, book }

    struct Review: Identifiable, Equatable, Sendable {
        var row: Row
        var id: String { row.id }
        var kind: String { row.string("kind") }
        var subjectId: String { row.string("subjectId") }
        var charId: String { row.string("charId") }
        var at: Double { row.number("at") ?? 0 }
        var title: String { row.string("title") }
        var text: String { row.string("text") }
        var createdAt: Double { row.created ?? 0 }
    }

    static func all() -> [Review] { ((try? Database.shared.all(collection)) ?? []).map(Review.init(row:)) }

    static func list(_ kind: Kind, _ subjectId: String) -> [Review] {
        all().filter { $0.kind == kind.rawValue && $0.subjectId == subjectId }.sorted { $0.createdAt > $1.createdAt }
    }

    static func count(_ kind: Kind, _ subjectId: String) -> Int { list(kind, subjectId).count }

    static func remove(_ id: String) throws { try Database.shared.delete(collection, id: id) }

    /// 角色看到 / 读到的那部分（网页版 seenOf）。没有这一段，写出来的只能是泛泛之谈
    static func seen(_ kind: Kind, subjectId: String, at: Double) -> String {
        if kind == .book {
            guard let row = Books.get(subjectId) else { return "" }
            let text = Books.text(subjectId)
            guard text.length > 0 else { return "You have no text from this book at hand." }
            let upto = min(text.length, at > 0 ? Int(at) : row.chars)
            let tail = text.substring(with: NSRange(location: max(0, upto - 2000), length: upto - max(0, upto - 2000)))
            return "You read up to \(Books.percent(row, at: upto))% of the book.\nThe last part you read:\n\(tail)"
        }
        let row = VideoLib.get(subjectId)
        let lines = VideoLib.lines(row)
        guard !lines.isEmpty else {
            return "This film has no subtitles. You only know how far it played: \(Subtitle.stamp(at))."
        }
        let said = Array(lines.filter { $0.at <= at }.suffix(60)).map(\.text)
        let outline = VideoLib.outlineSoFar(row, at).map(\.text)
        return [
            "You watched up to \(Subtitle.stamp(at)).",
            outline.isEmpty ? "" : "\nWhat happened:\n" + outline.joined(separator: "\n"),
            said.isEmpty ? "" : "\nThe last lines you heard:\n" + said.joined(separator: "\n"),
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 让某个角色为这一部写一篇。一次接口调用
    @discardableResult
    static func write(_ kind: Kind, subjectId: String, charId: String, at: Double = 0) async throws -> Review {
        guard let char = try Repo.character(charId) else { throw StoreError(message: "这个角色已经不在了") }
        let title: String
        if kind == .book {
            guard let b = Books.get(subjectId) else { throw StoreError(message: "这本书已经不在了") }
            title = b.title
        } else {
            guard let v = VideoLib.get(subjectId) else { throw StoreError(message: "这部片子已经不在了") }
            title = v.title
        }
        let s = AppSettings.load()
        let me = (try? Repo.activePersona(s)) ?? nil
        let system = Templates.render("task.review", [
            "charName": char.name,
            "userName": me?.name ?? "对方",
            "title": title,
            "verb": kind == .book ? "reading" : "watching",
            "seen": seen(kind, subjectId: subjectId, at: at),
        ], settings: s)
        let r = try await AIService.shared.send(task: "review.write", system: system,
                                                messages: [AIMessage(role: .user, content: "Write it now.")], maxTokens: 900)
        let text = ReplyParser.stripThink(r.text).0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StoreError(message: "模型没有写出内容") }
        let row = Row.new(prefix: "rev", [
            "kind": .string(kind.rawValue), "subjectId": .string(subjectId), "charId": .string(charId),
            "at": .number(at), "title": .string(title), "text": .string(text),
        ])
        try Database.shared.put(collection, row)
        return Review(row: row)
    }

    /// 收场时要不要自动写一篇。默认关着
    static func autoOn(_ s: AppSettings = .load()) -> Bool { s.raw["reviewAuto"]?.bool == true }

    static func writeOnFinish(kind: Kind, subjectId: String, charId: String, at: Double) async {
        guard autoOn(), !charId.isEmpty, !subjectId.isEmpty else { return }
        do { try await write(kind, subjectId: subjectId, charId: charId, at: at) }
        catch { Diagnostics.shared.record("review-auto-failed", ["error": error.localizedDescription]) }
    }
}

/// 书摘小卡片（网页版 system/excerpt.js）：摘一段，写一句自己的话，发到某个角色的会话里。不调接口
enum Excerpt {
    static func text(title: String, quote: String, note: String) -> String {
        ["[书摘：《\(title)》]", "「\(quote)」", note].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    @discardableResult
    static func send(chatId: String, bookId: String, quote: String, note: String = "", at: Int = 0) throws -> Message {
        guard var chat = try Repo.chat(chatId) else { throw StoreError(message: "会话不存在") }
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw StoreError(message: "请先写下要摘的那一段") }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = Books.get(bookId)
        let title = row?.title ?? "一本书"
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: text(title: title, quote: q, note: n), kind: "excerpt")
        m.row["bookId"] = .string(bookId)
        m.row["bookTitle"] = .string(title)
        m.row["bookAuthor"] = .string(row?.author ?? "")
        m.row["quote"] = .string(q)
        m.row["note"] = .string(n)
        m.row["at"] = .number(Double(at))
        m = try Repo.append(m)
        chat.row["lastMessageAt"] = .number(Date().millis)
        chat.row.touch()
        try Repo.save(chat)
        NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
        return m
    }

    /// 能发给谁：一对一的会话，最近聊过的在前
    static func targets() -> [Chat] {
        ((try? Repo.chats()) ?? []).filter { $0.characterIds.count == 1 && !$0.isGroup }.sorted { $0.lastMessageAt > $1.lastMessageAt }
    }
}
