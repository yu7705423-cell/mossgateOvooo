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

/// 表情按名字找：精确、关键词、去空白、包含；指认之后记成关键词
final class StickerMatchTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testFindAndLearn() throws {
        let all = try Database.shared.all("stickers")
        XCTAssertEqual(StickerMatch.find("开心", in: all)?.id, "stk_1")
        XCTAssertEqual(StickerMatch.find("「开心」.png", in: all)?.id, "stk_1")
        XCTAssertEqual(StickerMatch.find("很开心呀", in: all)?.id, "stk_1")
        XCTAssertNil(StickerMatch.find("哦", in: all))
        XCTAssertNil(StickerMatch.find("转圈圈", in: all))

        var m = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "[表情：转圈圈]", kind: "sticker")
        m.row["stickerName"] = .string("转圈圈")
        m = try Repo.append(m)
        let bound = try StickerMatch.bind(m, to: try XCTUnwrap(Database.shared.get("stickers", id: "stk_1")))
        XCTAssertEqual(bound.row.string("stickerId"), "stk_1")
        XCTAssertEqual(bound.content, "[表情：开心]")
        XCTAssertEqual(StickerMatch.find("转圈圈", in: try Database.shared.all("stickers"))?.id, "stk_1")
        // 已经认得的不重复记
        try StickerMatch.learn("stk_1", name: "转圈圈")
        XCTAssertEqual(StickerMatch.keywords(try XCTUnwrap(Database.shared.get("stickers", id: "stk_1"))).filter { $0 == "转圈圈" }.count, 1)
    }
}

/// 连发的图摞成一叠：同一个人、连着的、没挂状态的才算
final class ImageStackTests: XCTestCase {
    private func img(_ id: String, role: Message.Role = .user, author: String = "me", media: String = "done") -> Message {
        var m = Message.new(chatId: "c", role: role, authorId: author, content: "[图片]", kind: "image")
        m.row["id"] = .string(id)
        m.row["imageId"] = .string("img_" + id)
        m.row["media"] = .string(media)
        return m
    }

    func testGroup() {
        let text = Message.new(chatId: "c", role: .user, authorId: "me", content: "看")
        let g = ImageStacks.group([img("a"), img("b"), text, img("c"), img("d", media: "pending"), img("e", role: .char, author: "x"), img("f", role: .char, author: "x")])
        XCTAssertEqual(g.map { $0.count }, [2, 1, 1, 1, 2])
    }
}

/// 心声的显示方式与翻看历史
final class InnerCardTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testStyleAndHistory() throws {
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertEqual(InnerVoice.style(chat), "quiet")
        chat.row["innerStyle"] = .string("card")
        XCTAssertEqual(InnerVoice.style(chat), "card")
        var a = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "嗯")
        a.row["inner"] = .string("第一句心声")
        a = try Repo.append(a)
        var b = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "好")
        b.row["inner"] = .string("第二句心声")
        b = try Repo.append(b)
        XCTAssertEqual(InnerCardView.history("chat_a").map(\.id), [b.id, a.id])
    }
}

/// 旁白与「已读，未回复」的长按菜单、旁白与心声的译文显示、群聊旁白的名字颜色、多选「选到这里」、改心声的译文
/// （网页版 MsgMenu 的 narr / silent，4.529、4.648、4.586、4.438、4.636）
final class NarrationDisplayTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testSlimMenuForNarrationAndSilence() {
        let narr = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "[旁白：风停了]", kind: "narration")
        XCTAssertEqual(MessageActions.slimMenu(narr, canRegen: true), ["regenerate", "edit", "copy", "select", "delete"])
        XCTAssertEqual(MessageActions.slimMenu(narr, canRegen: false), ["edit", "copy", "select", "delete"])
        let mine = Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "[旁白：雨停了]", kind: "narration")
        XCTAssertEqual(MessageActions.slimMenu(mine, canRegen: true), ["edit", "copy", "select", "delete"])
        let silence = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "", kind: "silence")
        XCTAssertEqual(MessageActions.slimMenu(silence, canRegen: true), ["regenerate", "select", "delete"])
        XCTAssertEqual(MessageActions.slimMenu(silence, canRegen: false), ["select", "delete"])
        let text = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "嗯")
        XCTAssertNil(MessageActions.slimMenu(text, canRegen: true))
    }

    func testNarrationTextStripsMarker() {
        var m = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "[旁白：风停了]", kind: "narration")
        XCTAssertEqual(MessageActions.narrationText(m), "风停了")
        m.row["narration"] = .string("雨停了")
        XCTAssertEqual(MessageActions.narrationText(m), "雨停了")
        let old = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "【旁白: 夜深了】", kind: "narration")
        XCTAssertEqual(MessageActions.narrationText(old), "夜深了")
    }

    func testTranslationModes() {
        // 旁白与气泡：只显示译文时正文换成译文，点开看到原文；只显示原文时不画译文
        XCTAssertEqual(MessageActions.transSwap("rain", "下雨了", mode: "both").main, "rain")
        XCTAssertEqual(MessageActions.transSwap("rain", "下雨了", mode: "both").sub, "下雨了")
        XCTAssertEqual(MessageActions.transSwap("rain", "下雨了", mode: "trans").main, "下雨了")
        XCTAssertEqual(MessageActions.transSwap("rain", "下雨了", mode: "trans").sub, "rain")
        XCTAssertEqual(MessageActions.transSwap("rain", "下雨了", mode: "orig").sub, "")
        XCTAssertEqual(MessageActions.transSwap("rain", "  ", mode: "trans").main, "rain")
        // 心声：网页版 transView.pair，只显示译文时下面不再有一行
        XCTAssertEqual(MessageActions.transPair("tired", "累了", mode: "both").sub, "累了")
        XCTAssertEqual(MessageActions.transPair("tired", "累了", mode: "trans").main, "累了")
        XCTAssertEqual(MessageActions.transPair("tired", "累了", mode: "trans").sub, "")
        XCTAssertEqual(MessageActions.transPair("tired", "累了", mode: "orig").main, "tired")
        XCTAssertEqual(MessageActions.transPair("tired", "累了", mode: "orig").sub, "")
    }

    func testNarrToneCyclesByMemberOrder() {
        let ids = (1...10).map { "c\($0)" }
        XCTAssertNil(MessageActions.narrTone(mine: true, memberIds: ids, authorId: "me"))
        XCTAssertEqual(MessageActions.narrTone(mine: false, memberIds: ids, authorId: "c1"), 0)
        XCTAssertEqual(MessageActions.narrTone(mine: false, memberIds: ids, authorId: "c8"), 7)
        XCTAssertEqual(MessageActions.narrTone(mine: false, memberIds: ids, authorId: "c9"), 0)
        XCTAssertEqual(MessageActions.narrTone(mine: false, memberIds: ids, authorId: "gone"), 0)
        XCTAssertEqual(Theme.narrPalette.count, 8)
    }

    func testPickRange() {
        let ids = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(MessageActions.pickRange(ids: ids, picked: ["b"], last: "b", to: "d"), ["b", "c", "d"])
        XCTAssertEqual(MessageActions.pickRange(ids: ids, picked: ["e"], last: "e", to: "c"), ["c", "d", "e"])
        // 一条都没勾时只选这一条
        XCTAssertEqual(MessageActions.pickRange(ids: ids, picked: [], last: nil, to: "c"), ["c"])
        // 最后勾的那一条已经取消了：只选这一条
        XCTAssertEqual(MessageActions.pickRange(ids: ids, picked: ["a"], last: "d", to: "c"), ["a", "c"])
        XCTAssertEqual(MessageActions.pickRange(ids: ids, picked: ["a"], last: "a", to: "zz"), ["a"])
    }

    func testEditInnerTranslation() throws {
        var m = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "Hello")
        m.row["inner"] = .string("tired")
        m.row["innerTrans"] = .string("累")
        m = try Repo.append(m)
        let a = try MessageActions.setTranslations(m, translation: " 你好 ", innerTrans: " 累了 ")
        XCTAssertEqual(a.row.string("translation"), "你好")
        XCTAssertEqual(a.row.string("innerTrans"), "累了")
        XCTAssertTrue(a.row.bool("transEdited"))
        let saved = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.id == m.id })
        XCTAssertEqual(saved.row.string("innerTrans"), "累了")
        let b = try MessageActions.setTranslations(a, translation: "", innerTrans: "")
        XCTAssertNil(b.row["translation"])
        XCTAssertNil(b.row["innerTrans"])
        // 没有心声那一栏时不动 innerTrans
        let c = try MessageActions.setTranslations(a, translation: "嗨", innerTrans: nil)
        XCTAssertEqual(c.row.string("innerTrans"), "累了")
    }

    func testInnerHistoryOnlyThatMember() throws {
        var a = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "嗯")
        a.row["inner"] = .string("甲的心声")
        a = try Repo.append(a)
        var b = Message.new(chatId: "chat_a", role: .char, authorId: "char_b", content: "好")
        b.row["inner"] = .string("乙的心声")
        b = try Repo.append(b)
        XCTAssertEqual(InnerCardView.history("chat_a", who: "char_a").map(\.id), [a.id])
        XCTAssertEqual(InnerCardView.history("chat_a", who: "char_b").map(\.id), [b.id])
        XCTAssertEqual(Set(InnerCardView.history("chat_a").map(\.id)), [a.id, b.id])
    }
}
