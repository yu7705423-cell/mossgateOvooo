import Foundation

// 网页版美化 CSS 的值怎么读：切词、数字与单位、颜色、渐变、阴影、transform。
// 只供 CssSkinParser.swift 用；纯函数，不碰界面，不读文件。
// 全部按 Unicode.Scalar 处理，不用 Character（工程里有同名的 Character 类型）。

/// 读值时的上下文：同一个元素已经知道的字号、字色与尺寸（em、currentColor、百分比要用）
struct CssValueContext {
    var fontSize: Double = 16
    var color: CssColor?
    var width: Double?
    var height: Double?
}

/// 一个长度：像素，或百分比（要等知道元素大小才换得成像素）
enum CssLength: Equatable {
    case px(Double)
    case percent(Double)
}

/// 切词与小工具
enum CssScan {
    typealias S = Unicode.Scalar

    static func str<C: Sequence>(_ a: C) -> String where C.Element == Unicode.Scalar {
        var s = ""
        s.unicodeScalars.append(contentsOf: a)
        return s
    }

    static func isSpace(_ c: S) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}"
    }

    static func isDigit(_ c: S) -> Bool { c.value >= 48 && c.value <= 57 }

    static func isHex(_ c: S) -> Bool {
        isDigit(c) || (c.value >= 65 && c.value <= 70) || (c.value >= 97 && c.value <= 102)
    }

    /// 标识符里能出现的字：字母、数字、- 与 _，以及非 ASCII
    static func isIdent(_ c: S) -> Bool {
        let v = c.value
        return (v >= 97 && v <= 122) || (v >= 65 && v <= 90) || (v >= 48 && v <= 57) || v == 45 || v == 95 || v > 127
    }

    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 在顶层（圆括号、方括号、引号之外）按分隔符切开，每段去掉首尾空白
    static func split(_ s: String, on sep: S) -> [String] {
        var out: [String] = []
        var cur: [S] = []
        var depth = 0
        var quote: S?
        var esc = false
        for c in s.unicodeScalars {
            if esc { cur.append(c); esc = false; continue }
            if c == "\\" { cur.append(c); esc = true; continue }
            if let q = quote {
                cur.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" { quote = c; cur.append(c); continue }
            if c == "(" || c == "[" { depth += 1; cur.append(c); continue }
            if c == ")" || c == "]" { depth = max(0, depth - 1); cur.append(c); continue }
            if depth == 0 && c == sep {
                out.append(trim(str(cur)))
                cur = []
                continue
            }
            cur.append(c)
        }
        out.append(trim(str(cur)))
        return out
    }

    /// 按顶层空白切成词；slash 为 true 时顶层的 `/` 单独成一个词（background、font 简写用）
    static func words(_ s: String, slash: Bool = false) -> [String] {
        var out: [String] = []
        var cur: [S] = []
        var depth = 0
        var quote: S?
        var esc = false
        for c in s.unicodeScalars {
            if esc { cur.append(c); esc = false; continue }
            if c == "\\" { cur.append(c); esc = true; continue }
            if let q = quote {
                cur.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" { quote = c; cur.append(c); continue }
            if c == "(" { depth += 1; cur.append(c); continue }
            if c == ")" { depth = max(0, depth - 1); cur.append(c); continue }
            if depth == 0 && isSpace(c) {
                if !cur.isEmpty { out.append(str(cur)); cur = [] }
                continue
            }
            if depth == 0 && slash && c == "/" {
                if !cur.isEmpty { out.append(str(cur)); cur = [] }
                out.append("/")
                continue
            }
            cur.append(c)
        }
        if !cur.isEmpty { out.append(str(cur)) }
        return out
    }

    /// a[open] 是 `(`，返回与它配对的 `)` 的下标。引号里的括号不算
    static func matchParen(_ a: [S], _ open: Int) -> Int? {
        var depth = 0
        var quote: S?
        var esc = false
        var i = open
        while i < a.count {
            let c = a[i]
            if esc { esc = false; i += 1; continue }
            if c == "\\" { esc = true; i += 1; continue }
            if let q = quote {
                if c == q { quote = nil }
                i += 1
                continue
            }
            if c == "\"" || c == "'" { quote = c }
            else if c == "(" { depth += 1 }
            else if c == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// 整段正好是一个函数调用 `name(args)` 时，返回小写的函数名与括号里的原文
    static func function(_ s: String) -> (name: String, args: String)? {
        let a = Array(trim(s).unicodeScalars)
        guard let open = a.firstIndex(of: "("), open > 0, a.last == ")" else { return nil }
        for c in a[0..<open] where !isIdent(c) { return nil }
        guard let close = matchParen(a, open), close == a.count - 1 else { return nil }
        return (str(a[0..<open]).lowercased(), str(a[(open + 1)..<close]))
    }

    /// 去掉引号并处理转义（`\"`、`\\`、`\A`、`\201C`）。没有引号的原样去转义
    static func unquote(_ s: String) -> String {
        let t = trim(s)
        var a = Array(t.unicodeScalars)
        if a.count >= 2, let f = a.first, (f == "\"" || f == "'"), a.last == f {
            a = Array(a[1..<(a.count - 1)])
        }
        var out: [S] = []
        var i = 0
        while i < a.count {
            let c = a[i]
            if c != "\\" { out.append(c); i += 1; continue }
            i += 1
            guard i < a.count else { break }
            if a[i] == "\n" { i += 1; continue }
            if isHex(a[i]) {
                var j = i
                var hex: [S] = []
                while j < a.count, hex.count < 6, isHex(a[j]) { hex.append(a[j]); j += 1 }
                if j < a.count, isSpace(a[j]) { j += 1 }
                if let v = UInt32(str(hex), radix: 16), let u = Unicode.Scalar(v), v != 0 { out.append(u) }
                i = j
                continue
            }
            out.append(a[i])
            i += 1
        }
        return str(out)
    }

    /// 数字与紧跟的单位（单位转小写）。"1.55" → (1.55, "")，"-3deg" → (-3, "deg")，".5em" → (0.5, "em")
    static func number(_ s: String) -> (value: Double, unit: String)? {
        let a = Array(trim(s).unicodeScalars)
        var i = 0
        if i < a.count, a[i] == "+" || a[i] == "-" { i += 1 }
        var digits = 0
        while i < a.count, isDigit(a[i]) { i += 1; digits += 1 }
        if i < a.count, a[i] == "." {
            i += 1
            while i < a.count, isDigit(a[i]) { i += 1; digits += 1 }
        }
        guard digits > 0 else { return nil }
        if i < a.count, a[i] == "e" || a[i] == "E" {
            var j = i + 1
            if j < a.count, a[j] == "+" || a[j] == "-" { j += 1 }
            if j < a.count, isDigit(a[j]) {
                while j < a.count, isDigit(a[j]) { j += 1 }
                i = j
            }
        }
        var text = str(a[0..<i])
        if text.hasPrefix("+") { text.removeFirst() }
        if text.hasPrefix(".") { text = "0" + text }
        if text.hasPrefix("-.") { text = "-0" + text.dropFirst() }
        guard let v = Double(text), v.isFinite else { return nil }
        let unit = str(a[i...]).lowercased()
        for c in unit.unicodeScalars where !(isIdent(c) || c == "%") { return nil }
        return (v, unit)
    }
}

/// 值的读法
enum CssVal {
    // MARK: 长度、角度、数字

    /// 长度。px、em（按同一元素的字号）、rem（16）、pt、百分比、0；calc() 里只有绝对长度时算得出
    static func length(_ s: String, _ ctx: CssValueContext) -> CssLength? {
        let t = CssScan.trim(s).lowercased()
        if let f = CssScan.function(t) {
            guard f.name == "calc" else { return nil }
            var p = CssCalc(f.args, ctx)
            return p.run().map { CssLength.px($0) }
        }
        guard let n = CssScan.number(t) else { return nil }
        switch n.unit {
        case "": return n.value == 0 ? .px(0) : nil
        case "px": return .px(n.value)
        case "em": return .px(n.value * ctx.fontSize)
        case "rem": return .px(n.value * 16)
        case "pt": return .px(n.value * 4 / 3)
        case "%": return .percent(n.value)
        default: return nil
        }
    }

    /// 只要像素。百分比按 base 换算，没有 base 时读不出
    static func px(_ s: String, _ ctx: CssValueContext, base: Double? = nil) -> Double? {
        switch length(s, ctx) {
        case .px(let v): return v
        case .percent(let p): return base.map { $0 * p / 100 }
        case nil: return nil
        }
    }

    /// 角度，换成度。deg、turn、rad、grad；0 可以不带单位
    static func angle(_ s: String) -> Double? {
        guard let n = CssScan.number(s) else { return nil }
        switch n.unit {
        case "deg": return n.value
        case "turn": return n.value * 360
        case "rad": return n.value * 180 / Double.pi
        case "grad": return n.value * 0.9
        case "": return n.value == 0 ? 0 : nil
        default: return nil
        }
    }

    /// 不带单位的数字，或百分数（换成 0...1 的倍数）
    static func fraction(_ s: String) -> Double? {
        guard let n = CssScan.number(s) else { return nil }
        if n.unit == "%" { return n.value / 100 }
        return n.unit.isEmpty ? n.value : nil
    }

    // MARK: 颜色

    static func color(_ s: String, _ ctx: CssValueContext) -> CssColor? {
        let t = CssScan.trim(s).lowercased()
        if t.isEmpty { return nil }
        if t == "transparent" { return .clear }
        if t == "currentcolor" { return ctx.color ?? CssColor(r: 0, g: 0, b: 0, a: 1) }
        if t.hasPrefix("#") { return hex(String(t.dropFirst())) }
        if let f = CssScan.function(t) {
            switch f.name {
            case "rgb", "rgba": return rgb(f.args)
            case "hsl", "hsla": return hsl(f.args)
            default: return nil
            }
        }
        if let v = named[t] {
            return CssColor(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255,
                            b: Double(v & 0xFF) / 255, a: 1)
        }
        return nil
    }

    static func hex(_ h: String) -> CssColor? {
        let a = Array(h.unicodeScalars)
        guard [3, 4, 6, 8].contains(a.count), a.allSatisfy(CssScan.isHex) else { return nil }
        var digits = a
        if a.count <= 4 {
            digits = []
            for c in a { digits.append(c); digits.append(c) }
        }
        guard let v = UInt64(CssScan.str(digits), radix: 16) else { return nil }
        if digits.count == 8 {
            return CssColor(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                            b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
        }
        return CssColor(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255,
                        b: Double(v & 0xFF) / 255, a: 1)
    }

    /// rgb()/rgba() 的参数：逗号或空格分隔，透明度可写在 `/` 后面
    private static func channels(_ args: String) -> [String] {
        CssScan.words(args.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "/", with: " "))
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    private static func alpha(_ s: String?) -> Double? {
        guard let s else { return 1 }
        if s == "none" { return 0 }
        guard let n = CssScan.number(s) else { return nil }
        if n.unit == "%" { return clamp01(n.value / 100) }
        return n.unit.isEmpty ? clamp01(n.value) : nil
    }

    static func rgb(_ args: String) -> CssColor? {
        let p = channels(args)
        guard p.count == 3 || p.count == 4 else { return nil }
        var ch: [Double] = []
        for i in 0..<3 {
            if p[i] == "none" { ch.append(0); continue }
            guard let n = CssScan.number(p[i]) else { return nil }
            if n.unit == "%" { ch.append(clamp01(n.value / 100)) }
            else if n.unit.isEmpty { ch.append(clamp01(n.value / 255)) }
            else { return nil }
        }
        guard let a = alpha(p.count == 4 ? p[3] : nil) else { return nil }
        return CssColor(r: ch[0], g: ch[1], b: ch[2], a: a)
    }

    static func hsl(_ args: String) -> CssColor? {
        let p = channels(args)
        guard p.count == 3 || p.count == 4 else { return nil }
        var hue: Double
        if let n = CssScan.number(p[0]), n.unit.isEmpty { hue = n.value }
        else if let d = angle(p[0]) { hue = d }
        else { return nil }
        guard let sn = CssScan.number(p[1]), let ln = CssScan.number(p[2]),
              sn.unit == "%" || sn.unit.isEmpty, ln.unit == "%" || ln.unit.isEmpty,
              let a = alpha(p.count == 4 ? p[3] : nil) else { return nil }
        hue = hue.truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let s = clamp01(sn.value / 100), l = clamp01(ln.value / 100)
        func f(_ n: Double) -> Double {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            let m = s * min(l, 1 - l)
            return l - m * max(-1, min(k - 3, 9 - k, 1))
        }
        return CssColor(r: clamp01(f(0)), g: clamp01(f(8)), b: clamp01(f(4)), a: a)
    }

    /// CSS 的具名颜色（常用的全部，加上基本的十六个）
    static let named: [String: UInt32] = [
        "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF,
        "yellow": 0xFFFF00, "orange": 0xFFA500, "purple": 0x800080, "pink": 0xFFC0CB, "gray": 0x808080,
        "grey": 0x808080, "silver": 0xC0C0C0, "maroon": 0x800000, "olive": 0x808000, "lime": 0x00FF00,
        "aqua": 0x00FFFF, "cyan": 0x00FFFF, "teal": 0x008080, "navy": 0x000080, "fuchsia": 0xFF00FF,
        "magenta": 0xFF00FF, "brown": 0xA52A2A, "gold": 0xFFD700, "beige": 0xF5F5DC, "ivory": 0xFFFFF0,
        "khaki": 0xF0E68C, "lavender": 0xE6E6FA, "coral": 0xFF7F50, "salmon": 0xFA8072, "tomato": 0xFF6347,
        "crimson": 0xDC143C, "indigo": 0x4B0082, "violet": 0xEE82EE, "orchid": 0xDA70D6, "plum": 0xDDA0DD,
        "tan": 0xD2B48C, "chocolate": 0xD2691E, "sienna": 0xA0522D, "peru": 0xCD853F, "wheat": 0xF5DEB3,
        "linen": 0xFAF0E6, "snow": 0xFFFAFA, "azure": 0xF0FFFF, "mintcream": 0xF5FFFA, "honeydew": 0xF0FFF0,
        "aliceblue": 0xF0F8FF, "ghostwhite": 0xF8F8FF, "whitesmoke": 0xF5F5F5, "gainsboro": 0xDCDCDC,
        "lightgray": 0xD3D3D3, "lightgrey": 0xD3D3D3, "darkgray": 0xA9A9A9, "darkgrey": 0xA9A9A9,
        "dimgray": 0x696969, "dimgrey": 0x696969, "lightslategray": 0x778899, "slategray": 0x708090,
        "darkslategray": 0x2F4F4F, "skyblue": 0x87CEEB, "lightskyblue": 0x87CEFA, "deepskyblue": 0x00BFFF,
        "lightblue": 0xADD8E6, "powderblue": 0xB0E0E6, "steelblue": 0x4682B4, "royalblue": 0x4169E1,
        "dodgerblue": 0x1E90FF, "cornflowerblue": 0x6495ED, "midnightblue": 0x191970, "darkblue": 0x00008B,
        "mediumblue": 0x0000CD, "slateblue": 0x6A5ACD, "lightcyan": 0xE0FFFF, "turquoise": 0x40E0D0,
        "aquamarine": 0x7FFFD4, "lightgreen": 0x90EE90, "palegreen": 0x98FB98, "darkgreen": 0x006400,
        "forestgreen": 0x228B22, "seagreen": 0x2E8B57, "mediumseagreen": 0x3CB371, "limegreen": 0x32CD32,
        "olivedrab": 0x6B8E23, "yellowgreen": 0x9ACD32, "lightyellow": 0xFFFFE0, "lemonchiffon": 0xFFFACD,
        "goldenrod": 0xDAA520, "darkorange": 0xFF8C00, "orangered": 0xFF4500, "lightsalmon": 0xFFA07A,
        "lightcoral": 0xF08080, "indianred": 0xCD5C5C, "firebrick": 0xB22222, "darkred": 0x8B0000,
        "hotpink": 0xFF69B4, "deeppink": 0xFF1493, "lightpink": 0xFFB6C1, "palevioletred": 0xDB7093,
        "mistyrose": 0xFFE4E1, "lavenderblush": 0xFFF0F5, "seashell": 0xFFF5EE, "oldlace": 0xFDF5E6,
        "antiquewhite": 0xFAEBD7, "bisque": 0xFFE4C4, "peachpuff": 0xFFDAB9, "papayawhip": 0xFFEFD5,
        "blanchedalmond": 0xFFEBCD, "moccasin": 0xFFE4B5, "navajowhite": 0xFFDEAD, "cornsilk": 0xFFF8DC,
        "floralwhite": 0xFFFAF0, "burlywood": 0xDEB887, "rosybrown": 0xBC8F8F, "saddlebrown": 0x8B4513,
        "thistle": 0xD8BFD8, "mediumpurple": 0x9370DB, "darkviolet": 0x9400D3, "darkorchid": 0x9932CC,
        "darkmagenta": 0x8B008B, "mediumorchid": 0xBA55D3, "rebeccapurple": 0x663399,
        "darkslateblue": 0x483D8B, "cadetblue": 0x5F9EA0, "darkcyan": 0x008B8B, "darkturquoise": 0x00CED1,
        "mediumturquoise": 0x48D1CC, "lightseagreen": 0x20B2AA, "darkseagreen": 0x8FBC8F,
        "springgreen": 0x00FF7F, "lawngreen": 0x7CFC00, "chartreuse": 0x7FFF00, "darkkhaki": 0xBDB76B,
        "palegoldenrod": 0xEEE8AA, "darkgoldenrod": 0xB8860B, "darkolivegreen": 0x556B2F,
    ]

    // MARK: 渐变

    /// linear-gradient / repeating-linear-gradient（含 -webkit- 旧写法）。approx 为 true 表示有近似：
    /// 像素位置而元素大小未知、颜色提示被略去
    static func gradient(_ s: String, _ ctx: CssValueContext) -> (gradient: CssGradient, approx: Bool)? {
        guard let f = CssScan.function(s) else { return nil }
        var name = f.name
        let webkit = name.hasPrefix("-webkit-")
        if webkit { name = String(name.dropFirst(8)) }
        let repeating = name == "repeating-linear-gradient"
        guard repeating || name == "linear-gradient" else { return nil }
        var args = CssScan.split(f.args, on: ",").filter { !$0.isEmpty }
        guard !args.isEmpty else { return nil }
        var angleDeg = 180.0
        var approx = false
        let first = args[0].lowercased()
        if first.hasPrefix("to ") || first == "to" {
            guard let a = sideAngle(CssScan.words(first).dropFirst().map { $0 }) else { return nil }
            angleDeg = a
            args.removeFirst()
        } else if let a = angle(first), CssScan.words(first).count == 1, color(first, ctx) == nil {
            angleDeg = webkit ? 90 - a : a
            args.removeFirst()
        } else if webkit, let a = sideAngle(CssScan.words(first)) {
            // 旧写法写的是起点：top 等于 to bottom
            angleDeg = (a + 180).truncatingRemainder(dividingBy: 360)
            args.removeFirst()
        }
        // 像素位置按渐变方向上的那条边换成比例
        let norm = ((angleDeg.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        var axis: Double?
        if norm == 0 || norm == 180 { axis = ctx.height }
        else if norm == 90 || norm == 270 { axis = ctx.width }

        var raw: [(color: CssColor, at: Double?)] = []
        for arg in args {
            let w = CssScan.words(arg)
            guard let ci = w.firstIndex(where: { color($0, ctx) != nil }), let c = color(w[ci], ctx) else {
                // 只有位置没有颜色的是颜色提示，原生版略去
                if w.count == 1, length(w[0], ctx) != nil { approx = true; continue }
                return nil
            }
            var positions: [Double] = []
            for (i, word) in w.enumerated() where i != ci {
                switch length(word, ctx) {
                case .percent(let p)?: positions.append(p / 100)
                case .px(let v)?:
                    if v == 0 { positions.append(0) }
                    else if let axis, axis > 0 { positions.append(v / axis) }
                    else { positions.append(v / 100); approx = true }
                case nil: return nil
                }
            }
            if positions.isEmpty { raw.append((color: c, at: nil)) }
            for p in positions.prefix(2) { raw.append((color: c, at: Optional(p))) }
        }
        guard !raw.isEmpty else { return nil }
        if raw.count == 1 { raw.append((color: raw[0].color, at: nil)) }
        if raw[0].at == nil { raw[0].at = 0 }
        if raw[raw.count - 1].at == nil { raw[raw.count - 1].at = 1 }
        // 位置比前面的小，按前面最大的算（同一位置两种颜色就是硬分界）
        var maxSoFar = raw[0].at ?? 0
        for i in raw.indices {
            if let p = raw[i].at {
                if p < maxSoFar { raw[i].at = maxSoFar } else { maxSoFar = p }
            }
        }
        // 没写位置的，在前后两个有位置的之间平分
        var i = 0
        while i < raw.count {
            if raw[i].at != nil { i += 1; continue }
            let start = i - 1
            var end = i
            while end < raw.count, raw[end].at == nil { end += 1 }
            let a = raw[start].at ?? 0, b = raw[end].at ?? 1
            let n = Double(end - start)
            for k in i..<end { raw[k].at = a + (b - a) * Double(k - start) / n }
            i = end
        }
        let stops = raw.map { CssGradient.Stop(color: $0.color, at: $0.at ?? 0) }
        return (CssGradient(angle: angleDeg, stops: stops, repeating: repeating), approx)
    }

    /// `to` 后面的方位词换成角度
    static func sideAngle(_ words: [String]) -> Double? {
        let set = Set(words.map { $0.lowercased() })
        guard !set.isEmpty, set.count == words.count else { return nil }
        let top = set.contains("top"), bottom = set.contains("bottom")
        let left = set.contains("left"), right = set.contains("right")
        guard set.isSubset(of: ["top", "bottom", "left", "right"]), !(top && bottom), !(left && right) else { return nil }
        switch (top, bottom, left, right) {
        case (true, false, false, false): return 0
        case (false, false, false, true): return 90
        case (false, true, false, false): return 180
        case (false, false, true, false): return 270
        case (true, false, false, true): return 45
        case (false, true, false, true): return 135
        case (false, true, true, false): return 225
        case (true, false, true, false): return 315
        default: return nil
        }
    }

    // MARK: 阴影

    /// box-shadow / text-shadow 的列表。none 为空列表。text 为 true 时不认 inset 与 spread
    static func shadows(_ s: String, _ ctx: CssValueContext, text: Bool) -> [CssShadow]? {
        let t = CssScan.trim(s)
        if t.lowercased() == "none" { return [] }
        var out: [CssShadow] = []
        for layer in CssScan.split(t, on: ",") {
            var inset = false
            var col: CssColor?
            var lens: [Double] = []
            for w in CssScan.words(layer) {
                if let l = length(w, ctx) {
                    guard case .px(let v) = l else { return nil }
                    lens.append(v)
                } else if w.lowercased() == "inset", !text {
                    inset = true
                } else if col == nil, let c = color(w, ctx) {
                    col = c
                } else {
                    return nil
                }
            }
            let maxLens = text ? 3 : 4
            guard lens.count >= 2, lens.count <= maxLens else { return nil }
            out.append(CssShadow(x: lens[0], y: lens[1], blur: lens.count > 2 ? max(0, lens[2]) : 0,
                                 spread: lens.count > 3 ? lens[3] : 0,
                                 color: col ?? ctx.color ?? CssColor(r: 0, g: 0, b: 0, a: 1), inset: inset))
        }
        return out
    }

    // MARK: transform

    /// 平移、旋转、缩放。approx 为 true 表示有读不了而略去的部分，或先旋转缩放再平移（次序不同结果不同）
    static func transform(_ s: String, _ ctx: CssValueContext) -> (transform: CssTransform, approx: Bool)? {
        let t = CssScan.trim(s)
        if t.lowercased() == "none" { return (CssTransform(), false) }
        var tr = CssTransform()
        var approx = false
        var turned = false
        for w in CssScan.words(t) {
            guard let f = CssScan.function(w) else { return nil }
            let a = CssScan.split(f.args, on: ",").flatMap { CssScan.words($0) }
            func len(_ i: Int, _ base: Double?) -> Double? {
                guard i < a.count else { return 0 }
                return px(a[i], ctx, base: base)
            }
            switch f.name {
            case "translate", "translatex", "translatey", "translate3d":
                var x: Double? = 0, y: Double? = 0
                if f.name == "translatey" { y = len(0, ctx.height) }
                else {
                    x = len(0, ctx.width)
                    if f.name != "translatex" { y = len(1, ctx.height) }
                }
                if f.name == "translate3d", a.count > 2 { approx = true }
                if x == nil || y == nil { approx = true }
                if turned { approx = true }
                tr.dx += x ?? 0
                tr.dy += y ?? 0
            case "rotate", "rotatez":
                guard let d = a.first.flatMap(angle) else { return nil }
                tr.rotate += d
                turned = true
            case "scale", "scalex", "scaley", "scale3d":
                guard let sx = a.first.flatMap(fraction) else { return nil }
                let sy: Double? = a.count > 1 ? fraction(a[1]) : Optional(sx)
                guard let sy else { return nil }
                if f.name == "scale" || f.name == "scale3d" { tr.scaleX *= sx; tr.scaleY *= sy }
                else if f.name == "scalex" { tr.scaleX *= sx }
                else { tr.scaleY *= sx }
                turned = true
            default:
                // matrix、skew、透视与三维旋转原生版不认
                approx = true
            }
        }
        return (tr, approx)
    }

    // MARK: 字体

    static func fontWeight(_ s: String) -> Int? {
        switch CssScan.trim(s).lowercased() {
        case "normal": return 400
        case "bold", "bolder": return 700
        case "lighter": return 300
        default:
            guard let n = CssScan.number(s), n.unit.isEmpty, n.value >= 1, n.value <= 1000 else { return nil }
            let r = Int((n.value / 100).rounded()) * 100
            return min(900, max(100, r))
        }
    }

    /// 字号关键字
    static func fontSizeKeyword(_ s: String) -> Double? {
        switch s.lowercased() {
        case "xx-small": return 9
        case "x-small": return 10
        case "small": return 13
        case "medium": return 16
        case "large": return 18
        case "x-large": return 24
        case "xx-large": return 32
        case "xxx-large": return 48
        default: return nil
        }
    }

    static func fontFamily(_ s: String) -> [String]? {
        let list = CssScan.split(s, on: ",").map { CssScan.unquote($0) }.filter { !$0.isEmpty }
        return list.isEmpty ? nil : list
    }

    /// content 的文字。none / normal 返回 nil 且 none 为 true；counter()、attr() 读不出
    static func content(_ s: String) -> (text: String?, none: Bool)? {
        let t = CssScan.trim(s)
        let low = t.lowercased()
        if low == "none" || low == "normal" { return (nil, true) }
        var out = ""
        for w in CssScan.words(t) {
            guard let f = w.unicodeScalars.first, f == "\"" || f == "'" else { return nil }
            out += CssScan.unquote(w)
        }
        return (out, false)
    }

    /// url("...") 里的地址
    static func url(_ s: String) -> String? {
        guard let f = CssScan.function(s), f.name == "url" else { return nil }
        let u = CssScan.unquote(f.args)
        return u.isEmpty ? nil : u
    }
}

/// calc() 里只含绝对长度与数字时算出像素；碰到百分比、视口单位、min()/max() 就算不出
struct CssCalc {
    private var toks: [String] = []
    private var i = 0
    private let ctx: CssValueContext

    init(_ inner: String, _ ctx: CssValueContext) {
        self.ctx = ctx
        let src = inner.lowercased().replacingOccurrences(of: "calc(", with: "(")
        var cur: [Unicode.Scalar] = []
        for c in src.unicodeScalars {
            if c == "(" || c == ")" || c == "*" || c == "/" {
                if !cur.isEmpty { toks.append(CssScan.str(cur)); cur = [] }
                toks.append(CssScan.str([c]))
            } else if CssScan.isSpace(c) {
                if !cur.isEmpty { toks.append(CssScan.str(cur)); cur = [] }
            } else {
                cur.append(c)
            }
        }
        if !cur.isEmpty { toks.append(CssScan.str(cur)) }
    }

    mutating func run() -> Double? {
        guard let v = expr(), i == toks.count else { return nil }
        return v
    }

    private mutating func expr() -> Double? {
        guard var v = term() else { return nil }
        while i < toks.count, toks[i] == "+" || toks[i] == "-" {
            let op = toks[i]
            i += 1
            guard let r = term() else { return nil }
            v = op == "+" ? v + r : v - r
        }
        return v
    }

    private mutating func term() -> Double? {
        guard var v = factor() else { return nil }
        while i < toks.count, toks[i] == "*" || toks[i] == "/" {
            let op = toks[i]
            i += 1
            guard let r = factor() else { return nil }
            if op == "*" { v *= r } else {
                guard r != 0 else { return nil }
                v /= r
            }
        }
        return v
    }

    private mutating func factor() -> Double? {
        guard i < toks.count else { return nil }
        let t = toks[i]
        i += 1
        if t == "(" {
            guard let v = expr(), i < toks.count, toks[i] == ")" else { return nil }
            i += 1
            return v
        }
        guard let n = CssScan.number(t) else { return nil }
        switch n.unit {
        case "", "px": return n.value
        case "em": return n.value * ctx.fontSize
        case "rem": return n.value * 16
        case "pt": return n.value * 4 / 3
        default: return nil
        }
    }
}
