import Foundation

/// 正则替换（网页版 system/regex.js，ARCHITECTURE 4.383）。
///
/// 每条规则：查找（普通文字或正则）、替换为、作用于谁、在哪儿、改哪里（只改显示 / 两边都改 / 只改发给角色的）、适用哪些角色。
/// **存着的原文永远不动。** 显示时套一次，组装发给角色的聊天记录时套一次。关掉一条规则，两边立刻回到原样。不调接口。
/// 规则按列表顺序依次套；写错的正则不套。存在 settings.regexRules，随备份走。
enum RegexRules {
    struct Rule: Identifiable, Equatable {
        var json: [String: JSONValue]
        var id: String { json["id"]?.string ?? "" }
        var name: String { json["name"]?.string ?? "" }
        var on: Bool { json["on"]?.bool != false }
        var find: String { json["find"]?.string ?? "" }
        var isRegex: Bool { json["regex"]?.bool == true }
        var caseSensitive: Bool { json["caseSensitive"]?.bool != false }
        var replace: String { json["replace"]?.string ?? "" }
        var mode: String { json["mode"]?.string ?? "display" }
        var who: [String] { json["who"]?.array?.compactMap(\.string) ?? ["char", "user"] }
        var whereList: [String] { json["where"]?.array?.compactMap(\.string) ?? ["online", "offline"] }
        var charIds: [String] { json["charIds"]?.array?.compactMap(\.string) ?? [] }
    }

    static let modes: [(id: String, label: String, desc: String)] = [
        ("display", "只改显示", "屏幕上显示替换后的文字，发给角色的仍是原文"),
        ("both", "两边都改", "屏幕上与发给角色的都是替换后的文字"),
        ("prompt", "只改发给角色的", "屏幕上显示原文，发给角色的是替换后的文字"),
    ]

    static func blank(name: String) -> [String: JSONValue] {
        ["id": .string(Ids.make("rx")), "name": .string(name), "on": .bool(true), "find": .string(""), "regex": .bool(false),
         "caseSensitive": .bool(true), "replace": .string(""), "who": .array([.string("char"), .string("user")]),
         "where": .array([.string("online"), .string("offline")]), "mode": .string("display"), "charIds": .array([])]
    }

    static func list(_ s: AppSettings) -> [Rule] {
        (s.raw["regexRules"]?.array ?? []).compactMap { $0.object.map(Rule.init(json:)) }
    }

    static let format = "eira-regex"

    /// 导出（网页版 exportOf）：{ format, version, rules }，规则去掉 id。ids 为 nil 时导出全部
    static func exportFile(_ s: AppSettings, ids: [String]? = nil) throws -> URL {
        let rows: [JSONValue] = list(s).filter { ids == nil || ids!.contains($0.id) }.map { r in
            var o = r.json
            o["id"] = nil
            return .object(o)
        }
        let obj: JSONValue = .object(["format": .string(format), "version": .number(1), "rules": .array(rows)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Eira正则规则.json")
        try JSONSerialization.data(withJSONObject: obj.any, options: [.prettyPrinted]).write(to: url)
        return url
    }

    /// 读文件（网页版 importText）：规则接在现有的后面，各自换新 id。回导入了几条
    @discardableResult
    static func importData(_ s: inout AppSettings, _ data: Data) throws -> Int {
        guard case .object(let obj)? = try? JSONValue.parse(data) else { throw StoreError(message: "文件不是有效的正则规则") }
        guard obj["format"]?.string == format, let list = obj["rules"]?.array else { throw StoreError(message: "文件不是本应用导出的正则规则") }
        let rows: [JSONValue] = list.compactMap(\.object).map { r in
            var o = blank(name: "")
            o.merge(r) { _, n in n }
            o["id"] = .string(Ids.make("rx"))
            return .object(o)
        }
        s.raw["regexRules"] = .array((s.raw["regexRules"]?.array ?? []) + rows)
        return rows.count
    }

    /// 编译。查找为空回 nil；正则写错回错误说明。
    static func compile(_ r: Rule) -> (NSRegularExpression?, String) {
        guard !r.find.isEmpty else { return (nil, "") }
        let pattern = r.isRegex ? r.find : NSRegularExpression.escapedPattern(for: r.find)
        // 每一行消息、每次画都要套一遍：编译过的按「写法 + 大小写」记住，不重复编译
        let key = (r.caseSensitive ? "1" : "0") + pattern
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = cache[key] { return hit }
        let out: (NSRegularExpression?, String)
        do { out = (try NSRegularExpression(pattern: pattern, options: r.caseSensitive ? [] : [.caseInsensitive]), "") }
        catch { out = (nil, error.localizedDescription) }
        if cache.count > 200 { cache.removeAll() }
        cache[key] = out
        return out
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (NSRegularExpression?, String)] = [:]

    /// 套一条。普通文字那一档，替换里的 $ 原样写出，不当成引用；正则那一档 $& 换成整段（JS 的写法）。
    static func apply(_ r: Rule, _ text: String) -> String {
        guard let re = compile(r).0, !text.isEmpty else { return text }
        let template = r.isRegex ? r.replace.replacingOccurrences(of: "$&", with: "$0")
                                 : NSRegularExpression.escapedTemplate(for: r.replace)
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    struct Context {
        var who: String       // char | user
        var whereIs: String   // online | offline
        var charIds: [String]
    }

    private static func fits(_ r: Rule, side: String, _ c: Context) -> Bool {
        guard r.on else { return false }
        if side == "display" ? r.mode == "prompt" : r.mode == "display" { return false }
        guard r.who.contains(c.who), r.whereList.contains(c.whereIs) else { return false }
        return r.charIds.isEmpty || c.charIds.contains { r.charIds.contains($0) }
    }

    private static func run(_ side: String, _ text: String, _ c: Context, _ rules: [Rule]) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var out = text
        for r in rules where fits(r, side: side, c) { out = apply(r, out) }
        return out
    }

    static func forDisplay(_ text: String, _ c: Context, settings s: AppSettings = .load()) -> String { run("display", text, c, list(s)) }
    static func forPrompt(_ text: String, _ c: Context, settings s: AppSettings) -> String { run("prompt", text, c, list(s)) }

    /// 组装聊天记录时用。只套文字与旁白，方括号标记那些不碰。
    static func promptMessage(_ m: Message, chat: Chat, settings s: AppSettings) -> Message {
        guard ["text", "narration"].contains(m.kind) else { return m }
        let out = forPrompt(m.content, Context(who: m.role == .user ? "user" : "char", whereIs: "online", charIds: chat.characterIds), settings: s)
        guard out != m.content else { return m }
        var copy = m
        copy.row["content"] = .string(out)
        return copy
    }
}
