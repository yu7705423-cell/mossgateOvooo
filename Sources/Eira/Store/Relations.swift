import Foundation

/// 角色之间的关系（网页版 ai/tasks/card.js 的「关系」一节，ARCHITECTURE 4.593）。
///
/// 存在角色自己身上：relations: [{ charId, label, circle }]。label 的含义统一成「对方是我的什么」，加的时候两边各写一条。
/// circle：在这个角色看来对方属于哪个圈子，是这个角色自己的分法，另一方那条上的圈子不一定一样。空串为未分组。
/// 指向已删除角色的那几条读的时候滤掉（导入的角色包里可能有指向包外角色的关系）。
enum Relations {
    struct Rel: Equatable, Identifiable, Sendable {
        var charId: String
        var label: String
        var circle: String
        var id: String { charId }
    }

    struct Group: Equatable, Identifiable {
        var circle: String
        var items: [Rel]
        var id: String { circle.isEmpty ? "_" : circle }
    }

    private static func str(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s)?: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let n)?: return n == n.rounded() ? String(Int(n)) : String(n)
        default: return ""
        }
    }

    private static func raw(_ row: Row) -> [[String: JSONValue]] { (row["relations"]?.array ?? []).compactMap(\.object) }

    /// 这个角色眼里的关系，找不到对方的不算
    static func of(_ charId: String) -> [Rel] {
        guard let c = try? Repo.character(charId) else { return [] }
        let live = Set(((try? Repo.characters()) ?? []).map(\.id))
        return raw(c.row).compactMap { r in
            let id = r["charId"]?.string ?? ""
            guard live.contains(id) else { return nil }
            return Rel(charId: id, label: str(r["label"]), circle: str(r["circle"]))
        }
    }

    /// 这个角色已有的圈子名，按第一次出现的先后
    static func circles(_ charId: String) -> [String] {
        var out: [String] = []
        for r in of(charId) where !r.circle.isEmpty && !out.contains(r.circle) { out.append(r.circle) }
        return out
    }

    /// 按圈子分组：有名字的在前，未分组的最后一组（circle 为空串）。空组不回
    static func grouped(_ charId: String) -> [Group] {
        let rels = of(charId)
        var groups = circles(charId).map { c in Group(circle: c, items: rels.filter { $0.circle == c }) }
        let rest = rels.filter { $0.circle.isEmpty }
        if !rest.isEmpty { groups.append(Group(circle: "", items: rest)) }
        return groups.filter { !$0.items.isEmpty }
    }

    private static func write(_ charId: String, _ change: ([[String: JSONValue]]) -> [[String: JSONValue]]) throws {
        guard var row = try Database.shared.get(Collections.characters, id: charId) else { return }
        row["relations"] = .array(change(raw(row)).map { .object($0) })
        row.touch()
        try Database.shared.put(Collections.characters, row)
    }

    /// 改这一方眼里的那条关系：标签、圈子，给哪个改哪个
    static func set(_ charId: String, _ otherId: String, label: String? = nil, circle: String? = nil) throws {
        try write(charId) { list in
            list.map { r in
                guard r["charId"]?.string == otherId else { return r }
                var o = r
                if let label { o["label"] = .string(label.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if let circle { o["circle"] = .string(circle.trimmingCharacters(in: .whitespacesAndNewlines)) }
                return o
            }
        }
    }

    /// 把这几个人归入某个圈子（空串为未分组）
    static func setCircle(_ charId: String, _ otherIds: [String], _ circle: String) throws {
        for o in otherIds { try set(charId, o, circle: circle) }
    }

    /// 圈子改名：这个角色身上叫 from 的全改成 to
    static func renameCircle(_ charId: String, from: String, to: String) throws {
        let f = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return }
        try write(charId) { list in
            list.map { r in
                guard str(r["circle"]) == f else { return r }
                var o = r
                o["circle"] = .string(to.trimmingCharacters(in: .whitespacesAndNewlines))
                return o
            }
        }
    }

    /// 两边各写一条。circleA：a 眼里 b 属于哪个圈子；circleB 反过来。没给的保留原来那条上的
    static func link(_ a: String, _ b: String, labelForA: String, labelForB: String = "",
                     circleA: String? = nil, circleB: String? = nil) throws {
        guard !a.isEmpty, !b.isEmpty, a != b else { return }
        func put(_ id: String, _ other: String, _ label: String, _ circle: String?) throws {
            try write(id) { list in
                let old = list.first { $0["charId"]?.string == other }
                var cur = list.filter { $0["charId"]?.string != other }
                cur.append(["charId": .string(other), "label": .string(label.trimmingCharacters(in: .whitespacesAndNewlines)),
                            "circle": .string((circle ?? str(old?["circle"])).trimmingCharacters(in: .whitespacesAndNewlines))])
                return cur
            }
        }
        try put(a, b, labelForA, circleA)
        try put(b, a, labelForB.isEmpty ? labelForA : labelForB, circleB)
    }

    static func unlink(_ a: String, _ b: String) throws {
        try write(a) { $0.filter { $0["charId"]?.string != b } }
        try write(b) { $0.filter { $0["charId"]?.string != a } }
    }

    // MARK: - 关系网

    struct Node: Equatable, Identifiable { var id: String; var name: String; var avatar: String; var depth: Int }
    struct Edge: Equatable, Identifiable { var key: String; var a: String; var b: String; var label: String; var id: String { key } }

    /// 以某个角色为中心往外走两层。按广度走：一个既是直接关系、又能从别人那儿绕到的人，
    /// 深度优先会先被记成第二层，画出来的圈就乱了
    static func graph(around charId: String, depth: Int = 2) -> (nodes: [Node], edges: [Edge]) {
        var nodes: [Node] = []
        var edges: [Edge] = []
        var frontier = [charId]
        var seen: Set<String> = [charId]
        var d = 0
        while d <= depth && !frontier.isEmpty {
            var next: [String] = []
            for id in frontier {
                guard let c = try? Repo.character(id) else { continue }
                nodes.append(Node(id: id, name: c.row.string("name"), avatar: c.avatar, depth: d))
                for r in of(id) {
                    let key = [id, r.charId].sorted().joined(separator: "|")
                    if !edges.contains(where: { $0.key == key }) { edges.append(Edge(key: key, a: id, b: r.charId, label: r.label)) }
                    if !seen.contains(r.charId) { seen.insert(r.charId); next.append(r.charId) }
                }
            }
            frontier = next
            d += 1
        }
        let ids = Set(nodes.map(\.id))
        return (nodes, edges.filter { ids.contains($0.a) && ids.contains($0.b) })
    }

    // MARK: - 生成 NPC 读的设定

    /// 这个角色的全部设定文字（网页版 settingOf，4.726）：人设、核心设定、情境、角色卡上挂着的世界书里每一条开着的条目（不看关键词）
    static func setting(of char: Character) -> String {
        var parts: [String] = []
        func add(_ head: String, _ v: String) {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append("### \(head)\n\(t)") }
        }
        add("Character card", char.persona)
        add("Core settings", char.core)
        add("Scenario", char.scenario)
        let own = char.row["loreEntries"]?.object ?? [:]
        for id in char.lorebookIds {
            guard let row = try? Database.shared.get(Collections.lorebooks, id: id) else { continue }
            if row.bool("forImage") || row.bool("forVoice") || row.bool("forMemory") { continue }
            let book = Lorebook(row: row)
            for e in book.entries {
                let on = own["\(book.id):\(e.id)"]?.bool ?? e.enabled
                guard on, !e.isCard else { continue }
                let title = e.json["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? e.comment
                add("World book「\(book.name)」\(title)".trimmingCharacters(in: .whitespaces), e.content)
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
