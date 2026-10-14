import XCTest
@testable import Eira

/// 相册：新建、存图（记下来自谁）、移动、设封面、删相册时照片退回未归类、从相册移除不动会话里那一条
final class AlbumTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testAlbumFlow() throws {
        let a = try Album.createAlbum("  旅行  ")
        XCTAssertEqual(a.string("name"), "旅行")
        XCTAssertThrowsError(try Album.createAlbum("   "))
        let m = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.kind == "image" })
        let p = try Album.saveFrom(m, name: "林")
        let photo = try XCTUnwrap(Album.photo(p.id))
        XCTAssertEqual(photo.imageId, m.imageId)
        XCTAssertEqual(photo.fromName, "林")
        XCTAssertEqual(Album.listPhotos("").count, 1)
        try Album.move(p.id, to: a.id)
        try Album.setCover(a.id, p.id)
        XCTAssertEqual(Album.listPhotos(a.id).map(\.id), [p.id])
        XCTAssertEqual(Album.coverImage(try XCTUnwrap(Album.album(a.id))), m.imageId)
        try Album.removeAlbum(a.id)
        XCTAssertNil(Album.album(a.id))
        XCTAssertEqual(Album.photo(p.id)?.albumId, "")
        try Album.removePhoto(p.id)
        XCTAssertNil(Album.photo(p.id))
        // 会话里那一条还在，图片也还在
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").first { $0.id == m.id }?.imageId, m.imageId)
    }

    func testStickerSavesItsImage() throws {
        var m = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "[表情：开心]", kind: "sticker")
        m.row["stickerId"] = .string("stk_1")
        let p = try Album.saveFrom(m, name: "林")
        XCTAssertEqual(Album.photo(p.id)?.imageId, "img_a")
    }

    func testCardLines() throws {
        let r = Row.new(prefix: "ph", ["albumId": .string(""), "kind": .string("card"), "title": .string("那天"),
                                        "msgs": .array([.object(["role": .string("user"), "content": .string("在吗"), "_name": .string("我")]),
                                                        .object(["role": .string("char"), "content": .string("在"), "_name": .string("林")])])])
        try Database.shared.put(Album.photos, r)
        let p = try XCTUnwrap(Album.photo(r.id))
        XCTAssertEqual(p.cardLines.map(\.text), ["在吗", "在"])
        XCTAssertTrue(p.cardLines[0].mine)
    }
}
