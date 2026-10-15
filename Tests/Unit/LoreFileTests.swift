import XCTest
@testable import Eira

/// 世界书的文本写法（网页版 lorefile.js）：导出再导回来每一条的设置原样还原；别处来的文字按 ## 切，没有就整篇一条且常驻
final class LoreFileTests: StoreTestCase {
    func testPlainTextBecomesOneConstantEntry() {
        let d = LoreFile.fromText("这是一段设定。\n第二行。", name: "设定集")
        XCTAssertEqual(d.name, "设定集")
        XCTAssertEqual(d.entries.count, 1)
        XCTAssertEqual(d.entries[0]["constant"]?.bool, true)
        XCTAssertFalse(d.own)
        XCTAssertTrue(LoreFile.Options(d).constant)
    }

    func testRoundTrip() throws {
        let text = """
        # 城市
        用途：生图
        全局生效：是

        ## 茶馆
        关键词：茶、茶馆
        常驻：否
        启用：是
        位置：角色后
        深度：2

        城南的茶馆。

        ## 河
        城外的河。
        """
        let d = LoreFile.fromText(text, name: "文件名")
        XCTAssertEqual(d.name, "城市")
        XCTAssertEqual(d.purpose, "image")
        XCTAssertTrue(d.global)
        XCTAssertTrue(d.own)
        XCTAssertEqual(d.entries.count, 2)
        XCTAssertEqual(d.entries[0]["keys"]?.array?.compactMap(\.string), ["茶", "茶馆"])
        XCTAssertEqual(d.entries[0]["part"]?.string, "after")
        XCTAssertEqual(d.entries[0]["depth"]?.number, 2)
        XCTAssertEqual(d.entries[0]["content"]?.string, "城南的茶馆。")
        XCTAssertEqual(d.entries[1]["content"]?.string, "城外的河。")

        let book = try LoreFile.save(d, LoreFile.Options(d))
        let row = try XCTUnwrap(Database.shared.get(Collections.lorebooks, id: book.id))
        XCTAssertEqual(row.bool("forImage"), true)
        XCTAssertEqual(row.bool("global"), true)
        let back = LoreFile.fromText(LoreFile.toText(row))
        XCTAssertEqual(back.name, "城市")
        XCTAssertEqual(back.purpose, "image")
        XCTAssertEqual(back.entries.map { $0["comment"]?.string }, ["茶馆", "河"])
        XCTAssertEqual(back.entries[0]["part"]?.string, "after")
        XCTAssertEqual(back.entries[0]["keys"]?.array?.compactMap(\.string), ["茶", "茶馆"])

        // 不保留文件里的设置：整本照确认页上的
        var o = LoreFile.Options(d)
        o.keepOwn = false; o.constant = true; o.part = "before"; o.depth = 0
        let flat = try LoreFile.save(d, o)
        let r2 = try XCTUnwrap(Database.shared.get(Collections.lorebooks, id: flat.id))
        XCTAssertTrue((r2["entries"]?.array ?? []).allSatisfy { $0["constant"]?.bool == true && $0["part"]?.string == "before" })
    }

    func testExportZip() throws {
        let e: JSONValue = .object(["comment": .string("一条"), "content": .string("正文")])
        let a = Row.new(prefix: "lb", ["name": .string("甲"), "entries": .array([e])])
        let b = Row.new(prefix: "lb", ["name": .string("甲"), "entries": .array([e])])
        let url = try LoreFile.exportFile([a, b])
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".zip"))
        // 同名的两本装进一个 zip，读回来还是两本
        let r = LoreFile.readFiles([url])
        XCTAssertEqual(r.drafts.map(\.name), ["甲", "甲"])
        XCTAssertEqual(r.drafts.first?.entries.first?["content"]?.string, "正文")
    }
}
