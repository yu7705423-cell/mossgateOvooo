import Foundation

/// 按一段描述生成一份美化（原生版的功能，网页版还没有；模板 `task.skinGen` 在 `Resources/native-templates.json`）。
///
/// 用户点了才调，一次一次接口（retries 0），不是自动触发的，不进 ExtraCalls；记账任务名 skin.gen，走副用接口。
/// 模型写的是编辑器（生成器）的设置，不是 CSS：旋钮的清单由网页版 skin-gen.js 给（`SkinGen.groups`），
/// 交回来的逐项按那份清单核过（组与项认得、颜色是十六进制、选项在列表里），认不出的丢掉；
/// 存成新的一份，之后在编辑器里照常调。图片、渐变与叠加两类不交给模型（写不出图片，渐变的结构另有一套）。
/// 生成器的包不在时（`SkinGen.available` 为假）没有清单，这一项不可用。
enum SkinAI {
    static let task = "skin.gen"
    static let template = "task.skinGen"

    /// 交给模型的旋钮清单：一组一行开头，下面每项一行
    static func schema(_ groups: [SkinGen.Group]) -> String {
        groups.map { g in
            let items = g.items.filter { !["image", "paint"].contains($0.type) }.map { it -> String in
                var t = "  \(it.id) (\(it.label)): \(it.type)"
                if it.type == "num" {
                    let range = [it.min, it.max].map { $0.map { n in n == n.rounded() ? String(Int(n)) : String(n) } ?? "" }
                    if !range[0].isEmpty || !range[1].isEmpty { t += " \(range[0])..\(range[1])" }
                    if !it.unit.isEmpty { t += " \(it.unit)" }
                }
                if it.type == "pick", !it.options.isEmpty { t += " [" + it.options.map(\.id).joined(separator: ", ") + "]" }
                return t
            }
            return "\(g.id) (\(g.label))\n" + items.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// 模型交回来的设置按清单核一遍。认不出的组、项、值一律丢掉
    static func clean(_ raw: JSONValue?, _ groups: [SkinGen.Group]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for g in groups {
            guard let src = raw?[g.id]?.object else { continue }
            var grp: [String: JSONValue] = [:]
            for it in g.items {
                guard let v = src[it.id], !v.isNull else { continue }
                switch it.type {
                case "color":
                    if let s = v.string?.trimmingCharacters(in: .whitespaces),
                       s.range(of: #"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#, options: .regularExpression) != nil {
                        grp[it.id] = .string(s)
                    }
                case "num":
                    // 数字不按滑杆的范围截（网页版编辑器的数字框同样可以填出范围）
                    if let n = v.number ?? v.string.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), n.isFinite { grp[it.id] = .number(n) }
                case "switch":
                    if let b = v.bool { grp[it.id] = .bool(b) }
                case "pick":
                    if let s = v.string, it.options.contains(where: { $0.id == s }) { grp[it.id] = .string(s) }
                case "text":
                    if let s = v.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { grp[it.id] = .string(s) }
                default:
                    continue
                }
            }
            if !grp.isEmpty { out[g.id] = .object(grp) }
        }
        return out
    }

    struct Made: Equatable {
        var name: String
        var gen: [String: JSONValue]
    }

    /// 调一次接口，交回名字与设置（不动库）
    static func generate(_ request: String) async throws -> Made {
        let ask = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty else { throw StoreError(message: "请先写下想要的样子") }
        guard let groups = SkinGen.shared.groups() else {
            throw StoreError(message: "这个版本没有带上美化编辑器的设置清单，无法生成")
        }
        let s = AppSettings.load()
        let tpl = Templates.get(template, settings: s)
        guard !tpl.isEmpty else { throw StoreError(message: "缺少生成美化的提示词模板") }
        let system = Templates.fill(tpl, ["request": ask, "schema": schema(groups)])
        let r = try await AIService.shared.send(task: task, system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                retries: 0)
        guard let json = JSONReply.parse(r.text) else { throw StoreError(message: JSONReply.failure(r.text)) }
        let gen = clean(json["gen"], groups)
        guard !gen.isEmpty else { throw StoreError(message: "模型没有给出可用的设置") }
        let name = (json["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Made(name: name.isEmpty ? "生成的美化" : String(name.prefix(80)), gen: gen)
    }

    /// 存成新的一份（重名加后缀，同导入）
    @discardableResult
    static func save(_ m: Made) throws -> Row {
        var p = Skins.Pack()
        p.name = m.name
        p.gen = m.gen
        return try Skins.install(p)
    }
}
