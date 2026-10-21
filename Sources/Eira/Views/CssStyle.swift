import SwiftUI

/// 网页版美化 CSS 翻译成原生样式之后的样子（第一步：原生格子）。
///
/// 网页版美化包按契约写（网页版 system/skin-contract.js：`.ph-bubble`、`.ph-composer` 这类类名与 `--ph-*` 变量）。
/// 原生版不跑 CSS：导入、打开时由 `CssSkin.compile` 把 CSS 里读得懂的那部分读成这里的 `CssStyle`，
/// 挂了同名钩子的原生元素用 `.phStyle(...)` 照着画。读不懂的一条条记进 `CssReport`，确认页上写明。
///
/// 只加不改：这里的字段与 `Hook` 一经发布不改名（同网页版第 18 条的精神）。
enum CssSkin {}

/// 钩子名，不带 `ph-` 前缀，与网页版契约同名（"bubble"、"bubble-mine"、"composer"、"navbar"……）
typealias CssHook = String

/// 一种状态。`normal` 之外只认 `:active`（按下）与 `:focus`（输入框聚焦）
enum CssState: String, Hashable, Sendable, CaseIterable {
    case normal, pressed, focused
}

/// 伪元素。第一步只读它们的文字（content）、背景与盒子；画成图是第二步
enum CssPart: String, Hashable, Sendable, CaseIterable {
    case main, before, after, placeholder
}

struct CssKey: Hashable, Sendable {
    var hook: CssHook
    var state: CssState = .normal
    var part: CssPart = .main
}

/// 颜色。存 RGBA（0...1），不存 SwiftUI.Color，便于比较与测试
struct CssColor: Equatable, Hashable, Sendable {
    var r: Double, g: Double, b: Double, a: Double
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    static let clear = CssColor(r: 0, g: 0, b: 0, a: 0)
}

/// 线性渐变。angle 按 CSS 的度数：0 朝上、90 朝右、180 朝下（`to bottom` 即 180）
struct CssGradient: Equatable, Sendable {
    struct Stop: Equatable, Sendable { var color: CssColor; var at: Double }   // at: 0...1
    var angle: Double
    var stops: [Stop]
    var repeating = false
}

/// 一层背景。多层时第一层在最上面（同 CSS）
enum CssLayer: Equatable, Sendable {
    case color(CssColor)
    case gradient(CssGradient)
    /// 图片：https 地址或 data: 地址。下载、画 SVG 是导入那一步的事，这里只记来源
    case image(url: String)
}

struct CssBackground: Equatable, Sendable {
    var layers: [CssLayer] = []
    /// background-size：cover、contain，或 "W H"（像素或百分比，原样记）
    var size = ""
    var position = ""
    var repeatImage = true
}

/// 一道阴影。box-shadow 与 text-shadow 共用（text-shadow 没有 spread 与 inset）
struct CssShadow: Equatable, Sendable {
    var x: Double, y: Double, blur: Double, spread: Double = 0
    var color: CssColor
    var inset = false
}

struct CssBorder: Equatable, Sendable {
    var width: Double
    var color: CssColor
    /// solid、dashed、dotted；none 不记
    var style = "solid"
}

/// 四边。CSS 简写按 上 右 下 左 展开
struct CssEdges: Equatable, Sendable {
    var top: Double = 0, right: Double = 0, bottom: Double = 0, left: Double = 0
}

/// transform 只认平移、旋转、缩放（按 CSS 写的先后次序）
struct CssTransform: Equatable, Sendable {
    var dx: Double = 0, dy: Double = 0
    var rotate: Double = 0          // 度
    var scaleX: Double = 1, scaleY: Double = 1
}

/// 一个钩子（一种状态、一个部位）读出来的全部样式。nil 为没写，照原生默认
struct CssStyle: Equatable, Sendable {
    var background: CssBackground?
    var color: CssColor?
    var opacity: Double?
    var radius: Double?
    /// border-radius 写了百分比（50% 画圆）
    var radiusPercent: Double?
    var border: CssBorder?
    var borderTop: CssBorder?
    var borderBottom: CssBorder?
    var outline: CssBorder?
    var shadows: [CssShadow]?
    var textShadows: [CssShadow]?
    var fontSize: Double?
    /// 100...900；bold 为 700
    var fontWeight: Int?
    var fontFamily: [String]?
    var letterSpacing: Double?
    /// 行高：倍数（1.55）或像素，像素时 lineHeightPx 有值
    var lineHeight: Double?
    var lineHeightPx: Double?
    var textAlign: String?
    var padding: CssEdges?
    var margin: CssEdges?
    var width: Double?
    var height: Double?
    var minWidth: Double?
    var minHeight: Double?
    var gap: Double?
    var transform: CssTransform?
    /// display: none
    var hidden: Bool?
    /// ::before / ::after 的 content（只记字符串，counter() 之类不认）
    var content: String?
    /// 原文的声明，按属性名，读成上面各字段之后仍留着，第二步画图用
    var raw: [String: String] = [:]
}

/// 一份美化读完的结果
struct CssCompiled: Equatable, Sendable {
    var styles: [CssKey: CssStyle] = [:]
    /// 最后生效的 `--ph-*` 与作者自己的变量（已经展开过 var()）
    var vars: [String: String] = [:]
    var report = CssReport()

    func style(_ hook: CssHook, _ state: CssState = .normal, _ part: CssPart = .main) -> CssStyle? {
        styles[CssKey(hook: hook, state: state, part: part)]
    }
}

/// 读的过程记下的账：哪些用上了、哪些近似、哪些跳过，各写原因。导入确认页照这个列
struct CssReport: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        enum Kind: String, Sendable { case used, approx, skipped }
        var kind: Kind
        /// 选择器原文
        var selector: String
        /// 属性名，整条规则跳过时为空
        var property: String
        /// 写给用户看的一句，书面语
        var reason: String
    }
    var items: [Item] = []
    var used: Int { items.filter { $0.kind == .used }.count }
    var approx: Int { items.filter { $0.kind == .approx }.count }
    var skipped: Int { items.filter { $0.kind == .skipped }.count }
}
