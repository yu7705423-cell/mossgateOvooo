import XCTest
@testable import Eira

/// 美化 app（docs/jscore-skin.md）：网页版 skin-gen.js 在 JavaScriptCore 里编出来的与网页版原文件编的逐字相同；
/// 最终生效的 CSS 的先后（令牌、头像框、生成器、手写、late 那一段）与原生读出来的结果；包不在时退回原生的几项；
/// 美化包的 TXT、DOCX、JSON 来回；首页的文件夹
final class SkinGenTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
        SkinGen.forceMissing = false
    }

    override func tearDownWithError() throws {
        SkinGen.forceMissing = false
        try super.tearDownWithError()
    }

    private func requireBundle() throws {
        try XCTSkipUnless(SkinGen.bundled, "没有 skin.bundle.js（没有 WEB_REPO_TOKEN 的编译）")
        XCTAssertTrue(SkinGen.shared.available, SkinGen.shared.lastError ?? "")
    }

    private func put(_ fields: [String: JSONValue]) throws -> Row {
        let r = Row.new(prefix: "sk", fields)
        try Database.shared.put(Skins.collection, r)
        return r
    }

    private func json(_ name: String) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: fixture(name)))
    }

    // MARK: - 与网页版逐字相同

    func testEmitMatchesWebForFixtures() throws {
        try requireBundle()
        let expURL = fixture("skingen-expected.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: expURL.path), "没有 skingen-expected.json")
        let cases = try XCTUnwrap(json("skingen-cases.json")["cases"]?.array)
        let expected = try XCTUnwrap(JSONValue.parse(Data(contentsOf: expURL))["cases"]?.array)
        XCTAssertEqual(cases.count, expected.count)
        for (c, e) in zip(cases, expected) {
            let name = c["name"]?.string ?? ""
            XCTAssertEqual(SkinGen.shared.emit(c["gen"]), e["css"]?.string, name)
        }
        print("[weblogic] 美化生成器 网页版 \(SkinGen.shared.webCommit ?? "?")")
    }

    func testGroupsAndState() throws {
        try requireBundle()
        let groups = try XCTUnwrap(SkinGen.shared.groups())
        let bubble = try XCTUnwrap(groups.first { $0.id == "bubble" })
        XCTAssertEqual(bubble.items.first { $0.id == "bg" }?.type, "color")
        XCTAssertEqual(bubble.items.first { $0.id == "side" }?.options.map(\.id), ["all", "theirs", "mine"])
        // 每一组最后都有「这一块的 CSS」，收在更多里
        XCTAssertTrue(groups.allSatisfy { $0.items.last?.id == "css" && $0.items.last?.more == true })

        // 有显示条件的那几项：前面一项设了之后才出现
        let none = try XCTUnwrap(SkinGen.shared.state(.object([:])))
        XCTAssertFalse(none.shows("bubble", "imgFill"))
        XCTAssertFalse(none.touched)
        let some = try XCTUnwrap(SkinGen.shared.state(.object(["bubble": .object(["img": .string("https://a.example/x.png"), "r": .number(4)])])))
        XCTAssertTrue(some.shows("bubble", "imgFill"))
        XCTAssertEqual(some.changed["bubble"], 2)
        XCTAssertEqual(some.links, 1)
        XCTAssertEqual(some.value("bubble", "r"), .number(4))
        // 没设的项是默认值
        XCTAssertEqual(some.value("bubble", "side"), .string("all"))
    }

    // MARK: - 最终生效的 CSS

    func testEffectiveCssOrderAndLate() throws {
        try requireBundle()
        let gen: JSONValue = .object(["bubble": .object(["r": .number(9)])])
        let r = try put(["tokens": .object(["bubbleR": .number(20), "navH": .number(50.4)]), "shape": .string("round"),
                         "gen": gen, "css": .string(".ph-chat .ph-msg .ph-bubble { border-radius: 2px !important; }")])
        let css = Skins.effectiveCss(r)
        XCTAssertTrue(css.hasPrefix(":root{--ph-navbar-h:50px;--ph-bubble-r:20px;--ph-avatar-r:50%}"), css)
        let made = try XCTUnwrap(SkinGen.shared.emit(gen))
        let at = { (s: String) in css.range(of: s)?.lowerBound }
        XCTAssertLessThan(try XCTUnwrap(at(made)), try XCTUnwrap(at(".ph-chat .ph-msg")))
        XCTAssertFalse(css.contains(":not(#skin-late)"))
        // 手写 CSS 在后：手写的 !important 选择器更具体，盖过生成器
        XCTAssertEqual(Skins.compiled(r)?.resolve(["bubble"])?.radius, 2)

        // 之后又动了生成器：late，生成器那一段再写一遍、加重选择器，原生读出来是生成器的
        try Skins.setGen(r.id, "bubble", "r", .number(9))
        let late = try XCTUnwrap(Skins.get(r.id))
        XCTAssertEqual(late["late"]?.bool, true)
        let lateCss = Skins.effectiveCss(late)
        XCTAssertTrue(lateCss.contains(":root:root{--ph-navbar-h:50px"), lateCss)
        XCTAssertTrue(lateCss.contains(":not(#skin-late) .ph-bubble {"), lateCss)
        XCTAssertEqual(Skins.compiled(late)?.resolve(["bubble"])?.radius, 9)

        // 再改手写 CSS：late 清掉
        try Skins.setCss(r.id, ".ph-bubble { color: #111111; }")
        XCTAssertEqual(Skins.get(r.id)?["late"]?.bool, false)
    }

    func testFrameCss() throws {
        let png = "data:image/png;base64,AAAA"
        let r = try put(["frame": .string(png), "frameWho": .string("mine"), "frameScale": .number(999)])
        let css = Skins.frameCss(r)
        XCTAssertTrue(css.hasPrefix(".msg.is-mine .msg-face{position:relative}"))
        XCTAssertTrue(css.contains("width:300%;height:300%"))
        XCTAssertTrue(css.contains("url(\"\(png)\")"))
        XCTAssertEqual(Skins.frameCss(try put(["frame": .string("javascript:1")])), "")
    }

    func testMissingBundleFallsBackToNative() throws {
        SkinGen.forceMissing = true
        XCTAssertFalse(SkinGen.shared.available)
        XCTAssertNil(SkinGen.shared.emit(.object(["bubble": .object(["bg": .string("#112233")])])))
        let r = try put(["tokens": .object(["gap": .number(24)]), "css": .string(".ph-bubble{color:#fff}"),
                         "gen": .object(["bubble": .object(["bg": .string("#112233"), "r": .number(6)])])])
        // 生成器那一段是空的，其余照旧
        XCTAssertEqual(Skins.effectiveCss(r), ":root{--ph-bubble-gap:24px}\n.ph-bubble{color:#fff}")
        // 原生认得的几项照旧直接读
        let l = Skins.look(r, css: Skins.compiled(r))
        XCTAssertEqual(l.theirs.bg, "#112233")
        XCTAssertEqual(l.theirs.radius, 6)
        XCTAssertEqual(l.gap, 24)
        // 设置原样留着
        try Skins.setToken(r.id, "gap", 20)
        XCTAssertEqual(Skins.get(r.id)?["gen"]?["bubble"]?["r"], .number(6))
    }

    // MARK: - 美化包来回

    func testPackRoundTripTxtDocxJson() throws {
        let r = try ChatTheme.create(name: "晚风")
        try ChatTheme.set(r.id, "mine.fill", .string("#5c5c5c"))
        try Skins.update(r.id) { row in
            row["gen"] = .object(["bubble": .object(["bg": .string("#EEEEEE"), "r": .number(8)]), "anim": .object(["kind": .string("rise")])])
            row["tokens"] = .object(["bubbleR": .number(12), "navH": .number(52)])
            row["css"] = .string(".ph-bubble { color: #222222; }")
            row["scope"] = .array([.string("chat"), .string("shell")])
            row["late"] = .bool(true)
        }
        let row = try XCTUnwrap(Skins.get(r.id))
        XCTAssertEqual(SkinFile.signed("晚风", "阿岚"), "晚风 by 阿岚")
        XCTAssertEqual(SkinFile.signed("晚风 by 阿岚", "阿岚"), "晚风 by 阿岚")
        XCTAssertEqual(SkinFile.signed("晚风", ""), "晚风")

        let text = try SkinFile.toText(row, who: "阿岚")
        XCTAssertTrue(text.hasPrefix("Eira 美化包：晚风 by 阿岚\n作者：阿岚\n"))
        XCTAssertTrue(text.contains(SkinFile.begin) && text.contains(SkinFile.end))
        // 每行不超过 76 个字符
        let body = text.components(separatedBy: SkinFile.begin)[1].components(separatedBy: SkinFile.end)[0]
        XCTAssertTrue(body.components(separatedBy: "\n").allSatisfy { $0.count <= 76 })

        func check(_ p: Skins.Pack) {
            XCTAssertEqual(p.name, "晚风 by 阿岚")
            XCTAssertEqual(p.author, "阿岚")
            XCTAssertEqual(JSONValue.object(p.gen), row["gen"])
            XCTAssertEqual(p.tokens["bubbleR"], .number(12))
            XCTAssertEqual(p.tokens["navH"], .number(52))
            XCTAssertEqual(p.css, row.string("css"))
            XCTAssertEqual(p.scope, ["chat", "shell"])
            XCTAssertTrue(p.late)
            XCTAssertEqual(p.native?["mine"]?["fill"]?.string, "#5C5C5C")
        }
        // 经聊天软件转手：前后多了字、base64 被折成几行、多出空格
        let mangled = "转发：\n" + text.replacingOccurrences(of: "\n", with: "\n  ") + "\n以上"
        check(try Skins.parsePack(mangled))
        for f in SkinFile.Format.allCases {
            let url = try SkinFile.export(row, format: f, who: "阿岚")
            XCTAssertEqual(url.pathExtension, f.rawValue)
            XCTAssertTrue(url.lastPathComponent.hasPrefix("美化-晚风 by 阿岚"))
            check(try Skins.parsePack(DocText.read(url)))
        }
        // 装回来是新的一份，不覆盖
        let back = try Skins.install(try Skins.parsePack(text))
        XCTAssertNotEqual(back.id, row.id)
        XCTAssertEqual(back["gen"], row["gen"])
        XCTAssertEqual(back["late"]?.bool, true)
        // 作者名记在设置里
        try SkinFile.setAuthor(" 阿岚 ")
        XCTAssertEqual(SkinFile.author(), "阿岚")
    }

    // MARK: - 首页的文件夹

    func testFoldersListUsingFirst() throws {
        let used = try ChatTheme.create(name: "挂着的")
        let idle = try ChatTheme.create(name: "没挂的")
        try Skins.attach("chat_a", used.id)
        try ChatTheme.setGlobal("builtin-paper")
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        chat.row["statusBar"] = .object(["offline": .object(["css": .string(".ph-status { color: #333333; }")])])
        try Repo.save(chat)
        var s = try AppSettings.loadForWrite()
        s.raw["stage"] = .object(["css": .string(".ph-stage { color: #444444; }")])
        try s.save()

        let cats = SkinPlaces.categories()
        XCTAssertEqual(cats.map(\.id), ["chat", "app", "status", "inner", "stage", "card", "widget"])
        let chatCat = try XCTUnwrap(cats.first { $0.id == "chat" })
        XCTAssertEqual(Set(chatCat.using.map(\.key)), [used.id, "builtin-paper"])
        XCTAssertTrue(chatCat.rest.contains { $0.key == idle.id })
        XCTAssertTrue(chatCat.rest.contains { $0.key == "builtin-graphite" })
        XCTAssertEqual(chatCat.items.first?.on, true)
        XCTAssertEqual(chatCat.items.first { $0.key == used.id }?.sub, "用于 1 段会话")
        XCTAssertEqual(chatCat.items.first { $0.key == idle.id }?.go, .skin(idle.id))
        let app = try XCTUnwrap(cats.first { $0.id == "app" })
        XCTAssertEqual(app.using.first?.title, "纸白")
        XCTAssertEqual(app.go, .global)
        let status = try XCTUnwrap(cats.first { $0.id == "status" })
        XCTAssertEqual(status.using.first?.sub, "线下")
        XCTAssertEqual(status.using.first?.go, .status("chat_a"))
        XCTAssertEqual(status.using.first?.preview, .code(".ph-status { color: #333333; }"))
        XCTAssertEqual(cats.first { $0.id == "stage" }?.using.first?.go, .stage(nil))

        // 总开关关着：默认主题不算「正在使用」
        try setSettings(["skinOff": .bool(true)])
        let off = SkinPlaces.categories(settings: .load())
        XCTAssertTrue(off.first { $0.id == "app" }?.using.isEmpty ?? false)
        XCTAssertFalse(off.first { $0.id == "chat" }?.using.contains { $0.key == "builtin-paper" } ?? true)
    }
}
