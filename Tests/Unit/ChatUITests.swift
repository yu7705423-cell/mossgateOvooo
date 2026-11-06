import XCTest
@testable import Eira

/// 聊天界面补齐网页版的几样（4.757 多选范围、4.853 收藏、4.901 面板分页、4.917 调整顺序、4.935 最近常用、
/// 4.802 / 4.857 状态栏折叠与限高、4.776 上一轮发送的内容、4.937 转发记录按聊天的样子打开）。
final class ChatUITests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
        LastSent.shared.clear()
    }

    // MARK: - 多选：往下全选、选中间

    func testPickSpan() {
        let ids = ["a", "b", "c", "d", "e"]
        // 往下全选：从勾的最早那一条一直选到最新一条
        XCTAssertEqual(Picking.span(ids: ids, picked: ["b"], toEnd: true), ["b", "c", "d", "e"])
        XCTAssertEqual(Picking.span(ids: ids, picked: ["d", "b"], toEnd: true), ["b", "c", "d", "e"])
        // 选中间：最早与最晚勾的两条之间
        XCTAssertEqual(Picking.span(ids: ids, picked: ["b", "e"], toEnd: false), ["b", "c", "d", "e"])
        XCTAssertEqual(Picking.span(ids: ids, picked: ["a", "c"], toEnd: false), ["a", "b", "c"])
        // 一条都没勾：原样；不在列表里的不算
        XCTAssertEqual(Picking.span(ids: ids, picked: [], toEnd: true), [])
        XCTAssertEqual(Picking.span(ids: ids, picked: ["x", "c"], toEnd: false), ["x", "c"])
        // 灰着的时候：只勾一条时的「选中间」、已经选到最后的「往下全选」
        XCTAssertFalse(Picking.spanGap(ids: ids, picked: ["b"]))
        XCTAssertTrue(Picking.spanGap(ids: ids, picked: ["b", "d"]))
        XCTAssertFalse(Picking.spanGap(ids: ids, picked: ["b", "c"]))
        XCTAssertTrue(Picking.belowGap(ids: ids, picked: ["b"]))
        XCTAssertFalse(Picking.belowGap(ids: ids, picked: ["c", "d", "e"]))
        XCTAssertFalse(Picking.belowGap(ids: ids, picked: []))
        // 补上的那几条按位置排进勾选先后，最后勾的仍在原来的位置之后
        XCTAssertEqual(Picking.order(["d", "b"], ids: ids, picked: ["b", "c", "d", "e"]), ["d", "b", "c", "e"])
        // 「选到这里」照旧
        XCTAssertEqual(MessageActions.pickRange(ids: ids, picked: ["b"], last: "b", to: "d"), ["b", "c", "d"])
    }

    // MARK: - 收藏

    func testFavoritesRoundTrip() throws {
        let a = try Repo.append(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "第一句"))
        let b = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "第二句"))
        XCTAssertTrue(try Favorites.all().isEmpty)
        try Favorites.set(a, true, at: 1000)
        try Favorites.set(b, true, at: 2000)
        // 最近收藏的在前；字段与网页版一样（fav、favAt），存在消息上
        XCTAssertEqual(try Favorites.all().map(\.id), [b.id, a.id])
        let row = try XCTUnwrap(Database.shared.get(Collections.messages, id: a.id))
        XCTAssertEqual(row["fav"], .bool(true))
        XCTAssertEqual(row["favAt"], .number(1000))
        // 取消：fav false、favAt 0
        try Favorites.set(a, false)
        let off = try XCTUnwrap(Database.shared.get(Collections.messages, id: a.id))
        XCTAssertEqual(off["fav"], .bool(false))
        XCTAssertEqual(off["favAt"], .number(0))
        XCTAssertEqual(try Favorites.all().map(\.id), [b.id])
        // 删掉消息，收藏随之没有
        try MessageActions.delete(b)
        XCTAssertTrue(try Favorites.all().isEmpty)
        XCTAssertEqual(Favorites.line(Message.new(chatId: "x", role: .user, authorId: "me", content: "[表情：好的]", kind: "sticker")), "[表情：好的]")
    }

    // MARK: - 加号面板分页与调整顺序

    func testPanelPagesAndMoveTo() {
        XCTAssertEqual(Panel.pages(Array(1...17)).map(\.count), [8, 8, 1])
        XCTAssertEqual(Panel.pages([Int]()).count, 0)
        XCTAssertEqual(Panel.pages([1, 2, 3]), [[1, 2, 3]])
        var s = AppSettings(raw: ["panelOrder": .array(["watch", "photo", "voice"].map { .string($0) })])
        XCTAssertFalse(Panel.changed(AppSettings(raw: [:])))
        let before = Panel.order(s)
        Panel.moveTo(&s, from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(Array(Panel.order(s).prefix(3)), [before[1], before[2], before[0]])
        // 网页版存着的、原生版不认识的那一格不丢
        XCTAssertTrue((s.raw["panelOrder"]?.array ?? []).contains(.string("watch")))
        XCTAssertTrue(Panel.changed(s))
        Panel.reset(&s)
        XCTAssertFalse(Panel.changed(s))
    }

    func testMsgMenuOrder() {
        var s = AppSettings(raw: [:])
        // 默认顺序与网页版 MSG_ITEMS 一致，三十项
        XCTAssertEqual(MenuOrder.order(s).count, 30)
        XCTAssertEqual(Array(MenuOrder.order(s).prefix(4)), ["reply", "copy", "fav", "edit"])
        XCTAssertEqual(MenuOrder.order(s).suffix(2), ["multi", "delete"])
        XCTAssertFalse(MenuOrder.changed(s))
        // 删除拖到最前：存进 msgMenuOrder，原生版不列的几格位置不动
        let shown = MenuOrder.shown(s)
        let fullBefore = MenuOrder.order(s)
        MenuOrder.move(&s, from: IndexSet(integer: shown.count - 1), to: 0)
        XCTAssertEqual(MenuOrder.shown(s).first, "delete")
        XCTAssertEqual(MenuOrder.shown(s).count, shown.count)
        let full = MenuOrder.order(s)
        for (i, id) in fullBefore.enumerated() where !MenuOrder.native.contains(id) { XCTAssertEqual(full[i], id) }
        XCTAssertEqual(s.raw["msgMenuOrder"]?.array?.count, 30)
        XCTAssertTrue(MenuOrder.changed(s))
        // 读的时候丢掉不认识的、补上缺的
        let odd = AppSettings(raw: ["msgMenuOrder": .array(["delete", "nope", "delete", "copy"].map { .string($0) })])
        XCTAssertEqual(Array(MenuOrder.order(odd).prefix(3)), ["delete", "copy", "reply"])
        XCTAssertEqual(MenuOrder.order(odd).count, 30)
        // 恢复默认写成 null，与网页版一样
        MenuOrder.reset(&s)
        XCTAssertEqual(s.raw["msgMenuOrder"], .null)
        XCTAssertFalse(MenuOrder.changed(s))
        XCTAssertEqual(MenuOrder.order(s), MenuOrder.all.map(\.id))
    }

    func testMenuOrderPersists() throws {
        var s = AppSettings.load()
        MenuOrder.move(&s, from: IndexSet(integer: 1), to: 0)
        try s.save()
        XCTAssertEqual(MenuOrder.shown(AppSettings.load()).prefix(2), ["copy", "reply"])
    }

    // MARK: - 表情面板：最近常用

    func testRecentStickers() throws {
        let a = Row.new(prefix: "stk", ["name": .string("好的"), "group": .string("默认")])
        let b = Row.new(prefix: "stk", ["name": .string("晚安"), "group": .string("夜")])
        try Database.shared.put(Stickers.collection, a)
        try Database.shared.put(Stickers.collection, b)
        let s = AppSettings.load()
        XCTAssertFalse(try Stickers.panelGroups(Stickers.all(), settings: s).contains(Stickers.recent))
        try Stickers.markMine(a.id, at: 1000)
        try Stickers.markMine(b.id, at: 2000)
        let items = try Stickers.all()
        XCTAssertEqual(Stickers.panelGroups(items, settings: s).first, Stickers.recent)
        XCTAssertEqual(Stickers.recentMine(items).map(\.id), [b.id, a.id])
        XCTAssertEqual(try Database.shared.get(Stickers.collection, id: a.id)?["myUsedAt"], .number(1000))
        // 角色发表情只记 useCount，不算最近常用
        let c = Row.new(prefix: "stk", ["name": .string("哼")])
        try Database.shared.put(Stickers.collection, c)
        Stickers.markUsed(c.id)
        XCTAssertFalse(Stickers.recentMine(try Stickers.all()).contains { $0.id == c.id })
    }

    // MARK: - 状态栏：折叠与最大高度

    func testStatusFoldBriefAndHeight() throws {
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        // 网页版存着的自定义样式（css）原生版不认，存回去不丢
        chat.row["statusBar"] = .object(["online": .object(["on": .bool(true), "css": .string(".ph-status-online{color:#333}")])])
        try Repo.save(chat)
        var cfg = StatusBar.config(try XCTUnwrap(Repo.chat("chat_a")))
        XCTAssertFalse(cfg.fold)
        XCTAssertTrue(cfg.folded)
        cfg.fold = true
        cfg.folded = false
        cfg.brief = "{{心情}} · {{ 所在地 }}"
        try StatusBar.save("chat_a", cfg)
        let raw = try XCTUnwrap(Repo.chat("chat_a")?.row["statusBar"]?.object?["online"]?.object)
        XCTAssertEqual(raw["css"], .string(".ph-status-online{color:#333}"))
        XCTAssertEqual(raw["fold"], .bool(true))
        XCTAssertEqual(raw["folded"], .bool(false))
        let back = StatusBar.config(try XCTUnwrap(Repo.chat("chat_a")))
        XCTAssertEqual(back.brief, "{{心情}} · {{ 所在地 }}")
        XCTAssertFalse(back.folded)

        let vals: [(id: String, label: String, value: String)] = [("mood", "心情", "开心"), ("place", "所在地", "家")]
        XCTAssertEqual(StatusBar.briefOf(back, vals), "开心 · 家")
        var plain = back
        plain.brief = ""
        XCTAssertEqual(StatusBar.briefOf(plain, vals), "开心 · 家")
        plain.brief = "{{没有这一栏}}在{{所在地}}"
        XCTAssertEqual(StatusBar.briefOf(plain, vals), "在家")

        // 最大高度存在 look.status.online.mh，钳在 40 到 1200；清空即不限，别的 look 不动
        var c2 = try XCTUnwrap(Repo.chat("chat_a"))
        c2.row["look"] = .object(["bg": .string("img_x")])
        try Repo.save(c2)
        try StatusBar.setMaxHeight("chat_a", 5)
        XCTAssertEqual(StatusBar.maxHeight(try XCTUnwrap(Repo.chat("chat_a"))), 40)
        try StatusBar.setMaxHeight("chat_a", 300)
        let look = try XCTUnwrap(Repo.chat("chat_a")?.row["look"]?.object)
        XCTAssertEqual(look["bg"], .string("img_x"))
        XCTAssertEqual(look["status"]?.object?["online"]?.object?["mh"], .number(300))
        try StatusBar.setMaxHeight("chat_a", nil)
        XCTAssertNil(StatusBar.maxHeight(try XCTUnwrap(Repo.chat("chat_a"))))
    }

    @MainActor
    func testStatusFoldsEachBlock() {
        var cfg = StatusBar.Config()
        cfg.fold = true
        let f = StatusFolds()
        let k1 = StatusFolds.key(chatId: "c", msgId: "m1", top: false)
        let k2 = StatusFolds.key(chatId: "c", msgId: "m2", top: false)
        XCTAssertTrue(f.folded(k1, cfg))
        f.toggle(k1, cfg)
        // 点一块只变这一块
        XCTAssertFalse(f.folded(k1, cfg))
        XCTAssertTrue(f.folded(k2, cfg))
        // 不能折叠时一律展开
        cfg.fold = false
        XCTAssertFalse(f.folded(k2, cfg))
    }

    // MARK: - 上一轮发送的内容

    func testSections() {
        let parts = LastSent.sections("你是某人。\n\n[对方是谁]\n名字：小明\n\n[相关记忆]\n- 喜欢猫\n[空的]\n\n[尾]\n[这一行不是抬头] 后面有字")
        // 抬头下面一个字都没有的那一块不列
        XCTAssertEqual(parts.map(\.head), ["开头", "对方是谁", "相关记忆", "尾"])
        XCTAssertEqual(parts[0].text, "你是某人。")
        XCTAssertEqual(parts[1].text, "名字：小明")
        XCTAssertEqual(parts[2].text, "- 喜欢猫")
        XCTAssertEqual(parts[3].text, "[这一行不是抬头] 后面有字")
        XCTAssertEqual(LastSent.headsOf(.init(role: "system", content: "[现在几点]\n十点\n[对方的日程]\n上班", images: 0)), "（现在几点、对方的日程）")
        XCTAssertEqual(LastSent.headsOf(.init(role: "user", content: "[现在几点]\n十点", images: 0)), "")
        XCTAssertFalse(LastSent.isHead("[" + String(repeating: "字", count: 21) + "]"))
    }

    func testReplyKeepsLastSentWithoutExtraCall() async throws {
        URLProtocol.registerClass(MockNet.self)
        defer { URLProtocol.unregisterClass(MockNet.self) }
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "name": .string("主用"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
        _ = try Repo.append(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "在吗"))
        XCTAssertNil(LastSent.shared.last("chat_a"))
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("在呢")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        // 记下来不另调接口
        XCTAssertEqual(MockNet.count, 1)
        let row = try XCTUnwrap(LastSent.shared.last("chat_a"))
        XCTAssertEqual(row.model, "m")
        XCTAssertFalse(row.system.isEmpty)
        XCTAssertTrue(row.messages.contains { $0.content.contains("在吗") })
        XCTAssertTrue(LastSent.text(row).hasPrefix("=== system ===\n"))
        // 失败的那一轮也记（发出去的就是它）；别的会话没有
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        _ = try Repo.append(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "第二句"))
        try? await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(LastSent.shared.last("chat_a")?.messages.contains { $0.content.contains("第二句") } == true)
        XCTAssertNil(LastSent.shared.last("chat_nope"))
    }

    // MARK: - 转发记录按聊天的样子打开

    func testForwardBubbles() throws {
        let sticker = Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "[表情：好的]", kind: "sticker")
        var st = sticker
        st.row["stickerId"] = .string("stk_1")
        st.row["translation"] = .string("OK")
        let a = try Repo.append(st)
        let b = try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "嗯"))
        let sent = try Forward.send(from: "chat_a", to: "chat_a", list: [a, b])
        let items = Forward.items(of: sent).items
        XCTAssertEqual(items[0].stickerId, "stk_1")
        XCTAssertEqual(items[0].trans, "OK")
        let char = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(items[1].face, ChatFaces.of(try Repo.chat("chat_a"), key: "char_a", fallback: char.avatar))
        XCTAssertEqual(Forward.stickerName("[表情：好的]"), "好的")

        // 名字：说话的不止一位时左边每条写名字；时刻：相隔十分钟以上才写
        let now = Date(millis: 1_800_000_000_000)
        let t0 = now.millis - 3_600_000
        let list = [
            Forward.Item(who: "甲", mine: false, kind: "text", text: "一", imageId: "", at: t0),
            Forward.Item(who: "乙", mine: false, kind: "text", text: "二", imageId: "", at: t0 + 60_000),
            Forward.Item(who: "我", mine: true, kind: "text", text: "三", imageId: "", at: t0 + 11 * 60_000),
        ]
        let rows = Forward.bubbles(list, meAvatar: "img_me", faceByName: { $0 == "甲" ? "img_jia" : "" }, now: now)
        XCTAssertEqual(rows.map(\.label), ["甲", "乙", ""])
        XCTAssertEqual(rows.map { !$0.time.isEmpty }, [true, false, true])
        XCTAssertEqual(rows.map(\.face), ["img_jia", "", "img_me"])
        let one = Forward.bubbles(Array(list.prefix(1)), meAvatar: "", faceByName: { _ in "" }, now: now)
        XCTAssertEqual(one.first?.label, "")
    }
}
