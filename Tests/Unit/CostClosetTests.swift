import XCTest
@testable import Eira

/// 衣帽间、心愿、梦境里会调接口的几样（网页版第 15 条、autocost 的规矩）：接口一直失败时数真正打出去几次。
///
/// 每日穿搭、每晚做梦：默认关，登记在 ExtraCalls；开着时一天只自动试一次，失败也算，关了又开当天也不再试。
/// 单独判定心愿：默认关；先记「试过」再发，失败之后要再攒够一个间隔才再判。
/// 点了才调的（按设定生成衣帽间、现在做一个梦、现在判定）：点一次一次，不进 ExtraCalls。
extension CostTests {
    private func failing() { MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) } }

    func testClosetDailyOffByDefault() async throws {
        UserDefaults.standard.removeObject(forKey: "phone.daily.tried")
        failing()
        _ = try Closet.create(["owner": .string("char_a"), "group": .string("top"), "sub": .string("衬衫"), "name": .string("白衬衫")])
        let ran = await ClosetAI.ensureDaily("char_a")
        XCTAssertFalse(ran)
        XCTAssertEqual(MockNet.count, 0)
        XCTAssertFalse(ExtraCalls.switchedOn(.load()).contains { $0.id == "closetDaily" })
        // 发一条消息也不多打
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("在的")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        UserDefaults.standard.removeObject(forKey: "phone.daily.tried")
    }

    func testClosetDailyFailingOncePerDay() async throws {
        UserDefaults.standard.removeObject(forKey: "phone.daily.tried")
        failing()
        _ = try Closet.create(["owner": .string("char_a"), "group": .string("top"), "sub": .string("衬衫"), "name": .string("白衬衫")])
        try Diary.patchChar("char_a", ["closetDaily": .bool(true)])
        XCTAssertTrue(ExtraCalls.switchedOn(.load()).contains { $0.id == "closetDaily" })
        let first = await ClosetAI.ensureDaily("char_a")
        let second = await ClosetAI.ensureDaily("char_a")
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(hostsOf(), ["spare.test"], "走副用接口")
        let c = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(c.row.string("closetDailyAt"), Closet.today())
        XCTAssertFalse(c.row.string("closetDailyError").isEmpty)
        // 关了又开、记号被清掉，当天也不再自动试
        try Diary.patchChar("char_a", ["closetDaily": .bool(false), "closetDailyAt": .string("")])
        try Diary.patchChar("char_a", ["closetDaily": .bool(true)])
        let third = await ClosetAI.ensureDaily("char_a")
        XCTAssertFalse(third)
        // 发消息之前那一处同样不再试
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("在的")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        UserDefaults.standard.removeObject(forKey: "phone.daily.tried")
    }

    func testDreamAutoFailingOncePerDay() async throws {
        UserDefaults.standard.removeObject(forKey: "phone.daily.tried")
        failing()
        XCTAssertFalse(ExtraCalls.switchedOn(.load()).contains { $0.id == "dreamAuto" })
        let off = await Dream.ensureToday("char_a")
        XCTAssertFalse(off)
        try Diary.patchChar("char_a", ["dreamAuto": .bool(true), "dreamHour": .number(0)])
        XCTAssertTrue(ExtraCalls.switchedOn(.load()).contains { $0.id == "dreamAuto" })
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let first = await Dream.ensureToday("char_a", now: noon)
        let second = await Dream.ensureToday("char_a", now: noon)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertFalse(try XCTUnwrap(Repo.character("char_a")).row.string("dreamAutoError").isEmpty)
        try Diary.patchChar("char_a", ["dreamAuto": .bool(false), "dreamAutoAt": .string("")])
        try Diary.patchChar("char_a", ["dreamAuto": .bool(true)])
        let third = await Dream.ensureToday("char_a", now: noon)
        XCTAssertFalse(third)
        XCTAssertEqual(MockNet.count, 1)
        UserDefaults.standard.removeObject(forKey: "phone.daily.tried")
    }

    func testWishJudgeOffByDefaultAndOncePerInterval() async throws {
        failing()
        try Wish.addMine(text: "一起看雪")
        XCTAssertFalse(Wish.shouldJudge("chat_a"))
        XCTAssertFalse(ExtraCalls.switchedOn(.load()).contains { $0.id == "wishJudge" })
        try setSettings(["wishJudge": .bool(true), "wishJudgeEvery": .number(1)])
        XCTAssertTrue(ExtraCalls.switchedOn(.load()).contains { $0.id == "wishJudge" })
        XCTAssertTrue(Wish.shouldJudge("chat_a"))
        do { _ = try await Wish.judgeNow("chat_a"); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        // 失败也算试过：没有新的角色回复之前不再判
        XCTAssertEqual(try XCTUnwrap(Repo.chat("chat_a")).row.string("wishTriedId"), "msg_3")
        XCTAssertFalse(Wish.shouldJudge("chat_a"))
        Wish.autoJudge("chat_a")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(MockNet.count, 1)
    }

    /// 随记忆总结一起判定：不多调接口，结果只认交出去的那几条
    func testWishCheckRidesOnSummary() async throws {
        let w = try Wish.addMine(text: "一起看雪", shown: false)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.openaiStream(
            #"{"events":[],"facts":[],"ended":[],"open":[],"closed":[],"state":{},"spending":[],"wishesDone":[{"id":"\#(w.id)","note":"下雪了"},"ws_fake"]}"#)) }
        _ = try await MemorySummary.extract(chatId: "chat_a")
        XCTAssertEqual(MockNet.count, 1)
        let body = String(decoding: try XCTUnwrap(MockNet.requests.first?.httpBodyStreamData()), as: UTF8.self)
        XCTAssertTrue(body.contains("(id:\(w.id)) owner: User | wish: "))
        XCTAssertEqual(Wish.get(w.id)?.doneBy, "summary")
    }

    func testClosetDreamWishTapsAreOneRequestEach() async throws {
        let runs: [(String, () async throws -> Void)] = [
            ("closet.wardrobe", { _ = try await ClosetAI.wardrobe("char_a", count: 5) }),
            ("closet.daily", { _ = try await ClosetAI.pickToday("char_a") }),
            ("dream.write", { _ = try await Dream.write("char_a") }),
            ("wish.judge", { _ = try await Wish.judgeNow("chat_a") }),
        ]
        _ = try Closet.create(["owner": .string("char_a"), "group": .string("top"), "sub": .string("衬衫"), "name": .string("白衬衫")])
        try Wish.addMine(text: "一起看雪")
        for (task, run) in runs {
            failing()
            let before = await Usage.shared.today(task: task)
            do { try await run(); XCTFail("\(task) 应当失败") } catch {}
            XCTAssertEqual(MockNet.count, 1, task)
            let after = await Usage.shared.today(task: task)
            XCTAssertEqual(after - before, 1, task)
            XCTAssertFalse(ExtraCalls.all.contains { $0.id == task }, task)
        }
        // 识图没配：一次都不打
        failing()
        let r = try Closet.create(["name": .string("有图的"), "imageId": .string("img_a")])
        do { try await ClosetAI.recognize(r.id); XCTFail("没有识图接口时应当报错") } catch {}
        XCTAssertEqual(MockNet.count, 0)
        // 生图没配：一次都不打
        do { try await ClosetAI.draw(r.id); XCTFail("没有生图接口时应当报错") } catch {}
        XCTAssertEqual(MockNet.count, 0)
    }

    private func hostsOf() -> [String] { MockNet.requests.compactMap { $0.url?.host } }
}
