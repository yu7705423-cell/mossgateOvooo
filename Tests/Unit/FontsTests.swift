import XCTest
@testable import Eira

/// 自定义字体：认得网页版的几种记录；删掉正在用的那一款，那一槽回到默认；解析不出字体的文件不存
final class FontsTests: StoreTestCase {
    func testWebRecordsAndRemove() throws {
        try setSettings(["fonts": .array([
            .object(["id": .string("fnt-a"), "name": .string("霞鹜文楷"), "fileId": .string("f_1"), "bytes": .number(2048)]),
            .object(["id": .string("fnt-b"), "name": .string("在线"), "source": .string("https://x.test/a.ttf")]),
            .object(["id": .string("fnt-c"), "name": .string("谷歌"), "css": .string("https://fonts.googleapis.com/css2?family=X"), "family": .string("X")]),
        ]), "fontBody": .string("fnt-a"), "fontSerif": .string("fnt-b")])
        let list = Fonts.list(.load())
        XCTAssertEqual(list.map(\.id), ["fnt-a", "fnt-b", "fnt-c"])
        XCTAssertEqual(list[1].url, "https://x.test/a.ttf", "旧记录叫 source")
        XCTAssertEqual(list[2].css.isEmpty, false)

        try Fonts.remove("fnt-a")
        let s = AppSettings.load()
        XCTAssertEqual(Fonts.list(s).map(\.id), ["fnt-b", "fnt-c"])
        XCTAssertNil(s.raw["fontBody"]?.string)
        XCTAssertEqual(s.raw["fontSerif"]?.string, "fnt-b")
    }

    func testBadFileNotStored() throws {
        XCTAssertThrowsError(try Fonts.add(Data("not a font".utf8), name: "x.ttf"))
        XCTAssertTrue(Fonts.list(.load()).isEmpty)
    }
}
