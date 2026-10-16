import Foundation

/// 记忆与世界书的增删改。字段与默认值照网页版「设定集」的记忆页与世界书页（apps/preset/memory、apps/preset/lore）。
enum Knowledge {
    // MARK: - 记忆

    static let categories: [(String, String)] = [
        ("fact", "事实"), ("emotion", "情绪"), ("pending", "待办"), ("pattern", "模式"),
        ("relation", "关系"), ("profile", "画像"), ("event", "事件"),
    ]

    /// 这个角色在当前身份下看得到的记忆：身份按根账号隔离，没写身份的算大号的（网页版 context/memory.js 的 listFor）。
    static func memories(charId: String, personaId: String) throws -> [Memory] {
        let personas = try Repo.personas()
        let root = Repo.rootId(of: personaId, in: personas)
        return try Repo.memories(charId: charId)
            .filter { $0.personaId.isEmpty || Repo.rootId(of: $0.personaId, in: personas) == root }
            .sorted { $0.at > $1.at }
    }

    /// 手动新建。默认值照网页版：事实、B 级、手动来源。
    static func newMemory(charId: String, personaId: String) -> Memory {
        Memory(row: .new(prefix: "mem", [
            "charId": .string(charId), "personaId": .string(personaId), "content": .string(""),
            "kind": .string("fact"), "category": .string("fact"), "rank": .string("B"),
            "keywords": .array([]), "source": .string("manual"), "at": .number(Date().millis),
        ]))
    }

    /// 改种类时顺带改的字段：改成进行中带上状态与「待办」分类；从进行中改成事件，分类换回事件。
    static func kindPatch(_ m: Memory, to kind: Memory.Kind) -> [String: JSONValue] {
        var p: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        if kind == .open {
            p["category"] = .string("pending")
            if m.row.string("status").isEmpty { p["status"] = .string("open") }
        } else if kind == .event && m.row.string("category") == "pending" {
            p["category"] = .string("event")
        } else if kind == .fact && m.row.string("category") == "pending" {
            p["category"] = .string("fact")
        }
        return p
    }

    /// 「一直记着」与「不要主动提起」只能开一个。
    static func pinPatch(pinned: Bool) -> [String: JSONValue] {
        pinned ? ["pinned": .bool(true), "taboo": .bool(false)] : ["pinned": .bool(false)]
    }
    static func tabooPatch(taboo: Bool) -> [String: JSONValue] {
        taboo ? ["taboo": .bool(true), "pinned": .bool(false)] : ["taboo": .bool(false)]
    }

    @discardableResult
    static func save(_ m: Memory, _ fields: [String: JSONValue] = [:]) throws -> Memory {
        var row = m.row
        for (k, v) in fields { row[k] = v }
        row.touch()
        try Database.shared.put(Collections.memories, row)
        return Memory(row: row)
    }

    /// 批量处理几件进行中的事（网页版 4.534）：了结（done）或改为事件（event）。群聊里同一件事的几份（twin）一起改
    @discardableResult
    static func settle(_ ids: [String], as action: String) throws -> Int {
        let rows = try Database.shared.all(Collections.memories)
        let picked = rows.filter { ids.contains($0.id) }
        let twins = Set(picked.map { $0.string("twin") }.filter { !$0.isEmpty })
        let targets = rows.filter { ($0.string("kind") == "open")
            && (ids.contains($0.id) || (!$0.string("twin").isEmpty && twins.contains($0.string("twin")))) }
        let now = Date().millis
        for r in targets {
            var row = r
            if action == "event" {
                row["kind"] = .string("event"); row["category"] = .string("event"); row["status"] = .string(""); row["dueAt"] = .string("")
            } else {
                row["status"] = .string("done"); row["doneAt"] = .number(now)
            }
            row.touch()
            try Database.shared.put(Collections.memories, row)
        }
        return targets.count
    }

    static func deleteMemory(_ id: String) throws {
        try Database.shared.delete(Collections.memories, id: id)
    }

    /// 关键词按「、 , ， ; ；」切开（网页版 lorefile.js 的 list）。
    static func splitList(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: "、,，;；"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - 世界书

    static func createBook(name: String) throws -> Lorebook {
        let row = Row.new(prefix: "lb", ["name": .string(name), "description": .string(""), "global": .bool(false), "entries": .array([])])
        try Database.shared.put(Collections.lorebooks, row)
        return Lorebook(row: row)
    }

    static func book(_ id: String) throws -> Lorebook? {
        try Database.shared.get(Collections.lorebooks, id: id).map(Lorebook.init(row:))
    }

    @discardableResult
    static func updateBook(_ id: String, _ fields: [String: JSONValue]) throws -> Lorebook {
        guard var row = try Database.shared.get(Collections.lorebooks, id: id) else { throw StoreError(message: "这本世界书不存在") }
        for (k, v) in fields { row[k] = v }
        row.touch()
        try Database.shared.put(Collections.lorebooks, row)
        return Lorebook(row: row)
    }

    /// 删一本书，并从各个角色的 lorebookIds 里摘掉它。
    static func deleteBook(_ id: String) throws {
        for c in try Repo.characters() where c.lorebookIds.contains(id) {
            _ = try People.update(c, ["lorebookIds": .array(c.lorebookIds.filter { $0 != id }.map { .string($0) })])
        }
        try Database.shared.delete(Collections.lorebooks, id: id)
    }

    /// 新条目，默认值照网页版 blankEntry。
    /// card：新建一张 HTML 卡片（网页版 lorefile 的 card 默认值），不作为设定注入
    static func addEntry(bookId: String, card: Bool = false) throws -> String {
        let id = Ids.make("e")
        var o: [String: JSONValue] = [
            "id": .string(id), "comment": .string(""), "keys": .array([]), "secondaryKeys": .array([]), "content": .string(""),
            "enabled": .bool(true), "constant": .bool(false), "priority": .number(100), "order": .number(0),
            "part": .string("before"), "depth": .number(0), "caseSensitive": .bool(false), "probability": .number(100),
        ]
        if card {
            o["type"] = .string("card")
            o["card"] = .object(["html": .string(""), "fields": .object([:]), "width": .string("bubble"), "ratio": .string("4:3"),
                                 "images": .bool(false), "sampleText": .string("")])
        }
        let entry: JSONValue = .object(o)
        try mutateEntries(bookId) { $0.append(entry) }
        return id
    }

    /// 改一条：只动给的字段，条目里其余的（网页卡片之类）原样留着。
    static func updateEntry(bookId: String, entryId: String, _ fields: [String: JSONValue]) throws {
        try mutateEntries(bookId) { list in
            guard let i = list.firstIndex(where: { $0["id"]?.string == entryId }), case .object(var e) = list[i] else {
                throw StoreError(message: "这条设定不存在")
            }
            for (k, v) in fields { e[k] = v }
            list[i] = .object(e)
        }
    }

    static func deleteEntry(bookId: String, entryId: String) throws {
        try mutateEntries(bookId) { $0.removeAll { $0["id"]?.string == entryId } }
    }

    private static func mutateEntries(_ bookId: String, _ body: (inout [JSONValue]) throws -> Void) throws {
        guard var row = try Database.shared.get(Collections.lorebooks, id: bookId) else { throw StoreError(message: "这本世界书不存在") }
        var list = row["entries"]?.array ?? []
        try body(&list)
        row["entries"] = .array(list)
        row.touch()
        try Database.shared.put(Collections.lorebooks, row)
    }

    /// 给角色挂上或摘下一本书。
    static func setAttached(_ on: Bool, bookId: String, charId: String) throws {
        guard let c = try Repo.character(charId) else { throw StoreError(message: "这个角色不存在") }
        var ids = c.lorebookIds.filter { $0 != bookId }
        if on { ids.append(bookId) }
        _ = try People.update(c, ["lorebookIds": .array(ids.map { .string($0) })])
    }
}
