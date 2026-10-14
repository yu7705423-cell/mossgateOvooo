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

    /// 编译。查找为空回 nil；正则写错回错误说明。
    static func compile(_ r: Rule) -> (NSRegularExpression?, String) {
        guard !r.find.isEmpty else { return (nil, "") }
        let pattern = r.isRegex ? r.find : NSRegularExpression.escapedPattern(for: r.find)
        do { return (try NSRegularExpression(pattern: pattern, options: r.caseSensitive ? [] : [.caseInsensitive]), "") }
        catch { return (nil, error.localizedDescription) }
    }

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
