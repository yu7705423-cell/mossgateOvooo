import XCTest
@testable import Eira

/// 系统能力（网页版 4.895、4.896、4.941、4.104e）：Eira 推送的盒子解得开服务器封的、登记只打推送转发、通道交给服务器的样子；
/// 桌面组件的数据写进共用存储、点按取回记进健康；待办的系统闹钟与退回通知的记号。都不调模型。
final class SystemAbilityTests: StoreTestCase {
    private var suite = ""
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        suite = "eira-test-\(UUID().uuidString)"
        dir = root.appendingPathComponent("widgets", isDirectory: true)
        EiraPush.setRegistration(nil)
        TodoAlarm.testChannels = nil
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        UserDefaults.standard.removePersistentDomain(forName: suite)
        EiraPush.setRegistration(nil)
        BgPush.setDevice(nil)
        TodoAlarm.testChannels = nil
        try super.tearDownWithError()
    }

    private var store: WidgetStore { WidgetStore(defaults: UserDefaults(suiteName: suite), dir: dir) }

    // MARK: - Eira 推送的盒子

    /// 用 WebCrypto（与 worker/push.js 的 eiraBox 同一种写法）封的两个盒子：钥匙、iv、密文都是那边算出来的
    private let webKey = "AQgPFh0kKzI5QEdOVVxjanF4f4aNlJuiqbC3vsXM09o="
    private let webIv = "yMXCv7y5trOwraqn"
    private let webAlert = "URPxLVNXtnfUr0/6asztOzpCHpr3P1BHov3lDNH8Ad2/SccehPgaVs6swcHbewh1zsP4biDYG90="
    private let webRing = "URPmLVNXMK86MoszasztNzpCHprbGFxMnf3lDMT8AYuuVMMXsXSsCCbwc+bNIkjeW0eyQg=="

    func testOpensServerBoxes() {
        let a = PushBox.alert(PushBox.open(box: webAlert, iv: webIv, key: webKey))
        XCTAssertEqual(a, .init(title: "小雨", body: "在吗", chatId: "chat_a"))
        let r = PushBox.ring(PushBox.open(["box": webRing, "iv": webIv], key: webKey))
        XCTAssertEqual(r, .init(chatId: "chat_a", name: "小雨", video: true))
    }

    func testBadBoxesStayClosed() {
        let other = PushBox.newKey()
        XCTAssertNil(PushBox.open(box: webAlert, iv: webIv, key: other))
        XCTAssertNil(PushBox.open(box: String(webAlert.dropLast(8)), iv: webIv, key: webKey))
        XCTAssertNil(PushBox.open(box: webAlert, iv: "AAAA", key: webKey))
        XCTAssertNil(PushBox.open(["box": webAlert], key: webKey))
        XCTAssertNil(PushBox.open(["box": webAlert, "iv": webIv], key: nil))
        // 自己封的自己解得开
        let k = PushBox.newKey()
        let sealed = try! XCTUnwrap(PushBox.seal(["t": "甲", "b": "乙", "c": "chat_b"], key: k))
        XCTAssertEqual(PushBox.alert(PushBox.open(box: sealed.box, iv: sealed.iv, key: k))?.chatId, "chat_b")
        XCTAssertEqual(Data(base64Encoded: sealed.iv)?.count, 12)
    }

    func testKeyIsSharedWithExtension() {
        let k = EiraPush.key()
        XCTAssertEqual(Data(base64Encoded: k)?.count, 32)
        XCTAssertEqual(EiraPush.key(), k)
        XCTAssertEqual(PushBox.groupKey(), k)
    }

    // MARK: - 登记：只打推送转发

    func testSignBothHitsRelayOnly() async throws {
        MockNet.reset { req, _ in
            let body = (try? JSONSerialization.jsonObject(with: req.httpBodyStreamData() ?? Data())) as? [String: String] ?? [:]
            return .init(status: 200, body: #"{"cred":"c-\#(body["kind"] ?? "")-\#(body["token"] ?? "")"}"#)
        }
        let reg = try await EiraPush.signBoth(relay: "https://relay.test", alert: "aa11", voip: "bb22")
        XCTAssertEqual(MockNet.count, 2)
        XCTAssertTrue(MockNet.requests.allSatisfy { $0.url?.absoluteString == "https://relay.test/register" && $0.httpMethod == "POST" })
        XCTAssertEqual(reg.alert, .init(token: "aa11", cred: "c-alert-aa11"))
        XCTAssertEqual(reg.voip, .init(token: "bb22", cred: "c-voip-bb22"))
        // 没有来电推送的地址：只登记文字通知
        MockNet.reset { _, _ in .init(status: 200, body: #"{"cred":"x"}"#) }
        let one = try await EiraPush.signBoth(relay: "https://relay.test", alert: "aa11", voip: nil)
        XCTAssertNil(one.voip)
        XCTAssertEqual(MockNet.count, 1)
    }

    func testSignFailureSavesNothing() async throws {
        MockNet.reset { _, _ in .init(status: 403, body: #"{"error":"签名对不上"}"#) }
        do {
            _ = try await EiraPush.signBoth(relay: "https://relay.test", alert: "aa11", voip: "bb22")
            XCTFail("应当报错")
        } catch {
            XCTAssertEqual(error.localizedDescription, "签名对不上")
        }
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertNil(EiraPush.registration())
    }

    // MARK: - 交给服务器的通道

    func testChannelOut() throws {
        try importFixture("data.json")
        try setSettings(["bgPush": .object(["on": .bool(true), "server": .string("https://push.test"),
                                            "channel": .object(["kind": .string("eira")])])])
        // 选了却没登记：不交（服务器那边就关掉通道）
        XCTAssertEqual(BgPush.channelOut(), .null)
        EiraPush.setRegistration(.init(relay: "https://relay.test", alert: .init(token: "aa", cred: "ca"),
                                       voip: .init(token: "bb", cred: "cb"), at: 1))
        var ch = BgPush.channelOut()
        XCTAssertEqual(ch["kind"]?.string, "eira")
        XCTAssertEqual(ch["relay"]?.string, "https://relay.test")
        XCTAssertEqual(ch["key"]?.string, EiraPush.key())
        XCTAssertEqual(ch["alert"]?["cred"]?.string, "ca")
        XCTAssertEqual(ch["voip"]?["token"]?.string, "bb")
        XCTAssertEqual(ch["ring"]?.bool, false)
        XCTAssertEqual(ch["hide"]?.bool, false)
        // 系统来电界面开着才让服务器发来电推送；通知里不显示内容时 hide
        try setSettings(["callKit": .bool(true), "nativeNotifyText": .bool(false)])
        ch = BgPush.channelOut()
        XCTAssertEqual(ch["ring"]?.bool, true)
        XCTAssertEqual(ch["hide"]?.bool, true)
        // 换回别的通道：不再交 Eira 推送
        try setSettings(["bgPush": .object(["on": .bool(true), "channel": .object(["kind": .string("pushplus"), "token": .string("t")])])])
        XCTAssertEqual(BgPush.channelOut()["kind"]?.string, "pushplus")
        XCTAssertFalse(EiraPush.active())
        XCTAssertEqual(MockNet.count, 0)
    }

    /// 交给服务器的任务带着角色卡上能不能打电话（服务器据此决定发不发来电推送）
    func testJobsCarryCanCall() throws {
        UserDefaults.standard.removeObject(forKey: "phone.proactive.next")
        defer { UserDefaults.standard.removeObject(forKey: "phone.proactive.next") }
        try importFixture("data.json")
        var chat = try XCTUnwrap(Repo.chat("chat_a"))
        chat.row["unread"] = .number(0)
        chat.row["lastMessageAt"] = .number(0)
        try Repo.save(chat)
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])]),
                         "bgPush": .object(["on": .bool(true), "server": .string("https://push.test")])])
        var c = try XCTUnwrap(Repo.character("char_a"))
        c.row["proactive"] = .bool(true)
        c.row["proactiveMinutes"] = .number(60)
        c.row["proactiveQuietFrom"] = .number(0)
        c.row["proactiveQuietTo"] = .number(0)
        c.row["canCall"] = .bool(false)
        try Database.shared.put(Collections.characters, c.row)
        for m in try Repo.messages(chatId: "chat_a") {
            var row = m.row
            row["createdAt"] = .number(1_000_000)
            try Database.shared.put(Collections.messages, row)
        }
        let job = try XCTUnwrap(try BgPush.jobsNow().first { $0["charId"]?.string == "char_a" })
        XCTAssertEqual(job["canCall"]?.bool, false)
        XCTAssertEqual(MockNet.count, 0)
    }

    /// 选了 Eira 推送：后台刷新不再问服务器、不再弹本地通知（服务器自己推送）
    func testPeekSkipsWhenEiraPush() async throws {
        try importFixture("data.json")
        try setSettings(["nativeNotify": .bool(true),
                         "bgPush": .object(["on": .bool(true), "server": .string("https://push.test"),
                                            "channel": .object(["kind": .string("eira")])])])
        BgPush.setDevice(.init(server: "https://push.test", id: "d", token: "t", endpoint: ""))
        EiraPush.setRegistration(.init(relay: "https://relay.test", alert: .init(token: "aa", cred: "ca"), voip: nil, at: 1))
        let n = try await Notifier.peekResults()
        XCTAssertEqual(n, 0)
        XCTAssertEqual(MockNet.count, 0)
    }

    // MARK: - 桌面组件

    func testWidgetDataWritten() throws {
        try importFixture("data.json")
        try Diary.patchChar("char_a", ["dayOn": .bool(true)])
        let char = try XCTUnwrap(Repo.character("char_a"))
        let now = Date()
        let slot = DayPlan.slotNow(char, now)
        try DayPlan.save("char_a", date: DayPlan.dateKey(char, now), ["items": .array([
            .object(["slot": .string(slot.id), "text": .string("看书"), "state": .string(DayPlan.plan)]),
            .object(["slot": .string(slot.id), "text": .string("不去了"), "state": .string(DayPlan.drop)]),
        ])])
        try Health.addWater()
        try setSettings(["iosWidgetChar": .string("char_a")])
        XCTAssertTrue(WidgetFeed.sync(store: store, now: now))
        let w = try XCTUnwrap(store.readJSON(WidgetStore.charKey))
        XCTAssertEqual(w["name"] as? String, char.displayName)
        XCTAssertEqual(w["chatId"] as? String, "chat_a")
        let entries = try XCTUnwrap(w["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["text"] as? String, "看书")
        XCTAssertEqual(entries.first?["slot"] as? String, slot.label)
        // 一天半里时段一变就是一格，时间往后排
        XCTAssertGreaterThan(entries.count, 5)
        let ats = entries.compactMap { $0["at"] as? Double }
        XCTAssertEqual(ats, ats.sorted())
        let h = try XCTUnwrap(store.readJSON(WidgetStore.healthKey))
        XCTAssertEqual(h["date"] as? String, Health.dateKey())
        XCTAssertEqual(h["water"] as? Int, 1)
        XCTAssertEqual(MockNet.count, 0)
    }

    func testWidgetTapsLandInHealth() throws {
        try importFixture("data.json")
        try Health.saveMed(id: nil, name: "维生素", dose: "", times: ["00:00"], note: "", active: true)
        XCTAssertTrue(WidgetFeed.sync(store: store))
        store.record("water")
        store.record("water")
        store.record("poop")
        store.record("med")
        store.record("med")   // 只有一样药：第二下不再记
        store.record("bogus")
        // 组件这边先把数字加上
        let h = try XCTUnwrap(store.readJSON(WidgetStore.healthKey))
        XCTAssertEqual(h["water"] as? Int, 2)
        XCTAssertEqual(h["medTaken"] as? Int, 1)
        XCTAssertEqual(WidgetFeed.drain(store: store), 4)
        let d = Health.day(Health.me)
        XCTAssertEqual(d.water, 2)
        XCTAssertEqual(d.poops.count, 1)
        XCTAssertEqual(d.took.count, 1)
        // 取完清空，再取一次什么都不记
        XCTAssertEqual(WidgetFeed.drain(store: store), 0)
        XCTAssertEqual(Health.day(Health.me).water, 2)
    }

    func testWidgetFileNames() {
        XCTAssertTrue(WidgetStore.okName("char-avatar.img"))
        XCTAssertFalse(WidgetStore.okName("../x"))
        XCTAssertFalse(WidgetStore.okName("a/b"))
        XCTAssertThrowsError(try store.writeImage("../x", Data([1])))
    }

    func testDeepLinks() {
        XCTAssertEqual(DeepLink.parse(URL(string: "eiraowo://chat/chat_a")!), .chat("chat_a"))
        XCTAssertEqual(DeepLink.parse(URL(string: "eiraowo://open?app=health")!), .app("health"))
        XCTAssertEqual(DeepLink.parse(URL(string: "eiraowo://open")!), .home)
        XCTAssertEqual(DeepLink.parse(URL(string: "eiraowo://widget/water")!), .widgetTap("water"))
        XCTAssertNil(DeepLink.parse(URL(string: "eiraowo://widget/rm")!))
        XCTAssertNil(DeepLink.parse(URL(string: "eira://chat/chat_a")!))
    }

    // MARK: - 待办的系统闹钟

    final class FakeChannel: AlarmChannel, @unchecked Sendable {
        let kind: String
        var state: TodoAlarm.Status
        var added: [String: Date] = [:]
        var removed: [String] = []
        init(_ kind: String, _ state: TodoAlarm.Status) { self.kind = kind; self.state = state }
        func status() async -> TodoAlarm.Status { state }
        func request() async -> TodoAlarm.Status { if state == .notDetermined { state = .granted }; return state }
        func add(todoId: String, title: String, at: Date) async throws -> String {
            let id = kind == "alarm" ? TodoAlarm.uuid(from: todoId).uuidString : TodoAlarm.noteId(todoId)
            added[id] = at
            return id
        }
        func remove(todoId: String, alarmId: String) { removed.append(alarmId); added[alarmId] = nil }
        func list() async -> [String] { Array(added.keys) }
    }

    func testUuidMatchesShell() {
        // 与网页版外壳 AlarmBridge.uuid(from:) 同一种散法（FNV-1a，两遍铺满十六个字节）
        XCTAssertEqual(TodoAlarm.uuid(from: "td_abc").uuidString, "9BA5CE78-B5C0-446A-17D6-1A9005430433")
        XCTAssertEqual(TodoAlarm.uuid(from: "td_abc"), TodoAlarm.uuid(from: "td_abc"))
        XCTAssertNotEqual(TodoAlarm.uuid(from: "td_abc"), TodoAlarm.uuid(from: "td_abd"))
        XCTAssertTrue(TodoAlarm.isKitId(TodoAlarm.uuid(from: "x").uuidString))
        XCTAssertFalse(TodoAlarm.isKitId("todo-x"))
    }

    func testAlarmKitWhenAvailable() async throws {
        let kit = FakeChannel("alarm", .notDetermined), note = FakeChannel("notify", .granted)
        TodoAlarm.testChannels = (kit, note)
        let at = Date().millis + 3_600_000
        let t = try XCTUnwrap(Todo.addMine("交表", ["remindAt": .number(at)]))
        let r = await TodoAlarm.schedule(t.id)
        XCTAssertEqual(r, .alarmed)
        let row = try XCTUnwrap(Todo.get(t.id))
        XCTAssertEqual(row.alarmId, TodoAlarm.uuid(from: t.id).uuidString)
        XCTAssertEqual(row.alarmAt, at)
        XCTAssertTrue(note.added.isEmpty)
        let listed = await TodoAlarm.listNative()
        XCTAssertEqual(TodoAlarm.reconcile(listed).map(\.known), [true])
        // 撤掉：两条路都撤，记号清空
        TodoAlarm.cancelLocal(t.id)
        XCTAssertTrue(kit.added.isEmpty)
        XCTAssertEqual(Todo.get(t.id)?.alarmId, "")
        XCTAssertEqual(note.removed.count, 1)
        // 改时刻：撤旧的排新的
        let r2 = await TodoAlarm.reschedule(t.id, at: at + 60_000)
        XCTAssertEqual(r2, .alarmed)
        XCTAssertEqual(Todo.get(t.id)?.alarmAt, at + 60_000)
        XCTAssertEqual(MockNet.count, 0)
    }

    func testFallsBackToNotifications() async throws {
        let at = Date().millis + 3_600_000
        // 闹钟权限被拒：退回通知
        let kit = FakeChannel("alarm", .denied), note = FakeChannel("notify", .granted)
        TodoAlarm.testChannels = (kit, note)
        let t = try XCTUnwrap(Todo.addMine("吃药", ["remindAt": .number(at)]))
        let r = await TodoAlarm.schedule(t.id)
        XCTAssertEqual(r, .scheduled)
        XCTAssertEqual(Todo.get(t.id)?.alarmId, "todo-\(t.id)")
        XCTAssertTrue(kit.added.isEmpty)
        let name = await TodoAlarm.channelName()
        XCTAssertEqual(name, "系统通知")
        // 这台设备没有系统闹钟：同样用通知
        TodoAlarm.testChannels = (nil, note)
        let t2 = try XCTUnwrap(Todo.addMine("买菜", ["remindAt": .number(at)]))
        let r2 = await TodoAlarm.schedule(t2.id)
        XCTAssertEqual(r2, .scheduled)
        // 两条路都没有权限：不写记号，照实说
        TodoAlarm.testChannels = (FakeChannel("alarm", .denied), FakeChannel("notify", .denied))
        let t3 = try XCTUnwrap(Todo.addMine("散步", ["remindAt": .number(at)]))
        let r3 = await TodoAlarm.schedule(t3.id)
        XCTAssertEqual(r3, .denied)
        XCTAssertEqual(Todo.get(t3.id)?.alarmId, "")
        // 已经过去的时刻不排
        let t4 = try XCTUnwrap(Todo.addMine("昨天", ["remindAt": .number(Date().millis - 1000)]))
        let r4 = await TodoAlarm.schedule(t4.id)
        XCTAssertEqual(r4, .past)
    }
}
