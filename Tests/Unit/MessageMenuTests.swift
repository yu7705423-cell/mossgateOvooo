import XCTest
@testable import Eira

/// 长按菜单里不调接口的那几件：记住这句、收进示例、生成信息。
final class MessageMenuTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testRememberMakesManualMemory() throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        let m = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.role == .char && $0.kind == "text" })
        let r = try MessageActions.remember(m, chat: chat, char: char)
        let mem = try XCTUnwrap(Database.shared.get(Collections.memories, id: r.memoryId))
        XCTAssertEqual(r.charId, "char_a")
        XCTAssertEqual(mem.string("rank"), "A")
        XCTAssertEqual(mem.string("source"), "manual")
        XCTAssertTrue(mem.string("content").hasSuffix("说：\(m.content)"))
        let mine = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.role == .user })
        XCTAssertTrue(try XCTUnwrap(Database.shared.get(Collections.memories, id: MessageActions.remember(mine, chat: chat, char: char).memoryId))
            .string("content").hasPrefix("我说："))
    }

    func testAddExampleOnce() throws {
        let m = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.role == .char && $0.kind == "text" })
        XCTAssertTrue(try MessageActions.addExample(m))
        XCTAssertFalse(try MessageActions.addExample(m))
        XCTAssertTrue(try XCTUnwrap(Repo.character("char_a")).row.string("exampleDialogue").contains("：\(m.content)"))
    }

    func testServedText() throws {
        var m = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "嗯", turnId: "turn_x")
        m.row["served"] = .array([.object(["name": .string("主用"), "model": .string("model-a"), "at": .number(Date().millis)])])
        m.row["swipeIndex"] = .number(0)
        m = try Repo.append(m)
        XCTAssertTrue(try MessageActions.servedText(m).hasPrefix("由「主用」的 model-a 生成"))
        let bare = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "嗯"))
        XCTAssertEqual(try MessageActions.servedText(bare), "这一条生成时尚未记录模型")
    }
}

/// 编辑图片描述、语音文字、旁白；改译文；单条翻译只送这一句
final class MessageEditTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testEditImageAndVoice() throws {
        var img = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "[图片：海边]", kind: "image")
        img.row["prompt"] = .string("海边")
        img = try Repo.append(img)
        XCTAssertEqual(MessageActions.editableText(img), "海边")
        XCTAssertTrue(MessageActions.needsRegen(img))
        let e = try MessageActions.edit(img, text: "雪山")
        XCTAssertEqual(e.row.string("prompt"), "雪山")
        XCTAssertEqual(e.content, "[图片：雪山]")

        var mine = Message.new(chatId: "chat_a", role: .user, authorId: "", content: "[语音：你好]", kind: "voice")
        mine.row["voiceText"] = .string("你好")
        mine.row["tone"] = .string("很轻")
        mine = try Repo.append(mine)
        XCTAssertFalse(MessageActions.needsRegen(mine))
        let v = try MessageActions.edit(mine, text: "晚安")
        XCTAssertEqual(v.content, "[语音：晚安]（听起来很轻）")
        XCTAssertEqual(v.row.string("asr"), "done")

        let n = try MessageActions.edit(try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "[旁白：风停了]", kind: "narration")), text: "雨停了]")
        XCTAssertEqual(n.row.string("narration"), "雨停了")
        XCTAssertEqual(n.content, "[旁白：雨停了]")
        XCTAssertThrowsError(try MessageActions.edit(n, text: "  "))
    }

    func testSetTranslation() throws {
        let m = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "Hello"))
        XCTAssertEqual(try MessageActions.setTranslation(m, " 你好 ").row.string("translation"), "你好")
        XCTAssertNil(try MessageActions.setTranslation(m, "").row["translation"])
    }

    func testTranslatePayloadAndRows() {
        let s = AppSettings.load()
        let p = TranslateOne.payload(["Hi\nthere"], lang: "中文", extra: "keep names", settings: s)
        XCTAssertEqual(p.user, "1. Hi there")
        XCTAssertTrue(p.system.contains("keep names"))
        XCTAssertFalse(p.system.contains("{{"))
        XCTAssertEqual(TranslateOne.rows(#"{"lines":["1. 你好"]}"#, want: 1), ["你好"])
        XCTAssertEqual(TranslateOne.rows("你好", want: 1), ["你好"])
        XCTAssertEqual(TranslateOne.rows(#"["a","b"]"#, want: 2), ["a", "b"])
        let mine = Message.new(chatId: "chat_a", role: .user, authorId: "", content: "hi")
        XCTAssertFalse(TranslateOne.can(mine, lang: "中文"))
        let theirs = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "hi")
        XCTAssertFalse(TranslateOne.can(theirs, lang: ""))
        XCTAssertTrue(TranslateOne.can(theirs, lang: "中文"))
    }
}

/// 我掷骰子：本地随机，正文与网页版一字不差
final class DiceTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testRollDice() throws {
        let six = try ChatEngine.rollDice(chatId: "chat_a", faces: 6)
        let v = Int(six.row.number("value") ?? 0)
        XCTAssertTrue((1...6).contains(v))
        XCTAssertEqual(six.content, "[骰子：\(v)]")
        XCTAssertEqual(six.role, .user)
        let d20 = try ChatEngine.rollDice(chatId: "chat_a", faces: 20)
        XCTAssertEqual(d20.content, "[骰子：\(Int(d20.row.number("value") ?? 0))（20 面）]")
        XCTAssertEqual(Int(try ChatEngine.rollDice(chatId: "chat_a", faces: 1).row.number("faces") ?? 0), 6)
        XCTAssertEqual(ChatEngine.diceFaces(try XCTUnwrap(Repo.chat("chat_a"))), 6)
    }
}

/// 回应：最近用过的排前面，网格没有重复，任意 emoji 都收
final class ReactRecentTests: XCTestCase {
    func testQuickListPutsRecentFirst() {
        var s = AppSettings.load()
        s.raw["reactRecent"] = .array([.string("\u{1F525}"), .string("abc"), .string("\u{2764}")])
        let q = Interact.quickList(s)
        XCTAssertEqual(q.count, 6)
        XCTAssertEqual(q.first, "\u{1F525}")
        // 红心带不带变体选择符算同一个
        XCTAssertEqual(q.filter { $0.hasPrefix("\u{2764}") }.count, 1)
        XCTAssertEqual(Set(Interact.grid).count, Interact.grid.count)
        XCTAssertTrue(Interact.grid.allSatisfy(Interact.isEmoji))
        let next = Interact.noteRecent("\u{1F602}", s).array?.compactMap(\.string) ?? []
        XCTAssertEqual(next.first, "\u{1F602}")
    }
}

/// 我写的旁白：正文带标记，摘掉方括号，不调接口
final class UserNarrationTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testAddNarration() throws {
        let m = try XCTUnwrap(ChatEngine.addNarration(text: " 窗外下起了雨] ", chatId: "chat_a"))
        XCTAssertEqual(m.kind, "narration")
        XCTAssertEqual(m.role, .user)
        XCTAssertEqual(m.content, "[旁白：窗外下起了雨]")
        XCTAssertEqual(m.row.string("narration"), "窗外下起了雨")
        XCTAssertNil(try ChatEngine.addNarration(text: "]", chatId: "chat_a"))
    }
}

/// 用文字发一张图：角色收到 [图片：…]，不走识图
final class TextImageTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testSendTextImage() throws {
        let m = try ChatEngine.sendTextImage(" 窗外的雪] ", chatId: "chat_a")
        XCTAssertEqual(m.kind, "image")
        XCTAssertEqual(m.content, "[图片：窗外的雪]")
        XCTAssertEqual(m.row.string("vision"), "done")
        XCTAssertEqual(m.row.string("imageDesc"), "窗外的雪")
        XCTAssertThrowsError(try ChatEngine.sendTextImage("  ", chatId: "chat_a"))
    }
}
