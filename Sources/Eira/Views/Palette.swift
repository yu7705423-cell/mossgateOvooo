import SwiftUI
import UIKit

/// 配色（网页版 system/palette.js，4.494）。用户只挑三个颜色：主色、底色、文字色，深浅两套各一组；
/// 其余（次级底色、分隔线、次要文字、主色上的字……）按固定比例算出来。选「黑白」时一个都不盖，令牌回到原值。
/// Theme 的令牌在取色那一刻问这里（`Theme.token`），所以换了配色不用改任何视图。
enum Palette {
    struct Base: Equatable {
        var accent: String
        var bg: String
        var text: String
    }

    struct Preset: Identifiable {
        let id: String
        let label: String
        let light: Base?
        let dark: Base?
    }

    static let presets: [Preset] = [
        Preset(id: "mono", label: "黑白", light: nil, dark: nil),
        Preset(id: "mist", label: "雾蓝", light: Base(accent: "#5B7290", bg: "#F3F5F8", text: "#1E2430"),
               dark: Base(accent: "#8FA6C4", bg: "#101318", text: "#E6EAF0")),
        Preset(id: "sage", label: "鼠尾草", light: Base(accent: "#6E8B74", bg: "#F3F5F1", text: "#1F2620"),
               dark: Base(accent: "#9DB8A2", bg: "#101411", text: "#E4EAE3")),
        Preset(id: "latte", label: "奶茶", light: Base(accent: "#9C7B5F", bg: "#F7F3EE", text: "#2B241E"),
               dark: Base(accent: "#C9A88A", bg: "#15120F", text: "#EDE6DD")),
        Preset(id: "blush", label: "樱粉", light: Base(accent: "#B87C86", bg: "#FAF4F4", text: "#2E2224"),
               dark: Base(accent: "#D9A3AC", bg: "#161112", text: "#F0E4E6")),
        Preset(id: "lilac", label: "薰衣草", light: Base(accent: "#8577A8", bg: "#F5F3F9", text: "#25222F"),
               dark: Base(accent: "#B3A7D6", bg: "#121119", text: "#E8E5F0")),
        Preset(id: "clay", label: "陶土", light: Base(accent: "#A0655A", bg: "#F5F1EC", text: "#2A221F"),
               dark: Base(accent: "#D19A8E", bg: "#16110F", text: "#EEE3DE")),
    ]

    /// 黑白那一套在色块上画成什么样（它本身不盖任何令牌）
    static let monoShow = (light: Base(accent: "#000000", bg: "#FFFFFF", text: "#000000"),
                           dark: Base(accent: "#FFFFFF", bg: "#000000", text: "#FFFFFF"))

    static func isHex(_ v: String) -> Bool { v.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil }

    private static func rgb(_ h: String) -> [Double] {
        let n = UInt32(h.dropFirst(), radix: 16) ?? 0
        return [Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255)]
    }
    private static func ui(_ c: [Double], _ a: Double = 1) -> UIColor {
        UIColor(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: a)
    }
    /// a 按 t 的比例混进 b
    private static func mix(_ a: String, _ b: String, _ t: Double) -> UIColor {
        let x = rgb(a), y = rgb(b)
        return ui((0..<3).map { (x[$0] * t + y[$0] * (1 - t)).rounded() })
    }
    private static func lum(_ h: String) -> Double {
        rgb(h).map { v -> Double in let c = v / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            .enumerated().reduce(0) { $0 + [0.2126, 0.7152, 0.0722][$1.offset] * $1.element }
    }

    /// 三个颜色算出整套。比例与网页版一致（对着默认黑白量过）
    static func derive(_ b: Base, dark: Bool) -> [String: UIColor] {
        let k = dark ? (s2: 0.08, s3: 0.12, b1: 0.10, b2: 0.17, t2: 0.58, t3: 0.36, aw: 0.16, gf: 0.07)
                     : (s2: 0.045, s3: 0.075, b1: 0.07, b2: 0.14, t2: 0.56, t3: 0.34, aw: 0.10, gf: 0.04)
        return [
            "bg": ui(rgb(b.bg)), "surface": dark ? mix(b.text, b.bg, 0.04) : ui(rgb(b.bg)),
            "surface-2": mix(b.text, b.bg, k.s2), "surface-3": mix(b.text, b.bg, k.s3),
            "border": mix(b.text, b.bg, k.b1), "border-2": mix(b.text, b.bg, k.b2),
            "text": ui(rgb(b.text)), "text-2": ui(rgb(b.text), k.t2), "text-3": ui(rgb(b.text), k.t3),
            "accent": ui(rgb(b.accent)), "accent-weak": mix(b.accent, b.bg, k.aw),
            // 主色上的字：白字对比度不到 3.2 就换黑字
            "on-accent": 1.05 / (lum(b.accent) + 0.05) < 3.2 ? .black : .white,
            "group-fill": mix(b.text, b.bg, k.gf),
        ]
    }

    /// 当前选的是哪一套、深浅各用哪三个颜色。自定义的缺了哪个从雾蓝补
    static func base(_ cfg: JSONValue?) -> (light: Base?, dark: Base?) {
        let o = cfg?.object ?? [:]
        let id = o["id"]?.string ?? "mono"
        if id == "custom" {
            let ref = presets[1]
            func fill(_ c: [String: JSONValue]?, _ d: Base) -> Base {
                func pick(_ k: String, _ def: String) -> String { let v = c?[k]?.string ?? ""; return isHex(v) ? v : def }
                return Base(accent: pick("accent", d.accent), bg: pick("bg", d.bg), text: pick("text", d.text))
            }
            let custom = o["custom"]?.object
            return (fill(custom?["light"]?.object, ref.light!), fill(custom?["dark"]?.object, ref.dark!))
        }
        let hit = presets.first { $0.id == id } ?? presets[0]
        return (hit.light, hit.dark)
    }

    nonisolated(unsafe) private static var lightSet: [String: UIColor]?
    nonisolated(unsafe) private static var darkSet: [String: UIColor]?
    nonisolated(unsafe) private(set) static var key = ""

    /// 设置读进来或改了之后调一次
    static func apply(_ cfg: JSONValue?) {
        let b = base(cfg)
        lightSet = b.light.map { derive($0, dark: false) }
        darkSet = b.dark.map { derive($0, dark: true) }
        if let cfg, let d = try? cfg.encoded() { key = String(decoding: d, as: UTF8.self) } else { key = "" }
    }

    /// 某个令牌在这一套里的颜色；黑白返回 nil
    static func color(_ name: String, dark: Bool) -> UIColor? { (dark ? darkSet : lightSet)?[name] }

    // MARK: - 字号（网页版 fontScale，0.8 到 1.4）

    nonisolated(unsafe) private(set) static var fontScale: Double = 1

    static func applyFont(_ v: JSONValue?) {
        let n = v?.number ?? 1
        fontScale = n.isFinite && n > 0 ? min(1.4, max(0.8, n)) : 1
    }

    /// 系统那一档字号，跟着字号比例走（按文字样式写的字都随它变）
    static var typeSize: DynamicTypeSize {
        switch fontScale {
        case ..<0.88: return .xSmall
        case ..<0.96: return .small
        case ..<1.04: return .large
        case ..<1.12: return .xLarge
        case ..<1.22: return .xxLarge
        case ..<1.32: return .xxxLarge
        default: return .accessibility1
        }
    }
}

extension Color {
    /// 颜色转 #rrggbb（取色器选完写回设置用）
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func h(_ v: CGFloat) -> String { String(format: "%02X", Int((max(0, min(1, v)) * 255).rounded())) }
        return "#" + h(r) + h(g) + h(b)
    }
}
