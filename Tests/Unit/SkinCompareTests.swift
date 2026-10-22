import UIKit
import XCTest
@testable import Eira

/// 「对照」页：网页版样板页挂着契约类名、层级照网页版 CHAT_TREE、关在沙盒里；原生那一边的结构写法钩子；深色叠加；截图缓存的键
final class SkinCompareTests: XCTestCase {
    private func classes(_ html: String) -> Set<String> {
        let re = try! NSRegularExpression(pattern: #"class="([^"]*)""#)
        let ns = html as NSString
        var out = Set<String>()
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            for c in ns.substring(with: m.range(at: 1)).split(separator: " ") { out.insert(String(c)) }
        }
        return out
    }

    func testMockHasAllContractClasses() {
        let html = SkinCompareMock.html(css: "", dark: false)
        let have = classes(html)
        for c in SkinCompareMock.requiredClasses {
            XCTAssertTrue(have.contains(c), c)
        }
        // 只挂契约类名与样板自己的 rz- 类名
        XCTAssertTrue(have.allSatisfy { $0.hasPrefix("ph-") || $0.hasPrefix("rz-") }, "\(have)")
    }

    func testMockStructureFollowsChatTree() throws {
        let m = SkinCompareMock.markup()
        // 悬浮返回键在 .ph-screen 里、.ph-page 外（不在顶栏里）
        XCTAssertTrue(m.hasPrefix(#"<div class="ph-screen"><div class="ph-page"><div class="ph-navbar"><div class="ph-nav-left"></div><div class="ph-nav-title">"#))
        XCTAssertTrue(m.contains(#"<div class="ph-nav-right"><div class="ph-nav-action">"#))
        let back = try XCTUnwrap(m.range(of: #"<div class="ph-back">"#))
        let composer = try XCTUnwrap(m.range(of: #"<div class="ph-composer">"#))
        XCTAssertLessThan(composer.lowerBound, back.lowerBound)
        XCTAssertTrue(m.contains(#"</div></div><div class="ph-back">"#))
        // 同一轮两个气泡在同一列里
        XCTAssertTrue(m.contains(#"<div class="ph-col"><div class="ph-bubble ph-bubble-mine">刚刚结束。</div><div class="ph-bubble ph-bubble-mine">正在回家的路上。</div></div>"#))
        XCTAssertTrue(m.contains(#"<div class="ph-msg ph-msg-theirs"><div class="ph-face"><div class="ph-avatar"></div></div><div class="ph-col">"#))
        XCTAssertTrue(m.contains(#"<div class="ph-chat-body"><div class="ph-time-sep">"#))
        XCTAssertTrue(m.contains(#"<div class="ph-col"><div class="ph-transfer">"#))
        // 消息时刻与已读在最后一条的那一列里
        XCTAssertTrue(m.contains(#"<div class="ph-meta"><span class="ph-stamp">21:36</span><span class="ph-read">已读</span></div></div></div></div>"#))
        // 底栏：加号、输入框、表情键、发送键
        XCTAssertTrue(m.contains(#"<div class="ph-composer"><div class="ph-composer-btn ph-plus">"#))
        XCTAssertTrue(m.contains(#"<textarea class="ph-composer-input""#))
        XCTAssertTrue(m.contains(#"<div class="ph-composer-btn ph-sticker-btn">"#))
        XCTAssertTrue(m.contains(#"<div class="ph-send">"#))
    }

    func testMockIsSandboxed() {
        let html = SkinCompareMock.html(css: ".ph-send{color:red}</style><script>alert(1)</script>", dark: false)
        XCTAssertTrue(html.contains("http-equiv=\"Content-Security-Policy\" content=\"\(CssRasterPlan.csp)\""))
        XCTAssertFalse(html.contains("</style><script"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
    }

    func testMockDarkAndLight() {
        let css = "@media (prefers-color-scheme: dark) { .ph-send { color: red } }"
        let d = SkinCompareMock.html(css: css, dark: true)
        XCTAssertTrue(d.contains("<html data-theme=\"dark\">"))
        XCTAssertTrue(d.contains("content=\"dark\""))
        XCTAssertTrue(d.contains("@media (min-width: 0px) { .ph-send"))
        let l = SkinCompareMock.html(css: css, dark: false)
        XCTAssertTrue(l.contains("<html data-theme=\"light\">"))
        XCTAssertTrue(l.contains("@media (max-width: 0px) { .ph-send"))
    }

    /// 样板页自己的默认样子特异度为零：美化写的一律盖得住
    func testBaseStylesAreZeroSpecificity() {
        for line in SkinCompareMock.baseCSS.split(separator: "\n") where line.contains(".ph-") && line.contains("{") {
            let selector = line.split(separator: "{").first.map(String.init) ?? ""
            guard selector.contains(".ph-") else { continue }
            XCTAssertTrue(selector.hasPrefix(":where("), String(line))
        }
    }

    func testNativeStructuralHooks() {
        // 0 时间、1 角色、2 我（两个气泡）、3 角色（两个）、4 我（转账）、5 我（最后一条）
        let theirs = SkinCompareMock.msgHooks(1)
        XCTAssertEqual(Array(theirs.prefix(2)), ["msg", "msg-theirs"])
        XCTAssertTrue(theirs.contains("msg-theirs-even"))   // 列表里第二个（时间分隔算第一个）
        XCTAssertFalse(theirs.contains("msg-theirs-cont"))
        XCTAssertFalse(theirs.contains("msg-theirs-last"))
        let lastTheirs = SkinCompareMock.msgHooks(3)
        XCTAssertTrue(lastTheirs.contains("msg-theirs-last"))
        XCTAssertFalse(lastTheirs.contains("msg-last"))
        let cont = SkinCompareMock.msgHooks(5)
        XCTAssertTrue(cont.contains("msg-mine-cont"))
        XCTAssertTrue(cont.contains("msg-mine-last"))
        XCTAssertTrue(cont.contains("msg-last"))
        XCTAssertFalse(SkinCompareMock.msgHooks(4).contains("msg-mine-last"))

        let first = SkinCompareMock.bubbleHooks(2, 0, 2)
        XCTAssertEqual(Array(first.prefix(2)), ["bubble", "bubble-mine"])
        XCTAssertTrue(first.contains("bubble-mine-first"))
        XCTAssertFalse(first.contains("bubble-mine-tail"))
        XCTAssertFalse(first.contains("bubble-mine-cont"))
        let tail = SkinCompareMock.bubbleHooks(2, 1, 2)
        XCTAssertTrue(tail.contains("bubble-tail"))
        XCTAssertTrue(tail.contains("bubble-mine-tail"))
        XCTAssertTrue(tail.contains("bubble-mine-cont"))
        XCTAssertTrue(tail.contains("bubble-mine-even"))
        // 次序：first 在 tail 之前，last 在最后
        let only = SkinCompareMock.bubbleHooks(5, 0, 1)
        let fi = only.firstIndex(of: "bubble-mine-first") ?? -1
        let ti = only.firstIndex(of: "bubble-mine-tail") ?? -1
        XCTAssertLessThan(fi, ti)
        XCTAssertEqual(only.last, "bubble-mine-last")
    }

    func testEffectiveDarkOverlay() {
        var c = CssCompiled()
        var light = CssStyle()
        light.color = CssColor(r: 1, g: 0, b: 0, a: 1)
        light.radius = 8
        c.styles[CssKey(hook: "bubble")] = light
        var dark = CssStyle()
        dark.color = CssColor(r: 0, g: 0, b: 1, a: 1)
        c.dark[CssKey(hook: "bubble")] = dark
        c.darkVars["ph-accent"] = "#fff"
        let d = SkinCompare.effective(c, dark: true)
        XCTAssertEqual(d.style("bubble")?.color, CssColor(r: 0, g: 0, b: 1, a: 1))
        XCTAssertEqual(d.style("bubble")?.radius, 8)
        XCTAssertEqual(d.vars["ph-accent"], "#fff")
        XCTAssertEqual(SkinCompare.effective(c, dark: false), c)
        // 叠两次与叠一次相同
        XCTAssertEqual(SkinCompare.effective(d, dark: true).styles, d.styles)
    }

    @MainActor
    func testShotCacheKey() {
        let a = SkinCompareShot.key(css: ".ph-send{}", remote: [:], dark: false)
        XCTAssertEqual(a, SkinCompareShot.key(css: ".ph-send{}", remote: [:], dark: false))
        XCTAssertNotEqual(a, SkinCompareShot.key(css: ".ph-send{}", remote: [:], dark: true))
        XCTAssertNotEqual(a, SkinCompareShot.key(css: ".ph-send{ }", remote: [:], dark: false))
        XCTAssertNotEqual(a, SkinCompareShot.key(css: ".ph-send{}", remote: ["https://x.com/a.png": "img1"], dark: false))
        XCTAssertNil(SkinCompareShot.cached(css: ".ph-send{}", remote: [:], dark: false))
    }
}
