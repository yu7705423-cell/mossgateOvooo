import Foundation

/// 从一段散文资料读出一张角色卡（网页版 ai/tasks/card.js 的 parseCard 与 makeCore）。
///
/// 不做 JSON 导入（网页版第 17 条）：模型读完按本项目自己的字段填，不认别家的格式。
/// 用户点了才调，一次读取调一次接口；核心设定另调一次，确认页上有开关并写明。
enum CardImport {
    struct Draft: Equatable, Sendable {
        var name = ""
        var age = ""
        var gender = ""
        var birthday = ""
        var signature = ""
        var persona = ""
        var appearance = ""
        var scenario = ""
        var firstMessage = ""
        var exampleDialogue = ""
    }

    /// 资料最多带前 12000 字（网页版同样）。
    static let rawLimit = 12000

    static func parse(raw: String) async throws -> Draft {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StoreError(message: "这个文件是空的") }
        let s = AppSettings.load()
        let system = Templates.render("task.card-import", ["raw": String(text.prefix(rawLimit))], settings: s)
        let r = try await AIService.shared.send(task: "card.import", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: 3000, retries: 1)
        guard let json = JSONReply.parse(r.text)?.object else { throw StoreError(message: JSONReply.failure(r.text)) }
        func str(_ k: String) -> String {
            switch json[k] {
            case .string(let v)?: return v.trimmingCharacters(in: .whitespacesAndNewlines)
            case .number(let n)?: return n == n.rounded() ? String(Int(n)) : String(n)
            default: return ""
            }
        }
        var d = Draft(name: str("name"), age: str("age"), gender: str("gender"), birthday: str("birthday"),
                      signature: str("signature"), persona: str("persona"), appearance: str("appearance"),
                      scenario: str("scenario"), firstMessage: str("firstMessage"), exampleDialogue: str("exampleDialogue"))
        if d.persona.isEmpty && d.name.isEmpty { throw StoreError(message: "没能从这份资料里读出角色卡") }
        if d.name.isEmpty { d.name = "未命名" }
        return d
    }

    /// 存成一个新角色。字段照网页版 ImportPage 的 save。
    static func save(_ d: Draft) throws -> Character {
        let row = Row.new(prefix: "char", [
            "name": .string(d.name), "age": .string(d.age), "gender": .string(d.gender), "birthday": .string(d.birthday),
            "signature": .string(d.signature), "persona": .string(d.persona), "appearance": .string(d.appearance),
            "scenario": .string(d.scenario), "firstMessage": .string(d.firstMessage), "exampleDialogue": .string(d.exampleDialogue),
            "relations": .array([]), "lorebookIds": .array([]), "canSendVoice": .bool(true), "canSendImage": .bool(true),
        ])
        try Database.shared.put(Collections.characters, row)
        return Character(row: row)
    }

    /// 把人设压成三到五行的核心设定。另调一次接口；失败返回空串，不影响已经建好的角色（网页版同样）。
    static func makeCore(persona: String) async -> String {
        let text = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let s = AppSettings.load()
        let system = Templates.render("task.core", ["persona": String(text.prefix(6000))], settings: s)
        do {
            let r = try await AIService.shared.send(task: "card.core", system: system,
                                                    messages: [AIMessage(role: .user, content: "Produce the output as instructed.")],
                                                    maxTokens: 400)
            return String(r.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        } catch {
            Diagnostics.shared.record("card-core-failed", ["error": error.localizedDescription])
            return ""
        }
    }
}
