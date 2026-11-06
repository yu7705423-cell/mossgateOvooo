import SwiftUI

/// 卡包的卡面底色（网页版 tokens.css 的 --wl-*，低饱和）与卡面上的字（--wl-on）。只用在卡面上
extension Theme {
    static let walletOn = pair(hex(0xFFFFFF), hex(0xFFFFFF))

    static func wallet(_ id: String) -> Color {
        switch id {
        case "rose": return pair(hex(0xB9776F), hex(0x9C6159))
        case "pink": return pair(hex(0xC98E9E), hex(0xA87382))
        case "peach": return pair(hex(0xD29F7E), hex(0xAE8263))
        case "sand": return pair(hex(0xB8A27C), hex(0x998662))
        case "mint": return pair(hex(0x7FA590), hex(0x668A76))
        case "sky": return pair(hex(0x7C9DBB), hex(0x63819D))
        case "lilac": return pair(hex(0x9C8DB8), hex(0x82749C))
        case "joint": return pair(hex(0x6E5B6E), hex(0x57475A))
        case "kin": return pair(hex(0x556B63), hex(0x44574F))
        case "debit": return pair(hex(0x2D3036), hex(0x1F2125))
        default: return pair(hex(0x4A4E57), hex(0x3A3D45))
        }
    }
}

/// 卡包（网页版 apps/wallet，ARCHITECTURE 4.611 至 4.644）：一排分类，一次只看一类；每一类左右滑着看卡，下面是那一张的详情。
///
/// 账户读「记账」里当前那本账（不另记一份钱，改在记账里改）；娱乐卡、门禁卡、票券、会员卡都是与那个角色的对话里的消息，
/// 送出、使用、收回都会在对话中留下一条；证件存在人身上，不进提示词；纪念卡读情侣空间。
struct WalletHomeView: View {
    var openKey = ""
    @State private var tab = "acc"
    @State private var pick: [String: String] = [:]
    @State private var tick = 0
    @State private var problem: String?
    @State private var adding = false
    @State private var page: NewPage?
    @State private var naming: AccKind?
    @State private var accName = ""
    @State private var funSide = "held"

    enum NewPage: Hashable { case fun, pass, ticket, member, id }
    enum AccKind: Identifiable { case transit, bank; var id: Int { self == .transit ? 0 : 1 } }

    static let tabs: [(String, String)] = [("acc", "账户"), ("pass", "通行"), ("ticket", "票券"), ("member", "会员"), ("id", "证件"), ("fun", "娱乐"), ("memo", "纪念")]

    var body: some View {
        let _ = tick
        let items = itemsFor(tab)
        let here = items.filter { !$0.gone }.count
        let counts: [String: Int] = Dictionary(uniqueKeysWithValues: Self.tabs.map { t in (t.0, t.0 == tab ? here : countOf(t.0)) })
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sp4) {
                if let problem { Text(problem).foregroundStyle(Theme.danger).padding(.horizontal) }
                ChipStrip(items: Self.tabs.map { t in (t.0, (counts[t.0] ?? 0) > 0 ? "\(t.1) \(counts[t.0] ?? 0)" : t.1) }, selected: tab) { id in
                    if let id { tab = id }
                }
                .padding(.horizontal)
                if tab == "fun" {
                    Picker("娱乐卡", selection: $funSide) {
                        Text("收到的").tag("held")
                        Text("送出的").tag("given")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }
                let live = items.filter { !$0.gone && (tab != "fun" || $0.side == funSide) }
                if live.isEmpty {
                    EmptyState(title: emptyTitle(tab), desc: emptyDesc(tab))
                } else {
                    let sel = Binding(get: { pick[tab].flatMap { k in live.contains { $0.key == k } ? k : nil } ?? live[0].key },
                                      set: { pick[tab] = $0 })
                    TabView(selection: sel) {
                        ForEach(live) { it in it.face.padding(.horizontal, Theme.sp6).tag(it.key) }
                    }
                    .tabViewStyle(.page(indexDisplayMode: live.count > 1 ? .always : .never))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                    .frame(height: 230)
                    if let cur = live.first(where: { $0.key == sel.wrappedValue }) {
                        cur.detail.padding(.horizontal)
                    }
                }
                let gone = items.filter(\.gone)
                if !gone.isEmpty {
                    WalletList(title: "已失效", rows: gone.map { WRow(id: $0.key, title: $0.label, value: $0.goneNote) })
                        .padding(.horizontal)
                }
                HelpNote("账户读取自「记账」中当前的账本。娱乐卡、门禁卡、票券、会员卡都在与该角色的对话中，送出、使用、收回都会在对话中留下一条。纪念卡读取自「情侣空间」，证件只保存在本设备。", title: "卡包")
            }
            .padding(.vertical)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("卡包")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加")
            }
        }
        .confirmationDialog("添加", isPresented: $adding, titleVisibility: .visible) {
            Button("娱乐卡") { page = .fun }
            Button("门禁卡、钥匙、房卡") { page = .pass }
            Button("电影票、演出票") { page = .ticket }
            Button("会员卡") { page = .member }
            Button("工牌、学生证") { page = .id }
            Button("交通卡") { accName = "交通卡"; naming = .transit }
            Button("银行卡或账户") { accName = ""; naming = .bank }
        } message: {
            Text("娱乐卡、门禁卡、票券送给角色，送出后出现在对话中；会员卡两人共用；交通卡与银行卡记在当前账本上。")
        }
        .alert(naming == .transit ? "交通卡的名字" : "账户的名字", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField(naming == .transit ? "例如：地铁卡" : "例如：招行储蓄卡", text: $accName)
            Button("添加") { addAccount() }
            Button("取消", role: .cancel) { naming = nil }
        }
        .navigationDestination(item: $page) { p in
            switch p {
            case .fun: NewFunCardView()
            case .pass: NewPassView()
            case .ticket: NewTicketView()
            case .member: NewMemberView()
            case .id: IdPickView()
            }
        }
        .onAppear {
            if !openKey.isEmpty, let k = openKey.split(separator: ":").first {
                tab = ["fc": "fun", "ps": "pass", "tk": "ticket", "mb": "member", "ac": "acc"][String(k)] ?? tab
                pick[tab] = openKey
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .eiraLedgerChanged)) { _ in tick += 1 }
        .newFeatAsk(app: "wallet")
    }

    private func addAccount() {
        let kind = naming == .transit ? "transit" : ""
        do {
            guard let bk = try Ledger.current() ?? Ledger.ensure() else { return }
            let a = try Ledger.addAccount(bk.id, name: accName, owner: Ledger.me, kind: kind)
            tab = "acc"
            pick["acc"] = "ac:\(a.id)"
            problem = nil
        } catch { problem = "未能添加：\(error.localizedDescription)" }
        naming = nil
        tick += 1
    }

    static func ticketState(_ s: WalletCards.Ticket.State) -> String {
        if s.status == "checked" { return "已检票" }
        if s.status == "expired" { return "已过期" }
        guard let d = s.daysLeft else { return "" }
        return d > 0 ? "还有 \(d) 天" : d == 0 ? "今天" : ""
    }

    private func emptyTitle(_ t: String) -> String {
        switch t {
        case "acc": return Ledger.current() == nil ? "还没有账本" : "还没有账户"
        case "pass": return "还没有门禁卡与钥匙"
        case "ticket": return "还没有票"
        case "member": return "还没有会员卡"
        case "id": return "还没有证件"
        case "memo": return "还没有纪念卡"
        default: return funSide == "held" ? "还没有收到娱乐卡" : "还没有送出娱乐卡"
        }
    }

    private func emptyDesc(_ t: String) -> String {
        switch t {
        case "acc": return Ledger.current() == nil ? "在「记账」中建立账本后，你的账户、情侣账户与亲属卡会出现在这里。" : "点右上角的加号添加银行卡或交通卡。"
        case "pass": return "点右上角的加号，给角色一张门禁卡、钥匙或房卡。"
        case "ticket": return "点右上角的加号，送角色一张电影票或演出票。"
        case "member": return "点右上角的加号，和角色开一张常去店铺的会员卡。"
        case "id": return "点右上角的加号，填写角色或自己的工牌、学生证。"
        case "memo": return "和一个角色开始单聊后，这里显示你们在一起的天数与纪念日。"
        default: return funSide == "held" ? "" : "点右上角的加号，送角色一张和好卡、亲亲卡之类的卡。"
        }
    }

    private func countOf(_ t: String) -> Int {
        switch t {
        case "acc": return Ledger.current().map { WalletItems.accounts($0).count } ?? 0
        case "pass": return WalletCards.Pass.allPasses().count
        case "ticket": return WalletCards.Ticket.allTickets().filter { $0.status == "active" }.count
        case "member": return WalletCards.Member.allCards().count
        case "id": return WalletItems.ids().count
        case "memo": return WalletCards.singleChats().count
        default: return WalletCards.Fun.allCards().filter { $0.status != "expired" && $0.status != "spent" }.count
        }
    }

    private func itemsFor(_ t: String) -> [WalletItem] {
        let reload = { tick += 1 }
        let report = { (e: Error) in problem = e.localizedDescription }
        switch t {
        case "acc":
            guard let book = Ledger.current() else { return [] }
            return WalletItems.accounts(book).map { it in
                WalletItem(key: it.key, label: it.title, face: AnyView(WalletFace(eyebrow: it.eyebrow, title: it.title, big: it.amount, left: it.sub, right: it.right, tone: it.tone)),
                           detail: AnyView(AccountDetail(book: book, it: it, changed: reload, failed: report)))
            }
        case "pass":
            return WalletCards.Pass.allPasses().map { s in
                WalletItem(key: "ps:\(s.id)", label: s.name,
                           face: AnyView(WalletFace(eyebrow: WalletCards.Pass.kindOf(s.kind).eyebrow, title: s.name, big: s.place.isEmpty ? s.kindLabel : s.place,
                                                    left: s.holder == "user" ? "\(s.charName)给你" : "给\(s.charName)", right: s.revoked ? "权限已收回" : s.checkedOut ? "已退房" : "有效", tone: "ink")),
                           detail: AnyView(PassDetail(s: s, changed: reload, failed: report)))
            }
        case "ticket":
            return WalletCards.Ticket.allTickets().map { s in
                WalletItem(key: "tk:\(s.id)", label: s.title,
                           face: AnyView(WalletFace(eyebrow: WalletCards.Ticket.kindOf(s.kind).eyebrow, title: s.title, big: WalletCards.Ticket.whenText(s.at),
                                                    left: [s.holder == "user" ? "\(s.charName)送你" : "送给\(s.charName)", s.venue, s.seat].filter { !$0.isEmpty }.joined(separator: " · "),
                                                    right: Self.ticketState(s), tone: "sand")),
                           detail: AnyView(TicketDetail(s: s, changed: reload, failed: report)))
            }
        case "member":
            return WalletCards.Member.allCards().map { s in
                WalletItem(key: "mb:\(s.id)", label: s.shop,
                           face: AnyView(WalletFace(eyebrow: "MEMBER", title: s.shop, big: "\(s.points) 分", left: "和\(s.charName)共用", right: "去过 \(s.visits) 次", tone: "mint")),
                           detail: AnyView(MemberDetail(s: s, changed: reload, failed: report)))
            }
        case "id":
            return WalletItems.ids().map { x in
                let k = WalletCards.IdCard.kindOf(x.card.kind)
                return WalletItem(key: "id:\(x.id)", label: x.name,
                                  face: AnyView(WalletFace(eyebrow: k.eyebrow, title: x.name, big: x.card.org.isEmpty ? k.label : x.card.org,
                                                           left: [x.card.dept, x.card.title].filter { !$0.isEmpty }.joined(separator: " · "), right: x.card.no, tone: "debit")),
                                  detail: AnyView(NavigationLink("修改") { IdEditView(id: x.id, me: x.me) }.buttonStyle(.bordered)))
            }
        case "memo":
            return WalletCards.singleChats().map { p in
                let days = Space.togetherDays(p.chat) ?? 0
                let list = Space.days(p.chat.id).map { ($0, Space.leftDays($0)) }.filter { $0.1 >= 0 }.sorted { $0.1 < $1.1 }
                let next = list.first.map { $0.1 == 0 ? "今天是\($0.0.string("title"))" : "\($0.0.string("title"))还有 \($0.1) 天" } ?? ""
                return WalletItem(key: "mm:\(p.chat.id)", label: p.char.displayName,
                                  face: AnyView(WalletFace(eyebrow: "TOGETHER", title: p.char.displayName, big: "\(days) 天", left: next, right: "在一起", tone: "rose")),
                                  detail: AnyView(WalletList(title: "纪念日", rows: list.map { d in
                                      WRow(id: d.0.id, title: d.0.string("title"), value: d.1 == 0 ? "今天" : "还有 \(d.1) 天")
                                  }, empty: "还没有纪念日")))
            }
        default:
            return WalletCards.Fun.allCards().map { s in
                let left = s.uses > 0 ? "\(s.left ?? 0) / \(s.uses) 次" : "不限次数"
                let gone = s.status == "expired" || s.status == "spent"
                return WalletItem(key: "fc:\(s.id)", label: s.name,
                                  face: AnyView(WalletFace(eyebrow: "FUN CARD", title: s.name, big: left,
                                                           left: s.holder == "user" ? "\(s.charName)送你" : "送给\(s.charName)",
                                                           right: s.expiresAt > 0 ? "\(WalletCards.fmtDay(s.expiresAt)) 前" : "长期有效", tone: s.color)),
                                  detail: AnyView(FunDetail(s: s, changed: reload, failed: report)),
                                  side: s.holder == "user" ? "held" : "given", gone: gone,
                                  goneNote: "\(s.holder == "user" ? "\(s.charName)送你" : "送给\(s.charName)") · \(s.status == "expired" ? "已过期" : "次数已用完")")
            }
        }
    }
}

struct WalletItem: Identifiable {
    let key: String
    var id: String { key }
    let label: String
    let face: AnyView
    let detail: AnyView
    var side = ""
    var gone = false
    var goneNote = ""
}

/// 账户那一类要画成卡的几张：你的账户、情侣账户、两个方向的亲属卡（网页版 accountCards）
enum WalletItems {
    struct Acc {
        let key: String
        let type: String
        let acc: Ledger.Account?
        let card: Ledger.Card?
        let title: String
        let tone: String
        let locked: Bool
        let amount: String
        let sub: String
        var eyebrow: String { type == "kin" ? "FAMILY CARD" : type == "transit" ? "TRANSIT" : tone == "joint" ? "JOINT" : "DEBIT" }
        var right: String { type == "kin" ? "剩余额度" : locked ? "私密账户" : "余额" }
    }

    static func accounts(_ book: Ledger.Book) -> [Acc] {
        var out: [Acc] = []
        for a in book.accounts where a.owner == Ledger.me || a.owner == Ledger.joint {
            let transit = a.kind == "transit"
            let locked = !a.open
            out.append(Acc(key: "ac:\(a.id)", type: transit ? "transit" : "account", acc: a, card: nil,
                           title: a.name.isEmpty ? (transit ? "交通卡" : a.owner == Ledger.joint ? "情侣账户" : "我的账户") : a.name,
                           tone: transit ? "sky" : a.owner == Ledger.joint ? "joint" : "debit", locked: locked,
                           amount: locked ? "已锁定" : Ledger.money(book.id, Ledger.balanceOf(book.id, a.id)),
                           sub: transit ? "交通卡" : a.owner == Ledger.joint ? "情侣账户" : "日常开销"))
        }
        let who = Ledger.whoOf(book.id)
        let name = who.charRow?.displayName ?? "角色"
        for c in book.cards where c.active && (c.to == Ledger.me || c.from == Ledger.me) {
            let lim = Ledger.money(book.id, c.limit)
            out.append(Acc(key: "kin:\(c.id)", type: "kin", acc: nil, card: c, title: "亲属卡", tone: "kin", locked: false,
                           amount: Ledger.money(book.id, Ledger.cardLeft(book.id, c)),
                           sub: c.to == Ledger.me ? "\(name)送你 · 额度 \(lim)" : "送给\(name) · 额度 \(lim)"))
        }
        return out
    }

    struct Person { let id: String; let me: Bool; let name: String; let card: WalletCards.IdCard.Card }

    /// 有证件的人：自己（当前账号）与好友列表里看得见的角色
    static func ids() -> [Person] {
        var out: [Person] = []
        let ps = (try? Repo.personas()) ?? []
        if let me = Isolate.current(ps, .load()), let c = WalletCards.IdCard.of(me.id, me: true) {
            out.append(Person(id: me.id, me: true, name: me.row.string("name").isEmpty ? "我" : me.row.string("name"), card: c))
        }
        for ch in (try? Repo.characters()) ?? [] where (ch.parentId ?? "").isEmpty && Isolate.seesChar(ch) {
            if let c = WalletCards.IdCard.of(ch.id) { out.append(Person(id: ch.id, me: false, name: ch.displayName, card: c)) }
        }
        return out
    }
}

/// 一张卡的卡面：上面一行是哪一类，名字，中间大字，底下两头各一行
struct WalletFace: View {
    let eyebrow: String
    let title: String
    let big: String
    var left = ""
    var right = ""
    var tone = "ink"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sp2) {
            Text(eyebrow).font(.system(size: 11, weight: .semibold)).kerning(1.2).opacity(0.8)
            Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Text(big).font(Theme.serif(26)).lineLimit(1).minimumScaleFactor(0.5).monospacedDigit()
            HStack {
                Text(left).lineLimit(1)
                Spacer()
                Text(right).lineLimit(1)
            }
            .font(.system(size: 12)).opacity(0.85)
        }
        .foregroundStyle(Theme.walletOn)
        .padding(Theme.sp5)
        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 190, alignment: .leading)
        .background(Theme.wallet(tone), in: RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct WRow: Identifiable {
    let id: String
    var title: String
    var sub = ""
    var value = ""
}

/// 详情里那一块。会一直变多的（流水、使用记录）只列最近的 limit 条，组名写着一共几条，其余点「查看全部」进整页（第 26 条）
struct WalletList: View {
    let title: String
    let rows: [WRow]
    var empty = ""
    var counted = true
    var limit = 20

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sp2) {
            HStack {
                Text(title + (counted && !rows.isEmpty ? " · \(rows.count)" : "")).font(.footnote).foregroundStyle(Theme.text2)
                Spacer()
                if rows.count > limit {
                    NavigationLink("查看全部") { WalletAllView(title: title, rows: rows) }.font(.footnote)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty { WalletLine(title: empty) }
                ForEach(rows.prefix(limit)) { r in WalletLine(title: r.title, sub: r.sub, value: r.value) }
            }
            .padding(.horizontal, Theme.sp3)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
        }
    }
}

/// 整页的那一份
struct WalletAllView: View {
    let title: String
    let rows: [WRow]

    var body: some View {
        List(rows) { r in WalletLine(title: r.title, sub: r.sub, value: r.value) }
            .navigationTitle("\(title) · \(rows.count)")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct WalletLine: View {
    let title: String
    var sub = ""
    var value = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.text)
                if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(Theme.text3) }
            }
            Spacer()
            if !value.isEmpty { Text(value).foregroundStyle(Theme.text2) }
        }
        .padding(.vertical, 10)
    }
}

enum WalletText {
    static func day(_ ms: Double) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(millis: ms))
        return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    static func time(_ ms: Double) -> String {
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: Date(millis: ms))
        return "\(c.month ?? 0)月\(c.day ?? 0)日 " + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

// MARK: - 详情

private struct AccountDetail: View {
    let book: Ledger.Book
    let it: WalletItems.Acc
    var changed: () -> Void
    var failed: (Error) -> Void
    @State private var topping = false
    @State private var riding = false
    @State private var amount = ""
    @State private var from = ""

    var body: some View {
        let rows = it.type == "kin" ? Ledger.recent(book.id).filter { $0.cardId == it.card?.id } :
            Ledger.recent(book.id).filter { $0.accountId == it.acc?.id && !$0.pending }
        VStack(alignment: .leading, spacing: Theme.sp3) {
            if it.locked {
                WalletList(title: "最近流水", rows: [WRow(id: "locked", title: "私密账户已锁定", sub: "在「记账」中输入密码后才显示余额与流水")], counted: false)
            } else {
                WalletList(title: it.type == "kin" ? "这张卡的消费" : "最近流水", rows: rows.map { e in
                    WRow(id: e.id, title: e.note.isEmpty ? Ledger.labelOf(e) : e.note, sub: WalletText.time(e.at),
                         value: (e.amount > 0 ? "+" : "-") + Ledger.money(book.id, abs(e.amount)))
                }, empty: "还没有流水")
            }
            if it.type == "transit", let acc = it.acc {
                HStack {
                    Button("充值") { amount = ""; from = others(acc).first?.id ?? ""; topping = true }
                    Button("乘车") {
                        let last = Ledger.recent(book.id).first { $0.accountId == acc.id && $0.amount < 0 && $0.src != "move" }
                        amount = last.map { WalletCards.numText(-$0.amount) } ?? ""
                        riding = true
                    }
                }
                .buttonStyle(.bordered)
                .alert("充值金额", isPresented: $topping) {
                    TextField("例如：50", text: $amount).keyboardType(.decimalPad)
                    ForEach(others(acc)) { a in Button("从「\(a.name)」充值") { from = a.id; topUp(acc) } }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(others(acc).isEmpty ? "先在记账中建一个自己的账户，再从它充值。" : "充值是从自己的另一个账户挪过来，不算收支。")
                }
                .alert("这一程多少钱", isPresented: $riding) {
                    TextField("例如：3", text: $amount).keyboardType(.decimalPad)
                    Button("记下") { ride(acc) }
                    Button("取消", role: .cancel) {}
                }
            }
            Button("在记账中查看") { Notifier.shared.openApp = "bill" }.buttonStyle(.bordered)
        }
    }

    private func others(_ acc: Ledger.Account) -> [Ledger.Account] {
        book.accounts.filter { $0.id != acc.id && $0.owner == Ledger.me && $0.kind != "transit" }
    }

    private func topUp(_ acc: Ledger.Account) {
        do { try Ledger.moveBetween(book.id, from, acc.id, Ledger.parse(amount), note: "\(acc.name)充值"); changed() } catch { failed(error) }
    }

    private func ride(_ acc: Ledger.Account) {
        let n = abs(Ledger.parse(amount))
        guard n > 0 else { failed(StoreError(message: "请填写金额")); return }
        do { try Ledger.add(bookId: book.id, accountId: acc.id, amount: -n, category: "transit", sub: "metro", note: "乘车"); changed() } catch { failed(error) }
    }
}

private struct PassDetail: View {
    let s: WalletCards.Pass.State
    var changed: () -> Void
    var failed: (Error) -> Void
    @State private var asking = ""

    var body: some View {
        let mine = s.holder == "user"
        let who = s.charName.isEmpty ? "角色" : s.charName
        let use = WalletCards.Pass.kindOf(s.kind).use
        VStack(alignment: .leading, spacing: Theme.sp3) {
            WalletList(title: "这张卡", rows: [
                WRow(id: "who", title: mine ? "\(who)给你的" : "给\(who)的", sub: "\(WalletText.day(s.givenAt))给出"),
                WRow(id: "place", title: "地点", value: s.place),
                WRow(id: "note", title: "说明", sub: s.note),
                WRow(id: "state", title: "状态", value: s.revoked ? "权限已于\(WalletText.day(s.revokedAt))收回" : s.checkedOut ? "已退房" : "有效"),
            ].filter { $0.id != "place" || !s.place.isEmpty }.filter { $0.id != "note" || !s.note.isEmpty }, counted: false)
            if mine {
                Button(s.revoked ? "权限已被收回" : use) { run { try WalletCards.Pass.use(s.id, role: .user) } }
                    .buttonStyle(.bordered).disabled(s.revoked || s.checkedOut)
            } else if s.revoked {
                Button("恢复权限") { asking = "grant" }.buttonStyle(.bordered)
            } else {
                Button("收回权限", role: .destructive) { asking = "revoke" }.buttonStyle(.bordered)
            }
            WalletList(title: "记录", rows: s.history.reversed().map { h in
                let act = h.row.string("act")
                return WRow(id: h.id, title: act == "use" ? "\(h.role == .user ? "你" : who)\(use)" : act == "revoke" ? "收回权限" : "恢复权限", sub: WalletText.time(h.createdAt))
            }, empty: "还没有用过")
            Button("在对话中查看") { Notifier.shared.openChat = s.chatId }.buttonStyle(.bordered)
        }
        .confirmationDialog(asking == "revoke" ? "收回权限" : "恢复权限", isPresented: Binding(get: { !asking.isEmpty }, set: { if !$0 { asking = "" } }), titleVisibility: .visible) {
            if asking == "revoke" {
                Button("收回", role: .destructive) { run { try WalletCards.Pass.revoke(s.id, role: .user) } }
            } else {
                Button("恢复") { run { try WalletCards.Pass.grant(s.id, role: .user) } }
            }
        } message: {
            Text(asking == "revoke" ? "收回后\(who)不能再用这张\(s.kindLabel)，可以随时恢复。对话中会留下一条，\(who)可以看到。" : "\(who)可以再用这张\(s.kindLabel)。对话中会留下一条。")
        }
    }

    private func run(_ make: () throws -> Message) {
        do { try WalletCards.post(make()); changed() } catch { failed(error) }
        asking = ""
    }
}

private struct FunDetail: View {
    let s: WalletCards.Fun.State
    var changed: () -> Void
    var failed: (Error) -> Void
    @State private var asking = false

    var body: some View {
        let mine = s.holder == "user"
        let who = s.charName.isEmpty ? "角色" : s.charName
        VStack(alignment: .leading, spacing: Theme.sp3) {
            WalletList(title: "这张卡", rows: [
                WRow(id: "who", title: mine ? "\(who)送你的" : "送给\(who)的", sub: "\(WalletText.day(s.givenAt))送出"),
                WRow(id: "desc", title: "说明", sub: s.desc),
                WRow(id: "left", title: "剩余次数", value: s.uses > 0 ? "\(s.left ?? 0) / \(s.uses) 次" : "不限次数"),
                WRow(id: "exp", title: "有效期", value: s.expiresAt > 0 ? "\(WalletText.day(s.expiresAt))前" : "长期"),
                WRow(id: "confirm", title: "使用时", value: s.confirm ? "需对方同意" : "当即生效"),
            ].filter { $0.id != "desc" || !s.desc.isEmpty }, counted: false)
            if mine {
                Button(s.expired ? "已过期" : (s.left ?? 1) <= 0 ? "次数已用完" : s.pending != nil ? "上一次使用待同意" : "使用这张卡") { asking = true }
                    .buttonStyle(.bordered).disabled(!s.usable)
            }
            WalletList(title: "使用记录", rows: s.history.reversed().map { h in
                let st = h.row.string("useState")
                return WRow(id: h.id, title: h.role == .user ? "你使用了一次" : "\(who)使用了一次", sub: WalletText.time(h.createdAt),
                            value: st == WalletCards.Fun.pending ? "待同意" : st == WalletCards.Fun.declined ? "未同意" : "已使用")
            }, empty: "还没有用过")
            Button("在对话中查看") { Notifier.shared.openChat = s.chatId }.buttonStyle(.bordered)
        }
        .confirmationDialog("使用\(s.name)", isPresented: $asking, titleVisibility: .visible) {
            Button("使用") {
                do { try WalletCards.post(WalletCards.Fun.use(s.id, role: .user)); changed() } catch { failed(error) }
            }
        } message: {
            Text(s.confirm ? "将在与\(who)的对话中发出使用申请，\(who)同意后才算用掉一次。" : "将在与\(who)的对话中发出，当即用掉一次。")
        }
    }
}

private struct TicketDetail: View {
    let s: WalletCards.Ticket.State
    var changed: () -> Void
    var failed: (Error) -> Void
    @State private var asking = false

    var body: some View {
        let mine = s.holder == "user"
        let who = s.charName.isEmpty ? "角色" : s.charName
        VStack(alignment: .leading, spacing: Theme.sp3) {
            WalletList(title: "这张票", rows: [
                WRow(id: "who", title: mine ? "\(who)送你的" : "送给\(who)的", sub: "\(WalletText.day(s.givenAt))送出"),
                WRow(id: "at", title: "开场", value: WalletCards.Ticket.whenText(s.at)),
                WRow(id: "venue", title: "地点", value: s.venue),
                WRow(id: "seat", title: "座位", value: s.seat),
                WRow(id: "state", title: "状态", value: s.checked ? "已于\(WalletText.time(s.checkedAt))检票" : s.expired ? "已过期" : "未检票"),
            ].filter { ["who", "state"].contains($0.id) || !$0.value.isEmpty }, counted: false)
            if mine && s.status == "active" { Button("检票") { asking = true }.buttonStyle(.bordered) }
            Button("在对话中查看") { Notifier.shared.openChat = s.chatId }.buttonStyle(.bordered)
        }
        .confirmationDialog("检票：\(s.title)", isPresented: $asking, titleVisibility: .visible) {
            Button("检票") {
                do { try WalletCards.post(WalletCards.Ticket.check(s.id, role: .user)); changed() } catch { failed(error) }
            }
        } message: { Text("检票后这张票算用过了，对话中会留下一条，\(who)可以看到。") }
    }
}

private struct MemberDetail: View {
    let s: WalletCards.Member.State
    var changed: () -> Void
    var failed: (Error) -> Void
    @State private var asking = false
    @State private var points = "1"
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sp3) {
            Button("记一次消费") { points = "1"; note = ""; asking = true }.buttonStyle(.bordered)
            WalletList(title: "消费记录", rows: s.history.reversed().map { h in
                let n = Int(Ledger.num(h.row["points"]))
                return WRow(id: h.id, title: h.row.string("note").isEmpty ? (h.role == .user ? "你去了一次" : "\(s.charName)去了一次") : h.row.string("note"),
                            sub: WalletText.time(h.createdAt), value: n > 0 ? "+\(n) 分" : "")
            }, empty: "还没有去过")
            Button("在对话中查看") { Notifier.shared.openChat = s.chatId }.buttonStyle(.bordered)
        }
        .alert("在「\(s.shop)」消费一次", isPresented: $asking) {
            TextField("这一次攒几分，不攒填 0", text: $points).keyboardType(.numberPad)
            TextField("买了什么，可以不填", text: $note)
            Button("记下") {
                do { try WalletCards.post(WalletCards.Member.visit(s.id, role: .user, points: Ledger.parse(points), note: note)); changed() } catch { failed(error) }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

// MARK: - 新建

/// 送给谁：单聊里看得见的角色（好友列表的隔离，4.961），最近聊过的在前。一行横滑
private struct ChatPicker: View {
    @Binding var chatId: String

    static func list() -> [(chat: Chat, char: Character)] {
        WalletCards.singleChats().filter { Isolate.seesChar($0.char) }.sorted { $0.chat.lastMessageAt > $1.chat.lastMessageAt }
    }

    var body: some View {
        let list = Self.list()
        ChipStrip(items: list.map { ($0.chat.id, $0.char.displayName) }, selected: chatId) { id in if let id { chatId = id } }
            .onAppear { if chatId.isEmpty { chatId = list.first?.chat.id ?? "" } }
    }
}

private func who(_ chatId: String) -> String {
    WalletCards.singleChats().first { $0.chat.id == chatId }?.char.displayName ?? "角色"
}

private func userBase(_ chatId: String) -> Message { Message.new(chatId: chatId, role: .user, authorId: "me", content: "") }

struct NewFunCardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var to: String

    /// chatId：从会话的加号面板进来时送给的就是这段对话
    init(chatId: String = "") { _to = State(initialValue: chatId) }
    @State private var name = ""
    @State private var desc = ""
    @State private var uses = 1
    @State private var days = 30
    @State private var color = "rose"
    @State private var confirm = false
    @State private var problem: String?

    var body: some View {
        Form {
            if ChatPicker.list().isEmpty {
                EmptyState(title: "还没有可以送的对象", desc: "娱乐卡送进与某个角色的单聊里。先在「聊天」中和一个角色开始对话。")
            } else {
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
                Section {
                    WalletFace(eyebrow: "FUN CARD", title: name.isEmpty ? "卡的名字" : name, big: uses > 0 ? "\(uses) / \(uses) 次" : "不限次数",
                               left: "送给\(who(to))", right: days > 0 ? "\(days) 天内有效" : "长期有效", tone: color)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    ChipStrip(items: WalletCards.Fun.templates.map { ($0.name, $0.name) }, selected: name) { n in
                        guard let t = WalletCards.Fun.templates.first(where: { $0.name == n }) else { return }
                        name = t.name; desc = t.desc; color = t.color; uses = t.uses
                    }
                } header: { Text("从模板开始") }
                Section {
                    ChatPicker(chatId: $to)
                } header: { Text("送给") }
                Section {
                    TextField("例如：和好卡", text: $name)
                    TextField("持有这张卡的一方可以凭它要求什么", text: $desc, axis: .vertical)
                    Stepper(uses > 0 ? "可用 \(uses) 次" : "不限次数", value: $uses, in: 0...999)
                    Stepper(days > 0 ? "\(days) 天内有效" : "长期有效", value: $days, in: 0...3650)
                    ChipStrip(items: WalletCards.Fun.colors.map { ($0.id, $0.label) }, selected: color) { c in if let c { color = c } }
                    Toggle("使用时需要对方同意", isOn: $confirm)
                } footer: {
                    HelpNote("次数为 0 表示不限次数；有效期从送出那天算起，为 0 表示长期有效。开启「使用时需要对方同意」后，角色每次使用这张卡都要你同意才算用掉一次；关闭时一用即生效。", title: "娱乐卡")
                }
                Section {
                    Button("送给\(who(to))", action: send).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: { Text("送出后，这张卡出现在与\(who(to))的对话中，由\(who(to))持有。不调用接口。") }
            }
        }
        .navigationTitle("新建娱乐卡")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() {
        do {
            try WalletCards.post(WalletCards.Fun.give(userBase(to), name: name, desc: desc, uses: Double(uses), days: Double(days), color: color, confirm: confirm))
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

struct NewPassView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var kind = "door"
    @State private var name = ""
    @State private var place = ""
    @State private var note = ""
    @State private var problem: String?

    var body: some View {
        let k = WalletCards.Pass.kindOf(kind)
        Form {
            if ChatPicker.list().isEmpty {
                EmptyState(title: "还没有可以给的对象", desc: "先在「聊天」中和一个角色开始对话。")
            } else {
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
                Section {
                    WalletFace(eyebrow: k.eyebrow, title: name.isEmpty ? k.label : name, big: place.isEmpty ? k.label : place, left: "给\(who(to))", right: "有效", tone: "ink")
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    Picker("种类", selection: $kind) { ForEach(WalletCards.Pass.kinds, id: \.id) { Text($0.label).tag($0.id) } }.pickerStyle(.segmented)
                    ChatPicker(chatId: $to)
                    TextField(kind == "key" ? "例如：家里的备用钥匙" : "例如：我家楼下的门禁", text: $name)
                    TextField("地点，例如：滨江花园 3 栋", text: $place)
                    TextField("说明，例如：想来的时候直接来", text: $note, axis: .vertical)
                }
                Section {
                    Button("给\(who(to))", action: send)
                } footer: { Text("给出后出现在与\(who(to))的对话中，由\(who(to))持有。之后可以在卡包里随时收回或恢复权限，每一次都会在对话中留下一条。不调用接口。") }
            }
        }
        .navigationTitle("给一张\(k.label)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() {
        do {
            try WalletCards.post(WalletCards.Pass.give(userBase(to), kind: kind, name: name, place: place, note: note))
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

struct NewTicketView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var kind = "movie"
    @State private var title = ""
    @State private var when = ""
    @State private var venue = ""
    @State private var seat = ""
    @State private var problem: String?

    var body: some View {
        let at = WalletCards.Ticket.parseWhen(when)
        Form {
            if ChatPicker.list().isEmpty {
                EmptyState(title: "还没有可以送的对象", desc: "先在「聊天」中和一个角色开始对话。")
            } else {
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
                Section {
                    WalletFace(eyebrow: WalletCards.Ticket.kindOf(kind).eyebrow, title: title.isEmpty ? WalletCards.Ticket.kindOf(kind).label : title,
                               big: WalletCards.Ticket.whenText(at), left: [venue, seat].filter { !$0.isEmpty }.joined(separator: " · "), right: "送给\(who(to))", tone: "sand")
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    Picker("种类", selection: $kind) { ForEach(WalletCards.Ticket.kinds, id: \.id) { Text($0.label).tag($0.id) } }
                    ChatPicker(chatId: $to)
                    TextField("场次，例如：《花样年华》重映", text: $title)
                    TextField("开场时间，例如：10月20日 19:30", text: $when)
                    TextField("地点，例如：百老汇电影中心", text: $venue)
                    TextField("座位，例如：7 排 12 座", text: $seat)
                } footer: {
                    HelpNote("开场时间写成 10月20日 19:30 或 2026-10-20 19:30。过了开场那一天还没检票，这张票算过期。", title: "开场时间")
                }
                Section {
                    Button("送给\(who(to))", action: send).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: { Text("送出后出现在与\(who(to))的对话中，由\(who(to))持有，检票后算用过。不调用接口。") }
            }
        }
        .navigationTitle("送一张票")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() {
        do {
            try WalletCards.post(WalletCards.Ticket.give(userBase(to), kind: kind, title: title, at: WalletCards.Ticket.parseWhen(when), venue: venue, seat: seat))
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

struct NewMemberView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var shop = ""
    @State private var note = ""
    @State private var problem: String?

    var body: some View {
        Form {
            if ChatPicker.list().isEmpty {
                EmptyState(title: "还没有可以一起用的对象", desc: "先在「聊天」中和一个角色开始对话。")
            } else {
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
                Section {
                    WalletFace(eyebrow: "MEMBER", title: shop.isEmpty ? "店名" : shop, big: "0 分", left: "和\(who(to))共用", right: "去过 0 次", tone: "mint")
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    ChatPicker(chatId: $to)
                    TextField("店名，例如：街角那家咖啡店", text: $shop)
                    TextField("说明，例如：每次都点一样的拿铁", text: $note)
                }
                Section {
                    Button("开卡", action: send).disabled(shop.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: { Text("会员卡由你和\(who(to))共用，开卡与每一次消费都会在对话中留下一条。不调用接口。") }
            }
        }
        .navigationTitle("开一张会员卡")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() {
        do { try WalletCards.post(WalletCards.Member.open(userBase(to), shop: shop, note: note)); dismiss() } catch { problem = error.localizedDescription }
    }
}

/// 证件的主人：自己或某个角色
struct IdPickView: View {
    var body: some View {
        let ps = (try? Repo.personas()) ?? []
        let me = Isolate.current(ps, .load())
        let chars = ((try? Repo.characters()) ?? []).filter { ($0.parentId ?? "").isEmpty && !$0.isNpc && Isolate.seesChar($0) }
        List {
            if let me {
                NavigationLink("\(me.row.string("name").isEmpty ? "我" : me.row.string("name"))（自己）") { IdEditView(id: me.id, me: true) }
            }
            ForEach(chars) { c in NavigationLink(c.displayName) { IdEditView(id: c.id, me: false) } }
        }
        .navigationTitle("选择证件的主人")
    }
}

struct IdEditView: View {
    let id: String
    let me: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var card = WalletCards.IdCard.Card()
    @State private var loaded = false
    @State private var busy = false
    @State private var problem: String?
    @State private var dropping = false

    var body: some View {
        let k = WalletCards.IdCard.kindOf(card.kind)
        let name = me ? (((try? Repo.personas()) ?? []).first { $0.id == id }?.row.string("name") ?? "我")
            : ((try? Repo.character(id)) ?? nil)?.displayName ?? "角色"
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                WalletFace(eyebrow: k.eyebrow, title: name, big: card.org.isEmpty ? k.label : card.org,
                           left: [card.dept, card.title].filter { !$0.isEmpty }.joined(separator: " · "), right: card.no, tone: "debit")
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            Section {
                Picker("种类", selection: $card.kind) { ForEach(WalletCards.IdCard.kinds, id: \.id) { Text($0.label).tag($0.id) } }.pickerStyle(.segmented)
                TextField(k.orgLabel, text: $card.org)
                TextField("部门或班级", text: $card.dept)
                TextField(k.titleLabel, text: $card.title)
                TextField("编号", text: $card.no)
            }
            Section {
                if !me {
                    Button(busy ? "正在读取" : "从角色卡读取（调用一次接口）", action: read).disabled(busy)
                }
                Button("保存") {
                    do { try WalletCards.IdCard.set(id, card, me: me); dismiss() } catch { problem = "未能保存：\(error.localizedDescription)" }
                }
                if WalletCards.IdCard.of(id, me: me) != nil { Button("删除", role: .destructive) { dropping = true } }
            } footer: {
                HelpNote("「从角色卡读取」把角色卡交给模型读出单位、身份与编号，调用一次接口，读出来的先填进上面，保存后才生效。角色卡里没写的项留空。证件只保存在本设备，不进入提示词。", title: "证件")
            }
        }
        .navigationTitle("\(name)的证件")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let c = WalletCards.IdCard.of(id, me: me) { card = c }
        }
        .confirmationDialog("删除这张证件", isPresented: $dropping, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try WalletCards.IdCard.set(id, nil, me: me); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
        } message: { Text("只删除卡包里的这张证件，角色卡不受影响。") }
    }

    private func read() {
        busy = true
        Task { @MainActor in
            do { card = try await LedgerAI.readIdCard(id); problem = nil } catch { problem = "未能读取：\(error.localizedDescription)" }
            busy = false
        }
    }
}
