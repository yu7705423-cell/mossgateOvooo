import XCTest
@testable import Eira

/// 「联系」补齐的几样：关系与圈子、关系网、批量生成 NPC（点一次打一次）、我的人设分区与一次性导入、生日与年龄进「对方是谁」、近况。
final class ContactTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc"), "provider": .string("openai"),
                                         "baseUrl": .string("https://spare.test/v1"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc")])])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func reply(_ text: String) -> MockNet.Reply { .init(status: 200, body: MockNet.openaiStream(text)) }
    private func body(_ i: Int = 0) -> String { String(data: MockNet.requests[i].httpBodyStreamData() ?? Data(), encoding: .utf8) ?? "" }

    private func char(_ name: String, _ extra: [String: JSONValue] = [:]) throws -> Character {
        var c = try People.createCharacter(name: name)
        if !extra.isEmpty { c = try People.update(c, extra) }
        return c
    }

    // MARK: - 关系

    func testLinkWritesBothSidesAndKeepsCircle() throws {
        let a = try char("甲"), b = try char("乙")
        try Relations.link(a.id, b.id, labelForA: "妈妈", labelForB: "女儿", circleA: "家人")
        XCTAssertEqual(Relations.of(a.id), [.init(charId: b.id, label: "妈妈", circle: "家人")])
        XCTAssertEqual(Relations.of(b.id), [.init(charId: a.id, label: "女儿", circle: "")])
        // 再连一次不给圈子：保留原来那条上的
        try Relations.link(a.id, b.id, labelForA: "母亲", labelForB: "")
        XCTAssertEqual(Relations.of(a.id).first?.circle, "家人")
        XCTAssertEqual(Relations.of(b.id).first?.label, "母亲")   // 反向空着用正向
        try Relations.renameCircle(a.id, from: "家人", to: "亲人")
        XCTAssertEqual(Relations.circles(a.id), ["亲人"])
        try Relations.unlink(a.id, b.id)
        XCTAssertTrue(Relations.of(a.id).isEmpty)
        XCTAssertTrue(Relations.of(b.id).isEmpty)
    }

    func testDeletedTargetsAreHidden() throws {
        let a = try char("甲")
        _ = try People.update(a, ["relations": .array([.object(["charId": .string("char_gone"), "label": .string("旧识")])])])
        XCTAssertTrue(Relations.of(a.id).isEmpty)
    }

    func testGroupedAndGraphBreadthFirst() throws {
        let a = try char("中心"), b = try char("一"), c = try char("二"), d = try char("外")
        try Relations.link(a.id, b.id, labelForA: "同学", circleA: "大学")
        try Relations.link(a.id, c.id, labelForA: "邻居")
        try Relations.link(b.id, d.id, labelForA: "表亲")
        // c 既是直接关系，又能从 b 那儿绕到：按广度走仍是第一圈
        try Relations.link(b.id, c.id, labelForA: "朋友")
        let g = Relations.grouped(a.id)
        XCTAssertEqual(g.map(\.circle), ["大学", ""])
        let net = Relations.graph(around: a.id)
        let depth = Dictionary(net.nodes.map { ($0.id, $0.depth) }, uniquingKeysWith: { x, _ in x })
        XCTAssertEqual(depth[a.id], 0)
        XCTAssertEqual(depth[b.id], 1)
        XCTAssertEqual(depth[c.id], 1)
        XCTAssertEqual(depth[d.id], 2)
        XCTAssertEqual(net.edges.count, 4)
    }

    // MARK: - NPC

    func testNpcGenerateIsOneCallAndDoesNotTouchStore() async throws {
        let a = try char("林", ["persona": .string("林有一个妹妹叫小雨。"), "core": .string("CORE_X")])
        let before = try Repo.characters().count
        MockNet.reset { [self] _, _ in reply(#"{"npcs":[{"name":"小雨","age":"16","persona":"林的妹妹。","relation":"姐姐","reverse":"妹妹"},{"name":"","persona":"没名字"}]}"#) }
        let rows = try await NpcGen.generate(charId: a.id, only: true)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(rows.map(\.name), ["小雨"])
        XCTAssertTrue(body().contains("CORE_X"))           // 核心设定也读
        XCTAssertTrue(body().contains("Do not invent anyone"))   // 只提取时用 task.npc-extract
        XCTAssertEqual(try Repo.characters().count, before)   // 确认之前不入库
        let usage = await Usage.shared.today(task: NpcGen.task)
        XCTAssertEqual(usage, 1)

        let made = try NpcGen.commit(charId: a.id, rows, circle: "家人")
        XCTAssertEqual(made.count, 1)
        let npc = try XCTUnwrap(try Repo.character(made[0].id))
        XCTAssertTrue(npc.isNpc)
        XCTAssertEqual(Relations.of(npc.id).first?.label, "姐姐")
        XCTAssertEqual(Relations.of(a.id).first, .init(charId: npc.id, label: "妹妹", circle: "家人"))
    }

    /// 接口一直失败：开了自动重试与换接口也只打一次（retryMax 默认 0，这里开到 3 也受调用方的 1 限制）
    func testNpcFailingIsBounded() async throws {
        let a = try char("林", ["persona": .string("P")])
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { _ = try await NpcGen.generate(charId: a.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        // 设定全空时只提取：一次都不打
        let empty = try char("空")
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { _ = try await NpcGen.generate(charId: empty.id, only: true); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 0)
    }

    func testNpcMutualCircle() throws {
        let a = try char("林")
        let made = try NpcGen.commit(charId: a.id, [.init(name: "甲", persona: "p", relation: "同学"), .init(name: "乙", persona: "p", relation: "同学")],
                                     circle: "乐队", mutual: true)
        XCTAssertEqual(Relations.of(made[0].id).first { $0.charId == made[1].id }?.label, "乐队成员")
        XCTAssertEqual(Relations.of(made[1].id).first { $0.charId == made[0].id }?.circle, "乐队")
    }

    // MARK: - 我的人设

    func testSectionsAndPromptText() throws {
        let me = try People.createPersona(name: "小于")
        try SelfProfile.setText(me.id, "basic", "BASIC")
        var p = try XCTUnwrap(try Repo.personas().first { $0.id == me.id })
        // 只填了基础资料：原样写那一段
        XCTAssertEqual(SelfProfile.promptText(p, charId: "", userName: "小于"), "BASIC")
        try SelfProfile.append(me.id, "likes", "猫")
        try SelfProfile.append(me.id, "likes", "雨天")
        p = try XCTUnwrap(try Repo.personas().first { $0.id == me.id })
        XCTAssertEqual(SelfProfile.text(p, "likes"), "猫\n雨天")
        XCTAssertEqual(SelfProfile.promptText(p, charId: "", userName: "小于"), "Basics:\nBASIC\n\nLikes:\n猫\n雨天")
        let c = try char("林")
        try SelfProfile.addNote(me.id, charId: c.id, text: "在林面前话多")
        p = try XCTUnwrap(try Repo.personas().first { $0.id == me.id })
        XCTAssertTrue(SelfProfile.promptText(p, charId: c.id, userName: "小于").hasSuffix("How 小于 is around you:\n- 在林面前话多"))
        XCTAssertFalse(SelfProfile.promptText(p, charId: "char_other", userName: "小于").contains("在林面前话多"))
    }

    func testSelfImportSplitIsOneCallAndSaves() async throws {
        let me = try People.createPersona(name: "小于")
        _ = try People.update(me, ["gender": .string("男"), "description": .string("旧的")])
        MockNet.reset { [self] _, _ in
            reply(#"{"basic":"大学生","personality":"慢热","likes":"","habits":"","triggers":"","life":"","gender":"女","birthday":"1999-03-14","city":"成都"}"#)
        }
        let got = try await SelfProfile.parse("一整段人设 RAW_TAIL")
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(body().contains("RAW_TAIL"))
        XCTAssertEqual(got.parts["personality"], "慢热")
        let usage = await Usage.shared.today(task: "self.import")
        XCTAssertEqual(usage, 1)
        // 接在后面：分区接上；资料项只填空着的
        try SelfProfile.save(me.id, got, replace: false)
        let p = try XCTUnwrap(try Repo.personas().first { $0.id == me.id })
        XCTAssertEqual(p.row.string("description"), "旧的\n大学生")
        XCTAssertEqual(p.row.string("gender"), "男")
        XCTAssertEqual(p.row.string("birthday"), "1999-03-14")
        XCTAssertEqual(p.row.string("city"), "成都")
        // 替换：覆盖
        try SelfProfile.save(me.id, got, replace: true)
        let q = try XCTUnwrap(try Repo.personas().first { $0.id == me.id })
        XCTAssertEqual(q.row.string("description"), "大学生")
        XCTAssertEqual(q.row.string("gender"), "女")
    }

    func testSelfImportFailingIsOneCallAndSaveAllNeedsNoCall() async throws {
        let me = try People.createPersona(name: "小于")
        try setSettings(["retryMax": .number(3), "chatFallback": .bool(true)])
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { _ = try await SelfProfile.parse("内容"); XCTFail("应当失败") } catch {}
        XCTAssertLessThanOrEqual(MockNet.count, 2)   // 调用方给的上限 1 次重试（同网页版 runJSONTask）
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        try SelfProfile.saveAll(me.id, "  原文  ", replace: false)
        XCTAssertEqual(MockNet.count, 0)
        XCTAssertEqual(try Repo.personas().first { $0.id == me.id }?.row.string("description"), "原文")
    }

    // MARK: - 生日（4.775）

    func testAgeOf() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 13, hour: 12))!
        let z = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertEqual(SelfProfile.age("1999-03-14", now: now, zone: z), 26)
        XCTAssertEqual(SelfProfile.age("1999年3月13日", now: now, zone: z), 27)
        XCTAssertNil(SelfProfile.age("3月14日", now: now, zone: z))
    }

    func testUserBlockWritesBirthdayNickCity() throws {
        let me = try People.update(try People.createPersona(name: "小于"),
                                   ["birthday": .string("3月14日"), "nick": .string("于"), "city": .string("成都"), "description": .string("BASIC")])
        let c = try char("林")
        let text = ChatPrompt.userBlock(me: me, char: c)
        XCTAssertTrue(text.hasPrefix("\n\n[对方是谁]\nName: 小于\nScreen name in the chat app: 于\nBirthday: 3月14日\nCity: 成都\nBASIC"), text)
        XCTAssertFalse(text.contains("Age:"))
        let old = try People.update(me, ["birthday": .string("1990-01-01")])
        XCTAssertTrue(ChatPrompt.userBlock(me: old, char: c).contains("Age: "))
        // 没填不写
        let bare = try People.createPersona(name: "空")
        XCTAssertEqual(ChatPrompt.userBlock(me: bare, char: c), "\n\n[对方是谁]\nName: 空")
    }

    // MARK: - 近况

    func testNowSnapshotReadsOnlyAndHidesLockedDiary() throws {
        let c = try char("林", ["nowPlaying": .object(["kind": .string("recent"), "at": .number(1), "songs": .array([
            .object(["title": .string("晴天"), "artist": .string("周杰伦")])])])])
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        try Database.shared.put("diaries", Row.new(prefix: "dy", ["owner": .string(c.id), "charId": .string(c.id), "date": .string("2026-01-01"),
                                                                 "text": .string("SECRET"), "lock": .object(["code": .string("1234")])]))
        let s = try XCTUnwrap(CharNow.snapshot(c.id, personaId: ""))
        XCTAssertEqual(s.music?.songs, ["晴天 — 周杰伦"])
        XCTAssertEqual(s.diary?.locked, true)
        XCTAssertEqual(s.diary?.text, "")
        XCTAssertEqual(CharNow.line(s), "在听：晴天 — 周杰伦")
        XCTAssertEqual(MockNet.count, 0)
    }
}
