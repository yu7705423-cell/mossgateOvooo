import ImageIO
import UIKit
import XCTest
@testable import Eira

/// 美化 CSS 还原第二步的画图一边（CssRasterizer）：画哪几块、摆在哪儿、九宫格留多宽、网络图片的提取与替换、
/// 什么时候重画、存取 nativeRaster；最后一项真的请 WebKit 画一块红色方块
final class CssRasterTests: StoreTestCase {
    private func ios6() throws -> CssCompiled {
        let css = try String(contentsOf: fixture("skins/ios6.css"), encoding: .utf8)
        return CssSkin.compileUncached(css)
    }

    private func job(_ jobs: [CssRasterPlan.Job], _ id: String) -> CssRasterPlan.Job? {
        jobs.first { CssRaster.id($0.key) == id }
    }

    // MARK: - 画哪几块

    func testIos6Jobs() throws {
        let jobs = CssRasterPlan.jobs(try ios6())
        XCTAssertLessThanOrEqual(jobs.count, CssRasterPlan.maxRenders)
        let ids = Set(jobs.map { CssRaster.id($0.key) })

        // 多层渐变、边框与内阴影叠在一起的：整块画
        for id in ["navbar|normal|main|", "composer|normal|main|", "composer-input|normal|main|", "composer-btn|normal|main|",
                   "plus|normal|main|", "send|normal|main|"] {
            XCTAssertEqual(job(jobs, id)?.kind, .box, id)
        }
        // 按下、聚焦另画一张
        for id in ["composer-input|focused|main|", "composer-btn|pressed|main|", "plus|pressed|main|", "send|pressed|main|"] {
            XCTAssertEqual(job(jobs, id)?.kind, .box, id)
        }
        // svg 藏起来、::before 贴图：换图标，按元素写的大小画
        let back = try XCTUnwrap(job(jobs, "back|normal|before|"))
        XCTAssertEqual(back.kind, .icon)
        XCTAssertEqual(back.width, 85)
        XCTAssertEqual(back.height, 30)
        XCTAssertEqual(job(jobs, "nav-action|normal|before|")?.kind, .icon)
        XCTAssertEqual(job(jobs, "plus|normal|before|")?.kind, .icon)

        // 文档流里的装饰：高度由内容撑开
        let strip = try XCTUnwrap(job(jobs, "chat-body|normal|before|"))
        XCTAssertEqual(strip.kind, .decor)
        XCTAssertTrue(strip.autoHeight)
        XCTAssertTrue(try XCTUnwrap(job(jobs, "time-sep|normal|before|")).autoHeight)

        // 气泡按两边分开：高光带混合模式，连底一起画；小尾巴绝对定位
        for side in ["bubble-mine", "bubble-theirs"] {
            let hi = try XCTUnwrap(job(jobs, "bubble|normal|before|\(side)"))
            XCTAssertEqual(hi.kind, .decor)
            XCTAssertTrue(hi.withBackground)
            XCTAssertFalse(hi.below)
            let tail = try XCTUnwrap(job(jobs, "bubble|normal|after|\(side)"))
            XCTAssertFalse(tail.autoHeight)
            XCTAssertFalse(tail.withBackground)
            XCTAssertTrue(CssRasterPlan.hasImage(tail.raw))
        }
        XCTAssertEqual(job(jobs, "bubble|normal|after|bubble-mine")?.raw["width"], "38px")
        // 单层渐变加外框：格子画得了，不画
        XCTAssertFalse(ids.contains("bubble|normal|main|bubble-mine"))
        XCTAssertFalse(ids.contains("transfer|normal|main|"))
        // 只有文字的伪元素（Delivered、Send）：格子画字，不画
        XCTAssertFalse(ids.contains { $0.hasPrefix("msg-mine-last|") })
        XCTAssertFalse(ids.contains("send|normal|before|"))
        // 整块的排在最前（超过上限时先舍弃状态图）
        XCTAssertEqual(jobs.first?.kind, .box)
        XCTAssertEqual(jobs.last?.state, .pressed)
    }

    func testHiddenElementIsNotDrawn() {
        let c = CssSkin.compileUncached(".ph-send { display: none; background: linear-gradient(red, blue), linear-gradient(red, blue); }")
        XCTAssertTrue(CssRasterPlan.jobs(c).isEmpty)
    }

    func testChainMergesComposerButtonIntoPlus() throws {
        let c = CssSkin.compileUncached("""
            .ph-composer-btn { width: 30px; height: 28px; background: linear-gradient(red, blue); border: 1px solid #000; box-shadow: inset 0 1px 0 #fff; }
            .ph-plus svg { display: none; }
            """)
        let jobs = CssRasterPlan.jobs(c)
        let plus = try XCTUnwrap(jobs.first { CssRaster.id($0.key) == "plus|normal|main|" })
        XCTAssertEqual(plus.width, 30)
        XCTAssertEqual(plus.height, 28)
        XCTAssertEqual(plus.spec.chain, ["composer-btn", "plus"])
        XCTAssertTrue(CssRasterPlan.markup(plus).contains("ph-composer-btn ph-plus rz-target"))
    }

    // MARK: - 摆放

    func testTailFrameFromRightBottomAndTransform() throws {
        let raw = ["position": "absolute", "bottom": "0", "right": "0", "width": "38px", "height": "38px",
                   "transform": "translate(19px, 14px) rotate(-3deg) scale(0.3)"]
        let f = try XCTUnwrap(CssRasterPlan.predictFrame(raw, element: CGSize(width: 120, height: 44)))
        // 盒子 82,6 起 38×38；中心挪到 (120, 39)；缩成 11.4，转 3 度后外接框约 11.98
        XCTAssertEqual(f.midX, 120, accuracy: 0.001)
        XCTAssertEqual(f.midY, 39, accuracy: 0.001)
        XCTAssertEqual(f.width, 11.981, accuracy: 0.01)
        let p = CssRasterPlan.placement(frame: f, element: CGSize(width: 120, height: 44), raw: raw, part: .after)
        XCTAssertEqual(p.anchor, "bottomRight")
        XCTAssertEqual(p.dx, 5.99, accuracy: 0.01)
        XCTAssertEqual(p.dy, 0.99, accuracy: 0.01)
        XCTAssertFalse(p.stretchX)
    }

    func testTheirsTailAnchorsBottomLeft() throws {
        let raw = ["position": "absolute", "bottom": "0", "left": "0", "width": "42px", "height": "42px",
                   "transform": "translate(-21px, 17px) scale(0.5)"]
        let f = try XCTUnwrap(CssRasterPlan.predictFrame(raw, element: CGSize(width: 120, height: 44)))
        XCTAssertEqual(f.minX, -10.5, accuracy: 0.001)   // 中心 21 - 21 = 0，半宽 10.5
        let p = CssRasterPlan.placement(frame: f, element: CGSize(width: 120, height: 44), raw: raw, part: .after)
        XCTAssertEqual(p.anchor, "bottomLeft")
        XCTAssertEqual(p.dx, -10.5, accuracy: 0.001)
        XCTAssertEqual(p.dy, Double(f.maxY) - 44, accuracy: 0.001)
    }

    func testHighlightStretchesBetweenLeftAndRight() throws {
        let raw = ["position": "absolute", "top": "0", "left": "6px", "right": "6px", "height": "14px"]
        let f = try XCTUnwrap(CssRasterPlan.predictFrame(raw, element: CGSize(width: 120, height: 44)))
        XCTAssertEqual(f, CGRect(x: 6, y: 0, width: 108, height: 14))
        let p = CssRasterPlan.placement(frame: f, element: CGSize(width: 120, height: 44), raw: raw, part: .before)
        XCTAssertEqual(p.anchor, "topLeft")
        XCTAssertTrue(p.stretchX)
        XCTAssertFalse(p.stretchY)
        XCTAssertEqual(p.dx, 6)
        XCTAssertEqual(p.dy, 0)
    }

    func testCenteredAndInFlow() {
        let centered = ["position": "absolute", "left": "50%", "top": "50%", "width": "10px", "height": "10px"]
        let p = CssRasterPlan.placement(frame: CGRect(x: 55, y: 17, width: 10, height: 10),
                                        element: CGSize(width: 120, height: 44), raw: centered, part: .before)
        XCTAssertEqual(p.anchor, "center")
        XCTAssertEqual(p.dx, 0)
        XCTAssertEqual(p.dy, 0)

        let flow = ["display": "block", "width": "100%", "content": "\"iMessage\""]
        XCTAssertNil(CssRasterPlan.predictFrame(flow, element: CGSize(width: 375, height: 24)))
        let q = CssRasterPlan.placement(frame: CGRect(x: 0, y: 2, width: 375, height: 18),
                                        element: CGSize(width: 375, height: 0), raw: flow, part: .before)
        XCTAssertEqual(q.anchor, "topLeft")
        XCTAssertTrue(q.stretchX)
        XCTAssertEqual(q.dy, 2)
        // 行内的不拉伸
        let inline = ["content": "\"x\""]
        XCTAssertFalse(CssRasterPlan.placement(frame: .zero, element: CGSize(width: 375, height: 0), raw: inline, part: .after).stretchX)
    }

    func testImageForDecorUsesMeasuredCrop() {
        let raw = ["position": "absolute", "bottom": "0", "right": "0", "width": "38px", "height": "38px"]
        let spec = CssRasterPlan.Spec(hook: "bubble", variant: "bubble-mine", chain: ["bubble", "bubble-mine"])
        let j = CssRasterPlan.Job(key: CssRasterKey(hook: "bubble", part: "after", variant: "bubble-mine"), kind: .decor,
                                  spec: spec, state: .normal, part: .after, width: 120, height: 44, raw: raw)
        // 画布留白 40：元素在 (40, 40)。量出来的那一块从 (150, 70) 起 12×12，即元素坐标 (110, 30)–(122, 42)
        let img = CssRasterPlan.image(j, imageId: "img1", crop: CGRect(x: 150, y: 70, width: 12, height: 12), pad: 40)
        XCTAssertEqual(img.anchor, "bottomRight")
        XCTAssertEqual(img.dx, 2)
        XCTAssertEqual(img.dy, -2)
        XCTAssertEqual(img.width, 12)
        XCTAssertEqual(img.refWidth, 120)
        XCTAssertEqual(img.refHeight, 44)
    }

    // MARK: - 九宫格

    func testCaps() {
        let raw = ["border-radius": "6px", "border": "2px solid #000", "box-shadow": "inset 0 2px 5px rgba(0,0,0,0.3)"]
        // 边框 2 + 内阴影 5 + 2 = 9，大于圆角 6；加 1
        XCTAssertEqual(CssRasterPlan.caps(raw, size: CGSize(width: 100, height: 40)), CssEdges(top: 10, right: 10, bottom: 10, left: 10))
        // 50% 的圆角按短边的一半，不超过边长的一半
        let round = ["border-radius": "50%", "border": "1px solid #47515a"]
        XCTAssertEqual(CssRasterPlan.caps(round, size: CGSize(width: 30, height: 30)), CssEdges(top: 15, right: 15, bottom: 15, left: 15))

        // 溢出加在 cap 上
        let c = CssRasterPlan.imageCaps(CssEdges(top: 10, right: 10, bottom: 10, left: 10),
                                        out: CssEdges(top: 1, right: 2, bottom: 3, left: 0), size: CGSize(width: 102, height: 44))
        XCTAssertEqual(c, CssEdges(top: 11, right: 12, bottom: 13, left: 10))
        // 放不下时中间留 1 点
        let tight = CssRasterPlan.imageCaps(CssEdges(top: 15, right: 15, bottom: 15, left: 15), out: CssEdges(), size: CGSize(width: 30, height: 30))
        XCTAssertEqual(tight.left + tight.right, 29)
        XCTAssertEqual(tight.top, 14.5)
    }

    func testBoxImageIncludesOutline() {
        let raw = ["outline": "1px solid #818d9a", "border-radius": "17px", "background-image": "url(\"data:image/png;base64,AA\")"]
        let spec = CssRasterPlan.Spec(hook: "bubble", variant: "", chain: ["bubble"])
        let j = CssRasterPlan.Job(key: CssRasterKey(hook: "bubble"), kind: .box, spec: spec, state: .normal, part: .main,
                                  width: 120, height: 44, raw: raw)
        XCTAssertEqual(CssRasterPlan.canvas(j).pad, 40)
        let img = CssRasterPlan.image(j, imageId: "x", crop: CGRect(x: 39, y: 39, width: 122, height: 46), pad: 40)
        XCTAssertEqual(img.dx, -1)
        XCTAssertEqual(img.dy, -1)
        // 圆角 17 + 1，加上外框溢出的 1
        XCTAssertEqual(img.capLeft, 19)
        XCTAssertEqual(img.capRight, 19)
        XCTAssertEqual(img.capTop, 19)
        XCTAssertEqual(img.capBottom, 19)
        XCTAssertEqual(img.refWidth, 120)
        XCTAssertEqual(img.refHeight, 44)
    }

    // MARK: - 网络图片

    func testRemoteUrlsAndSubstitution() {
        let css = """
            .a{background:url("https://x.com/a.png")} .b{background:url( https://x.com/a.png )}
            .c{background:url('http://y.com/b.png')} .d{background:url("data:image/png;base64,AAAA")}
            .e{--tail:url(https://z.com/t.png)} .f{background:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'%3E")}
            """
        XCTAssertEqual(CssRasterPlan.remoteURLs(css), ["https://x.com/a.png", "https://z.com/t.png"])
        XCTAssertEqual(CssRasterPlan.insecureURLs(css), ["http://y.com/b.png"])
        let out = CssRasterPlan.substitute(css, ["https://x.com/a.png": "data:image/png;base64,QQ=="])
        XCTAssertEqual(out.components(separatedBy: "url(\"data:image/png;base64,QQ==\")").count - 1, 2)
        XCTAssertFalse(out.contains("https://x.com/a.png"))
        XCTAssertTrue(out.contains("https://z.com/t.png"))
        XCTAssertTrue(out.contains("http://y.com/b.png"))
        XCTAssertTrue(out.contains("base64,AAAA"))
        XCTAssertEqual(CssRasterPlan.substitute(css, [:]), css)
    }

    func testCheckImage() throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        XCTAssertNoThrow(try CssRasterPlan.checkImage(png, mime: "image/png"))
        XCTAssertNoThrow(try CssRasterPlan.checkImage(png, mime: nil))
        XCTAssertThrowsError(try CssRasterPlan.checkImage(Data("<html></html>".utf8), mime: "text/html"))
        XCTAssertThrowsError(try CssRasterPlan.checkImage(Data("not an image".utf8), mime: "image/png"))
        XCTAssertThrowsError(try CssRasterPlan.checkImage(Data(count: CssRasterPlan.maxRemoteBytes + 1), mime: "image/png"))
    }

    func testFetchOnlyHttpsAndNoRetry() async throws {
        CssRasterNet.session = CssRasterNet.makeSession(protocols: [MockNet.self])
        defer { CssRasterNet.session = CssRasterNet.makeSession() }
        MockNet.reset { _, _ in MockNet.Reply(status: 404, body: "") }
        do { _ = try await CssRasterNet.fetch("http://x.com/a.png"); XCTFail("http 不该下载") } catch {}
        XCTAssertEqual(MockNet.count, 0)
        do { _ = try await CssRasterNet.fetch("https://x.com/a.png"); XCTFail("404 不该成功") } catch {
            XCTAssertTrue(error.localizedDescription.contains("404"))
        }
        XCTAssertEqual(MockNet.count, 1)
        // 200 但不是图片
        MockNet.reset { _, _ in MockNet.Reply(status: 200, body: "hello") }
        do { _ = try await CssRasterNet.fetch("https://x.com/a.png"); XCTFail("不是图片不该成功") } catch {}
        XCTAssertEqual(MockNet.count, 1)
    }

    @MainActor
    func testRenderWithoutFetchNeverTouchesNetwork() async throws {
        CssRasterNet.session = CssRasterNet.makeSession(protocols: [MockNet.self])
        defer { CssRasterNet.session = CssRasterNet.makeSession() }
        MockNet.reset { _, _ in MockNet.Reply(status: 500, body: "") }
        // 没有要画的块（只写了文字颜色），不起 WebKit
        let css = ".ph-bubble { color: red; --tail: url(https://x.com/t.png); }"
        let set = await CssRasterizer.render(css: css, compiled: CssSkin.compileUncached(css), existing: nil, fetchRemote: false)
        XCTAssertEqual(MockNet.count, 0)
        XCTAssertTrue(set.images.isEmpty)
        XCTAssertNotNil(set.failures["remote|https://x.com/t.png"])
        XCTAssertEqual(set.cssHash, CssRasterPlan.hash(css))
        // 下载失败只试一次，记下原因
        let fetched = await CssRasterizer.render(css: css, compiled: CssSkin.compileUncached(css), existing: nil, fetchRemote: true)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(fetched.remote.isEmpty)
        XCTAssertTrue(fetched.failures["remote|https://x.com/t.png"]?.contains("下载失败") == true)
    }

    // MARK: - 样板页

    func testDocumentIsSandboxed() throws {
        let jobs = CssRasterPlan.jobs(try ios6())
        let hi = try XCTUnwrap(job(jobs, "bubble|normal|before|bubble-mine"))
        let doc = CssRasterPlan.document(hi, css: ".ph-bubble{color:red}</style><script>alert(1)</script>", background: "#000000")
        XCTAssertTrue(doc.contains("http-equiv=\"Content-Security-Policy\" content=\"\(CssRasterPlan.csp)\""))
        XCTAssertTrue(CssRasterPlan.csp.contains("default-src 'none'"))
        XCTAssertFalse(CssRasterPlan.csp.contains("script"))
        XCTAssertFalse(doc.contains("</style><script"))
        XCTAssertTrue(doc.contains("ph-bubble ph-bubble-mine rz-target"))
        XCTAssertTrue(doc.contains("ph-msg ph-msg-mine rz-anc"))
        // 带混合模式的装饰连底一起画；量范围的那一页去掉底并且不混合
        XCTAssertFalse(doc.contains("background: none !important; box-shadow: none !important; border-color: transparent"))
        let measure = CssRasterPlan.document(hi, css: "", background: "#ffffff", measure: true)
        XCTAssertTrue(measure.contains("mix-blend-mode: normal !important; }"))
        XCTAssertTrue(measure.contains("border-color: transparent"))
    }

    func testStateRewrite() {
        XCTAssertEqual(CssRasterPlan.stateCSS(".ph-send:active{x}", .pressed), ".ph-send.rz-active{x}")
        XCTAssertEqual(CssRasterPlan.stateCSS(".ph-a:focus-visible{y} .ph-b:focus{z}", .focused), ".ph-a.rz-focus{y} .ph-b.rz-focus{z}")
        XCTAssertEqual(CssRasterPlan.stateCSS(".ph-send:active{x}", .normal), ".ph-send:active{x}")
    }

    func testLastMessageSampleHasNoFollowingSibling() {
        let spec = CssRasterPlan.Spec(hook: "msg-mine-last", variant: "", chain: ["msg", "msg-mine", "msg-mine-last"])
        let last = CssRasterPlan.Job(key: CssRasterKey(hook: "msg-mine-last"), kind: .decor, spec: spec, state: .normal,
                                     part: .after, width: 375, height: 60, raw: [:])
        XCTAssertFalse(CssRasterPlan.markup(last).contains("rz-sib"))
        var plain = last
        plain.spec = CssRasterPlan.Spec(hook: "msg", variant: "msg-mine", chain: ["msg", "msg-mine"])
        XCTAssertTrue(CssRasterPlan.markup(plain).contains("ph-msg ph-msg-mine rz-sib"))
    }

    // MARK: - 第三步：深色

    func testDarkKeyHelpers() {
        XCTAssertEqual(CssRaster.darkState("normal"), "normal@dark")
        XCTAssertEqual(CssRaster.darkState("normal@dark"), "normal@dark")
        XCTAssertTrue(CssRaster.isDark("pressed@dark"))
        XCTAssertFalse(CssRaster.isDark("pressed"))
        XCTAssertEqual(CssRaster.baseState("pressed@dark"), "pressed")
        let k = CssRasterKey(hook: "bubble", part: "after", variant: "bubble-mine")
        XCTAssertEqual(CssRaster.dark(k), CssRasterKey(hook: "bubble", state: "normal@dark", part: "after", variant: "bubble-mine"))
        XCTAssertEqual(CssRaster.id(CssRaster.dark(k)), "bubble|normal@dark|after|bubble-mine")
        let a = CssRasterKey(hook: "send"), b = CssRasterKey(hook: "composer-btn")
        XCTAssertEqual(CssRaster.withDark([a, b], dark: false), [a, b])
        XCTAssertEqual(CssRaster.withDark([a, b], dark: true), [CssRaster.dark(a), a, CssRaster.dark(b), b])
        XCTAssertEqual(CssRaster.structuralKeys("bubble-tail", side: "bubble-mine"),
                       [CssRasterKey(hook: "bubble-tail", variant: "bubble-mine"), CssRasterKey(hook: "bubble-tail")])
        XCTAssertEqual(CssRaster.structuralKeys("bubble-mine-tail", side: nil), [CssRasterKey(hook: "bubble-mine-tail")])
    }

    func testDarkTextAndTouches() {
        let css = """
            .ph-send { color: red; }
            @media screen and (prefers-color-scheme: DARK) { .ph-send { background: url(a.png); } @supports (x: y) { .ph-plus { color: blue; } } }
            @media (prefers-color-scheme: light) { .ph-composer { color: red; } }
            :root[data-theme="dark"] .ph-bubble-mine { color: white; }
            """
        XCTAssertTrue(CssRasterPlan.hasDark(css))
        XCTAssertTrue(CssRasterPlan.hasDark(#"html[data-theme=dark] .ph-send{}"#))
        XCTAssertFalse(CssRasterPlan.hasDark(".ph-send{} @media (prefers-color-scheme: light){.ph-send{}}"))
        let t = CssRasterPlan.darkText(css)
        XCTAssertTrue(t.contains(".ph-send { background"))
        XCTAssertTrue(t.contains(".ph-plus"))
        XCTAssertFalse(t.contains(".ph-composer"))
        XCTAssertTrue(t.contains(".ph-bubble-mine"))
        XCTAssertTrue(CssRasterPlan.darkTouches(["composer-btn", "plus"], text: t, hooks: []))
        XCTAssertTrue(CssRasterPlan.darkTouches(["bubble", "bubble-mine"], text: t, hooks: []))
        // .ph-bubble-mine 碰不到只挂着 bubble 的那一块
        XCTAssertFalse(CssRasterPlan.darkTouches(["bubble"], text: t, hooks: []))
        XCTAssertFalse(CssRasterPlan.darkTouches(["composer"], text: t, hooks: []))
        XCTAssertTrue(CssRasterPlan.darkTouches(["composer"], text: "", hooks: ["composer"]))
    }

    func testSchemeRewrite() {
        let css = "@media (prefers-color-scheme: dark) { a {} } @media (prefers-color-scheme:light){ b {} }"
        let dark = CssRasterPlan.schemeCSS(css, dark: true)
        XCTAssertEqual(dark, "@media (min-width: 0px) { a {} } @media (max-width: 0px){ b {} }")
        let light = CssRasterPlan.schemeCSS(css, dark: false)
        XCTAssertEqual(light, "@media (max-width: 0px) { a {} } @media (min-width: 0px){ b {} }")
        XCTAssertEqual(CssRasterPlan.schemeCSS(".ph-send{}", dark: true), ".ph-send{}")
    }

    private func style(_ raw: [String: String]) -> CssStyle {
        var s = CssStyle()
        s.raw = raw
        return s
    }

    private let twoGradients = "linear-gradient(red, blue), linear-gradient(blue, red)"

    func testDarkJobsOnlyForTouchedBlocks() {
        let css = """
            .ph-send { background: \(twoGradients); }
            .ph-composer { background: \(twoGradients); }
            @media (prefers-color-scheme: dark) { .ph-send { background: \(twoGradients), linear-gradient(#000, #000); } }
            """
        let jobs = CssRasterPlan.jobs(CssSkin.compileUncached(css), css: css)
        let ids = jobs.map { CssRaster.id($0.key) }
        XCTAssertTrue(ids.contains("send|normal|main|"))
        XCTAssertTrue(ids.contains("composer|normal|main|"))
        let dark = try? XCTUnwrap(job(jobs, "send|normal@dark|main|"))
        XCTAssertEqual(dark?.dark, true)
        XCTAssertEqual(dark?.state, .normal)
        XCTAssertFalse(ids.contains("composer|normal@dark|main|"))
        // 不传原文、解析也没读出深色：不画深色
        let plain = CssRasterPlan.jobs(CssSkin.compileUncached(".ph-send { background: \(twoGradients); }"))
        XCTAssertFalse(plain.contains { $0.dark })
    }

    func testDarkOnlyBoxAndDarkVars() {
        var c = CssCompiled()
        c.styles[CssKey(hook: "composer")] = style(["background": "red"])
        c.styles[CssKey(hook: "send")] = style(["background": twoGradients])
        c.dark[CssKey(hook: "composer")] = style(["background": twoGradients])
        var ids = Set(CssRasterPlan.jobs(c).map { CssRaster.id($0.key) })
        // 深色下才要整块画的：只有深色那张
        XCTAssertTrue(ids.contains("composer|normal@dark|main|"))
        XCTAssertFalse(ids.contains("composer|normal|main|"))
        XCTAssertTrue(ids.contains("send|normal|main|"))
        XCTAssertFalse(ids.contains("send|normal@dark|main|"))
        // 深色改了变量：每一块都另画深色
        c.darkVars["ph-accent"] = "#fff"
        ids = Set(CssRasterPlan.jobs(c).map { CssRaster.id($0.key) })
        XCTAssertTrue(ids.contains("send|normal@dark|main|"))
    }

    func testDarkJobOrderAfterBase() {
        var c = CssCompiled()
        c.styles[CssKey(hook: "send")] = style(["background": twoGradients])
        c.styles[CssKey(hook: "send", state: .pressed)] = style(["background": twoGradients + ", url(x.png)"])
        c.darkVars["x"] = "1"
        let jobs = CssRasterPlan.jobs(c)
        XCTAssertEqual(jobs.map { CssRaster.id($0.key) },
                       ["send|normal|main|", "send|normal@dark|main|", "send|pressed|main|", "send|pressed@dark|main|"])
    }

    func testDarkDocument() throws {
        var c = CssCompiled()
        c.styles[CssKey(hook: "send")] = style(["background": twoGradients])
        c.darkVars["x"] = "1"
        let jobs = CssRasterPlan.jobs(c)
        let dark = try XCTUnwrap(jobs.first { $0.dark })
        let light = try XCTUnwrap(jobs.first { !$0.dark })
        let css = "@media (prefers-color-scheme: dark) { .ph-send { color: red } }"
        let d = CssRasterPlan.document(dark, css: css, background: "#000000")
        XCTAssertTrue(d.contains("<html data-theme=\"dark\">"))
        XCTAssertTrue(d.contains("name=\"color-scheme\" content=\"dark\""))
        XCTAssertTrue(d.contains("@media (min-width: 0px) { .ph-send"))
        let l = CssRasterPlan.document(light, css: css, background: "#000000")
        XCTAssertTrue(l.contains("<html data-theme=\"light\">"))
        XCTAssertTrue(l.contains("@media (max-width: 0px) { .ph-send"))
    }

    // MARK: - 第三步：结构写法

    private func sampleJob(_ spec: CssRasterPlan.Spec) -> CssRasterPlan.Job {
        CssRasterPlan.Job(key: CssRasterKey(hook: spec.hook, variant: spec.variant), kind: .box, spec: spec, state: .normal,
                          part: .main, width: 120, height: 44, raw: [:])
    }

    func testStructuralSpecs() {
        var c = CssCompiled()
        c.styles[CssKey(hook: "bubble-mine")] = style(["background": twoGradients])
        c.styles[CssKey(hook: "bubble-tail")] = style(["border-radius": "4px"])
        c.styles[CssKey(hook: "msg-mine-cont")] = style(["margin-top": "2px"])
        c.styles[CssKey(hook: "msg-odd", part: .after)] = style(["content": "\"\"", "background": "url(x.png)"])
        c.styles[CssKey(hook: "nonsense-tail")] = style(["color": "red"])
        c.styles[CssKey(hook: "msg")] = style(["color": "red"])
        let specs = CssRasterPlan.specs(c)
        XCTAssertTrue(specs.contains(CssRasterPlan.Spec(hook: "bubble-tail", variant: "bubble-mine",
                                                        chain: ["bubble", "bubble-mine", "bubble-tail"])))
        XCTAssertTrue(specs.contains(CssRasterPlan.Spec(hook: "bubble-tail", variant: "bubble-theirs",
                                                        chain: ["bubble", "bubble-theirs", "bubble-tail"])))
        XCTAssertTrue(specs.contains(CssRasterPlan.Spec(hook: "msg-mine-cont", variant: "", chain: ["msg", "msg-mine", "msg-mine-cont"])))
        XCTAssertTrue(specs.contains { $0.hook == "msg-odd" && $0.chain == ["msg", "msg-odd"] })
        XCTAssertFalse(specs.contains { $0.hook == "nonsense-tail" })
        // 原钩子记下同一家写了哪些结构写法
        let base = specs.first { $0.hook == "bubble" && $0.variant == "bubble-mine" }
        XCTAssertEqual(base?.avoid, ["-tail"])
        XCTAssertEqual(Set(specs.first { $0.hook == "msg" }?.avoid ?? []), ["-cont", "-odd"])
        // 早就认的 -last 一串不算派生
        XCTAssertFalse(CssRasterPlan.isDerived("bubble-mine-last"))
        XCTAssertTrue(CssRasterPlan.isDerived("bubble-mine-tail"))
        XCTAssertFalse(CssRasterPlan.isDerived("bubble-mine"))
    }

    func testStructuralJobsOnlyOwnPartsAndAfterBase() {
        var c = CssCompiled()
        c.styles[CssKey(hook: "bubble")] = style(["background": twoGradients])
        c.styles[CssKey(hook: "bubble", part: .after)] = style(["content": "\"\"", "position": "absolute", "background": "url(t.png)"])
        c.styles[CssKey(hook: "bubble-tail")] = style(["border-radius": "4px"])
        let jobs = CssRasterPlan.jobs(c)
        let ids = jobs.map { CssRaster.id($0.key) }
        XCTAssertTrue(ids.contains("bubble-tail|normal|main|"))
        // 派生钩子只改了整块：小尾巴照原钩子那张
        XCTAssertFalse(ids.contains("bubble-tail|normal|after|"))
        XCTAssertTrue(ids.contains("bubble|normal|after|"))
        let firstDerived = ids.firstIndex { $0.hasPrefix("bubble-tail|") } ?? 0
        let lastBase = ids.lastIndex { $0.hasPrefix("bubble|") } ?? Int.max
        XCTAssertLessThan(lastBase, firstDerived)
    }

    func testStructuralMarkupSiblings() {
        typealias S = CssRasterPlan.Spec
        let tail = CssRasterPlan.markup(sampleJob(S(hook: "bubble-tail", variant: "bubble-mine", chain: ["bubble", "bubble-mine", "bubble-tail"])))
        XCTAssertTrue(tail.contains(#"<div class="ph-col rz-anc"><div class="ph-bubble ph-bubble-mine rz-sib"></div><div class="ph-bubble ph-bubble-mine rz-target"></div></div>"#), tail)
        XCTAssertFalse(tail.contains("ph-bubble-tail"))
        // 这一轮之后还有一条：不是整段最后一条
        XCTAssertTrue(tail.contains(#"<div class="ph-msg ph-msg-mine rz-sib"></div>"#))

        let first = CssRasterPlan.markup(sampleJob(S(hook: "bubble-mine-first", variant: "", chain: ["bubble", "bubble-mine", "bubble-mine-first"])))
        XCTAssertTrue(first.contains(#"<div class="ph-col rz-anc"><div class="ph-bubble ph-bubble-mine rz-target"></div><div class="ph-bubble ph-bubble-mine rz-sib"></div></div>"#), first)

        let cont = CssRasterPlan.markup(sampleJob(S(hook: "msg-mine-cont", variant: "", chain: ["msg", "msg-mine", "msg-mine-cont"])))
        XCTAssertTrue(cont.contains(#"<div class="ph-chat-body rz-anc"><div class="ph-msg ph-msg-mine rz-sib"></div><div class="ph-msg ph-msg-mine rz-target"></div><div class="ph-msg ph-msg-mine rz-sib"></div></div>"#), cont)

        // 奇数：第三个，前面两条是另一边的（不命中连发）；偶数：第二个
        let odd = CssRasterPlan.markup(sampleJob(S(hook: "msg-odd", variant: "msg-theirs", chain: ["msg", "msg-theirs", "msg-odd"])))
        XCTAssertTrue(odd.contains(#"<div class="ph-chat-body rz-anc"><div class="ph-msg ph-msg-mine rz-sib"></div><div class="ph-msg ph-msg-mine rz-sib"></div><div class="ph-msg ph-msg-theirs rz-target"></div>"#), odd)
        let even = CssRasterPlan.markup(sampleJob(S(hook: "msg-even", variant: "msg-mine", chain: ["msg", "msg-mine", "msg-even"])))
        XCTAssertTrue(even.contains(#"<div class="ph-chat-body rz-anc"><div class="ph-msg ph-msg-theirs rz-sib"></div><div class="ph-msg ph-msg-mine rz-target"></div>"#), even)

        // 原钩子避开写了的结构写法：写了 -first 就不当第一个；只写了奇数就摆在偶数位
        let baseBubble = CssRasterPlan.markup(sampleJob(S(hook: "bubble", variant: "bubble-mine", chain: ["bubble", "bubble-mine"], avoid: ["-first", "-tail"])))
        XCTAssertTrue(baseBubble.contains(#"<div class="ph-col rz-anc"><div class="ph-bubble ph-bubble-mine rz-sib"></div><div class="ph-bubble ph-bubble-mine rz-target"></div><div class="ph-bubble ph-bubble-mine rz-sib"></div></div>"#), baseBubble)
        let baseMsg = CssRasterPlan.markup(sampleJob(S(hook: "msg", variant: "msg-mine", chain: ["msg", "msg-mine"], avoid: ["-odd"])))
        XCTAssertTrue(baseMsg.contains(#"<div class="ph-chat-body rz-anc"><div class="ph-msg ph-msg-theirs rz-sib"></div><div class="ph-msg ph-msg-mine rz-target"></div>"#), baseMsg)
        let plainMsg = CssRasterPlan.markup(sampleJob(S(hook: "msg", variant: "msg-mine", chain: ["msg", "msg-mine"])))
        XCTAssertTrue(plainMsg.contains(#"<div class="ph-chat-body rz-anc"><div class="ph-msg ph-msg-mine rz-target"></div><div class="ph-msg ph-msg-mine rz-sib"></div></div>"#), plainMsg)
    }

    // MARK: - 第三步：引擎版本与上限

    func testEngineBumpRedrawsOldSets() {
        XCTAssertGreaterThanOrEqual(CssRasterPlan.engine, 2)
        XCTAssertGreaterThanOrEqual(CssRasterPlan.maxRenders, 60)
        let css = ".ph-send{color:red}"
        let old = CssRasterSet(cssHash: CssRasterPlan.hash(css), engine: 1)
        XCTAssertTrue(CssRasterPlan.isStale(old, css: css, fetchRemote: false))
        let now = CssRasterSet(cssHash: CssRasterPlan.hash(css), engine: CssRasterPlan.engine)
        XCTAssertFalse(CssRasterPlan.isStale(now, css: css, fetchRemote: false))
    }

    // MARK: - 像素

    func testUnmatteAndBounds() {
        // 不透明红、全透明、半透明白
        let black: [UInt8] = [255, 0, 0, 255, 0, 0, 0, 255, 128, 128, 128, 255]
        let white: [UInt8] = [255, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255]
        XCTAssertEqual(CssRasterPlan.unmatte(black: black, white: white), [255, 0, 0, 255, 0, 0, 0, 0, 128, 128, 128, 128])

        var px = [UInt8](repeating: 0, count: 4 * 3 * 4)
        px[(1 * 4 + 1) * 4 + 3] = 255
        px[(2 * 4 + 2) * 4 + 3] = 200
        XCTAssertEqual(CssRasterPlan.alphaBounds(px, width: 4, height: 3), CssPixelRect(x: 1, y: 1, w: 2, h: 2))
        XCTAssertNil(CssRasterPlan.alphaBounds([UInt8](repeating: 0, count: 16), width: 2, height: 2))
        XCTAssertEqual(CssPixelRect(x: -2, y: 1, w: 10, h: 10).clamped(width: 5, height: 5), CssPixelRect(x: 0, y: 1, w: 5, h: 4))
        XCTAssertEqual(CssPixelRect(x: 0, y: 0, w: 2, h: 2).union(CssPixelRect(x: 3, y: 1, w: 1, h: 4)), CssPixelRect(x: 0, y: 0, w: 4, h: 5))
    }

    // MARK: - 重画与存取

    func testStaleness() {
        let css = ".ph-send{background:url(https://x.com/a.png)}"
        XCTAssertTrue(CssRasterPlan.isStale(nil, css: css, fetchRemote: false))
        var set = CssRasterSet(cssHash: CssRasterPlan.hash(css), engine: CssRasterPlan.engine)
        XCTAssertFalse(CssRasterPlan.isStale(set, css: css, fetchRemote: false))
        XCTAssertTrue(CssRasterPlan.isStale(set, css: css + " ", fetchRemote: false))
        // 要下载时，还有没下载的地址也算过期
        XCTAssertTrue(CssRasterPlan.isStale(set, css: css, fetchRemote: true))
        set.remote["https://x.com/a.png"] = "img1"
        XCTAssertFalse(CssRasterPlan.isStale(set, css: css, fetchRemote: true))
        set.engine = CssRasterPlan.engine - 1
        XCTAssertTrue(CssRasterPlan.isStale(set, css: css, fetchRemote: false))
        XCTAssertEqual(CssRasterPlan.hash("a"), CssRasterPlan.hash("a"))
        XCTAssertNotEqual(CssRasterPlan.hash("a"), CssRasterPlan.hash("b"))
    }

    @MainActor
    func testSaveKeepsOtherFieldsAndDecodes() throws {
        let row = try Skins.create(name: "金属")
        try Skins.update(row.id) { $0["css"] = .string(".ph-send{color:red}"); $0["frame"] = .string("keep") }
        let before = try XCTUnwrap(Skins.get(row.id))
        var set = CssRasterSet(cssHash: CssRasterPlan.hash(".ph-send{color:red}"), engine: CssRasterPlan.engine)
        var img = CssRasterImage(kind: .decor, imageId: "img_a", width: 12, height: 12)
        img.anchor = "bottomRight"
        img.dx = 5.99
        img.refWidth = 120
        set.images["bubble|normal|after|bubble-mine"] = img
        set.remote["https://x.com/a.png"] = "img_b"
        set.failures["send|normal|main|"] = "画图超时，这一块按原生样式显示"
        CssRasterizer.save(set, skinId: row.id)

        let after = try XCTUnwrap(Skins.get(row.id))
        XCTAssertEqual(after.string("frame"), "keep")
        XCTAssertEqual(after.string("name"), "金属")
        XCTAssertEqual(after.number("updatedAt"), before.number("updatedAt"))
        XCTAssertNotNil(after["nativeRaster"]?.object)
        XCTAssertEqual(Skins.raster(after), set)

        // CSS 改过：当前的那一份不认，旧的仍读得到（用它记下的网络图片）
        try Skins.update(row.id) { $0["css"] = .string(".ph-send{color:blue}") }
        let changed = try XCTUnwrap(Skins.get(row.id))
        XCTAssertNil(Skins.raster(changed))
        XCTAssertEqual(Skins.raster(changed, current: false)?.remote["https://x.com/a.png"], "img_b")
        XCTAssertNil(Skins.raster(nil))
    }

    @MainActor
    func testEnsureWithoutCssWritesNothing() async throws {
        let row = try Skins.create(name: "空")
        await CssRasterizer.ensure(skinId: row.id)
        XCTAssertNil(Skins.get(row.id)?["nativeRaster"])
        await CssRasterizer.ensure(skinId: "")
    }

    // MARK: - WebKit

    /// 真的画一块：20×20 的红色发送键。模拟器上 WebKit 截不了图时跳过（记下原因），不算失败
    @MainActor
    func testWebKitDrawsRedBox() async throws {
        let css = ".ph-send { width: 20px; height: 20px; background: #ff0000; border: 1px solid #ff0000; box-shadow: inset 0 0 0 1px #ff0000; }"
        let set = await CssRasterizer.render(css: css, compiled: CssSkin.compileUncached(css), existing: nil, fetchRemote: false)
        let id = CssRaster.id(CssRasterKey(hook: "send"))
        guard let img = set.images[id] else {
            let why = set.failures[id] ?? "没有记录"
            if why.contains("截图失败") || why.contains("超时") { throw XCTSkip("WebKit 未能截图：\(why)") }
            XCTFail(why)
            return
        }
        XCTAssertEqual(img.kind, .box)
        XCTAssertEqual(img.width, 20, accuracy: 0.5)
        XCTAssertEqual(img.height, 20, accuracy: 0.5)
        XCTAssertEqual(img.dx, 0, accuracy: 0.5)
        XCTAssertEqual(img.refWidth, 20)

        let url = try XCTUnwrap(MediaStore.url(.images, id: img.imageId))
        XCTAssertEqual(url.pathExtension, "png")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let px = try XCTUnwrap(CssRasterPlan.rgba(cg, width: cg.width, height: cg.height))
        let mid = ((cg.height / 2) * cg.width + cg.width / 2) * 4
        XCTAssertGreaterThan(px[mid], 200)
        XCTAssertLessThan(px[mid + 1], 40)
        XCTAssertLessThan(px[mid + 2], 40)
        XCTAssertGreaterThan(px[mid + 3], 200)
    }
}
