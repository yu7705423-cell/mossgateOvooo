import Foundation

/// 提示词模板。默认值是 `Resources/templates.json`，由 `scripts/sync-templates.mjs` 从网页版原样抄来，不在这里手改。
/// 用户改过的存在 settings.promptTemplates，优先用它（网页版 templates.js 的 template）。
enum Templates {
    static let defaults: [String: String] = {
        guard let url = Bundle.main.url(forResource: "templates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            assertionFailure("templates.json 缺失或格式不对")
            return [:]
        }
        return dict
    }()

    /// 网页版还没有、只有原生版有的功能的模板（`Resources/native-templates.json`，手写）。同一个 id 网页版有了就用网页版的
    static let nativeDefaults: [String: String] = {
        for bundle in [Bundle.main, Bundle(for: BundleToken.self)] {
            if let url = bundle.url(forResource: "native-templates", withExtension: "json"), let data = try? Data(contentsOf: url),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return dict.compactMapValues { $0 as? String }
            }
        }
        return [:]
    }()

    private final class BundleToken {}

    static func get(_ id: String, settings: AppSettings) -> String {
        if let mine = settings.raw["promptTemplates"]?.object?[id]?.string, !mine.isEmpty { return mine }
        return defaults[id] ?? nativeDefaults[id] ?? ""
    }

    /// `{{name}}` 换成 vars 里的值；没给的换成空串。
    static func fill(_ template: String, _ vars: [String: String]) -> String {
        let pattern = try! NSRegularExpression(pattern: #"\{\{(\w+)\}\}"#)
        let ns = template as NSString
        var out = ""
        var last = 0
        for m in pattern.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += vars[ns.substring(with: m.range(at: 1))] ?? ""
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func render(_ id: String, _ vars: [String: String] = [:], settings: AppSettings) -> String {
        fill(get(id, settings: settings), vars)
    }
}
