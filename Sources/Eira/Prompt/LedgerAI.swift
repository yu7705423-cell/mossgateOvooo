import Foundation

/// 记账与卡包里点了才调接口的两件事（网页版 ai/tasks/money.js、ai/tasks/idcard.js）。**用户点了才调，一次一个请求**，
/// 按钮上写着要调一次接口；不是自动触发的，不进 ExtraCalls（网页版第 15 条）。CostTests 数着。
enum LedgerAI {
    static let moneyTask = "char.money"
    static let idcardTask = "idcard.read"

    private static func ask(_ task: String, system: String, maxTokens: Int) async throws -> JSONValue {
        let r = try await AIService.shared.send(task: task, system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: maxTokens, retries: 1)
        guard let json = JSONReply.parse(r.text) else { throw StoreError(message: JSONReply.failure(r.text)) }
        return json
    }

    // MARK: - 角色的钱（4.278）

    /// 按角色卡生成起始余额与每月固定收支，落账；回来的是写在账本上的那份说明。
    /// 上一次生成的起始余额、固定收支（by 为 ai）整批换掉，用户自己记的流水与固定入账不动
    @discardableResult
    static func generate(_ bookId: String) async throws -> [String: JSONValue] {
        guard let book = Ledger.get(bookId) else { throw StoreError(message: "账本不存在") }
        guard let char = Ledger.whoOf(bookId).charRow else { throw StoreError(message: "这本账还没有关联对话") }
        guard let acc = try Ledger.ensureChar(bookId) else { throw StoreError(message: "这本账还没有关联对话") }
        let card = [char.persona, char.row.string("description"), char.scenario].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let system = Templates.render("task.char-money", [
            "charName": char.row.string("name"),
            "charPersona": card.isEmpty ? "(no settings written)" : card,
            "currency": Interact.currency(book.code).code,
        ], settings: .load())
        let out = try await ask(moneyTask, system: system, maxTokens: 900)
        return try apply(bookId, accountId: acc.id, out)
    }

    static func apply(_ bookId: String, accountId: String, _ out: JSONValue) throws -> [String: JSONValue] {
        func amount(_ v: JSONValue?) -> Double { abs(Ledger.num(v)) }
        func rows(_ v: JSONValue?) -> [(day: Double, amount: Double, note: String)] {
            (v?.array ?? []).map { r in
                let d = Ledger.num(r["day"]).rounded()
                return (max(1, min(28, d == 0 ? 1 : d)), amount(r["amount"]), (r["note"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            }.filter { $0.amount > 0 }
        }
        let income = rows(out["income"]), expenses = rows(out["expenses"])
        for r in Ledger.rulesOf(bookId) where r.by == "ai" { try Ledger.removeRule(bookId, r.id) }
        try Ledger.seed(bookId, accountId, amount(out["balance"]))
        for r in income {
            try Ledger.addRule(bookId, accountId: accountId, day: r.day, amount: r.amount, category: "salary", note: r.note.isEmpty ? "收入" : r.note, by: "ai")
        }
        for r in expenses {
            try Ledger.addRule(bookId, accountId: accountId, day: r.day, amount: -r.amount, category: "home", note: r.note.isEmpty ? "固定支出" : r.note, by: "ai")
        }
        func list(_ xs: [(day: Double, amount: Double, note: String)]) -> JSONValue {
            .array(xs.map { .object(["day": .number($0.day), "amount": .number($0.amount), "note": .string($0.note)]) })
        }
        let info: [String: JSONValue] = [
            "summary": .string((out["summary"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
            "balance": .number(amount(out["balance"])),
            "income": list(income), "expenses": list(expenses),
            "at": .number(Date().millis),
        ]
        try Ledger.setCharMoney(bookId, .object(info))
        return info
    }

    // MARK: - 证件（4.644）：从角色卡读出单位、身份与编号。读出来的先填进编辑框，保存后才生效

    static func readIdCard(_ charId: String) async throws -> WalletCards.IdCard.Card {
        guard let c = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        let card = [c.persona, c.scenario, c.signature].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !card.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError(message: "角色卡里还没有写人设") }
        let name = c.row.string("name")
        let system = Templates.render("task.idcard-read", ["name": name.isEmpty ? "the character" : name, "card": card], settings: .load())
        let out = try await ask(idcardTask, system: system, maxTokens: 300)
        return WalletCards.IdCard.clean(out) ?? WalletCards.IdCard.Card(kind: "other")
    }
}
