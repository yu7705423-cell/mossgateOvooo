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
        XCTAssertEqual(Skins.skipped(r), ["自定义 CSS"])
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
        XCTAssertEqual(Set(Skins.skipped(after)), ["自定义 CSS", "头像框", "生成器的其他样式"])
        try Skins.setToken(r.id, "bubbleR", nil)
        XCTAssertNil(Skins.token(try XCTUnwrap(Skins.get(r.id)), "bubbleR"))
    }
}
