import XCTest
import UIKit
@testable import Eira

/// 表情库与发表情。
final class StickerTests: StoreTestCase {
    private func png() -> Data { UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { _ in } }

    func testAddAndGroups() throws {
        let a = try Stickers.add(imageData: png(), name: "开心 笑", group: "")
        XCTAssertEqual(a.group, "默认")
        XCTAssertEqual(a.keywords, ["开心", "笑"])
        XCTAssertFalse(a.imageId.isEmpty)
        try Stickers.add(imageData: png(), name: "哭", group: "猫猫")
        var s = AppSettings(raw: [:])
        _ = Stickers.addGroup(&s, "空组")
        let items = try Stickers.all()
        XCTAssertEqual(Stickers.groups(items, settings: s), ["默认", "猫猫", "空组"])
        XCTAssertEqual(Stickers.groups(items, settings: s, onlyUsed: true), ["默认", "猫猫"])

        try Stickers.renameGroup(&s, from: "猫猫", to: "狗狗")
        XCTAssertEqual(try Stickers.all().filter { $0.group == "狗狗" }.count, 1)
        try Stickers.removeGroup(&s, "狗狗")
        XCTAssertEqual(try Stickers.all().filter { $0.group == "默认" }.count, 2)
        XCTAssertFalse(Stickers.groups(try Stickers.all(), settings: s).contains("狗狗"))
    }

    /// 发出去的样子与网页版一样：kind sticker、content [表情：名字]、stickerId；用过一次记一次。
    func testSendSticker() throws {
        try importFixture("data.json")
        let st = try Stickers.add(imageData: png(), name: "比心", group: "")
        let m = try ChatEngine.sendSticker(st, chatId: "chat_a")
        XCTAssertEqual(m.kind, "sticker")
        XCTAssertEqual(m.content, "[表情：比心]")
        XCTAssertEqual(m.row.string("stickerId"), st.id)
        XCTAssertEqual(try Stickers.all().first { $0.id == st.id }?.useCount, 1)
        // 进请求时是那一行文字
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        let b = try ChatPrompt.build(chat: chat, char: char, settings: .load())
        XCTAssertTrue(b.messages.last?.content.contains("[表情：比心]") == true)
    }
}
