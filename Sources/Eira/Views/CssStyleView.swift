import SwiftUI
import UIKit

/// 照着 `CssStyle` 画（网页版美化 CSS 翻成原生样式的第一步：原生格子）。
///
/// 读：`CssSkin.compile` 把美化包里的 CSS 读成 `CssCompiled`（`Skins.compiled` 按 CSS 原文缓存），
/// 会话页取一次，经环境值 `\.phSkin` 往下传。
/// 画：挂了契约钩子的元素用 `.phStyle(...)` 或 `PhBox`。**没有美化、总开关关着、这个钩子没写样式时一律走原来那条路**，
/// 一个像素都不变：各处都是 `if let 样式 { 新的画法 } else { 原样 }`，原样那一支不经过这里的任何东西。
///
/// 层叠照 CSS：基础钩子在前、具体一边的在后（`.ph-bubble` 之后 `.ph-bubble-mine`），后写的赢；
/// 按下、聚焦的样式叠在平时的上面。原生元素自己的默认样子当作最底下那一层（`PhFallback`），
/// CSS 写了哪一项就只换哪一项，同网页版里作者的规则只盖住自己写到的属性。
///
/// 第一步不画图：背景里的 url(...) 与伪元素上的图一律不画（第二步的事），只有颜色与渐变。

// MARK: - 环境值

private struct PhSkinKey: EnvironmentKey {
    static let defaultValue: CssCompiled? = nil
}

private struct PhRasterEnvKey: EnvironmentKey {
    static let defaultValue: CssRasterSet? = nil
}

extension EnvironmentValues {
    /// 这一页用的美化 CSS 读出来的样子。nil 为没有美化（或总开关关着），各处照原样画
    var phSkin: CssCompiled? {
        get { self[PhSkinKey.self] }
        set { self[PhSkinKey.self] = newValue }
    }

    /// 这一页用的美化里格子表达不了、请 WebKit 画成图的那几块（第二步，`CssRaster`）。
    /// nil 为没有画过（或没有美化），各处照第一步的格子画
    var phRaster: CssRasterSet? {
        get { self[PhRasterEnvKey.self] }
        set { self[PhRasterEnvKey.self] = newValue }
    }
}

// MARK: - 层叠

extension CssStyle {
    /// 两层叠起来：`top` 写了的盖过 `base`（同 CSS 后写的赢）。两者都没有为 nil
    static func merge(_ base: CssStyle?, _ top: CssStyle?) -> CssStyle? {
        guard let top else { return base }
        guard var out = base else { return top }
        if let v = top.background { out.background = v }
        if let v = top.color { out.color = v }
        if let v = top.opacity { out.opacity = v }
        // 圆角的两种写法互斥：后写的是像素就丢掉前面的百分比，反之亦然
        if let v = top.radius { out.radius = v; out.radiusPercent = nil }
        if let v = top.radiusPercent { out.radiusPercent = v; out.radius = nil }
        if let v = top.border { out.border = v }
        if let v = top.borderTop { out.borderTop = v }
        if let v = top.borderBottom { out.borderBottom = v }
        if let v = top.outline { out.outline = v }
        if let v = top.shadows { out.shadows = v }
        if let v = top.textShadows { out.textShadows = v }
        if let v = top.fontSize { out.fontSize = v }
        if let v = top.fontWeight { out.fontWeight = v }
        if let v = top.fontFamily { out.fontFamily = v }
        if let v = top.letterSpacing { out.letterSpacing = v }
        if top.lineHeight != nil || top.lineHeightPx != nil {
            out.lineHeight = top.lineHeight
            out.lineHeightPx = top.lineHeightPx
        }
        if let v = top.textAlign { out.textAlign = v }
        if let v = top.padding { out.padding = v }
        if let v = top.margin { out.margin = v }
        if let v = top.width { out.width = v }
        if let v = top.height { out.height = v }
        if let v = top.minWidth { out.minWidth = v }
        if let v = top.minHeight { out.minHeight = v }
        if let v = top.gap { out.gap = v }
        if let v = top.transform { out.transform = v }
        if let v = top.hidden { out.hidden = v }
        if let v = top.content { out.content = v }
        out.raw.merge(top.raw) { _, b in b }
        return out
    }

    /// 写了任何一项字体（字号、字重、字体）
    var hasFont: Bool { fontSize != nil || fontWeight != nil || fontFamily != nil }

    /// 图标藏起来了（`.ph-X svg { display: none }` 一类，由读 CSS 那一步记在 raw 里）
    var iconHidden: Bool { raw["iconHidden"] == "1" }

    /// 伪元素上要显示的那句话（去掉引号、把 \A 换成换行）。空串、`none`、`normal` 为没有
    var contentText: String? {
        guard let c = content else { return nil }
        let t = CssPaint.contentText(c)
        return t.isEmpty ? nil : t
    }
}

extension CssCompiled {
    /// 几个钩子按先后叠起来（基础的在前），再叠上这一种状态的。一项都没写为 nil
    func resolve(_ hooks: [CssHook], _ state: CssState = .normal, _ part: CssPart = .main) -> CssStyle? {
        var out: CssStyle?
        for h in hooks { out = CssStyle.merge(out, style(h, .normal, part)) }
        if state != .normal {
            for h in hooks { out = CssStyle.merge(out, style(h, state, part)) }
        }
        return out
    }

    /// 这几个钩子在任何一种状态下写过主体样式。决定走新画法还是原样：按它分支，不按状态分支，
    /// 免得按下、聚焦的那一刻换了一棵视图（输入框会因此丢掉焦点）
    func has(_ hooks: [CssHook]) -> Bool {
        hooks.contains { h in CssState.allCases.contains { styles[CssKey(hook: h, state: $0, part: .main)] != nil } }
    }

    /// 某个钩子的伪元素上写的那句话（::before 优先）
    func pseudoText(_ hooks: [CssHook], _ part: CssPart) -> String? {
        resolve(hooks, .normal, part)?.contentText
    }
}

// MARK: - 纯计算（测试直接调这些）

enum CssPaint {
    /// CSS 渐变线的起点与终点（`linear-gradient(角度, ...)`）。
    /// 渐变线过盒子中心，方向为角度（0 朝上、90 朝右），长度取到恰好让两个对角落在 0% 与 100% 上：
    /// |w·sin a| + |h·cos a|。size 为盒子的宽高，不知道时按正方形算
    static func points(angle: Double, size: CGSize = CGSize(width: 1, height: 1)) -> (start: UnitPoint, end: UnitPoint) {
        let w = max(Double(size.width), 0.0001), h = max(Double(size.height), 0.0001)
        let a = angle * .pi / 180
        let sx = sin(a), sy = -cos(a)          // 屏幕坐标里 y 朝下
        let len = abs(w * sin(a)) + abs(h * cos(a))
        let half = len / 2
        let start = UnitPoint(x: (w / 2 - sx * half) / w, y: (h / 2 - sy * half) / h)
        let end = UnitPoint(x: (w / 2 + sx * half) / w, y: (h / 2 + sy * half) / h)
        return (round(start), round(end))
    }

    private static func round(_ p: UnitPoint) -> UnitPoint {
        func r(_ v: CGFloat) -> CGFloat { (v * 1_000_000).rounded() / 1_000_000 }
        return UnitPoint(x: r(p.x), y: r(p.y))
    }

    /// 色标整理成 SwiftUI 收得下的样子：位置夹在 0...1，后一个不早于前一个（同 CSS：小于前一个的按前一个算，
    /// 两个色标同一位置就是硬边）。重复渐变按一个周期铺满 0...1（近似：CSS 是按渐变线长度铺的）
    static func stops(_ g: CssGradient) -> [CssGradient.Stop] {
        var out: [CssGradient.Stop] = []
        var last = 0.0
        for s in g.stops {
            let at = max(last, min(1, max(0, s.at)))
            out.append(CssGradient.Stop(color: s.color, at: at))
            last = at
        }
        guard g.repeating, let first = out.first, let tail = out.last else { return out }
        let start = first.at
        let period = tail.at - start
        guard period > 0.005, tail.at < 1 else { return out }
        var rep: [CssGradient.Stop] = []
        // 周期之前那一段按最后一个周期的样子往回铺，这里只往后铺：作者写的重复渐变几乎都从 0 开始
        var k = 0.0
        while start + k * period < 1, rep.count < 400 {
            for s in out {
                let at = s.at + k * period
                if at > 1 {
                    // 收在 1 上：按这一段的比例插一个颜色
                    if let prev = rep.last, at - prev.at > 0 {
                        let f = (1 - prev.at) / (at - prev.at)
                        rep.append(CssGradient.Stop(color: mix(prev.color, s.color, f), at: 1))
                    }
                    return rep
                }
                rep.append(CssGradient.Stop(color: s.color, at: at))
            }
            k += 1
        }
        return rep
    }

    static func mix(_ a: CssColor, _ b: CssColor, _ f: Double) -> CssColor {
        CssColor(r: a.r + (b.r - a.r) * f, g: a.g + (b.g - a.g) * f, b: a.b + (b.b - a.b) * f, a: a.a + (b.a - a.a) * f)
    }

    /// 圆角：像素按写的，百分比按短边算（CSS 的百分比横竖各按宽高，原生画不出椭圆角，取短边近似）。
    /// 一律不超过短边的一半：50% 及以上画成胶囊或正圆
    static func cornerRadius(px: Double?, percent: Double?, fallback: CGFloat, size: CGSize) -> CGFloat {
        let short = max(0, min(size.width, size.height))
        var r: CGFloat
        if let percent { r = short * CGFloat(max(0, percent)) / 100 }
        else if let px { r = CGFloat(max(0, px)) }
        else { r = fallback }
        r = min(r, short / 2)
        return max(0, r)
    }

    /// 写了 50% 以上：胶囊或正圆
    static func isCapsule(_ s: CssStyle?) -> Bool { (s?.radiusPercent ?? 0) >= 50 }

    /// CSS 的行高换成 SwiftUI 的行距：SwiftUI 默认一行约 1.2 倍字号，多出来的那一截是行距
    static func lineSpacing(_ s: CssStyle?, fontSize: CGFloat) -> CGFloat? {
        guard let s else { return nil }
        if let px = s.lineHeightPx { return max(0, CGFloat(px) - fontSize * 1.2) }
        if let m = s.lineHeight { return max(0, (CGFloat(m) - 1.2) * fontSize) }
        return nil
    }

    static func weight(_ w: Int?) -> Font.Weight {
        switch w ?? 400 {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }

    /// content 的原文：去掉一层引号，`\A` 换成换行，`\"` 还原。none、normal 与空串为空
    static func contentText(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "none" || t == "normal" { return "" }
        if t.count >= 2, let f = t.first, let l = t.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            t = String(t.dropFirst().dropLast())
        }
        t = t.replacingOccurrences(of: "\\A ", with: "\n").replacingOccurrences(of: "\\A", with: "\n")
            .replacingOccurrences(of: "\\a", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\'", with: "'")
        return t
    }

    static func insets(_ e: CssEdges) -> EdgeInsets {
        EdgeInsets(top: CGFloat(e.top), leading: CGFloat(e.left), bottom: CGFloat(e.bottom), trailing: CGFloat(e.right))
    }

    /// 能画的背景层（第一步不画图）：第一层在最上面
    static func drawable(_ b: CssBackground?) -> [CssLayer] {
        (b?.layers ?? []).filter { if case .image = $0 { return false }; return true }
    }
}

// MARK: - 字体

enum CssFonts {
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var misses: Set<String> = []
    private static let lock = NSLock()

    /// 自定义字体有增减时清掉（读美化时顺手清一次）
    static func reset() {
        lock.lock(); cache = [:]; misses = []; lock.unlock()
    }

    enum Pick: Equatable { case custom(String), serif, mono, rounded, system }

    /// font-family 列表里第一个认得的：「外观 - 字体」里加过的（按名字）、系统里装着的、几个通用名
    static func pick(_ families: [String]?) -> Pick {
        for raw in families ?? [] {
            let f = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
            switch f {
            case "": continue
            case "serif", "ui-serif": return .serif
            case "monospace", "ui-monospace": return .mono
            case "ui-rounded": return .rounded
            case "sans-serif", "system-ui", "-apple-system", "ui-sans-serif", "blinkmacsystemfont": return .system
            default:
                if let ps = lookup(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))) { return .custom(ps) }
            }
        }
        return .system
    }

    private static func lookup(_ family: String) -> String? {
        let key = family.lowercased()
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        if misses.contains(key) { lock.unlock(); return nil }
        lock.unlock()
        var found: String?
        if let rec = Fonts.list(AppSettings.load()).first(where: { $0.name.lowercased() == key || $0.id.lowercased() == key }),
           let ps = Fonts.psName(rec) {
            found = ps
        } else if UIFont(name: family, size: 12) != nil {
            found = family
        } else if let first = UIFont.fontNames(forFamilyName: family).first {
            found = first
        }
        lock.lock()
        if let found { cache[key] = found } else { misses.insert(key) }
        lock.unlock()
        return found
    }

    /// 这一项写的字体。没写字号时用 size（元素原本的字号）
    static func font(_ s: CssStyle?, size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let sz = s?.fontSize.map { CGFloat($0) } ?? size
        let w = s?.fontWeight != nil ? CssPaint.weight(s?.fontWeight) : (weight ?? .regular)
        switch pick(s?.fontFamily) {
        case .custom(let ps): return .custom(ps, size: sz).weight(w)
        case .serif: return .system(size: sz, weight: w, design: .serif)
        case .mono: return .system(size: sz, weight: w, design: .monospaced)
        case .rounded: return .system(size: sz, weight: w, design: .rounded)
        case .system: return .system(size: sz, weight: w)
        }
    }
}

// MARK: - 原生元素自己的样子（最底下那一层）

struct PhShadow: Equatable {
    var color: Color
    var radius: CGFloat
    var x: CGFloat = 0
    var y: CGFloat = 0
}

/// 元素原本的样子。CSS 没写的那几项照这里画
struct PhFallback {
    var fill: Color? = nil
    var radius: CGFloat = 0
    var continuous = true
    var padH: CGFloat? = nil
    var padV: CGFloat? = nil
    var fg: Color? = nil
    var shadow: PhShadow? = nil
    var stroke: Color? = nil
    var strokeWidth: CGFloat = 1
    var minWidth: CGFloat? = nil
    var minHeight: CGFloat? = nil
    var alignment: Alignment = .center
    /// 元素原本的字号：CSS 只写了字重或字体时按它
    var fontSize: CGFloat? = nil
}

// MARK: - 形状

/// 盒子的轮廓：像素圆角、百分比圆角（按短边）、或元素原本的圆角
struct CssBoxShape: InsettableShape {
    var px: Double?
    var percent: Double?
    var fallback: CGFloat = 0
    var continuous = false
    var inset: CGFloat = 0

    init(_ s: CssStyle?, fallback: PhFallback) {
        px = s?.radius
        percent = s?.radiusPercent
        self.fallback = fallback.radius
        // 只有沿用原本圆角时才跟着原本的连续曲线；CSS 写的圆角是正圆弧
        continuous = s?.radius == nil && s?.radiusPercent == nil && fallback.continuous
    }

    func path(in rect: CGRect) -> Path {
        let rr = rect.insetBy(dx: inset, dy: inset)
        guard rr.width > 0, rr.height > 0 else { return Path() }
        let r = max(0, CssPaint.cornerRadius(px: px, percent: percent, fallback: fallback, size: rect.size) - inset)
        return Path(roundedRect: rr, cornerRadius: min(r, min(rr.width, rr.height) / 2), style: continuous ? .continuous : .circular)
    }

    func inset(by amount: CGFloat) -> CssBoxShape {
        var s = self
        s.inset += amount
        return s
    }

    /// 往外扩一圈（外框线、阴影的扩散用）
    func grown(_ d: CGFloat) -> CssBoxShape {
        var s = self
        if let p = px { s.px = p + Double(d) } else if percent == nil { s.fallback = fallback + d }
        return s
    }
}

// MARK: - 画一个盒子

/// 照 CSS 画一个盒子：文字样式、内距、尺寸、背景、阴影、边框、外框线、透明度、变换、外边距。
/// 只在这个钩子确实有样式时用；没有样式的地方不要经过它。
///
/// 第二步：传了 hooks 且这一页有画好的图（`\.phRaster`）时，整块背景（底、边框、阴影）换成那张图按九宫格拉伸，
/// ::before / ::after 画成的装饰按各自的位置贴上（z-index 负的贴在底下）。文字样式、内距、尺寸照第一步。
/// 没传 hooks、没有图时与第一步一个像素都不差
struct PhBox: ViewModifier {
    let style: CssStyle
    var fallback = PhFallback()
    /// 这一块挂的钩子（基础的在前，同 `CssCompiled.resolve`）与此刻的状态：找画好的图用。空为不找
    var hooks: [CssHook] = []
    var state: CssState = .normal
    /// 整块背景用不用画好的图（生成器定下了底色、圆角的气泡不用：生成器赢）
    var rasterBox = true
    /// 伪元素的装饰在这里贴不贴（时间分隔行把它们排在字的上下，由调用的一边自己画）
    var rasterDecor = true
    @Environment(\.phRaster) private var raster

    func body(content: Content) -> some View {
        if style.hidden == true {
            EmptyView()
        } else {
            let shape = CssBoxShape(style, fallback: fallback)
            let box = rasterBox ? CssRasterDraw.pick(raster, hooks, state: state, kind: .box) : nil
            let decors = rasterDecor ? CssRasterDraw.decors(raster, hooks, state: state) : []
            content
                .modifier(PhTextLook(style: style, fallback: fallback))
                .padding(insets)
                .frame(width: style.width.map { CGFloat($0) }, height: style.height.map { CGFloat($0) })
                .frame(minWidth: style.minWidth.map { CGFloat($0) } ?? fallback.minWidth,
                       minHeight: style.minHeight.map { CGFloat($0) } ?? fallback.minHeight,
                       alignment: fallback.alignment)
                .background {
                    if let box {
                        // 图还没读出来（或读不到）时照第一步画，不先空一下
                        CssRasterView(image: box) {
                            PhBackground(style: style, fallback: fallback, shape: shape)
                                .overlay { PhEdges(style: style, fallback: fallback, shape: shape) }
                        }
                    } else {
                        PhBackground(style: style, fallback: fallback, shape: shape)
                    }
                }
                .modifier(PhDecors(images: decors.filter(\.below), below: true))
                .overlay {
                    // 画好的图里已经有边框、内阴影
                    if box == nil { PhEdges(style: style, fallback: fallback, shape: shape) }
                }
                .modifier(PhDecors(images: decors.filter { !$0.below }, below: false))
                .opacity(min(1, max(0, style.opacity ?? 1)))
                .modifier(PhTransform(t: style.transform))
                .padding(style.margin.map(CssPaint.insets) ?? EdgeInsets())
        }
    }

    private var insets: EdgeInsets {
        if let p = style.padding { return CssPaint.insets(p) }
        let h = fallback.padH ?? 0, v = fallback.padV ?? 0
        return EdgeInsets(top: v, leading: h, bottom: v, trailing: h)
    }
}

/// 文字：颜色、字体、字距、行距、对齐、文字阴影。作用于里面没有自己定死这几项的 Text
struct PhTextLook: ViewModifier {
    let style: CssStyle
    var fallback = PhFallback()

    func body(content: Content) -> some View {
        let fg = style.color?.color ?? fallback.fg
        let size = fallback.fontSize ?? 15
        let ts = style.textShadows ?? []
        content
            .modifier(PhOptionalForeground(color: fg))
            .modifier(PhOptionalFont(font: style.hasFont ? CssFonts.font(style, size: size) : nil))
            .modifier(PhOptionalKerning(value: style.letterSpacing.map { CGFloat($0) }))
            .modifier(PhOptionalLineSpacing(value: CssPaint.lineSpacing(style, fontSize: CGFloat(style.fontSize ?? Double(size)))))
            .modifier(PhOptionalAlign(align: style.textAlign))
            .modifier(PhOptionalShadow(s: ts.first))
            .modifier(PhOptionalShadow(s: ts.count > 1 ? ts[1] : nil))
    }
}

private struct PhOptionalForeground: ViewModifier {
    let color: Color?
    func body(content: Content) -> some View {
        if let color { content.foregroundStyle(color) } else { content }
    }
}

private struct PhOptionalFont: ViewModifier {
    let font: Font?
    func body(content: Content) -> some View {
        if let font { content.font(font) } else { content }
    }
}

private struct PhOptionalKerning: ViewModifier {
    let value: CGFloat?
    func body(content: Content) -> some View {
        if let value { content.kerning(value) } else { content }
    }
}

private struct PhOptionalLineSpacing: ViewModifier {
    let value: CGFloat?
    func body(content: Content) -> some View {
        if let value { content.lineSpacing(value) } else { content }
    }
}

private struct PhOptionalAlign: ViewModifier {
    let align: String?
    func body(content: Content) -> some View {
        switch align ?? "" {
        case "center": content.multilineTextAlignment(.center)
        case "right", "end": content.multilineTextAlignment(.trailing)
        case "left", "start", "justify": content.multilineTextAlignment(.leading)
        default: content
        }
    }
}

/// 文字阴影：模糊半径按 CSS 的一半给 SwiftUI（CSS 的 blur 约是高斯的两倍标准差）
private struct PhOptionalShadow: ViewModifier {
    let s: CssShadow?
    func body(content: Content) -> some View {
        if let s {
            content.shadow(color: s.color.color, radius: CGFloat(s.blur) / 2, x: CGFloat(s.x), y: CGFloat(s.y))
        } else {
            content
        }
    }
}

private struct PhTransform: ViewModifier {
    let t: CssTransform?
    func body(content: Content) -> some View {
        if let t {
            content
                .scaleEffect(x: CGFloat(t.scaleX), y: CGFloat(t.scaleY))
                .rotationEffect(.degrees(t.rotate))
                .offset(x: CGFloat(t.dx), y: CGFloat(t.dy))
        } else {
            content
        }
    }
}

/// 背景：外阴影在最下面，背景层叠在上面（第一层在最上）。一层能画的都没有时用元素原本的底色。
/// CSS 没写 box-shadow 时沿用元素原本的那道阴影（画在底色上）
struct PhBackground: View {
    let style: CssStyle
    let fallback: PhFallback
    let shape: CssBoxShape

    var body: some View {
        let outer = (style.shadows ?? []).filter { !$0.inset }
        ZStack {
            if !outer.isEmpty { PhOuterShadows(shadows: outer, shape: shape) }
            fills.modifier(PhPlainShadow(s: style.shadows == nil ? fallback.shadow : nil))
        }
    }

    @ViewBuilder private var fills: some View {
        let layers = CssPaint.drawable(style.background)
        if layers.isEmpty {
            if let f = fallback.fill { shape.fill(f) }
        } else {
            ZStack {
                ForEach(Array(layers.reversed().enumerated()), id: \.offset) { _, l in
                    PhLayer(layer: l, shape: shape)
                }
            }
        }
    }
}

private struct PhPlainShadow: ViewModifier {
    let s: PhShadow?
    func body(content: Content) -> some View {
        if let s { content.shadow(color: s.color, radius: s.radius, x: s.x, y: s.y) } else { content }
    }
}

private struct PhLayer: View {
    let layer: CssLayer
    let shape: CssBoxShape

    var body: some View {
        switch layer {
        case .color(let c):
            shape.fill(c.color)
        case .gradient(let g):
            GeometryReader { geo in
                let p = CssPaint.points(angle: g.angle, size: geo.size)
                shape.fill(LinearGradient(stops: CssPaint.stops(g).map { Gradient.Stop(color: $0.color.color, location: CGFloat($0.at)) },
                                          startPoint: p.start, endPoint: p.end))
            }
        case .image:
            EmptyView()
        }
    }
}

/// 外阴影：按扩散放大轮廓、偏移、模糊；盒子里面挖掉（CSS 的阴影不画在盒子底下，半透明的底透不出阴影）
private struct PhOuterShadows: View {
    let shadows: [CssShadow]
    let shape: CssBoxShape

    var body: some View {
        ZStack {
            ForEach(Array(shadows.reversed().enumerated()), id: \.offset) { _, s in
                shape.grown(CGFloat(max(0, s.spread)))
                    .fill(s.color.color)
                    .padding(CGFloat(-s.spread))
                    .offset(x: CGFloat(s.x), y: CGFloat(s.y))
                    .blur(radius: CGFloat(max(0, s.blur)) / 2)
            }
        }
        .mask {
            ZStack {
                Rectangle().padding(-400)
                shape.fill(Color.black).blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}

/// 边框、上下单边、内阴影、外框线（画在盒子外面一圈）
private struct PhEdges: View {
    let style: CssStyle
    let fallback: PhFallback
    let shape: CssBoxShape

    var body: some View {
        ZStack {
            ForEach(Array((style.shadows ?? []).filter(\.inset).enumerated()), id: \.offset) { _, s in
                shape
                    .stroke(s.color.color, lineWidth: max(1, CGFloat(s.blur) + CGFloat(max(0, s.spread)) * 2))
                    .offset(x: CGFloat(s.x), y: CGFloat(s.y))
                    .blur(radius: CGFloat(max(0, s.blur)) / 2)
                    .clipShape(shape)
            }
            if let b = style.border, b.width > 0 {
                shape.strokeBorder(b.color.color, style: Self.stroke(b))
            } else if style.border == nil, let c = fallback.stroke {
                shape.strokeBorder(c, lineWidth: fallback.strokeWidth)
            }
            if let b = style.borderTop, b.width > 0 {
                Rectangle().fill(b.color.color).frame(height: CGFloat(b.width))
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            if let b = style.borderBottom, b.width > 0 {
                Rectangle().fill(b.color.color).frame(height: CGFloat(b.width))
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            if let o = style.outline, o.width > 0 {
                let w = CGFloat(o.width)
                shape.grown(w).strokeBorder(o.color.color, style: Self.stroke(o)).padding(-w)
            }
        }
        .allowsHitTesting(false)
    }

    static func stroke(_ b: CssBorder) -> StrokeStyle {
        let w = CGFloat(b.width)
        switch b.style {
        case "dashed": return StrokeStyle(lineWidth: w, dash: [w * 3, w * 2])
        case "dotted": return StrokeStyle(lineWidth: w, lineCap: .round, dash: [0.1, w * 2])
        default: return StrokeStyle(lineWidth: w)
        }
    }
}

// MARK: - 挂钩子

extension View {
    /// 挂一个契约钩子：这一页的美化给它写了样式就照着画，没写就原样不动（不经过任何额外的修饰）。
    /// fallback 是元素原本的底色、圆角、内距：CSS 没写的那几项照它画。
    /// 只适合原本没有自己画底与内距的元素；原本就画了的，在原处写 `if let 样式 … else 原样`，把原本的样子交给 fallback
    func phStyle(_ hook: CssHook, state: CssState = .normal, fallback: PhFallback = PhFallback()) -> some View {
        modifier(PhHook(hooks: [hook], state: state, fallback: fallback))
    }

    func phStyle(_ hooks: [CssHook], state: CssState = .normal, fallback: PhFallback = PhFallback()) -> some View {
        modifier(PhHook(hooks: hooks, state: state, fallback: fallback))
    }

    /// 按钮：美化给这几个钩子写了样式时换成能读出「按下」的样式（`:active`），否则照旧 `.plain`
    func phButton(_ hooks: [CssHook], fallback: PhFallback = PhFallback()) -> some View {
        modifier(PhButtonIf(hooks: hooks, fallback: fallback))
    }
}

private struct PhHook: ViewModifier {
    let hooks: [CssHook]
    let state: CssState
    let fallback: PhFallback
    @Environment(\.phSkin) private var skin

    func body(content: Content) -> some View {
        if let skin, skin.has(hooks), let st = skin.resolve(hooks, state) {
            content.modifier(PhBox(style: st, fallback: fallback, hooks: hooks, state: state))
        } else {
            content
        }
    }
}

private struct PhButtonIf: ViewModifier {
    let hooks: [CssHook]
    let fallback: PhFallback
    @Environment(\.phSkin) private var skin

    func body(content: Content) -> some View {
        if let skin, skin.has(hooks) {
            content.buttonStyle(PhButtonStyle(hooks: hooks, fallback: fallback))
        } else {
            content.buttonStyle(.plain)
        }
    }
}

/// 读得出「按下」的按钮样式：按下时叠上 `:active` 的那一份
struct PhButtonStyle: ButtonStyle {
    let hooks: [CssHook]
    var fallback = PhFallback()

    func makeBody(configuration: Configuration) -> some View {
        PhButtonBody(label: configuration.label, pressed: configuration.isPressed, hooks: hooks, fallback: fallback)
    }
}

private struct PhButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let hooks: [CssHook]
    let fallback: PhFallback
    @Environment(\.phSkin) private var skin

    var body: some View {
        let st = skin?.resolve(hooks, pressed ? .pressed : .normal) ?? CssStyle()
        label
            // 按下时找 :active 画成的那张，没有就用平时那张
            .modifier(PhBox(style: st, fallback: fallback, hooks: hooks, state: pressed ? .pressed : .normal))
            // CSS 没写按下的样子时，照 .plain 的习惯淡一点，让人知道按到了
            .opacity(pressed && !hooks.contains { skin?.style($0, .pressed) != nil } ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// 原本自己带内距的一块（如底栏 .ph-composer）：没有样式时照原样加内距；有样式时内距交给 CSS 的 padding，没写照原样
struct PhPadded: ViewModifier {
    let hooks: [CssHook]
    let padH: CGFloat
    let padV: CGFloat
    @Environment(\.phSkin) private var skin

    func body(content: Content) -> some View {
        if let skin, skin.has(hooks), let st = skin.resolve(hooks) {
            content.modifier(PhBox(style: st, fallback: PhFallback(padH: padH, padV: padV), hooks: hooks))
        } else {
            content.padding(.horizontal, padH).padding(.vertical, padV)
        }
    }
}

/// 顶栏（.ph-navbar）的底：系统顶栏只收一种填充，取最上面那一层能画的（颜色或渐变）。没有为原样
struct PhNavBar: ViewModifier {
    let style: CssStyle?

    func body(content: Content) -> some View {
        if let paint = style.flatMap(Self.paint) {
            content
                .toolbarBackground(paint, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            content
        }
    }

    static func paint(_ s: CssStyle) -> AnyShapeStyle? {
        guard let top = CssPaint.drawable(s.background).first else { return nil }
        switch top {
        case .color(let c):
            return AnyShapeStyle(c.color)
        case .gradient(let g):
            // 顶栏约是一个横长条：按 4:1 算渐变线
            let p = CssPaint.points(angle: g.angle, size: CGSize(width: 4, height: 1))
            return AnyShapeStyle(LinearGradient(stops: CssPaint.stops(g).map { Gradient.Stop(color: $0.color.color, location: CGFloat($0.at)) },
                                                startPoint: p.start, endPoint: p.end))
        case .image:
            return nil
        }
    }
}

/// 消息列表（.ph-chat-body）的底：只画背景，其余几项不管。没有能画的层为原样
struct PhBodyBackground: ViewModifier {
    let style: CssStyle?

    func body(content: Content) -> some View {
        if let style, !CssPaint.drawable(style.background).isEmpty {
            let bg = { () -> CssStyle in var b = CssStyle(); b.background = style.background; return b }()
            content.background {
                PhBackground(style: bg, fallback: PhFallback(), shape: CssBoxShape(nil, fallback: PhFallback()))
                    .ignoresSafeArea(edges: .bottom)
            }
        } else {
            content
        }
    }
}

/// 伪元素上的那句话画成一行字（第一步：只画字和它的盒子，不画图）
struct PhPseudoText: View {
    let text: String
    let style: CssStyle?
    var size: CGFloat = 11
    var color: Color = Theme.text3

    var body: some View {
        if let style {
            Text(text)
                .font(CssFonts.font(style, size: size))
                .modifier(PhBox(style: style, fallback: PhFallback(fg: color, fontSize: size)))
        } else {
            Text(text).font(.system(size: size)).foregroundStyle(color)
        }
    }
}

// MARK: - 第二步：贴画好的图

/// 找图、摆图的纯计算（测试直接调这些）
enum CssRasterDraw {
    /// 按什么次序找一块图：先找这一种状态，没有再找平时的；同一状态里先找「基础钩子 + 具体一边」的变体
    /// （气泡挂着 bubble 与 bubble-mine：hook bubble、variant bubble-mine），再按钩子从具体到基础各找一次
    static func candidates(_ hooks: [CssHook], state: CssState = .normal, part: CssPart = .main) -> [CssRasterKey] {
        guard let base = hooks.first else { return [] }
        var states = [state]
        if state != .normal { states.append(.normal) }
        var out: [CssRasterKey] = []
        for st in states {
            for v in hooks.dropFirst().reversed() where v != base {
                out.append(CssRasterKey(hook: base, state: st.rawValue, part: part.rawValue, variant: v))
            }
            for h in hooks.reversed() {
                out.append(CssRasterKey(hook: h, state: st.rawValue, part: part.rawValue))
            }
        }
        var seen = Set<CssRasterKey>()
        return out.filter { seen.insert($0).inserted }
    }

    /// 这几个钩子在这一种状态、这几个部位上画好的某一种图。没有为 nil
    static func pick(_ set: CssRasterSet?, _ hooks: [CssHook], state: CssState = .normal,
                     parts: [CssPart] = [.main], kind: CssRasterImage.Kind) -> CssRasterImage? {
        guard let set, !set.images.isEmpty, !hooks.isEmpty else { return nil }
        for p in parts {
            for k in candidates(hooks, state: state, part: p) {
                if let img = set.images[CssRaster.id(k)], img.kind == kind, !img.imageId.isEmpty { return img }
            }
        }
        return nil
    }

    /// ::before、::after 画成的装饰（先 before 后 after：after 画在上面，同 CSS）
    static func decors(_ set: CssRasterSet?, _ hooks: [CssHook], state: CssState = .normal) -> [CssRasterImage] {
        guard set != nil, !hooks.isEmpty else { return [] }
        return [CssPart.before, .after].compactMap { pick(set, hooks, state: state, parts: [$0], kind: .decor) }
    }

    /// 换掉图标的那一张（`.ph-x svg { display: none }` 加伪元素贴图）
    static func icon(_ set: CssRasterSet?, _ hooks: [CssHook]) -> CssRasterImage? {
        pick(set, hooks, parts: [.main, .before, .after], kind: .icon)
    }

    /// 装饰对齐元素的哪个角、哪条边。认不出的按左上
    static func alignment(_ anchor: String) -> Alignment {
        switch anchor.lowercased() {
        case "topleft": return .topLeading
        case "topright": return .topTrailing
        case "bottomleft": return .bottomLeading
        case "bottomright": return .bottomTrailing
        case "top": return .top
        case "bottom": return .bottom
        case "left": return .leading
        case "right": return .trailing
        case "center": return .center
        default: return .topLeading
        }
    }

    /// 只看左右：贴在顶上那一条（消息列表的 ::before）用
    static func horizontal(_ anchor: String) -> Alignment {
        let a = anchor.lowercased()
        if a.hasSuffix("left") { return .leading }
        if a.hasSuffix("right") { return .trailing }
        return .center
    }

    /// 从对齐的那个角再挪多少（屏幕坐标，右、下为正；CssRasterPlan.placement 的约定）。
    /// 随元素拉伸的那一边由 `stretchInsets` 定位，不再挪
    static func offset(_ img: CssRasterImage) -> CGSize {
        CGSize(width: img.stretchX ? 0 : fin(img.dx), height: img.stretchY ? 0 : fin(img.dy))
    }

    private static func fin(_ v: Double) -> CGFloat { v.isFinite ? CGFloat(v) : 0 }

    /// 随元素拉伸的装饰离元素四边的距离（负为伸出元素之外）：左 dx、右 refWidth - dx - width，上 dy、下 refHeight - dy - height。
    /// 参考尺寸为 0（高度由内容撑开、或旧数据）时两边按对称算。不拉伸的那一边为 0
    static func stretchInsets(_ img: CssRasterImage) -> EdgeInsets {
        var e = EdgeInsets()
        if img.stretchX {
            let l = fin(img.dx)
            e.leading = l
            e.trailing = img.refWidth > 0 ? fin(img.refWidth - img.dx - img.width) : l
        }
        if img.stretchY {
            let t = fin(img.dy)
            e.top = t
            e.bottom = img.refHeight > 0 ? fin(img.refHeight - img.dy - img.height) : t
        }
        return e
    }

    /// box 图伸出元素四边多少（正为往外）：图的左上角在元素的 (dx, dy)，溢出时为负；
    /// 左 -dx、上 -dy、右 width - refWidth + dx、下 height - refHeight + dy。
    /// 参考尺寸为 0（高度由内容撑开、或旧数据）时那一方向按对称算（下同上、右同左）
    static func boxOutset(_ img: CssRasterImage) -> EdgeInsets {
        let left = -fin(img.dx), top = -fin(img.dy)
        let right = img.refWidth > 0 ? fin(img.width - img.refWidth + img.dx) : left
        let bottom = img.refHeight > 0 ? fin(img.height - img.refHeight + img.dy) : top
        return EdgeInsets(top: top, leading: left, bottom: bottom, trailing: right)
    }

    /// 九宫格四边：负数、非数按 0；同一方向两边加起来超过图的边长时按比例缩，中间至少留 1 点拉伸
    static func caps(_ img: CssRasterImage) -> EdgeInsets {
        func c(_ v: Double) -> Double { v.isFinite ? max(0, v) : 0 }
        let (t, b) = fit(c(img.capTop), c(img.capBottom), c(img.height))
        let (l, r) = fit(c(img.capLeft), c(img.capRight), c(img.width))
        return EdgeInsets(top: CGFloat(t), leading: CGFloat(l), bottom: CGFloat(b), trailing: CGFloat(r))
    }

    static func fit(_ a: Double, _ b: Double, _ total: Double) -> (Double, Double) {
        let room = max(0, total - 1)
        let sum = a + b
        guard sum > room, sum > 0 else { return (a, b) }
        let k = room / sum
        return (a * k, b * k)
    }

    /// 一块图的点尺寸（非数、负数为 0）
    static func size(_ img: CssRasterImage) -> CGSize {
        func c(_ v: Double) -> CGFloat { v.isFinite ? CGFloat(max(0, v)) : 0 }
        return CGSize(width: c(img.width), height: c(img.height))
    }

    /// 读图时解码到多大：按三倍屏算，图本身更小时按图本身（缩略图不放大）
    static func maxPixel(_ img: CssRasterImage) -> CGFloat {
        let s = size(img)
        return max(1, (max(s.width, s.height) * 3).rounded(.up))
    }

    /// 解出来的图按画图时的点尺寸定比例：九宫格的四边按点算
    static func pointImage(_ raw: UIImage, _ img: CssRasterImage) -> UIImage {
        let w = size(img).width
        guard let cg = raw.cgImage, w > 0 else { return raw }
        let scale = CGFloat(cg.width) / w
        guard scale.isFinite, scale > 0 else { return raw }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    static func cached(_ img: CssRasterImage) -> UIImage? {
        Images.cached(img.imageId, maxPixel: maxPixel(img)).map { pointImage($0, img) }
    }

    static func load(_ img: CssRasterImage) async -> UIImage? {
        await Images.load(img.imageId, maxPixel: maxPixel(img)).map { pointImage($0, img) }
    }
}

/// 一张画好的图。box 按九宫格拉伸，盖住给它的大小再往外伸出阴影、外框溢出的那一圈（`boxOutset`）；
/// decor、icon 整张缩放到给它的大小（调用的一边定 frame）。图还没读出来、或读不到时画 fallback（不外扩）
struct CssRasterView<Fallback: View>: View {
    let image: CssRasterImage
    let fallback: Fallback
    @State private var ui: UIImage?

    init(image: CssRasterImage, @ViewBuilder fallback: () -> Fallback) {
        self.image = image
        self.fallback = fallback()
        _ui = State(initialValue: CssRasterDraw.cached(image))
    }

    var body: some View {
        Group {
            if let ui {
                if image.kind == .box {
                    let o = CssRasterDraw.boxOutset(image)
                    Image(uiImage: ui).resizable(capInsets: CssRasterDraw.caps(image), resizingMode: .stretch)
                        .padding(EdgeInsets(top: -o.top, leading: -o.leading, bottom: -o.bottom, trailing: -o.trailing))
                } else {
                    Image(uiImage: ui).resizable()
                }
            } else {
                fallback
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: image.imageId) {
            if let hit = CssRasterDraw.cached(image) { ui = hit; return }
            ui = await CssRasterDraw.load(image)
        }
    }
}

extension CssRasterView where Fallback == EmptyView {
    init(image: CssRasterImage) {
        self.init(image: image) { EmptyView() }
    }
}

/// 一块装饰按自己的大小摆在元素上：对齐 anchor 那个角，再挪 dx、dy；
/// 随元素拉伸的那一边跟着元素伸缩，离元素两边的距离保持画图时的样子（`stretchInsets`，可为负）
struct PhDecor: View {
    let image: CssRasterImage

    var body: some View {
        let s = CssRasterDraw.size(image)
        CssRasterView(image: image)
            .frame(width: image.stretchX ? nil : s.width, height: image.stretchY ? nil : s.height)
            .frame(maxWidth: image.stretchX ? .infinity : nil, maxHeight: image.stretchY ? .infinity : nil)
            .padding(CssRasterDraw.stretchInsets(image))
            .offset(CssRasterDraw.offset(image))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: CssRasterDraw.alignment(image.anchor))
            .allowsHitTesting(false)
    }
}

/// 装饰排在字的上下（时间分隔行的 ::before / ::after），不叠在元素上。横向拉伸的保持左右两边的距离
struct PhFlowDecor: View {
    let image: CssRasterImage

    var body: some View {
        let s = CssRasterDraw.size(image)
        let e = CssRasterDraw.stretchInsets(image)
        CssRasterView(image: image)
            .frame(width: image.stretchX ? nil : s.width, height: s.height)
            .frame(maxWidth: image.stretchX ? .infinity : nil)
            .padding(.leading, e.leading)
            .padding(.trailing, e.trailing)
    }
}

/// 一组装饰：below 的贴在元素底下（背景之下），其余盖在上面。超出元素的部分照样画（气泡的小尾巴），这里不裁。
/// 一张都没有时原样
private struct PhDecors: ViewModifier {
    let images: [CssRasterImage]
    let below: Bool

    func body(content: Content) -> some View {
        if images.isEmpty {
            content
        } else if below {
            content.background {
                ZStack { ForEach(Array(images.enumerated()), id: \.offset) { _, img in PhDecor(image: img) } }
            }
        } else {
            content.overlay {
                ZStack { ForEach(Array(images.enumerated()), id: \.offset) { _, img in PhDecor(image: img) } }
            }
        }
    }
}

/// 消息列表（.ph-chat-body）的 ::before 画成的那一条：钉在顶栏下面，不随消息滚动（CSS 的 position: sticky 的近似）。
/// 没有图时原样
struct PhStickyTop: ViewModifier {
    let image: CssRasterImage?
    var margin: CssEdges?

    func body(content: Content) -> some View {
        if let image {
            content.safeAreaInset(edge: .top, spacing: 0) {
                PhFlowDecor(image: image)
                    .frame(maxWidth: .infinity, alignment: CssRasterDraw.horizontal(image.anchor))
                    .padding(margin.map(CssPaint.insets) ?? EdgeInsets())
                    .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}
