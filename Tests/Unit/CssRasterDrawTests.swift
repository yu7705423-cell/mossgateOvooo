import SwiftUI
import XCTest
@testable import Eira

/// 美化第二步「贴画好的图」那一边的纯计算：按钩子、状态、变体找图，装饰的对齐与挪动，九宫格四边的收拢。
/// CssRasterSet 一律手写，不经过画图的那一步
final class CssRasterDrawTests: XCTestCase {
    private func img(_ kind: CssRasterImage.Kind, _ id: String, w: Double = 20, h: Double = 10) -> CssRasterImage {
        CssRasterImage(kind: kind, imageId: id, width: w, height: h)
    }

    private func set(_ items: [(CssRasterKey, CssRasterImage)]) -> CssRasterSet {
        var s = CssRasterSet()
        for (k, v) in items { s.images[CssRaster.id(k)] = v }
        return s
    }

    // MARK: - 找图

    func testNoSetOrNoHooksFindsNothing() {
        XCTAssertNil(CssRasterDraw.pick(nil, ["bubble"], kind: .box))
        XCTAssertNil(CssRasterDraw.pick(CssRasterSet(), ["bubble"], kind: .box))
        let s = set([(CssRasterKey(hook: "bubble"), img(.box, "a"))])
        XCTAssertNil(CssRasterDraw.pick(s, [], kind: .box))
        XCTAssertEqual(CssRasterDraw.decors(nil, ["bubble"]), [])
        XCTAssertNil(CssRasterDraw.icon(nil, ["send"]))
    }

    func testVariantBeatsPlainHook() {
        let s = set([
            (CssRasterKey(hook: "bubble"), img(.box, "base")),
            (CssRasterKey(hook: "bubble", variant: "bubble-mine"), img(.box, "mine")),
            (CssRasterKey(hook: "bubble", variant: "bubble-theirs"), img(.box, "theirs")),
        ])
        XCTAssertEqual(CssRasterDraw.pick(s, ["bubble", "bubble-mine"], kind: .box)?.imageId, "mine")
        XCTAssertEqual(CssRasterDraw.pick(s, ["bubble", "bubble-theirs"], kind: .box)?.imageId, "theirs")
        // 没有这一边的变体：退到基础钩子
        let only = set([(CssRasterKey(hook: "bubble"), img(.box, "base"))])
        XCTAssertEqual(CssRasterDraw.pick(only, ["bubble", "bubble-mine"], kind: .box)?.imageId, "base")
    }

    func testMoreSpecificHookBeforeBase() {
        // 加号：.ph-composer-btn 与 .ph-plus 都画了，按 .ph-plus 的
        let s = set([
            (CssRasterKey(hook: "composer-btn"), img(.box, "btn")),
            (CssRasterKey(hook: "plus"), img(.box, "plus")),
        ])
        XCTAssertEqual(CssRasterDraw.pick(s, ["composer-btn", "plus"], kind: .box)?.imageId, "plus")
        XCTAssertEqual(CssRasterDraw.pick(s, ["composer-btn", "sticker-btn"], kind: .box)?.imageId, "btn")
    }

    func testPressedFallsBackToNormal() {
        let normal = set([(CssRasterKey(hook: "send"), img(.box, "n"))])
        XCTAssertEqual(CssRasterDraw.pick(normal, ["send"], state: .pressed, kind: .box)?.imageId, "n")
        let both = set([
            (CssRasterKey(hook: "send"), img(.box, "n")),
            (CssRasterKey(hook: "send", state: CssState.pressed.rawValue), img(.box, "p")),
        ])
        XCTAssertEqual(CssRasterDraw.pick(both, ["send"], state: .pressed, kind: .box)?.imageId, "p")
        XCTAssertEqual(CssRasterDraw.pick(both, ["send"], state: .normal, kind: .box)?.imageId, "n")
    }

    func testPressedVariantBeforeNormalVariant() {
        let s = set([
            (CssRasterKey(hook: "bubble", variant: "bubble-mine"), img(.box, "n")),
            (CssRasterKey(hook: "bubble", state: CssState.pressed.rawValue), img(.box, "p-base")),
        ])
        // 这一种状态优先于更具体的钩子：按下时有按下的图就用它
        XCTAssertEqual(CssRasterDraw.pick(s, ["bubble", "bubble-mine"], state: .pressed, kind: .box)?.imageId, "p-base")
    }

    func testKindAndPartMustMatch() {
        let s = set([
            (CssRasterKey(hook: "bubble", part: CssPart.after.rawValue, variant: "bubble-mine"), img(.decor, "tail")),
            (CssRasterKey(hook: "send", part: CssPart.before.rawValue), img(.icon, "arrow")),
            (CssRasterKey(hook: "nav-action"), img(.box, "box-not-icon")),
        ])
        XCTAssertNil(CssRasterDraw.pick(s, ["bubble", "bubble-mine"], kind: .box))
        XCTAssertEqual(CssRasterDraw.decors(s, ["bubble", "bubble-mine"]).map(\.imageId), ["tail"])
        XCTAssertEqual(CssRasterDraw.decors(s, ["bubble", "bubble-theirs"]).map(\.imageId), [])
        XCTAssertEqual(CssRasterDraw.icon(s, ["send"])?.imageId, "arrow")
        XCTAssertNil(CssRasterDraw.icon(s, ["nav-action"]))
        // 没有图 id 的不算
        let blank = set([(CssRasterKey(hook: "send"), img(.box, ""))])
        XCTAssertNil(CssRasterDraw.pick(blank, ["send"], kind: .box))
    }

    func testDecorsBeforeThenAfter() {
        let s = set([
            (CssRasterKey(hook: "composer", part: CssPart.after.rawValue), img(.decor, "after")),
            (CssRasterKey(hook: "composer", part: CssPart.before.rawValue), img(.decor, "before")),
        ])
        XCTAssertEqual(CssRasterDraw.decors(s, ["composer"]).map(\.imageId), ["before", "after"])
    }

    func testCandidatesHaveNoDuplicates() {
        let c = CssRasterDraw.candidates(["bubble", "bubble"], state: .pressed)
        XCTAssertEqual(c.count, Set(c).count)
        XCTAssertEqual(c.first, CssRasterKey(hook: "bubble", state: "pressed"))
        XCTAssertEqual(CssRasterDraw.candidates([]), [])
    }

    // MARK: - 摆放

    func testAnchorToAlignment() {
        let pairs: [(String, Alignment)] = [
            ("topLeft", .topLeading), ("topRight", .topTrailing), ("bottomLeft", .bottomLeading), ("bottomRight", .bottomTrailing),
            ("top", .top), ("bottom", .bottom), ("left", .leading), ("right", .trailing), ("center", .center),
            ("BOTTOMRIGHT", .bottomTrailing), ("", .topLeading), ("middle", .topLeading),
        ]
        for (a, want) in pairs { XCTAssertEqual(CssRasterDraw.alignment(a), want, a) }
        XCTAssertEqual(CssRasterDraw.horizontal("bottomRight"), .trailing)
        XCTAssertEqual(CssRasterDraw.horizontal("topLeft"), .leading)
        XCTAssertEqual(CssRasterDraw.horizontal("top"), .center)
    }

    func testOffsetIgnoresStretchedAxisAndNonFinite() {
        var d = img(.decor, "t")
        d.dx = 6; d.dy = -3
        XCTAssertEqual(CssRasterDraw.offset(d), CGSize(width: 6, height: -3))
        d.stretchX = true
        XCTAssertEqual(CssRasterDraw.offset(d), CGSize(width: 0, height: -3))
        d.stretchY = true
        XCTAssertEqual(CssRasterDraw.offset(d), .zero)
        var bad = img(.decor, "b")
        bad.dx = .nan; bad.dy = .infinity
        XCTAssertEqual(CssRasterDraw.offset(bad), .zero)
    }

    func testStretchInsetsKeepBothMargins() {
        // ios6 气泡高光：left 6 right 6，元素 200 宽时图 188 宽
        var d = img(.decor, "hl", w: 188, h: 8)
        d.stretchX = true; d.dx = 6; d.refWidth = 200
        var e = CssRasterDraw.stretchInsets(d)
        XCTAssertEqual(e.leading, 6); XCTAssertEqual(e.trailing, 6); XCTAssertEqual(e.top, 0); XCTAssertEqual(e.bottom, 0)
        // 伸出元素之外为负
        d.dx = -4; d.width = 210
        e = CssRasterDraw.stretchInsets(d)
        XCTAssertEqual(e.leading, -4); XCTAssertEqual(e.trailing, -6)
        // 竖向：参考高度为 0（内容撑开）时上下对称
        var v = img(.decor, "v", w: 4, h: 50)
        v.stretchY = true; v.dy = 3; v.refHeight = 0
        e = CssRasterDraw.stretchInsets(v)
        XCTAssertEqual(e.top, 3); XCTAssertEqual(e.bottom, 3); XCTAssertEqual(e.leading, 0)
        v.refHeight = 60
        XCTAssertEqual(CssRasterDraw.stretchInsets(v).bottom, 7)
        // 不拉伸的没有边距
        XCTAssertEqual(CssRasterDraw.stretchInsets(img(.decor, "n")), EdgeInsets())
    }

    func testBoxOutsetFromPlacement() {
        // 元素 100x40，阴影左右各伸出 4、上伸出 2、下伸出 8：图 108x50，左上角在 (-4, -2)
        var b = img(.box, "b", w: 108, h: 50)
        b.dx = -4; b.dy = -2; b.refWidth = 100; b.refHeight = 40
        XCTAssertEqual(CssRasterDraw.boxOutset(b), EdgeInsets(top: 2, leading: 4, bottom: 8, trailing: 4))
        // 没有溢出
        var plain = img(.box, "p", w: 100, h: 40)
        plain.refWidth = 100; plain.refHeight = 40
        XCTAssertEqual(CssRasterDraw.boxOutset(plain), EdgeInsets())
        // 高度由内容撑开（refHeight 0）：下与上对称
        var auto = img(.box, "a", w: 110, h: 999)
        auto.dx = -5; auto.dy = -3; auto.refWidth = 100; auto.refHeight = 0
        XCTAssertEqual(CssRasterDraw.boxOutset(auto), EdgeInsets(top: 3, leading: 5, bottom: 3, trailing: 5))
    }

    // MARK: - 九宫格

    func testCapsKeptWhenTheyFit() {
        var b = img(.box, "b", w: 40, h: 30)
        b.capTop = 10; b.capBottom = 12; b.capLeft = 14; b.capRight = 15
        XCTAssertEqual(CssRasterDraw.caps(b), EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 15))
    }

    func testCapsShrinkProportionallyLeavingOnePoint() {
        var b = img(.box, "b", w: 21, h: 11)
        b.capTop = 10; b.capBottom = 10      // 20 > 11 - 1：按比例缩到一共 10
        b.capLeft = 30; b.capRight = 10      // 40 > 21 - 1：按比例缩到一共 20
        let c = CssRasterDraw.caps(b)
        XCTAssertEqual(c.top, 5, accuracy: 0.0001)
        XCTAssertEqual(c.bottom, 5, accuracy: 0.0001)
        XCTAssertEqual(c.leading, 15, accuracy: 0.0001)
        XCTAssertEqual(c.trailing, 5, accuracy: 0.0001)
    }

    func testCapsNegativeAndNonFiniteAreZero() {
        var b = img(.box, "b", w: 40, h: 30)
        b.capTop = -4; b.capBottom = .nan; b.capLeft = .infinity; b.capRight = 3
        let c = CssRasterDraw.caps(b)
        XCTAssertEqual(c.top, 0); XCTAssertEqual(c.bottom, 0); XCTAssertEqual(c.leading, 0); XCTAssertEqual(c.trailing, 3)
        // 图的边长不足 1 点：四边全收成 0
        var tiny = img(.box, "t", w: 0.5, h: 0)
        tiny.capTop = 2; tiny.capLeft = 2
        XCTAssertEqual(CssRasterDraw.caps(tiny), EdgeInsets())
    }

    func testMaxPixelAndPointScale() {
        let b = img(.box, "b", w: 40, h: 30)
        XCTAssertEqual(CssRasterDraw.maxPixel(b), 120)
        XCTAssertEqual(CssRasterDraw.maxPixel(img(.box, "z", w: 0, h: 0)), 1)
        // 存的是 120 像素宽的图，画图时 40 点：按 3 倍读，九宫格的四边按点算
        UIGraphicsBeginImageContextWithOptions(CGSize(width: 120, height: 90), false, 1)
        let raw = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard let raw else { return XCTFail("测试图未能生成") }
        let p = CssRasterDraw.pointImage(raw, b)
        XCTAssertEqual(p.scale, 3, accuracy: 0.0001)
        XCTAssertEqual(p.size.width, 40, accuracy: 0.0001)
        XCTAssertEqual(p.size.height, 30, accuracy: 0.0001)
    }
}
