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
        // 深色模式的规则另读一份，常规那一份里没有
        XCTAssertNil(c.style("send"))
        assertColor(c.dark[CssKey(hook: "send")]?.color, hex(0xFF0000))
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-send" })?.reason, "深色模式：已读取")
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-send" })?.kind, .used)
        assertColor(c.style("plus")?.color, hex(0xFF0000))
        XCTAssertNil(c.style("back"))
        assertColor(c.style("tab")?.color, hex(0xFF0000))
        XCTAssertNil(c.report.items.first(where: { $0.selector.hasPrefix("@keyframes") && $0.kind != .used }))
        XCTAssertEqual(c.report.items.first(where: { $0.selector.hasPrefix("@font-face") })?.reason, "自定义字体原生版暂不读取")
        XCTAssertEqual(c.report.items.first(where: { $0.selector.hasPrefix("@import") })?.kind, .skipped)
        XCTAssertEqual(items(c, ".ph-navbar", "animation").first?.kind, .used)
        let an = c.style("navbar")?.animations ?? []
        XCTAssertEqual(an.count, 1)
        XCTAssertEqual(an.first?.name, "pop")
        XCTAssertEqual(an.first?.duration, 1)
        XCTAssertEqual(an.first?.frames.map(\.at), [0, 1])
        XCTAssertEqual(an.first?.frames.map(\.opacity), [0, 1])
        XCTAssertEqual(c.style("navbar")?.hidden, true)
        // @charset 不记
        XCTAssertNil(c.report.items.first(where: { $0.selector.hasPrefix("@charset") }))
    }

    // MARK: 第三步：结构写法

    func testStructuralSelectors() {
        let c = CssSkin.compileUncached("""
        .ph-bubble:first-child { color: red; }
        .ph-msg-theirs:first-of-type { color: red; }
        .ph-chat-row:last-child { color: red; }
        .ph-bubble-mine:last-child::after { content: "x"; }
        .ph-col > .ph-bubble:last-child { color: red; }
        .ph-col .ph-bubble-mine:last-child { color: blue; }
        .ph-msg-theirs .ph-col > .ph-bubble:last-child { color: green; }
        .ph-col > .ph-bubble.ph-bubble-mine:first-child { color: green; }
        .ph-list-item:nth-child(odd) { color: red; }
        .ph-list-item:nth-child(2n) { color: blue; }
        .ph-moment:nth-child(2n + 1) { color: green; }
        .ph-moment:nth-of-type(even) { color: blue; }
        .ph-list-title:nth-child(3n+1) { color: red; }
        .ph-msg-mine + .ph-msg-mine { margin-top: 2px; }
        .ph-msg-theirs + .ph-msg-theirs { margin-top: 3px; }
        .ph-chat-body .ph-msg + .ph-msg { margin-top: 4px; }
        .ph-msg-mine + .ph-msg-theirs { color: red; }
        .ph-msg-mine ~ .ph-msg-mine { color: red; }
        .ph-msg:not(.ph-msg-mine) { color: red; }
        .ph-msg-theirs { color: blue; }
        .ph-bubble:not(.ph-bubble-mine) { padding: 5px; }
        .ph-bubble:not(.ph-bubble-theirs) { padding: 6px; }
        .ph-send:not(.ph-plus) { color: red; }
        .ph-bubble:first-child:last-child { color: red; }
        .ph-msg-theirs:last-child .ph-bubble { color: green; }
        """)
        assertColor(c.style("bubble-first")?.color, hex(0xFF0000))
        assertColor(c.style("msg-theirs-first")?.color, hex(0xFF0000))
        assertColor(c.style("chat-row-last")?.color, hex(0xFF0000))
        XCTAssertEqual(c.style("bubble-mine-last", .normal, .after)?.content, "x")
        // 在 .ph-col 里的最后一个气泡：一轮的最后一个
        assertColor(c.style("bubble-tail")?.color, hex(0xFF0000))
        assertColor(c.style("bubble-mine-tail")?.color, hex(0x0000FF))
        assertColor(c.style("bubble-theirs-tail")?.color, hex(0x008000))
        assertColor(c.style("bubble-mine-first")?.color, hex(0x008000))
        XCTAssertEqual(items(c, ".ph-col > .ph-bubble:last-child", "color").first?.kind, .used)
        XCTAssertNil(c.style("bubble-last"))
        assertColor(c.style("list-item-odd")?.color, hex(0xFF0000))
        assertColor(c.style("list-item-even")?.color, hex(0x0000FF))
        assertColor(c.style("moment-odd")?.color, hex(0x008000))
        assertColor(c.style("moment-even")?.color, hex(0x0000FF))
        XCTAssertNil(c.style("list-title"))
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-list-title:nth-child(3n+1)" })?.reason,
                       "这种 :nth-child 写法原生版不认，只认第奇数条与第偶数条")
        // 连发
        XCTAssertEqual(c.style("msg-mine-cont")?.margin?.top, 2)
        XCTAssertEqual(c.style("msg-theirs-cont")?.margin?.top, 3)
        XCTAssertEqual(c.style("msg-cont")?.margin?.top, 4)
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-msg-mine + .ph-msg-theirs" })?.kind, .skipped)
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-msg-mine ~ .ph-msg-mine" })?.kind, .skipped)
        // :not(.ph-msg-mine) 即对方；特异度按两个类算，压过后写的 .ph-msg-theirs
        assertColor(c.style("msg-theirs")?.color, hex(0xFF0000))
        XCTAssertNil(c.style("msg"))
        XCTAssertEqual(c.style("bubble-theirs")?.padding?.top, 5)
        XCTAssertEqual(c.style("bubble-mine")?.padding?.top, 6)
        XCTAssertNil(c.style("send"))
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-send:not(.ph-plus)" })?.kind, .skipped)
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-bubble:first-child:last-child" })?.reason,
                       "几种位置条件写在一起，原生版不认")
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-msg-theirs:last-child .ph-bubble" })?.kind, .skipped)
        // 派生钩子名拆得回去
        XCTAssertEqual(CssStructural.split("bubble-mine-tail")?.base, "bubble-mine")
        XCTAssertEqual(CssStructural.split("msg-mine-cont")?.suffix, "-cont")
    }

    func testWhereIsExpansion() {
        let c = CssSkin.compileUncached("""
        .ph-plus { color: blue; }
        :where(.ph-send, .ph-plus) { color: red; }
        :is(.ph-tab, .ph-tab-on):active { color: green; }
        .ph-navbar :is(.ph-back, .ph-nav-title) { font-size: 20px; }
        :is(.ph-nav-action, .ph-chat .ph-badge) { padding: 7px; }
        :where(.ph-msg-mine, .ph-msg-theirs):last-child { margin-bottom: 9px; }
        """)
        assertColor(c.style("send")?.color, hex(0xFF0000))
        // :where() 的特异度为 0，压不过前面的 .ph-plus
        assertColor(c.style("plus")?.color, hex(0x0000FF))
        assertColor(c.style("tab", .pressed)?.color, hex(0x008000))
        assertColor(c.style("tab-on", .pressed)?.color, hex(0x008000))
        XCTAssertEqual(c.style("back")?.fontSize, 20)
        XCTAssertEqual(c.style("nav-title")?.fontSize, 20)
        XCTAssertEqual(c.style("nav-action")?.padding?.top, 7)
        XCTAssertNil(c.style("badge"))
        XCTAssertTrue(c.report.items.contains(where: {
            $0.selector == ":is(.ph-nav-action, .ph-chat .ph-badge)" && $0.kind == .skipped && $0.property.isEmpty
        }))
        XCTAssertEqual(c.style("msg-mine-last")?.margin?.bottom, 9)
        XCTAssertEqual(c.style("msg-theirs-last")?.margin?.bottom, 9)
    }

    func testQuoteInPattern() {
        let c = CssSkin.compileUncached("""
        .ph-quote { color: red; }
        .ph-col:has(.ph-quote-in) > .ph-quote { display: none; }
        .ph-msg:has(.ph-quote-in) > .ph-quote { color: blue; }
        .ph-bubble:has(.ph-send) { color: blue; }
        """)
        let q = c.style("quote")
        XCTAssertEqual(q?.hidden, true)
        XCTAssertEqual(q?.raw["whenQuoteIn"], "1")
        assertColor(q?.color, hex(0xFF0000))
        let it = items(c, ".ph-col:has(.ph-quote-in) > .ph-quote", "display").first
        XCTAssertEqual(it?.kind, .approx)
        XCTAssertEqual(it?.reason, "只在气泡里带引用时生效，原生版按近似处理")
        XCTAssertEqual(c.report.items.first(where: { $0.selector == ".ph-msg:has(.ph-quote-in) > .ph-quote" })?.kind, .skipped)
        XCTAssertNil(c.style("bubble"))
    }

    // MARK: 第三步：动画

    func testKeyframesParsing() throws {
        let c = CssSkin.compileUncached("""
        :root { --lo: 0.2; }
        @keyframes pop {
          from { opacity: 0; transform: scale(0.5); }
          50% { transform: translateY(-4px) rotate(10deg); color: red; }
          to { opacity: 1; }
        }
        @-webkit-keyframes "blink" { 0%, 100% { opacity: 1 } 50% { opacity: var(--lo) } 120% { opacity: 0 } }
        @keyframes dup { to { opacity: 0.1 } }
        @keyframes dup { to { opacity: 0.9 } }
        .ph-send { animation: pop 1s; }
        .ph-plus { animation: blink 1s; }
        .ph-back { animation: dup 1s; }
        """)
        let pop = try XCTUnwrap(c.style("send")?.animations.first?.frames)
        XCTAssertEqual(pop.map(\.at), [0, 0.5, 1])
        XCTAssertEqual(pop[0].opacity, 0)
        XCTAssertEqual(pop[0].transform?.scaleX, 0.5)
        XCTAssertEqual(pop[0].transform?.scaleY, 0.5)
        XCTAssertNil(pop[1].opacity)
        XCTAssertEqual(pop[1].transform?.dy, -4)
        XCTAssertEqual(pop[1].transform?.rotate, 10)
        XCTAssertEqual(pop[2].opacity, 1)
        XCTAssertNil(pop[2].transform)
        XCTAssertEqual(items(c, "@keyframes pop", "color").first?.reason, "动画里只认透明度与变换，这一项原生版不读取")
        XCTAssertEqual(items(c, "@keyframes pop", "opacity").first?.kind, .used)

        // 一帧写几个位置；带引号的名字；越界的位置跳过；变量展开
        let blink = try XCTUnwrap(c.style("plus")?.animations.first)
        XCTAssertEqual(blink.name, "blink")
        XCTAssertEqual(blink.frames.map(\.at), [0, 0.5, 1])
        XCTAssertEqual(blink.frames.map(\.opacity), [1, 0.2, 1])
        XCTAssertEqual(c.report.items.first(where: { $0.reason == "关键帧的位置 120% 原生版不认" })?.kind, .skipped)

        // 同名的以后写的为准
        XCTAssertEqual(c.style("back")?.animations.first?.frames.map(\.opacity), [0.9])
        XCTAssertEqual(c.report.items.filter({ $0.selector == "@keyframes dup" && $0.kind == .skipped }).count, 1)
    }

    func testAnimationShorthandVariants() throws {
        let c = CssSkin.compileUncached("""
        @keyframes pop { from { opacity: 0 } to { opacity: 1 } }
        @keyframes blink { 50% { opacity: 0 } }
        @keyframes dup { to { opacity: 1 } }
        .ph-send { animation: pop 300ms cubic-bezier(0.2, 0, 0, 1) 0.1s infinite alternate both; }
        .ph-plus { animation: blink 2s linear infinite, pop .5s ease-out 3 reverse forwards, nothere 1s; }
        .ph-back { -webkit-animation-name: dup; animation-duration: 1.5s; animation-iteration-count: 2.5; }
        .ph-tab { animation: nothere 1s; }
        .ph-tab-on { transition: color .2s; animation: none; }
        .ph-navbar { animation: pop 1s banana; }
        @media (prefers-reduced-motion: reduce) { .ph-send { animation: none; } }
        """)
        let send = try XCTUnwrap(c.style("send")?.animations)
        XCTAssertEqual(send.count, 1)
        XCTAssertEqual(send[0].name, "pop")
        XCTAssertEqual(send[0].duration, 0.3, accuracy: 0.0001)
        XCTAssertEqual(send[0].delay, 0.1, accuracy: 0.0001)
        XCTAssertEqual(send[0].timing, "cubic-bezier(0.2, 0, 0, 1)")
        XCTAssertNil(send[0].iterations)
        XCTAssertEqual(send[0].direction, "alternate")
        XCTAssertEqual(send[0].fillMode, "both")
        XCTAssertEqual(send[0].frames.count, 2)
        XCTAssertEqual(items(c, ".ph-send", "animation").first?.kind, .approx)
        XCTAssertEqual(items(c, ".ph-send", "animation").first?.reason, "这种缓动曲线按 ease 近似")
        // 减弱动态效果里的不读
        XCTAssertEqual(items(c, ".ph-send", "animation").last?.kind, .skipped)

        let plus = try XCTUnwrap(c.style("plus")?.animations)
        XCTAssertEqual(plus.map(\.name), ["blink", "pop"])
        XCTAssertEqual(plus[0].duration, 2)
        XCTAssertEqual(plus[0].timing, "linear")
        XCTAssertNil(plus[0].iterations)
        XCTAssertEqual(plus[1].duration, 0.5)
        XCTAssertEqual(plus[1].timing, "ease-out")
        XCTAssertEqual(plus[1].iterations, 3)
        XCTAssertEqual(plus[1].direction, "reverse")
        XCTAssertEqual(plus[1].fillMode, "forwards")
        XCTAssertEqual(plus[1].delay, 0)
        XCTAssertEqual(items(c, ".ph-plus", "animation").first?.kind, .approx)
        XCTAssertEqual(items(c, ".ph-plus", "animation").first?.reason, "找不到同名的 @keyframes，这段动画不读取")

        let back = try XCTUnwrap(c.style("back")?.animations.first)
        XCTAssertEqual(back.name, "dup")
        XCTAssertEqual(back.duration, 1.5)
        XCTAssertEqual(back.iterations, 2.5)
        XCTAssertEqual(back.timing, "ease")
        XCTAssertEqual(items(c, ".ph-back", "-webkit-animation-name").first?.kind, .used)

        XCTAssertEqual(c.style("tab")?.animations, [])
        XCTAssertEqual(items(c, ".ph-tab", "animation").first?.kind, .skipped)
        XCTAssertEqual(items(c, ".ph-tab-on", "transition").first?.reason, "原生版不按这一项做过渡动画")
        XCTAssertEqual(c.style("tab-on")?.animations, [])
        XCTAssertEqual(items(c, ".ph-navbar", "animation").first?.reason, "这个值无法识别")

        XCTAssertEqual(CssVal.time("250ms"), 0.25)
        XCTAssertEqual(CssVal.time(".5s"), 0.5)
        XCTAssertNil(CssVal.time("0"))
    }

    // MARK: 第三步：深色模式

    func testDarkModeOverlay() {
        let css = """
        :root { --fg: #111111; --bg: #ffffff; --pad: 4px; }
        .ph-send { color: var(--fg); background: var(--bg); padding: var(--pad); }
        .ph-plus { color: red; }
        .ph-list-item { color: var(--fg); }
        .ph-list-item { color: blue; }
        .ph-navbar { color: var(--fg) !important; }
        @media screen and (prefers-color-scheme: dark) {
          :root { --fg: #eeeeee; --accent: var(--fg); }
          .ph-plus { color: var(--accent); }
          .ph-back { color: var(--missing-dark, #00ff00); }
          .ph-navbar { color: black; }
        }
        @media (prefers-color-scheme: dark) and (max-width: 300px) { .ph-tab { color: red; } }
        @media (prefers-color-scheme: light) { .ph-tab-on { color: red; } }
        """
        let c = CssSkin.compileUncached(css)
        // 常规那一份不受深色影响
        assertColor(c.style("send")?.color, hex(0x111111))
        assertColor(colors(c.style("send")).first, hex(0xFFFFFF))
        assertColor(c.style("plus")?.color, hex(0xFF0000))
        XCTAssertEqual(c.vars["fg"], "#111111")
        XCTAssertNil(c.vars["accent"])
        // 深色变量：写了的与因此变了值的
        XCTAssertEqual(c.darkVars["fg"], "#eeeeee")
        XCTAssertEqual(c.darkVars["accent"], "#eeeeee")
        XCTAssertNil(c.darkVars["bg"])
        XCTAssertNil(c.darkVars["pad"])
        // 深色那一份只有变了的几项
        let send = c.dark[CssKey(hook: "send")]
        assertColor(send?.color, hex(0xEEEEEE))
        XCTAssertNil(send?.background)
        XCTAssertNil(send?.padding)
        assertColor(c.dark[CssKey(hook: "plus")]?.color, hex(0xEEEEEE))
        assertColor(c.dark[CssKey(hook: "back")]?.color, hex(0x00FF00))
        XCTAssertNil(c.style("back"))
        // 常规里后写的压过用变量的那条：深色下照样是它，不叠
        XCTAssertNil(c.dark[CssKey(hook: "list-item")])
        // !important 的常规规则压过深色里没加 !important 的，取深色变量
        assertColor(c.dark[CssKey(hook: "navbar")]?.color, hex(0xEEEEEE))
        // 深色加别的尺寸条件：不读
        XCTAssertNil(c.dark[CssKey(hook: "tab")])
        XCTAssertNil(c.style("tab"))
        assertColor(c.style("tab-on")?.color, hex(0xFF0000))
        XCTAssertNil(c.dark[CssKey(hook: "tab-on")])
        // 记账
        XCTAssertEqual(items(c, ".ph-plus", "color").first?.reason, "已读取")
        XCTAssertEqual(items(c, ".ph-plus", "color").last?.reason, "深色模式：已读取")
        XCTAssertEqual(items(c, ".ph-plus", "color").last?.kind, .used)
        XCTAssertTrue(items(c, ":root", "--fg").last?.reason.hasPrefix("深色模式：") == true)
        XCTAssertFalse(c.report.items.contains(where: { $0.reason.contains("暂不读取") && $0.selector == ".ph-plus" }))
        // 缓存里存的是同一份（含深色与动画）
        XCTAssertEqual(CssSkin.compile(css), c)
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
