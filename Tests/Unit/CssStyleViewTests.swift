import SwiftUI
import XCTest
@testable import Eira

/// 美化 CSS 照着画的那几样纯计算：渐变线、色标、圆角、行距、伪元素的字、钩子的层叠、生成器盖过手写 CSS。
/// CssCompiled 一律手写，不经过读 CSS 那一步
final class CssStyleViewTests: XCTestCase {
    private func near(_ a: UnitPoint, _ x: CGFloat, _ y: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, x, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(a.y, y, accuracy: 0.0001, file: file, line: line)
    }

    private let red = CssColor(r: 1, g: 0, b: 0, a: 1)
    private let blue = CssColor(r: 0, g: 0, b: 1, a: 1)

    // MARK: - 渐变

    func testGradientLineOnSquare() {
        var p = CssPaint.points(angle: 180)      // to bottom
        near(p.start, 0.5, 0); near(p.end, 0.5, 1)
        p = CssPaint.points(angle: 0)            // to top
        near(p.start, 0.5, 1); near(p.end, 0.5, 0)
        p = CssPaint.points(angle: 90)           // to right
        near(p.start, 0, 0.5); near(p.end, 1, 0.5)
        p = CssPaint.points(angle: 45)           // 左下到右上，正方形上正好落在两个角
        near(p.start, 0, 1); near(p.end, 1, 0)
        p = CssPaint.points(angle: 135)
        near(p.start, 0, 0); near(p.end, 1, 1)
    }

    func testGradientLineOnWideBox() {
        // 2:1 的盒子上 45 度：渐变线长 |w·sin| + |h·cos|，伸出盒子之外，两个角落在 0% 与 100% 的垂线上
        let p = CssPaint.points(angle: 45, size: CGSize(width: 2, height: 1))
        near(p.start, 0.125, 1.25); near(p.end, 0.875, -0.25)
        // 横着的不受宽高比影响
        let q = CssPaint.points(angle: 90, size: CGSize(width: 3, height: 1))
        near(q.start, 0, 0.5); near(q.end, 1, 0.5)
    }

    func testStopsMonotonicAndHardEdges() {
        let g = CssGradient(angle: 180, stops: [.init(color: red, at: 0.5), .init(color: blue, at: 0.3), .init(color: red, at: 1.4)])
        let s = CssPaint.stops(g)
        XCTAssertEqual(s.map(\.at), [0.5, 0.5, 1])   // 小于前一个按前一个算：同一位置为硬边
        XCTAssertEqual(s[1].color, blue)
    }

    func testRepeatingGradientTiles() {
        let g = CssGradient(angle: 90, stops: [.init(color: red, at: 0), .init(color: blue, at: 0.25)], repeating: true)
        let s = CssPaint.stops(g)
        XCTAssertEqual(s.first?.at, 0)
        XCTAssertEqual(s.last?.at ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(s.count, 8)
        // 不重复的照原样
        var plain = g
        plain.repeating = false
        XCTAssertEqual(CssPaint.stops(plain).count, 2)
    }

    // MARK: - 圆角

    func testCornerRadiusRules() {
        let box = CGSize(width: 100, height: 40)
        XCTAssertEqual(CssPaint.cornerRadius(px: 8, percent: nil, fallback: 14, size: box), 8)
        XCTAssertEqual(CssPaint.cornerRadius(px: nil, percent: nil, fallback: 14, size: box), 14)
        XCTAssertEqual(CssPaint.cornerRadius(px: 99, percent: nil, fallback: 14, size: box), 20)     // 不超过短边一半
        XCTAssertEqual(CssPaint.cornerRadius(px: nil, percent: 25, fallback: 14, size: box), 10)     // 百分比按短边
        XCTAssertEqual(CssPaint.cornerRadius(px: nil, percent: 50, fallback: 14, size: box), 20)
        XCTAssertEqual(CssPaint.cornerRadius(px: -3, percent: nil, fallback: 14, size: box), 0)
        var st = CssStyle()
        st.radiusPercent = 50
        XCTAssertTrue(CssPaint.isCapsule(st))
        st.radiusPercent = 30
        XCTAssertFalse(CssPaint.isCapsule(st))
        XCTAssertFalse(CssPaint.isCapsule(nil))
    }

    // MARK: - 文字

    func testLineSpacingFromLineHeight() {
        var st = CssStyle()
        XCTAssertNil(CssPaint.lineSpacing(st, fontSize: 14))
        st.lineHeight = 1.6
        XCTAssertEqual(CssPaint.lineSpacing(st, fontSize: 10) ?? 0, 4, accuracy: 0.0001)
        st.lineHeight = 1.0
        XCTAssertEqual(CssPaint.lineSpacing(st, fontSize: 10), 0)
        st.lineHeightPx = 20
        XCTAssertEqual(CssPaint.lineSpacing(st, fontSize: 10) ?? 0, 8, accuracy: 0.0001)
    }

    func testContentText() {
        XCTAssertEqual(CssPaint.contentText("\"Send\""), "Send")
        XCTAssertEqual(CssPaint.contentText("'Delivered'"), "Delivered")
        XCTAssertEqual(CssPaint.contentText("\"a\\Ab\""), "a\nb")
        XCTAssertEqual(CssPaint.contentText("none"), "")
        XCTAssertEqual(CssPaint.contentText("Send"), "Send")
        var st = CssStyle()
        st.content = "\"\""
        XCTAssertNil(st.contentText)
        st.content = "\"Send\""
        XCTAssertEqual(st.contentText, "Send")
    }

    func testWeights() {
        XCTAssertEqual(CssPaint.weight(nil), .regular)
        XCTAssertEqual(CssPaint.weight(700), .bold)
        XCTAssertEqual(CssPaint.weight(600), .semibold)
        XCTAssertEqual(CssPaint.weight(300), .light)
    }

    func testGenericFontFamilies() {
        XCTAssertEqual(CssFonts.pick(["serif"]), .serif)
        XCTAssertEqual(CssFonts.pick(["'ui-monospace'", "monospace"]), .mono)
        XCTAssertEqual(CssFonts.pick(nil), .system)
        XCTAssertEqual(CssFonts.pick(["sans-serif"]), .system)
    }

    func testDrawableLayersSkipImages() {
        let bg = CssBackground(layers: [.image(url: "https://a.example/x.png"), .color(red)])
        XCTAssertEqual(CssPaint.drawable(bg), [.color(red)])
        XCTAssertEqual(CssPaint.drawable(nil), [])
    }

    // MARK: - 层叠

    private func compiled(_ list: [(CssKey, CssStyle)]) -> CssCompiled {
        var c = CssCompiled()
        for (k, v) in list { c.styles[k] = v }
        return c
    }

    func testBaseThenSideBubbleCascade() {
        var base = CssStyle()
        base.color = red
        base.radius = 12
        base.padding = CssEdges(top: 4, right: 8, bottom: 4, left: 8)
        base.raw = ["a": "1", "b": "1"]
        var mine = CssStyle()
        mine.color = blue
        mine.radiusPercent = 50
        mine.raw = ["b": "2"]
        let c = compiled([(CssKey(hook: "bubble"), base), (CssKey(hook: "bubble-mine"), mine)])
        let m = c.resolve(["bubble", "bubble-mine"])
        XCTAssertEqual(m?.color, blue)                 // 具体一边的在后，盖过基础的
        XCTAssertNil(m?.radius)                        // 百分比圆角后写，像素圆角让位
        XCTAssertEqual(m?.radiusPercent, 50)
        XCTAssertEqual(m?.padding, base.padding)       // 没写的沿用基础的
        XCTAssertEqual(m?.raw, ["a": "1", "b": "2"])
        // 角色那一边只有基础的
        XCTAssertEqual(c.resolve(["bubble", "bubble-theirs"]), base)
        XCTAssertNil(c.resolve(["composer"]))
        XCTAssertTrue(c.has(["bubble"]))
        XCTAssertFalse(c.has(["send"]))
    }

    func testPressedLayersOverNormal() {
        var normal = CssStyle()
        normal.color = red
        normal.opacity = 1
        var pressed = CssStyle()
        pressed.opacity = 0.5
        let c = compiled([(CssKey(hook: "send"), normal), (CssKey(hook: "send", state: .pressed), pressed)])
        XCTAssertEqual(c.resolve(["send"], .pressed)?.opacity, 0.5)
        XCTAssertEqual(c.resolve(["send"], .pressed)?.color, red)
        XCTAssertEqual(c.resolve(["send"])?.opacity, 1)
        // 只写了按下的样子也算写过：分支按「写过没有」，按下的那一刻不换视图
        let only = compiled([(CssKey(hook: "plus", state: .pressed), pressed)])
        XCTAssertTrue(only.has(["composer-btn", "plus"]))
        XCTAssertNil(only.resolve(["composer-btn", "plus"]))
    }

    func testPseudoTextAndIconHidden() {
        var send = CssStyle()
        send.raw = ["iconHidden": "1"]
        var before = CssStyle()
        before.content = "\"Send\""
        var after = CssStyle()
        after.content = "\"Delivered\""
        let c = compiled([(CssKey(hook: "send"), send), (CssKey(hook: "send", part: .before), before),
                          (CssKey(hook: "msg-mine-last", part: .after), after)])
        XCTAssertTrue(c.resolve(["send"])?.iconHidden == true)
        XCTAssertEqual(c.pseudoText(["send"], .before), "Send")
        XCTAssertNil(c.pseudoText(["send"], .after))
        XCTAssertEqual(c.pseudoText(["msg-mine-last"], .after), "Delivered")
    }

    // MARK: - 生成器盖过手写 CSS（网页版生成器那一段带 !important）

    func testGeneratorFixedItemsWinOverBubbleCss() {
        var st = CssStyle()
        st.background = CssBackground(layers: [.color(red)])
        st.color = blue
        st.radius = 3
        st.padding = CssEdges(top: 1, right: 1, bottom: 1, left: 1)
        st.fontSize = 20
        st.opacity = 0.9
        var b = Skins.Bubble()
        XCTAssertEqual(b.overriding(st), st)          // 生成器什么都没定：CSS 原样
        b.bg = "#112233"
        b.fixed = ["r", "fs"]
        let out = b.overriding(st)
        XCTAssertNil(out.background)
        XCTAssertEqual(out.color, blue)
        XCTAssertNil(out.radius)
        XCTAssertNil(out.fontSize)
        XCTAssertEqual(out.padding, st.padding)
        XCTAssertEqual(out.opacity, 0.9)
        b.fg = "#ffffff"
        b.fixed.insert("px")
        XCTAssertNil(b.overriding(st).color)
        XCTAssertNil(b.overriding(st).padding)
    }

    // MARK: - 变量落到原生的几格

    func testVarsMapOntoKnobs() {
        var l = Skins.Look()
        Skins.applyVars(&l, ["ph-bubble-r": "22px", "ph-bubble-px": "10", "ph-bubble-py": "6px", "ph-bubble-fs": "16px",
                             "ph-bubble-gap": "20px", "ph-bubble-gap-in": "2px", "ph-avatar-size": "44px",
                             "ph-avatar-r": "12px", "ph-navbar-h": "56px", "ph-composer-h": "42px", "ph-composer-pad": "6px",
                             "ph-unknown": "3px"])
        XCTAssertEqual(l.mine.radius, 22)
        XCTAssertEqual(l.theirs.radius, 22)
        XCTAssertEqual(l.theirs.padX, 10)
        XCTAssertEqual(l.mine.padY, 6)
        XCTAssertEqual(l.mine.font, 16)
        XCTAssertEqual(l.gap, 20)
        XCTAssertEqual(l.gapIn, 2)
        XCTAssertEqual(l.avatarSize, 44)
        XCTAssertEqual(l.radius(44), 12)
        XCTAssertEqual(l.navbarH, 56)
        XCTAssertEqual(l.composerH, 42)
        XCTAssertEqual(l.composerPad, 6)
        // 夹在范围里；空表不动
        var m = Skins.Look()
        Skins.applyVars(&m, ["ph-bubble-fs": "200px", "ph-composer-h": "2px"])
        XCTAssertEqual(m.mine.font, 60)
        XCTAssertEqual(m.composerH, 24)
        var n = Skins.Look()
        Skins.applyVars(&n, [:])
        XCTAssertEqual(n, Skins.Look())
    }

    func testCssPxParsing() {
        XCTAssertEqual(Skins.cssPx("14px"), 14)
        XCTAssertEqual(Skins.cssPx(" 14.5 "), 14.5)
        XCTAssertEqual(Skins.cssPx("14px !important"), 14)
        XCTAssertNil(Skins.cssPx("1.2em"))
        XCTAssertNil(Skins.cssPx("50%"))
        XCTAssertEqual(Skins.cssPercent("50%"), 50)
        XCTAssertNil(Skins.cssPercent("50px"))
    }
}
