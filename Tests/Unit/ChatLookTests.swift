import XCTest
@testable import Eira

/// 聊天背景与上下栏：字段照网页版 chat.look，缺的补默认值，按项合并，照搬到全部会话
final class ChatLookTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testDefaultsAndClamp() throws {
        var c = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertFalse(ChatLook.of(c).isSet)
        c.row["look"] = .object(["veil": .number(200), "top": .object(["style": .string("weird"), "color": .string("red"), "alpha": .number(-5)]),
                                 "narr": .string("#AABBCC")])
        let l = ChatLook.of(c)
        XCTAssertEqual(l.veil, 90)
        XCTAssertEqual(l.top.style, "solid")
        XCTAssertEqual(l.top.color, "")
        XCTAssertEqual(l.top.alpha, 0)
        XCTAssertEqual(l.bottom, l.top)
        XCTAssertEqual(l.narr, "#AABBCC")
    }

    func testSetMergesAndSplitCopiesTop() throws {
        try ChatLook.set("chat_a", ["top": .object(["style": .string("glass")])])
        try ChatLook.set("chat_a", ["top": .object(["color": .string("#1C1C1E")])])
        var l = ChatLook.of(try XCTUnwrap(Repo.chat("chat_a")))
        XCTAssertEqual(l.top.style, "glass")
        XCTAssertEqual(l.top.color, "#1C1C1E")
        try ChatLook.set("chat_a", ["split": .bool(true)])
        l = ChatLook.of(try XCTUnwrap(Repo.chat("chat_a")))
        XCTAssertTrue(l.split)
        XCTAssertEqual(l.bottom, l.top)
        try ChatLook.set("chat_a", ["bottom": .object(["style": .string("clear")])])
        l = ChatLook.of(try XCTUnwrap(Repo.chat("chat_a")))
        XCTAssertEqual(l.bottom.style, "clear")
        XCTAssertEqual(l.top.style, "glass")
    }

    func testApplyToAllAndReset() throws {
        let other = try GroupChat.create(memberIds: [try XCTUnwrap(Repo.characters().first).id, People.createCharacter(name: "周").id],
                                         title: "", personaId: "me_root")
        try ChatLook.setBg("chat_a", imageId: "img_a")
        XCTAssertGreaterThanOrEqual(try ChatLook.applyToAll("chat_a"), 1)
        XCTAssertEqual(ChatLook.of(try XCTUnwrap(Repo.chat(other.id))).bg, "img_a")
        try ChatLook.reset("chat_a")
        XCTAssertFalse(ChatLook.of(try XCTUnwrap(Repo.chat("chat_a"))).isSet)
    }
}

/// 只在这段会话里换头像：专用的优先，恢复后用回自己的那张
final class ChatFacesTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testSetAndClear() throws {
        XCTAssertEqual(ChatFaces.of(try Repo.chat("chat_a"), key: "char_a", fallback: "img_a"), "img_a")
        try ChatFaces.set("chat_a", key: "char_a", imageId: "img_new")
        try ChatFaces.set("chat_a", key: ChatFaces.me, imageId: "img_me")
        let c = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertEqual(ChatFaces.of(c, key: "char_a", fallback: "img_a"), "img_new")
        XCTAssertEqual(ChatFaces.of(c, key: ChatFaces.me, fallback: ""), "img_me")
        // 角色自己的头像不动
        XCTAssertEqual(try Repo.character("char_a")?.avatar, "img_a")
        XCTAssertTrue(try ChatFaces.clear("chat_a", key: "char_a"))
        XCTAssertFalse(try ChatFaces.clear("chat_a", key: "char_a"))
        XCTAssertEqual(ChatFaces.of(try Repo.chat("chat_a"), key: "char_a", fallback: "img_a"), "img_a")
    }
}
