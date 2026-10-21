import XCTest
@testable import Eira

/// 美化：读网页版 skins 的令牌、形状、生成器的头像与气泡两组；挂哪一份看 chat.skinId，没挂看全局；
/// 删一份时挂着的会话一并取下；读不懂的几样原样保留、写回不丢
final class SkinsTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    private func put(_ fields: [String: JSONValue]) throws -> Row {
        let r = Row.new(prefix: "sk", fields)
        try Database.shared.put(Skins.collection, r)
        return r
    }

    func testDefaultsWithoutSkin() throws {
        let l = Skins.look(nil)
        XCTAssertEqual(l, Skins.Look())
        XCTAssertTrue(l.showFace(true) && l.showFace(false))
        XCTAssertEqual(l.radius(44), 14)
    }

    func testTokensThenGeneratorWinsOnItsSide() throws {
        let r = try put([
            "name": .string("A"),
            "tokens": .object(["bubbleR": .number(20), "bubbleFS": .number(16), "gap": .number(24), "gapIn": .number(2)]),
            "shape": .string("round"),
            "gen": .object([
                "bubble": .object(["side": .string("mine"), "bg": .string("#112233"), "r": .string("6")]),
                "avatar": .object(["show": .string("theirs"), "size": .number(48)]),
            ]),
            "css": .string(".ph-bubble{color:red}"),
        ])
        let l = Skins.look(r)
        XCTAssertEqual(l.gap, 24)
        XCTAssertEqual(l.gapIn, 2)
        XCTAssertEqual(l.theirs.radius, 20)
        XCTAssertEqual(l.theirs.font, 16)
        XCTAssertEqual(l.theirs.bg, "")
        XCTAssertEqual(l.mine.radius, 6)
        XCTAssertEqual(l.mine.bg, "#112233")
        XCTAssertNotNil(l.mine.fill)
        XCTAssertEqual(l.avatarSize, 48)
        XCTAssertEqual(l.radius(48), 24)
        XCTAssertFalse(l.showFace(true))
        XCTAssertTrue(l.showFace(false))
        // 自定义 CSS 不再算「画不出来」：读得懂的照着画，逐条情况在还原情况里
        XCTAssertEqual(Skins.skipped(r), [])
    }

    func testGeneratorRoundOverridesShape() throws {
        let r = try put(["shape": .string("square"), "gen": .object(["avatar": .object(["round": .number(25)])])])
        XCTAssertEqual(Skins.look(r).radius(40), 10)
    }

    func testBadColorIgnored() throws {
        let r = try put(["gen": .object(["bubble": .object(["bg": .string("red"), "fg": .string("#abc")])])])
        let l = Skins.look(r)
        XCTAssertEqual(l.theirs.bg, "")
        XCTAssertEqual(l.theirs.fg, "#abc")
    }

    func testChatSkinThenGlobal() throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertNil(Skins.of(chat))
        let g = try put(["name": .string("全局"), "scope": .array([.string("chat"), .string("shell")])])
        try setSettings(["globalSkinId": .string(g.id)])
        XCTAssertEqual(Skins.of(chat, settings: .load())?.id, g.id)
        try setSettings(["globalSkinId": .string(g.id), "skinOff": .bool(true)])
        XCTAssertNil(Skins.of(chat, settings: .load()))
        let mine = try Skins.create(name: "这一段")
        try Skins.attach("chat_a", mine.id)
        XCTAssertNil(Skins.of(try Repo.chat("chat_a"), settings: .load()))
        try setSettings(["skinOff": .bool(false)])
        XCTAssertEqual(Skins.of(try Repo.chat("chat_a"), settings: .load())?.id, mine.id)
        XCTAssertEqual(Skins.usedBy(mine.id), 1)
    }

    func testRemoveDetachesChats() throws {
        let r = try Skins.create(name: "B")
        try Skins.attach("chat_a", r.id)
        try setSettings(["globalSkinId": .string(r.id)])
        try Skins.remove(r.id)
        XCTAssertEqual(try Repo.chat("chat_a")?.row.string("skinId"), "")
        XCTAssertEqual(AppSettings.load().raw["globalSkinId"]?.string, "")
        XCTAssertNil(Skins.get(r.id))
    }

    func testEditsKeepUnknownFields() throws {
        let r = try put(["name": .string("C"), "css": .string("x{}"), "frame": .string("data:image/png;base64,AA"),
                         "gen": .object(["tail": .object(["on": .bool(true)])])])
        try Skins.setToken(r.id, "bubbleR", 9)
        try Skins.setGen(r.id, "bubble", "fg", .string("#000000"))
        try Skins.setGen(r.id, "avatar", "show", .string("none"))
        let after = try XCTUnwrap(Skins.get(r.id))
        XCTAssertEqual(after.string("css"), "x{}")
        XCTAssertEqual(after.string("frame"), "data:image/png;base64,AA")
        XCTAssertEqual(after["gen"]?.object?["tail"]?.object?["on"]?.bool, true)
        XCTAssertEqual(Skins.token(after, "bubbleR"), 9)
        XCTAssertEqual(Skins.look(after).show, "none")
        XCTAssertEqual(Set(Skins.skipped(after)), ["头像框", "生成器的其他样式"])
        // 有手写 CSS 时动了令牌、生成器：记 late（网页版 4.615）
        XCTAssertEqual(after["late"]?.bool, true)
        try Skins.setToken(r.id, "bubbleR", nil)
        XCTAssertNil(Skins.token(try XCTUnwrap(Skins.get(r.id)), "bubbleR"))
    }

    // MARK: - 手写 CSS 的变量与令牌、生成器的先后

    private func cssWith(_ vars: [String: String]) -> CssCompiled {
        var c = CssCompiled()
        c.vars = vars
        return c
    }

    func testCssVarsOverrideTokensButNotGenerator() throws {
        let r = try put([
            "tokens": .object(["bubbleR": .number(20), "gap": .number(24)]),
            "gen": .object(["bubble": .object(["side": .string("mine"), "r": .number(6)])]),
            "css": .string(":root{--ph-bubble-r:3px}"),
        ])
        let l = Skins.look(r, css: cssWith(["ph-bubble-r": "3px", "ph-bubble-gap": "30px", "ph-composer-h": "44px",
                                            "ph-avatar-r": "50%", "ph-avatar-size": "40px"]))
        XCTAssertEqual(l.theirs.radius, 3)      // 变量盖过令牌
        XCTAssertEqual(l.mine.radius, 6)        // 生成器（!important）盖过变量
        XCTAssertEqual(l.mine.fixed, ["r"])
        XCTAssertEqual(l.gap, 30)
        XCTAssertEqual(l.composerH, 44)
        XCTAssertNil(l.composerPad)
        XCTAssertEqual(l.avatarSize, 40)
        XCTAssertEqual(l.radius(40), 20)
    }

    func testLateTokensWinOverCssVars() throws {
        let r = try put(["tokens": .object(["bubbleR": .number(20)]), "late": .bool(true), "css": .string("a{}")])
        let l = Skins.look(r, css: cssWith(["ph-bubble-r": "3px", "ph-bubble-px": "9"]))
        XCTAssertEqual(l.theirs.radius, 20)
        XCTAssertEqual(l.theirs.padX, 9)
    }

    func testAvatarRadiusPixelsAndShape() throws {
        let r = try put(["shape": .string("round")])
        // 形状在令牌这一层，CSS 的像素圆角盖过它；像素不超过边长的一半
        let l = Skins.look(r, css: cssWith(["ph-avatar-r": "8px"]))
        XCTAssertEqual(l.radius(36), 8)
        XCTAssertEqual(Skins.look(r, css: cssWith(["ph-avatar-r": "80px"])).radius(36), 18)
        XCTAssertEqual(Skins.look(r).radius(36), 18)
        // 认不出的单位当没写
        XCTAssertEqual(Skins.look(r, css: cssWith(["ph-avatar-r": "1em", "ph-bubble-r": "calc(2px + 1px)"])).theirs.radius, Theme.bubbleRadius)
    }

    func testNoCssVarsKeepsOldLook() throws {
        let r = try put(["tokens": .object(["bubbleR": .number(20)]), "shape": .string("soft")])
        XCTAssertEqual(Skins.look(r, css: CssCompiled()), Skins.look(r))
    }

    // MARK: - 美化包

    private func packJSON(_ extra: String = "") -> String {
        """
        {"kind":"phone-skin","version":1,"name":"晚风","author":"阿岚","tokens":{"bubbleR":"18","bad":3,"gap":"x"},
         "shape":"round","scope":["chat","shell","other"],"gen":{"bubble":{"bg":"#112233"}},"frame":"javascript:1",
         "frameWho":"nobody","frameScale":999,"css":".ph-bubble{color:#fff;background:url(https://a.example/x.png)}"\(extra)}
        """
    }

    func testUnpackKeepsOnlyKnownFields() throws {
        let p = try Skins.unpack(packJSON())
        XCTAssertEqual(p.name, "晚风")
        XCTAssertEqual(p.author, "阿岚")
        XCTAssertEqual(p.tokens, ["bubbleR": .number(18)])
        XCTAssertEqual(p.shape, "round")
        XCTAssertEqual(p.scope, ["chat", "shell"])
        XCTAssertEqual(p.frame, "")
        XCTAssertEqual(p.frameWho, "both")
        XCTAssertEqual(p.frameScale, 300)
        XCTAssertFalse(p.late)
        XCTAssertEqual(Skins.remoteRefs(p.css), 1)
    }

    func testUnpackErrorsSayWhy() {
        XCTAssertThrowsError(try Skins.unpack("not json")) { XCTAssertTrue($0.localizedDescription.contains("不是有效的 JSON")) }
        XCTAssertThrowsError(try Skins.unpack("[1]")) { XCTAssertTrue($0.localizedDescription.contains("不是一个对象")) }
        XCTAssertThrowsError(try Skins.unpack(#"{"kind":"phone-char"}"#)) { XCTAssertTrue($0.localizedDescription.contains("phone-char")) }
        XCTAssertThrowsError(try Skins.unpack(#"{"kind":"phone-skin","version":2}"#)) { XCTAssertTrue($0.localizedDescription.contains("更新的版本")) }
    }

    func testParsePackFromMarkersAndMangledJSON() throws {
        let b64 = Data(packJSON().utf8).base64EncodedString()
        var lines: [String] = []
        var rest = Substring(b64)
        while !rest.isEmpty { lines.append(String(rest.prefix(76))); rest = rest.dropFirst(76) }
        // 说明文字里也提到了标记：取最后一个；中间被折行、多了空格也读得出
        let text = "Eira 美化包：晚风\n复制 -----BEGIN EIRA SKIN----- 到 END\n\n-----BEGIN EIRA SKIN-----\n"
            + lines.joined(separator: " \r\n") + "\n-----END EIRA SKIN-----\n"
        XCTAssertEqual(try Skins.parsePack(text).name, "晚风")
        // 聊天软件把引号换成弯引号、前后多了字
        let mangled = "看这个：" + packJSON().replacingOccurrences(of: "\"", with: "\u{201C}") + " 好看"
        XCTAssertEqual(try Skins.parsePack(mangled).name, "晚风")
        XCTAssertThrowsError(try Skins.parsePack("-----BEGIN EIRA SKIN-----\nAAAA"))
    }

    func testInstallNeverOverwrites() throws {
        let p = try Skins.unpack(packJSON(#","late":true"#))
        let a = try Skins.install(p)
        let b = try Skins.install(p)
        XCTAssertEqual(a.string("name"), "晚风")
        XCTAssertEqual(b.string("name"), "晚风（2）")
        XCTAssertEqual(b.string("css"), p.css)
        XCTAssertEqual(b["late"]?.bool, true)
        XCTAssertEqual(b["scope"]?.array?.compactMap(\.string), ["chat", "shell"])
        XCTAssertNotNil(Skins.get(a.id))
    }
}
