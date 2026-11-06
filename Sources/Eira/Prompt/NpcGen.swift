import Foundation

/// 批量生成关联 NPC（网页版 ai/tasks/card.js 的 generateNpcs、commitNpcs，ARCHITECTURE 4.593、4.726）。
///
/// 用户点了才调，一次一次接口，记账任务名 card.npc。生成结果先在确认页上看、勾掉不要的再存（网页版第 6 条的例外：东西还没入库），
/// 所以 generate 只交回草稿，不动库；commit 才建角色、连关系。
enum NpcGen {
    struct Draft: Equatable, Identifiable, Sendable {
        var name = ""
        var age = ""
        var gender = ""
        var birthday = ""
        var signature = ""
        var persona = ""
        /// 在 NPC 眼里主角是什么
        var relation = ""
        /// 在主角眼里这个 NPC 是什么
        var reverse = ""
        var id: String { name + "|" + relation }
    }

    static let task = "card.npc"

    /// only（默认开）：只提取设定里已经写到的人，不另编新人、不凑数；count 不起作用
    static func generate(charId: String, count: Int = 4, circle: String = "", only: Bool = false) async throws -> [Draft] {
        guard let char = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        let ring = circle.trimmingCharacters(in: .whitespacesAndNewlines)
        let setting = Relations.setting(of: char)
        if only && setting.isEmpty { throw StoreError(message: "该角色的人设、核心设定、情境与世界书都是空的，没有可提取的人物") }
        let name = char.row.string("name")
        let known = Relations.of(charId).map { r -> String in
            let other = (try? Repo.character(r.charId))?.row.string("name") ?? ""
            return "- \(other)（\(r.label)\(r.circle.isEmpty ? "" : "，\(r.circle)")）"
        }.joined(separator: "\n")
        let s = AppSettings.load()
        let system = Templates.render(only ? "task.npc-extract" : "task.npc-batch", [
            "charName": name,
            "charPersona": setting.isEmpty ? "(no character card was written)" : setting,
            "count": String(max(1, count)),
            "existing": known.isEmpty ? "" : "## These people already exist around the character. Do not repeat them\n\(known)",
            "circle": ring.isEmpty ? "" : "## The circle\nAll of these people belong to \(name)'s circle 「\(ring)」 and are connected to the character through it.",
        ], settings: s)
        let r = try await AIService.shared.send(task: task, system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                retries: 1)
        guard let json = JSONReply.parse(r.text) else { throw StoreError(message: JSONReply.failure(r.text)) }
        let rows = parse(json)
        if rows.isEmpty {
            throw StoreError(message: only ? "设定里没有写到尚未建立的人物。可以关闭「只提取设定里写到的人」另外生成" : "模型没给出可用的 NPC")
        }
        return rows
    }

    /// 回复里的 npcs 数组。名字或人设空着的不要
    static func parse(_ json: JSONValue) -> [Draft] {
        func str(_ o: [String: JSONValue], _ k: String) -> String {
            switch o[k] {
            case .string(let v)?: return v.trimmingCharacters(in: .whitespacesAndNewlines)
            case .number(let n)?: return n == n.rounded() ? String(Int(n)) : String(n)
            default: return ""
            }
        }
        return (json["npcs"]?.array ?? []).compactMap(\.object).map { o in
            Draft(name: str(o, "name"), age: str(o, "age"), gender: str(o, "gender"), birthday: str(o, "birthday"),
                  signature: str(o, "signature"), persona: str(o, "persona"), relation: str(o, "relation"), reverse: str(o, "reverse"))
        }.filter { !$0.name.isEmpty && !$0.persona.isEmpty }
    }

    /// 把挑好的 NPC 建出来并连上关系。circle：在主角看来这一批属于哪个圈子；
    /// mutual：这一圈的人彼此认识，这一批之间、以及与圈子里已有的人之间也连上
    @discardableResult
    static func commit(charId: String, _ rows: [Draft], circle: String = "", mutual: Bool = false) throws -> [Character] {
        let ring = circle.trimmingCharacters(in: .whitespacesAndNewlines)
        var made: [Character] = []
        for n in rows {
            let row = Row.new(prefix: "char", [
                "name": .string(n.name), "age": .string(n.age), "gender": .string(n.gender), "birthday": .string(n.birthday),
                "signature": .string(n.signature), "persona": .string(n.persona), "isNpc": .bool(true), "relations": .array([]),
                "lorebookIds": .array([]), "canSendVoice": .bool(true), "canSendImage": .bool(true),
            ])
            try Database.shared.put(Collections.characters, row)
            try Relations.link(row.id, charId, labelForA: n.relation, labelForB: n.reverse.isEmpty ? n.relation : n.reverse, circleB: ring)
            made.append(Character(row: row))
        }
        if mutual {
            var members: [String] = []
            if !ring.isEmpty { members = Relations.of(charId).filter { $0.circle == ring }.map(\.charId) }
            for m in made where !members.contains(m.id) { members.append(m.id) }
            let label = ring.isEmpty ? "熟人" : "\(ring)成员"
            for i in members.indices {
                for j in members.indices where j > i {
                    let (a, b) = (members[i], members[j])
                    if Relations.of(a).contains(where: { $0.charId == b }) { continue }   // 已经认识的不改
                    try Relations.link(a, b, labelForA: label, labelForB: label, circleA: ring, circleB: ring)
                }
            }
        }
        return made
    }
}
