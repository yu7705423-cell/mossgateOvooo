import XCTest
@testable import Eira

/// 正则替换（网页版 regex.js）。
final class RegexRulesTests: StoreTestCase {
    private func rule(_ f: [String: JSONValue]) -> RegexRules.Rule {
        var j = RegexRules.blank(name: "r")
        j.merge(f) { _, n in n }
        return RegexRules.Rule(json: j)
    }

    func testApply() {
        // 普通文字：$ 原样写出
        XCTAssertEqual(RegexRules.apply(rule(["find": .string("a.b"), "replace": .string("$1")]), "xa.by axb"), "x$1y axb")
        // 正则：分组引用、$& 是整段
        XCTAssertEqual(RegexRules.apply(rule(["find": .string("(\\d+)元"), "regex": .bool(true), "replace": .string("$1块")]), "10元"), "10块")
        XCTAssertEqual(RegexRules.apply(rule(["find": .string("猫"), "regex": .bool(true), "replace": .string("[$&]")]), "小猫"), "小[猫]")
        // 不区分大小写
        XCTAssertEqual(RegexRules.apply(rule(["find": .string("hi"), "caseSensitive": .bool(false), "replace": .string("嗨")]), "Hi"), "嗨")
        // 写错的正则不套
        let bad = rule(["find": .string("(("), "regex": .bool(true), "replace": .string("x")])
        XCTAssertFalse(RegexRules.compile(bad).1.isEmpty)
        XCTAssertEqual(RegexRules.apply(bad, "(("), "((")
    }

    /// 只改显示：发给角色的是原文；只改发给角色的：显示原文。作用于谁、适用的角色。
    func testSides() {
        let c = RegexRules.Context(who: "char", whereIs: "online", charIds: ["char_a"])
        let s = AppSettings(raw: ["regexRules": .array([
            .object(rule(["find": .string("A"), "replace": .string("1"), "mode": .string("display")]).json),
            .object(rule(["find": .string("B"), "replace": .string("2"), "mode": .string("prompt")]).json),
            .object(rule(["find": .string("C"), "replace": .string("3"), "mode": .string("both"), "who": .array([.string("user")])]).json),
            .object(rule(["find": .string("D"), "replace": .string("4"), "mode": .string("both"), "charIds": .array([.string("char_x")])]).json),
            .object(rule(["find": .string("E"), "replace": .string("5"), "mode": .string("both"), "on": .bool(false)]).json),
        ])])
        XCTAssertEqual(RegexRules.forDisplay("ABCDE", c, settings: s), "1BCDE")
        XCTAssertEqual(RegexRules.forPrompt("ABCDE", c, settings: s), "A2CDE")
        XCTAssertEqual(RegexRules.forPrompt("ABCDE", .init(who: "user", whereIs: "online", charIds: ["char_x"]), settings: s), "A234E")
    }

    /// 组装请求时套「发给角色的」那一份，库里的原文不动。
    func testAppliedInPrompt() throws {
        try importFixture("data.json")
        try setSettings(["regexRules": .array([.object(rule(["find": .string("你好"), "replace": .string("HELLO_SWAPPED"), "mode": .string("prompt")]).json)])])
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        let b = try ChatPrompt.build(chat: chat, char: char, settings: .load())
        XCTAssertTrue(b.messages.contains { $0.content.contains("HELLO_SWAPPED") })
        XCTAssertTrue(try Repo.messages(chatId: "chat_a").contains { $0.content == "你好" })
    }
}
