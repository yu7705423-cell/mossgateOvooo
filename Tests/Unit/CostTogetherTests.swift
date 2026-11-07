import XCTest
@testable import Eira

/// 一起看与一起读的花钱次数（网页版第 15 条、autocost 的 due:watch）：接口一直失败时数真正打出去几次。
/// 自己开口、翻页开口、收场写评、自动续读都是自动触发的：默认关；开着时先记「试过」再发，失败了不会每五秒、每翻一页再调一次。
extension CostTests {
    private func fail() { MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) } }

    private func resetTogether() {
        Watch.set { $0 = .init() }
        ReadTogether.set { $0 = .init() }
    }

    private func film() throws -> VideoLib.Video {
        let srt = (0..<12).map { "\($0 + 1)\n00:00:\(String(format: "%02d", $0 * 4)),000 --> 00:00:\(String(format: "%02d", $0 * 4 + 1)),000\n第\($0)句\n" }
            .joined(separator: "\n")
        return try VideoLib.add(title: "片子", url: "https://v.test/a.mp4", subtitle: srt, seconds: 600)
    }

    func testTogetherExtraCallsDefaultOff() {
        let s = AppSettings.load()
        for id in ["watchAuto", "readAuto", "reviewAuto", "readAheadAuto"] {
            let x = ExtraCalls.all.first { $0.id == id }
            XCTAssertNotNil(x, id)
            XCTAssertFalse(x!.isOn(s), "\(id) 默认关")
            XCTAssertFalse(x!.allowOn, id)
        }
    }

    /// 一起看：开口失败之后不再每五秒重试（网页版 autocost 的 due:watch：17 秒内只打出去一次）
    func testWatchAutoTalkFailingIsOneRequest() async throws {
        resetTogether()
        defer { resetTogether() }
        try setSettings(["watchGap": .number(1)])
        let v = try film()
        try Watch.start(chatId: "chat_a", videoId: v.id)
        Watch.tick(at: 200, duration: 600, playing: true)
        fail()
        for _ in 0..<4 { await Watch.autoTurn { _ in } }
        XCTAssertEqual(MockNet.count, 1)
        // 片子往前走过一个间隔才再试一次
        Watch.tick(at: 202, duration: 600, playing: true)
        await Watch.autoTurn { _ in }
        XCTAssertEqual(MockNet.count, 2)
    }

    func testWatchAutoTalkOffByDefault() async throws {
        resetTogether()
        defer { resetTogether() }
        let v = try film()
        try Watch.start(chatId: "chat_a", videoId: v.id)
        Watch.tick(at: 500, duration: 600, playing: true)
        fail()
        for _ in 0..<3 { await Watch.autoTurn { _ in } }
        XCTAssertEqual(MockNet.count, 0)
    }

    /// 一起看时你发一条：仍然只打一次（区块与能力说明是本地拼的）
    func testWatchingStillOneRequestPerMessage() async throws {
        resetTogether()
        defer { resetTogether() }
        let v = try film()
        try Watch.start(chatId: "chat_a", videoId: v.id)
        Watch.tick(at: 10, duration: 600, playing: true)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("好\n[暂停]")) }
        _ = try ChatEngine.send(text: "等一下", chatId: "chat_a")
        try await Watch.talk(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        let body = String(data: MockNet.requests.first?.httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("[你们正在看]"))
        // [暂停] 不落成气泡
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.content, "好")
    }

    /// 一起读：翻页开口失败之后，不翻够页数不再试
    func testReadTurnFailingWaitsForPages() async throws {
        resetTogether()
        defer { resetTogether() }
        let b = try Books.add(try Books.parse(Data(String(repeating: "字", count: 20000).utf8), name: "书", epub: false), title: "书", author: "")
        try ReadTogether.start(chatId: "chat_a", bookId: b.id)
        ReadTogether.markStart()
        fail()
        // 没填间隔按 0：翻页不开口
        try await ReadTogether.turn(to: 2400) { _ in }
        XCTAssertEqual(MockNet.count, 0)
        try setSettings(["readGap": .number(2)])
        // 开场之后翻满两页：开口一次，失败
        do { try await ReadTogether.turn(to: 4800) { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertFalse(ReadTogether.due(), "失败也算试过")
        do { try await ReadTogether.turn(to: 7200) { _ in } } catch {}
        XCTAssertEqual(MockNet.count, 1, "只又翻了一页，不够两页")
        do { try await ReadTogether.turn(to: 9600) { _ in } } catch {}
        XCTAssertEqual(MockNet.count, 2)
    }

    /// 收场写评：默认关，关着时一次都不打；开了每场一次
    func testReviewOnFinish() async throws {
        let v = try film()
        fail()
        await Reviews.writeOnFinish(kind: .video, subjectId: v.id, charId: "char_a", at: 30)
        XCTAssertEqual(MockNet.count, 0)
        try setSettings(["reviewAuto": .bool(true)])
        await Reviews.writeOnFinish(kind: .video, subjectId: v.id, charId: "char_a", at: 30)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertTrue(Reviews.list(.video, v.id).isEmpty)
    }

    /// 让角色先读：自动续读失败一次就停下，改回每次先问
    func testReadAheadAutoStopsAfterFailure() async throws {
        let b = try Books.add(try Books.parse(Data(String(repeating: "一段正文\n", count: 2000).utf8), name: "书", epub: false), title: "书", author: "")
        try ReadAhead.begin(b.id, charId: "char_a", from: 0)
        try ReadAhead.setAlways(b.id, true)
        XCTAssertTrue(ReadAhead.canAuto(b.id))
        XCTAssertTrue(ExtraCalls.all.first { $0.id == "readAheadAuto" }!.isOn(.load()))
        fail()
        do { try await ReadAhead.step(b.id, auto: true); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertFalse(ReadAhead.canAuto(b.id))
        XCTAssertEqual(ReadAhead.state(b.id)?.at, 0, "失败时读到的位置不动")
    }

    /// 点一次调一次的那几样：接口一直失败时点一次只打一次
    func testTogetherTasksFailingIsOneRequestPerTap() async throws {
        let v = try film()
        let b = try Books.add(try Books.parse(Data("第一段\n第二段".utf8), name: "书", epub: false), title: "书", author: "")
        let book = ParaNotes.subject(.book, b.id)
        let runs: [(String, () async throws -> Void)] = [
            ("watch.outline", { try await VideoLib.generateOutline(v.id) }),
            ("review.write", { try await Reviews.write(.book, subjectId: b.id, charId: "char_a") }),
            ("para.one", { _ = try await ParaNotes.one(book, at: 0, charId: "char_a") }),
            ("para.crew", { _ = try await ParaNotes.crewComments(book, at: 0, charIds: ["char_a"]) }),
            ("para.readers", { _ = try await ParaNotes.readers(book, at: 0) }),
            ("read.ahead", { _ = try await ReadAhead.run(bookId: b.id, charId: "char_a", from: 0) }),
            ("shelf.batch", { _ = try await Shelf.generate("char_a", count: 5) }),
        ]
        for (task, run) in runs {
            fail()
            let before = await Usage.shared.today(task: task)
            do { try await run(); XCTFail("\(task) 应当失败") } catch {}
            XCTAssertEqual(MockNet.count, 1, task)
            let after = await Usage.shared.today(task: task)
            XCTAssertEqual(after - before, 1, task)
        }
        XCTAssertTrue(VideoLib.get(v.id)!.outline.isEmpty)
        XCTAssertEqual(ParaNotes.count(book), 0)
    }

    /// B 站与片库本身不调模型接口
    func testBiliAndLibraryAreNotModelCalls() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: #"{"code":0,"data":{"isLogin":false,"wbi_img":{"img_url":"https://x/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://x/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#) }
        BiliApi.session = BiliApi.makeSession(protocols: [MockNet.self])
        defer { BiliApi.session = BiliApi.makeSession() }
        let before = await Usage.shared.today()
        _ = try await BiliApi.nav()
        let key = try await BiliApi.mixinKey()
        XCTAssertEqual(key, "ea1db124af3c7062474693fa704f4ff8")
        let after = await Usage.shared.today()
        XCTAssertEqual(after, before)
        XCTAssertTrue(MockNet.requests.allSatisfy { $0.url?.host == "api.bilibili.com" })
        XCTAssertEqual(MockNet.requests.first?.value(forHTTPHeaderField: "Referer"), "https://www.bilibili.com/")
    }
}
