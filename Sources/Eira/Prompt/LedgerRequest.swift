import Foundation

/// 申请（网页版 system/request.js，ARCHITECTURE 4.278）：开设情侣账户、动用情侣账户、发亲属卡、存入情侣账户。
///
/// 和转账同一个形状：一条消息带着状态，收到的一方通过或驳回，表完态落一行提示，提示行被删就当没表过态。
/// 存入情侣账户发出即落定，不必对方点头。**钱怎么动不在这里**：批过之后由 Ledger 读这条消息的状态现折（Ledger.chatEntries）。
/// 开设情侣账户、发亲属卡批准后在账本上建出账户与卡：那是结构不是钱，不随消息撤销（网页版 apply）。
enum LedgerRequest {
    static let pending = "pending", approved = "approved", rejected = "rejected"
    static let joint = "joint", spend = "spend", card = "card", deposit = "deposit"
    static let kinds = [joint, spend, card, deposit]

    static func stateLabel(_ state: String, kind: String = "") -> String {
        if kind == deposit { return "已存入" }
        return state == approved ? "已通过" : state == rejected ? "已驳回" : "待处理"
    }

    /// 上下文里的写法。模型读到的和它自己该写的是同一套格式
    static func content(kind: String, amount: Double, note: String, state: String, code: String?) -> String {
        let v = amount != 0 ? Interact.format(amount, code) : ""
        let head: String
        switch kind {
        case joint: head = "[开设情侣账户]"
        case card: head = "[亲属卡：额度 \(v)]"
        case deposit: head = "[存入情侣账户：\(v)]"
        default: head = "[申请：\(note.isEmpty ? "动用情侣账户" : note) \(v)]"
        }
        if kind == deposit { return head }
        return state == approved ? head + "（已通过）" : state == rejected ? head + "（已驳回）" : head
    }

    /// 一条申请。base 带上这一轮的公共字段（谁发的、turnId）
    static func make(_ base: Message, kind: String, amount: Double = 0, note: String = "") throws -> Message {
        guard kinds.contains(kind) else { throw StoreError(message: "不认识这种申请") }
        let code = Interact.currency().code
        let v = Interact.round(amount.isFinite ? amount : 0, code)
        if kind != joint && !(v > 0) { throw StoreError(message: "金额需大于 0") }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // 存入不用等对方点头：发出即落定
        let state = kind == deposit ? approved : pending
        var m = base
        m.row["kind"] = .string("request")
        m.row["requestKind"] = .string(kind)
        m.row["amount"] = .number(v)
        m.row["note"] = .string(text)
        m.row["request"] = .string(state)
        m.row["currency"] = .string(code)
        m.row["content"] = .string(content(kind: kind, amount: v, note: text, state: state, code: code))
        m.row["status"] = .string("done")
        return m
    }

    /// 你在会话里或钱包页发一条（网页版 RequestSheet、PoolPage 的存入）。存入先看自己的钱够不够（第二道关）
    @discardableResult
    static func sendFromUser(chatId: String, kind: String, amount: Double = 0, note: String = "") throws -> Message {
        if kind == deposit && !Ledger.affordable(chatId, Ledger.me, amount) { throw StoreError(message: "余额不足，存不了这么多") }
        let m = try make(Message.new(chatId: chatId, role: .user, authorId: "me", content: ""), kind: kind, amount: amount, note: note)
        let out = try Repo.append(m)
        try touch(chatId)
        Ledger.changed()
        return out
    }

    static func touch(_ chatId: String) throws {
        if var c = try Repo.chat(chatId) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
    }

    /// 这段对话里某一方提的、还没处理的最近一条。角色写 [批准] 时找的就是你提的那一条
    static func pendingFrom(_ chatId: String, role: Message.Role) throws -> Message? {
        try Repo.messages(chatId: chatId).last { $0.kind == "request" && $0.role == role && $0.row.string("request") == pending }
    }

    private static func names(_ chatId: String) -> (me: String, char: String, charId: String) { Interact.names(chatId) }

    /// 批准或驳回：改状态与正文，返回那一行提示（由调用方追加）。批准开设、亲属卡时同步在账本上建出来
    static func settle(_ msgId: String, ok: Bool, turnId: String? = nil) throws -> Message? {
        guard var row = try Database.shared.get(Collections.messages, id: msgId) else { return nil }
        let m = Message(row: row)
        guard m.kind == "request", row.string("request") == pending else { return nil }
        let state = ok ? approved : rejected
        let kind = row.string("requestKind"), amount = Ledger.num(row["amount"])
        let code = row.string("currency").isEmpty ? nil : row.string("currency")
        row["request"] = .string(state)
        row["content"] = .string(content(kind: kind, amount: amount, note: row.string("note"), state: state, code: code))
        row.touch()
        try Database.shared.put(Collections.messages, row)

        let n = names(m.chatId)
        let byUser = m.role != .user
        let who = byUser ? n.me : n.char
        let from = byUser ? n.char : n.me
        if ok { apply(m) }
        let what = kind == joint ? "开设情侣账户的申请"
            : kind == card ? "开出的亲属卡（额度 \(Interact.format(amount, code))）"
            : "动用情侣账户 \(Interact.format(amount, code)) 的申请"
        var notice = Message.new(chatId: m.chatId, role: byUser ? .user : .char, authorId: byUser ? "me" : (n.charId.isEmpty ? m.authorId : n.charId),
                                 content: "[\(who)\(ok ? "通过了" : "驳回了")\(from)\(what)]", kind: "notice", turnId: turnId)
        notice.row["settledId"] = .string(msgId)
        notice.row["settledKind"] = .string("request")
        Ledger.changed()
        return notice
    }

    /// 批准之后要落在账本上的那部分结构。金额不在这里动；同步落，紧接着的存入才有处可去
    private static func apply(_ m: Message) {
        let owner = m.role == .user ? Ledger.me : Ledger.char
        do {
            guard let book = Ledger.bookOfChat(m.chatId) else { return }
            switch m.row.string("requestKind") {
            case joint: try Ledger.ensureJoint(book.id)
            case card:
                // 发卡的是提出的那一方，收卡的是表态的那一方
                try Ledger.addCard(book.id, from: owner, to: owner == Ledger.me ? Ledger.char : Ledger.me, limit: Ledger.num(m.row["amount"]))
            default: break
            }
        } catch {
            Problems.report("申请已通过，但未能记到账本上：\(error.localizedDescription)")
        }
    }

    /// 提示行被删就当没表过态（重新生成那一轮时整轮清掉，走的也是这里）
    static func unsettle(_ notice: Message) throws {
        let id = notice.row.string("settledId")
        guard notice.kind == "notice", !id.isEmpty, var row = try Database.shared.get(Collections.messages, id: id),
              row.string("kind") == "request" else { return }
        let code = row.string("currency").isEmpty ? nil : row.string("currency")
        row["request"] = .string(pending)
        row["content"] = .string(content(kind: row.string("requestKind"), amount: Ledger.num(row["amount"]), note: row.string("note"), state: pending, code: code))
        row.touch()
        try Database.shared.put(Collections.messages, row)
        Ledger.changed()
    }

    // MARK: - 角色在回复里写的（网页版 reply.js 的 request 与 vote）

    /// [申请：…]、[亲属卡：…]、[开设情侣账户]、[存入情侣账户：…]。动用时情侣账户不够就不发，落一行说明；
    /// 存入时没有情侣账户、或者存入方的钱不够，同样落一行说明
    static func fromChar(_ base: Message, kind: String, amount: Double, note: String) throws -> Message? {
        let label = Interact.format(amount)
        if kind == spend, let book = Ledger.bookOfChat(base.chatId), book.strict, let j = Ledger.defaultFor(book.id, Ledger.joint),
           Ledger.balanceOf(book.id, j.id) < abs(amount) {
            return notice(base, "[情侣账户余额不足，\(label) 的申请没有发出]")
        }
        if kind == deposit {
            guard let book = Ledger.bookOfChat(base.chatId), Ledger.hasJoint(book.id) else {
                return notice(base, "[还没有情侣账户，\(label) 没有存入]")
            }
            if let short = Ledger.broke(base, amount: amount, what: "存入情侣账户 \(label)") { return short }
        }
        return try? make(base, kind: kind, amount: amount, note: note)
    }

    private static func notice(_ base: Message, _ text: String) -> Message {
        var m = base
        m.row["kind"] = .string("notice")
        m.row["content"] = .string(text)
        m.row["status"] = .string("done")
        return m
    }
}
