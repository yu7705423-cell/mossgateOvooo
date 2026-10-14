import XCTest
@testable import Eira

/// 预设的条目顺序（网页版 layout.js）与预设本身（presets.js）。
final class LayoutTests: StoreTestCase {
    private func build() throws -> ChatPrompt.Built {
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        return try ChatPrompt.build(chat: chat, char: char, settings: AppSettings.load().forChat(chat))
    }

    private func layout(_ ids: [(String, Bool)]) -> JSONValue {
        .object(["chat": .array(ids.map { .object(["id": .string($0.0), "on": .bool($0.1)]) })])
    }

    /// 没动过的人：线上聊天的默认顺序与网页版一字不差（网页版 DEFAULTS.chat 加迁移后的数据组顺序）。
    func testDefaultChatOrderMatchesWeb() {
        let ids = Layout.resolve("chat", AppSettings(raw: [:])).map(\.id)
        XCTAssertEqual(ids, ["opening", "faceOpening", "gender",
                             "grp:loreBefore", "grp:bond", "grp:char", "grp:loreAfter", "grp:you", "grp:recall", "grp:pinned",
                             "grp:impress", "grp:circle", "grp:between",
                             "faceSetup", "summary", "groupNote", "rules", "caps", "style", "core", "ban", "genderTail",
                             "history", "inner", "status", "grp:now"])
        // 通话的聊天记录永远在最后
        XCTAssertEqual(Layout.resolve("call", AppSettings(raw: [:])).last?.id, "history")
    }

    /// 存着的顺序为准；新加的段落按默认位置补进去；认不出的丢掉；跟随开关的关不掉。
    func testResolveMergesStored() {
        let s = AppSettings(raw: ["promptLayout": layout([("rules", true), ("opening", false), ("ghost", true), ("caps", false)])])
        let items = Layout.resolve("chat", s)
        XCTAssertEqual(Array(items.prefix(2).map(\.id)), ["rules", "opening"])
        XCTAssertFalse(items.contains { $0.id == "ghost" })
        XCTAssertEqual(items.first { $0.id == "opening" }?.on, false)
        XCTAssertEqual(items.first { $0.id == "caps" }?.on, true)
        XCTAssertEqual(Set(items.map(\.id)).count, Layout.resolve("chat", AppSettings(raw: [:])).count)
    }

    /// 自己加的条目进提示词，名字照填；关掉的一条不发；挪到聊天记录下面的一条贴着最后一条消息。
    func testCustomEntryAndToggles() throws {
        try importFixture("data.json")
        let base = try build()
        XCTAssertTrue(base.system.hasPrefix(Templates.render("skeleton.opening", ["charName": "林", "userName": "小于"], settings: .load())
            .trimmingCharacters(in: .whitespacesAndNewlines)))

        var items = Layout.resolve("chat", .load()).map { ($0.id, $0.on) }
        // 关掉身份开场
        items = items.map { $0.0 == "opening" ? ($0.0, false) : $0 }
        // 自己加一条，放在聊天记录前
        let h = items.firstIndex { $0.0 == "history" }!
        items.insert(("custom:c1", true), at: h)
        // 「消息规则」是必需的，存成关也照发
        items = items.map { $0.0 == "rules" ? ($0.0, false) : $0 }
        // 用户信息挪到聊天记录下面
        let you = items.remove(at: items.firstIndex { $0.0 == "grp:you" }!)
        items.append(you)
        try setSettings([
            "promptLayout": layout(items),
            "promptCustom": .array([.object(["id": .string("c1"), "name": .string("文风"), "text": .string("CUSTOM_FOR {{charName}}")])]),
        ])
        let b = try build()
        XCTAssertTrue(b.system.contains("CUSTOM_FOR 林"))
        XCTAssertFalse(b.system.contains(Templates.render("skeleton.opening", ["charName": "林", "userName": "小于"], settings: .load())
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(b.system.contains("2 to 4"))
        XCTAssertFalse(b.system.contains("[对方是谁]"))
        XCTAssertTrue(b.messages.contains { $0.content.contains("[对方是谁]") })
    }

    /// 本轮相关记忆深度填 0：留在设定区，不丢。
    func testRecallDepthZeroStaysInSystem() throws {
        try importFixture("data.json")
        try setSettings(["memoryDepth": .number(0), "memoryRecent": .number(0)])
        let b = try build()
        if !b.recalled.isEmpty {
            XCTAssertTrue(b.system.contains("[相关记忆]"))
            XCTAssertFalse(b.messages.contains { $0.content.contains("[相关记忆]") })
        }
    }

    // MARK: - 预设

    /// 没有 presets 时当作只有「默认」，且读的时候不往库里写。
    func testDefaultPresetNotWritten() throws {
        let s = AppSettings(raw: [:])
        XCTAssertEqual(Presets.list(s).map(\.id), ["default"])
        XCTAssertEqual(Presets.activeId(s), "default")
        XCTAssertNil(s.raw["presets"])
    }

    /// 复制、改另一套、切换全局：改的是各自的快照，切换时现在那一套存回去、新的那套铺上来。
    func testDuplicatePatchActivate() throws {
        var s = AppSettings(raw: ["msgMin": .number(2), "msgMax": .number(4), "theme": .string("dark")])
        let copy = Presets.duplicate(&s)
        XCTAssertEqual(Presets.list(s).count, 2)
        XCTAssertEqual(Presets.activeId(s), "default")

        // 改副本：设置本身不变
        Presets.patch(&s, copy, ["msgMax": .number(7), "theme": .string("light")])
        XCTAssertEqual(s.raw["msgMax"]?.number, 4)
        XCTAssertEqual(Presets.values(s, copy).raw["msgMax"]?.number, 7)
        // 不是预设里的键不收
        XCTAssertEqual(Presets.values(s, copy).raw["theme"]?.string, "dark")

        // 切过去：设置换成副本的值，原来那套存回快照
        Presets.activate(&s, copy)
        XCTAssertEqual(Presets.activeId(s), copy)
        XCTAssertEqual(s.raw["msgMax"]?.number, 7)
        XCTAssertEqual(Presets.values(s, "default").raw["msgMax"]?.number, 4)

        // 全局那一套不能删；只剩一套不能删
        XCTAssertThrowsError(try Presets.remove(&s, copy))
        try Presets.remove(&s, "default")
        XCTAssertEqual(Presets.list(s).map(\.id), [copy])
        XCTAssertThrowsError(try Presets.remove(&s, copy))
    }

    /// 会话选了别的一套：只在拼这段会话时叠上去。
    func testChatUsesItsPreset() throws {
        try importFixture("data.json")
        var s = try AppSettings.loadForWrite()
        let copy = Presets.duplicate(&s)
        Presets.patch(&s, copy, ["msgMin": .number(5), "msgMax": .number(6)])
        try s.save()
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        chat.row["presetId"] = .string(copy)
        try Repo.save(chat)
        XCTAssertTrue(try build().system.contains("5 to 6"))

        // 删掉那一套：会话改回跟随全局
        var s2 = try AppSettings.loadForWrite()
        try Presets.remove(&s2, copy)
        try s2.save()
        try Presets.releaseChats(copy)
        XCTAssertEqual(try Repo.chat("chat_a")?.presetId, "")
    }

    /// 组里的先后改了，数据组按新的 injectOrder 排。
    func testInjectOrderMovesGroups() {
        let s = AppSettings(raw: ["injectOrder": .array(["character", "lorebook", "user"].map { .string($0) })])
        let ids = Layout.resolve("chat", s).map(\.id)
        XCTAssertLessThan(ids.firstIndex(of: "grp:char")!, ids.firstIndex(of: "grp:loreBefore")!)
    }

    func testBanList() {
        XCTAssertEqual(Ban.list(AppSettings(raw: ["banPhrases": .string("a b\n\n a b \n把*揉")])), ["a b", "把*揉"])
        XCTAssertTrue(Ban.tooBroad("把*"))
        XCTAssertFalse(Ban.tooBroad("把*揉"))
        // 星号代替最多十二个字；空白可有可无；英文不分大小写
        XCTAssertEqual(Ban.scan("把她整个人揉进骨血里", ["把*揉进骨血里"]), ["把*揉进骨血里"])
        XCTAssertEqual(Ban.scan("把这一段远远超过十二个字的内容全部揉进骨血里", ["把*揉进骨血里"]), [])
        XCTAssertEqual(Ban.scan("屋里空气中弥漫着咖啡香", ["空气中 弥漫着"]), ["空气中 弥漫着"])
        XCTAssertEqual(Ban.scan("A Chill ran down", ["a chill"]), ["a chill"])
        XCTAssertEqual(Ban.scan("空气里弥漫着", ["空气中弥漫着"]), [])
    }

    /// 角色的回复命中禁写词：那一条带上记号。
    func testBanMarkedOnReply() async throws {
        try importFixture("data.json")
        try setSettings(["banPhrases": .array([.string("不易察觉")]),
                         "services": .object(["chat": .object(["presets": .array([.object(["id": .string("p"), "provider": .string("anthropic"),
                            "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])])])])])
        URLProtocol.registerClass(MockNet.self)
        defer { URLProtocol.unregisterClass(MockNet.self) }
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("他露出不易察觉的笑\n好")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let list = try Repo.messages(chatId: "chat_a")
        XCTAssertEqual(list.first { $0.content.contains("不易察觉") }?.row["ban"]?.array?.first?.string, "不易察觉")
        XCTAssertNil(list.last?.row["ban"])
        XCTAssertTrue(try build().system.contains("不易察觉"))
    }
}
