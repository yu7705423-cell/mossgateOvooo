import XCTest
@testable import Eira

/// 对照之后补上的几处规矩：
///   · 删角色时其余数据域里指着它的一并处理（它自己的删，你的留着、摘掉指向）
///   · 封存的角色不能再对话，一次接口都不调；也不再主动发起对话
///   · 提示词里拼的每项能力、每块区块都在新功能登记里（基线或 features），新功能没开不进
///   · 通话出声默认关，开着时登记在「用量与上限」
///   · 能力页「全部关闭」只动原生列出的那几样
final class RuleFixTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
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

    private func put(_ c: String, _ fields: [String: JSONValue]) throws -> Row {
        let r = Row.new(prefix: "t", fields)
        try Database.shared.put(c, r)
        return r
    }

    func testDeleteCharacterCleansOtherDomains() throws {
        let id = "char_a"
        let moment = try put("moments", ["authorId": .string(id), "text": .string("x")])
        let otherMoment = try put("moments", ["authorId": .string("me"), "text": .string("y")])
        let hisWish = try put("wishes", ["owner": .string(id)])
        let myWish = try put("wishes", ["owner": .string("me"), "charId": .string(id)])
        let tie = try put(Ties.collection, ["from": .string(id), "to": .string("me")])
        let thread = try put("smsThreads", ["charId": .string(id)])
        var sms = Message.new(chatId: thread.id, role: .char, authorId: id, content: "短信")
        sms = try Repo.append(sms)
        let playlist = try put("playlists", ["owner": .string(id)])
        let closet = try put("closet", ["owner": .string(id)])
        let pet = try put("pets", ["charId": .string(id), "owner": .string("both")])
        let box = try put("boxes", ["kind": .string("own"), "owner": .string(id)])
        let slip = try put("slips", ["boxId": .string(box.id), "author": .string(id)])
        let shared = try put("collection", ["owner": .string(id), "shared": .string("me")])

        try People.deleteCharacter(id)

        XCTAssertNil(try Database.shared.get("moments", id: moment.id))
        XCTAssertNotNil(try Database.shared.get("moments", id: otherMoment.id))
        XCTAssertNil(try Database.shared.get("wishes", id: hisWish.id))
        XCTAssertEqual(try Database.shared.get("wishes", id: myWish.id)?.string("charId"), "")
        XCTAssertNil(try Database.shared.get(Ties.collection, id: tie.id))
        XCTAssertNil(try Database.shared.get("smsThreads", id: thread.id))
        XCTAssertNil(try Database.shared.get(Collections.messages, id: sms.id))
        XCTAssertNil(try Database.shared.get("playlists", id: playlist.id))
        XCTAssertNil(try Database.shared.get("closet", id: closet.id))
        XCTAssertEqual(try Database.shared.get("pets", id: pet.id)?.string("owner"), "me")
        XCTAssertNil(try Database.shared.get("boxes", id: box.id))
        XCTAssertNil(try Database.shared.get("slips", id: slip.id))
        // 与别人共同拥有的交给另一方，不随它删
        let handed = try XCTUnwrap(Database.shared.get("collection", id: shared.id))
        XCTAssertEqual(handed.string("owner"), "me")
        XCTAssertEqual(handed.string("shared"), "")
        XCTAssertNil(try Repo.character(id))
    }

    func testArchivedCharacterMakesNoRequest() async throws {
        var c = try XCTUnwrap(Repo.character("char_a"))
        c.row["archived"] = .number(Date().millis)
        c.row["proactive"] = .bool(true)
        try Database.shared.put(Collections.characters, c.row)
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertTrue(Archive.chatArchived(chat))
        XCTAssertFalse(Proactive.config(try Repo.character("char_a")).on)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("不该出现")) }
        _ = try ChatEngine.send(text: "在吗", chatId: "chat_a")
        do { try await ChatEngine.reply(chatId: "chat_a") { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 0)
    }

    func testEveryInjectedCapAndBlockIsRegistered() {
        for id in ChatPrompt.capIds { XCTAssertTrue(NewFeat.known(cap: id), "能力 \(id) 不在基线也不在新功能里") }
        for id in ChatPrompt.blockIds { XCTAssertTrue(NewFeat.known(block: id), "区块 \(id) 不在基线也不在新功能里") }
        for id in Layout.blockMeta.keys { XCTAssertTrue(NewFeat.known(block: id), "预设里的区块 \(id) 不在基线也不在新功能里") }
    }

    func testNewFeatureOffUntilChosen() throws {
        var s = AppSettings.load()
        XCTAssertFalse(NewFeat.blockOn("pets", s))
        XCTAssertFalse(NewFeat.capOn("quiz", s))
        XCTAssertTrue(NewFeat.capOn("image", s))
        NewFeat.set("pets", true, &s)
        XCTAssertTrue(NewFeat.blockOn("pets", s))
        XCTAssertEqual(NewFeat.decided("quiz", s), "")
    }

    @MainActor
    func testCallVoiceOffByDefault() throws {
        let s = AppSettings.load()
        XCTAssertFalse(ExtraCalls.active(s).contains { $0.id == "callVoice" })
        let session = CallSession(chatId: "chat_a", char: try XCTUnwrap(Repo.character("char_a")))
        XCTAssertFalse(session.speak)
    }
}
