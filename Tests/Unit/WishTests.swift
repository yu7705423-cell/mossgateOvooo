import XCTest
@testable import Eira

/// 心愿（网页版 wish.js、context/wishes.js、tasks/wish-judge.js）：标记的切分与落库、私下心愿不落进聊天、重新生成那一轮撤回、
/// 你没公开的心愿不进提示词、判定只认交出去的那几条。
final class WishTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    private func chat() throws -> Chat { try XCTUnwrap(Repo.chat("chat_a")) }
    private func char() throws -> Character { try XCTUnwrap(Repo.character("char_a")) }

    func testParserAndWebMapAgree() {
        let p = ReplyParser.split("[心愿：去海边看日出|一起去]\n好啊\n[私下心愿：学会做饭]\n[心愿达成：日出]").parts
        XCTAssertEqual(p.map(\.type), [.wish, .text, .wish, .wishDone])
        XCTAssertEqual(p[0].text, "去海边看日出|一起去")
        XCTAssertTrue(p[0].flag)
        XCTAssertFalse(p[2].flag)
        XCTAssertEqual(p[3].text, "日出")
        let (parts, unmapped) = WebLogic.map([
            ["type": "wish", "body": "去海边看日出|一起去", "shown": true],
            ["type": "text", "text": "好啊"],
            ["type": "wish", "body": "学会做饭", "shown": false],
            ["type": "wishdone", "body": "日出"],
        ])
        XCTAssertEqual(unmapped, [])
        XCTAssertEqual(parts, p)
    }

    func testCharWritesAndFulfils() throws {
        var pub = ReplyParser.Part(type: .wish, text: "去海边看日出｜一起去")
        pub.flag = true
        let m = try XCTUnwrap(Wish.effect(pub, chat: chat(), char: char(), turnId: "t1"))
        XCTAssertEqual(m.content, "[林写下了一个心愿：去海边看日出]")
        XCTAssertEqual(m.kind, "notice")
        let w = try XCTUnwrap(Wish.ownOf("char_a").first)
        XCTAssertEqual(w.cond, "一起去")
        XCTAssertTrue(w.row.id.hasPrefix("ws_"))
        XCTAssertEqual(w.row.string("turnId"), "t1")
        // 同一句未达成的不再记一遍
        XCTAssertNil(try Wish.effect(pub, chat: chat(), char: char(), turnId: "t1"))
        // 私下的：记下，但聊天里一个字都不落，你这边也看不见
        var hidden = ReplyParser.Part(type: .wish, text: "学会做饭")
        hidden.flag = false
        XCTAssertNil(try Wish.effect(hidden, chat: chat(), char: char(), turnId: "t1"))
        XCTAssertEqual(Wish.ownOf("char_a").count, 2)
        XCTAssertEqual(Wish.charsSeen("char_a").map(\.text), ["去海边看日出"])
        // 达成：给一小段原话认自己的那一条
        let done = try XCTUnwrap(Wish.effect(ReplyParser.Part(type: .wishDone, text: "做饭"), chat: chat(), char: char(), turnId: "t2"))
        XCTAssertEqual(done.content, "[林的心愿已达成：学会做饭]")
        let cook = try XCTUnwrap(Wish.ownOf("char_a").first { $0.text == "学会做饭" })
        XCTAssertTrue(cook.isDone)
        XCTAssertEqual(cook.doneBy, "char")
        // 达成之后私下心愿也看得见
        XCTAssertEqual(Wish.charsSeen("char_a").count, 2)
        // 认不出就不动
        XCTAssertNil(try Wish.effect(ReplyParser.Part(type: .wishDone, text: "登月"), chat: chat(), char: char(), turnId: "t2"))
        // 重新生成：t2 那一轮的达成退回去；t1 那一轮写下的删掉
        try Wish.undoTurn(chatId: "chat_a", turnId: "t2")
        XCTAssertFalse(try XCTUnwrap(Wish.get(cook.id)).isDone)
        try Wish.undoTurn(chatId: "chat_a", turnId: "t1")
        XCTAssertTrue(Wish.ownOf("char_a").isEmpty)
    }

    func testCapsOffSkipsMark() throws {
        try setSettings(["capsOff": .array([.string("wish")])])
        var pub = ReplyParser.Part(type: .wish, text: "去海边")
        pub.flag = true
        XCTAssertNil(try Wish.effect(pub, chat: chat(), char: char(), turnId: "t1"))
        XCTAssertTrue(Wish.ownOf("char_a").isEmpty)
    }

    func testBlockKeepsYourHiddenWishesOut() throws {
        try Wish.addMine(text: "SHOWN_WISH", charId: "char_a", shown: true)
        try Wish.addMine(text: "HIDDEN_WISH", shown: false)
        _ = try Wish.charWrite(charId: "char_a", chatId: "chat_a", body: "OWN_SECRET", shown: false)
        let b = try ChatPrompt.build(chat: chat(), char: char(), settings: .load())
        let all = b.system + b.messages.map(\.content).joined()
        XCTAssertTrue(all.contains("[心愿]"))
        XCTAssertTrue(all.contains("- SHOWN_WISH"))
        XCTAssertTrue(all.contains("- OWN_SECRET [hidden]"))
        XCTAssertFalse(all.contains("HIDDEN_WISH"))
        // 写法在能力里
        XCTAssertTrue(b.system.contains("[私下心愿："))
        // 判定清单里两边都有，你隐藏的也在（判定的是总结模型）
        let list = Wish.listText(Wish.openFor("chat_a"))
        XCTAssertTrue(list.contains("HIDDEN_WISH"))
        XCTAssertTrue(list.contains("owner: 林 | wish: OWN_SECRET"))
    }

    func testApplyJudgedOnlyTrustsSentIds() throws {
        let w = try Wish.addMine(text: "一起看雪")
        let sent = Wish.openFor("chat_a")
        let n = Wish.applyJudged(.array([.string("ws_made_up"), .object(["id": .string(w.id), "note": .string("下雪了")])]), sent: sent, by: "summary")
        XCTAssertEqual(n, 1)
        let got = try XCTUnwrap(Wish.get(w.id))
        XCTAssertTrue(got.isDone)
        XCTAssertEqual(got.doneBy, "summary")
        XCTAssertEqual(got.doneNote, "下雪了")
    }

    func testDeleteCharacter() throws {
        try Wish.addMine(text: "和林去看海", charId: "char_a", shown: true)
        _ = try Wish.charWrite(charId: "char_a", chatId: "chat_a", body: "学吉他", shown: true)
        try People.deleteCharacter("char_a")
        XCTAssertTrue(Wish.ownOf("char_a").isEmpty)
        XCTAssertEqual(Wish.mine().first?.charId, "")
    }
}
