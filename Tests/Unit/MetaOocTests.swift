import XCTest
@testable import Eira

// 会话菜单分组的先后（网页版 4.917 后一半）、角色截图（4.904）、元模式（4.817、4.832、4.903）、场外（4.819）。

final class ConvOrderTests: StoreTestCase {
    /// 默认顺序与网页版 CONV_GROUPS 一字不差；原生版没有的两组不在排序页上
    func testDefaultAndShown() {
        let s = AppSettings(raw: [:])
        XCTAssertEqual(ConvOrder.order(s), ["who", "reply", "scene", "play", "input", "display", "basic", "prompt", "memory", "review", "ties"])
        XCTAssertEqual(ConvOrder.shown(s), ["who", "reply", "play", "input", "basic", "prompt", "memory", "review", "ties"])
        XCTAssertFalse(ConvOrder.changed(s))
    }

    /// 记忆挪到最前：菜单上的组跟着排，「更多」固定在最后；原生版不列的两组位置不动；恢复默认写成 null
    func testMoveAndSortMenuGroups() {
        var s = AppSettings(raw: [:])
        let before = ConvOrder.order(s)
        let at = ConvOrder.shown(s).firstIndex(of: "memory")!
        ConvOrder.move(&s, from: IndexSet(integer: at), to: 0)
        XCTAssertEqual(ConvOrder.shown(s).first, "memory")
        XCTAssertTrue(ConvOrder.changed(s))
        let after = ConvOrder.order(s)
        for (i, id) in before.enumerated() where !ConvOrder.native.contains(id) { XCTAssertEqual(after[i], id) }
        let labels = ["这个角色", "回复", "玩法", "输入栏", "基础", "提示词", "记忆", "回顾", "好友与拉黑", "更多"]
        let sorted = ConvOrder.sort(labels, s, by: ConvOrder.idOf)
        XCTAssertEqual(sorted.first, "记忆")
        XCTAssertEqual(sorted.last, "更多")
        XCTAssertEqual(sorted.count, labels.count)
        XCTAssertEqual(ConvOrder.idOf("这个群"), "who")
        ConvOrder.reset(&s)
        XCTAssertFalse(ConvOrder.changed(s))
        XCTAssertEqual(ConvOrder.order(s), before)
    }

    /// 读的时候丢掉不认识的、补上缺的（以后新加一组，老用户不会静默少一组）
    func testDirtyStoredOrder() {
        let s = AppSettings(raw: ["convMenuOrder": .array([.string("ties"), .string("nope"), .string("ties"), .string("who")])])
        let o = ConvOrder.order(s)
        XCTAssertEqual(Array(o.prefix(2)), ["ties", "who"])
        XCTAssertEqual(o.count, ConvOrder.all.count)
    }
}

final class CharShotTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testParse() {
        XCTAssertEqual(CharShot.parse("从「今天好累」开始|下班那天|私密"), .init(quote: "今天好累", note: "下班那天", priv: true))
        XCTAssertEqual(CharShot.parse("下班"), .init(quote: "", note: "下班", priv: false))
        XCTAssertEqual(CharShot.parse(""), .init(quote: "", note: "", priv: false))
        XCTAssertEqual(CharShot.parse("从“你好”开始").quote, "你好")
    }

    /// 标记照网页版 reply.js：单独一行才认；截图不落成消息，发截图带着说明
    func testParserMarks() {
        let parts = ReplyParser.split("[截图：从「你好」开始|第一句]\n[发截图：第一句]\n好的").parts
        XCTAssertEqual(parts.map(\.type), [.shot, .sendshot, .text])
        XCTAssertEqual(parts[0].text, "从「你好」开始|第一句")
        XCTAssertEqual(parts[1].text, "第一句")
        XCTAssertEqual(ReplyParser.split("[截图]").parts.map(\.type), [.shot])
        let (mapped, unmapped) = WebLogic.map([["type": "shot", "raw": "x"], ["type": "sendshot", "query": "y"]])
        XCTAssertEqual(mapped.map(\.type), [.shot, .sendshot])
        XCTAssertEqual(mapped.map(\.text), ["x", "y"])
        XCTAssertTrue(unmapped.isEmpty)
    }

    /// 从那句原话截到这一轮之前；是角色那一边的截图：你说的在左边（role char），名字是你的账号名（没有备注时）
    func testTakeFromQuote() throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        let id = try XCTUnwrap(CharShot.take(chat: chat, char: char, raw: "从「你好」开始|第一句", turnId: "turn_new"))
        let p = try XCTUnwrap(Theirs.photos("char_a").first { $0.id == id })
        XCTAssertEqual(p.kind, "shot")
        XCTAssertEqual(p.note, "第一句")
        XCTAssertEqual(p.chatId, "chat_a")
        XCTAssertEqual(p.msgs.count, 3)
        XCTAssertEqual(p.msgs[0]["role"]?.string, "char")
        XCTAssertEqual(p.msgs[0]["_name"]?.string, "小于")
        XCTAssertEqual(p.msgs[1]["role"]?.string, "user")
        XCTAssertEqual(p.msgs[1]["_name"]?.string, "林")
        XCTAssertFalse(p.shotId.isEmpty)
        XCTAssertNotNil(try Database.shared.get("shots", id: p.shotId))
        // 这一轮自己刚落下的不算
        let id2 = try XCTUnwrap(CharShot.take(chat: chat, char: char, raw: "", turnId: "turn_1"))
        XCTAssertEqual(Theirs.photos("char_a").first { $0.id == id2 }?.msgs.count, 1)
        XCTAssertEqual(Theirs.photos("char_a").first { $0.id == id2 }?.note, "聊天记录")
    }

    func testPrivateGoesToLockedBookAndPick() throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        try Theirs.addAlbum("char_a", name: "秘密", code: "1234")
        try CharShot.take(chat: chat, char: char, raw: "|只给自己看|私密", turnId: "")
        let book = try XCTUnwrap(Theirs.albums("char_a").first { $0.name == "秘密" })
        XCTAssertEqual(CharShot.shotsOf("char_a").first?.albumId, book.id)
        XCTAssertEqual(CharShot.pick("char_a", "只给自己")?.note, "只给自己看")
        XCTAssertNil(CharShot.pick("char_nobody", "x"))
        XCTAssertEqual(CharShot.savedLine("char_a"), "只给自己看")
        let carried = CharShot.carry(try XCTUnwrap(CharShot.shotsOf("char_a").first))
        XCTAssertEqual(carried["note"]?.string, "只给自己看")
    }

    /// 新功能默认不注入（第 24 条）：没开时提示词里没有这一项，开了（全局或这个角色）才有
    func testFeatureOffByDefault() throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        var s = AppSettings.load()
        XCTAssertFalse(CharShot.capOn(char, s))
        XCTAssertFalse(try ChatPrompt.build(chat: chat, char: char, settings: s).system.contains("[截图："))
        XCTAssertEqual(NewFeat.pending(app: "chat", s).map(\.id), ["charshot"])
        try NewFeat.setFor("char_a", "charshot", "on")
        let mine = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertTrue(CharShot.capOn(mine, s))
        XCTAssertTrue(try ChatPrompt.build(chat: chat, char: mine, settings: s).system.contains("[截图："))
        NewFeat.set("charshot", true, &s)
        try NewFeat.setFor("char_a", "charshot", "off")
        XCTAssertFalse(CharShot.capOn(try XCTUnwrap(Repo.character("char_a")), s))
        try NewFeat.setFor("char_a", "charshot", "")
        XCTAssertTrue(CharShot.capOn(try XCTUnwrap(Repo.character("char_a")), s))
        XCTAssertTrue(NewFeat.pending(app: "chat", s).isEmpty)
    }
}

/// 网络一律接住：主用（Anthropic）回 main，副用（OpenAI 兼容）回 spare
class MockedChatCase: StoreTestCase {
    var main: (Int) -> MockNet.Reply = { _ in .init(status: 200, body: MockNet.anthropicStream("好")) }
    var spare: (Int) -> MockNet.Reply = { _ in .init(status: 200, body: MockNet.openaiStream(#"{"ok":true}"#)) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([
                .object(["id": .string("svc_main"), "name": .string("主"), "provider": .string("anthropic"),
                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("claude-x")]),
                .object(["id": .string("svc_spare"), "name": .string("副"), "provider": .string("openai"),
                         "baseUrl": .string("https://spare.test/v1"), "apiKey": .string("k"), "model": .string("deepseek-chat")]),
            ]),
            "activeId": .string("svc_main"),
            "fallbackId": .string("svc_spare"),
        ])])])
        MockNet.reset { [unowned self] req, n in req.url?.host == "spare.test" ? self.spare(n) : self.main(n) }
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    func hosts() -> [String] { MockNet.requests.compactMap { $0.url?.host } }
    func body(_ i: Int) -> String { String(data: MockNet.requests[i].httpBodyStreamData() ?? Data(), encoding: .utf8) ?? "" }
}

final class MetaTests: MockedChatCase {
    func testEnsureAndIds() throws {
        XCTAssertNil(try Repo.chat(Meta.firstChatId))
        let c = try Meta.ensure()
        XCTAssertTrue(Meta.isMeta(c))
        XCTAssertEqual(c.characterIds, ["char_meta"])
        let other = try Meta.create("")
        XCTAssertTrue(other.id.hasPrefix("chat_meta_"))
        XCTAssertEqual(Meta.charIdOf(other.id), "char_meta_" + other.id.dropFirst("chat_meta_".count))
        XCTAssertEqual(Meta.nameOf(other), "元 2")
        XCTAssertEqual(Set(Meta.list().map(\.id)), [c.id, other.id])
        XCTAssertTrue(Meta.valid(Meta.firstChatId))
        XCTAssertFalse(Meta.valid("chat_a"))
        // 元的会话不进记忆
        try Meta.send("你好", chatId: c.id)
        try Meta.send("在吗", chatId: c.id)
        XCTAssertTrue(try MemorySummary.pending(chatId: c.id).isEmpty)
    }

    /// 默认什么都不注入：没有 system，消息就是说过的话；引用写成 Markdown 引用块
    func testBuildDefaultEmpty() throws {
        let c = try Meta.ensure()
        let a = try Meta.send("第一句", chatId: c.id)
        try Meta.send("第二句", chatId: c.id, quote: a)
        let b = Meta.build(try XCTUnwrap(Repo.chat(c.id)), msgs: try Repo.messages(chatId: c.id))
        XCTAssertEqual(b.system, "")
        XCTAssertEqual(b.messages.map(\.role), [.user, .user])
        XCTAssertEqual(b.messages[0].content, "第一句")
        XCTAssertEqual(b.messages[1].content, "> 第一句\n\n第二句")
    }

    /// 系统提示词认 {{char}}；挂上的书触发、全局的书不带；时间感知开了才有
    func testBuildWithSystemBooksTime() throws {
        let c = try Meta.ensure()
        try Meta.send("说说猫", chatId: c.id)
        let mine = Row.new(prefix: "lb", ["name": .string("元的书"), "entries": .array([
            .object(["id": .string("m1"), "keys": .array([.string("猫")]), "content": .string("META_CAT"), "enabled": .bool(true)]),
        ])])
        let global = Row.new(prefix: "lb", ["name": .string("全局"), "global": .bool(true), "entries": .array([
            .object(["id": .string("g1"), "constant": .bool(true), "content": .string("GLOBAL_ALWAYS"), "enabled": .bool(true)]),
        ])])
        try Database.shared.put(Collections.lorebooks, mine)
        try Database.shared.put(Collections.lorebooks, global)
        try Meta.set(c.id, ["metaSystem": .string("你是{{char}}。"), "metaBooks": .array([.string(mine.id)]), "metaTime": .bool(true)])
        let b = Meta.build(try XCTUnwrap(Repo.chat(c.id)), msgs: try Repo.messages(chatId: c.id))
        XCTAssertTrue(b.system.hasPrefix("你是元。"))
        XCTAssertTrue(b.system.contains("META_CAT"))
        XCTAssertFalse(b.system.contains("GLOBAL_ALWAYS"))
        XCTAssertFalse(b.system.contains("LORE_ALWAYS"))
        XCTAssertTrue(b.system.contains("It is now "))
    }

    func testParagraphsAndStickerSplit() {
        XCTAssertEqual(Meta.paragraphs("a\n\nb\n```\nx\n\ny\n```\n\nc"), ["a", "b\n```\nx\n\ny\n```", "c"])
        XCTAssertEqual(Meta.split("嗯\n[表情：开心]\n好", sticker: true, paragraphs: false), [.text("嗯"), .sticker("开心"), .text("好")])
        XCTAssertEqual(Meta.split("嗯\n[表情：开心]", sticker: false, paragraphs: false), [.text("嗯\n[表情：开心]")])
    }

    func testMarkdownBlocks() {
        let b = MarkdownBlocks.parse("# 标题\n正文**粗**\n\n- 一\n- 二\n\n1. 甲\n2. 乙\n\n> 引\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---")
        XCTAssertEqual(b, [.heading(level: 1, text: "标题"), .paragraph("正文**粗**"), .bullet(["一", "二"]), .ordered(start: 1, items: ["甲", "乙"]),
                           .quote("引"), .code(lang: "swift", text: "let a = 1\n\nlet b = 2"), .table([["a", "b"], ["1", "2"]]), .rule])
        // 流式写到一半的代码块照样是代码块
        XCTAssertEqual(MarkdownBlocks.parse("```\nabc"), [.code(lang: "", text: "abc")])
    }

    /// 一条消息一次请求；原样一条、不拆条；人不在这一页时记未读；重新生成上一版留作候选
    func testReplyOneRequestAndRegenerate() async throws {
        main = { _ in .init(status: 200, body: MockNet.anthropicStream("第一行\n第二行\n\n[表情：开心]")) }
        let c = try Meta.ensure()
        try Meta.send("你好", chatId: c.id)
        try await Meta.reply(chatId: c.id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(hosts(), ["main.test"])
        XCTAssertFalse(body(0).contains("PERSONA_TEXT"))
        let msgs = try Repo.messages(chatId: c.id)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs.last?.content, "第一行\n第二行\n\n[表情：开心]")
        XCTAssertEqual(msgs.last?.authorId, "char_meta")
        XCTAssertEqual(try Repo.chat(c.id)?.unread, 1)
        main = { _ in .init(status: 200, body: MockNet.anthropicStream("新的")) }
        try await Meta.reply(chatId: c.id, regenerate: true)
        XCTAssertEqual(MockNet.count, 2)
        let after = try Repo.messages(chatId: c.id)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after.last?.content, "新的")
        XCTAssertEqual(after.last?.row["swipes"]?.array?.count, 2)
        try Meta.switchVersion(chatId: c.id, step: -1)
        XCTAssertEqual(try Repo.messages(chatId: c.id).last?.content, "第一行\n第二行\n\n[表情：开心]")
        XCTAssertEqual(MockNet.count, 2)
    }

    /// 一段一条与表情包都开时：按空行切、表情落成表情（名字对不上的不落）
    func testReplySplitAndSticker() async throws {
        main = { _ in .init(status: 200, body: MockNet.anthropicStream("一段\n\n二段\n[表情：开心]\n[表情：没有这个]")) }
        let c = try Meta.ensure()
        try Meta.set(c.id, ["metaSplit": .bool(true)])
        try Meta.setCap(c.id, "sticker", true)
        try Meta.send("你好", chatId: c.id)
        Meta.looking.insert(c.id)
        defer { Meta.looking.remove(c.id) }
        try await Meta.reply(chatId: c.id)
        let out = try Repo.messages(chatId: c.id).dropFirst()
        XCTAssertEqual(out.map(\.kind), ["text", "text", "sticker"])
        XCTAssertEqual(out.last?.row.string("stickerId"), "stk_1")
        XCTAssertEqual(Set(out.map(\.turnId)).count, 1)
        XCTAssertEqual(try Repo.chat(c.id)?.unread ?? 0, 0)
        XCTAssertTrue(body(0).contains("开心"))
    }

    /// 接口一直失败：只打一次，不落失败的消息，错误交给界面
    func testReplyFailureOneRequest() async throws {
        main = { _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        let c = try Meta.ensure()
        try Meta.send("你好", chatId: c.id)
        do { try await Meta.reply(chatId: c.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(try Repo.messages(chatId: c.id).count, 1)
    }

    func testSaveToOwnBook() throws {
        let c = try Meta.ensure()
        let name = try Meta.saveToBook(c.id, text: "记住这条\n第二行")
        XCTAssertEqual(name, "元 · 世界书")
        let book = try XCTUnwrap(Meta.ownBook(c.id))
        XCTAssertEqual(book.entries.first?.comment, "记住这条")
        XCTAssertTrue(book.entries.first?.constant == true)
        XCTAssertEqual(try Repo.chat(c.id)?.row.strings("metaBooks"), [book.id])
        try Meta.saveToBook(c.id, text: "再一条")
        XCTAssertEqual(Meta.ownBook(c.id)?.entries.count, 2)
    }

    func testRemoveDropsMemories() throws {
        let c = try Meta.create("测试")
        let cid = Meta.charIdOf(c.id)
        try Database.shared.put(Collections.memories, Row.new(prefix: "mem", ["charId": .string(cid), "content": .string("x")]))
        try Meta.send("你好", chatId: c.id)
        try Meta.remove(c.id)
        XCTAssertNil(try Repo.chat(c.id))
        XCTAssertTrue(try Repo.memories(charId: cid).isEmpty)
        XCTAssertTrue(try Repo.messages(chatId: c.id).isEmpty)
    }
}

final class OocTests: MockedChatCase {
    func testCfgAndTrigger() throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertEqual(Ooc.cfg(chat), Ooc.Cfg())
        XCTAssertNil(Ooc.triggered(chat, "ooc 这里不对"))
        try Ooc.set("chat_a", ["on": .bool(true)])
        let on = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertEqual(Ooc.triggered(on, "ooc 这里不对"), "这里不对")
        XCTAssertEqual(Ooc.triggered(on, "OOC：人设偏了"), "人设偏了")
        XCTAssertNil(Ooc.triggered(on, "oocx 不是"))
        XCTAssertNil(Ooc.triggered(on, "你好"))
        XCTAssertEqual(Ooc.menuLabel(on), "已开启")
    }

    func testStyleTitleAndParts() throws {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertEqual(Ooc.styleOf(chat, model: "deepseek-reasoner"), "deepseek")
        XCTAssertEqual(Ooc.styleOf(chat, model: "gemini-2.5-pro"), "gemini")
        XCTAssertEqual(Ooc.styleOf(chat, model: "gpt-5"), "gpt")
        XCTAssertEqual(Ooc.styleOf(chat, model: "o3-mini"), "gpt")
        XCTAssertEqual(Ooc.styleOf(chat, model: "something"), "claude")
        XCTAssertEqual(Ooc.titleOf("【错误分类】「人设偏离」\n【违规行为】…"), "人设偏离")
        XCTAssertTrue(Ooc.titleOf("没有分类").hasPrefix("纠偏 "))
        let char = try XCTUnwrap(Repo.character("char_a"))
        let s = AppSettings.load()
        let p = Ooc.checkParts(chat, char: char, card: "CARD", lore: "", context: "", reply: "REPLY", model: "deepseek-chat", settings: s)
        XCTAssertEqual(p.system, "")
        XCTAssertTrue(p.user.contains("CARD") && p.user.contains("REPLY") && p.user.contains("(empty)"))
        XCTAssertEqual(p.user.hasPrefix(Templates.get("task.ooc-check-deepseek", settings: s)), true)
        let q = Ooc.checkParts(chat, char: char, card: "CARD", lore: "", context: "", reply: "REPLY", model: "claude-x", settings: s)
        XCTAssertEqual(q.system, Templates.get("task.ooc-check-claude", settings: s))
        try Ooc.set("chat_a", ["style": .string("custom"), "customReview": .string("看看{{char}}")])
        XCTAssertEqual(Ooc.reviewText(try Repo.chat("chat_a"), char: char, note: "哪里不对", model: "", settings: s), "看看林\n\n哪里不对")
    }

    /// 不可见时场外的问答一条都不进历史；可见时写成 [场外：…] 与 [场外回复：…]
    func testHistoryVisibility() throws {
        try Repo.append(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "这里出戏了", kind: Ooc.kind))
        try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "OOC_ANSWER", kind: Ooc.kind))
        let char = try XCTUnwrap(Repo.character("char_a"))
        let s = AppSettings.load()
        let hidden = try ChatPrompt.build(chat: try XCTUnwrap(Repo.chat("chat_a")), char: char, settings: s)
        XCTAssertFalse(hidden.messages.contains { $0.content.contains("这里出戏了") || $0.content.contains("OOC_ANSWER") })
        try Ooc.set("chat_a", ["visible": .bool(true)])
        let shown = try ChatPrompt.build(chat: try XCTUnwrap(Repo.chat("chat_a")), char: char, settings: s)
        XCTAssertTrue(shown.messages.contains { $0.content.contains("[场外：这里出戏了]") })
        XCTAssertTrue(shown.messages.contains { $0.content.contains("[场外回复：OOC_ANSWER]") })
        // 不进记忆
        XCTAssertFalse(try MemorySummary.pending(chatId: "chat_a").contains { $0.kind == Ooc.kind })
    }

    /// 存为世界书：默认存进「角色名 的纠偏」，第一次存时建、挂到角色上；标题取【错误分类】
    func testSaveToCorrectionBook() throws {
        let name = try Ooc.save("chat_a", text: "【错误分类】语气\n【正确示范】……")
        XCTAssertEqual(name, "林 的纠偏")
        let book = try XCTUnwrap(Repo.lorebooks().first { $0.row.string("oocFor") == "char_a" })
        XCTAssertEqual(book.entries.first?.comment, "语气")
        XCTAssertTrue(book.entries.first?.constant == true)
        XCTAssertTrue(try XCTUnwrap(Repo.character("char_a")).lorebookIds.contains(book.id))
        XCTAssertEqual(Ooc.targetName("chat_a"), "林 的纠偏")
        try Ooc.save("chat_a", text: "再一条")
        XCTAssertEqual(try Repo.lorebooks().filter { $0.row.string("oocFor") == "char_a" }.count, 1)
        // 选了别的书就存进那一本
        try Ooc.set("chat_a", ["bookId": .string("lb_1")])
        XCTAssertEqual(try Ooc.save("chat_a", text: "进设定"), "设定")
    }

    func testEndsOf() throws {
        var head = Message.new(chatId: "c", role: .char, authorId: "x", content: "a", turnId: "t1")
        head.row["oocCheck"] = .string("issues")
        let tail = Message.new(chatId: "c", role: .char, authorId: "x", content: "b", turnId: "t1")
        XCTAssertEqual(Ooc.endsOf([head, tail])[tail.id]?.id, head.id)
        head.row["oocDismissed"] = .bool(true)
        XCTAssertTrue(Ooc.endsOf([head, tail]).isEmpty)
    }

    func testExtraCallsRegistered() throws {
        let s = AppSettings.load()
        XCTAssertFalse(ExtraCalls.all.first { $0.id == "oocCheck" }!.isOn(s))
        try Ooc.set("chat_a", ["check": .bool(true)])
        XCTAssertTrue(ExtraCalls.all.first { $0.id == "oocCheck" }!.isOn(s))
        XCTAssertFalse(ExtraCalls.all.first { $0.id == "oocRewrite" }!.isOn(s))
        XCTAssertEqual(RouteGroup.of(task: "ooc.check"), "ooc")
    }
}

/// 花钱的次数（网页版第 15 条，同 CostTests 的规矩）：场外的提问、自动检查、自动重写，元的回复
final class OocCostTests: MockedChatCase {
    /// 默认关：一轮回复只打一次，场外一次都不打
    func testDefaultNoCheck() async throws {
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        await Ooc.after(chatId: "chat_a")
        XCTAssertEqual(MockNet.count, 1)
    }

    /// 开了自动检查：每轮多一次（走副用），结果写在这一轮第一条上；同一轮不再自动检查第二次
    func testCheckOncePerTurn() async throws {
        try Ooc.set("chat_a", ["check": .bool(true)])
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        await Ooc.after(chatId: "chat_a")
        XCTAssertEqual(hosts(), ["main.test", "spare.test"])
        let head = try XCTUnwrap(ChatEngine.lastTurn(chatId: "chat_a")?.rows.first)
        XCTAssertEqual(head.row.string("oocCheck"), "ok")
        await Ooc.after(chatId: "chat_a")
        XCTAssertEqual(MockNet.count, 2)
    }

    /// 检查的接口一直失败：先记「试过」再发，失败也算试过，这一轮不再自动试；不重试
    func testCheckFailingTriedOnce() async throws {
        spare = { _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        try setSettings(["retryMax": .number(3)])
        try Ooc.set("chat_a", ["check": .bool(true)])
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let replyCalls = MockNet.count
        await Ooc.after(chatId: "chat_a")
        await Ooc.after(chatId: "chat_a")
        XCTAssertEqual(MockNet.count, replyCalls + 1)
        let head = try XCTUnwrap(ChatEngine.lastTurn(chatId: "chat_a")?.rows.first)
        XCTAssertEqual(head.row.string("oocCheck"), "failed")
        XCTAssertTrue(head.row.string("oocError").contains("down"))
    }

    /// 自动重写，最多一次：回复 + 检查 + 重写 + 再检查，之后只标出；原回复留在候选里
    func testRewriteCapped() async throws {
        spare = { _ in .init(status: 200, body: MockNet.openaiStream(#"{"ok":false,"issues":[{"card":"不喝酒","reply":"喝了酒","fix":"不喝"}]}"#)) }
        try Ooc.set("chat_a", ["check": .bool(true), "checkMode": .string("rewrite"), "rewriteMax": .number(1)])
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        await Ooc.after(chatId: "chat_a")
        XCTAssertEqual(hosts(), ["main.test", "spare.test", "main.test", "spare.test"])
        XCTAssertTrue(body(2).contains("不喝酒"))
        let turn = try XCTUnwrap(ChatEngine.lastTurn(chatId: "chat_a"))
        XCTAssertEqual(turn.versions.swipes.count, 2)
        XCTAssertEqual(turn.rows.first?.row.string("oocCheck"), "issues")
        XCTAssertEqual(Ooc.issues(of: try XCTUnwrap(turn.rows.first)).first?.card, "不喝酒")
        await Ooc.after(chatId: "chat_a")
        XCTAssertEqual(MockNet.count, 4)
    }

    /// 场外问答：一次提问一次请求（走主用），问与答都是 kind ooc，末尾接复盘说明
    func testAskOneRequest() async throws {
        main = { _ in .init(status: 200, body: MockNet.anthropicStream("【错误分类】语气")) }
        try Ooc.set("chat_a", ["on": .bool(true)])
        let ans = try await Ooc.ask(chatId: "chat_a", note: "刚才那句出戏了")
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(hosts(), ["main.test"])
        XCTAssertEqual(ans.kind, Ooc.kind)
        XCTAssertTrue(body(0).contains("刚才那句出戏了"))
        XCTAssertTrue(body(0).contains("PERSONA_TEXT"))
        let oocs = try Repo.messages(chatId: "chat_a").filter { $0.kind == Ooc.kind }
        XCTAssertEqual(oocs.map(\.role), [.user, .char])
    }

    /// 场外问答的接口一直失败：只打一次，问的那一条留着，答复不落
    func testAskFailingOneRequest() async throws {
        main = { _ in .init(status: 500, body: "{}") }
        try setSettings(["retryMax": .number(3)])
        try Ooc.set("chat_a", ["on": .bool(true)])
        do { try await Ooc.ask(chatId: "chat_a", note: "x"); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").filter { $0.kind == Ooc.kind }.count, 1)
    }

    /// 元的回复：接口一直失败时一条消息只打出去一次（retries 取 1 与 retryMax 默认 0 里小的那个）
    func testMetaFailingOnce() async throws {
        main = { _ in .init(status: 503, body: "{}") }
        let c = try Meta.ensure()
        try Meta.send("你好", chatId: c.id)
        do { try await Meta.reply(chatId: c.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
    }

    /// 角色截图：截下、发截图都不另调接口；回复只打一次，截图那一行不落成消息
    func testCharShotNoExtraCall() async throws {
        var s = AppSettings.load()
        NewFeat.set("charshot", true, &s)
        try s.save()
        main = { _ in .init(status: 200, body: MockNet.anthropicStream("[截图：从「你好」开始|第一句]\n好的")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(CharShot.shotsOf("char_a").first?.note, "第一句")
        XCTAssertFalse(try Repo.messages(chatId: "chat_a").contains { $0.content.contains("截图") })
        main = { _ in .init(status: 200, body: MockNet.anthropicStream("[发截图：第一句]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 2)
        let sent = try XCTUnwrap(Repo.messages(chatId: "chat_a").last)
        XCTAssertEqual(sent.kind, "charshot")
        XCTAssertEqual(sent.content, "[聊天截图：第一句]")
        XCTAssertEqual(sent.row["shot"]?["msgs"]?.array?.isEmpty, false)
        XCTAssertTrue(body(1).contains("第一句"))
    }
}
