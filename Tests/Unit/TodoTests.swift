import XCTest
@testable import Eira

/// 待办（网页版 todo.js、when.js、alarm.js、context/plan.js）：线索词识别、「明天七点」的折算、待确认的两道监督、
/// [待办：…] 标记、按天的任务、[你记着的事] 区块、导入导出不丢字段、一次回复仍只调一次接口
final class TodoTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    /// 本机时区里的一个时刻
    private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    // MARK: - 线索词

    func testDetect() {
        XCTAssertEqual(Todo.detect("我想去看那个展，明天有空吗")?.text, "我想去看那个展")
        XCTAssertEqual(Todo.detect("我想去看那个展，明天有空吗")?.cue, "我想")
        XCTAssertNil(Todo.detect("我想你了"))
        XCTAssertNil(Todo.detect("我想"))
        XCTAssertNil(Todo.detect("今天天气很好"))
        XCTAssertEqual(Todo.detect("回头记得提醒我交房租")?.text, "记得提醒我交房租")
        // 用户自己那一份：删光等于关掉
        XCTAssertNil(Todo.detect("我想去看展", cues: [], skips: []))
        XCTAssertEqual(Todo.detect("周末逛超市", cues: ["逛"], skips: [])?.text, "逛超市")
    }

    func testCueSettings() throws {
        XCTAssertTrue(Todo.localOn())
        XCTAssertEqual(Todo.cues(), Todo.defaultCues)
        try setSettings(["todoCues": .array([])])
        XCTAssertFalse(Todo.localOn())
        try setSettings(["todoCues": .array([.string(" 逛 "), .string("")]), "todoDetect": .bool(true)])
        XCTAssertEqual(Todo.cues(), ["逛"])
        try setSettings(["todoDetect": .bool(false)])
        XCTAssertFalse(Todo.localOn())
        try setSettings(["todoCues": .null])
        XCTAssertEqual(Todo.cues(), Todo.defaultCues)
    }

    // MARK: - 明天七点

    func testCnNum() {
        XCTAssertEqual(When.cnNum("七"), 7)
        XCTAssertEqual(When.cnNum("十"), 10)
        XCTAssertEqual(When.cnNum("十三"), 13)
        XCTAssertEqual(When.cnNum("二十三"), 23)
        XCTAssertEqual(When.cnNum("两"), 2)
        XCTAssertEqual(When.cnNum("19"), 19)
        XCTAssertNil(When.cnNum("一百"))
        XCTAssertNil(When.cnNum(""))
    }

    func testWhenParse() throws {
        // 2026-09-29 是周二，晚上八点
        let now = local(2026, 9, 29, 20, 0)
        let a = try XCTUnwrap(When.parse("明天七点叫我起床", now: now))
        XCTAssertEqual(a.at, local(2026, 9, 30, 7, 0).millis)
        XCTAssertTrue(a.hasTime)
        XCTAssertEqual(a.hit, "明天七点")
        // 只说点钟、今天已经过了：明天
        XCTAssertEqual(When.parse("七点", now: now)?.at, local(2026, 9, 30, 7, 0).millis)
        XCTAssertEqual(When.parse("后天下午三点半", now: now)?.at, local(2026, 10, 1, 15, 30).millis)
        XCTAssertEqual(When.parse("晚上十一点", now: now)?.at, local(2026, 9, 29, 23, 0).millis)
        XCTAssertEqual(When.parse("十九点一刻", now: now)?.at, local(2026, 9, 30, 19, 15).millis)
        XCTAssertEqual(When.parse("周四上午十点", now: now)?.at, local(2026, 10, 1, 10, 0).millis)
        XCTAssertEqual(When.parse("下周四 7:30", now: now)?.at, local(2026, 10, 8, 7, 30).millis)
        XCTAssertEqual(When.parse("3天后中午", now: now)?.at, local(2026, 10, 2, 12, 0).millis)
        XCTAssertEqual(When.parse("10月3日 8点", now: now)?.at, local(2026, 10, 3, 8, 0).millis)
        // 月份已经过去：明年那一次
        XCTAssertEqual(When.parse("3月1号九点", now: now)?.at, local(2027, 3, 1, 9, 0).millis)
        // 只认出日子，没有点钟
        let d = try XCTUnwrap(When.parse("我想说今天天气不错", now: now))
        XCTAssertFalse(d.hasTime)
        XCTAssertNil(When.parse("随便聊聊", now: now))
        XCTAssertNil(When.parse("二十五点", now: now))
        XCTAssertEqual(When.show(local(2026, 9, 30, 7, 0).millis, now: now), "明天 07:00")
        XCTAssertEqual(When.show(local(2026, 10, 5, 9, 5).millis, now: now), "2026-10-05 09:05")
    }

    // MARK: - 两道监督

    func testProposeAndAttachTime() throws {
        let now = Date()
        let a = try XCTUnwrap(Todo.propose(text: "去看那个展", chatId: "chat_a", charId: "char_a", from: Todo.fromChar, now: now))
        XCTAssertEqual(a.state, Todo.pending)
        XCTAssertEqual(a.remindAt, 0)
        XCTAssertEqual(a.row["dueAt"], .string(""))
        // 同一句不问第二遍，忽略过的也算
        try Todo.ignore(a.id)
        XCTAssertNil(try Todo.propose(text: "去看那个展", chatId: "chat_a"))
        XCTAssertEqual(try Todo.clearDropped(), 1)
        XCTAssertNotNil(try Todo.propose(text: "去看那个展", chatId: "chat_a"))
        // 时刻在前面几句里
        let b = try XCTUnwrap(Todo.propose(text: "叫我起来跑步", chatId: "chat_a", near: ["明天七点", "嗯"], now: now))
        XCTAssertGreaterThan(b.remindAt, now.millis)
        // 先说了事、后补时刻：补给最近那一条还没挂时刻的
        let c = try XCTUnwrap(Todo.propose(text: "记得买牛奶", chatId: "chat_b"))
        XCTAssertEqual(c.remindAt, 0)
        let got = try XCTUnwrap(Todo.attachTime(chatId: "chat_b", text: "明天七点"))
        XCTAssertEqual(got.id, c.id)
        XCTAssertGreaterThan(got.remindAt, now.millis)
        // 计入之后才算；等确认的不进 openOnes
        XCTAssertTrue(Todo.openOnes().isEmpty)
        try Todo.accept(c.id)
        XCTAssertEqual(Todo.openOnes().map(\.id), [c.id])
        XCTAssertEqual(Todo.pendingOf("chat_b").count, 0)
    }

    /// 用户发出去的那一句走本地这一道：不调接口，落成待确认
    func testUserSendDetects() throws {
        let m = try ChatEngine.send(text: "我打算周末把房间收拾一下", chatId: "chat_a")
        let p = Todo.pendingOf("chat_a")
        XCTAssertEqual(p.map(\.text), ["我打算周末把房间收拾一下"])
        XCTAssertEqual(p.first?.from, Todo.fromLocal)
        XCTAssertEqual(p.first?.srcMsgId, m.id)
        XCTAssertEqual(p.first?.charId, "char_a")
        _ = try ChatEngine.send(text: "明天下午三点", chatId: "chat_a")
        XCTAssertGreaterThan(try XCTUnwrap(Todo.pendingOf("chat_a").first).remindAt, 0)
        try setSettings(["todoDetect": .bool(false)])
        _ = try ChatEngine.send(text: "我想去买花", chatId: "chat_a")
        XCTAssertEqual(Todo.pendingOf("chat_a").count, 1)
        XCTAssertEqual(MockNet.count, 0)
    }

    // MARK: - [待办：…]

    func testReplyMarker() throws {
        let r = ReplyParser.split("好的\n[待办：周末去买菜]\n记住了", autoSplitAt: 0)
        XCTAssertEqual(r.parts.map(\.type), [.text, .todo, .text])
        XCTAssertEqual(r.parts[1].text, "周末去买菜")
        XCTAssertEqual(ReplyParser.split("【todo: buy milk】", autoSplitAt: 0).parts.map(\.type), [.todo])
        let (parts, unmapped) = WebLogic.map([["type": "todo", "text": "周末去买菜"]])
        XCTAssertEqual(parts.first?.type, .todo)
        XCTAssertEqual(parts.first?.text, "周末去买菜")
        XCTAssertEqual(unmapped, [])
    }

    /// 角色写的待办不占气泡，落成待确认；这一轮仍只打一次接口（不进 ExtraCalls）
    func testMarkerInReplyOneRequest() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("好\n[待办：周六去医院复查]")) }
        let before = try Repo.messages(chatId: "chat_a").count
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        let after = try Repo.messages(chatId: "chat_a")
        XCTAssertEqual(after.count, before + 1)
        XCTAssertFalse(after.contains { $0.content.contains("待办") })
        let p = try XCTUnwrap(Todo.pendingOf("chat_a").first)
        XCTAssertEqual(p.text, "周六去医院复查")
        XCTAssertEqual(p.from, Todo.fromChar)
        XCTAssertEqual(p.charId, "char_a")
    }

    func testOneReplyStillOneRequestWithTodosOpen() async throws {
        try Todo.addMine("交房租", ["remindAt": .number(Date().millis + 3_600_000)])
        _ = try ChatEngine.send(text: "我想明天去跑步", chatId: "chat_a")
        do { try await ChatEngine.reply(chatId: "chat_a") { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        // 到点的提醒是本机的事，不调接口
        _ = TodoAlarm.beat(now: Date().addingTimeInterval(7200)) { _ in }
        XCTAssertEqual(MockNet.count, 1)
    }

    // MARK: - 按天

    func testWeeklyTasks() throws {
        // 2026-09-28 是周一
        let r = try XCTUnwrap(Todo.addMine("晨跑", ["repeat": .string(Todo.weekly), "weekdays": .array([.number(1), .number(3)]),
                                                    "from": .string("2026-09-01"), "time": .string("07:00")]))
        XCTAssertEqual(Todo.repeatText(r), "每周一、三")
        XCTAssertTrue(Todo.onDay(r, "2026-09-28"))
        XCTAssertFalse(Todo.onDay(r, "2026-09-29"))
        XCTAssertFalse(Todo.onDay(r, "2026-08-31"))
        XCTAssertEqual(Todo.tasksOn("2026-09-30").map(\.time), ["07:00"])
        try Todo.toggleOn(r.id, "2026-09-28")
        let x = try XCTUnwrap(Todo.get(r.id))
        XCTAssertTrue(Todo.doneOn(x, "2026-09-28"))
        XCTAssertFalse(Todo.doneOn(x, "2026-09-30"))
        XCTAssertEqual(x.state, Todo.open)
        // 来源字段里不是日期（从待办页设的重复）：不当开始日期
        let y = try XCTUnwrap(Todo.addMine("浇花", ["repeat": .string(Todo.weekly), "weekdays": .array([.number(2)]), "createdAt": .number(1)]))
        XCTAssertEqual(y.from, Todo.fromMe)
        XCTAssertTrue(Todo.onDay(y, "2026-09-29"))
        // 不重复的：dueAt，没写看提醒落在哪天
        let z = try XCTUnwrap(Todo.addMine("寄快递", ["dueAt": .string("2026-09-29"), "createdAt": .number(2)]))
        XCTAssertTrue(Todo.onDay(z, "2026-09-29"))
        let w = try XCTUnwrap(Todo.addMine("开会", ["remindAt": .number(local(2026, 9, 29, 14, 30).millis), "createdAt": .number(3)]))
        XCTAssertEqual(Todo.timeOf(w, "2026-09-29"), "14:30")
        XCTAssertEqual(Todo.tasksOn("2026-09-29").map(\.row.text), ["开会", "浇花", "寄快递"])
        try Todo.toggleOn(z.id, "2026-09-29")
        XCTAssertEqual(Todo.get(z.id)?.state, Todo.done)
        XCTAssertGreaterThan(try XCTUnwrap(Todo.get(z.id)).doneAt, 0)
    }

    func testUserSchedListsTasks() throws {
        let s = AppSettings.load()
        let today = UserSched.today(s, at: Date()).key
        XCTAssertEqual(UserSched.textFor(UserSched.ownerOf(""), back: 0, ahead: 0, settings: s), "")
        try Todo.addMine("取快递", ["dueAt": .string(today)])
        let text = UserSched.textFor(UserSched.ownerOf(""), back: 0, ahead: 0, settings: s)
        XCTAssertTrue(text.contains("- Any time Task: 取快递 (not done)"), text)
    }

    // MARK: - [你记着的事]

    func testPlanBlock() throws {
        let s0 = AppSettings.load()
        XCTAssertEqual(Todo.planBlock(userName: "小于", settings: s0), "")
        let now = Date()
        try Todo.addMine("没排时间的")
        try Todo.addMine("后面那件", ["remindAt": .number(now.millis + 2 * 86_400_000)])
        try Todo.addMine("先到的", ["remindAt": .number(now.millis + 3_600_000)])
        try Todo.addMine("每周的", ["repeat": .string(Todo.weekly), "weekdays": .array([.number(1)])])
        try Todo.propose(text: "还没确认的", chatId: "chat_a")
        let b = Todo.planBlock(userName: "小于", settings: s0, now: now)
        let lines = b.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "[你记着的事]")
        XCTAssertTrue(lines[1].hasSuffix("\u{3000}先到的"), b)
        XCTAssertTrue(lines[2].hasSuffix("\u{3000}后面那件"), b)
        XCTAssertEqual(lines[3], "没排时间的")
        XCTAssertEqual(lines.last, "These are things 小于 has said they intend to do. They have not been done yet.")
        XCTAssertFalse(b.contains("每周的"))
        XCTAssertFalse(b.contains("还没确认的"))
        try setSettings(["planCount": .number(1)])
        XCTAssertEqual(Todo.planBlock(userName: "", settings: .load(), now: now).components(separatedBy: "\n").count, 3)
        XCTAssertTrue(Todo.planBlock(userName: "", settings: .load(), now: now).contains("These are things 对方 "))
    }

    func testPromptCarriesPlanAndCap() throws {
        try Todo.addMine("十五号去上海")
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        let b = try ChatPrompt.build(chat: chat, char: char, settings: .load())
        let all = ([b.system] + b.messages.map(\.content)).joined(separator: "\n")
        XCTAssertTrue(all.contains("[你记着的事]\n十五号去上海"), all)
        XCTAssertTrue(b.system.contains("[待办：the thing"), b.system)
        // 全局关掉、角色卡关掉，都不再告诉模型
        try setSettings(["capsOff": .array([.string("todo")])])
        XCTAssertFalse(try ChatPrompt.build(chat: chat, char: char, settings: .load()).system.contains("[待办："))
        XCTAssertTrue(NewFeat.known(cap: "todo"))
        XCTAssertTrue(NewFeat.known(block: "plan"))
    }

    // MARK: - 提醒

    func testAlarmBookkeeping() throws {
        let now = Date()
        let a = try XCTUnwrap(Todo.addMine("吃药", ["remindAt": .number(now.millis - 1000)]))
        let b = try XCTUnwrap(Todo.addMine("排了的", ["remindAt": .number(now.millis - 1000), "alarmId": .string("todo-x"), "alarmAt": .number(now.millis - 1000)]))
        try Todo.addMine("还早", ["remindAt": .number(now.millis + 600_000)])
        var rung: [String] = []
        XCTAssertEqual(TodoAlarm.beat(now: now) { rung.append($0.id) }, 1)
        XCTAssertEqual(rung, [a.id])
        // 只响一次
        XCTAssertEqual(TodoAlarm.beat(now: now) { rung.append($0.id) }, 0)
        XCTAssertGreaterThan(try XCTUnwrap(Todo.get(b.id)).rungAt, 0)
        XCTAssertEqual(TodoAlarm.upcoming(now: now).map(\.text), ["还早"])
        XCTAssertFalse(TodoAlarm.stale(try XCTUnwrap(Todo.get(b.id))))
        try Todo.update(b.id, ["remindAt": .number(now.millis + 5000)])
        XCTAssertTrue(TodoAlarm.stale(try XCTUnwrap(Todo.get(b.id))))
        XCTAssertEqual(TodoAlarm.reconcile(["todo-x"]).map(\.known), [true])
        XCTAssertEqual(TodoAlarm.reconcile([]).map(\.known), [false])
    }

    // MARK: - 网页版的数据

    func testWebBackupRoundTrip() throws {
        // 网页版备份里的一条待办与一条备忘，带着原生版不认识的字段
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture("data.json"))) as? [String: Any])
        obj["todos"] = [["id": "td_web1", "text": "网页版的待办", "state": "open", "from": "char", "chatId": "chat_a", "charId": "char_a",
                         "srcMsgId": "", "dueAt": "2026-10-01", "remindAt": "", "createdAt": 1_760_000_000_000, "updatedAt": 1_760_000_000_000,
                         "fitSched": "2026-10-01", "webOnly": ["keep": true]],
                        ["id": "td_web2", "text": "每周的", "state": "open", "from": "2026-09-01", "repeat": "weekly", "weekdays": [1, 3],
                         "doneDates": ["2026-09-28"], "createdAt": 1_760_000_000_001]]
        obj["notes"] = [["id": "nt_web1", "text": "第一行\n第二行", "from": "chat", "chatId": "chat_a", "charId": "char_a",
                         "createdAt": 1_760_000_000_000, "updatedAt": 1_760_000_000_000]]
        let src = root.appendingPathComponent("web-todo.json")
        try JSONSerialization.data(withJSONObject: obj).write(to: src)
        try BackupImporter.run(file: src, password: "") { _ in }

        let t = try XCTUnwrap(Todo.get("td_web1"))
        XCTAssertEqual(t.text, "网页版的待办")
        XCTAssertEqual(t.remindAt, 0)
        XCTAssertEqual(Todo.fromLabel(t.from), "角色提出")
        XCTAssertTrue(Todo.onDay(t, "2026-10-01"))
        let w = try XCTUnwrap(Todo.get("td_web2"))
        XCTAssertTrue(w.isRepeat)
        XCTAssertTrue(Todo.doneOn(w, "2026-09-28"))
        XCTAssertFalse(Todo.onDay(w, "2026-08-31"))
        XCTAssertEqual(Notes.titleOf(try XCTUnwrap(Notes.get("nt_web1"))), "第一行")
        XCTAssertEqual(Notes.restOf(try XCTUnwrap(Notes.get("nt_web1"))), "第二行")

        // 在原生版里改过，再导出、导回去：改的在，不认识的字段也在
        try Todo.update("td_web1", ["text": .string("改过的待办")])
        try Todo.setState("td_web1", Todo.done)
        try Notes.update("nt_web1", text: "改过的备忘")
        let out = try BackupExporter.run(.init(media: false))
        Database.shared.close()
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Database.shared = try Database(url: root.appendingPathComponent("test.sqlite"))
        try BackupImporter.run(file: out.file, password: "") { _ in }
        let back = try XCTUnwrap(Todo.get("td_web1"))
        XCTAssertEqual(back.text, "改过的待办")
        XCTAssertEqual(back.state, Todo.done)
        XCTAssertEqual(back.row["webOnly"]?["keep"]?.bool, true)
        XCTAssertEqual(back.row.string("fitSched"), "2026-10-01")
        XCTAssertEqual(Notes.get("nt_web1")?.string("text"), "改过的备忘")
        XCTAssertEqual(Todo.get("td_web2")?.doneDates, ["2026-09-28"])
    }

    func testNotes() throws {
        let a = try Notes.add("买菜清单\n鸡蛋 牛奶")
        XCTAssertEqual(Notes.fromLabel(a.string("from")), "手动添加")
        XCTAssertEqual(Notes.titleOf(try Notes.add("")), "（空）")
        XCTAssertEqual(Notes.search("牛奶").map(\.id), [a.id])
        try Notes.remove(a.id)
        XCTAssertNil(Notes.get(a.id))
    }
}
