import XCTest
@testable import Eira

/// 网页版美化 CSS 读成原生样式（CssSkin.compile）。
/// 前一半拿 Tests/Fixtures/skins/ios6.css（真实的一份美化）逐项核对，后一半是切词与读值的边角
final class CssSkinTests: XCTestCase {
    // MARK: 工具

    private func ios6() throws -> CssCompiled {
        let url = Bundle(for: CssSkinTests.self).resourceURL!
            .appendingPathComponent("Fixtures").appendingPathComponent("skins").appendingPathComponent("ios6.css")
        let css = try String(contentsOf: url, encoding: .utf8)
        return CssSkin.compileUncached(css)
    }

    private func hex(_ v: UInt32, _ a: Double = 1) -> CssColor {
        CssColor(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: a)
    }

    private func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CssColor {
        CssColor(r: r / 255, g: g / 255, b: b / 255, a: a)
    }

    private func assertColor(_ c: CssColor?, _ want: CssColor, file: StaticString = #filePath, line: UInt = #line) {
        guard let c else { return XCTFail("没有颜色", file: file, line: line) }
        XCTAssertEqual(c.r, want.r, accuracy: 0.002, "r", file: file, line: line)
        XCTAssertEqual(c.g, want.g, accuracy: 0.002, "g", file: file, line: line)
        XCTAssertEqual(c.b, want.b, accuracy: 0.002, "b", file: file, line: line)
        XCTAssertEqual(c.a, want.a, accuracy: 0.002, "a", file: file, line: line)
    }

    private func gradients(_ st: CssStyle?) -> [CssGradient] {
        var out: [CssGradient] = []
        for layer in st?.background?.layers ?? [] {
            if case .gradient(let g) = layer { out.append(g) }
        }
        return out
    }

    private func images(_ st: CssStyle?) -> [String] {
        var out: [String] = []
        for layer in st?.background?.layers ?? [] {
            if case .image(let u) = layer { out.append(u) }
        }
        return out
    }

    private func colors(_ st: CssStyle?) -> [CssColor] {
        var out: [CssColor] = []
        for layer in st?.background?.layers ?? [] {
            if case .color(let c) = layer { out.append(c) }
        }
        return out
    }

    private func items(_ c: CssCompiled, _ selector: String, _ prop: String) -> [CssReport.Item] {
        c.report.items.filter { $0.selector == selector && $0.property == prop }
    }

    // MARK: ios6.css

    func testNavbar() throws {
        let c = try ios6()
        let nav = try XCTUnwrap(c.style("navbar"))
        let g = try XCTUnwrap(gradients(nav).first)
        XCTAssertEqual(g.angle, 180)
        XCTAssertEqual(g.stops.count, 2)
        assertColor(g.stops[0].color, hex(0xB5CADD))
        assertColor(g.stops[1].color, hex(0x5B7798))
        XCTAssertEqual(g.stops.map(\.at), [0, 1])
        assertColor(colors(nav).first, hex(0x5B7798))
        let bottom = try XCTUnwrap(nav.borderBottom)
        XCTAssertEqual(bottom.width, 1)
        assertColor(bottom.color, hex(0x465978))
        XCTAssertNil(nav.border)
        XCTAssertNil(nav.borderTop)
        let sh = try XCTUnwrap(nav.shadows)
        XCTAssertEqual(sh.count, 1)
        XCTAssertTrue(sh[0].inset)
        XCTAssertEqual(sh[0].x, 0)
        XCTAssertEqual(sh[0].y, 1)
        XCTAssertEqual(sh[0].blur, 0)
        assertColor(sh[0].color, rgba(255, 255, 255, 0.9))
    }

    func testNavTitle() throws {
        let c = try ios6()
        let t = try XCTUnwrap(c.style("nav-title"))
        assertColor(t.color, hex(0xFFFFFF))
        XCTAssertEqual(t.fontWeight, 700)
        XCTAssertEqual(t.fontSize, 20)
        XCTAssertEqual(t.textAlign, "center")
        let ts = try XCTUnwrap(t.textShadows)
        XCTAssertEqual(ts.count, 1)
        XCTAssertEqual(ts[0].x, 0)
        XCTAssertEqual(ts[0].y, -1)
        XCTAssertEqual(ts[0].blur, 0)
        assertColor(ts[0].color, rgba(0, 0, 0, 0.5))
        // 版式类的几项记为用上，原因写明
        let ws = items(c, ".ph-nav-title", "white-space")
        XCTAssertEqual(ws.first?.kind, .used)
        XCTAssertEqual(ws.first?.reason, "原生版的版式已经如此")
    }

    func testBubble() throws {
        let c = try ios6()
        let b = try XCTUnwrap(c.style("bubble"))
        let o = try XCTUnwrap(b.outline)
        XCTAssertEqual(o.width, 1)
        XCTAssertEqual(o.style, "solid")
        assertColor(o.color, rgba(129, 141, 154, 1))
        XCTAssertEqual(try XCTUnwrap(b.lineHeight), 1.55, accuracy: 0.0001)
        XCTAssertNil(b.lineHeightPx)
        XCTAssertEqual(try XCTUnwrap(b.letterSpacing), 0.32, accuracy: 0.0001)
        XCTAssertEqual(b.minWidth, 31)
        XCTAssertEqual(b.minHeight, 20)
        XCTAssertEqual(b.border?.width, 0)
        XCTAssertEqual(b.background?.size, "cover")
        XCTAssertEqual(b.background?.repeatImage, false)
        assertColor(b.color, hex(0x000000))

        let mine = try XCTUnwrap(c.style("bubble-mine"))
        let g = try XCTUnwrap(gradients(mine).first)
        XCTAssertEqual(g.angle, 180)
        assertColor(g.stops.first?.color, rgba(151, 198, 252))
        assertColor(g.stops.last?.color, rgba(207, 236, 254))
        // `.ph-bubble-mine *` 的文字阴影记在气泡本身
        assertColor(mine.textShadows?.first?.color, rgba(255, 255, 255, 0.8))
        let star = items(c, ".ph-bubble-mine *", "text-shadow")
        XCTAssertEqual(star.first?.kind, .approx)

        // 高光层：mix-blend-mode 留给第二步
        let hi = items(c, ".ph-bubble::before", "mix-blend-mode")
        XCTAssertEqual(hi.first?.kind, .approx)
        XCTAssertEqual(hi.first?.reason, "第二步画成图片后还原")
        XCTAssertEqual(c.style("bubble", .normal, .before)?.raw["mix-blend-mode"], "overlay")
        XCTAssertEqual(gradients(c.style("bubble", .normal, .before)).first?.stops.count, 2)
    }

    func testTailVarsAndAfter() throws {
        let c = try ios6()
        let tailURL = "https://imgbed.heliar.top/i/Uv2Qx6HgepYZqjjm_8455832DE0C33DCCA6B0F56B2A0E8E1E.png"
        XCTAssertEqual(c.vars["tail-mine"], "url(\"\(tailURL)\")")
        XCTAssertEqual(c.vars["tail-mine-scale"], "0.3")
        XCTAssertEqual(c.vars["tail-mine-x"], "19px")
        XCTAssertEqual(c.vars["tail-mine-y"], "14px")
        XCTAssertEqual(c.vars["tail-mine-rotate"], "-3deg")
        XCTAssertEqual(c.vars["tail-theirs-y"], "17px")
        XCTAssertEqual(c.vars["ph-bubble-r"], "17px")
        XCTAssertEqual(c.vars["ph-composer-h"], "30px")
        XCTAssertEqual(c.vars["ph-navbar-h"], "44px")
        XCTAssertEqual(items(c, ".ph-screen", "--ph-bubble-r").first?.kind, .used)

        let after = try XCTUnwrap(c.style("bubble-mine", .normal, .after))
        let t = try XCTUnwrap(after.transform)
        XCTAssertEqual(t.dx, 19)
        XCTAssertEqual(t.dy, 14)
        XCTAssertEqual(t.rotate, -3)
        XCTAssertEqual(t.scaleX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(t.scaleY, 0.3, accuracy: 0.0001)
        XCTAssertEqual(images(after), [tailURL])
        XCTAssertEqual(after.width, 38)
        XCTAssertEqual(after.height, 38)
        XCTAssertEqual(after.raw["right"], "0")
        // 伪元素上的图片记为近似，留给第二步
        XCTAssertEqual(items(c, ".ph-bubble-mine::after", "background-image").first?.kind, .approx)
        // 共用的 ::after：!important 的 background-size
        XCTAssertEqual(c.style("bubble", .normal, .after)?.background?.size, "contain")

        let theirs = try XCTUnwrap(c.style("bubble-theirs", .normal, .after)?.transform)
        XCTAssertEqual(theirs.dx, -21)
        XCTAssertEqual(theirs.dy, 17)
        XCTAssertEqual(theirs.rotate, 3)
    }

    func testSend() throws {
        let c = try ios6()
        let send = try XCTUnwrap(c.style("send"))
        let g = try XCTUnwrap(gradients(send).first)
        XCTAssertEqual(g.stops.count, 4)
        XCTAssertEqual(g.stops.map(\.at), [0, 0.5, 0.5, 1])
        assertColor(g.stops[1].color, hex(0x6195E6))
        assertColor(g.stops[2].color, hex(0x3E7ADD))
        XCTAssertEqual(send.radius, 15)
        XCTAssertEqual(send.padding, CssEdges(top: 0, right: 12, bottom: 0, left: 12))
        XCTAssertEqual(send.border?.width, 1)
        assertColor(send.border?.color, hex(0x1A3E6F))
        assertColor(send.color, .clear)
        XCTAssertEqual(send.fontSize, 0)
        XCTAssertEqual(send.raw["iconHidden"], "1")
        XCTAssertEqual(send.shadows?.count, 2)

        let before = try XCTUnwrap(c.style("send", .normal, .before))
        XCTAssertEqual(before.content, "Send")
        XCTAssertEqual(before.fontSize, 13)
        XCTAssertEqual(before.fontWeight, 700)
        XCTAssertEqual(before.fontFamily, ["Helvetica", "Arial", "sans-serif"])
        assertColor(before.color, hex(0xFFFFFF))
        XCTAssertEqual(before.padding?.bottom, 1)

        let pressed = try XCTUnwrap(c.style("send", .pressed))
        let pg = try XCTUnwrap(gradients(pressed).first)
        XCTAssertEqual(pg.stops.map(\.at), [0, 0.5, 0.5, 1])
        assertColor(pg.stops[0].color, hex(0x5F85BB))
        assertColor(pg.stops[3].color, hex(0x1D4B98))
        let ps = try XCTUnwrap(pressed.shadows)
        XCTAssertEqual(ps.count, 1)
        XCTAssertTrue(ps[0].inset)
        XCTAssertEqual(ps[0].blur, 5)
    }

    func testComposer() throws {
        let c = try ios6()
        let bar = try XCTUnwrap(c.style("composer"))
        XCTAssertEqual(bar.gap, 5)
        XCTAssertEqual(bar.borderTop?.width, 1)
        XCTAssertEqual(bar.shadows?.count, 2)
        XCTAssertEqual(bar.shadows?.first?.inset, true)
        XCTAssertEqual(bar.shadows?.last?.inset, false)

        let input = try XCTUnwrap(c.style("composer-input"))
        XCTAssertEqual(input.radius, 25)
        XCTAssertEqual(input.outline?.width, 0)
        XCTAssertEqual(input.border?.width, 1)
        assertColor(input.border?.color, hex(0xB3B2B4))
        XCTAssertEqual(input.lineHeightPx, 10)

        let focused = try XCTUnwrap(c.style("composer-input", .focused))
        let fb = try XCTUnwrap(focused.border)
        XCTAssertEqual(fb.width, 1)
        assertColor(fb.color, hex(0x888888))
        XCTAssertEqual(focused.shadows?.count, 1)
        assertColor(focused.shadows?.first?.color, rgba(0, 0, 0, 0.1))

        assertColor(c.style("composer-input", .normal, .placeholder)?.color, hex(0x8E8E93))

        let btn = try XCTUnwrap(c.style("composer-btn"))
        XCTAssertEqual(btn.radiusPercent, 50)
        XCTAssertNil(btn.radius)
        XCTAssertNotNil(c.style("composer-btn", .pressed)?.background)

        XCTAssertEqual(c.style("plus")?.raw["iconHidden"], "1")
        XCTAssertEqual(c.style("plus", .normal, .before)?.width, 20)
    }

    func testBackAndActions() throws {
        let c = try ios6()
        let back = try XCTUnwrap(c.style("back"))
        XCTAssertEqual(back.raw["iconHidden"], "1")
        XCTAssertEqual(back.transform?.dy, 8)
        XCTAssertEqual(back.border?.width, 0)
        XCTAssertEqual(back.width, 85)
        assertColor(colors(back).first, .clear)
        let before = try XCTUnwrap(c.style("back", .normal, .before))
        XCTAssertEqual(before.content, "")
        XCTAssertTrue(images(before).first?.hasPrefix("data:image/svg+xml,%3Csvg") == true)
        XCTAssertEqual(before.background?.size, "contain")
        XCTAssertEqual(before.background?.position, "left center")
        XCTAssertEqual(before.raw["filter"], "drop-shadow(0 1px 0 rgba(255, 255, 255, 0.5))")
        XCTAssertEqual(c.style("nav-action")?.raw["iconHidden"], "1")
    }

    func testLastMessageAndTimeSep() throws {
        let c = try ios6()
        let after = try XCTUnwrap(c.style("msg-mine-last", .normal, .after))
        XCTAssertEqual(after.content, "Delivered")
        XCTAssertEqual(after.fontSize, 11)
        XCTAssertEqual(after.fontWeight, 700)
        XCTAssertEqual(after.lineHeight, 1)
        XCTAssertEqual(c.style("msg-mine-last")?.padding?.bottom, 15)
        XCTAssertEqual(items(c, ".ph-msg-mine:not(:has(~ .ph-msg-mine))::after", "content").first?.kind, .used)

        let sep = try XCTUnwrap(c.style("time-sep"))
        XCTAssertEqual(sep.margin?.top, 24)
        XCTAssertEqual(sep.margin?.bottom, 8)
        XCTAssertEqual(sep.fontSize, 11)
        XCTAssertEqual(sep.lineHeight, 1.5)
        XCTAssertEqual(sep.fontFamily?.first, "Helvetica Neue")
        let sb = try XCTUnwrap(c.style("time-sep", .normal, .before))
        XCTAssertEqual(sb.content, "iMessage")
        XCTAssertEqual(sb.fontSize, 12)
        XCTAssertEqual(sb.fontWeight, 400)
        let lines = gradients(sb)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first?.repeating, true)
        XCTAssertEqual(lines.first?.angle, 90)
        XCTAssertEqual(items(c, ".ph-time-sep::before", "background-size").first?.kind, .approx)
        // 会挪动元素的写法跳过
        XCTAssertEqual(items(c, ".ph-time-sep", "flex-direction").first?.kind, .skipped)
    }

    func testTransferAndReport() throws {
        let c = try ios6()
        let tr = try XCTUnwrap(c.style("transfer"))
        XCTAssertEqual(gradients(tr).first?.angle, 244)
        assertColor(gradients(tr).first?.stops.first?.color, hex(0xD6D6D6))
        XCTAssertEqual(tr.radius, 19)
        XCTAssertEqual(tr.minHeight, 93)
        XCTAssertEqual(items(c, ".ph-transfer *", "border-color").first?.kind, .skipped)

        XCTAssertEqual(items(c, ".ph-chat-body::before", "position").first?.kind, .approx)
        XCTAssertFalse(c.report.items.isEmpty)
        for it in c.report.items { XCTAssertFalse(it.reason.isEmpty, "\(it.selector) \(it.property)") }
        // 整份读下来，读不懂的值一个都没有
        XCTAssertTrue(c.report.items.filter({ $0.reason == "这个值无法识别" }).isEmpty,
                      c.report.items.filter({ $0.reason == "这个值无法识别" }).map { "\($0.selector) \($0.property)" }.joined(separator: "; "))
        XCTAssertGreaterThan(c.report.used, 60)
    }

    func testCacheReturnsSameResult() throws {
        let css = ".ph-send { color: red }"
        XCTAssertEqual(CssSkin.compile(css), CssSkin.compile(css))
        XCTAssertEqual(CssSkin.compile(css), CssSkin.compileUncached(css))
    }

    // MARK: 切词的边角

    func testDataURIWithSemicolons() {
        let c = CssSkin.compileUncached("""
        .ph-send::before { background-image: url(data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg'></svg>); color: red; }
        .ph-plus::before { background-image: url("data:image/svg+xml;charset=utf-8,a);b;c"); content: "/* 不是注释 */"; }
        /* .ph-send { color: blue } */
        """)
        let send = c.style("send", .normal, .before)
        XCTAssertEqual(images(send), ["data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg'></svg>"])
        assertColor(send?.color, hex(0xFF0000))
        XCTAssertNil(c.style("send"))
        let plus = c.style("plus", .normal, .before)
        XCTAssertEqual(images(plus), ["data:image/svg+xml;charset=utf-8,a);b;c"])
        XCTAssertEqual(plus?.content, "/* 不是注释 */")
    }

    func testVarFallbacksAndCycles() {
        let c = CssSkin.compileUncached("""
        :root { --a: var(--b); --b: var(--a); --base: 10px; --pad: var(--base); }
        .ph-send { color: var(--missing, var(--also-missing, #ff0000)); padding: var(--pad) var(--nope, 4px); }
        .ph-plus { color: var(--a); }
        .ph-back { box-shadow: var(--sh, 0 1px 2px rgba(0, 0, 0, 0.5), inset 0 0 1px red); }
        """)
        let send = c.style("send")
        assertColor(send?.color, hex(0xFF0000))
        XCTAssertEqual(send?.padding, CssEdges(top: 10, right: 4, bottom: 10, left: 4))
        XCTAssertNil(c.style("plus")?.color)
        XCTAssertEqual(items(c, ".ph-plus", "color").first?.kind, .skipped)
        XCTAssertEqual(items(c, ".ph-plus", "color").first?.reason, "用到的变量没有定义")
        XCTAssertEqual(c.vars["pad"], "10px")
        XCTAssertNil(c.vars["a"])
        // 后备值里的逗号不切开
        XCTAssertEqual(c.style("back")?.shadows?.count, 2)
    }

    func testCommaInsideNotAndSelectorKinds() {
        let c = CssSkin.compileUncached("""
        .ph-bubble:not(.x, .y), .ph-send { color: red; }
        .msg { color: blue; }
        .ph-nothing { color: blue; }
        .ph-send:hover { color: blue; }
        .ph-send + .ph-plus { color: blue; }
        .ph-navbar .ph-back { color: green; }
        :where(.ph-tab) { color: green; }
        .ph-bubble.ph-bubble-mine { color: green; }
        .ph-msg-theirs:last-child .ph-bubble { color: green; }
        """)
        assertColor(c.style("send")?.color, hex(0xFF0000))
        XCTAssertNil(c.style("bubble"))
        let notItem = c.report.items.first(where: { $0.selector == ".ph-bubble:not(.x, .y)" })
        XCTAssertEqual(notItem?.kind, .skipped)
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".msg" })?.kind, .skipped)
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-nothing" })?.reason, "契约里没有 .ph-nothing，原生版没有这个元素")
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-send:hover" })?.kind, .skipped)
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-send + .ph-plus" })?.kind, .skipped)
        // 前面挂着别的钩子：按最后一个处理，记为近似
        assertColor(c.style("back")?.color, hex(0x008000))
        XCTAssertEqual(items(c, ".ph-navbar .ph-back", "color").first?.kind, .approx)
        assertColor(c.style("tab")?.color, hex(0x008000))
        assertColor(c.style("bubble-mine")?.color, hex(0x008000))
        XCTAssertNil(c.style("bubble-mine-last"))
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-msg-theirs:last-child .ph-bubble" })?.kind, .skipped)
    }

    func testImportantSpecificityAndOrder() {
        let c = CssSkin.compileUncached("""
        .ph-send { color: red !important; }
        .ph-send { color: blue; }
        .ph-plus { color: red; }
        .ph-plus { color: blue; }
        .ph-bubble.ph-bubble-mine { color: red; }
        .ph-bubble-mine { color: blue; }
        .ph-back { background: red; }
        .ph-back { background-image: linear-gradient(red, blue); }
        .ph-tab { background-image: linear-gradient(red, blue); }
        .ph-tab { background: green; }
        .ph-tab-on { color: red ! important; color: blue; }
        """)
        assertColor(c.style("send")?.color, hex(0xFF0000))
        assertColor(c.style("plus")?.color, hex(0x0000FF))
        assertColor(c.style("bubble-mine")?.color, hex(0xFF0000))
        // 先简写后单项：两样都在
        XCTAssertEqual(gradients(c.style("back")).count, 1)
        assertColor(colors(c.style("back")).first, hex(0xFF0000))
        // 先单项后简写：简写把图片清掉
        XCTAssertTrue(gradients(c.style("tab")).isEmpty)
        assertColor(colors(c.style("tab")).first, hex(0x008000))
        assertColor(c.style("tab-on")?.color, hex(0xFF0000))
    }

    func testAtRules() {
        let c = CssSkin.compileUncached("""
        @charset "utf-8";
        @import url("x.css");
        @media (prefers-color-scheme: dark) { .ph-send { color: red; } }
        @media (prefers-color-scheme: light) { .ph-plus { color: red; } }
        @media (max-width: 400px) { .ph-back { color: red; } }
        @media screen { .ph-tab { color: red; } }
        @keyframes pop { from { opacity: 0 } to { opacity: 1 } }
        @font-face { font-family: X; src: url(x.woff); }
        .ph-navbar { animation: pop 1s; display: none; }
        """)
        XCTAssertNil(c.style("send"))
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-send" })?.reason, "深色模式的规则暂不读取")
        assertColor(c.style("plus")?.color, hex(0xFF0000))
        XCTAssertNil(c.style("back"))
        assertColor(c.style("tab")?.color, hex(0xFF0000))
        XCTAssertEqual(c.report.items.first(where: { $0.selector.hasPrefix("@keyframes") })?.reason, "动画原生版暂不读取")
        XCTAssertEqual(c.report.items.first(where: { $0.selector.hasPrefix("@font-face") })?.reason, "自定义字体原生版暂不读取")
        XCTAssertEqual(c.report.items.first(where: { $0.selector.hasPrefix("@import") })?.kind, .skipped)
        XCTAssertEqual(items(c, ".ph-navbar", "animation").first?.kind, .skipped)
        XCTAssertEqual(c.style("navbar")?.hidden, true)
        // 只有 .ph-navbar 那两条与 @ 规则进了账，@charset 不记
        XCTAssertNil(c.report.items.first(where: { $0.selector.hasPrefix("@charset") }))
    }

    // MARK: 读值

    func testColorFormats() {
        let ctx = CssValueContext()
        assertColor(CssVal.color("#abc", ctx), hex(0xAABBCC))
        assertColor(CssVal.color("#abcd", ctx), hex(0xAABBCC, Double(0xDD) / 255))
        assertColor(CssVal.color("#AABBCC", ctx), hex(0xAABBCC))
        assertColor(CssVal.color("#aabbcc80", ctx), hex(0xAABBCC, Double(0x80) / 255))
        assertColor(CssVal.color("rgb(255 0 0 / 50%)", ctx), rgba(255, 0, 0, 0.5))
        assertColor(CssVal.color("rgba(0,0,0,.5)", ctx), rgba(0, 0, 0, 0.5))
        assertColor(CssVal.color("RGB(100%, 0%, 0%)", ctx), rgba(255, 0, 0))
        assertColor(CssVal.color("hsl(120, 100%, 50%)", ctx), rgba(0, 255, 0))
        assertColor(CssVal.color("hsla(0.5turn 100% 50% / 0.25)", ctx), rgba(0, 255, 255, 0.25))
        assertColor(CssVal.color("rebeccapurple", ctx), hex(0x663399))
        assertColor(CssVal.color("transparent", ctx), .clear)
        var red = CssValueContext()
        red.color = rgba(255, 0, 0)
        assertColor(CssVal.color("currentColor", red), rgba(255, 0, 0))
        XCTAssertNil(CssVal.color("#abcde", ctx))
        XCTAssertNil(CssVal.color("notacolor", ctx))
        XCTAssertNil(CssVal.color("rgb(1, 2)", ctx))
    }

    func testLengthsAnglesAndCalc() {
        var ctx = CssValueContext()
        ctx.fontSize = 10
        XCTAssertEqual(CssVal.length("12px", ctx), .px(12))
        XCTAssertEqual(CssVal.length("1.5em", ctx), .px(15))
        XCTAssertEqual(CssVal.length(".5rem", ctx), .px(8))
        XCTAssertEqual(CssVal.length("50%", ctx), .percent(50))
        XCTAssertEqual(CssVal.length("0", ctx), .px(0))
        XCTAssertNil(CssVal.length("12", ctx))
        XCTAssertEqual(CssVal.length("calc(10px + 2em)", ctx), .px(30))
        XCTAssertEqual(CssVal.length("calc((4px + 2px) * 2)", ctx), .px(12))
        XCTAssertNil(CssVal.length("calc(50% - 40px)", ctx))
        XCTAssertEqual(CssVal.angle("0.25turn"), 90)
        XCTAssertEqual(CssVal.angle("-3deg"), -3)
        XCTAssertEqual(try XCTUnwrap(CssVal.angle("3.14159265rad")), 180, accuracy: 0.001)
        XCTAssertEqual(CssScan.number("1e2px")?.value, 100)
        XCTAssertEqual(CssScan.number("2em")?.unit, "em")
    }

    func testGradients() throws {
        let ctx = CssValueContext()
        let a = try XCTUnwrap(CssVal.gradient("linear-gradient(to right, red, green, blue)", ctx))
        XCTAssertEqual(a.gradient.angle, 90)
        XCTAssertEqual(a.gradient.stops.map(\.at), [0, 0.5, 1])
        XCTAssertFalse(a.approx)
        let b = try XCTUnwrap(CssVal.gradient("linear-gradient(red 50%, blue 20%)", ctx))
        XCTAssertEqual(b.gradient.angle, 180)
        XCTAssertEqual(b.gradient.stops.map(\.at), [0.5, 0.5])
        let c = try XCTUnwrap(CssVal.gradient("linear-gradient(to top left, red 0 40%, blue)", ctx))
        XCTAssertEqual(c.gradient.angle, 315)
        XCTAssertEqual(c.gradient.stops.map(\.at), [0, 0.4, 1])
        var sized = CssValueContext()
        sized.height = 40
        let d = try XCTUnwrap(CssVal.gradient("repeating-linear-gradient(red, red 10px, blue 10px, blue 20px)", sized))
        XCTAssertTrue(d.gradient.repeating)
        XCTAssertEqual(d.gradient.stops.map(\.at), [0, 0.25, 0.25, 0.5])
        XCTAssertFalse(d.approx)
        let e = try XCTUnwrap(CssVal.gradient("repeating-linear-gradient(red, red 10px, blue 10px)", ctx))
        XCTAssertTrue(e.approx)
        let f = try XCTUnwrap(CssVal.gradient("-webkit-linear-gradient(top, red, blue)", ctx))
        XCTAssertEqual(f.gradient.angle, 180)
        XCTAssertNil(CssVal.gradient("radial-gradient(red, blue)", ctx))
    }

    func testShadowsTransformsAndShorthands() throws {
        let ctx = CssValueContext()
        let s = try XCTUnwrap(CssVal.shadows("inset 0 2px 4px rgba(0,0,0,.65), 0 1px 0 #fff", ctx, text: false))
        XCTAssertEqual(s.count, 2)
        XCTAssertTrue(s[0].inset)
        XCTAssertEqual(s[0].blur, 4)
        XCTAssertEqual(s[1].y, 1)
        XCTAssertEqual(CssVal.shadows("none", ctx, text: false), [])
        XCTAssertNil(CssVal.shadows("inset 0 1px red", ctx, text: true))

        let t = try XCTUnwrap(CssVal.transform("translateX(4px) translateY(-2px) rotate(0.5turn) scale(2, 3)", ctx))
        XCTAssertEqual(t.transform, CssTransform(dx: 4, dy: -2, rotate: 180, scaleX: 2, scaleY: 3))
        XCTAssertFalse(t.approx)
        XCTAssertTrue(try XCTUnwrap(CssVal.transform("rotate(10deg) translate(5px)", ctx)).approx)
        XCTAssertTrue(try XCTUnwrap(CssVal.transform("skewX(10deg)", ctx)).approx)

        let c = CssSkin.compileUncached("""
        .ph-send { font: italic bold 14px/20px "PingFang SC", sans-serif; padding: 1px 2px 3px; margin: 4px;
                   border-radius: 50%; border-left: 2px dashed red; border-right: 2px dashed red; }
        .ph-plus { border-width: 1px 2px; border-style: solid; border-color: red; letter-spacing: 0.1em; font-size: 20px; }
        """)
        let send = try XCTUnwrap(c.style("send"))
        XCTAssertEqual(send.fontWeight, 700)
        XCTAssertEqual(send.fontSize, 14)
        XCTAssertEqual(send.lineHeightPx, 20)
        XCTAssertEqual(send.fontFamily, ["PingFang SC", "sans-serif"])
        XCTAssertEqual(send.padding, CssEdges(top: 1, right: 2, bottom: 3, left: 2))
        XCTAssertEqual(send.margin, CssEdges(top: 4, right: 4, bottom: 4, left: 4))
        XCTAssertEqual(send.radiusPercent, 50)
        XCTAssertEqual(send.border?.style, "dashed")
        XCTAssertEqual(send.border?.width, 2)
        XCTAssertNil(send.borderTop)
        let plus = try XCTUnwrap(c.style("plus"))
        XCTAssertEqual(plus.border?.width, 2)
        XCTAssertEqual(plus.borderTop?.width, 1)
        XCTAssertEqual(plus.borderBottom?.width, 1)
        XCTAssertEqual(try XCTUnwrap(plus.letterSpacing), 2, accuracy: 0.0001)
    }
}
