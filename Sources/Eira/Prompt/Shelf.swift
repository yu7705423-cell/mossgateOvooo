import Foundation

/// 角色的个人书架（网页版 system/shelf.js、ai/tasks/shelf-batch.js、shelf-impression.js），存在角色卡的 shelf 上。
///
/// 书架上的书默认是个占位：只有书名、作者和备注。你自己导入同名的书之后，那一格就接上真书（接的是 bookId，不是书名）。
/// 生成书目、写读后感都是按一下调一次，和聊天无关；生成的书目先列出来勾选再存（网页版第 6 条的例外）。
enum Shelf {
    struct Item: Identifiable, Equatable {
        var raw: [String: JSONValue]
        var id: String { raw["id"]?.string ?? "" }
        var title: String { raw["title"]?.string ?? "" }
        var author: String { raw["author"]?.string ?? "" }
        var note: String { raw["note"]?.string ?? "" }
        var impression: String { raw["impression"]?.string ?? "" }
        var impressionTrans: String { raw["impressionTrans"]?.string ?? "" }
        var bookId: String { raw["bookId"]?.string ?? "" }
        var book: Books.Book? { Books.get(bookId) }
    }

    static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"[《》「」【】\s]"#, with: "", options: .regularExpression)
    }

    private static func raw(_ charId: String) -> [[String: JSONValue]] {
        (((try? Repo.character(charId)) ?? nil)?.row["shelf"]?.array ?? []).compactMap(\.object)
    }

    static func list(_ charId: String) -> [Item] { raw(charId).map(Item.init(raw:)) }

    private static func write(_ charId: String, _ next: [[String: JSONValue]]) throws {
        guard var row = try Database.shared.get(Collections.characters, id: charId) else { throw StoreError(message: "角色不存在") }
        row["shelf"] = .array(next.map { .object($0) })
        row.touch()
        try Database.shared.put(Collections.characters, row)
    }

    static func has(_ charId: String, _ title: String) -> Bool { raw(charId).contains { norm($0["title"]?.string ?? "") == norm(title) } }

    @discardableResult
    static func add(_ charId: String, title: String, author: String = "", note: String = "") throws -> Item {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError(message: "请填写书名") }
        var all = raw(charId)
        guard !all.contains(where: { norm($0["title"]?.string ?? "") == norm(name) }) else { throw StoreError(message: "书架上已经有这一本了") }
        var item: [String: JSONValue] = [
            "id": .string(Ids.make("shf")), "title": .string(name), "author": .string(author), "coverUrl": .string(""),
            "cover": .null, "note": .string(note), "bookId": .null,
        ]
        // 库里已经有同名的书就直接接上
        if let hit = Books.all().first(where: { norm($0.title) == norm(name) }) { item["bookId"] = .string(hit.id) }
        all.append(item)
        try write(charId, all)
        return Item(raw: item)
    }

    static func setEntry(_ charId: String, _ entryId: String, _ patch: [String: JSONValue]) throws {
        try write(charId, raw(charId).map { it in
            guard it["id"]?.string == entryId else { return it }
            var x = it
            for (k, v) in patch { x[k] = v }
            return x
        })
    }

    /// 从书架上拿下来。这一格的封面图留着（原生版不自己删图，要先核引用）
    static func remove(_ charId: String, _ entryId: String) throws {
        try write(charId, raw(charId).filter { $0["id"]?.string != entryId })
    }

    /// 手动接上某一本真书，或者断开
    static func link(_ charId: String, _ entryId: String, bookId: String?) throws {
        try setEntry(charId, entryId, ["bookId": bookId.map { JSONValue.string($0) } ?? .null])
    }

    /// 刚导入一本书，把各个角色书架上同名的占位接上
    @discardableResult
    static func linkImported(_ bookId: String) throws -> Int {
        guard let b = Books.get(bookId) else { return 0 }
        var n = 0
        for c in try Repo.characters() {
            let list = (c.row["shelf"]?.array ?? []).compactMap(\.object)
            guard !list.isEmpty else { continue }
            var dirty = false
            let next = list.map { it -> [String: JSONValue] in
                guard (it["bookId"]?.string ?? "").isEmpty, norm(it["title"]?.string ?? "") == norm(b.title) else { return it }
                dirty = true; n += 1
                var x = it; x["bookId"] = .string(bookId); return x
            }
            if dirty { try write(c.id, next) }
        }
        return n
    }

    /// 一本书被删掉了，接着它的那几格退回占位
    static func unlinkBook(_ bookId: String) throws {
        for c in try Repo.characters() {
            let list = (c.row["shelf"]?.array ?? []).compactMap(\.object)
            guard list.contains(where: { $0["bookId"]?.string == bookId }) else { continue }
            try write(c.id, list.map { it in
                guard it["bookId"]?.string == bookId else { return it }
                var x = it; x["bookId"] = .null; return x
            })
        }
    }

    /// 哪些角色有书架
    static func withShelf() -> [(char: Character, count: Int)] {
        ((try? Repo.characters()) ?? []).compactMap { c in
            let n = c.row["shelf"]?.array?.count ?? 0
            return n > 0 ? (char: c, count: n) : nil
        }
    }

    // MARK: - 生成书目（一次调用一批，数目自己填）

    static let kinds: [(id: String, label: String, line: String)] = [
        ("real", "现实中存在的书", "Only books that actually exist. Do not invent titles."),
        ("any", "不限", "Books that exist and books that exist only in this character's "
            + "world both qualify. Take which is appropriate from the settings above."),
    ]

    struct Suggestion: Identifiable, Equatable {
        var id: String { title }
        var title: String
        var author: String
        var note: String
    }

    static func generate(_ charId: String, count: Int = 8, kind: String = "real") async throws -> [Suggestion] {
        guard let char = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        let n = max(1, count)
        let have = list(charId)
        let system = Templates.render("task.shelf-batch", [
            "charName": char.name, "charPersona": ParaNotes.persona(char), "count": "\(n)",
            "kindLine": (kinds.first { $0.id == kind } ?? kinds[0]).line,
            "existing": have.isEmpty ? "（书架还是空的）" : have.map { "- \($0.title)" }.joined(separator: "\n"),
        ], settings: .load())
        let r = try await AIService.shared.send(task: "shelf.batch", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: 300 + n * 60)
        guard let j = JSONReply.parse(r.text) else { throw StoreError(message: JSONReply.failure(r.text)) }
        var seen = Set<String>()
        return (j["books"]?.array ?? []).compactMap { x -> Suggestion? in
            func str(_ v: JSONValue?) -> String { (v?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let b = x.string != nil ? Suggestion(title: str(x), author: "", note: "")
                : Suggestion(title: str(x["title"]), author: str(x["author"]), note: str(x["note"]))
            let key = norm(b.title)
            guard !key.isEmpty, !seen.contains(key), !has(charId, b.title) else { return nil }
            seen.insert(key)
            return b
        }
    }

    /// 勾选之后一并放上书架，重名的跳过
    @discardableResult
    static func keep(_ charId: String, _ rows: [Suggestion]) -> Int {
        rows.reduce(0) { n, b in (try? add(charId, title: b.title, author: b.author, note: b.note)) == nil ? n : n + 1 }
    }

    // MARK: - 读后感（一本一次调用）

    static func impression(_ charId: String, entryId: String) async throws -> String {
        guard let char = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        guard let item = list(charId).first(where: { $0.id == entryId }) else { throw StoreError(message: "这一本已经不在书架上了") }
        let s = AppSettings.load()
        let system = Templates.render("task.impression", [
            "charName": char.name, "title": item.title, "authorLine": item.author.isEmpty ? "" : "（\(item.author)）",
            "charPersona": ParaNotes.persona(char),
        ], settings: s) + ParaNotes.textPart(GenTrans.forChar(charId), s)
        let r = try await AIService.shared.send(task: "shelf.impression", system: system,
                                                messages: [AIMessage(role: .user, content: "Write it now.")], maxTokens: 400)
        let text = ReplyParser.stripThink(r.text).0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StoreError(message: "模型没有写出内容") }
        return text
    }

    static func saveImpression(_ charId: String, entryId: String, _ text: String) throws {
        let (body, trans) = ParaNotes.splitText(GenTrans.forChar(charId), text)
        try setEntry(charId, entryId, ["impression": .string(body), "impressionTrans": .string(trans), "impressionAt": .number(Date().millis)])
    }
}
