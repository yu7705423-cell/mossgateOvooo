import Foundation

/// 一份美化最终生效的那一段 CSS（网页版 skin.js 的 compile，ARCHITECTURE 4.111、4.615、4.955）。
///
/// 次序与网页版相同：
///
///     :root { 令牌与头像形状的变量 }
///     头像框（.msg-face::after）
///     生成器编出来的那一段（SkinGen.emit，网页版 skin-gen.js 原样跑；带 !important）
///     手写 CSS
///     手写 CSS 之后又动过令牌或生成器（late）：变量再写一遍（:root:root），生成器那一段每条选择器前面加 :not(#skin-late)
///
/// 会话页、编辑器预览、主题小样、画成图片的部分都只读这一段（`Skins.compiled` 交给 `CssSkin.compile`），只有一条路。
/// 生成器的包不在时（`SkinGen.available` 为假）生成器那一段是空的：`Skins.look` 照旧直接读生成器里原生认得的那几项。
/// 网页版最后还把 @import 挪到最前面（hoistImports）：原生版不载入外部样式表，次序不影响读出来的样式，这一步不做。
extension Skins {
    /// 头像框挂在哪一边（网页版 FRAME_WHO）。选择器是网页版的内部类名，原生版读不懂、不画（还原情况里写明）
    static let frameWho: [(id: String, label: String, sel: String)] = [
        ("both", "双方", ".msg-face"),
        ("char", "仅角色", ".msg:not(.is-mine) .msg-face"),
        ("mine", "仅自己", ".msg.is-mine .msg-face"),
    ]

    /// 框比头像大多少（百分比，网页版 frameScaleOf）
    static func frameScale(_ r: Row) -> Int {
        guard let v = r["frameScale"]?.number ?? r["frameScale"]?.string.flatMap({ Double($0) }), v.isFinite else { return 160 }
        let n = Int(v.rounded())
        if n <= 0 { return 160 }
        return Swift.max(100, Swift.min(300, n))
    }

    static func frameCss(_ r: Row) -> String {
        let url = r.string("frame")
        guard imgOk(url) else { return "" }
        let sel = (frameWho.first { $0.id == r.string("frameWho") } ?? frameWho[0]).sel
        let pct = frameScale(r)
        return "\(sel){position:relative}\n"
            + "\(sel)::after{content:'';position:absolute;left:50%;top:50%;"
            + "transform:translate(-50%,-50%);width:\(pct)%;height:\(pct)%;"
            + "background:url(\"\(url)\") center/contain no-repeat;pointer-events:none}"
    }

    /// 令牌与头像形状写成的变量（网页版 compile 的 vars）。值四舍五入（同网页版 Math.round）
    static func tokenVars(_ r: Row) -> [String] {
        var out: [String] = []
        for t in tokens {
            guard let raw = r["tokens"]?.object?[t.id], !raw.isNull, raw.string != "" else { continue }
            let n = raw.number ?? raw.string.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? .nan
            out.append("\(t.css):\(jsRound(n))px")
        }
        let shapeCss = ["round": "50%", "square": "4px", "soft": "10px"]
        if let c = shapeCss[r.string("shape")] { out.append("--ph-avatar-r:\(c)") }
        return out
    }

    /// Math.round 写成字符串：整数不带小数点；NaN 写 NaN（与网页版拼出来的一样）
    private static func jsRound(_ v: Double) -> String {
        guard v.isFinite else { return "NaN" }
        let n = (v + 0.5).rounded(.down)
        if n == 0 { return "0" }
        return abs(n) < 1e15 ? String(Int(n)) : String(format: "%.0f", n)
    }

    /// 生成器那一段每条规则的选择器前面加一层（网页版 boost）。只认单独一行、以 { 结尾的选择器行
    static func boost(_ css: String, _ pre: String) -> String {
        css.components(separatedBy: "\n").map { line in
            guard line.hasSuffix("{"), let first = line.unicodeScalars.first,
                  !CharacterSet.whitespacesAndNewlines.contains(first), first != "/" else { return line }
            let sel = String(line.dropLast())
            guard !sel.contains("{") else { return line }
            return sel.components(separatedBy: ",").map { pre + $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", ") + " {"
        }.joined(separator: "\n")
    }

    /// 这一份最终生效的 CSS。gen 给了就用它代替这一行存着的生成器设置（编辑器的草稿）
    static func effectiveCss(_ r: Row, gen draft: JSONValue? = nil) -> String {
        var out: [String] = []
        let vars = tokenVars(r)
        if !vars.isEmpty { out.append(":root{\(vars.joined(separator: ";"))}") }
        let frame = frameCss(r)
        if !frame.isEmpty { out.append(frame) }
        let made = SkinGen.shared.emit(draft ?? r["gen"]) ?? ""
        if !made.isEmpty { out.append(made) }
        let css = r.string("css").trimmingCharacters(in: .whitespacesAndNewlines)
        if !css.isEmpty { out.append(css) }
        // 草稿：按存下去之后的样子算 late（网页版 draftOf，4.955）
        var late = r["late"]?.bool == true
        if let draft, !css.isEmpty, draft != (r["gen"] ?? .object([:])) { late = true }
        if !css.isEmpty && late {
            if !vars.isEmpty { out.append(":root:root{\(vars.joined(separator: ";"))}") }
            if !made.isEmpty { out.append(boost(made, ":not(#skin-late) ")) }
        }
        return out.joined(separator: "\n")
    }
}
