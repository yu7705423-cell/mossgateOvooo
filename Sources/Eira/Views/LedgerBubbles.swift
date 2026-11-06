import SwiftUI

/// 会话里情侣账户与卡包那几种消息的卡片（网页版 TransferBits 的申请卡、FunCardFace、PassFace、TicketFace、MemberFace 的聊天版）。
/// 角色提的申请、角色要用一张要你同意的卡，在这张卡上表态；别的在卡包里看与操作。卡上只画这条消息自己记着的，不现算别的消息
struct LedgerBubble: View {
    static let kinds: Set<String> = ["request", "funcard", "funcard-use", "pass", "pass-act", "ticket", "ticket-act", "member", "member-act"]

    let message: Message
    let mine: Bool
    var answer: ((Bool) -> Void)?

    struct Face {
        var icon: String
        var title: String
        var detail = ""
        var foot = ""
        /// 等你表态的那两个按钮
        var ask: (yes: String, no: String)?
    }

    static func face(_ m: Message) -> Face {
        let r = m.row
        let obj = { (k: String) -> [String: JSONValue] in r[k]?.object ?? [:] }
        let s = { (o: [String: JSONValue], k: String) -> String in o[k]?.string ?? "" }
        switch m.kind {
        case "request":
            let k = r.string("requestKind")
            let code = r.string("currency").isEmpty ? nil : r.string("currency")
            let v = Interact.display(Ledger.num(r["amount"]), code)
            let title = k == LedgerRequest.joint ? "开设情侣账户" : k == LedgerRequest.card ? "亲属卡　额度 \(v)"
                : k == LedgerRequest.deposit ? "存入情侣账户　\(v)" : "动用情侣账户　\(v)"
            let st = r.string("request")
            let pending = st == LedgerRequest.pending && k != LedgerRequest.deposit
            return Face(icon: k == LedgerRequest.card ? "creditcard" : k == LedgerRequest.deposit ? "wallet.pass" : "person.2", title: title,
                        detail: (k == LedgerRequest.spend || k == LedgerRequest.deposit) ? r.string("note") : "",
                        foot: LedgerRequest.stateLabel(st, kind: k), ask: pending && m.role == .char ? (yes: "通过", no: "驳回") : nil)
        case "funcard":
            let c = obj("card")
            let uses = Int(Ledger.num(c["uses"])), exp = Ledger.num(c["expiresAt"])
            return Face(icon: "ticket", title: s(c, "name"), detail: s(c, "desc"),
                        foot: [uses > 0 ? "\(uses) 次" : "不限次数", exp > 0 ? "\(WalletCards.fmtDay(exp)) 前有效" : "长期有效",
                               Ledger.truthy(c["confirm"]) ? "使用需对方同意" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
        case "funcard-use":
            let st = r.string("useState")
            return Face(icon: "ticket", title: "使用\(r.string("cardName"))",
                        foot: st == WalletCards.Fun.pending ? "待同意" : st == WalletCards.Fun.declined ? "未同意" : "已使用",
                        ask: st == WalletCards.Fun.pending && m.role == .char ? (yes: "同意", no: "不同意") : nil)
        case "pass":
            let p = obj("pass")
            let k = WalletCards.Pass.kindOf(s(p, "kind"))
            return Face(icon: "key", title: "\(k.label)　\(s(p, "name"))", detail: [s(p, "place"), s(p, "note")].filter { !$0.isEmpty }.joined(separator: " · "),
                        foot: m.role == .user ? "给出的\(k.label)" : "收到的\(k.label)")
        case "ticket":
            let t = obj("ticket")
            let at = Ledger.num(t["at"])
            return Face(icon: "ticket", title: s(t, "title"),
                        detail: [WalletCards.Ticket.whenText(at), s(t, "venue"), s(t, "seat")].filter { !$0.isEmpty }.joined(separator: " · "),
                        foot: WalletCards.Ticket.kindOf(s(t, "kind")).label)
        case "member":
            let o = obj("member")
            return Face(icon: "creditcard", title: "会员卡　\(s(o, "shop"))", detail: s(o, "note"), foot: "两人共用")
        case "member-act":
            let n = Int(Ledger.num(r["points"]))
            return Face(icon: "creditcard", title: "会员卡消费　\(r.string("memberShop"))",
                        detail: [n > 0 ? "\(n) 分" : "", r.string("note")].filter { !$0.isEmpty }.joined(separator: " · "))
        case "ticket-act":
            return Face(icon: "ticket", title: "检票　\(r.string("ticketTitle"))")
        default:
            // pass-act：刷卡、收回、恢复，正文就是那一句
            return Face(icon: "key", title: m.content.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        }
    }

    var body: some View {
        let f = Self.face(message)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Theme.gap) {
                Image(systemName: f.icon).foregroundStyle(Theme.secondaryText).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.title).font(.system(size: Theme.bubbleFont, weight: .medium)).foregroundStyle(Theme.bubbleTheirsText)
                    if !f.detail.isEmpty {
                        Text(f.detail).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(3)
                    }
                }
            }
            if !f.foot.isEmpty {
                Text(f.foot).font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            if let ask = f.ask, !mine {
                HStack {
                    Button(ask.yes) { answer?(true) }
                    Button(ask.no) { answer?(false) }.foregroundStyle(Theme.secondaryText)
                }
                .font(.footnote).buttonStyle(.bordered)
            }
        }
        .frame(minWidth: 160, maxWidth: 260, alignment: .leading)
        .padding(Theme.pad)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    }

    /// 你在卡片上表态（网页版 request.settle、funcard.settle）。返回那一行提示，由会话页追加
    static func settle(_ m: Message, _ yes: Bool) throws -> Message? {
        if m.kind == "request" { return try LedgerRequest.settle(m.id, ok: yes) }
        return try WalletCards.Fun.settle(m.id, ok: yes)
    }
}

/// 发起申请（网页版 TransferBits 的 RequestSheet）。四种共用一张，选哪一种决定要不要填金额
struct LedgerRequestSheet: View {
    let chatId: String
    @Environment(\.dismiss) private var dismiss
    @State private var kind = LedgerRequest.spend
    @State private var amount = ""
    @State private var note = ""
    @State private var problem: String?
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let book = Ledger.bookOfChat(chatId)
        let joint = book.map { Ledger.hasJoint($0.id) } ?? false
        let kinds: [(String, String)] = (joint ? [(LedgerRequest.deposit, "存入"), (LedgerRequest.spend, "动用")] : [(LedgerRequest.joint, "开设情侣账户")])
            + [(LedgerRequest.card, "亲属卡")]
        let cur = kinds.contains { $0.0 == kind } ? kind : kinds[0].0
        let needAmount = cur != LedgerRequest.joint
        let mine = book.flatMap { Ledger.defaultFor($0.id, Ledger.me) }
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if book == nil {
                Section {
                    NavigationLink("建立账本并关联这段对话") { BooksView(newChatId: chatId) }
                } footer: {
                    Text("这段对话还没有关联账本。情侣账户、亲属卡与申请都记在账本上，需要先建立一本并关联该对话。")
                }
            }
            Section {
                Picker("种类", selection: Binding(get: { cur }, set: { kind = $0 })) {
                    ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                if needAmount {
                    TextField(cur == LedgerRequest.card ? "额度" : "金额", text: $amount).keyboardType(.decimalPad)
                    if cur == LedgerRequest.deposit, let book, let mine {
                        Text("从本人的钱包存入。当前余额 \(Ledger.money(book.id, Ledger.balanceOf(book.id, mine.id)))").font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
                if cur == LedgerRequest.spend || cur == LedgerRequest.deposit {
                    TextField("用途，可以不写", text: $note)
                }
            } footer: {
                HelpNote(cur == LedgerRequest.joint ? "对方通过后，账本中会建立情侣账户。双方均可存入，动用需对方批准。"
                    : cur == LedgerRequest.deposit ? "发出即存入，不需要对方批准。金额从本人的钱包转入情侣账户。"
                    : cur == LedgerRequest.card ? "对方通过后，对方消费时将在额度内从你的余额扣除。额度用尽后恢复从对方余额扣除。"
                    : "对方通过后，该金额从情侣账户扣除。", title: "申请")
            }
            Section {
                Button(cur == LedgerRequest.deposit ? "存入" : "发出申请") { submit(cur) }
                    .disabled(book == nil || (needAmount && !(Ledger.parse(amount) > 0)))
            }
        }
        .navigationTitle("申请")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onReceive(NotificationCenter.default.publisher(for: .eiraLedgerChanged)) { _ in tick += 1 }
    }

    private func submit(_ kind: String) {
        do {
            try LedgerRequest.sendFromUser(chatId: chatId, kind: kind, amount: Ledger.parse(amount), note: note)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}
