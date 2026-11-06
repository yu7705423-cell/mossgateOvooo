import XCTest
import SwiftUI
import UIKit
@testable import Eira

/// 聊天主题（ChatTheme）：挂哪一份（会话 > 默认 > 应用本来的样子，总开关关着时一律回到本来的样子）、
/// 网页版 CSS 的变量落到同样的格子上、原生格子盖过网页版美化、这段会话自己的背景与上下栏盖过主题、
/// 改一格不丢认不得的字段、导出再导入一字不差（背景图跟着文件走）、内置的几套只用黑白灰
final class ChatThemeTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    private func put(_ fields: [String: JSONValue]) throws -> Row {
        let r = Row.new(prefix: "sk", fields)
        try Database.shared.put(Skins.collection, r)
        return r
    }

    private func chat() throws -> Chat { try XCTUnwrap(Repo.chat("chat_a")) }

    private func gray(_ v: Double) -> CssColor { CssColor(r: v, g: v, b: v, a: 1) }

    // MARK: - 挂哪一份

    func testNoThemeIsAppDefault() throws {
        let c = try chat()
        let t = ChatTheme.resolve(c, settings: .load())
        XCTAssertNil(t.row)
        XCTAssertEqual(t.source, "")
        XCTAssertNil(t.light.css)
        XCTAssertNil(t.dark.css)
        XCTAssertEqual(t.light.skin, Skins.Look())
        XCTAssertEqual(t.dark.skin, Skins.Look())
        XCTAssertEqual(t.light.look, ChatLook.of(c))
        XCTAssertEqual(t.scheme, "")
        XCTAssertTrue(t.structUse.isEmpty)
        XCTAssertFalse(t.webCss)
    }

    func testChatThemeBeatsGlobalBeatsDefault() throws {
        // 默认：内置的纸白
        try ChatTheme.setGlobal("builtin-paper")
        var t = ChatTheme.resolve(try chat(), settings: .load())
        XCTAssertEqual(t.row?.id, "builtin-paper")
        XCTAssertEqual(t.source, "global")
        XCTAssertEqual(t.light.skin.mine.radius, 18)
        XCTAssertEqual(t.light.look.base, "#F5F5F5")
        XCTAssertEqual(t.dark.look.base, "#0F0F0F")

        // 这段会话挂了自己的一份：整份换成它的，默认那一份的格子不掺进来
        let mine = try ChatTheme.create(name: "这一段")
        try ChatTheme.set(mine.id, "mine.fill", .string("#777777"))
        try Skins.attach("chat_a", mine.id)
        t = ChatTheme.resolve(try chat(), settings: .load())
        XCTAssertEqual(t.row?.id, mine.id)
        XCTAssertEqual(t.source, "chat")
        XCTAssertEqual(t.light.skin.mine.bg, "#777777")
        XCTAssertEqual(t.light.skin.mine.radius, Theme.bubbleRadius)
        XCTAssertEqual(t.light.look.base, "")

        // 取下之后回到默认
        try Skins.attach("chat_a", "")
        XCTAssertEqual(ChatTheme.resolve(try chat(), settings: .load()).row?.id, "builtin-paper")

        // 库里的一份要带 shell 这一档才当默认（同网页版 isGlobal）；setGlobal 自动带上
        let g = try ChatTheme.create(name: "默认")
        try setSettings(["globalSkinId": .string(g.id)])
        XCTAssertNil(ChatTheme.resolve(try chat(), settings: .load()).row)
        try ChatTheme.setGlobal(g.id)
        XCTAssertTrue(ChatTheme.scopes(try XCTUnwrap(Skins.get(g.id))).contains("shell"))
        XCTAssertEqual(ChatTheme.resolve(try chat(), settings: .load()).row?.id, g.id)
        // 不存在的不能设
        XCTAssertThrowsError(try ChatTheme.setGlobal("builtin-none"))
    }

    func testMasterSwitchOffGivesDefaults() throws {
        let r = try ChatTheme.create(name: "A")
        try ChatTheme.set(r.id, "palette.bg", .string("#E9E9E9"))
        try ChatTheme.set(r.id, "avatar.shape", .string("round"))
        try Skins.attach("chat_a", r.id)
        try ChatTheme.setGlobal("builtin-graphite")
        try ChatLook.set("chat_a", ["narr": .string("#3A3A3C")])
        try setSettings(["skinOff": .bool(true)])
        let t = ChatTheme.resolve(try chat(), settings: .load())
        XCTAssertNil(t.row)
        XCTAssertNil(t.light.css)
        XCTAssertEqual(t.light.skin, Skins.Look())
        XCTAssertEqual(t.scheme, "")
        XCTAssertEqual(t.light.look.base, "")
        // 这段会话自己的设置不是主题：照旧
        XCTAssertEqual(t.light.look.narr, "#3A3A3C")
        try setSettings(["skinOff": .bool(false)])
        XCTAssertEqual(ChatTheme.resolve(try chat(), settings: .load()).row?.id, r.id)
    }

    func testApplyToAll() throws {
        let a = try ChatTheme.create(name: "A")
        try Skins.attach("chat_a", a.id)
        let n = try ChatTheme.applyToAll("builtin-mist", clearChats: true)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try chat().row.string("skinId"), "")
        XCTAssertEqual(AppSettings.load().raw["globalSkinId"]?.string, "builtin-mist")
        XCTAssertEqual(ChatTheme.resolve(try chat(), settings: .load()).source, "global")
        try Skins.attach("chat_a", a.id)
        XCTAssertEqual(try ChatTheme.applyToAll("builtin-paper", clearChats: false), 0)
        XCTAssertEqual(try chat().row.string("skinId"), a.id)
    }

    // MARK: - 网页版美化与原生格子落进同样几格

    func testCssVarsMapUnderCssAndNativeWins() throws {
        var web = CssCompiled()
        web.vars = ["ph-accent": "#333333", "ph-surface": "rgba(255, 255, 255, 0.5)", "ph-bg": "#EEEEEE", "ph-status-r": "6px"]
        let row = Row(fields: ["id": .string("sk_web")])
        let f = ChatTheme.face(row: row, web: web, own: ChatLook.Look(), dark: false)
        let css = try XCTUnwrap(f.css)
        XCTAssertEqual(css.style("bubble-mine")?.background?.layers.first, .color(gray(0.2)))
        // 主色上的字按明暗取白
        XCTAssertEqual(css.style("bubble-mine")?.color, gray(1))
        XCTAssertEqual(css.style("bubble-theirs")?.background?.layers.first, .color(CssColor(r: 1, g: 1, b: 1, a: 128.0 / 255)))
        XCTAssertEqual(css.style("status")?.radius, 6)
        XCTAssertEqual(f.look.base, "#EEEEEE")
        // 网页版的变量不把上下栏换成实色（免得盖掉 CSS 自己画的顶栏）
        XCTAssertFalse(f.look.top.isSet)
        // 变量垫在手写 CSS 下面：CSS 写了的照 CSS
        web.styles[CssKey(hook: "bubble-mine")] = { var s = CssStyle(); s.background = CssBackground(layers: [.color(gray(0))]); return s }()
        let f2 = ChatTheme.face(row: row, web: web, own: ChatLook.Look(), dark: false)
        XCTAssertEqual(f2.css?.style("bubble-mine")?.background?.layers.first, .color(gray(0)))

        // 同一行里原生版亲手调的盖过手写 CSS（按生成器的规矩：底色写进 Look，画的时候把 CSS 的底去掉）
        let both = try put(["name": .string("B"), "css": .string(".ph-bubble-mine{background:#111111}"),
                            "native": .object(["mine": .object(["fill": .string("#777777"), "border": .string("#000000")])])])
        let t = ChatTheme.resolve(row: both)
        XCTAssertTrue(t.webCss)
        XCTAssertEqual(t.light.skin.mine.bg, "#777777")
        let raw = try XCTUnwrap(t.light.css?.resolve(["bubble", "bubble-mine"]))
        XCTAssertNil(t.light.skin.mine.overriding(raw).background)
        XCTAssertEqual(raw.border?.width, 1)
    }

    func testCssTextVarsReachSlots() throws {
        let r = try put(["name": .string("V"), "css": .string(":root{--ph-accent:#333333}")])
        let t = ChatTheme.resolve(row: r)
        XCTAssertEqual(t.light.css?.style("bubble-mine")?.background?.layers.first, .color(gray(0.2)))
    }

    func testChatOwnLookBeatsTheme() throws {
        let r = try ChatTheme.create(name: "壁纸")
        try ChatTheme.set(r.id, "wall.image", .string("img_theme"))
        try ChatTheme.set(r.id, "wall.blur", .number(12))
        try ChatTheme.set(r.id, "wall.dim", .number(30))
        try ChatTheme.set(r.id, "palette.bg", .string("#E9E9E9"))
        try ChatTheme.set(r.id, "sys.color", .string("#5C5C5C"))
        try Skins.attach("chat_a", r.id)
        var t = ChatTheme.resolve(try chat(), settings: .load())
        XCTAssertEqual(t.light.look.bg, "img_theme")
        XCTAssertEqual(t.light.look.blur, 12)
        XCTAssertEqual(t.light.look.veil, 30)
        XCTAssertEqual(t.light.look.top.color, "#E9E9E9")
        XCTAssertEqual(t.light.look.top.style, "solid")
        XCTAssertEqual(t.light.look.narr, "#5C5C5C")
        // 这段会话自己设过的背景图、上下栏、旁白颜色在上
        try ChatLook.set("chat_a", ["bg": .string("img_chat"), "veil": .number(10), "top": .object(["style": .string("glass")]),
                                    "narr": .string("#3A3A3C")])
        t = ChatTheme.resolve(try chat(), settings: .load())
        XCTAssertEqual(t.light.look.bg, "img_chat")
        XCTAssertEqual(t.light.look.veil, 10)
        XCTAssertEqual(t.light.look.blur, 0)
        XCTAssertEqual(t.light.look.top.style, "glass")
        XCTAssertEqual(t.light.look.narr, "#3A3A3C")
        // 底色仍是主题的
        XCTAssertEqual(t.light.look.base, "#E9E9E9")
        // 有背景图时消息列表不另铺底色以外的东西：底色照样记在 chat-body 上，会话页按 look.bg 决定画不画
        XCTAssertNotNil(t.light.css?.style("chat-body"))
    }

    func testDarkLayerAndForcedScheme() throws {
        let r = try ChatTheme.create(name: "深浅")
        try ChatTheme.set(r.id, "palette.accent", .string("#1A1A1A"))
        try ChatTheme.set(r.id, "palette.accent", .string("#E6E6E6"), dark: true)
        var t = ChatTheme.resolve(row: try XCTUnwrap(Skins.get(r.id)))
        XCTAssertEqual(t.light.skin.mine.bg, "#1A1A1A")
        XCTAssertEqual(t.light.skin.mine.fg, "#FFFFFF")
        XCTAssertEqual(t.dark.skin.mine.bg, "#E6E6E6")
        XCTAssertEqual(t.dark.skin.mine.fg, "#000000")
        XCTAssertTrue(ChatTheme.darkSet(Skins.get(r.id), "palette.accent"))
        XCTAssertFalse(ChatTheme.darkSet(Skins.get(r.id), "palette.bg"))

        // 石墨始终深色：上下栏的字跟着换成浅色
        t = ChatTheme.resolve(row: ChatTheme.row("builtin-graphite"))
        XCTAssertEqual(t.scheme, "dark")
        XCTAssertEqual(ChatTheme.colorScheme(t.scheme), .dark)
        XCTAssertEqual(t.light.look.top.fg, "light")
        XCTAssertEqual(t.light.look.bottom.fg, "light")
        XCTAssertEqual(t.light.skin.radius(36), 18)
    }

    func testTailFontAndStamps() throws {
        let r = try ChatTheme.create(name: "尾巴")
        try ChatTheme.set(r.id, "mine.tail", .bool(true))
        try ChatTheme.set(r.id, "font.family", .string("serif"))
        try ChatTheme.set(r.id, "font.scale", .number(1.2))
        try ChatTheme.set(r.id, "sys.fill", .string("#D6D6D6"))
        let t = ChatTheme.resolve(row: try XCTUnwrap(Skins.get(r.id)))
        XCTAssertTrue(t.structUse.contains("-tail"))
        let css = try XCTUnwrap(t.light.css)
        // 只挂在同一条消息最后一个气泡上
        let last = CssStructural.hooks(["bubble", "bubble-mine"], CssStructural.bubble(CssStructCtx(), at: 1, of: 2, used: t.structUse))
        let first = CssStructural.hooks(["bubble", "bubble-mine"], CssStructural.bubble(CssStructCtx(), at: 0, of: 2, used: t.structUse))
        XCTAssertEqual(css.resolve(last)?.raw[ChatTheme.tailKey], "right")
        XCTAssertNil(css.resolve(first)?.raw[ChatTheme.tailKey])
        XCTAssertNil(css.resolve(["bubble", "bubble-theirs"])?.raw[ChatTheme.tailKey])
        XCTAssertEqual(css.style("bubble-mine")?.fontFamily, ["serif"])
        // 字号按整体缩放，生成器的规矩：CSS 写的字号让位
        XCTAssertEqual(t.light.skin.mine.font, Theme.bubbleFont * 1.2, accuracy: 0.001)
        XCTAssertTrue(t.light.skin.mine.fixed.contains("fs"))
        XCTAssertEqual(css.style("stamp")?.fontSize ?? 0, 11 * 1.2, accuracy: 0.001)
        XCTAssertEqual(css.style("time-sep")?.radius, 999)
        XCTAssertEqual(css.style("time-sep")?.background?.layers.first, .color(gray(214.0 / 255)))

        // 画出来：小尾巴朝外伸出气泡
        let st = try XCTUnwrap(css.resolve(last))
        let path = CssBoxShape(st, fallback: PhFallback(radius: 14)).path(in: CGRect(x: 0, y: 0, width: 100, height: 40))
        XCTAssertGreaterThan(path.boundingRect.maxX, 100)
        let plain = CssBoxShape(nil, fallback: PhFallback(radius: 14)).path(in: CGRect(x: 0, y: 0, width: 100, height: 40))
        XCTAssertEqual(plain.boundingRect.maxX, 100, accuracy: 0.5)
    }

    // MARK: - 改与存

    func testEditsKeepUnknownFieldsAndValidate() throws {
        let r = try put(["name": .string("C"), "css": .string("x{}"), "future": .string("keep"),
                         "native": .object(["v": .number(1), "later": .object(["a": .number(1)]),
                                            "mine": .object(["fill": .string("#111111"), "glow": .bool(true)])])])
        try ChatTheme.set(r.id, "mine.radius", .number(99))
        try ChatTheme.set(r.id, "theirs.text", .string("#222"), dark: true)
        var after = try XCTUnwrap(Skins.get(r.id))
        XCTAssertEqual(ChatTheme.slots(after, dark: false).num("mine.radius"), 40)
        XCTAssertEqual(ChatTheme.slots(after, dark: true).color("theirs.text"), "#222222")
        XCTAssertNil(ChatTheme.slots(after, dark: false).color("theirs.text"))
        try ChatTheme.reset(r.id, group: "mine")
        after = try XCTUnwrap(Skins.get(r.id))
        XCTAssertEqual(after["native"]?["later"]?["a"]?.number, 1)
        XCTAssertEqual(after["native"]?["mine"]?["glow"]?.bool, true)
        XCTAssertNil(after["native"]?["mine"]?["fill"])
        XCTAssertEqual(after.string("css"), "x{}")
        XCTAssertEqual(after.string("future"), "keep")
        XCTAssertThrowsError(try ChatTheme.set("builtin-paper", "mine.fill", .string("#000000")))
        XCTAssertThrowsError(try ChatTheme.set(r.id, "mine.fill", .string("red")))
        XCTAssertThrowsError(try ChatTheme.set(r.id, "mine.nothing", .string("#000000")))
        // 库里写坏了的值当没写
        let bad = try put(["native": .object(["mine": .object(["fill": .string("blue"), "radius": .string("12")]),
                                              "avatar": .object(["shape": .string("star")])])])
        let s = ChatTheme.slots(bad, dark: false)
        XCTAssertNil(s.color("mine.fill"))
        XCTAssertEqual(s.num("mine.radius"), 12)
        XCTAssertEqual(s.choice("avatar.shape"), "")
    }

    func testCopyBuiltinAndUserRow() throws {
        let paper = try XCTUnwrap(ChatTheme.row("builtin-paper"))
        let copy = try ChatTheme.create(name: "纸白 副本", from: paper)
        XCTAssertFalse(ChatTheme.isBuiltin(copy.id))
        XCTAssertEqual(ChatTheme.slots(copy, dark: true), ChatTheme.slots(paper, dark: true))
        try ChatTheme.set(copy.id, "mine.fill", .string("#5C5C5C"))
        // 内置的那一份不跟着变
        XCTAssertNil(ChatTheme.slots(ChatTheme.row("builtin-paper"), dark: false).color("mine.fill"))

        let web = try put(["name": .string("W"), "css": .string("a{}"), "tokens": .object(["bubbleR": .number(9)])])
        let c2 = try ChatTheme.create(name: "W2", from: web)
        XCTAssertEqual(c2.string("css"), "a{}")
        XCTAssertEqual(Skins.token(c2, "bubbleR"), 9)
        XCTAssertNotEqual(c2.id, web.id)
    }

    // MARK: - 导入导出

    func testPackRoundTrip() throws {
        let r = try ChatTheme.create(name: "晚灯")
        try ChatTheme.set(r.id, "mine.fill", .string("#5c5c5c"))
        try ChatTheme.set(r.id, "mine.tail", .bool(true))
        try ChatTheme.set(r.id, "font.family", .string("serif"))
        try ChatTheme.set(r.id, "look.scheme", .string("dark"))
        try ChatTheme.set(r.id, "palette.bg", .string("#1A1A1A"), dark: true)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let img = try Images.save(png)
        try ChatTheme.set(r.id, "wall.image", .string(img))
        let row = try XCTUnwrap(Skins.get(r.id))

        let text = try ChatTheme.pack(row)
        XCTAssertTrue(text.contains("\"phone-skin\""))
        // 本机的图片 id 不出门，图本身以 data: 地址带着
        XCTAssertFalse(text.contains(img))
        XCTAssertTrue(text.contains("data:image/"))

        let p = try Skins.parsePack(text)
        XCTAssertEqual(p.name, "晚灯")
        XCTAssertNotNil(p.native?["wall"]?["data"]?.string)
        let back = try Skins.install(p)
        XCTAssertNotEqual(back.id, r.id)
        let newImg = try XCTUnwrap(ChatTheme.slots(back, dark: false).color("wall.image"))
        XCTAssertNotEqual(newImg, img)
        XCTAssertNotNil(MediaStore.url(.images, id: newImg))
        XCTAssertNil(back["native"]?["wall"]?["data"])
        for d in [false, true] {
            var a = ChatTheme.slots(row, dark: d)
            var b = ChatTheme.slots(back, dark: d)
            a.v["wall.image"] = nil
            b.v["wall.image"] = nil
            XCTAssertEqual(a, b)
        }
        XCTAssertEqual(ChatTheme.slots(back, dark: false).color("mine.fill"), "#5C5C5C")

        // 文件也读得回
        let url = try ChatTheme.exportFile(row)
        XCTAssertEqual(url.pathExtension, "json")
        XCTAssertEqual(try Skins.parsePack(String(contentsOf: url, encoding: .utf8)).native, p.native)
    }

    func testPackKeepsWebPartsAndDropsUnknown() throws {
        let r = try put(["name": .string("混合"), "css": .string(".ph-bubble{color:#111}"), "shape": .string("round"),
                         "tokens": .object(["bubbleR": .number(9)]), "scope": .array([.string("chat"), .string("shell")]),
                         "native": .object(["mine": .object(["fill": .string("#777777"), "secret": .string("x")]),
                                            "hack": .string("y"), "wall": .object(["image": .string("img_local")])])])
        let p = try Skins.parsePack(try ChatTheme.pack(r))
        XCTAssertEqual(p.css, ".ph-bubble{color:#111}")
        XCTAssertEqual(p.shape, "round")
        XCTAssertEqual(p.tokens["bubbleR"]?.number, 9)
        XCTAssertEqual(Set(p.scope), ["chat", "shell"])
        XCTAssertEqual(p.native?["mine"]?["fill"]?.string, "#777777")
        XCTAssertNil(p.native?["mine"]?["secret"])
        XCTAssertNil(p.native?["hack"])
        // 图读不到时不带，本机 id 也不带
        XCTAssertNil(p.native?["wall"])
        // 网页版导出的老包没有 native
        let old = try Skins.unpack(#"{"kind":"phone-skin","version":1,"name":"老包","css":""}"#)
        XCTAssertNil(old.native)
        XCTAssertNil(try Skins.install(old)[ChatTheme.field])
        // 别人给的 data: 地址以外的图不认
        XCTAssertNil(ChatTheme.sanitize(.object(["wall": .object(["data": .string("https://example.com/a.png")])]))?["wall"])
    }

    // MARK: - 内置

    func testBuiltinsAreNeutralGrey() throws {
        XCTAssertEqual(Set(ChatTheme.builtins.map(\.id)).count, ChatTheme.builtins.count)
        for r in ChatTheme.builtins {
            XCTAssertTrue(ChatTheme.isBuiltin(r.id))
            XCTAssertFalse(r.string("name").isEmpty)
            for d in [false, true] {
                let s = ChatTheme.slots(r, dark: d)
                XCTAssertFalse(s.isEmpty, r.id)
                for (k, v) in s.v {
                    guard ChatTheme.def(k)?.kind == .color || ChatTheme.def(k)?.kind == .solid, let h = v.string else { continue }
                    let a = Array(h.dropFirst())
                    XCTAssertTrue(a.count >= 6 && a[0] == a[2] && a[2] == a[4] && a[1] == a[3] && a[3] == a[5], "\(r.id) \(k) \(h) 不是灰")
                }
            }
            // 每一套都画得出来
            let t = ChatTheme.resolve(row: r)
            XCTAssertNotNil(t.light.css, r.id)
        }
    }
}
