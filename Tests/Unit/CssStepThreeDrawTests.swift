import SwiftUI
import XCTest
@testable import Eira

/// 美化第三步画的一边的纯计算：结构写法的层叠次序、找图次序、深色叠加、动画时序、顶栏何时自己画。
/// CssCompiled 一律手写，不经过读 CSS 那一步
final class CssStepThreeDrawTests: XCTestCase {
    private let red = CssColor(r: 1, g: 0, b: 0, a: 1)
    private let blue = CssColor(r: 0, g: 0, b: 1, a: 1)
    private let green = CssColor(r: 0, g: 1, b: 0, a: 1)

    private func styled(_ f: (inout CssStyle) -> Void) -> CssStyle {
        var s = CssStyle()
        f(&s)
        return s
    }

    // MARK: - 结构写法：钩子次序

    func testNoContextKeepsBaseHooks() {
        XCTAssertEqual(CssStructural.hooks(["bubble", "bubble-mine"], CssStructCtx()), ["bubble", "bubble-mine"])
    }

    func testDerivedHooksFollowDocumentedOrder() {
        let c = CssStructCtx(first: true, tail: true, index: 0, cont: true, last: true, firstOfSide: true, lastOfSide: true)
        XCTAssertEqual(CssStructural.hooks(["bubble", "bubble-mine"], c), [
            "bubble", "bubble-mine",
            "bubble-first", "bubble-mine-first",
            "bubble-tail", "bubble-mine-tail",
            "bubble-odd", "bubble-mine-odd",
            "bubble-cont", "bubble-mine-cont",
            "bubble-last", "bubble-mine-last",
        ])
    }

    func testOddEvenFromZeroBasedIndex() {
        // 第 0 个是 nth-child(1)：奇数
        XCTAssertEqual(CssStructural.hooks(["msg"], CssStructCtx(index: 0)), ["msg", "msg-odd"])
        XCTAssertEqual(CssStructural.hooks(["msg"], CssStructCtx(index: 1)), ["msg", "msg-even"])
        XCTAssertEqual(CssStructural.hooks(["msg"], CssStructCtx(index: 6)), ["msg", "msg-odd"])
    }

    func testSidedHooksUseSideEdges() {
        // 我发的最后一条，但不是整个列表的最后一条：msg-mine-last 挂上，msg-last 不挂
        let c = CssStructCtx(last: false, lastOfSide: true)
        XCTAssertEqual(CssStructural.hooks(["msg", "msg-mine"], c), ["msg", "msg-mine", "msg-mine-last"])
        // 整个列表的第一条，也是角色这一侧的第一条
        let d = CssStructCtx(first: true, firstOfSide: true)
        XCTAssertEqual(CssStructural.hooks(["msg", "msg-theirs"], d), ["msg", "msg-theirs", "msg-first", "msg-theirs-first"])
    }

    func testTrimmedDropsUnusedSuffixes() {
        let c = CssStructCtx(first: true, tail: true, index: 3, cont: true, last: true, firstOfSide: true, lastOfSide: true)
        XCTAssertEqual(CssStructural.trimmed(c, used: []), CssStructCtx())
        let t = CssStructural.trimmed(c, used: ["-even", "-cont"])
        XCTAssertEqual(t, CssStructCtx(index: 3, cont: true))
    }

    func testBubbleContextInsideColumn() {
        let row = CssStructCtx(cont: true, lastOfSide: true)
        let all: Set<String> = Set(CssStructural.suffixes)
        let first = CssStructural.bubble(row, at: 0, of: 3, used: all)
        XCTAssertTrue(first.first && first.firstOfSide)
        XCTAssertFalse(first.tail || first.last || first.lastOfSide)
        XCTAssertEqual(first.index, 0)
        XCTAssertTrue(first.cont)
        let last = CssStructural.bubble(row, at: 2, of: 3, used: all)
        XCTAssertTrue(last.tail && last.last && last.lastOfSide)
        XCTAssertFalse(last.first)
        // 只有一个气泡：既是第一个也是最后一个
        let only = CssStructural.bubble(CssStructCtx(), at: 0, of: 1, used: all)
        XCTAssertTrue(only.first && only.tail)
        // 美化没用到的不算
        XCTAssertEqual(CssStructural.bubble(row, at: 0, of: 3, used: []), CssStructCtx())
    }

    func testUsedSuffixesFromStylesAndDark() {
        var c = CssCompiled()
        c.styles[CssKey(hook: "bubble")] = CssStyle()
        c.styles[CssKey(hook: "msg-mine-last", part: .after)] = CssStyle()
        c.dark[CssKey(hook: "bubble-tail")] = CssStyle()
        XCTAssertEqual(CssStructural.used(c), ["-last", "-tail"])
        XCTAssertEqual(CssStructural.used(nil), [])
    }

    func testDerivedStyleWinsOverBase() {
        var c = CssCompiled()
        c.styles[CssKey(hook: "bubble")] = styled { $0.radius = 18; $0.color = red }
        c.styles[CssKey(hook: "bubble-mine")] = styled { $0.color = blue }
        c.styles[CssKey(hook: "bubble-mine-tail")] = styled { $0.radius = 4 }
        c.styles[CssKey(hook: "bubble-last")] = styled { $0.radius = 2 }
        let ctx = CssStructCtx(tail: true, last: true, lastOfSide: true)
        let st = c.resolve(CssStructural.hooks(["bubble", "bubble-mine"], ctx))
        // last 在 tail 之后：bubble-last 的 2 赢过 bubble-mine-tail 的 4
        XCTAssertEqual(st?.radius, 2)
        XCTAssertEqual(st?.color, blue)
        // 不是最后一个：照原钩子
        XCTAssertEqual(c.resolve(CssStructural.hooks(["bubble", "bubble-mine"], CssStructCtx()))?.radius, 18)
    }

    // MARK: - 结构写法：找图次序

    func testRasterCandidatesTryDerivedFirst() {
        let hooks = CssStructural.hooks(["bubble", "bubble-mine"], CssStructCtx(tail: true, lastOfSide: true))
        let c = CssRasterDraw.candidates(hooks)
        XCTAssertEqual(Array(c.prefix(6)), [
            CssRasterKey(hook: "bubble-mine-last"),
            CssRasterKey(hook: "bubble-mine-tail"),
            CssRasterKey(hook: "bubble-tail", variant: "bubble-mine"),
            CssRasterKey(hook: "bubble-tail"),
            CssRasterKey(hook: "bubble", variant: "bubble-mine"),
            CssRasterKey(hook: "bubble-mine"),
        ])
        XCTAssertEqual(c.last, CssRasterKey(hook: "bubble"))
        XCTAssertEqual(c.count, Set(c).count)
    }

    func testRasterCandidatesWithoutDerivedUnchanged() {
        XCTAssertEqual(CssRasterDraw.candidates(["bubble", "bubble-mine"]), [
            CssRasterKey(hook: "bubble", variant: "bubble-mine"),
            CssRasterKey(hook: "bubble-mine"),
            CssRasterKey(hook: "bubble"),
        ])
        // 只有一个派生钩子（消息行的「最后一条」）
        XCTAssertEqual(CssRasterDraw.candidates(["msg-mine-last"], part: .after),
                       [CssRasterKey(hook: "msg-mine-last", part: CssPart.after.rawValue)])
    }

    func testRasterCandidatesDarkFirst() {
        let c = CssRasterDraw.candidates(["send"], state: .pressed, dark: true)
        XCTAssertEqual(c, [
            CssRasterKey(hook: "send", state: "pressed@dark"),
            CssRasterKey(hook: "send", state: "pressed"),
            CssRasterKey(hook: "send", state: "normal@dark"),
            CssRasterKey(hook: "send", state: "normal"),
        ])
    }

    func testPickPrefersDerivedImage() {
        func img(_ id: String) -> CssRasterImage {
            CssRasterImage(kind: .box, imageId: id, width: 20, height: 10)
        }
        var s = CssRasterSet()
        s.images[CssRaster.id(CssRasterKey(hook: "bubble", variant: "bubble-mine"))] = img("base")
        s.images[CssRaster.id(CssRasterKey(hook: "bubble-tail", variant: "bubble-mine"))] = img("tail")
        let tail = CssStructural.hooks(["bubble", "bubble-mine"], CssStructCtx(tail: true))
        XCTAssertEqual(CssRasterDraw.pick(s, tail, kind: .box)?.imageId, "tail")
        XCTAssertEqual(CssRasterDraw.pick(s, ["bubble", "bubble-mine"], kind: .box)?.imageId, "base")
    }

    // MARK: - 深色

    func testDarkOverlayMergesFieldByField() {
        var c = CssCompiled()
        c.styles[CssKey(hook: "bubble")] = styled { $0.color = red; $0.radius = 12; $0.fontSize = 15 }
        c.dark[CssKey(hook: "bubble")] = styled { $0.color = blue }
        c.dark[CssKey(hook: "send")] = styled { $0.opacity = 0.5 }
        c.vars = ["ph-bubble-r": "12px", "ph-avatar-size": "40px"]
        c.darkVars = ["ph-bubble-r": "4px"]
        let d = c.scheme(dark: true)
        XCTAssertEqual(d.style("bubble")?.color, blue)
        XCTAssertEqual(d.style("bubble")?.radius, 12)
        XCTAssertEqual(d.style("bubble")?.fontSize, 15)
        // 只在深色里写了的钩子也有
        XCTAssertEqual(d.style("send")?.opacity, 0.5)
        XCTAssertEqual(d.vars["ph-bubble-r"], "4px")
        XCTAssertEqual(d.vars["ph-avatar-size"], "40px")
        // 浅色原样
        XCTAssertEqual(c.scheme(dark: false), c)
        XCTAssertTrue(c.hasDark)
        // 没写深色规则的深色下也原样
        var plain = c
        plain.dark = [:]
        plain.darkVars = [:]
        XCTAssertFalse(plain.hasDark)
        XCTAssertEqual(plain.scheme(dark: true), plain)
    }

    func testMergeTakesLaterAnimations() {
        let a = CssAnimation(name: "a", frames: [], duration: 1)
        let b = CssAnimation(name: "b", frames: [], duration: 2)
        let base = styled { $0.animations = [a] }
        XCTAssertEqual(CssStyle.merge(base, styled { $0.animations = [b] })?.animations.map(\.name), ["b"])
        // 后一层没写动画：保留前面的
        XCTAssertEqual(CssStyle.merge(base, styled { $0.color = red })?.animations.map(\.name), ["a"])
    }

    // MARK: - 动画时序

    private func anim(duration: Double = 2, delay: Double = 0, iterations: Double? = 1, direction: String = "normal",
                      timing: String = "linear", fill: String = "none", frames: [CssKeyframe] = []) -> CssAnimation {
        CssAnimation(name: "x", frames: frames, duration: duration, delay: delay, iterations: iterations,
                     direction: direction, timing: timing, fillMode: fill)
    }

    private func near(_ a: Double?, _ b: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("nil", file: file, line: line) }
        XCTAssertEqual(a, b, accuracy: 0.0001, file: file, line: line)
    }

    func testProgressNormalWithDelay() {
        let a = anim(duration: 2, delay: 1)
        XCTAssertNil(CssAnim.progress(a, at: 0.5))          // 还在延迟里，没有 backwards
        near(CssAnim.progress(a, at: 1), 0)
        near(CssAnim.progress(a, at: 2), 0.5)
        XCTAssertNil(CssAnim.progress(a, at: 3.5))          // 播完了，没有 forwards
    }

    func testProgressFillModes() {
        near(CssAnim.progress(anim(delay: 1, direction: "reverse", fill: "backwards"), at: 0), 1)
        near(CssAnim.progress(anim(fill: "forwards"), at: 10), 1)
        near(CssAnim.progress(anim(fill: "both"), at: .infinity), 1)
        XCTAssertNil(CssAnim.progress(anim(fill: "backwards"), at: 10))
    }

    func testProgressAlternateWithDelay() {
        let a = anim(duration: 2, delay: 1, iterations: 2, direction: "alternate", fill: "forwards")
        near(CssAnim.progress(a, at: 2), 0.5)              // 第一次的一半
        near(CssAnim.progress(a, at: 3.5), 0.75)           // 第二次倒着走，过了四分之一
        near(CssAnim.progress(a, at: 4.9), 0.05)
        near(CssAnim.progress(a, at: 9), 0)                // 偶数次 alternate 停在起点
        let r = anim(duration: 2, iterations: 2, direction: "alternate-reverse")
        near(CssAnim.progress(r, at: 0.5), 0.75)
        near(CssAnim.progress(r, at: 2.5), 0.25)
    }

    func testProgressFractionalAndInfinite() {
        let half = anim(duration: 2, iterations: 1.5, fill: "forwards")
        near(CssAnim.progress(half, at: 100), 0.5)
        let loop = anim(duration: 2, iterations: nil)
        near(CssAnim.progress(loop, at: 101), 0.5)
        XCTAssertNil(CssAnim.progress(loop, at: .infinity))
        let zero = anim(duration: 0, fill: "forwards")
        near(CssAnim.progress(zero, at: 0), 1)
    }

    func testEasingCurves() {
        near(CssAnim.ease("linear", 0.3), 0.3)
        near(CssAnim.ease("ease-in-out", 0.5), 0.5)
        XCTAssertLessThan(CssAnim.ease("ease-in", 0.5), 0.5)
        XCTAssertGreaterThan(CssAnim.ease("ease-out", 0.5), 0.5)
        XCTAssertGreaterThan(CssAnim.ease("ease", 0.5), 0.5)
        near(CssAnim.ease("cubic-bezier(0, 0, 1, 1)", 0.37), 0.37)
        near(CssAnim.ease("steps(4)", 0.3), 0.25)
        near(CssAnim.ease("steps(4, start)", 0.3), 0.5)
        near(CssAnim.ease("ease", 0), 0)
        near(CssAnim.ease("ease", 1), 1)
        // 认不出的按 ease
        near(CssAnim.ease("bounce", 0.5), CssAnim.ease("ease", 0.5))
    }

    func testSampleInterpolatesWithImplicitEnds() {
        // 只写了 50% 一帧：0% 与 100% 用元素自己的值
        let pulse = anim(duration: 2, iterations: nil, frames: [
            CssKeyframe(at: 0.5, opacity: 0.2, transform: CssTransform(scaleX: 1.2, scaleY: 1.2)),
        ])
        let mid = CssAnim.sample(pulse, at: 1, opacity: 1, transform: nil)
        near(mid.opacity, 0.2)
        near(mid.transform.map(\.scaleX), 1.2)
        let quarter = CssAnim.sample(pulse, at: 0.5, opacity: 1, transform: nil)
        near(quarter.opacity, 0.6)
        near(quarter.transform.map(\.scaleY), 1.1)
        // 没动到的那一项为 nil
        let fade = anim(frames: [CssKeyframe(at: 0, opacity: 0), CssKeyframe(at: 1, opacity: 1)])
        XCTAssertNil(CssAnim.sample(fade, at: 1, opacity: 1, transform: nil).transform)
    }

    func testSampleAllLaterWinsAndRest() {
        let fadeIn = anim(duration: 1, fill: "forwards", frames: [CssKeyframe(at: 0, opacity: 0), CssKeyframe(at: 1, opacity: 0.8)])
        let slide = anim(duration: 1, frames: [CssKeyframe(at: 0, transform: CssTransform(dy: 20)), CssKeyframe(at: 1, transform: CssTransform())])
        let v = CssAnim.sampleAll([fadeIn, slide], at: 0.5, opacity: 1, transform: nil)
        near(v.opacity, 0.4)
        near(v.transform.map(\.dy), 10)
        // 停下来的样子：forwards 的停在终点，没有 forwards 的回到元素自己的值
        let r = CssAnim.rest([fadeIn, slide], opacity: 1, transform: nil)
        near(r.opacity, 0.8)
        XCTAssertNil(r.transform)
        // 无限次的停在元素自己的样子
        let spin = anim(duration: 1, iterations: nil, frames: [CssKeyframe(at: 1, transform: CssTransform(rotate: 360))])
        let s = CssAnim.rest([spin], opacity: 0.9, transform: CssTransform(dx: 3))
        near(s.opacity, 0.9)
        XCTAssertEqual(s.transform, CssTransform(dx: 3))
    }

    func testTotalDuration() {
        XCTAssertEqual(CssAnim.total([anim(duration: 2, delay: 1, iterations: 2), anim(duration: 1)]), 5)
        XCTAssertNil(CssAnim.total([anim(), anim(iterations: nil)]))
        XCTAssertEqual(CssAnim.total([]), 0)
    }

    func testInfiniteAnimationBudget() {
        let b = PhAnimBudget(cap: 2)
        XCTAssertTrue(b.take())
        XCTAssertTrue(b.take())
        XCTAssertFalse(b.take())
        b.give()
        XCTAssertTrue(b.take())
        b.give(); b.give(); b.give()
        XCTAssertEqual(b.inUse, 0)
    }

    // MARK: - 顶栏

    func testNavBarCustomOnlyBeyondSystemFill() {
        XCTAssertFalse(PhNavPlan.custom(nil, hasRaster: false, height: nil))
        // 只有一种颜色或一道渐变：系统顶栏画得出，照旧
        let plain = styled { $0.background = CssBackground(layers: [.color(red)]) }
        XCTAssertFalse(PhNavPlan.custom(plain, hasRaster: false, height: nil))
        let grad = styled { $0.background = CssBackground(layers: [.gradient(CssGradient(angle: 90, stops: []))]) }
        XCTAssertFalse(PhNavPlan.custom(grad, hasRaster: false, height: nil))
        // 边框、阴影、画好的底图、自定的高度、好几层背景：自己画
        XCTAssertTrue(PhNavPlan.custom(styled { $0.borderBottom = CssBorder(width: 1, color: blue) }, hasRaster: false, height: nil))
        XCTAssertTrue(PhNavPlan.custom(styled { $0.shadows = [CssShadow(x: 0, y: 1, blur: 4, color: green)] }, hasRaster: false, height: nil))
        XCTAssertTrue(PhNavPlan.custom(plain, hasRaster: true, height: nil))
        XCTAssertTrue(PhNavPlan.custom(plain, hasRaster: false, height: 56))
        XCTAssertTrue(PhNavPlan.custom(styled { $0.background = CssBackground(layers: [.color(red), .color(blue)]) }, hasRaster: false, height: nil))
        // 写了 display: none 的不画
        XCTAssertFalse(PhNavPlan.custom(styled { $0.hidden = true; $0.borderBottom = CssBorder(width: 1, color: blue) }, hasRaster: true, height: nil))
    }
}
