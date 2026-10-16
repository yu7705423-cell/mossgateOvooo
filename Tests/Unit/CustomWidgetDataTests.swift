import XCTest
@testable import Eira

/// 自定义组件的占位符：认得的名字与 :N 参数；认不出的原样留着；填进去的文字一律转义；
/// 写了占位符就关掉外部图片与字体（除非这一格开了 allowRemote）；widget.data 里的 </script> 截不断桥；
/// 从库里取的最近一句、最近几句是对的。
final class CustomWidgetDataTests: StoreTestCase {
    private func cell(_ id: String, config: [String: JSONValue] = [:]) -> Shell.Cell {
        Shell.Cell(id: id, kind: "widget", ref: CustomWidget.id, x: 0, y: 0, w: 4, h: 2, name: "", apps: [],
                   label: "", coverIcon: "", coverImageId: "", config: config)
    }

    // MARK: - 读占位符

    func testParsesNamesAndParams() {
        let html = "<p>{{角色名}}</p><p>{{ 最近几句:3 }}</p><p>{{角色日记：40}}</p><p>{{角色名}}</p><p>{{不认识}}</p><p>{{}}</p>"
        let t = CustomWidget.tokens(html)
        XCTAssertEqual(t, [
            CustomWidget.Token(name: "角色名", arg: ""),
            CustomWidget.Token(name: "最近几句", arg: "3"),
            CustomWidget.Token(name: "角色日记", arg: "40"),
        ], "去重、按顺序、认不出的不算")
        XCTAssertEqual(t[1].key, "最近几句:3")
        XCTAssertEqual(t[2].key, "角色日记:40", "全角冒号也认")
        XCTAssertTrue(CustomWidget.tokens("<p>no placeholders</p>").isEmpty)
        XCTAssertEqual(CustomWidget.count("3", default: 5), 3)
        XCTAssertEqual(CustomWidget.count("", default: 5), 5)
        XCTAssertEqual(CustomWidget.count("0", default: 5), 1)
        XCTAssertEqual(CustomWidget.count("x", default: 5), 5)
    }

    func testFillEscapesAndLeavesUnknown() {
        let html = "<b>{{角色名}}</b><i>{{最近一句}}</i>{{不认识}}<s>{{签名}}</s><a title=\"{{最近几句:2}}\"></a>"
        let out = CustomWidget.fill(html, [
            "角色名": "<script>alert(1)</script>",
            "最近一句": "a & b 'c' \"d\" `e` \\f",
            "最近几句:2": "x\"><img src=y>",
        ])
        XCTAssertFalse(out.contains("<script>"), "值里的标签不生效")
        XCTAssertTrue(out.contains("<b>&lt;script&gt;alert(1)&lt;/script&gt;</b>"))
        XCTAssertTrue(out.contains("<i>a &amp; b &#39;c&#39; &quot;d&quot; &#96;e&#96; &#92;f</i>"))
        XCTAssertTrue(out.contains("{{不认识}}"), "认不出的原样留着")
        XCTAssertTrue(out.contains("<s></s>"), "没有值的填空串")
        XCTAssertTrue(out.contains("title=\"x&quot;&gt;&lt;img src=y&gt;\""), "属性里截不断")
        // 值里的占位符不再展开
        XCTAssertEqual(CustomWidget.fill("{{角色名}}", ["角色名": "{{签名}}"]), "{{签名}}")
        XCTAssertEqual(CustomWidget.recentText([
            CustomWidget.Line(who: "我", me: true, text: "a", time: 1),
            CustomWidget.Line(who: "阿青", me: false, text: "b", time: 2),
            CustomWidget.Line(who: "我", me: true, text: "c", time: 3),
        ], 2), "阿青：b\n我：c")
    }

    // MARK: - 盒子

    func testPlaceholdersTurnOffRemoteImages() {
        let vars = CustomWidget.themeVars(dark: false)
        let plain = CustomWidget.document("<p>x</p>", cell: cell("c1"), fit: "fit", vars: vars, scheme: "light")
        XCTAssertTrue(plain.contains("img-src data: blob: https:"), "没写占位符时照旧放开")

        let with = CustomWidget.document("<p>{{角色名}}</p>", cell: cell("c1"), fit: "fit", vars: vars, scheme: "light",
                                         filled: CustomWidget.Filled(text: ["角色名": "阿青"]))
        XCTAssertTrue(with.contains("img-src data: blob:;") || with.contains("img-src data: blob:\""), "写了占位符关掉外部图片")
        XCTAssertFalse(with.contains("https:"), "图片、字体、样式都不放开")
        XCTAssertTrue(with.contains("<p>阿青</p>"))

        let allowed = CustomWidget.document("<p>{{角色名}}</p>", cell: cell("c1", config: ["allowRemote": .bool(true)]), fit: "fit",
                                            vars: vars, scheme: "light")
        XCTAssertTrue(allowed.contains("img-src data: blob: https:"), "开了 allowRemote 照旧放开")
        XCTAssertTrue(allowed.contains("<p></p>"), "没算值时填空串")
    }

    func testWidgetDataEscapesScriptEnd() {
        let html = "<p>{{最近一句}}</p><p>{{最近几句:2}}</p>"
        let f = CustomWidget.Filled(text: ["最近一句": "</script><script>alert(1)</script>", "最近几句:2": "我：hi"],
                                    lines: [CustomWidget.Line(who: "我", me: true, text: "</script>", time: 5)])
        let doc = CustomWidget.document(html, cell: cell("c1"), fit: "fit", vars: "", scheme: "light", filled: f)
        XCTAssertEqual(doc.components(separatedBy: "</script>").count, 2, "只有桥自己的那一个 </script>")
        XCTAssertTrue(doc.contains("data:{"), "widget.data 交进去")
        XCTAssertTrue(doc.contains("\\u003c/script>") || doc.contains("\\u003c\\/script>"), "JSON 里的斜杠可能另被转义")

        let v = CustomWidget.dataValue(CustomWidget.tokens(html), f)
        XCTAssertEqual(v["最近一句"]?.string, "</script><script>alert(1)</script>")
        XCTAssertEqual(v["最近几句:2"]?.string, "我：hi")
        XCTAssertEqual(v["最近几句"]?.array?.count, 1, "最近几句另给一份数组")
        XCTAssertEqual(v["最近几句"]?[0]?["me"]?.bool, true)
        XCTAssertNil(v["角色名"], "只给写了的那几项")

        let none = CustomWidget.document("<p>x</p>", cell: cell("c1"), fit: "fit", vars: "", scheme: "light")
        XCTAssertTrue(none.contains("data:{}"), "没写占位符时为空对象")
    }

    // MARK: - 从库里取

    @MainActor
    func testResolvesRecentMessages() throws {
        let ch = Row.new(prefix: "char", ["name": .string("阿青"), "signature": .string("一句签名"), "persona": .string("人设正文")])
        try Database.shared.put(Collections.characters, ch)
        let chat = Chat(row: Row.new(prefix: "chat", ["characterIds": .array([.string(ch.id)])]))
        try Repo.save(chat)
        try Repo.append(Message.new(chatId: chat.id, role: .user, authorId: "me", content: "你好"))
        try Repo.append(Message.new(chatId: chat.id, role: .char, authorId: ch.id, content: "在的"))
        try Repo.append(Message.new(chatId: chat.id, role: .user, authorId: "me", content: "今天下雨"))
        try Repo.append(Message.new(chatId: chat.id, role: .char, authorId: ch.id, content: "<b>带伞</b>"))
        try Repo.append(Message.new(chatId: chat.id, role: .char, authorId: ch.id, content: "[图片：一把伞]"))

        let html = "{{角色名}}|{{签名}}|{{最近一句}}|{{最近几句:2}}|{{最近几句}}|{{未读}}|{{认识天数}}|{{角色头像}}|{{纪念日天数}}"
        let used = CustomWidget.tokens(html)
        let f = CustomWidget.resolve(used, charId: ch.id)
        XCTAssertEqual(f.text["角色名"], "阿青")
        XCTAssertEqual(f.text["签名"], "一句签名")
        XCTAssertEqual(f.text["最近一句"], "<b>带伞</b>", "方括号标记开头的跳过")
        XCTAssertEqual(f.text["最近几句:2"], "我：今天下雨\n阿青：<b>带伞</b>")
        XCTAssertEqual(f.text["最近几句"], "我：你好\n阿青：在的\n我：今天下雨\n阿青：<b>带伞</b>")
        XCTAssertEqual(f.text["未读"], "0")
        XCTAssertEqual(f.text["认识天数"], "1")
        XCTAssertEqual(f.text["角色头像"], "", "没有头像为空串")
        XCTAssertEqual(f.text["纪念日天数"], "")
        XCTAssertEqual(f.lines.count, 4, "数组按写了的最大条数取")
        XCTAssertEqual(f.lines.last?.me, false)
        XCTAssertEqual(f.lines.first?.who, "我")
        XCTAssertFalse(f.text.values.contains { $0.contains("人设正文") }, "人设不交进去")

        // 跟随最近聊过的角色
        let follow = CustomWidget.resolve([CustomWidget.Token(name: "角色名", arg: "")], charId: "")
        XCTAssertEqual(follow.text["角色名"], "阿青")

        let page = CustomWidget.fill(html, f.text)
        XCTAssertTrue(page.contains("&lt;b&gt;带伞&lt;/b&gt;"))
        XCTAssertFalse(page.contains("<b>"))
    }
}
