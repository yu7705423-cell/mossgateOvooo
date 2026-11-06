import SwiftUI

/// 聊天主题（原生版自己的，用户 2026-11-06 定的：会话页原生渲染时用原生主题，像 QQ、微信的主题那样由一组格子组成，
/// 用户挑、用户调，不写 CSS；写 CSS 的完整 DIY 另走网页渲染，不在这里）。
///
/// **数据只存一处，与网页版的美化同一个概念**：主题就是 skins 这一域里的一行（网页版 system/skin.js 的美化），
/// 挂哪一份照旧记在 chat.skinId，全部会话的默认照旧记在 settings.globalSkinId，总开关照旧是 settings.skinOff。
/// 原生主题的格子写在这一行的 `native` 字段里（网页版不认得这一项，原样带着、不显示）；网页版美化的令牌、生成器、
/// 手写 CSS 照旧在原来的字段里，由 `Skins.look` 与 `CssSkin.compile` 读。内置的几套写在代码里（id 以 builtin- 开头），
/// 不进库，要改先复制一份。
///
///     native: { v: 1,
///       look:     { scheme: '' | light | dark }                       始终浅色 / 始终深色；不写跟随系统
///       palette:  { bg, surface, text, text2, accent }                底色、浮层（角色气泡、输入框）、文字、次要文字、主色（我的气泡）
///       wall:     { image, blur, dim }                                 聊天背景图（图片 id）、模糊、遮罩
///       mine / theirs: { fill, text, radius, tail, border, borderWidth, padX, padY }
///       avatar:   { shape: round | square | soft, size, show: both | theirs | mine | none }
///       spacing:  { gap, gapIn }
///       nav / composer: { style: solid | clear | glass, color, alpha, fg: light | dark }，composer 另有 input（输入框底色）
///       font:     { family: system | serif | rounded, scale, size }    字体、整体缩放、气泡字号
///       stamp:    { color, size }                                      消息时刻、已读
///       sys:      { color, fill }                                      时间分隔行与旁白
///       status:   { fill, text, radius, border }                       状态栏那一块
///       dark:     { 以上任意几组 }                                     深色时叠在上面的那几项
///     }
///
/// **只有一条路**：会话页只读 `resolve` 算出来的那一份（`Resolved`），里面是三样东西 ——
/// `Skins.Look`（气泡尺寸、头像、间距）、`CssCompiled`（经 \.phSkin 往下传、各处 `.phStyle` 照着画的样式）、
/// `ChatLook.Look`（背景与上下栏）。网页版美化读出来的样子与原生主题的格子落进同样这三样里，层叠的先后：
///
///     应用默认 → 网页版 CSS 的公开变量（--ph-bg、--ph-accent……，垫在最底下）→ 网页版的令牌、手写 CSS、生成器（照旧）
///              → 这一份的原生格子（用户在原生版里亲手调的，盖过前面全部）
///
/// 挂在会话上的一份与全部会话的默认只取一份（会话挂了就用会话的，没挂才用默认，同 `Skins.of`）；
/// 这段会话自己的聊天背景与上下栏（chat.look，「聊天背景」那一页）设过的那几项再盖过主题。
/// 总开关关着时两层都不用，会话页回到应用本来的样子（网页版第 18 条的逃生口）。设置 app 从不套主题。
enum ChatTheme {
    static let field = "native"
    static let version = 1
    static let builtinPrefix = "builtin-"
    /// 气泡小尾巴记在样式的 raw 里（CssBoxShape 读它画）：left、right
    static let tailKey = "eira-tail"

    // MARK: - 格子的定义

    enum Kind: Equatable {
        /// #RRGGBB 或 #RRGGBBAA
        case color
        /// 只认 #RRGGBB（上下栏、底色：系统顶栏与背景不收透明）
        case solid
        case number(Double, Double)
        case flag
        case choice([String])
        /// 本机图片 id
        case image
    }

    struct Def {
        let group: String
        let key: String
        let kind: Kind
        var path: String { "\(group).\(key)" }
    }

    private static func bubbleDefs(_ g: String) -> [Def] {
        [Def(group: g, key: "fill", kind: .color), Def(group: g, key: "text", kind: .color),
         Def(group: g, key: "radius", kind: .number(0, 40)), Def(group: g, key: "tail", kind: .flag),
         Def(group: g, key: "border", kind: .color), Def(group: g, key: "borderWidth", kind: .number(0, 4)),
         Def(group: g, key: "padX", kind: .number(2, 32)), Def(group: g, key: "padY", kind: .number(2, 28))]
    }

    private static func barDefs(_ g: String) -> [Def] {
        [Def(group: g, key: "style", kind: .choice(["solid", "clear", "glass"])), Def(group: g, key: "color", kind: .solid),
         Def(group: g, key: "alpha", kind: .number(0, 100)), Def(group: g, key: "fg", kind: .choice(["light", "dark"]))]
    }

    /// 全部格子。只加不改：一经发布不改名（同网页版第 18 条的精神）
    static let defs: [Def] = [
        Def(group: "look", key: "scheme", kind: .choice(["light", "dark"])),
        Def(group: "palette", key: "bg", kind: .solid), Def(group: "palette", key: "surface", kind: .color),
        Def(group: "palette", key: "text", kind: .color), Def(group: "palette", key: "text2", kind: .color),
        Def(group: "palette", key: "accent", kind: .color),
        // 主色上的字：编辑页不列（按主色的明暗自动取黑或白），网页版的 --ph-on-accent 读进来落在这里
        Def(group: "palette", key: "onAccent", kind: .color),
        Def(group: "wall", key: "image", kind: .image), Def(group: "wall", key: "blur", kind: .number(0, 40)),
        Def(group: "wall", key: "dim", kind: .number(0, 90)),
    ] + bubbleDefs("mine") + bubbleDefs("theirs") + [
        Def(group: "avatar", key: "shape", kind: .choice(["round", "square", "soft"])),
        Def(group: "avatar", key: "size", kind: .number(24, 64)),
        Def(group: "avatar", key: "show", kind: .choice(["both", "theirs", "mine", "none"])),
        Def(group: "spacing", key: "gap", kind: .number(0, 48)), Def(group: "spacing", key: "gapIn", kind: .number(0, 24)),
    ] + barDefs("nav") + barDefs("composer") + [
        Def(group: "composer", key: "input", kind: .color),
        Def(group: "font", key: "family", kind: .choice(["system", "serif", "rounded"])),
        Def(group: "font", key: "scale", kind: .number(0.8, 1.4)), Def(group: "font", key: "size", kind: .number(11, 24)),
        Def(group: "stamp", key: "color", kind: .color), Def(group: "stamp", key: "size", kind: .number(9, 16)),
        Def(group: "sys", key: "color", kind: .color), Def(group: "sys", key: "fill", kind: .color),
        Def(group: "status", key: "fill", kind: .color), Def(group: "status", key: "text", kind: .color),
        Def(group: "status", key: "radius", kind: .number(0, 24)), Def(group: "status", key: "border", kind: .color),
    ]

    static func def(_ path: String) -> Def? { defs.first { $0.path == path } }

    /// 颜色写成 #RRGGBB / #RRGGBBAA（大写）。#rgb 展开；认不出为 nil
    static func normHex(_ s: String?, solid: Bool = false) -> String? {
        guard var h = s?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return nil }
        h.removeFirst()
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || (!solid && h.count == 8), h.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + h.uppercased()
    }

    /// 一个值按格子的类型核过：不合规的当没写
    static func valid(_ v: JSONValue?, _ kind: Kind) -> JSONValue? {
        guard let v, !v.isNull else { return nil }
        switch kind {
        case .color: return normHex(v.string).map { JSONValue.string($0) }
        case .solid: return normHex(v.string, solid: true).map { JSONValue.string($0) }
        case .number(let lo, let hi):
            let raw = v.number ?? v.string.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard let num = raw, num.isFinite else { return nil }
            return .number(min(hi, max(lo, num)))
        case .flag: return v.bool.map { JSONValue.bool($0) }
        case .choice(let list):
            guard let c = v.string, list.contains(c) else { return nil }
            return .string(c)
        case .image:
            guard let s = v.string, !s.isEmpty, s.count <= 120,
                  s.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
            return .string(s)
        }
    }

    // MARK: - 一份主题读出来的格子

    /// 拍平的格子：键为「组.项」，值都核过
    struct Slots: Equatable {
        var v: [String: JSONValue] = [:]

        func color(_ k: String) -> String? { v[k]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        func num(_ k: String) -> Double? { v[k]?.number }
        func int(_ k: String) -> Int? { num(k).map { Int($0.rounded()) } }
        func flag(_ k: String) -> Bool? { v[k]?.bool }
        func choice(_ k: String) -> String { v[k]?.string ?? "" }
        func has(_ group: String) -> Bool { v.keys.contains { $0.hasPrefix(group + ".") } }
        var isEmpty: Bool { v.isEmpty }

        /// 上面那一层写了的盖过这一层
        func overlay(_ top: Slots) -> Slots {
            var out = self
            out.v.merge(top.v) { _, b in b }
            return out
        }
    }

    /// 一个对象（native 或 native.dark）里认得的那几格，拍平
    static func flatten(_ o: [String: JSONValue]?) -> Slots {
        var s = Slots()
        guard let o else { return s }
        for d in defs {
            if let v = valid(o[d.group]?.object?[d.key], d.kind) { s.v[d.path] = v }
        }
        return s
    }

    /// 一行里的原生格子。dark 为真时叠上 native.dark
    static func slots(_ row: Row?, dark: Bool) -> Slots {
        guard let o = row?[field]?.object else { return Slots() }
        let base = flatten(o)
        return dark ? base.overlay(flatten(o["dark"]?.object)) : base
    }

    /// 网页版美化 CSS 的公开变量落到同样的格子上（网页版 tokens.css：--bg、--surface、--text、--accent 都先取 --ph-* 那一个）。
    /// 气泡的尺寸、头像、间距那几个变量照旧由 `Skins.applyVars` 读，这里只管颜色与状态栏
    static func slots(vars: [String: String]) -> Slots {
        var s = Slots()
        guard !vars.isEmpty else { return s }
        func color(_ name: String, _ path: String, solid: Bool = false) {
            guard let raw = vars[name], let c = CssVal.color(raw.replacingOccurrences(of: "!important", with: ""), CssValueContext()) else { return }
            if solid && c.a < 0.999 { return }
            s.v[path] = .string(hex(c, alpha: !solid))
        }
        color("ph-bg", "palette.bg", solid: true)
        color("ph-surface", "palette.surface")
        color("ph-text", "palette.text")
        color("ph-text-3", "palette.text2")
        color("ph-accent", "palette.accent")
        color("ph-on-accent", "palette.onAccent")
        color("ph-status-bg", "status.fill")
        color("ph-status-fg", "status.text")
        color("ph-status-bc", "status.border")
        if let r = vars["ph-status-r"].flatMap(Skins.cssPx) { s.v["status.radius"] = .number(min(24, max(0, r))) }
        return s
    }

    static func hex(_ c: CssColor, alpha: Bool = true) -> String {
        func h(_ v: Double) -> String { String(format: "%02X", Int((max(0, min(1, v)) * 255).rounded())) }
        let base = "#" + h(c.r) + h(c.g) + h(c.b)
        return alpha && c.a < 0.999 ? base + h(c.a) : base
    }

    private static func cssColor(_ hex: String) -> CssColor? { CssVal.hex(String(hex.dropFirst())) }

    /// 一个底色上的字取黑还是白（同 Palette 的算法：白字对比度不到 3.2 换黑字）
    static func contrast(_ hex: String) -> String {
        guard let c = cssColor(hex) else { return "#FFFFFF" }
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let lum = 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        return 1.05 / (lum + 0.05) < 3.2 ? "#000000" : "#FFFFFF"
    }

    // MARK: - 格子落成会话页读的那三样

    /// 一种外观（浅色或深色）下的那一份
    struct Face: Equatable {
        /// 经 \.phSkin 往下传。nil 为没有任何样式，各处照原样画
        var css: CssCompiled?
        var skin = Skins.Look()
        var look = ChatLook.Look()
    }

    private static func put(_ out: inout [CssKey: CssStyle], _ hook: CssHook, _ f: (inout CssStyle) -> Void) {
        let k = CssKey(hook: hook)
        var st = out[k] ?? CssStyle()
        f(&st)
        out[k] = st
    }

    private static func fill(_ hex: String) -> CssBackground? {
        cssColor(hex).map { CssBackground(layers: [.color($0)]) }
    }

    static func family(_ id: String) -> [String]? {
        switch id {
        case "serif": return ["serif"]
        case "rounded": return ["ui-rounded"]
        default: return nil
        }
    }

    /// 格子翻成钩子上的样式。over 为真：用户在原生版亲手调的那一份，气泡的底色、字色、圆角、内距、字号按生成器的规矩
    /// 写进 Skins.Look（盖过手写 CSS 与画好的底图），其余写成样式叠在最上面；
    /// over 为假：网页版 CSS 变量读出来的那一份，一律写成样式垫在手写 CSS 下面
    static func compile(_ s: Slots, over: Bool, skin: inout Skins.Look) -> [CssKey: CssStyle] {
        var out: [CssKey: CssStyle] = [:]
        let scale = s.num("font.scale") ?? 1
        let fam = family(s.choice("font.family"))
        let accent = s.color("palette.accent")

        for mine in [true, false] {
            let side = mine ? "mine" : "theirs"
            let hook: CssHook = "bubble-" + side
            let fillHex: String? = s.color("\(side).fill") ?? (mine ? accent : s.color("palette.surface"))
            // 字色：写了的；我的一边用主色上的字（网页版 --ph-on-accent），角色那一边用文字色；都没有按底色取黑或白
            var textHex: String? = s.color("\(side).text")
            if textHex == nil {
                if mine {
                    if s.color("mine.fill") == nil { textHex = s.color("palette.onAccent") }
                } else {
                    textHex = s.color("palette.text")
                }
            }
            if textHex == nil, let f = fillHex { textHex = contrast(f) }
            if over {
                var b = skin.bubble(mine)
                if let fillHex { b.bg = fillHex }
                if let textHex { b.fg = textHex }
                if let r = s.num("\(side).radius") { b.radius = CGFloat(r); b.fixed.insert("r") }
                if let p = s.num("\(side).padX") { b.padX = CGFloat(p); b.fixed.insert("px") }
                if let p = s.num("\(side).padY") { b.padY = CGFloat(p); b.fixed.insert("py") }
                if s.num("font.size") != nil || scale != 1 {
                    b.font = CGFloat(s.num("font.size") ?? Double(b.font)) * CGFloat(scale)
                    b.fixed.insert("fs")
                }
                if mine { skin.mine = b } else { skin.theirs = b }
            } else {
                if let fillHex, let bg = fill(fillHex) { put(&out, hook) { $0.background = bg } }
                if let textHex, let c = cssColor(textHex) { put(&out, hook) { $0.color = c } }
            }
            if let bc = s.color("\(side).border").flatMap(cssColor) {
                let w = s.num("\(side).borderWidth") ?? 1
                if w > 0 { put(&out, hook) { $0.border = CssBorder(width: w, color: bc) } }
            }
            if let fam { put(&out, hook) { $0.fontFamily = fam } }
            if s.flag("\(side).tail") == true {
                put(&out, hook + "-tail") { $0.raw[tailKey] = mine ? "right" : "left" }
            }
        }

        if over {
            switch s.choice("avatar.shape") {
            case "round": skin.avatarRound = 0.5; skin.avatarRadiusPx = nil
            case "square": skin.avatarRound = 4 / Theme.avatarSize; skin.avatarRadiusPx = nil
            case "soft": skin.avatarRound = 10 / Theme.avatarSize; skin.avatarRadiusPx = nil
            default: break
            }
            if let n = s.num("avatar.size") { skin.avatarSize = CGFloat(n) }
            let show = s.choice("avatar.show")
            if !show.isEmpty { skin.show = show }
            if let n = s.num("spacing.gap") { skin.gap = CGFloat(n) }
            if let n = s.num("spacing.gapIn") { skin.gapIn = CGFloat(n) }

            // 消息时刻与已读
            let stampHex = s.color("stamp.color") ?? s.color("palette.text2")
            let stampSize = s.num("stamp.size") ?? (scale != 1 ? 11 : nil)
            if stampHex != nil || stampSize != nil || fam != nil {
                for h in ["stamp", "read"] {
                    put(&out, h) {
                        if let c = stampHex.flatMap(cssColor) { $0.color = c }
                        if let n = stampSize { $0.fontSize = n * scale }
                        if let fam { $0.fontFamily = fam }
                    }
                }
            }
            // 时间分隔行：有底色时画成一枚胶囊
            let sysHex = s.color("sys.color") ?? s.color("palette.text2")
            let sysFill = s.color("sys.fill")
            if sysHex != nil || sysFill != nil || scale != 1 || fam != nil {
                put(&out, "time-sep") {
                    if let c = sysHex.flatMap(cssColor) { $0.color = c }
                    if let f = sysFill, let bg = fill(f) {
                        $0.background = bg
                        $0.padding = CssEdges(top: 2, right: 8, bottom: 2, left: 8)
                        $0.radius = 999
                    }
                    if scale != 1 { $0.fontSize = 12 * scale }
                    if let fam { $0.fontFamily = fam }
                }
            }
            // 输入框
            if let inputHex = s.color("composer.input") ?? s.color("palette.surface"), let bg = fill(inputHex) {
                put(&out, "composer-input") {
                    $0.background = bg
                    if let c = s.color("palette.text").flatMap(cssColor) { $0.color = c }
                }
            }
            if let fam {
                put(&out, "composer-input") { $0.fontFamily = fam }
                put(&out, "nav-title") { $0.fontFamily = fam }
            }
            // 消息列表的底：盖过网页版 CSS 写的 .ph-chat-body
            if let bg = s.color("palette.bg").flatMap(fill) { put(&out, "chat-body") { $0.background = bg } }
        }

        // 状态栏那一块
        if s.has("status") {
            put(&out, "status") {
                if let bg = s.color("status.fill").flatMap(fill) { $0.background = bg }
                if let c = s.color("status.text").flatMap(cssColor) { $0.color = c }
                if let r = s.num("status.radius") { $0.radius = r }
                if let c = s.color("status.border").flatMap(cssColor) { $0.border = CssBorder(width: 1, color: c) }
            }
        }
        return out
    }

    /// 一栏（顶栏、输入栏）：格子里写了的、底色、强制的深浅。都没有为没设过（应用本来的样子）
    static func bar(_ s: Slots, _ group: String, base: String, forcedFg: String) -> ChatLook.Bar? {
        let written = s.color("\(group).color") != nil || !s.choice("\(group).style").isEmpty
            || s.num("\(group).alpha") != nil || !s.choice("\(group).fg").isEmpty
        guard written || !base.isEmpty || !forcedFg.isEmpty else { return nil }
        var b = ChatLook.Bar()
        let st = s.choice("\(group).style")
        b.style = st.isEmpty ? "solid" : st
        b.color = s.color("\(group).color") ?? base
        b.alpha = s.int("\(group).alpha") ?? 70
        let fg = s.choice("\(group).fg")
        b.fg = fg.isEmpty ? forcedFg : fg
        return b.isSet ? b : nil
    }

    /// 背景与上下栏：这段会话自己设过的（own）在上，主题的格子在下。
    /// 上下栏只听原生格子（native）：网页版 CSS 的变量只给底色（under），不把系统顶栏换成实色，免得盖掉 CSS 自己画的顶栏
    static func look(_ own: ChatLook.Look, under: Slots = Slots(), native s: Slots) -> ChatLook.Look {
        var l = own
        let nativeBase = s.color("palette.bg") ?? ""
        l.base = nativeBase.isEmpty ? (under.color("palette.bg") ?? "") : nativeBase
        if own.bg.isEmpty, let img = s.color("wall.image") {
            l.bg = img
            l.veil = s.int("wall.dim") ?? 0
            l.blur = s.int("wall.blur") ?? 0
        }
        let scheme = s.choice("look.scheme")
        let forcedFg = scheme == "dark" ? "light" : scheme == "light" ? "dark" : ""
        if !own.top.isSet, let b = bar(s, "nav", base: nativeBase, forcedFg: forcedFg) { l.top = b }
        if !own.bottom.isSet, let b = bar(s, "composer", base: nativeBase, forcedFg: forcedFg) { l.bottom = b }
        if own.narr.isEmpty, let c = s.color("sys.color") { l.narr = String(c.prefix(7)) }
        return l
    }

    /// 一行（网页版美化、原生主题或两样都有）在一种外观下落成的那一份。web 为这一行的手写 CSS 读出来的（已按外观叠好深色规则）
    static func face(row: Row?, web: CssCompiled?, own: ChatLook.Look, dark: Bool) -> Face {
        var f = Face()
        f.skin = Skins.look(row, css: web)
        let under = slots(vars: web?.vars ?? [:])
        let native = slots(row, dark: dark)
        var styles = compile(under, over: false, skin: &f.skin)
        for (k, st) in web?.styles ?? [:] { styles[k] = CssStyle.merge(styles[k], st) }
        for (k, st) in compile(native, over: true, skin: &f.skin) { styles[k] = CssStyle.merge(styles[k], st) }
        if web != nil || !styles.isEmpty {
            var c = web ?? CssCompiled()
            c.styles = styles
            f.css = c
        }
        f.look = look(own, under: under, native: native)
        return f
    }

    // MARK: - 挂哪一份

    struct Resolved: Equatable {
        /// 用的那一行（内置的也是一行，不在库里）。nil 为没有主题
        var row: Row?
        /// chat：挂在这段会话上；global：全部会话的默认；空为没有
        var source = ""
        var light = Face()
        var dark = Face()
        /// 始终浅色 / 始终深色；空为跟随系统
        var scheme = ""
        /// 结构写法用到的后缀（网页版 CSS 里的，加上原生主题的小尾巴）
        var structUse: Set<String> = []
        /// 这一行有手写 CSS（要请画图的一边画格子表达不了的部分）
        var webCss = false

        func face(dark isDark: Bool) -> Face { isDark ? dark : light }
    }

    static func isBuiltin(_ id: String) -> Bool { id.hasPrefix(builtinPrefix) }

    /// 按 id 取一份：内置的从代码里取，其余从库里取
    static func row(_ id: String) -> Row? {
        guard !id.isEmpty else { return nil }
        if isBuiltin(id) { return builtins.first { $0.id == id } }
        return Skins.get(id)
    }

    static func scopes(_ r: Row) -> [String] {
        r["scope"]?.array?.compactMap(\.string) ?? (r["scope"]?.string.map { [$0] } ?? [])
    }

    /// 这段会话用哪一份：挂着的那一份；没挂用默认的那一份（库里的要带 shell 这一档，同网页版 isGlobal）。总开关关着时两层都不用
    static func pick(_ chat: Chat?, settings s: AppSettings) -> (row: Row?, source: String) {
        if s.raw["skinOff"]?.bool == true { return (nil, "") }
        if let id = chat?.row.string("skinId"), let r = row(id) { return (r, "chat") }
        let gid = s.raw["globalSkinId"]?.string ?? ""
        guard let r = row(gid) else { return (nil, "") }
        if isBuiltin(gid) || scopes(r).contains("shell") { return (r, "global") }
        return (nil, "")
    }

    /// 会话页读的那一份
    static func resolve(_ chat: Chat?, settings s: AppSettings = .load()) -> Resolved {
        let own = chat.map(ChatLook.of) ?? ChatLook.Look()
        let p = pick(chat, settings: s)
        return resolve(row: p.row, own: own, source: p.source)
    }

    /// 一行单独算（编辑页的预览、主题列表的小样也走这里）
    static func resolve(row: Row?, own: ChatLook.Look = ChatLook.Look(), source: String = "") -> Resolved {
        var out = Resolved()
        out.row = row
        out.source = row == nil ? "" : source
        let builtinOrNone = row.map { isBuiltin($0.id) } ?? true
        let web: CssCompiled? = builtinOrNone ? nil : Skins.compiled(row)
        out.webCss = web != nil
        out.light = face(row: row, web: web, own: own, dark: false)
        out.dark = face(row: row, web: web?.scheme(dark: true), own: own, dark: true)
        out.scheme = slots(row, dark: false).choice("look.scheme")
        var use = CssStructural.used(web)
        for d in [false, true] {
            let sl = slots(row, dark: d)
            if sl.flag("mine.tail") == true || sl.flag("theirs.tail") == true { use.insert("-tail") }
        }
        out.structUse = use
        return out
    }

    // MARK: - 内置的几套（只用中性的黑白灰，网页版第 4 条）

    private static func o(_ pairs: [String: [String: JSONValue]]) -> JSONValue {
        JSONValue.object(pairs.mapValues { JSONValue.object($0) })
    }

    private static func builtin(_ id: String, _ name: String, _ native: [String: [String: JSONValue]], dark: [String: [String: JSONValue]] = [:]) -> Row {
        var n = native.mapValues { JSONValue.object($0) }
        n["v"] = .number(Double(version))
        if !dark.isEmpty { n["dark"] = o(dark) }
        return Row(fields: ["id": .string(builtinPrefix + id), "name": .string(name), "scope": .array([.string("chat")]),
                            field: .object(n)])
    }

    private static func c(_ s: String) -> JSONValue { .string(s) }
    private static func n(_ v: Double) -> JSONValue { .number(v) }

    static let builtins: [Row] = [
        builtin("paper", "纸白", [
            "palette": ["bg": c("#F5F5F5"), "surface": c("#FFFFFF"), "text": c("#1A1A1A"), "text2": c("#8A8A8A"), "accent": c("#1A1A1A")],
            "mine": ["radius": n(18), "tail": .bool(true)],
            "theirs": ["radius": n(18), "tail": .bool(true), "border": c("#E2E2E2"), "borderWidth": n(1)],
            "composer": ["input": c("#FFFFFF")],
        ], dark: [
            "palette": ["bg": c("#0F0F0F"), "surface": c("#1C1C1C"), "text": c("#EDEDED"), "text2": c("#8A8A8A"), "accent": c("#E6E6E6")],
            "theirs": ["border": c("#2A2A2A")],
            "composer": ["input": c("#1C1C1C")],
        ]),
        builtin("graphite", "石墨", [
            "look": ["scheme": c("dark")],
            "palette": ["bg": c("#1B1B1B"), "surface": c("#2A2A2A"), "text": c("#ECECEC"), "text2": c("#9A9A9A"), "accent": c("#D9D9D9")],
            "mine": ["radius": n(12)],
            "theirs": ["radius": n(12)],
            "avatar": ["shape": c("round")],
            "composer": ["input": c("#2A2A2A")],
            "status": ["fill": c("#262626"), "text": c("#CFCFCF")],
        ]),
        builtin("mist", "雾灰", [
            "palette": ["bg": c("#E9E9E9"), "surface": c("#F7F7F7"), "text": c("#222222"), "text2": c("#7A7A7A"), "accent": c("#6E6E6E")],
            "mine": ["radius": n(10)],
            "theirs": ["radius": n(10)],
            "avatar": ["shape": c("soft")],
            "font": ["family": c("rounded")],
            "sys": ["color": c("#6A6A6A"), "fill": c("#D6D6D6")],
        ], dark: [
            "palette": ["bg": c("#161616"), "surface": c("#242424"), "text": c("#E4E4E4"), "text2": c("#8A8A8A"), "accent": c("#8C8C8C")],
            "sys": ["color": c("#A0A0A0"), "fill": c("#2A2A2A")],
        ]),
        builtin("letter", "信笺", [
            "palette": ["bg": c("#FAFAFA"), "surface": c("#FFFFFF"), "text": c("#2B2B2B"), "text2": c("#9A9A9A")],
            "mine": ["fill": c("#EFEFEF"), "text": c("#1F1F1F"), "border": c("#CFCFCF"), "borderWidth": n(1), "radius": n(4)],
            "theirs": ["fill": c("#FFFFFF"), "text": c("#1F1F1F"), "border": c("#CFCFCF"), "borderWidth": n(1), "radius": n(4)],
            "avatar": ["shape": c("square")],
            "font": ["family": c("serif"), "scale": n(1.05)],
        ], dark: [
            "palette": ["bg": c("#121212"), "surface": c("#1A1A1A"), "text": c("#DADADA"), "text2": c("#7A7A7A")],
            "mine": ["fill": c("#262626"), "text": c("#E6E6E6"), "border": c("#3A3A3A")],
            "theirs": ["fill": c("#1A1A1A"), "text": c("#DADADA"), "border": c("#3A3A3A")],
        ]),
        builtin("plain", "素简", [
            "palette": ["bg": c("#FFFFFF")],
            "mine": ["fill": c("#E4E4E4"), "text": c("#111111"), "radius": n(6), "padX": n(10)],
            "theirs": ["fill": c("#F3F3F3"), "text": c("#111111"), "radius": n(6), "padX": n(10)],
            "avatar": ["show": c("none")],
            "spacing": ["gap": n(12)],
        ], dark: [
            "palette": ["bg": c("#000000")],
            "mine": ["fill": c("#2E2E2E"), "text": c("#EEEEEE")],
            "theirs": ["fill": c("#1A1A1A"), "text": c("#EEEEEE")],
        ]),
    ]

    // MARK: - 改

    /// 改一格（dark 为真时改深色那一层）。传 nil 为恢复默认。只动这一格，native 里其余字段（含认不得的）原样留着
    static func set(_ id: String, _ path: String, _ value: JSONValue?, dark: Bool = false) throws {
        guard !isBuiltin(id) else { throw StoreError(message: "内置主题不能修改，请先复制一份") }
        guard let d = def(path) else { throw StoreError(message: "没有这一项：\(path)") }
        let v = value.flatMap { valid($0, d.kind) }
        if value != nil && v == nil { throw StoreError(message: "这个值无法使用") }
        try Skins.update(id) { r in
            var n = r[field]?.object ?? [:]
            if n["v"] == nil { n["v"] = .number(Double(version)) }
            var layer = dark ? (n["dark"]?.object ?? [:]) : n
            var g = layer[d.group]?.object ?? [:]
            if let v { g[d.key] = v } else { g.removeValue(forKey: d.key) }
            layer[d.group] = .object(g)
            if dark { n["dark"] = .object(layer) } else { n = layer }
            r[field] = .object(n)
        }
    }

    /// 一组恢复默认（只清认得的那几项）
    static func reset(_ id: String, group: String, dark: Bool = false) throws {
        guard !isBuiltin(id) else { throw StoreError(message: "内置主题不能修改，请先复制一份") }
        try Skins.update(id) { r in
            var n = r[field]?.object ?? [:]
            var layer = dark ? (n["dark"]?.object ?? [:]) : n
            var g = layer[group]?.object ?? [:]
            for d in defs where d.group == group { g.removeValue(forKey: d.key) }
            layer[group] = .object(g)
            if dark { n["dark"] = .object(layer) } else { n = layer }
            r[field] = .object(n)
        }
    }

    /// 这一格在深色那一层单独写过
    static func darkSet(_ row: Row?, _ path: String) -> Bool {
        guard let d = def(path), let v = row?[field]?["dark"]?[d.group]?[d.key] else { return false }
        return !v.isNull
    }

    /// 新建一份。from 给了就照它抄（内置的只抄格子；库里的整份抄，id 与时间重来）
    @discardableResult
    static func create(name: String, from: Row? = nil) throws -> Row {
        let r = try Skins.create(name: name)
        guard let from else {
            try Skins.update(r.id) { $0[field] = .object(["v": .number(Double(version))]) }
            return Skins.get(r.id) ?? r
        }
        try Skins.update(r.id) { row in
            if isBuiltin(from.id) {
                row[field] = from[field] ?? .object(["v": .number(Double(version))])
            } else {
                for (k, v) in from.fields where !["id", "createdAt", "updatedAt", "name", "nativeRaster"].contains(k) { row[k] = v }
            }
        }
        if !isBuiltin(from.id), !from.string("css").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let id = r.id
            Task { @MainActor in await CssRasterizer.ensure(skinId: id) }
        }
        return Skins.get(r.id) ?? r
    }

    /// 设为全部会话的默认。传空为取消。库里的那一份自动带上 shell 这一档（同网页版 setGlobal）
    static func setGlobal(_ id: String) throws {
        if !id.isEmpty, !isBuiltin(id) {
            guard let r = Skins.get(id) else { throw StoreError(message: "这份主题已不存在") }
            if !scopes(r).contains("shell") {
                try Skins.update(id) { row in
                    let list = scopes(row) + ["shell"]
                    row["scope"] = .array(list.map { JSONValue.string($0) })
                }
            }
        } else if !id.isEmpty, row(id) == nil {
            throw StoreError(message: "这份主题已不存在")
        }
        var s = try AppSettings.loadForWrite()
        s.raw["globalSkinId"] = .string(id)
        try s.save()
        NotificationCenter.default.post(name: .eiraSkinChanged, object: nil)
    }

    /// 应用到全部会话：设为默认；clearChats 为真时一并取下各段会话单独挂的。返回取下了几段
    @discardableResult
    static func applyToAll(_ id: String, clearChats: Bool) throws -> Int {
        try setGlobal(id)
        guard clearChats else { return 0 }
        var n = 0
        for var c in try Repo.chats() where !c.row.string("skinId").isEmpty {
            c.row["skinId"] = .string("")
            c.row.touch()
            try Repo.save(c)
            n += 1
        }
        NotificationCenter.default.post(name: .eiraSkinChanged, object: nil)
        return n
    }

    /// 几段会话单独挂着这一份
    static func usedBy(_ id: String) -> Int { Skins.usedBy(id) }

    // MARK: - 导入导出（本应用自己的美化包格式 phone-skin，加一项 native；网页版读包时不认 native，照常导入其余部分）

    /// 包里的 native：只留认得的格子（别人给的文件不照单全收，同网页版 unpack），背景图以 data: 地址带着（wall.data）
    static func sanitize(_ raw: JSONValue?) -> JSONValue? {
        guard let o = raw?.object else { return nil }
        func layer(_ src: [String: JSONValue]?) -> [String: JSONValue] {
            var out: [String: JSONValue] = [:]
            for (path, v) in flatten(src).v {
                let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
                var g = out[parts[0]]?.object ?? [:]
                g[parts[1]] = v
                out[parts[0]] = .object(g)
            }
            return out
        }
        var n = layer(o)
        // 本机图片 id 到了别人手机上没有意义：只认包里带着的那张图
        if var w = n["wall"]?.object {
            w.removeValue(forKey: "image")
            n["wall"] = w.isEmpty ? nil : JSONValue.object(w)
        }
        if let d = o["wall"]?["data"]?.string, isImageData(d) {
            var w = n["wall"]?.object ?? [:]
            w["data"] = .string(d)
            n["wall"] = .object(w)
        }
        let dark = layer(o["dark"]?.object)
        if !dark.isEmpty { n["dark"] = .object(dark.filter { $0.key != "wall" }) }
        n["v"] = .number(Double(version))
        return .object(n)
    }

    static func isImageData(_ s: String) -> Bool {
        s.range(of: #"^data:image/(png|jpeg|jpg|gif|webp|heic);base64,[A-Za-z0-9+/=]+$"#, options: .regularExpression) != nil
    }

    /// 导出成一段文本（JSON）。字段与网页版 skin.pack 一致，多一项 native；背景图读出来以 data: 地址放进 wall.data
    static func pack(_ row: Row) throws -> String {
        var o: [String: JSONValue] = [
            "kind": .string(Skins.packKind), "version": .number(Double(Skins.packVersion)),
            "name": .string(row.string("name").isEmpty ? "未命名" : row.string("name")),
            "tokens": row["tokens"] ?? .object([:]), "shape": .string(row.string("shape")),
            "scope": .array(scopes(row).filter { $0 == "chat" || $0 == "shell" }.map { JSONValue.string($0) }),
            "gen": row["gen"] ?? .object([:]), "frame": .string(row.string("frame")),
            "frameWho": .string(row.string("frameWho").isEmpty ? "both" : row.string("frameWho")),
            "frameScale": .number(row.number("frameScale") ?? 160), "css": .string(row.string("css")),
        ]
        if (o["scope"]?.array ?? []).isEmpty { o["scope"] = .array([.string("chat")]) }
        if row["late"]?.bool == true { o["late"] = .bool(true) }
        if var n = row[field]?.object {
            if let id = n["wall"]?["image"]?.string, let url = MediaStore.url(.images, id: id), let data = try? Data(contentsOf: url) {
                let ext = url.pathExtension.lowercased()
                let mime = ext == "png" ? "png" : ext == "gif" ? "gif" : ext == "webp" ? "webp" : "jpeg"
                var w = n["wall"]?.object ?? [:]
                w["data"] = .string("data:image/\(mime);base64," + data.base64EncodedString())
                n["wall"] = .object(w)
            }
            if let clean = sanitize(.object(n)) { o[field] = clean }
        }
        let data = try JSONSerialization.data(withJSONObject: JSONValue.object(o).any, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// 导出成一个文件，交给系统的分享
    static func exportFile(_ row: Row) throws -> URL {
        let text = try pack(row)
        let safe = (row.string("name").isEmpty ? "主题" : row.string("name"))
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("theme-export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(safe).json")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// 装包时把 native 里带着的背景图存进本机，换成图片 id。存不下就去掉那张图，其余照装
    static func installNative(_ native: JSONValue?) -> JSONValue? {
        guard var n = native?.object else { return nil }
        if var w = n["wall"]?.object, let d = w["data"]?.string {
            w.removeValue(forKey: "data")
            if let comma = d.firstIndex(of: ","), let data = Data(base64Encoded: String(d[d.index(after: comma)...])),
               let id = try? Images.save(data) {
                w["image"] = .string(id)
            }
            n["wall"] = w.isEmpty ? nil : JSONValue.object(w)
        }
        return .object(n)
    }
}
