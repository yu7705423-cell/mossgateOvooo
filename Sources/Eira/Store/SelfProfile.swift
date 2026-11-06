import Foundation

/// 我的人设分区（网页版 system/selfprofile.js，ARCHITECTURE 4.347）与一次性导入（4.959）。
///
/// 六个通用分区。**「基础资料」就是原来那一段 description**，其余五段存在 persona.sections 里。
/// 与某个角色相关的条目（persona.charNotes）一条一条，每条单独选谁读得到（only / some / all）。
/// 人设正文只在编辑页的输入框里出现（网页版第 6 条）：列表上只写多少字、几条。
enum SelfProfile {
    struct Section: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let en: String
    }

    static let sections: [Section] = [
        .init(id: "basic", label: "基础资料", en: "Basics"),
        .init(id: "personality", label: "性格", en: "Personality"),
        .init(id: "likes", label: "喜好", en: "Likes"),
        .init(id: "habits", label: "习惯", en: "Habits"),
        .init(id: "triggers", label: "雷点", en: "Sore points"),
        .init(id: "life", label: "生活状态", en: "Current life"),
    ]

    static func text(_ p: Persona?, _ id: String) -> String {
        guard let p else { return "" }
        return id == "basic" ? p.row.string("description") : (p.row["sections"]?[id]?.string ?? "")
    }

    private static func persona(_ id: String) throws -> Persona? {
        try Database.shared.get(Collections.personas, id: id).map(Persona.init(row:))
    }

    static func setText(_ personaId: String, _ id: String, _ text: String) throws {
        guard let p = try persona(personaId), sections.contains(where: { $0.id == id }) else { return }
        if id == "basic" {
            _ = try People.update(p, ["description": .string(text)])
        } else {
            var sec = p.row["sections"]?.object ?? [:]
            sec[id] = .string(text)
            _ = try People.update(p, ["sections": .object(sec)])
        }
    }

    /// 在一段末尾另起一行接上
    static func append(_ personaId: String, _ id: String, _ text: String) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let p = try persona(personaId) else { return }
        var cur = Self.text(p, id)
        while let last = cur.last, last.isWhitespace { cur.removeLast() }
        try setText(personaId, id, cur.isEmpty ? t : "\(cur)\n\(t)")
    }

    // MARK: - 与角色相关的条目

    /// 加一条「与某个角色相关」的条目（kind 'imp' 专属印象 / 'exp' 经历），默认仅该角色可见
    @discardableResult
    static func addNote(_ personaId: String, charId: String, kind: String = "imp", text: String,
                        vis: String = "only", visIds: [String] = []) throws -> [String: JSONValue]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !charId.isEmpty, !t.isEmpty, let p = try persona(personaId) else { return nil }
        let n: [String: JSONValue] = [
            "id": .string(Ids.make("cn")), "charId": .string(charId), "kind": .string(kind == "exp" ? "exp" : "imp"),
            "text": .string(t), "vis": .string(vis), "visIds": .array(visIds.map { .string($0) }), "at": .number(Date().millis),
        ]
        _ = try People.update(p, ["charNotes": .array((p.row["charNotes"]?.array ?? []) + [.object(n)])])
        return n
    }

    // MARK: - 一次性导入（4.959）

    /// 拆分结果：六个分区，加资料里的性别、生日、城市
    struct Split: Equatable, Sendable {
        var parts: [String: String] = [:]
        var gender = ""
        var birthday = ""
        var city = ""
    }

    /// 资料项：选「替换」时覆盖，选「接在后面」时只填空着的
    static let profileKeys: [(id: String, label: String)] = [("gender", "性别"), ("birthday", "生日"), ("city", "所在城市")]

    /// 按分区拆分：调一次接口（模板 task.self-import，记账 self.import，走副用）。拆分不是改写，原文照抄
    static func parse(_ text: String) async throws -> Split {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw StoreError(message: "没有可拆分的内容") }
        let system = Templates.render("task.self-import", ["raw": raw], settings: AppSettings.load())
        let r = try await AIService.shared.send(task: "self.import", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                retries: 1)
        guard let json = JSONReply.parse(r.text)?.object else { throw StoreError(message: JSONReply.failure(r.text)) }
        return try split(from: json)
    }

    static func split(from json: [String: JSONValue]) throws -> Split {
        func str(_ k: String) -> String { (json[k]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var out = Split()
        for s in sections { out.parts[s.id] = str(s.id) }
        guard out.parts.values.contains(where: { !$0.isEmpty }) else { throw StoreError(message: "没能从这段内容里拆出人设") }
        out.gender = str("gender"); out.birthday = str("birthday"); out.city = str("city")
        return out
    }

    /// 存入。replace：已有内容的分区替换；否则接在后面。资料项替换时覆盖，接在后面时只填空着的
    static func save(_ personaId: String, _ got: Split, replace: Bool) throws {
        func put(_ id: String, _ v: String) throws {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if replace { try setText(personaId, id, t) } else { try append(personaId, id, t) }
        }
        for s in sections { try put(s.id, got.parts[s.id] ?? "") }
        guard let p = try persona(personaId) else { return }
        var patch: [String: JSONValue] = [:]
        for (k, v) in [("gender", got.gender), ("birthday", got.birthday), ("city", got.city)] {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && (replace || p.row.string(k).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { patch[k] = .string(t) }
        }
        if !patch.isEmpty { _ = try People.update(p, patch) }
    }

    /// 全部存入基础资料：不调接口，原文原样
    static func saveAll(_ personaId: String, _ text: String, replace: Bool) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw StoreError(message: "请先粘贴或读取内容") }
        if replace { try setText(personaId, "basic", t) } else { try append(personaId, "basic", t) }
    }
}

// MARK: - 注入

extension SelfProfile {
    /// 「对方是谁」那一段的正文（网页版 promptText）：通用分区按段写，空的不写；只填了基础资料时原样写那一段。
    /// 与角色相关的条目只写这个角色读得到的，并写明原本属于哪位角色
    static func promptText(_ p: Persona, charId: String, userName: String) -> String {
        var out: [String] = []
        let others = (p.row["sections"]?.object ?? [:]).values.contains { !($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for s in sections {
            let t = text(p, s.id).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            out.append(s.id == "basic" && !others ? t : "\(s.en):\n\(t)")
        }
        guard !charId.isEmpty else { return out.joined(separator: "\n\n") }
        let notes = (p.row["charNotes"]?.array ?? []).compactMap(\.object).filter { n in
            let owner = n["charId"]?.string ?? ""
            let vis = n["vis"]?.string ?? ""
            return owner == charId || vis == "all" || (vis == "some" && (n["visIds"]?.array ?? []).contains(.string(charId)))
        }
        var heads: [String] = []
        var lines: [String: [String]] = [:]
        for n in notes {
            let owner = n["charId"]?.string ?? ""
            let own = owner == charId
            let who = (try? Repo.character(owner))?.row.string("name") ?? ""
            let h: String
            if n["kind"]?.string == "exp" {
                h = own ? "History between you and \(userName)" : "History between \(userName) and \(who)"
            } else {
                h = own ? "How \(userName) is around you" : "How \(userName) is around \(who)"
            }
            if lines[h] == nil { heads.append(h) }
            lines[h, default: []].append(n["text"]?.string ?? "")
        }
        for h in heads { out.append("\(h):\n" + (lines[h] ?? []).map { "- \($0)" }.joined(separator: "\n")) }
        return out.joined(separator: "\n\n")
    }

    /// 「1999-03-14」「1999年3月14日」这种带年份的，算到今天满几岁；认不出年份回 nil（网页版 context/basic.js 的 ageOf）
    static func age(_ raw: String, now: Date = Date(), zone: TimeZone = .current) -> Int? {
        guard let re = try? NSRegularExpression(pattern: #"((?:19|20)\d{2})\s*[年\-/.]\s*(\d{1,2})\s*[月\-/.]\s*(\d{1,2})"#),
              let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)), m.numberOfRanges == 4 else { return nil }
        let ns = raw as NSString
        guard let y = Int(ns.substring(with: m.range(at: 1))), let mo = Int(ns.substring(with: m.range(at: 2))),
              let d = Int(ns.substring(with: m.range(at: 3))) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let t = cal.dateComponents([.year, .month, .day], from: now)
        guard let ty = t.year, let tm = t.month, let td = t.day else { return nil }
        var a = ty - y
        if tm < mo || (tm == mo && td < d) { a -= 1 }
        return a >= 0 && a < 150 ? a : nil
    }
}
