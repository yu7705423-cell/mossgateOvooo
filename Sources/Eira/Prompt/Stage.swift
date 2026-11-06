import SwiftUI

/// 线下的外观（网页版 system/stage.js）。和全局主题、阅读器都分开存（settings.stage），某一场可以单独盖一份（scene.stage）。
/// 三套内置主题各是一整组颜色，选一个就一次性填好，之后哪一项都还改得动。颜色是用户自己挑的，不是设计令牌。
enum Stage {
    struct ThemeSet: Identifiable {
        let id: String
        let label: String
        var serif = true
        var bg = "", ink = "", dim = "", line = "", mark = ""
    }

    static let themes: [ThemeSet] = [
        ThemeSet(id: "body", label: "正文", serif: true, bg: "#FCFBF8", ink: "#1C1F24", dim: "#6E737B", line: "#E2E0D9", mark: "#27405E"),
        ThemeSet(id: "night", label: "夜刊", serif: true, bg: "#15171B", ink: "#E6E3DB", dim: "#8B9098", line: "#2A2E35", mark: "#C2A15B"),
        ThemeSet(id: "plain", label: "素", serif: false, bg: "#FFFFFF", ink: "#101214", dim: "#70757C", line: "#EBEDEF", mark: "#1F6F5C"),
        ThemeSet(id: "custom", label: "自定义"),
    ]

    static func theme(_ id: String) -> ThemeSet { themes.first { $0.id == id } ?? themes[0] }

    static let signs: [(id: String, label: String)] = [("full", "完整"), ("line", "一行"), ("none", "不显示")]

    /// 版式（网页版 stage.LAYOUTS）。原生版画翻页与明信片两档；网页版的「气泡」那一档按明信片画，设置原样留着
    static let layouts: [(id: String, label: String)] = [("page", "翻页"), ("cards", "明信片")]

    /// 这一份外观按哪一档画：认不出的（气泡）按明信片
    static func layoutOf(_ cfg: [String: JSONValue]) -> String { cfg["layout"]?.string == "page" ? "page" : "cards" }

    /// 一段切成几张（网页版 4.107：一段超过 pageChars 就续张，0 表示不切）。按段落接，一段太长时在句末断开
    static func pages(_ text: String, max n: Int) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n > 0, t.count > n else { return [t] }
        var out: [String] = []
        var cur = ""
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        for para in t.components(separatedBy: "\n") {
            var p = para
            while p.count > n {
                // 一段比一张还长：在一张的字数以内找最后一个句末标点
                let head = String(p.prefix(n))
                let cut = head.lastIndex(where: { "。！？…!?」”".contains($0) }).map { head.distance(from: head.startIndex, to: $0) + 1 } ?? n
                let piece = String(p.prefix(max(1, cut)))
                if !cur.isEmpty && cur.count + piece.count > n { flush() }
                cur += (cur.isEmpty ? "" : "\n") + piece
                flush()
                p = String(p.dropFirst(max(1, cut)))
            }
            if p.isEmpty { continue }
            if !cur.isEmpty && cur.count + 1 + p.count > n { flush() }
            cur += (cur.isEmpty ? "" : "\n") + p
        }
        flush()
        return out.isEmpty ? [t] : out
    }

    /// 全局那份，缺的按网页版 DEFAULTS 补
    static func config(_ s: AppSettings = .load()) -> [String: JSONValue] {
        var out: [String: JSONValue] = [
            "theme": .string("body"), "layout": .string("page"), "pageChars": .number(700), "tapTurn": .bool(true),
            "sign": .string("full"), "serif": .bool(true),
            "fontSize": .number(17), "lineHeight": .number(1.9), "paraGap": .number(1),
            "bgColor": .string(""), "ink": .string(""), "dim": .string(""), "line": .string(""), "mark": .string(""),
        ]
        for (k, v) in s.raw["stage"]?.object ?? [:] { out[k] = v }
        // 从前这一项是个开关（stamp），现在有三档。老设置里关着的，对应「不显示」
        if s.raw["stage"]?["stamp"]?.bool == false && s.raw["stage"]?["sign"] == nil { out["sign"] = .string("none") }
        return out
    }

    /// 某一场单独换过外观的话，用它那一份盖在全局上
    static func forScene(_ scene: Row?, _ s: AppSettings = .load()) -> [String: JSONValue] {
        var out = config(s)
        for (k, v) in scene?["stage"]?.object ?? [:] { out[k] = v }
        return out
    }

    struct Look: Equatable {
        var bg: Color, ink: Color, dim: Color, line: Color, mark: Color
        var serif: Bool
        var fontSize: CGFloat
        var lineSpacing: CGFloat
        var paraGap: CGFloat
        var sign: String

        func font(_ size: CGFloat? = nil) -> Font {
            let n = size ?? fontSize
            return serif ? Theme.serif(n) : .system(size: n)
        }
    }

    static func look(_ cfg: [String: JSONValue]) -> Look {
        let t = theme(cfg["theme"]?.string ?? "body")
        func c(_ key: String, _ fallback: String, _ def: String) -> Color {
            let v = cfg[key]?.string ?? ""
            return Color(hex: v.isEmpty ? (fallback.isEmpty ? def : fallback) : v) ?? Color(hex: def) ?? .white
        }
        let size = CGFloat(cfg["fontSize"]?.number ?? 17)
        let lh = CGFloat(cfg["lineHeight"]?.number ?? 1.9)
        return Look(bg: c("bgColor", t.bg, "#FCFBF8"), ink: c("ink", t.ink, "#1C1F24"), dim: c("dim", t.dim, "#6E737B"),
                    line: c("line", t.line, "#E2E0D9"), mark: c("mark", t.mark, "#27405E"),
                    serif: cfg["serif"]?.bool ?? true, fontSize: size, lineSpacing: max(0, size * (lh - 1)),
                    paraGap: size * CGFloat(cfg["paraGap"]?.number ?? 1), sign: cfg["sign"]?.string ?? "full")
    }

    /// 换一套内置主题：把那一组颜色一次性填进去
    @MainActor
    static func useTheme(_ id: String) {
        let t = theme(id)
        set(id == "custom" ? ["theme": .string("custom")] : [
            "theme": .string(id), "bgColor": .string(t.bg), "ink": .string(t.ink), "dim": .string(t.dim),
            "line": .string(t.line), "mark": .string(t.mark), "serif": .bool(t.serif),
        ])
    }

    @MainActor
    static func set(_ patch: [String: JSONValue]) {
        SettingsModel.shared.update { s in
            var cur = s.raw["stage"]?.object ?? [:]
            for (k, v) in patch { cur[k] = v }
            s.raw["stage"] = .object(cur)
        }
    }

    @MainActor
    static func reset() { SettingsModel.shared.set("stage", .object([:])) }
}
