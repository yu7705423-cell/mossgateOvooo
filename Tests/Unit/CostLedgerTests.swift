import XCTest
@testable import Eira

/// 记账与卡包（网页版第 15 条）：按角色卡生成角色的钱、从角色卡读证件都是点了才调，接口一直失败时点一次只打一次；
/// 账本绑在对话上之后发一条消息仍只打一次（余额只是本地算好写进去）；补固定入账、结算昨天的花销不调接口。
extension CostTests {
    func testLedgerTasksFailingIsOneRequestPerTap() async throws {
        let book = try Ledger.create(name: "一起记账", chatId: "chat_a")
        let runs: [(String, () async throws -> Void)] = [
            (LedgerAI.moneyTask, { _ = try await LedgerAI.generate(book.id) }),
            (LedgerAI.idcardTask, { _ = try await LedgerAI.readIdCard("char_a") }),
        ]
        for (task, run) in runs {
            MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
            let before = await Usage.shared.today(task: task)
            do { try await run(); XCTFail("\(task) 应当失败") } catch {}
            XCTAssertEqual(MockNet.count, 1, task)
            let after = await Usage.shared.today(task: task)
            XCTAssertEqual(after - before, 1, task)
            XCTAssertFalse(ExtraCalls.all.contains { $0.id == task }, task)
        }
        // 失败时账上什么都没动：角色的钱照旧是「尚未生成」
        XCTAssertFalse(Ledger.charReady(book.id))
        XCTAssertNil(Ledger.charMoneyOf(book.id))
    }

    func testLedgerMoneyApplies() async throws {
        let book = try Ledger.create(name: "一起记账", chatId: "chat_a")
        let json = #"{"summary":"一份工作","balance":3200,"income":[{"day":10,"amount":6000,"note":"工资"}],"expenses":[{"day":35,"amount":-1500,"note":""}]}"#
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream(json)) }
        let info = try await LedgerAI.generate(book.id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(info["summary"]?.string, "一份工作")
        XCTAssertTrue(Ledger.charReady(book.id))
        let hers = try XCTUnwrap(Ledger.defaultFor(book.id, Ledger.char))
        XCTAssertEqual(Ledger.balanceOf(book.id, hers.id), 3200)
        let rules = Ledger.rulesOf(book.id)
        XCTAssertEqual(rules.map(\.amount), [6000, -1500])
        XCTAssertEqual(rules.map(\.day), [10, 28])
        XCTAssertEqual(rules.map(\.note), ["工资", "固定支出"])
        XCTAssertEqual(rules.map(\.by), ["ai", "ai"])
        // 再生成一次：上一次的整批换掉，不叠加
        _ = try await LedgerAI.generate(book.id)
        XCTAssertEqual(Ledger.rulesOf(book.id).count, 2)
        XCTAssertEqual(Ledger.balanceOf(book.id, hers.id), 3200)
    }

    func testBoundBookStillOneRequestPerMessage() async throws {
        let book = try Ledger.create(name: "一起记账", chatId: "chat_a", start: 500)
        try Ledger.update(book.id, Ledger.BookPatch(settle: true))
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("[转账：99999 都给你]\n好")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        // 请求里写着余额（本地算好）；角色的钱还没生成，所以这一笔不拦
        let body = String(data: MockNet.requests.first?.httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("[你的钱]"), "绑了账本的对话里写着余额")
        XCTAssertTrue(body.contains("500.00"))
        // 补固定入账、结算昨天：不调接口
        try Ledger.addRule(book.id, day: 1, amount: 100, now: Date(timeIntervalSinceNow: -40 * 86400))
        _ = try Ledger.runRules(book.id)
        _ = try Ledger.settleYesterday("char_a")
        XCTAssertEqual(MockNet.count, 1)
    }
}
