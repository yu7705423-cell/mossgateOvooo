import SwiftUI
import UIKit

/// 美化 CSS 还原的第二步：格子表达不了的纯视觉部分，请 WebKit 按 CSS 原样画成图片（导入或打开时画一次，之后只读图）。
///
/// 两边共用这里的结构：
/// - 画图的一边（CssRasterizer）：在关起来、不联网的 WKWebView 里摆一个挂着契约类名的样板元素，套上这份 CSS，截图存下；
///   CSS 里引用的 https 图片在导入那一刻下载到本机，换成 data: 再画（之后不再联网）。
/// - 用图的一边（CssStyleView）：有图就贴图，没图照第一步的格子画。
///
/// 只加不改：字段与 Kind 一经发布不改名。
enum CssRaster {}

/// 一张画好的图是哪一块
struct CssRasterKey: Hashable, Sendable, Codable {
    var hook: CssHook
    var state: String = CssState.normal.rawValue
    var part: String = CssPart.main.rawValue
    /// 同一钩子按另一个钩子区分的变体（气泡挂着 bubble-mine 还是 bubble-theirs），没有为空
    var variant: String = ""
}

/// 一张图怎么贴
struct CssRasterImage: Equatable, Sendable, Codable {
    enum Kind: String, Sendable, Codable {
        /// 整块背景（元素自己的底、边框、阴影、内阴影、混合模式），大小会变：按九宫格拉伸
        case box
        /// 伪元素装饰（::before / ::after），按它自己的大小与位置贴在元素上
        case decor
        /// 换掉元素里的图标（返回键、加号、发送键这类：.ph-x svg { display:none } 加 ::before 贴图）
        case icon
    }
    var kind: Kind
    /// 存在 MediaStore(.images) 里的图 id（Images.save 存的；原生版不删图，规约第 20 条）
    var imageId: String
    /// 画图时用的点尺寸（不是像素）
    var width: Double
    var height: Double
    /// box：九宫格四边不拉伸的宽度（点）
    var capTop: Double = 0
    var capLeft: Double = 0
    var capBottom: Double = 0
    var capRight: Double = 0
    /// decor：相对元素的摆放。anchor 为 "topLeft" "topRight" "bottomLeft" "bottomRight" "top" "bottom" "left" "right" "center"，
    /// dx / dy 是从那个角再挪的点数（已含 CSS 的 top/left/right/bottom 与 translate）
    var anchor: String = "topLeft"
    var dx: Double = 0
    var dy: Double = 0
    /// 画在元素之下（z-index 负）还是之上
    var below = false
    /// decor 是否盖住整个元素（left:0 right:0 这类），盖住时宽度随元素拉伸
    var stretchX = false
    var stretchY = false
}

/// 一份美化画出来的全部图片。存在 skins 数据域那一行的 `nativeRaster` 字段里（网页版不认这个字段，写回时原样保留）
struct CssRasterSet: Equatable, Sendable, Codable {
    /// 画的是哪一份 CSS（css 文本的哈希）。CSS 改过就重画
    var cssHash: String = ""
    /// 画图引擎的版本：引擎改了也重画
    var engine: Int = 1
    var images: [String: CssRasterImage] = [:]   // key 为 CssRaster.id(CssRasterKey)
    /// 导入时下载过的远程图片：地址 → 本机图 id
    var remote: [String: String] = [:]
    /// 画不出来的几块与原因（写给用户看，书面语）
    var failures: [String: String] = [:]
}

extension CssRaster {
    static func id(_ k: CssRasterKey) -> String {
        [k.hook, k.state, k.part, k.variant].joined(separator: "|")
    }
}
