import CryptoKit
import Foundation
import ImageIO
import UIKit
import WebKit

// 美化 CSS 还原的第二步，画图的一边（CssRaster.swift 是两边共用的结构）。
//
// 格子画不出来的那几块（多层渐变加内阴影加边框、混合模式、滤镜、伪元素贴图、换掉的图标），
// 交给 WebKit 按 CSS 原样画一次，截图存成图片，之后只读图。
//
// 沙盒（网页版第 21 条，原生版同样）：不落盘的数据存储、loadHTMLString 的 baseURL 为 nil、不跑脚本、
// CSP 只放行内联样式与 data: 图片字体，页面里的任何跳转一律拦下。CSS 里引用的 https 图片只在导入那一刻
// 由这里用 URLSession 下载（限 https、限 5 MB、必须认得出是图片），存进本机，换成 data: 再画；之后不再联网。
//
// 不跑脚本就量不了位置，所以样板一律摆成已知的固定大小：元素放在画布里 (pad, pad) 处、宽高写死，
// 画出来之后在像素里找不透明的范围，伪元素在哪儿、多大由像素决定。
// 透明背景不靠 WebKit：同一页在黑底、白底上各截一张，两张一比就得出每个像素的不透明度（网页截图不一定带透明）。

// MARK: - 纯计算

/// 画哪几块、样板多大、贴到哪儿、九宫格留多宽、CSS 里的网络图片。纯函数，不碰 WebKit
enum CssRasterPlan {
    /// 画图引擎的版本。画法改了就加一，存着的图一律重画
    static let engine = 1
    /// 每份美化最多画几张
    static let maxRenders = 40
    /// 每一页最多等几秒（第一页要先起 WebKit 的进程，多等一些）
    static let renderTimeout: TimeInterval = 3
    static let firstTimeout: TimeInterval = 10
    /// 元素四周留的空白（点）：阴影、外框、伪元素伸出去的部分画在这里
    static let minPad: Double = 40
    static let maxRemoteBytes = 5 * 1024 * 1024
    static let remoteMaxPixel: CGFloat = 1024
    /// 由内容撑开高度时的画布高度（点）
    static let autoCanvasHeight: Double = 400

    static func hash(_ css: String) -> String {
        SHA256.hash(data: Data(css.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 要不要重画：没画过、CSS 改过、引擎改过；要下载网络图片时，还有没下载过的地址也算
    static func isStale(_ set: CssRasterSet?, css: String, fetchRemote: Bool) -> Bool {
        guard let set else { return true }
        if set.engine != engine || set.cssHash != hash(css) { return true }
        if fetchRemote, remoteURLs(css).contains(where: { set.remote[$0] == nil }) { return true }
        return false
    }

    // MARK: 网络图片

    struct UrlRef: Equatable {
        var range: NSRange
        var url: String
    }

    private static let urlRE = try! NSRegularExpression(
        pattern: #"url\(\s*(?:"([^"]*)"|'([^']*)'|([^'"\)\s]*))\s*\)"#, options: [.caseInsensitive])

    /// CSS 里每一处 url(...)：位置与地址
    static func urlRefs(_ css: String) -> [UrlRef] {
        let ns = css as NSString
        return urlRE.matches(in: css, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            for g in 1...3 where m.range(at: g).location != NSNotFound {
                return UrlRef(range: m.range, url: ns.substring(with: m.range(at: g)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
    }

    /// 要下载的地址：只认 https，去重，按出现的先后
    static func remoteURLs(_ css: String) -> [String] {
        unique(urlRefs(css).map(\.url).filter { $0.lowercased().hasPrefix("https://") })
    }

    /// http 地址不下载
    static func insecureURLs(_ css: String) -> [String] {
        unique(urlRefs(css).map(\.url).filter { $0.lowercased().hasPrefix("http://") })
    }

    private static func unique(_ a: [String]) -> [String] {
        var seen = Set<String>()
        return a.filter { seen.insert($0).inserted }
    }

    /// 把下载过的地址换成 data: 地址。没有换的原样留着（CSP 拦着，画不出来，也不会联网）
    static func substitute(_ css: String, _ map: [String: String]) -> String {
        guard !map.isEmpty else { return css }
        let out = NSMutableString(string: css)
        for r in urlRefs(css).reversed() {
            guard let data = map[r.url] else { continue }
            out.replaceCharacters(in: r.range, with: "url(\"\(data)\")")
        }
        return out as String
    }

    /// 下载回来的内容是不是一张图片
    static func checkImage(_ data: Data, mime: String?) throws {
        guard data.count <= maxRemoteBytes else { throw StoreError(message: "图片超过 5 MB，未下载") }
        let m = (mime ?? "").lowercased()
        if !m.isEmpty, !(m.hasPrefix("image/") || m == "application/octet-stream" || m == "binary/octet-stream") {
            throw StoreError(message: "该地址返回的不是图片")
        }
        guard !data.isEmpty, let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(src) != nil, CGImageSourceGetCount(src) > 0 else {
            throw StoreError(message: "无法识别这张图片")
        }
    }

    // MARK: 画哪几块

    /// 会话页上要画的钩子（与 CssStyleView 挂的那几个一致）
    static let hooks: [CssHook] = [
        "navbar", "nav-title", "back", "nav-action", "chat-body", "time-sep",
        "msg", "msg-last", "msg-mine-last", "msg-theirs-last",
        "bubble", "bubble-last", "bubble-mine-last", "bubble-theirs-last",
        "meta", "stamp", "read", "transfer", "gift", "location", "narration",
        "composer", "composer-input", "composer-btn", "plus", "sticker-btn", "send", "panel",
    ]

    /// 同一钩子按另一个钩子分开画的（键里的 variant）
    static let variants: [CssHook: [CssHook]] = [
        "bubble": ["bubble-mine", "bubble-theirs"],
        "msg": ["msg-mine", "msg-theirs"],
        "narration": ["narration-mine", "narration-theirs"],
    ]

    /// 同一个元素上一起挂着的、更泛的钩子（网页版：加号是 .ph-composer-btn.ph-plus）
    static let chains: [CssHook: [CssHook]] = [
        "plus": ["composer-btn"], "sticker-btn": ["composer-btn"],
        "msg-last": ["msg"], "msg-mine-last": ["msg", "msg-mine"], "msg-theirs-last": ["msg", "msg-theirs"],
        "bubble-last": ["bubble"], "bubble-mine-last": ["bubble", "bubble-mine"],
        "bubble-theirs-last": ["bubble", "bubble-theirs"],
    ]

    /// 按钮类：网页版里内容居中（内部样式），样板上照样给个居中的默认值，作者写了的照作者的
    static let buttons: Set<CssHook> = ["back", "nav-action", "composer-btn", "plus", "sticker-btn", "send"]

    /// 一个要画的元素：钩子、变体，以及它身上一起挂着的钩子（由泛到具体）
    struct Spec: Equatable {
        var hook: CssHook
        var variant: String
        var chain: [CssHook]
        var family: CssHook { chain.first ?? hook }
    }

    static func specs(_ c: CssCompiled) -> [Spec] {
        let present = Set(c.styles.keys.map(\.hook))
        var out: [Spec] = []
        for h in hooks {
            if let vs = variants[h], vs.contains(where: { present.contains($0) }) {
                for v in vs { out.append(Spec(hook: h, variant: v, chain: [h, v])) }
            } else if present.contains(h) {
                out.append(Spec(hook: h, variant: "", chain: (chains[h] ?? []) + [h]))
            }
        }
        return out
    }

    /// 这一串钩子在这一状态、这一部位上合起来的声明（泛的在前、具体的在后；状态叠在常态之上）。一条都没写为 nil
    static func merged(_ c: CssCompiled, _ chain: [CssHook], _ state: CssState, _ part: CssPart) -> [String: String]? {
        var out: [String: String] = [:]
        var hit = false
        let states: [CssState] = state == .normal ? [.normal] : [.normal, state]
        for s in states {
            for h in chain {
                guard let st = c.style(h, s, part) else { continue }
                if s == state { hit = true }
                out.merge(st.raw) { _, new in new }
            }
        }
        return hit ? out : nil
    }

    struct Job: Equatable {
        var key: CssRasterKey
        var kind: CssRasterImage.Kind
        var spec: Spec
        var state: CssState
        var part: CssPart
        /// 元素的参考大小（点）
        var width: Double
        var height: Double
        /// 伪元素在文档流里（不是绝对定位）：元素高度由内容撑开
        var autoHeight = false
        /// decor 带混合模式：连元素自己的底一起画，贴在元素之上
        var withBackground = false
        var below = false
        /// 这一部位合起来的声明（摆放、九宫格用）
        var raw: [String: String]
    }

    static func jobs(_ c: CssCompiled) -> [Job] {
        var boxes: [Job] = [], icons: [Job] = [], decors: [Job] = [], states: [Job] = []
        for s in specs(c) {
            let main = merged(c, s.chain, .normal, .main)
            // 元素本身藏起来了：原生版同样不画，这里也不画
            if let main, val(main, "display") == "none" { continue }
            let size = refSize(s, main ?? [:], vars: c.vars)
            func key(_ st: CssState, _ p: CssPart) -> CssRasterKey {
                CssRasterKey(hook: s.hook, state: st.rawValue, part: p.rawValue, variant: s.variant)
            }
            if let main, needsBox(main) {
                boxes.append(Job(key: key(.normal, .main), kind: .box, spec: s, state: .normal, part: .main,
                                 width: size.width, height: size.height, raw: main))
            }
            for st in [CssState.pressed, .focused] {
                guard let r = merged(c, s.chain, st, .main), needsBox(r) else { continue }
                states.append(Job(key: key(st, .main), kind: .box, spec: s, state: st, part: .main,
                                  width: size.width, height: size.height, raw: r))
            }
            let iconHidden = main?["iconHidden"] == "1"
            for part in [CssPart.before, .after] {
                guard let r = merged(c, s.chain, .normal, part), contentOn(r) else { continue }
                if iconHidden, hasImage(r) {
                    icons.append(Job(key: key(.normal, part), kind: .icon, spec: s, state: .normal, part: part,
                                     width: size.width, height: size.height, raw: r))
                } else if decorNeeded(r) {
                    let blend = active(r, "mix-blend-mode", none: ["normal"])
                    let z = Int(val(r, "z-index") ?? "") ?? 0
                    decors.append(Job(key: key(.normal, part), kind: .decor, spec: s, state: .normal, part: part,
                                      width: size.width, height: size.height, autoHeight: !positioned(r),
                                      withBackground: blend, below: !blend && z < 0, raw: r))
                }
            }
        }
        return boxes + icons + decors + states
    }

    // MARK: 读声明

    static func val(_ raw: [String: String], _ k: String) -> String? {
        guard let v = raw[k] else { return nil }
        let t = CssScan.trim(v).lowercased()
        return t.isEmpty ? nil : t
    }

    static func px(_ raw: [String: String], _ k: String, base: Double? = nil) -> Double? {
        guard let v = raw[k] else { return nil }
        return CssVal.px(v, CssValueContext(), base: base)
    }

    /// 写了且不是 auto
    static func isSet(_ raw: [String: String], _ k: String) -> Bool {
        guard let v = val(raw, k) else { return false }
        return v != "auto"
    }

    static func active(_ raw: [String: String], _ k: String, none: Set<String>) -> Bool {
        guard let v = val(raw, k) else { return false }
        return !none.contains(v)
    }

    static func backgroundText(_ raw: [String: String]) -> String {
        [raw["background"], raw["background-image"]].compactMap { $0 }.joined(separator: " ").lowercased()
    }

    static func count(_ s: String, _ needle: String) -> Int {
        s.components(separatedBy: needle).count - 1
    }

    /// 背景里有渐变或图片
    static func hasImage(_ raw: [String: String]) -> Bool {
        let bg = backgroundText(raw)
        return bg.contains("gradient(") || bg.contains("url(")
    }

    /// 格子画不了的那几样
    static func special(_ raw: [String: String]) -> Bool {
        active(raw, "mix-blend-mode", none: ["normal"]) || active(raw, "filter", none: ["none"])
            || active(raw, "clip-path", none: ["none"]) || active(raw, "mask", none: ["none"])
            || active(raw, "-webkit-mask", none: ["none"]) || active(raw, "mask-image", none: ["none"])
            || active(raw, "-webkit-mask-image", none: ["none"]) || active(raw, "border-image", none: ["none"])
            || active(raw, "border-image-source", none: ["none"])
    }

    static func insetShadow(_ raw: [String: String]) -> Bool {
        (val(raw, "box-shadow") ?? "").contains("inset")
    }

    /// 写了有宽度的边框或外框
    static func bordered(_ raw: [String: String]) -> Bool {
        for (k, v) in raw where (k.hasPrefix("border") || k.hasPrefix("outline")) && !k.contains("radius")
            && !k.hasSuffix("-color") && !k.hasSuffix("-style") && !k.contains("image") && !k.contains("offset") {
            let t = v.lowercased()
            if t.contains("none") || t.contains("hidden") { continue }
            if CssScan.words(t).contains(where: { (CssVal.px($0, CssValueContext()) ?? 0) > 0 }) { return true }
        }
        return false
    }

    /// 元素本身要整块画成图：多层渐变、背景图、混合模式、滤镜、裁剪，或渐变、边框与内阴影叠在一起
    static func needsBox(_ raw: [String: String]) -> Bool {
        let bg = backgroundText(raw)
        let grads = count(bg, "gradient(")
        if special(raw) || bg.contains("url(") || grads >= 2 || bg.contains("repeating-") { return true }
        for k in ["background-size", "background-position"] {
            if let v = val(raw, k), v.contains(",") || v.contains("calc(") { return true }
        }
        return insetShadow(raw) && (grads > 0 || bordered(raw))
    }

    /// 伪元素画得出来（写了 content、没有隐藏）
    static func contentOn(_ raw: [String: String]) -> Bool {
        guard let c = val(raw, "content"), c != "none", c != "normal" else { return false }
        return val(raw, "display") != "none"
    }

    /// 伪元素要画成装饰：背景有渐变或图片、混合模式、滤镜、阴影
    static func decorNeeded(_ raw: [String: String]) -> Bool {
        hasImage(raw) || special(raw) || active(raw, "box-shadow", none: ["none"])
    }

    static func positioned(_ raw: [String: String]) -> Bool {
        let p = val(raw, "position")
        return p == "absolute" || p == "fixed"
    }

    /// 样板的参考大小（点）：写了像素的照写的，没写的按会话页上常见的大小
    static func refSize(_ s: Spec, _ raw: [String: String], vars: [String: String]) -> (width: Double, height: Double) {
        func pick(_ v: Double?, _ fallback: Double, min lo: Double? = nil) -> Double {
            var out = fallback
            if let v, v > 0 { out = v }
            if let lo, lo > out { out = lo }
            return Swift.min(1000, out.rounded(.up))
        }
        let w = px(raw, "width"), h = px(raw, "height")
        let minW = px(raw, "min-width"), minH = px(raw, "min-height")
        let r: (Double, Double)
        switch s.family {
        case "navbar":
            let vh = vars["ph-navbar-h"].flatMap { CssVal.px($0, CssValueContext()) }
            r = (375, pick(h ?? vh, 44, min: minH))
        case "nav-title": r = (pick(w, 200), pick(h, 24))
        case "back", "nav-action", "composer-btn": r = (pick(w, 36, min: minW), pick(h, 36, min: minH))
        case "send": r = (pick(w, 56, min: minW), pick(h, 36, min: minH))
        case "chat-body": r = (375, 200)
        case "time-sep": r = (375, pick(h, 24, min: minH))
        case "msg": r = (375, 60)
        case "bubble": r = (pick(w, 120, min: minW), pick(h, 44, min: minH))
        case "meta": r = (80, 16)
        case "stamp", "read": r = (40, 16)
        case "transfer", "gift", "location": r = (pick(w, 220, min: minW), pick(h, 80, min: minH))
        case "narration": r = (300, 40)
        case "composer": r = (375, pick(h, 50, min: minH))
        case "composer-input": r = (pick(w, 280, min: minW), pick(h, 36, min: minH))
        case "panel": r = (375, pick(h, 240, min: minH))
        default: r = (pick(w, 120, min: minW), pick(h, 44, min: minH))
        }
        return (r.0, r.1)
    }

    // MARK: 摆放

    /// 绝对定位的伪元素按 CSS 算出来的位置（相对元素左上角，点）：left/right/top/bottom、宽高，再按 transform
    /// （以中心为原点：先平移，再旋转、缩放，取外接框）。不是绝对定位的为 nil。用来估画布要留多大
    static func predictFrame(_ raw: [String: String], element: CGSize) -> CGRect? {
        guard positioned(raw) else { return nil }
        let W = Double(element.width), H = Double(element.height)
        let l = px(raw, "left", base: W), r = px(raw, "right", base: W)
        let t = px(raw, "top", base: H), b = px(raw, "bottom", base: H)
        var w = px(raw, "width", base: W), h = px(raw, "height", base: H)
        if w == nil, let l, let r { w = W - l - r }
        if h == nil, let t, let b { h = H - t - b }
        let bw = Swift.max(0, w ?? 0), bh = Swift.max(0, h ?? 0)
        let x = l ?? r.map { W - $0 - bw } ?? 0
        let y = t ?? b.map { H - $0 - bh } ?? 0
        var frame = CGRect(x: x, y: y, width: bw, height: bh)
        if let tv = raw["transform"], let tr = CssVal.transform(tv, CssValueContext(width: bw, height: bh))?.transform {
            let cx = x + bw / 2 + tr.dx, cy = y + bh / 2 + tr.dy
            let sw = bw * abs(tr.scaleX), sh = bh * abs(tr.scaleY)
            let rad = tr.rotate * .pi / 180
            let rw = abs(sw * cos(rad)) + abs(sh * sin(rad))
            let rh = abs(sw * sin(rad)) + abs(sh * cos(rad))
            frame = CGRect(x: cx - rw / 2, y: cy - rh / 2, width: rw, height: rh)
        }
        return frame
    }

    struct Placement: Equatable {
        var anchor: String
        var dx: Double
        var dy: Double
        var stretchX = false
        var stretchY = false
    }

    /// 一块装饰贴在元素的哪个角、再挪多少。frame 为它相对元素左上角的位置（点）。
    /// 约定：图上与 anchor 同名的那个角（边、中心）落在元素同名的那一点，再挪 (dx, dy)。
    /// 拉伸的那一边一律从左（上）算起：dx（dy）为左（上）边距
    static func placement(frame: CGRect, element: CGSize, raw: [String: String], part: CssPart) -> Placement {
        let W = Double(element.width), H = Double(element.height)
        var h = "left", v = "top"
        var sx = false, sy = false
        if positioned(raw) {
            let l = isSet(raw, "left"), r = isSet(raw, "right"), t = isSet(raw, "top"), b = isSet(raw, "bottom")
            if l && r && !isSet(raw, "width") { sx = true }
            else if r && !l { h = "right" }
            else if val(raw, "left") == "50%" { h = "center" }
            if t && b && !isSet(raw, "height") { sy = true }
            else if b && !t { v = "bottom" }
            else if val(raw, "top") == "50%" { v = "center" }
        } else {
            let display = val(raw, "display") ?? "inline"
            let block = ["block", "flex", "grid", "list-item", "table", "flow-root"].contains(display)
            let w = val(raw, "width")
            sx = block && (w == nil || w == "auto" || w == "100%")
            if part == .after { v = "bottom" }
        }
        let dx: Double
        switch h {
        case "right": dx = Double(frame.maxX) - W
        case "center": dx = Double(frame.midX) - W / 2
        default: dx = Double(frame.minX)
        }
        let dy: Double
        switch v {
        case "bottom": dy = Double(frame.maxY) - H
        case "center": dy = Double(frame.midY) - H / 2
        default: dy = Double(frame.minY)
        }
        return Placement(anchor: anchorName(h: h, v: v), dx: dx, dy: dy, stretchX: sx, stretchY: sy)
    }

    static func anchorName(h: String, v: String) -> String {
        switch (v, h) {
        case ("top", "left"): return "topLeft"
        case ("top", "right"): return "topRight"
        case ("bottom", "left"): return "bottomLeft"
        case ("bottom", "right"): return "bottomRight"
        case ("top", _): return "top"
        case ("bottom", _): return "bottom"
        case (_, "left"): return "left"
        case (_, "right"): return "right"
        default: return "center"
        }
    }

    // MARK: 九宫格

    /// 元素四边不拉伸的宽度（点）：圆角与「边框加内阴影」里较大的那个，加 1 留给抗锯齿；不超过边长的一半
    static func caps(_ raw: [String: String], size: CGSize) -> CssEdges {
        let W = Double(size.width), H = Double(size.height)
        let ctx = CssValueContext()
        var radius = 0.0
        for (k, v) in raw where k.contains("radius") {
            for w in CssScan.words(v, slash: true) where w != "/" {
                if let x = CssVal.px(w, ctx, base: Swift.min(W, H)) { radius = Swift.max(radius, x) }
            }
        }
        var border = 0.0
        for (k, v) in raw where k.hasPrefix("border") && !k.contains("radius") && !k.hasSuffix("-color")
            && !k.hasSuffix("-style") && !k.contains("image") {
            for w in CssScan.words(v) { if let x = CssVal.px(w, ctx) { border = Swift.max(border, x) } }
        }
        var inset = 0.0
        if let s = raw["box-shadow"], let list = CssVal.shadows(s, ctx, text: false) {
            for sh in list where sh.inset {
                inset = Swift.max(inset, sh.blur + Swift.max(0, sh.spread) + Swift.max(abs(sh.x), abs(sh.y)))
            }
        }
        let cap = Swift.max(radius, border + inset) + 1
        let cx = Swift.min(cap, W / 2), cy = Swift.min(cap, H / 2)
        return CssEdges(top: cy, right: cx, bottom: cy, left: cx)
    }

    /// 图上的 cap：元素的 cap 加上溢出，两边加起来至少给中间留 1 点
    static func imageCaps(_ c: CssEdges, out: CssEdges, size: CGSize) -> CssEdges {
        func fit(_ a: Double, _ b: Double, _ total: Double) -> (Double, Double) {
            let room = Swift.max(0, total - 1)
            if a + b <= room { return (a, b) }
            let a2 = Swift.min(a, Swift.max(room / 2, room - b))
            return (a2, Swift.max(0, Swift.min(b, room - a2)))
        }
        let (l, r) = fit(c.left + Swift.max(0, out.left), c.right + Swift.max(0, out.right), Double(size.width))
        let (t, b) = fit(c.top + Swift.max(0, out.top), c.bottom + Swift.max(0, out.bottom), Double(size.height))
        return CssEdges(top: t, right: r, bottom: b, left: l)
    }

    /// 外阴影与外框伸出去多远（点）
    static func overflow(_ raw: [String: String]) -> Double {
        let ctx = CssValueContext()
        var out = 0.0
        if let s = raw["box-shadow"], let list = CssVal.shadows(s, ctx, text: false) {
            for sh in list where !sh.inset {
                out = Swift.max(out, sh.blur + Swift.max(0, sh.spread) + Swift.max(abs(sh.x), abs(sh.y)))
            }
        }
        var outline = 0.0
        for (k, v) in raw where k.hasPrefix("outline") && !k.hasSuffix("-color") && !k.hasSuffix("-style") {
            for w in CssScan.words(v) { if let x = CssVal.px(w, ctx) { outline += Swift.max(0, x) } }
        }
        return Swift.max(out, outline)
    }

    /// 画布：元素四周留多少、整张多大（点）
    static func canvas(_ job: Job) -> (pad: Double, width: Double, height: Double) {
        var over = overflow(job.raw)
        if job.part != .main, let f = predictFrame(job.raw, element: CGSize(width: job.width, height: job.height)) {
            over = Swift.max(over, -Double(f.minX), -Double(f.minY), Double(f.maxX) - job.width, Double(f.maxY) - job.height)
        }
        let pad = Swift.min(400, Swift.max(minPad, (over + 8).rounded(.up)))
        let h = job.autoHeight ? autoCanvasHeight : job.height
        return (pad, job.width + 2 * pad, h + 2 * pad)
    }

    /// 截出来的一块（画布坐标，点）落成 CssRasterImage 里的尺寸与摆放
    static func image(_ job: Job, imageId: String, crop: CGRect, pad: Double) -> CssRasterImage {
        let frame = crop.offsetBy(dx: -pad, dy: -pad)
        let W = job.width
        var img = CssRasterImage(kind: job.kind, imageId: imageId, width: round2(crop.width), height: round2(crop.height))
        img.refWidth = W
        img.refHeight = job.autoHeight ? 0 : job.height
        switch job.kind {
        case .box:
            let H = job.height
            img.anchor = "topLeft"
            img.dx = round2(frame.minX)
            img.dy = round2(frame.minY)
            let out = CssEdges(top: -Double(frame.minY), right: Double(frame.maxX) - W,
                               bottom: Double(frame.maxY) - H, left: -Double(frame.minX))
            let c = imageCaps(caps(job.raw, size: CGSize(width: W, height: H)), out: out, size: crop.size)
            img.capTop = round2(c.top); img.capLeft = round2(c.left)
            img.capBottom = round2(c.bottom); img.capRight = round2(c.right)
        case .icon:
            img.anchor = "center"
            img.dx = round2(Double(frame.midX) - W / 2)
            img.dy = round2(Double(frame.midY) - job.height / 2)
        case .decor:
            var H = job.height
            if job.autoHeight {
                // 由内容撑开时元素的底量不出来：按伪元素的底加它的下外边距估
                H = Double(frame.maxY) + Swift.max(0, px(job.raw, "margin-bottom") ?? 0)
            }
            let p = placement(frame: frame, element: CGSize(width: W, height: H), raw: job.raw, part: job.part)
            img.anchor = p.anchor
            img.dx = round2(p.dx)
            img.dy = round2(p.dy)
            img.stretchX = p.stretchX
            img.stretchY = p.stretchY
            img.below = job.below
        }
        return img
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    static func round2(_ v: CGFloat) -> Double { round2(Double(v)) }

    // MARK: 样板页

    static let csp = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:"

    /// 按下、聚焦不靠脚本触发：把 CSS 里的 :active、:focus 换成类名，样板元素挂上同名的类
    static func stateCSS(_ css: String, _ state: CssState) -> String {
        let pattern: String
        let cls: String
        switch state {
        case .normal: return css
        case .pressed: pattern = #":active\b"#; cls = ".rz-active"
        case .focused: pattern = #":focus(?:-visible|-within)?\b"#; cls = ".rz-focus"
        }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return css }
        return re.stringByReplacingMatches(in: css, range: NSRange(location: 0, length: (css as NSString).length),
                                           withTemplate: cls)
    }

    /// 样板元素与它的祖先（照网页版 CHAT_TREE 的层级，类名与网页版一致）
    static func markup(_ job: Job) -> String {
        let s = job.spec
        let cls = s.chain.filter { !CssSkin.lastHooks.contains($0) }.map { "ph-" + $0 }
        var tcls = cls + ["rz-target"]
        if buttons.contains(s.family) || buttons.contains(s.hook) { tcls.append("rz-btn") }
        if job.state == .pressed { tcls.append("rz-active") }
        if job.state == .focused { tcls.append("rz-focus") }
        let isLast = CssSkin.lastHooks.contains(s.hook)
        let svg = buttons.contains(s.family) || buttons.contains(s.hook)
            ? #"<svg class="rz-svg" width="20" height="20" viewBox="0 0 24 24"></svg>"# : ""
        let target = "<div class=\"\(tcls.joined(separator: " "))\">\(svg)</div>"
        func a(_ c: String, _ inner: String) -> String { "<div class=\"\(c) rz-anc\">\(inner)</div>" }
        let mine = cls.contains("ph-bubble-mine") || cls.contains("ph-msg-mine") || cls.contains("ph-narration-mine")
        let msgCls = mine ? "ph-msg ph-msg-mine" : "ph-msg ph-msg-theirs"
        // 后面再接一条同一边的消息：不是一串里的最后一条（:not(:has(~ .ph-msg-mine)) 不命中）
        let sibMsg = "<div class=\"\(msgCls) rz-sib\"></div>"
        let sibItem = #"<i class="rz-sib"></i>"#
        func page(_ inner: String) -> String { a("ph-screen", a("ph-page", inner)) }
        func chat(_ inner: String) -> String { page(a("ph-chat", inner)) }
        func body(_ inner: String) -> String { chat(a("ph-chat-body", inner)) }
        func inCol(_ inner: String) -> String { body(a(msgCls, a("ph-col", inner)) + sibMsg) }
        switch s.family {
        case "navbar": return page(target)
        case "nav-title": return page(a("ph-navbar", target))
        case "nav-action": return page(a("ph-navbar", a("ph-nav-right", target)))
        // 悬浮返回键（默认开启）：在 .ph-screen 里、.ph-page 外
        case "back": return a("ph-screen", a("ph-page", "") + target)
        case "chat-body", "composer", "panel": return chat(target)
        case "time-sep", "narration": return body(target)
        case "msg": return body(target + (isLast ? "" : sibMsg))
        case "bubble": return inCol(target + (isLast ? "" : sibItem))
        case "meta", "transfer", "gift", "location": return inCol(target)
        case "stamp", "read": return inCol(a("ph-meta", target))
        case "composer-input", "composer-btn", "send": return chat(a("ph-composer", target))
        default: return chat(target)
        }
    }

    /// 整页。background 为画布底色（黑或白）。measure 为 true 时只画伪元素本身（量它的范围）
    static func document(_ job: Job, css: String, background: String, measure: Bool = false) -> String {
        let g = canvas(job)
        let P = "html:root body.rz-body .rz-stage"
        let T = "\(P) .rz-target.rz-target.rz-target"
        func n(_ v: Double) -> String { String(format: "%.2f", v) }
        var o: [String] = [
            "html, body { margin: 0 !important; padding: 0 !important; background: \(background) !important; overflow: hidden !important; }",
            "*, *::before, *::after { animation: none !important; transition: none !important; caret-color: transparent !important; }",
            "\(P) { position: relative !important; display: block !important; width: \(n(g.width))px !important; height: \(n(g.height))px !important; overflow: hidden !important; background: \(background) !important; margin: 0 !important; padding: 0 !important; }",
            "\(P) .rz-anc { display: block !important; visibility: visible !important; position: static !important; background: none !important; border: 0 !important; box-shadow: none !important; outline: 0 !important; filter: none !important; backdrop-filter: none !important; -webkit-backdrop-filter: none !important; opacity: 1 !important; transform: none !important; clip-path: none !important; mask: none !important; -webkit-mask: none !important; contain: none !important; perspective: none !important; will-change: auto !important; mix-blend-mode: normal !important; overflow: visible !important; }",
            "\(P) .rz-anc::before, \(P) .rz-anc::after { display: none !important; }",
            "\(P) .rz-sib { display: none !important; }",
            "\(T) { position: absolute !important; left: \(n(g.pad))px !important; top: \(n(g.pad))px !important; right: auto !important; bottom: auto !important; margin: 0 !important; width: \(n(job.width))px !important; min-width: 0 !important; max-width: none !important; height: \(job.autoHeight ? "auto" : n(job.height) + "px") !important; min-height: 0 !important; max-height: none !important; transform: none !important; opacity: 1 !important; flex: none !important; backdrop-filter: none !important; -webkit-backdrop-filter: none !important; }",
            "\(T) > * { visibility: hidden !important; }",
        ]
        switch job.kind {
        case .box:
            o.append("\(T)::before, \(T)::after { display: none !important; }")
        case .icon, .decor:
            let other = job.part == .before ? "after" : "before"
            o.append("\(T)::\(other) { display: none !important; }")
            if measure {
                // 量范围时不混合：底色去掉之后，混合模式会让它在黑底白底上一样，量不出来
                o.append("\(T)::\(job.part.rawValue) { mix-blend-mode: normal !important; }")
            }
            if measure || !job.withBackground {
                o.append("\(T) { background: none !important; box-shadow: none !important; border-color: transparent !important; border-image: none !important; outline: none !important; }")
            }
        }
        let base = [
            "*, *::before, *::after { box-sizing: border-box; }",
            "html { -webkit-text-size-adjust: 100%; }",
            "body { font-family: -apple-system, system-ui, \"PingFang SC\", sans-serif; font-size: 15px; line-height: 1.4; color: #1c1c1e; }",
            ":where(.rz-btn) { display: flex; align-items: center; justify-content: center; }",
            ":where(.rz-svg) { display: block; }",
        ].joined(separator: "\n")
        let user = stateCSS(css, job.state).replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
        return "<!doctype html><html><head><meta charset=\"utf-8\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
            + "<meta name=\"viewport\" content=\"width=\(Int(g.width.rounded(.up))), initial-scale=1, maximum-scale=1, user-scalable=no\">"
            + "<meta name=\"color-scheme\" content=\"light\">"
            + "<style>\(base)</style><style>\(user)</style><style>\(o.joined(separator: "\n"))</style>"
            + "</head><body class=\"rz-body\"><div class=\"rz-stage\">\(markup(job))</div></body></html>"
    }

    // MARK: 像素

    /// 黑底、白底两张截图（RGBA，不透明）合成带透明的一张（预乘 RGBA）：
    /// 同一像素白底减黑底的差就是 1 - 不透明度，黑底上的颜色就是预乘过的颜色
    static func unmatte(black: [UInt8], white: [UInt8]) -> [UInt8] {
        let n = Swift.min(black.count, white.count) / 4 * 4
        var out = [UInt8](repeating: 0, count: n)
        var i = 0
        while i < n {
            let d = (Int(white[i]) - Int(black[i]) + Int(white[i + 1]) - Int(black[i + 1])
                     + Int(white[i + 2]) - Int(black[i + 2])) / 3
            let a = Swift.max(0, Swift.min(255, 255 - d))
            out[i] = UInt8(Swift.min(Int(black[i]), a))
            out[i + 1] = UInt8(Swift.min(Int(black[i + 1]), a))
            out[i + 2] = UInt8(Swift.min(Int(black[i + 2]), a))
            out[i + 3] = UInt8(a)
            i += 4
        }
        return out
    }

    /// 不透明像素的范围（像素）。全透明为 nil
    static func alphaBounds(_ px: [UInt8], width: Int, height: Int, threshold: UInt8 = 3) -> CssPixelRect? {
        guard width > 0, height > 0, px.count >= width * height * 4 else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where px[row + x * 4 + 3] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return CssPixelRect(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1)
    }

    /// 截出一块，编成 PNG（带透明）
    static func png(_ px: [UInt8], width: Int, crop: CssPixelRect, scale: CGFloat) -> Data? {
        guard crop.w > 0, crop.h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var out = [UInt8](repeating: 0, count: crop.w * crop.h * 4)
        for y in 0..<crop.h {
            let src = ((crop.y + y) * width + crop.x) * 4
            let dst = y * crop.w * 4
            guard src >= 0, src + crop.w * 4 <= px.count else { return nil }
            out.replaceSubrange(dst..<(dst + crop.w * 4), with: px[src..<(src + crop.w * 4)])
        }
        let cg: CGImage? = out.withUnsafeMutableBytes { p in
            CGContext(data: p.baseAddress, width: crop.w, height: crop.h, bitsPerComponent: 8, bytesPerRow: crop.w * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let cg else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up).pngData()
    }

    /// 截图读成 RGBA（sRGB、预乘）
    static func rgba(_ cg: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buf : nil
    }
}

/// 像素矩形
struct CssPixelRect: Equatable, Sendable {
    var x: Int, y: Int, w: Int, h: Int
    var maxX: Int { x + w }
    var maxY: Int { y + h }

    func union(_ o: CssPixelRect) -> CssPixelRect {
        let nx = Swift.min(x, o.x), ny = Swift.min(y, o.y)
        return CssPixelRect(x: nx, y: ny, w: Swift.max(maxX, o.maxX) - nx, h: Swift.max(maxY, o.maxY) - ny)
    }

    /// 限在 width × height 的画布里
    func clamped(width: Int, height: Int) -> CssPixelRect? {
        let nx = Swift.max(0, x), ny = Swift.max(0, y)
        let mx = Swift.min(width, maxX), my = Swift.min(height, maxY)
        guard mx > nx, my > ny else { return nil }
        return CssPixelRect(x: nx, y: ny, w: mx - nx, h: my - ny)
    }
}

// MARK: - 网络图片

/// 导入时下载 CSS 里的 https 图片。只在这里联网
enum CssRasterNet {
    /// 不存 cookie、不走缓存。测试里换成接住请求的那一个
    nonisolated(unsafe) static var session: URLSession = makeSession()

    static func makeSession(protocols: [AnyClass] = []) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        if !protocols.isEmpty { c.protocolClasses = protocols }
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }

    /// 下载一张：只认 https，状态码 2xx，不超过 5 MB，必须认得出是图片。不重试
    static func fetch(_ address: String) async throws -> Data {
        guard let url = URL(string: address), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw StoreError(message: "只下载 https 地址的图片")
        }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw StoreError(message: "图片地址没有正常响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw StoreError(message: "图片地址返回了错误（\(http.statusCode)）")
        }
        if http.expectedContentLength > Int64(CssRasterPlan.maxRemoteBytes) {
            throw StoreError(message: "图片超过 5 MB，未下载")
        }
        var buf: [UInt8] = []
        buf.reserveCapacity(Int(Swift.max(0, Swift.min(http.expectedContentLength, Int64(CssRasterPlan.maxRemoteBytes)))))
        for try await b in bytes {
            buf.append(b)
            if buf.count > CssRasterPlan.maxRemoteBytes { throw StoreError(message: "图片超过 5 MB，未下载") }
        }
        let data = Data(buf)
        try CssRasterPlan.checkImage(data, mime: http.mimeType)
        return data
    }
}

// MARK: - 画图

@MainActor
enum CssRasterizer {
    /// 正在画的美化：同一份不同时画两次
    private static var running: Set<String> = []
    /// 画的过程中又有人要（值为要不要下载网络图片）：画完再核对一遍
    private static var again: [String: Bool] = [:]
    /// 画的过程中又来要的，等这一轮画完一起返回
    private static var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// 这一份美化的图是不是最新的，不是就画（WebKit 异步画，不挡界面），画完存进那一行并发 eiraSkinChanged。
    /// 导入时 fetchRemote 为 true：顺带下载 CSS 里的 https 图片；打开会话时为 false，只用已经下载过的。
    /// 同一份正在画时再来要，等这一轮画完（必要时再画一轮）一起返回
    static func ensure(skinId: String, fetchRemote: Bool = false) async {
        guard !skinId.isEmpty else { return }
        if running.contains(skinId) {
            again[skinId] = (again[skinId] ?? false) || fetchRemote
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiters[skinId, default: []].append(c) }
            return
        }
        running.insert(skinId)
        var fetch = fetchRemote
        while true {
            await once(skinId, fetchRemote: fetch)
            guard let more = again.removeValue(forKey: skinId) else { break }
            fetch = more
        }
        running.remove(skinId)
        for c in waiters.removeValue(forKey: skinId) ?? [] { c.resume() }
    }

    /// 不是最新的才画一次
    private static func once(_ skinId: String, fetchRemote: Bool) async {
        guard let row = Skins.get(skinId) else { return }
        let css = row.string("css")
        guard !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let existing = Skins.raster(row, current: false)
        guard CssRasterPlan.isStale(existing, css: css, fetchRemote: fetchRemote) else { return }
        let set = await render(css: css, compiled: Skins.compiled(css: css), existing: existing, fetchRemote: fetchRemote)
        // 画的过程中这一份删了：不存。CSS 又改了：这一份作废，按新的再画一轮
        guard let now = Skins.get(skinId) else { return }
        guard CssRasterPlan.hash(now.string("css")) == set.cssHash else {
            again[skinId] = (again[skinId] ?? false) || fetchRemote
            return
        }
        save(set, skinId: skinId)
    }

    /// 存进那一行的 nativeRaster。其余字段原样保留；不动 updatedAt（不是用户改的）
    static func save(_ set: CssRasterSet, skinId: String) {
        do {
            guard var r = try Database.shared.get(Skins.collection, id: skinId) else { return }
            r["nativeRaster"] = try JSONValue.parse(JSONEncoder().encode(set))
            try Database.shared.put(Skins.collection, r)
            NotificationCenter.default.post(name: .eiraSkinChanged, object: nil)
        } catch {
            Problems.report("美化图片保存失败：\(error.localizedDescription)")
        }
    }

    /// 画一份 CSS。existing 为上一次画的（用它记下的网络图片，不重复下载）
    static func render(css: String, compiled: CssCompiled, existing: CssRasterSet?, fetchRemote: Bool) async -> CssRasterSet {
        var out = CssRasterSet()
        out.cssHash = CssRasterPlan.hash(css)
        out.engine = CssRasterPlan.engine
        var inline: [String: String] = [:]
        for url in CssRasterPlan.insecureURLs(css) {
            out.failures["remote|" + url] = "只下载 https 地址的图片，这一张不显示"
        }
        for url in CssRasterPlan.remoteURLs(css) {
            if let id = existing?.remote[url], let uri = await dataURI(id) {
                out.remote[url] = id
                inline[url] = uri
                continue
            }
            guard fetchRemote else {
                out.failures["remote|" + url] = "这张网络图片尚未下载，重新导入这份美化时下载"
                continue
            }
            do {
                let data = try await CssRasterNet.fetch(url)
                let id = try await Task.detached(priority: .utility) {
                    try Images.save(data, maxPixel: CssRasterPlan.remoteMaxPixel)
                }.value
                out.remote[url] = id
                if let uri = await dataURI(id) { inline[url] = uri }
            } catch {
                out.failures["remote|" + url] = "网络图片下载失败：\(error.localizedDescription)"
            }
        }
        let prepared = CssRasterPlan.substitute(css, inline)
        let jobs = CssRasterPlan.jobs(compiled)
        guard !jobs.isEmpty else { return out }
        let shot = CssSnapshotter()
        for (i, job) in jobs.enumerated() {
            let id = CssRaster.id(job.key)
            guard i < CssRasterPlan.maxRenders else {
                out.failures[id] = "超过每份美化最多 \(CssRasterPlan.maxRenders) 张图的上限，这一块按原生样式显示"
                continue
            }
            do {
                out.images[id] = try await draw(job, css: prepared, shot: shot)
            } catch {
                out.failures[id] = error.localizedDescription
            }
        }
        shot.close()
        return out
    }

    /// 本机存着的图读成 data: 地址
    private static func dataURI(_ id: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let url = MediaStore.url(.images, id: id), let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            return "data:\(Images.mediaType(ext: url.pathExtension));base64,\(data.base64EncodedString())"
        }.value
    }

    private static func capture(_ job: CssRasterPlan.Job, css: String, shot: CssSnapshotter, measure: Bool) async throws -> CssCapture {
        let g = CssRasterPlan.canvas(job)
        let size = CGSize(width: g.width, height: g.height)
        var shots: [UIImage] = []
        for bg in ["#000000", "#ffffff"] {
            let html = CssRasterPlan.document(job, css: css, background: bg, measure: measure)
            guard await shot.load(html, size: size) else { throw StoreError(message: "画图超时，这一块按原生样式显示") }
            guard let img = await shot.snapshot(), img.cgImage != nil else {
                throw StoreError(message: "截图失败，这一块按原生样式显示")
            }
            shots.append(img)
        }
        let scale = shots[0].scale > 0 ? shots[0].scale : 1
        let w = Int((g.width * Double(scale)).rounded()), h = Int((g.height * Double(scale)).rounded())
        guard let b = shots[0].cgImage, let wt = shots[1].cgImage else { throw StoreError(message: "截图失败，这一块按原生样式显示") }
        let result = await Task.detached(priority: .utility) { () -> CssCapture? in
            guard let black = CssRasterPlan.rgba(b, width: w, height: h),
                  let white = CssRasterPlan.rgba(wt, width: w, height: h) else { return nil }
            let px = CssRasterPlan.unmatte(black: black, white: white)
            return CssCapture(px: px, width: w, height: h, scale: scale,
                           bounds: CssRasterPlan.alphaBounds(px, width: w, height: h))
        }.value
        guard let result else { throw StoreError(message: "截图失败，这一块按原生样式显示") }
        // 画布左上角在留白里，必须是透明的；不是就是截图没画出来（整张空白）
        guard result.px.count >= 4, result.px[3] <= 8 else { throw StoreError(message: "截图失败：画面为空，这一块按原生样式显示") }
        return result
    }

    private static func draw(_ job: CssRasterPlan.Job, css: String, shot: CssSnapshotter) async throws -> CssRasterImage {
        let g = CssRasterPlan.canvas(job)
        let full = try await capture(job, css: css, shot: shot, measure: false)
        let s = Double(full.scale)
        let element = CssPixelRect(x: Int((g.pad * s).rounded()), y: Int((g.pad * s).rounded()),
                                   w: Int((job.width * s).rounded()), h: Int((job.height * s).rounded()))
        var crop: CssPixelRect?
        switch job.kind {
        case .box:
            crop = full.bounds.map { $0.union(element) } ?? element
        case .icon, .decor:
            if job.withBackground {
                crop = try await capture(job, css: css, shot: shot, measure: true).bounds
            } else {
                crop = full.bounds
            }
        }
        guard let c = crop?.clamped(width: full.width, height: full.height) else {
            throw StoreError(message: "这一块没有画出任何内容")
        }
        guard let png = CssRasterPlan.png(full.px, width: full.width, crop: c, scale: full.scale) else {
            throw StoreError(message: "图片编码失败，这一块按原生样式显示")
        }
        let maxPixel = CGFloat(Swift.max(c.w, c.h))
        let id = try await Task.detached(priority: .utility) { try Images.save(png, maxPixel: maxPixel) }.value
        let rect = CGRect(x: Double(c.x) / s, y: Double(c.y) / s, width: Double(c.w) / s, height: Double(c.h) / s)
        return CssRasterPlan.image(job, imageId: id, crop: rect, pad: g.pad)
    }
}

/// 一张截好、去掉底色的画布（像素为预乘 RGBA）
struct CssCapture: Sendable {
    var px: [UInt8]
    var width: Int
    var height: Int
    var scale: CGFloat
    var bounds: CssPixelRect?
}

// MARK: - WebKit

/// 关起来的 WKWebView：不落盘、不跑脚本、不联网，只放行自己装进去的那一页。一份美化画完就关
@MainActor
final class CssSnapshotter: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private var pending: CssOneShot<Bool>?
    private var current: WKNavigation?
    private var allowNext = false
    private var loads = 0

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.suppressesIncrementalRendering = true
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        web = WKWebView(frame: CGRect(x: -4000, y: 0, width: 100, height: 100), configuration: cfg)
        super.init()
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isUserInteractionEnabled = false
        web.allowsLinkPreview = false
        web.overrideUserInterfaceStyle = .light
        // 放进窗口里（画面之外）WebKit 才老实画；没有窗口时照样试
        if let host = Self.host() { host.insertSubview(web, at: 0) }
    }

    private static func host() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    /// 装一页，等它画完。超时为 false
    func load(_ html: String, size: CGSize) async -> Bool {
        pending?.resume(false)
        pending = nil
        loads += 1
        let timeout = loads == 1 ? CssRasterPlan.firstTimeout : CssRasterPlan.renderTimeout
        web.frame = CGRect(x: -size.width - 4000, y: 0, width: size.width, height: size.height)
        allowNext = true
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let one = CssOneShot(c)
            pending = one
            current = web.loadHTMLString(html, baseURL: nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                one.resume(false)
            }
        }
        if !ok {
            web.stopLoading()
            return false
        }
        // 背景图解码、排版落定
        try? await Task.sleep(nanoseconds: 60_000_000)
        return true
    }

    func snapshot() async -> UIImage? {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        cfg.afterScreenUpdates = true
        let timeout = CssRasterPlan.renderTimeout
        return await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
            let one = CssOneShot(c)
            web.takeSnapshot(with: cfg) { image, _ in one.resume(image) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                one.resume(nil)
            }
        }
    }

    func close() {
        pending?.resume(false)
        pending = nil
        web.stopLoading()
        web.navigationDelegate = nil
        web.removeFromSuperview()
    }

    private func finish(_ navigation: WKNavigation?, _ ok: Bool) {
        guard navigation == nil || navigation === current else { return }
        pending?.resume(ok)
        pending = nil
    }

    // 只放行自己装进去的那一页；页面里的任何跳转、子框架一律拦下
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame == true, allowNext, navigationAction.navigationType == .other else {
            return .cancel
        }
        allowNext = false
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(navigation, true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(navigation, false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(navigation, false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(nil, false)
    }
}

/// 只回一次的等待：超时与完成谁先到算谁
final class CssOneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?

    init(_ c: CheckedContinuation<T, Never>) { cont = c }

    func resume(_ value: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
