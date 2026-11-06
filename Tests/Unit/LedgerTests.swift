import XCTest
@testable import Eira

/// 记账与卡包（网页版 ledger.js、request.js、funcard.js、pass.js、ticket.js、member.js）。
///
/// ledger-web.json 是网页版自己的代码记下的一本账（scripts/make-ledger-fixture.mjs），ledger-web-expected.json 是网页版
/// 对同一份数据算出来的余额、合计、收支、构成、亲属卡额度、注入的那一段与几种卡的状态。这里核对原生算出来的一样。
/// 时区钉成 UTC，和生成时一样。
final class LedgerTests: StoreTestCase {
    private var savedZone: TimeZone!
    private var exp: [String: Any] = [:]
    private var bookId = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "UTC")!
        let data = try Data(contentsOf: fixture("ledger-web-expected.json"))
        exp = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        bookId = exp["bookId"] as? String ?? ""
    }

    override func tearDownWithError() throws {
        NSTimeZone.default = savedZone
        try super.tearDownWithError()
    }

    private var nowE: Date { Date(millis: (exp["now"] as? NSNumber)?.doubleValue ?? 0) }
    private func dict(_ k: String) -> [String: Any] { exp[k] as? [String: Any] ?? [:] }
    private func list(_ k: String) -> [[String: Any]] { exp[k] as? [[String: Any]] ?? [] }
    private func dbl(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

    private func load() throws {
        try importFixture("ledger-web.json")
        XCTAssertEqual(try Ledger.runRules(bookId, now: nowE), (exp["ranEnd"] as? NSNumber)?.intValue)
    }

    // MARK: - 和网页版算的一样

    func testBalancesMatchWeb() throws {
        try load()
        for (acc, v) in dict("balances") { XCTAssertEqual(Ledger.balanceOf(bookId, acc), dbl(v), accuracy: 0.001, acc) }
        let t = dict("total")
        XCTAssertEqual(Ledger.totalOf(bookId), dbl(t["all"]), accuracy: 0.001)
        XCTAssertEqual(Ledger.totalOf(bookId, Ledger.me), dbl(t["me"]), accuracy: 0.001)
        XCTAssertEqual(Ledger.totalOf(bookId, Ledger.char), dbl(t["char"]), accuracy: 0.001)
        XCTAssertEqual(Ledger.totalOf(bookId, Ledger.joint), dbl(t["joint"]), accuracy: 0.001)
        XCTAssertEqual(Ledger.months(bookId, now: nowE), exp["months"] as? [String])
        XCTAssertEqual(Ledger.charReady(bookId), exp["charReady"] as? Bool)
        XCTAssertEqual(Ledger.pendingOf(bookId).map(\.id), exp["pending"] as? [String])
        // 再补一次不会重复
        XCTAssertEqual(try Ledger.runRules(bookId, now: nowE), 0)
    }

    func testChatEntriesAndCardsMatchWeb() throws {
        try load()
        let got = Ledger.chatEntries(bookId)
        let want = list("chatEntries")
        XCTAssertEqual(got.map(\.id), want.map { $0["id"] as? String ?? "" })
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.accountId, w["accountId"] as? String, g.id)
            XCTAssertEqual(g.amount, dbl(w["amount"]), accuracy: 0.001, g.id)
            XCTAssertEqual(g.cardId, w["cardId"] as? String, g.id)
            XCTAssertEqual(g.note, w["note"] as? String, g.id)
        }
        let cards = Ledger.cardsOf(bookId)
        XCTAssertEqual(cards.map(\.id), list("cards").map { $0["id"] as? String ?? "" })
        for (c, w) in zip(cards, list("cards")) {
            XCTAssertEqual(c.from, w["from"] as? String)
            XCTAssertEqual(c.to, w["to"] as? String)
            XCTAssertEqual(Ledger.cardUsed(bookId, c.id), dbl(w["used"]), accuracy: 0.001)
            XCTAssertEqual(Ledger.cardLeft(bookId, c), dbl(w["left"]), accuracy: 0.001)
        }
    }

    func testStatsAndSpendingMatchWeb() throws {
        try load()
        for (month, raw) in dict("stats") {
            let w = raw as? [String: Any] ?? [:]
            let s = Ledger.stats(bookId, month: month)
            XCTAssertEqual(s.income, dbl(w["income"]), accuracy: 0.001, month)
            XCTAssertEqual(s.expense, dbl(w["expense"]), accuracy: 0.001, month)
            XCTAssertEqual(s.net, dbl(w["net"]), accuracy: 0.001, month)
            let cats = w["byCategory"] as? [[String: Any]] ?? []
            XCTAssertEqual(s.byCategory.map(\.id), cats.map { $0["id"] as? String ?? "" }, month)
            XCTAssertEqual(s.byCategory.map(\.label), cats.map { $0["label"] as? String ?? "" }, month)
        }
        for (month, raw) in dict("spending") {
            let w = raw as? [String: Any] ?? [:]
            let sp = Ledger.spending(bookId, month: month)
            XCTAssertEqual(sp.total, dbl(w["total"]), accuracy: 0.001, month)
            let rows = w["rows"] as? [[String: Any]] ?? []
            XCTAssertEqual(sp.rows.map(\.id), rows.map { $0["id"] as? String ?? "" }, month)
            for (r, x) in zip(sp.rows, rows) {
                XCTAssertEqual(r.label, x["label"] as? String)
                XCTAssertEqual(r.amount, dbl(x["amount"]), accuracy: 0.001)
                XCTAssertEqual(r.count, (x["count"] as? NSNumber)?.intValue)
                XCTAssertEqual(r.share, dbl(x["share"]), accuracy: 1e-9)
                let subs = x["subs"] as? [[String: Any]] ?? []
                XCTAssertEqual(r.subs.map(\.id), subs.map { $0["id"] as? String ?? "" }, r.id)
                XCTAssertEqual(r.subs.map(\.label), subs.map { $0["label"] as? String ?? "" }, r.id)
            }
        }
    }

    func testContextBlockMatchesWeb() throws {
        try load()
        let chat = try XCTUnwrap(try Repo.chat("chat_a"))
        XCTAssertEqual(Ledger.block(chat, now: nowE), exp["bill"] as? String)
        let c = try XCTUnwrap(Ledger.context("chat_a", now: nowE))
        let w = dict("context")
        XCTAssertEqual(c.selfBalance, w["self"] as? String)
        XCTAssertEqual(c.other, w["other"] as? String)
        XCTAssertEqual(c.joint, w["joint"] as? String)
        XCTAssertEqual(c.month, w["month"] as? String)
        XCTAssertEqual(c.cardGiven?.left, (w["cardGiven"] as? [String: Any])?["left"] as? String)
        XCTAssertNil(c.cardHeld)
        let a = dict("affordable")
        XCTAssertEqual(Ledger.affordable("chat_a", Ledger.me, 100), a["me100"] as? Bool)
        XCTAssertEqual(Ledger.affordable("chat_a", Ledger.me, 100_000), a["me1e5"] as? Bool)
        XCTAssertEqual(Ledger.affordable("chat_a", Ledger.char, 500), a["char500"] as? Bool)
        XCTAssertEqual(Ledger.affordable("chat_a", Ledger.char, 100_000), a["char1e5"] as? Bool)
        // 私密账户的余额、密码一个字都不进
        XCTAssertFalse(Ledger.block(chat, now: nowE).contains("999"))
        XCTAssertFalse(Ledger.block(chat, now: nowE).contains("0520"))
    }

    func testCategoriesAndLabelsMatchWeb() throws {
        try load()
        let cats = Ledger.categories()
        XCTAssertEqual(cats.map(\.id), list("categories").map { $0["id"] as? String ?? "" })
        XCTAssertEqual(cats.map { $0.subs.map(\.id) }, list("categories").map { $0["subs"] as? [String] ?? [] })
        let labels = Dictionary(uniqueKeysWithValues: list("labels").map { ($0["id"] as? String ?? "", $0["label"] as? String ?? "") })
        for e in Ledger.entriesOf(bookId) where e.src == "manual" { XCTAssertEqual(Ledger.labelOf(e), labels[e.id], e.id) }
    }

    func testWalletCardsMatchWeb() throws {
        try load()
        let fc = dict("funcard")
        let f = WalletCards.Fun.facts("chat_a")
        XCTAssertEqual(f.mine, fc["mine"] as? [String])
        XCTAssertEqual(f.theirs, fc["theirs"] as? [String])
        XCTAssertEqual(f.waiting, fc["waiting"] as? String)
        let fs = WalletCards.Fun.cardsOf("chat_a")
        XCTAssertEqual(fs.map(\.id), list("funStates").map { $0["id"] as? String ?? "" })
        for (s, w) in zip(fs, list("funStates")) {
            XCTAssertEqual(s.status, w["status"] as? String, s.name)
            XCTAssertEqual(s.used, (w["used"] as? NSNumber)?.intValue, s.name)
            XCTAssertEqual(s.left, (w["left"] as? NSNumber)?.intValue, s.name)
            XCTAssertEqual(s.holder, w["holder"] as? String, s.name)
        }
        let pf = dict("pass")
        let p = WalletCards.Pass.facts("chat_a")
        XCTAssertEqual(p.mine, pf["mine"] as? [String])
        XCTAssertEqual(p.given, pf["given"] as? [String])
        let ps = WalletCards.Pass.passesOf("chat_a")
        XCTAssertEqual(ps.map(\.id), list("passStates").map { $0["id"] as? String ?? "" })
        for (s, w) in zip(ps, list("passStates")) {
            XCTAssertEqual(s.revoked, w["revoked"] as? Bool, s.name)
            XCTAssertEqual(s.uses, (w["uses"] as? NSNumber)?.intValue, s.name)
        }
        let tf = dict("ticket")
        let t = WalletCards.Ticket.facts("chat_a")
        XCTAssertEqual(t.mine, tf["mine"] as? [String])
        XCTAssertEqual(t.theirs, tf["theirs"] as? [String])
        let ts = WalletCards.Ticket.ticketsOf("chat_a")
        XCTAssertEqual(ts.map(\.id), list("ticketStates").map { $0["id"] as? String ?? "" })
        for (s, w) in zip(ts, list("ticketStates")) {
            XCTAssertEqual(s.status, w["status"] as? String, s.title)
            XCTAssertEqual(s.at, dbl(w["at"]), s.title)
        }
        XCTAssertEqual(WalletCards.Member.facts("chat_a"), exp["member"] as? [String])
        // 网页版读出来的开场时间：和网页版的 parseWhen 一样
        XCTAssertEqual(WalletCards.Ticket.parseWhen("2030-10-20 19:30"), 1_918_755_000_000)
        XCTAssertEqual(WalletCards.Ticket.parseWhen("2030年3月2日 晚上8点"), 1_898_712_000_000)
    }

    // MARK: - 写

    /// 改账本、账户、规则、卡时，不认得的字段原样留着；导出再导入一份不差
    func testUnknownFieldsSurviveAndRoundTrip() throws {
        try load()
        var row = try XCTUnwrap(try Database.shared.get(Ledger.booksCollection, id: bookId))
        var accs = row["accounts"]?.array ?? []
        var first = accs[0].object ?? [:]
        first["webOnly"] = .string("keep")
        accs[0] = .object(first)
        row["accounts"] = .array(accs)
        row["bookWebOnly"] = .number(7)
        try Database.shared.put(Ledger.booksCollection, row)

        let acc = Ledger.accountsOf(bookId)[0]
        try Ledger.updateAccount(bookId, acc.id, Ledger.AccountPatch(name: "零钱"))
        try Ledger.update(bookId, Ledger.BookPatch(inject: false))
        let rule = Ledger.rulesOf(bookId)[0]
        try Ledger.setRule(bookId, rule.id, Ledger.RulePatch(active: false))
        let after = try XCTUnwrap(Ledger.get(bookId))
        XCTAssertEqual(after.accounts[0].obj["webOnly"]?.string, "keep")
        XCTAssertEqual(after.accounts[0].name, "零钱")
        XCTAssertEqual(after.row["bookWebOnly"]?.number, 7)
        XCTAssertFalse(after.inject)
        XCTAssertNil(Ledger.context("chat_a"))
        XCTAssertFalse(after.rules[0].active)
        XCTAssertEqual(after.rules[0].obj["by"]?.string, rule.by)

        let balances = Dictionary(uniqueKeysWithValues: after.accounts.map { ($0.id, Ledger.balanceOf(bookId, $0.id)) })
        let file = try BackupExporter.run(.init(media: false)).file
        Database.shared.close()
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Database.shared = try Database(url: root.appendingPathComponent("test.sqlite"))
        try BackupImporter.run(file: file, password: "") { _ in }
        let back = try XCTUnwrap(Ledger.get(bookId))
        XCTAssertEqual(back.accounts[0].obj["webOnly"]?.string, "keep")
        for (id, v) in balances { XCTAssertEqual(Ledger.balanceOf(bookId, id), v, accuracy: 0.001) }
        XCTAssertEqual(AppSettings.load().raw["ledgerCats"], (try? JSONValue.parse(try Data(contentsOf: fixture("ledger-web.json"))))?["settings"]?["ledgerCats"])
    }

    /// 转账收下才算钱；删掉「收下了」那一行（重新生成那一轮），那笔钱回到待收款，余额跟着回去
    func testTransferUndoMovesMoneyBack() throws {
        try load()
        let mine = try XCTUnwrap(Ledger.defaultFor(bookId, Ledger.me))
        let before = Ledger.balanceOf(bookId, mine.id)
        let t = try ChatEngine.sendTransfer(chatId: "chat_a", amount: 66, note: "测试")
        XCTAssertEqual(Ledger.balanceOf(bookId, mine.id), before, accuracy: 0.001, "待收款的钱没动")
        let notice = try XCTUnwrap(try Interact.settleTransfer(t.id, take: true, turnId: "turn_x"))
        let n = try Repo.append(notice)
        XCTAssertEqual(Ledger.balanceOf(bookId, mine.id), before - 66, accuracy: 0.001)
        try Interact.drop(n)
        XCTAssertEqual(Ledger.balanceOf(bookId, mine.id), before, accuracy: 0.001, "提示行删掉之后回到待收款")
        // 那一条转账本身删掉也一样
        let n2 = try Repo.append(try XCTUnwrap(try Interact.settleTransfer(t.id, take: true)))
        XCTAssertEqual(Ledger.balanceOf(bookId, mine.id), before - 66, accuracy: 0.001)
        try Interact.drop(t)
        XCTAssertEqual(Ledger.balanceOf(bookId, mine.id), before, accuracy: 0.001)
        _ = n2
    }

    /// 申请：通过之后建情侣账户、发亲属卡；删掉「通过了」那一行，申请回到待处理（建出来的账户与卡留着，同网页版）
    func testRequestSettleAndUnsettle() throws {
        try Database.shared.put(Collections.chats, Row(fields: ["id": .string("c2"), "characterIds": .array([.string("char_b")]), "personaId": .string("p1")]))
        try Database.shared.put(Collections.characters, Row(fields: ["id": .string("char_b"), "name": .string("白")]))
        try Database.shared.put(Collections.personas, Row(fields: ["id": .string("p1"), "name": .string("我")]))
        let book = try Ledger.create(name: "", chatId: "c2", start: 100)
        XCTAssertEqual(book.name, "未命名账本")
        XCTAssertEqual(Ledger.accountsOf(book.id).map(\.owner), ["me", "char"])
        XCTAssertEqual(Ledger.accountsOf(book.id)[1].name, "白")

        let ask = try Repo.append(try LedgerRequest.make(Message.new(chatId: "c2", role: .char, authorId: "char_b", content: ""), kind: LedgerRequest.joint))
        XCTAssertEqual(ask.content, "[开设情侣账户]")
        let notice = try Repo.append(try XCTUnwrap(try LedgerRequest.settle(ask.id, ok: true)))
        XCTAssertEqual(notice.content, "[我通过了白开设情侣账户的申请]")
        XCTAssertTrue(Ledger.hasJoint(book.id))
        XCTAssertEqual((try Database.shared.get(Collections.messages, id: ask.id))?.string("content"), "[开设情侣账户]（已通过）")
        try Interact.drop(notice)
        XCTAssertEqual((try Database.shared.get(Collections.messages, id: ask.id))?.string("request"), "pending")
        XCTAssertTrue(Ledger.hasJoint(book.id))

        // 存入：发出即落定。钱从我的钱包出、进情侣账户
        let mine = try XCTUnwrap(Ledger.defaultFor(book.id, Ledger.me))
        try LedgerRequest.sendFromUser(chatId: "c2", kind: LedgerRequest.deposit, amount: 40)
        XCTAssertEqual(Ledger.balanceOf(book.id, mine.id), 60, accuracy: 0.001)
        XCTAssertEqual(Ledger.balanceOf(book.id, try XCTUnwrap(Ledger.defaultFor(book.id, Ledger.joint)).id), 40, accuracy: 0.001)
        XCTAssertThrowsError(try LedgerRequest.sendFromUser(chatId: "c2", kind: LedgerRequest.deposit, amount: 1000), "余额不足")

        // 亲属卡：角色提、我通过，卡是角色发给我的
        let card = try Repo.append(try LedgerRequest.make(Message.new(chatId: "c2", role: .char, authorId: "char_b", content: ""), kind: LedgerRequest.card, amount: 80))
        XCTAssertEqual(card.content, "[亲属卡：额度 80.00]")
        _ = try Repo.append(try XCTUnwrap(try LedgerRequest.settle(card.id, ok: true)))
        XCTAssertEqual(Ledger.cardTo(book.id, Ledger.me)?.from, Ledger.char)
    }

    /// 余额不足时角色的转账不落，落一行说明；角色的钱还没生成时不拦
    func testBrokeOnlyWhenKnown() throws {
        try Database.shared.put(Collections.chats, Row(fields: ["id": .string("c3"), "characterIds": .array([.string("char_c")])]))
        try Database.shared.put(Collections.characters, Row(fields: ["id": .string("char_c"), "name": .string("青")]))
        let book = try Ledger.create(name: "账", chatId: "c3")
        let base = Message.new(chatId: "c3", role: .char, authorId: "char_c", content: "")
        XCTAssertNil(Ledger.broke(base, amount: 500, what: "转账 500.00"), "角色的钱还没生成：不知道有多少，不拦")
        let hers = try XCTUnwrap(Ledger.defaultFor(book.id, Ledger.char))
        try Ledger.seed(book.id, hers.id, 100)
        XCTAssertTrue(Ledger.charReady(book.id))
        let short = try XCTUnwrap(Ledger.broke(base, amount: 500, what: "转账 500.00"))
        XCTAssertEqual(short.kind, "notice")
        XCTAssertEqual(short.content, "[余额不足，转账 500.00 没有付成。当前余额 ¥100.00]")
        XCTAssertNil(Ledger.broke(base, amount: 100, what: "转账 100.00"))
        try Ledger.update(book.id, Ledger.BookPatch(strict: false))
        XCTAssertNil(Ledger.broke(base, amount: 500, what: "转账 500.00"))
    }

    /// 固定入账：二月没有三十一号，落在二月最后一天；建之前的月份不补
    func testRuleDueDates() throws {
        try Database.shared.put(Ledger.booksCollection, Row(fields: ["id": .string("bk_r"), "name": .string("r"), "accounts": .array([])]))
        let acc = try Ledger.addAccount("bk_r", name: "现金")
        let from = Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 20, hour: 12))!
        let rule = try Ledger.addRule("bk_r", accountId: acc.id, day: 31, amount: 100, now: from)
        let now = Calendar.current.date(from: DateComponents(year: 2027, month: 4, day: 1, hour: 12))!
        XCTAssertEqual(Ledger.dueDates(rule, now: now).map(Ledger.ymd), ["2027-01-31", "2027-02-28", "2027-03-31"])
        XCTAssertEqual(try Ledger.runRules("bk_r", now: now), 3)
        XCTAssertEqual(try Ledger.runRules("bk_r", now: now), 0)
        XCTAssertEqual(Ledger.balanceOf("bk_r", acc.id), 300)
    }

    /// 千分位只在界面上（网页版 4.768）；写进标记的照旧不加
    func testMoneyDisplayGrouping() {
        XCTAssertEqual(Interact.display(98_765_432.1, "CNY"), "¥98,765,432.10")
        XCTAssertEqual(Interact.display(-1234, "JPY"), "¥-1,234")
        XCTAssertEqual(Interact.display(999, "USD"), "$999.00")
        XCTAssertEqual(Interact.format(98_765_432.1, "CNY"), "98765432.10")
    }

    /// 账号隔离（4.961）：隔离的账号只看自己建的账本
    func testIsolationHidesOtherAccountsBooks() throws {
        try Database.shared.put(Collections.personas, Row(fields: ["id": .string("pa"), "name": .string("甲"), "createdAt": .number(1)]))
        try Database.shared.put(Collections.personas, Row(fields: ["id": .string("pb"), "name": .string("乙"), "createdAt": .number(2),
                                                                    "isolate": .object(["wallet": .bool(true)])]))
        try setSettings(["activePersonaId": .string("pa")])
        let a = try Ledger.create(name: "甲的")
        try setSettings(["activePersonaId": .string("pb")])
        XCTAssertTrue(Ledger.visible().isEmpty)
        let b = try XCTUnwrap(try Ledger.ensure())
        XCTAssertEqual(Ledger.visible().map(\.id), [b.id])
        try setSettings(["activePersonaId": .string("pa")])
        XCTAssertEqual(Ledger.visible().map(\.id), [a.id], "不隔离的账号看不见隔离账号的账本")
    }

    /// 回复里的标记（网页版 reply.js）：申请、表态、送卡、用卡、门禁卡、票券、会员卡
    func testReplyMarks() {
        func parts(_ raw: String) -> [ReplyParser.Part] { ReplyParser.split(raw).parts }
        XCTAssertEqual(parts("[开设情侣账户]").first?.type, .request)
        XCTAssertEqual(parts("[开设情侣账户]").first?.extra, LedgerRequest.joint)
        let sp = parts("[申请：买机票 2000]").first
        XCTAssertEqual(sp?.type, .request)
        XCTAssertEqual(sp?.extra, LedgerRequest.spend)
        XCTAssertEqual(sp?.amount, 2000)
        XCTAssertEqual(sp?.text, "买机票")
        XCTAssertEqual(parts("[亲属卡：额度 2000]").first?.extra, LedgerRequest.card)
        XCTAssertEqual(parts("[存入情侣账户：500]").first?.extra, LedgerRequest.deposit)
        XCTAssertEqual(parts("[批准]").first?.type, .vote)
        XCTAssertEqual(parts("[批准]").first?.flag, true)
        XCTAssertEqual(parts("[驳回]").first?.flag, false)
        XCTAssertEqual(parts("[同意用卡]").first?.type, .funVote)
        XCTAssertEqual(parts("[不同意用卡]").first?.flag, false)
        let give = parts("[送卡：和好卡｜吵架后先和好｜3 次｜30 天｜需确认]").first
        XCTAssertEqual(give?.type, .funGive)
        XCTAssertEqual(give?.info?["name"], "和好卡")
        XCTAssertEqual(give?.info?["uses"], "3")
        XCTAssertEqual(give?.info?["days"], "30")
        XCTAssertEqual(give?.info?["confirm"], "1")
        XCTAssertEqual(parts("[用卡：和好卡]").first?.type, .funUse)
        let pg = parts("[给钥匙：家里的｜滨江花园｜随时来]").first
        XCTAssertEqual(pg?.type, .passGive)
        XCTAssertEqual(pg?.info?["kind"], "key")
        XCTAssertEqual(pg?.info?["place"], "滨江花园")
        XCTAssertEqual(parts("[收回门禁卡：楼下]").first?.info?["act"], "revoke")
        XCTAssertEqual(parts("[刷房卡：1208]").first?.info?["kind"], "room")
        let tk = parts("[送票：《花样年华》｜10月20日 19:30｜百老汇｜7排12座]").first
        XCTAssertEqual(tk?.type, .ticketGive)
        XCTAssertEqual(tk?.info?["seat"], "7排12座")
        XCTAssertEqual(parts("[检票：花样年华]").first?.type, .ticketCheck)
        XCTAssertEqual(parts("[开会员卡：街角咖啡｜拿铁]").first?.type, .memberOpen)
        let mv = parts("[会员卡消费：街角咖啡｜3 分｜拿铁]").first
        XCTAssertEqual(mv?.type, .memberVisit)
        XCTAssertEqual(mv?.info?["points"], "3")
    }

    /// 送卡、用卡、同意：要同意的卡先挂着，同意了才算一次；删掉「同意了」那一行回到待同意
    func testFunCardFlow() throws {
        try Database.shared.put(Collections.chats, Row(fields: ["id": .string("c4"), "characterIds": .array([.string("char_d")])]))
        try Database.shared.put(Collections.characters, Row(fields: ["id": .string("char_d"), "name": .string("墨")]))
        let give = try WalletCards.post(try WalletCards.Fun.give(Message.new(chatId: "c4", role: .user, authorId: "me", content: ""),
                                                               name: "和好卡", desc: "先和好", uses: 2, days: 0, confirm: true))
        XCTAssertEqual(give.content, "[送卡：和好卡｜先和好｜2 次｜长期有效｜使用需对方同意]")
        XCTAssertThrowsError(try WalletCards.Fun.use(give.id, role: .user), "不在你手里")
        let use = try Repo.append(try WalletCards.Fun.use(give.id, role: .char))
        XCTAssertEqual(use.content, "[用卡：和好卡]（待对方同意）")
        XCTAssertEqual(WalletCards.Fun.state(give.id)?.status, "pending")
        let notice = try Repo.append(try XCTUnwrap(try WalletCards.Fun.settle(use.id, ok: true)))
        XCTAssertEqual(notice.content, "[我同意了墨使用和好卡]")
        XCTAssertEqual(WalletCards.Fun.state(give.id)?.left, 1)
        try Interact.drop(notice)
        XCTAssertEqual(WalletCards.Fun.state(give.id)?.left, 2)
        XCTAssertEqual(WalletCards.Fun.state(give.id)?.status, "pending")
    }
}
