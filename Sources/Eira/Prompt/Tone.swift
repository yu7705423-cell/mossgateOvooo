import Foundation

/// 线下的文风（网页版 system/tone.js）。
///
/// 内置提示词一个字都不写文风（网页版第 16 条）。这里出厂带几份预设，一份都不默认启用；选哪几份是一场一场定的，
/// 每一份都能改、能删、能自己新建。改动存在 settings.tonePresets（id 对应 { name, text }，null 表示删掉了内置的那份），与网页版同一份。
/// 正文一律英文（第 14 条）。
enum Tone {
    struct Preset: Identifiable, Equatable {
        var id: String
        var name: String
        var text: String
        var builtin = false
    }

    static let builtin: [Preset] = [
        Preset(id: "lean", name: "克制", text: """
        Short sentences. Concrete nouns and verbs.
        No metaphor, no simile.
        Interior states are shown through action and through what is said, and are
        not named directly.
        """, builtin: true),
        Preset(id: "dense", name: "绵密", text: """
        Long sentences carrying subordinate clauses.
        Sensory detail is sustained across several lines before the passage moves on.
        Interior states are written out at length.
        """, builtin: true),
        Preset(id: "script", name: "剧本式", text: """
        Present tense throughout.
        Action and dialogue are on separate lines.
        Only what a camera in the room could record is written: no interior states.
        """, builtin: true),
        Preset(id: "second", name: "第二人称", text: """
        Address {{userName}} in the second person throughout the passage.
        {{charName}} is still written in the third person.
        """, builtin: true),
    ]

    private static func overrides(_ s: AppSettings) -> [String: JSONValue] { s.raw["tonePresets"]?.object ?? [:] }

    static func list(_ s: AppSettings = .load()) -> [Preset] {
        let ov = overrides(s)
        var out = builtin.filter { ov[$0.id] != .null }.map { b -> Preset in
            var p = b
            if let o = ov[b.id]?.object {
                p.name = o["name"]?.string ?? p.name
                p.text = o["text"]?.string ?? p.text
            }
            return p
        }
        for (id, v) in ov.sorted(by: { $0.key < $1.key }) where !builtin.contains(where: { $0.id == id }) {
            guard let o = v.object else { continue }
            out.append(Preset(id: id, name: o["name"]?.string ?? "未命名", text: o["text"]?.string ?? ""))
        }
        return out
    }

    static func get(_ id: String, _ s: AppSettings = .load()) -> Preset? { list(s).first { $0.id == id } }

    static func save(_ id: String, name: String, text: String) throws {
        var s = try AppSettings.loadForWrite()
        var ov = overrides(s)
        ov[id] = .object(["name": .string(name), "text": .string(text)])
        s.raw["tonePresets"] = .object(ov)
        try s.save()
    }

    @discardableResult
    static func create(name: String, text: String) throws -> String {
        let id = "tone" + String(Int(Date().millis), radix: 36)
        try save(id, name: name, text: text)
        return id
    }

    /// 内置那几份删不干净，只能记一个 null 盖住
    static func remove(_ id: String) throws {
        var s = try AppSettings.loadForWrite()
        var ov = overrides(s)
        if builtin.contains(where: { $0.id == id }) { ov[id] = .null } else { ov[id] = nil }
        s.raw["tonePresets"] = .object(ov)
        try s.save()
    }

    static func resetBuiltin() throws {
        var s = try AppSettings.loadForWrite()
        var ov = overrides(s)
        for b in builtin { ov[b.id] = nil }
        s.raw["tonePresets"] = .object(ov)
        try s.save()
    }

    /// 这一场选了哪几份：新数据存 tones 数组，老数据只有一个 tone 字符串
    static func ids(_ row: Row) -> [String] {
        if let a = row["tones"]?.array { return a.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let one = row.string("tone").trimmingCharacters(in: .whitespaces)
        return one.isEmpty ? [] : [one]
    }

    /// 这一场实际要用的那段文字。custom 用这一场自己写的
    static func forScene(_ row: Row, _ s: AppSettings = .load()) -> String {
        ids(row).compactMap { id -> String? in
            let t = (id == "custom" ? row.string("toneText") : get(id, s)?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }.joined(separator: "\n\n")
    }

    static func label(_ row: Row, _ s: AppSettings = .load()) -> String {
        let names = ids(row).compactMap { id in id == "custom" ? "自己写" : get(id, s)?.name }
        return names.isEmpty ? "不设定" : names.joined(separator: "、")
    }
}
