import SwiftUI

/// 记账（网页版 apps/bill，ARCHITECTURE 4.278、4.642、4.768）。账本的切换放在首页顶上，不进设置（第 5 条）。
/// 逻辑全在 Ledger：余额、收支、构成一律由流水现算，这里只画与转交。
struct BillHomeView: View {
    @State private var tick = 0
    @State private var sheet: EntryTarget?
    @State private var problem: String?
    @State private var sumOpen = false

    var body: some View {
        let _ = tick
        let bookId = Ledger.currentId()
        Group {
            if let book = Ledger.get(bookId) {
                content(book)
            } else {
                ScrollView {
                    VStack(spacing: Theme.sp3) {
                        EmptyState(title: "还没有账本")
                        NavigationLink("新建账本") { BooksView() }.buttonStyle(.bordered)
                    }
                }
            }
        }
        .navigationTitle("记账")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("记一笔") { sheet = EntryTarget(bookId: bookId) }.disabled(bookId.isEmpty)
            }
        }
        .sheet(item: $sheet) { t in NavigationStack { EntrySheet(target: t) } }
        .onAppear(perform: boot)
        .onReceive(NotificationCenter.default.publisher(for: .eiraLedgerChanged)) { _ in tick += 1 }
    }

    /// 第一次打开时建一本（不走迁移）；顺手把到期的固定入账补上；关联了对话的账本补上角色的钱包
    private func boot() {
        do {
            if let b = try Ledger.ensure() { try Ledger.runRules(b.id) }
            for b in Ledger.all() where !b.chatId.isEmpty { try Ledger.ensureChar(b.id) }
            problem = nil
        } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }

    @ViewBuilder private func content(_ book: Ledger.Book) -> some View {
        let id = book.id
        let st = Ledger.stats(id)
        let who = Ledger.whoOf(id)
        let ready = Ledger.charReady(id)
        let joint = Ledger.defaultFor(id, Ledger.joint)
        let rows = Ledger.recent(id).filter { !$0.pending }
        let pend = Ledger.pendingOf(id)
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                NavigationLink { BooksView() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.name).foregroundStyle(Theme.text)
                        Text("\(book.isReal ? "真实账本" : "虚拟账本") · 共 \(Ledger.visible().count) 本").font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
            }
            Section {
                Button { sumOpen.toggle() } label: {
                    VStack(alignment: .leading, spacing: Theme.sp2) {
                        HStack {
                            Text("本月结余 · \(st.month)").font(.footnote).foregroundStyle(Theme.text2)
                            Spacer()
                            Image(systemName: sumOpen ? "chevron.up" : "chevron.down").font(.footnote).foregroundStyle(Theme.text3)
                        }
                        MoneyText(bookId: id, amount: st.net, big: true, plain: true)
                        if sumOpen {
                            HStack { Text("支出").foregroundStyle(Theme.text2); Spacer(); MoneyText(bookId: id, amount: -st.expense) }
                            HStack { Text("收入").foregroundStyle(Theme.text2); Spacer(); MoneyText(bookId: id, amount: st.income) }
                        }
                        Text("全部账户合计 \(Ledger.money(id, Ledger.totalOf(id)))").font(.footnote).foregroundStyle(Theme.text3)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(sumOpen ? "收起收支" : "展开收支")
            }
            Section {
                NavigationLink { PoolView(owner: Ledger.me) } label: {
                    HStack { Text("我的钱"); Spacer(); MoneyText(bookId: id, amount: Ledger.totalOf(id, Ledger.me), plain: true) }
                }
                if !who.char.isEmpty {
                    NavigationLink { PoolView(owner: Ledger.char) } label: {
                        HStack {
                            Text("\(who.char)的钱")
                            Spacer()
                            if ready { MoneyText(bookId: id, amount: Ledger.totalOf(id, Ledger.char), plain: true) } else { Text("未生成").foregroundStyle(Theme.text3) }
                        }
                    }
                    NavigationLink { PoolView(owner: Ledger.joint) } label: {
                        HStack {
                            Text("情侣账户")
                            Spacer()
                            if let joint { MoneyText(bookId: id, amount: Ledger.balanceOf(id, joint.id), plain: true) } else { Text("未开设").foregroundStyle(Theme.text3) }
                        }
                    }
                }
            } header: { Text("钱包") } footer: {
                HelpNote("角色的钱按角色卡生成后计入。情侣账户在对话中发出申请，对方通过后建立。", title: "钱包")
            }
            Section {
                NavigationLink { RulesView() } label: {
                    let rs = Ledger.rulesOf(id).filter(\.active)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("固定入账")
                        Text(rs.isEmpty ? "还没有设置。可设置每月固定的收入或支出" : rs.map { "每月 \(Int($0.day)) 日 \(Ledger.money(id, $0.amount))" }.joined(separator: "　"))
                            .font(.footnote).foregroundStyle(Theme.text2).lineLimit(2)
                    }
                }
            }
            if !pend.isEmpty {
                Section {
                    ForEach(pend) { e in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.note.isEmpty ? Ledger.labelOf(e) : e.note)
                                Text("\(Ledger.accountOf(id, e.accountId)?.name ?? "") · 来自对话").font(.footnote).foregroundStyle(Theme.text2)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                MoneyText(bookId: id, amount: e.amount)
                                HStack {
                                    Button("确认") { act { try Ledger.confirm(e.id) } }.buttonStyle(.borderless)
                                    Button("删除") { act { try Ledger.drop(e.id) } }.buttonStyle(.borderless).foregroundStyle(Theme.danger)
                                }.font(.footnote)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { sheet = EntryTarget(bookId: id, entryId: e.id) }
                    }
                } header: { Text("待确认 · \(pend.count) 笔") } footer: {
                    HelpNote("以上条目由对话总结时提取，尚未计入余额与本月收支。确认后生效，删除后不再出现。", title: "待确认")
                }
            }
            Section {
                NavigationLink { SpendView() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("支出构成")
                        if !st.byCategory.isEmpty {
                            Text("本月" + st.byCategory.prefix(3).map { "\($0.label) \(Ledger.money(id, $0.amount))" }.joined(separator: "　"))
                                .font(.footnote).foregroundStyle(Theme.text2).lineLimit(2)
                        }
                    }
                }
                NavigationLink { CatsView() } label: {
                    let n = Ledger.categories().reduce(0) { $0 + ($1.custom ? 1 : 0) + $1.subs.filter(\.custom).count }
                    HStack { Text("分类管理"); Spacer(); if n > 0 { Text("自定义 \(n) 个").foregroundStyle(Theme.text3) } }
                }
            } footer: {
                HelpNote("按分类查看每个月的支出构成、占比与笔数。分类分大类与小类；自己加的分类可以改名、删除，所有账本共用。", title: "支出构成")
            }
            if rows.isEmpty {
                Section {
                    EmptyState(title: "还没有记过账", desc: "点击右上角记下第一笔。收支会按账户累加，余额随流水变化。")
                        .listRowBackground(Color.clear)
                }
            } else {
                EntryDays(bookId: id, rows: rows) { e in if e.stored { sheet = EntryTarget(bookId: id, entryId: e.id) } }
            }
        }
    }

    private func act(_ job: () throws -> Void) {
        do { try job(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }
}

/// 打开记一笔的那一张：新建或修改；从账户旁边进来时账户与收支那一档是选好的
struct EntryTarget: Identifiable {
    let id = UUID().uuidString
    var bookId: String
    var entryId: String?
    var accountId: String?
    var income = false
    var title: String?
}

/// 金额那一行：进账出账只靠正负号区分；plain 是余额那种，正数不写加号（4.768）
struct MoneyText: View {
    let bookId: String
    let amount: Double
    var big = false
    var plain = false

    var body: some View {
        let sign = amount > 0 && !plain ? "+" : amount < 0 ? "−" : ""
        Text(sign + Ledger.money(bookId, abs(amount)))
            .font(big ? Theme.serif(28) : .system(size: 15, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(Theme.text)
    }
}

/// 流水按天分组（网页版 parts.js 的 DayHead 与 Row）
struct EntryDays: View {
    let bookId: String
    let rows: [Ledger.Entry]
    var open: (Ledger.Entry) -> Void

    var body: some View {
        let days = Self.group(rows)
        ForEach(days, id: \.day) { d in
            Section {
                ForEach(d.rows) { e in
                    EntryRow(bookId: bookId, entry: e).contentShape(Rectangle()).onTapGesture { open(e) }
                }
            } header: {
                let inSum = d.rows.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
                let outSum = d.rows.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount }
                HStack {
                    Text(d.day)
                    Spacer()
                    Text([outSum != 0 ? "支出 \(Ledger.money(bookId, outSum))" : "", inSum != 0 ? "收入 \(Ledger.money(bookId, inSum))" : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                }
            }
        }
    }

    static func group(_ rows: [Ledger.Entry]) -> [(day: String, rows: [Ledger.Entry])] {
        var out: [(day: String, rows: [Ledger.Entry])] = []
        for e in rows {
            let k = Ledger.ymd(e.at)
            if out.last?.day == k { out[out.count - 1].rows.append(e) } else { out.append((k, [e])) }
        }
        return out
    }
}

struct EntryRow: View {
    let bookId: String
    let entry: Ledger.Entry

    var body: some View {
        let acc = Ledger.accountOf(bookId, entry.accountId)
        let cat = Ledger.categoryOf(entry.category)
        let label = Ledger.labelOf(entry)
        let sub = [acc?.name ?? "", label != cat.label ? cat.label : "", entry.note].filter { !$0.isEmpty }.joined(separator: " · ")
        HStack(spacing: Theme.sp3) {
            Text(label).font(.footnote).foregroundStyle(Theme.text2).frame(width: 56, alignment: .leading).lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.note.isEmpty ? label : entry.note).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(Theme.text3).lineLimit(1) }
            }
            Spacer()
            MoneyText(bookId: bookId, amount: entry.amount)
        }
    }
}

// MARK: - 记一笔

/// 新建和修改共用这一张：两边字段完全一样，写两份迟早走岔（网页版 EntrySheet）
struct EntrySheet: View {
    let target: EntryTarget
    @Environment(\.dismiss) private var dismiss
    @State private var income = false
    @State private var amount = ""
    @State private var accountId = ""
    @State private var category = "food"
    @State private var sub = ""
    @State private var note = ""
    @State private var at = Date()
    @State private var problem: String?
    @State private var loaded = false
    @State private var adding: AddCat?
    @State private var newName = ""
    @State private var confirmDrop = false
    @State private var tick = 0

    enum AddCat: Identifiable { case top, sub; var id: Int { self == .top ? 0 : 1 } }

    private var old: Ledger.Entry? {
        target.entryId.flatMap { id in Ledger.entriesOf(target.bookId).first { $0.id == id } }
    }

    var body: some View {
        let _ = tick
        let cats = Ledger.categories()
        let top = Ledger.categoryOf(category)
        let accs = Ledger.accountsOf(target.bookId)
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Picker("收支", selection: $income) { Text("支出").tag(false); Text("收入").tag(true) }.pickerStyle(.segmented)
                TextField("金额", text: $amount).keyboardType(.decimalPad)
            }
            Section("记入账户") {
                ForEach(accs) { a in
                    Button { accountId = a.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).foregroundStyle(Theme.text)
                                Text("\(Ledger.ownerLabel(target.bookId, a.owner)) · 余额 \(Ledger.money(target.bookId, Ledger.balanceOf(target.bookId, a.id)))")
                                    .font(.footnote).foregroundStyle(Theme.text2)
                            }
                            Spacer()
                            if accountId == a.id { Image(systemName: "checkmark").foregroundStyle(Theme.text) }
                        }
                    }
                }
            }
            Section {
                ChipStrip(items: cats.map { ($0.id, $0.label) }, selected: category, add: "新分类") { id in
                    if let id { category = id; sub = "" } else { newName = ""; adding = .top }
                }
                ChipStrip(items: [("", "不细分")] + top.subs.map { ($0.id, $0.label) }, selected: sub, add: "新小类") { id in
                    if let id { sub = id } else { newName = ""; adding = .sub }
                }
            } header: { Text("分类") } footer: {
                HelpNote("当场加的分类所有账本共用，改名与删除在「分类管理」中。", title: "分类")
            }
            Section {
                TextField("这一笔是什么", text: $note, axis: .vertical)
                DatePicker("时间", selection: $at)
            }
            Section {
                Button(old == nil ? "记下" : "保存", action: save)
                if old != nil {
                    Button("删除这一笔", role: .destructive) { confirmDrop = true }
                }
            }
        }
        .navigationTitle(old != nil ? "修改这一笔" : (target.title ?? "记一笔"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onAppear(perform: load)
        .alert(adding == .top ? "新的大类" : "\(top.label)里的新小类", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
            TextField("最多 8 个字", text: $newName)
            Button("添加") { addCat(top) }
            Button("取消", role: .cancel) { adding = nil }
        }
        .confirmationDialog("删除这一笔", isPresented: $confirmDrop, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let o = old else { return }
                do { try Ledger.drop(o.id); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
        } message: { Text("删除后余额会一并减去这一笔。") }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let o = old {
            income = o.amount > 0
            amount = WalletCards.numText(abs(o.amount))
            accountId = o.accountId
            category = o.category
            sub = o.sub
            note = o.note
            at = Date(millis: o.at)
        } else {
            income = target.income
            accountId = target.accountId ?? Ledger.accountsOf(target.bookId).first?.id ?? ""
        }
    }

    private func addCat(_ top: Ledger.Cat) {
        do {
            if adding == .top { let t = try Ledger.addCategory(newName); category = t.id; sub = "" }
            else { let x = try Ledger.addSub(top.id, newName); sub = x.id }
            problem = nil
        } catch { problem = error.localizedDescription }
        adding = nil
        tick += 1
    }

    private func save() {
        let v = abs(Ledger.parse(amount))
        guard v > 0 else { problem = "请填写金额"; return }
        let signed = income ? v : -v
        do {
            if let o = old {
                try Ledger.edit(o.id, Ledger.EntryPatch(amount: signed, accountId: accountId, category: category, sub: sub, note: note, at: at.millis))
            } else {
                try Ledger.add(bookId: target.bookId, accountId: accountId, amount: signed, category: category, sub: sub, note: note, at: at.millis)
            }
            dismiss()
        } catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}

/// 一排可以横滑的选项（第 26 条：不用不限高的自动换行）。最后一格是「添加」，点了回调 nil
struct ChipStrip: View {
    let items: [(String, String)]
    let selected: String
    var add: String?
    var pick: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.sp2) {
                ForEach(items, id: \.0) { it in
                    Button(it.1) { pick(it.0) }
                        .font(.footnote)
                        .padding(.horizontal, Theme.sp3).padding(.vertical, 6)
                        .foregroundStyle(selected == it.0 ? Theme.onAccent : Theme.text)
                        .background(selected == it.0 ? Theme.accent : Theme.surface3, in: Capsule())
                        .buttonStyle(.plain)
                }
                if let add {
                    Button("+ \(add)") { pick(nil) }
                        .font(.footnote)
                        .padding(.horizontal, Theme.sp3).padding(.vertical, 6)
                        .foregroundStyle(Theme.text2)
                        .overlay(Capsule().stroke(Theme.border2))
                        .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - 账本

struct BooksView: View {
    /// 从会话里过来「建一本并关联这段对话」
    var newChatId = ""
    @State private var tick = 0
    @State private var editing: BookEdit?
    @State private var dropping: Ledger.Book?
    @State private var problem: String?

    struct BookEdit: Identifiable { let id = UUID().uuidString; var book: Ledger.Book?; var chatId = "" }

    var body: some View {
        let _ = tick
        let list = Ledger.visible()
        let cur = Ledger.currentId()
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                ForEach(list) { b in
                    Button {
                        do { try Ledger.setCurrent(b.id); problem = nil } catch { problem = "未能切换：\(error.localizedDescription)" }
                        tick += 1
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.name).foregroundStyle(Theme.text)
                                Text("\(b.isReal ? "真实" : "虚拟") · \(b.accounts.count) 个账户 · \(Ledger.entriesOf(b.id).count) 笔流水 · 合计 \(Ledger.money(b.id, Ledger.totalOf(b.id)))")
                                    .font(.footnote).foregroundStyle(Theme.text2)
                            }
                            Spacer()
                            if b.id == cur { Text("当前").foregroundStyle(Theme.text3) }
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { dropping = b }
                        Button("编辑") { editing = BookEdit(book: b) }
                    }
                }
                if list.isEmpty { Text("还没有账本").foregroundStyle(Theme.text3) }
            } footer: {
                HelpNote("两种账本的功能完全相同，均可设置我的钱、角色的钱与情侣账户。归类只影响这一本记的是否为实际收支：真实账本用于记录本人的实际生活，虚拟账本用于记录设定中的收支。左滑一本可以编辑或删除。", title: "账本")
            }
        }
        .navigationTitle("账本")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("新建") { editing = BookEdit() } } }
        .sheet(item: $editing, onDismiss: { tick += 1 }) { e in NavigationStack { BookEditor(book: e.book, chatId: e.chatId) } }
        .confirmationDialog("删除「\(dropping?.name ?? "")」", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let b = dropping else { return }
                do { try Ledger.remove(b.id); problem = nil } catch { problem = "未能删除：\(error.localizedDescription)" }
                dropping = nil
                tick += 1
            }
        } message: { Text("该账本下的 \(dropping.map { Ledger.entriesOf($0.id).count } ?? 0) 笔流水会一并删除，且无法恢复。") }
        .onAppear {
            guard !newChatId.isEmpty, editing == nil else { return }
            if let had = Ledger.bookOfChat(newChatId) { try? Ledger.setCurrent(had.id); editing = BookEdit(book: had) }
            else { editing = BookEdit(chatId: newChatId) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .eiraLedgerChanged)) { _ in tick += 1 }
    }
}

struct BookEditor: View {
    let book: Ledger.Book?
    var chatId = ""
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var real = false
    @State private var bound = ""
    @State private var start = ""
    @State private var loaded = false
    @State private var problem: String?
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let pairs = WalletCards.singleChats()
        let live = book.flatMap { Ledger.get($0.id) }
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                TextField("我的账本", text: $name)
                Picker("归类", selection: $real) { Text("真实").tag(true); Text("虚拟").tag(false) }.pickerStyle(.segmented)
                if book == nil { TextField("当前资产", text: $start).keyboardType(.decimalPad) }
            } footer: {
                HelpNote(real ? "真实账本用于记录本人的实际收支。角色的钱与情侣账户同样可用，该部分属于设定内容。" : "虚拟账本用于记录设定中的收支，不对应实际生活。", title: "归类")
                HelpNote("当前资产作为起始余额记入本人的钱包。留空则从零开始。", title: "当前资产")
            }
            Section {
                Button { bound = "" } label: { pickRow("不关联", bound.isEmpty) }
                ForEach(pairs, id: \.chat.id) { p in
                    Button { bound = p.chat.id } label: { pickRow(p.char.displayName, bound == p.chat.id) }
                }
            } header: { Text("关联的对话") } footer: {
                HelpNote("关联对话后，账本上会有三个钱包：我的钱、角色的钱、情侣账户。角色的钱由模型按角色卡生成；情侣账户在对话中开设，双方均可存入。该对话中的转账、请客、代付与存入会直接计入余额，不另存流水。不关联时仅有本人账户，不显示角色相关的内容。", title: "关联的对话")
            }
            if let live, !bound.isEmpty {
                Section {
                    Toggle(isOn: Binding(get: { live.inject }, set: { v in patch(Ledger.BookPatch(inject: v)) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("把余额告诉角色")
                            Text(live.inject ? "不额外调用接口，仅占用少量 token。" : "已关闭。").font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                    Toggle(isOn: Binding(get: { live.settle }, set: { v in patch(Ledger.BookPatch(settle: v)) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("结算角色每天的花销")
                            Text(live.settle ? "不额外调用接口，花销随日程一并生成。" : "已关闭。").font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                    Toggle(isOn: Binding(get: { live.strict }, set: { v in patch(Ledger.BookPatch(strict: v)) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("余额不足时不予支付")
                            if !live.strict { Text("已关闭。").font(.footnote).foregroundStyle(Theme.text2) }
                        }
                    }
                } header: { Text("这本账在对话里怎么起作用") } footer: {
                    HelpNote(live.inject ? "每轮在上下文中写入角色余额、对方余额、情侣账户与本月支出，并注明数值由系统计算，不得改写。角色的钱尚未生成时不写角色余额。" : "角色不知道账上有多少钱，提到金额时会自行编造。", title: "把余额告诉角色")
                    HelpNote(live.settle ? "每天为角色排新日程时，把前一天日程中各项的花销与三顿的价钱记入该角色的账户。" : "角色的日常花销不计入账目，只有对话中明确发生的转账与消费才记账。", title: "结算角色每天的花销")
                    HelpNote(live.strict ? "转账、请客的金额超过该方余额时，该笔不予记录，并在对话中留下一行说明，角色下一轮可以看到。" : "金额超过余额时照常记录，余额会变为负数。", title: "余额不足时不予支付")
                }
            }
            Section { Button("保存", action: save) }
        }
        .navigationTitle(book == nil ? "新建账本" : "账本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let b = book { name = b.name; real = b.isReal; bound = b.chatId } else {
                bound = chatId
                if let p = pairs.first(where: { $0.chat.id == chatId }) { name = "和\(p.char.displayName)一起记账" }
            }
        }
    }

    private func pickRow(_ title: String, _ on: Bool) -> some View {
        HStack { Text(title).foregroundStyle(Theme.text); Spacer(); if on { Text("已选").foregroundStyle(Theme.text3) } }
    }

    private func patch(_ p: Ledger.BookPatch) {
        guard let id = book?.id else { return }
        do { try Ledger.update(id, p); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }

    private func save() {
        do {
            if let b = book { try Ledger.update(b.id, Ledger.BookPatch(name: name, kind: real ? Ledger.real : Ledger.play, chatId: bound)) }
            else {
                let made = try Ledger.create(name: name, kind: real ? Ledger.real : Ledger.play, chatId: bound, start: Ledger.parse(start))
                try Ledger.setCurrent(made.id)
            }
            dismiss()
        } catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}

// MARK: - 钱包（我的钱、角色的钱、情侣账户，4.278）

struct PoolView: View {
    let owner: String
    @State private var tick = 0
    @State private var sheet: EntryTarget?
    @State private var depositing = false
    @State private var depositText = ""
    @State private var asking = false
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        let _ = tick
        let bookId = Ledger.currentId()
        Group {
            if let book = Ledger.get(bookId) { content(book) } else { EmptyState(title: "还没有账本") }
        }
        .navigationTitle(title(bookId))
        .sheet(item: $sheet) { t in NavigationStack { EntrySheet(target: t) } }
        .onReceive(NotificationCenter.default.publisher(for: .eiraLedgerChanged)) { _ in tick += 1 }
    }

    private func title(_ bookId: String) -> String {
        owner == Ledger.me ? "我的钱" : owner == Ledger.char ? "\(Ledger.whoOf(bookId).char.isEmpty ? "角色" : Ledger.whoOf(bookId).char)的钱" : "情侣账户"
    }

    @ViewBuilder private func content(_ book: Ledger.Book) -> some View {
        let id = book.id
        let isChar = owner == Ledger.char, isJoint = owner == Ledger.joint, isMe = owner == Ledger.me
        let acc = Ledger.defaultFor(id, owner)
        let ready = !isChar || Ledger.charReady(id)
        let joint = Ledger.hasJoint(id)
        let info = isChar ? Ledger.charMoneyOf(id) : nil
        let ids = Set(book.accounts.filter { $0.owner == owner }.map(\.id))
        let rows = Ledger.recent(id).filter { !$0.pending && ids.contains($0.accountId) }
        let rules = book.rules.filter { ids.contains($0.accountId) }
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                VStack(alignment: .leading, spacing: Theme.sp2) {
                    Text(isJoint ? "两个人共同的钱" : isChar ? "由模型按角色卡生成" : "本人的钱").font(.footnote).foregroundStyle(Theme.text2)
                    if ready && acc != nil { MoneyText(bookId: id, amount: Ledger.totalOf(id, owner), big: true, plain: true) }
                    else { Text(isChar ? "尚未生成" : "尚未开设").font(Theme.serif(22)).foregroundStyle(Theme.text3) }
                }
            } footer: {
                if isChar && !ready {
                    HelpNote("生成前视作未知：不写入角色的上下文，也不拦截该角色的支付。", title: "角色的钱")
                } else if isJoint {
                    HelpNote("双方均可存入。动用需在对话中发出申请，对方通过后从此处扣除。", title: "情侣账户")
                } else {
                    HelpNote("余额由流水累加得出，不单独存储。", title: "余额")
                }
            }
            if isChar, let summary = info?["summary"]?.string, !summary.isEmpty {
                Section("角色卡上的钱") { Text(summary) }
            }
            Section {
                if isChar {
                    Button(busy ? "生成中" : ready ? "重新生成（调用一次接口）" : "按角色卡生成（调用一次接口）") { asking = true }
                        .disabled(busy)
                }
                if (isMe || isJoint) && joint && !book.chatId.isEmpty {
                    Button(isMe ? "存入情侣账户" : "从我的钱存入") { depositText = ""; depositing = true }
                }
                if let acc, !isJoint {
                    Button("记一笔收入") { sheet = EntryTarget(bookId: id, accountId: acc.id, income: true, title: "记一笔收入") }
                    Button("记一笔支出") { sheet = EntryTarget(bookId: id, accountId: acc.id, income: false, title: "记一笔支出") }
                }
            } footer: {
                if isJoint && !joint { HelpNote("在对话中发出「开设情侣账户」的申请，对方通过后建立。", title: "情侣账户") }
            }
            if acc != nil {
                Section("固定收支") {
                    ForEach(rules) { r in
                        NavigationLink { RulesView() } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("每月 \(Int(r.day)) 日")
                                    if !r.note.isEmpty { Text(r.note).font(.footnote).foregroundStyle(Theme.text2) }
                                }
                                Spacer()
                                MoneyText(bookId: id, amount: r.amount)
                            }
                        }
                    }
                    NavigationLink(rules.isEmpty ? "还没有固定收支" : "管理固定收支") { RulesView() }
                }
            }
            Section {
                NavigationLink { AccountsView() } label: { Text("账户设置") }
            } footer: { HelpNote("多个账户、私密账户、亲属卡。", title: "账户设置") }
            if rows.isEmpty {
                Section { Text("这个钱包还没有流水。").foregroundStyle(Theme.text3) }
            } else {
                EntryDays(bookId: id, rows: rows) { e in if e.stored { sheet = EntryTarget(bookId: id, entryId: e.id) } }
            }
        }
        .confirmationDialog(ready ? "重新生成角色的钱" : "按角色卡生成角色的钱", isPresented: $asking, titleVisibility: .visible) {
            Button("生成") { generate(id) }
        } message: {
            Text("调用一次接口。模型按角色卡决定起始余额与每月固定收支。" + (ready ? "上一次生成的起始余额与固定收支会被替换，你自己记的流水不变。" : ""))
        }
        .alert("存入情侣账户", isPresented: $depositing) {
            TextField("金额", text: $depositText).keyboardType(.decimalPad)
            Button("存入") { deposit(book) }
            Button("取消", role: .cancel) {}
        } message: {
            let mine = Ledger.defaultFor(id, Ledger.me)
            Text("存入会作为一条消息出现在对话中，角色看得见，不需要对方批准。" + (mine.map { "从「\($0.name)」转入，当前余额 \(Ledger.money(id, Ledger.balanceOf(id, $0.id)))。" } ?? ""))
        }
    }

    private func deposit(_ book: Ledger.Book) {
        let v = Ledger.parse(depositText)
        guard v > 0 else { problem = "请填写金额"; return }
        do { try LedgerRequest.sendFromUser(chatId: book.chatId, kind: LedgerRequest.deposit, amount: v); problem = nil }
        catch { problem = error.localizedDescription }
        tick += 1
    }

    private func generate(_ id: String) {
        busy = true
        Task { @MainActor in
            do { try await LedgerAI.generate(id); problem = nil } catch { problem = "未能生成：\(error.localizedDescription)" }
            busy = false
            tick += 1
        }
    }
}

// MARK: - 账户设置：多个账户、私密账户、亲属卡

struct AccountsView: View {
    @State private var tick = 0
    @State private var editing: AccEdit?
    @State private var card: Ledger.Card?
    @State private var guessing: Ledger.Account?
    @State private var sheet: EntryTarget?
    @State private var problem: String?

    struct AccEdit: Identifiable { let id = UUID().uuidString; var acc: Ledger.Account? }

    var body: some View {
        let _ = tick
        let bookId = Ledger.currentId()
        let who = Ledger.whoOf(bookId)
        let list = Ledger.accountsOf(bookId)
        let groups: [(String, String)] = [(Ledger.me, who.me)] + (who.char.isEmpty ? [] : [(Ledger.char, who.char)]) + [(Ledger.joint, "情侣账户")]
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            ForEach(groups, id: \.0) { owner, label in
                Section(label) {
                    let rows = list.filter { $0.owner == owner }
                    ForEach(rows) { a in
                        Button {
                            if a.open { editing = AccEdit(acc: a) } else { guessing = a }
                        } label: {
                            HStack {
                                if a.secret { Image(systemName: "lock").foregroundStyle(Theme.text3) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name).foregroundStyle(Theme.text)
                                    if !a.open { Text("已锁定，不计入合计").font(.footnote).foregroundStyle(Theme.text2) }
                                }
                                Spacer()
                                if a.open { MoneyText(bookId: bookId, amount: Ledger.balanceOf(bookId, a.id), plain: true) } else { Text("锁着").foregroundStyle(Theme.text3) }
                            }
                        }
                        if a.open {
                            HStack {
                                Button("存入") { sheet = EntryTarget(bookId: bookId, accountId: a.id, income: true, title: "存入 \(a.name)") }
                                Button("取出") { sheet = EntryTarget(bookId: bookId, accountId: a.id, income: false, title: "取出 \(a.name)") }
                            }
                            .buttonStyle(.bordered).font(.footnote)
                        }
                    }
                    if rows.isEmpty { Text("还没有账户").foregroundStyle(Theme.text3) }
                }
            }
            Section("亲属卡") {
                ForEach(Ledger.cardsOf(bookId)) { c in
                    HStack {
                        Button { card = c } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Ledger.ownerLabel(bookId, c.from)) 发给 \(Ledger.ownerLabel(bookId, c.to))").foregroundStyle(Theme.text)
                                Text(c.active ? "额度 \(Ledger.money(bookId, c.limit)) · 已用 \(Ledger.money(bookId, Ledger.cardUsed(bookId, c.id))) · 剩余 \(Ledger.money(bookId, Ledger.cardLeft(bookId, c)))"
                                     : "已停用。持卡一方消费时从本人余额扣除").font(.footnote).foregroundStyle(Theme.text2)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { c.active }, set: { v in act { try Ledger.setCard(bookId, c.id, active: v) } })).labelsHidden()
                    }
                }
                if Ledger.cardsOf(bookId).isEmpty { Text("还没有亲属卡").foregroundStyle(Theme.text3) }
            }
            Section {
                HStack { Text("全部账户"); Spacer(); MoneyText(bookId: bookId, amount: Ledger.totalOf(bookId), plain: true) }
            } header: { Text("合计") } footer: {
                HelpNote("余额由该账户下的全部流水累加得出，不单独存储。删除某一笔流水，余额会随之变化。情侣账户与亲属卡在对话中发出申请，对方通过后生效。持卡一方消费时在额度内从发卡方余额扣除，额度不足时恢复从本人余额扣除。", title: "账户设置")
            }
        }
        .navigationTitle("账户设置")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("新建") { editing = AccEdit() } } }
        .sheet(item: $editing, onDismiss: { tick += 1 }) { e in NavigationStack { AccountEditor(bookId: bookId, acc: e.acc) } }
        .sheet(item: $card, onDismiss: { tick += 1 }) { c in NavigationStack { CardEditor(bookId: bookId, card: c) } }
        .sheet(item: $guessing, onDismiss: { tick += 1 }) { a in NavigationStack { GuessView(bookId: bookId, acc: a) } }
        .sheet(item: $sheet) { t in NavigationStack { EntrySheet(target: t) } }
        .onReceive(NotificationCenter.default.publisher(for: .eiraLedgerChanged)) { _ in tick += 1 }
    }

    private func act(_ job: () throws -> Void) {
        do { try job(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }
}

struct AccountEditor: View {
    let bookId: String
    let acc: Ledger.Account?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var owner = Ledger.me
    @State private var secret = false
    @State private var pass = ""
    @State private var hint = ""
    @State private var loaded = false
    @State private var problem: String?
    @State private var dropping = false

    var body: some View {
        let who = Ledger.whoOf(bookId)
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                TextField("现金 / 银行卡 / 零钱", text: $name)
                Picker("所属", selection: $owner) {
                    Text(who.me).tag(Ledger.me)
                    if !who.char.isEmpty { Text(who.char).tag(Ledger.char) }
                    Text("情侣账户").tag(Ledger.joint)
                }
            } footer: {
                HelpNote(owner == Ledger.joint ? "情侣账户由双方共用。" : owner == Ledger.char ? "该账户属于角色，余额同样由流水累加得出。" : "该账户属于本人。", title: "所属")
            }
            if owner == Ledger.char {
                Section {
                    Toggle("设为私密", isOn: $secret)
                    if secret {
                        TextField("密码", text: $pass)
                        TextField("线索", text: $hint)
                    }
                } header: { Text("私密账户") } footer: {
                    HelpNote(secret ? "余额不显示、不计入合计，也不写入角色的上下文。需要输入密码才能查看。" : "该账户的余额正常显示。", title: "设为私密")
                    HelpNote("密码仅保存在本设备，输入正确后永久解锁。线索在查看时显示，供推断密码；留空则不显示线索。", title: "密码与线索")
                }
            }
            if let acc {
                Section { HStack { Text("当前余额"); Spacer(); MoneyText(bookId: bookId, amount: Ledger.balanceOf(bookId, acc.id), plain: true) } }
            }
            Section {
                Button("保存", action: save)
                if acc != nil { Button("删除这个账户", role: .destructive) { dropping = true } }
            }
        }
        .navigationTitle(acc == nil ? "新建账户" : "账户")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onAppear {
            guard !loaded, let a = acc else { loaded = true; return }
            loaded = true
            name = a.name; owner = a.owner.isEmpty ? Ledger.me : a.owner; secret = a.secret; pass = a.pass; hint = a.hint
        }
        .confirmationDialog("删除「\(acc?.name ?? "")」", isPresented: $dropping, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let a = acc else { return }
                do { try Ledger.removeAccount(bookId, a.id); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
        } message: {
            Text("该账户下的 \(acc.map { a in Ledger.entriesOf(bookId).filter { $0.accountId == a.id }.count } ?? 0) 笔流水会一并删除，且无法恢复。")
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { problem = "请填写名称"; return }
        let isChar = owner == Ledger.char
        do {
            if let a = acc {
                try Ledger.updateAccount(bookId, a.id, Ledger.AccountPatch(name: name, owner: owner, secret: isChar && secret,
                                                                          pass: isChar ? pass : nil, hint: isChar ? hint : nil))
            } else {
                try Ledger.addAccount(bookId, name: name, owner: owner, secret: isChar && secret, pass: isChar ? pass : "", hint: isChar ? hint : "")
            }
            dismiss()
        } catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}

struct CardEditor: View {
    let bookId: String
    let card: Ledger.Card
    @Environment(\.dismiss) private var dismiss
    @State private var limit = ""
    @State private var problem: String?
    @State private var dropping = false

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                LabeledContent("发卡方", value: Ledger.ownerLabel(bookId, card.from))
                LabeledContent("持卡方", value: Ledger.ownerLabel(bookId, card.to))
                LabeledContent("已用", value: Ledger.money(bookId, Ledger.cardUsed(bookId, card.id)))
            }
            Section {
                TextField("额度", text: $limit).keyboardType(.decimalPad)
            } footer: {
                HelpNote("持卡一方消费时，在剩余额度内从发卡方余额扣除。额度不足时该笔恢复从本人余额扣除。已用金额由流水累加得出，不单独存储。", title: "额度")
            }
            Section {
                Button("保存") {
                    do { try Ledger.setCard(bookId, card.id, limit: Ledger.parse(limit)); dismiss() } catch { problem = "未能保存：\(error.localizedDescription)" }
                }
                Button("删除这张卡", role: .destructive) { dropping = true }
            }
        }
        .navigationTitle("亲属卡")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onAppear { if limit.isEmpty { limit = WalletCards.numText(card.limit) } }
        .confirmationDialog("删除这张亲属卡", isPresented: $dropping, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Ledger.removeCard(bookId, card.id); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
        } message: { Text("删除后，此前走这张卡的消费会改为从持卡一方的余额扣除，两边余额都会随之变化。") }
    }
}

/// 猜密码。整件事只发生在这一页里：密码与余额都不进提示词
struct GuessView: View {
    let bookId: String
    let acc: Ledger.Account
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var wrong = 0
    @State private var problem: String?

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Text("该账户已锁定。余额不显示，也不计入合计。输入正确的密码后永久解锁。").foregroundStyle(Theme.text2)
            }
            if !acc.hint.isEmpty { Section("线索") { Text(acc.hint) } }
            Section {
                TextField("密码", text: $input).keyboardType(.numberPad)
                Button("解锁") {
                    do {
                        if try Ledger.tryPass(bookId, acc.id, input) { dismiss() } else { wrong += 1; input = "" }
                    } catch { problem = "未能保存：\(error.localizedDescription)" }
                }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text(wrong > 0 ? "不正确。已尝试 \(wrong) 次，可继续尝试。" : "输入后点击解锁。")
            }
        }
        .navigationTitle(acc.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
}

// MARK: - 固定入账

struct RulesView: View {
    @State private var tick = 0
    @State private var editing: RuleEdit?
    @State private var problem: String?

    struct RuleEdit: Identifiable { let id = UUID().uuidString; var rule: Ledger.Rule? }

    var body: some View {
        let _ = tick
        let bookId = Ledger.currentId()
        let list = Ledger.rulesOf(bookId)
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                ForEach(list) { r in
                    HStack {
                        Button { editing = RuleEdit(rule: r) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("每月 \(Int(r.day)) 日　\(Ledger.money(bookId, r.amount))").foregroundStyle(Theme.text)
                                Text([Ledger.accountOf(bookId, r.accountId)?.name ?? "", r.note, Ledger.categoryOf(r.category).label].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(Theme.text2)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { r.active }, set: { v in
                            do { try Ledger.setRule(bookId, r.id, Ledger.RulePatch(active: v)); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                            tick += 1
                        })).labelsHidden()
                    }
                }
                if list.isEmpty { Text("还没有固定入账").foregroundStyle(Theme.text3) }
            } footer: {
                HelpNote("每月到日期后自动落一笔。填负数即为固定支出，例如房租。补账在打开记账时进行，不在后台运行：应用未打开的期间不会入账，再次打开时一次补齐。新建的规则从建立当天起算，不补此前的月份。", title: "固定入账")
            }
        }
        .navigationTitle("固定入账")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("新建") { editing = RuleEdit() } } }
        .sheet(item: $editing, onDismiss: { tick += 1 }) { e in NavigationStack { RuleEditor(bookId: bookId, rule: e.rule) } }
        .onReceive(NotificationCenter.default.publisher(for: .eiraLedgerChanged)) { _ in tick += 1 }
    }
}

struct RuleEditor: View {
    let bookId: String
    let rule: Ledger.Rule?
    @Environment(\.dismiss) private var dismiss
    @State private var day = 1
    @State private var amount = ""
    @State private var accountId = ""
    @State private var category = "salary"
    @State private var note = ""
    @State private var loaded = false
    @State private var problem: String?
    @State private var dropping = false

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                TextField("金额", text: $amount).keyboardType(.numbersAndPunctuation)
                Stepper("每月 \(day) 日", value: $day, in: 1...31)
            } footer: {
                HelpNote("填负数即为固定支出，例如房租。该月没有这一天时，落在当月最后一天。", title: "金额与日期")
            }
            Section("入账账户") {
                ForEach(Ledger.accountsOf(bookId)) { a in
                    Button { accountId = a.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).foregroundStyle(Theme.text)
                                Text(Ledger.ownerLabel(bookId, a.owner)).font(.footnote).foregroundStyle(Theme.text2)
                            }
                            Spacer()
                            if accountId == a.id { Image(systemName: "checkmark").foregroundStyle(Theme.text) }
                        }
                    }
                }
            }
            Section("分类") {
                ChipStrip(items: Ledger.categories().map { ($0.id, $0.label) }, selected: category) { id in if let id { category = id } }
                TextField("工资 / 房租", text: $note)
            }
            Section {
                Button("保存", action: save)
                if rule != nil { Button("删除这条规则", role: .destructive) { dropping = true } }
            }
        }
        .navigationTitle(rule == nil ? "新建固定入账" : "固定入账")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let r = rule {
                day = Int(r.day); amount = WalletCards.numText(r.amount); accountId = r.accountId; category = r.category; note = r.note
            } else { accountId = Ledger.accountsOf(bookId).first?.id ?? "" }
        }
        .confirmationDialog("删除这条规则", isPresented: $dropping, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let r = rule else { return }
                do { try Ledger.removeRule(bookId, r.id); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
        } message: { Text("已经落下的流水不会删除，只是此后不再自动入账。") }
    }

    private func save() {
        let v = Ledger.parse(amount)
        guard v != 0 else { problem = "请填写金额"; return }
        do {
            if let r = rule {
                try Ledger.setRule(bookId, r.id, Ledger.RulePatch(accountId: accountId, day: Double(day), amount: v, category: category, note: note))
            } else {
                try Ledger.addRule(bookId, accountId: accountId, day: Double(day), amount: v, category: category, note: note)
            }
            try Ledger.runRules(bookId)
            dismiss()
        } catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}

// MARK: - 支出构成

/// 钱都花在哪儿了：哪一类吃掉了多少、占几成、花了多少笔（网页版 SpendPage，4.293）。
/// 环形图不上彩色，按从大到小用同一个颜色的深浅区分，列表每一行前面一个同样深浅的圆点对上号
struct SpendView: View {
    @State private var month = ""
    @State private var hi = ""
    @State private var tick = 0

    static func shade(_ i: Int, _ n: Int) -> Double { n <= 1 ? 1 : 1 - Double(i) * min(0.4, 0.86 / Double(n - 1)) }

    static func pct(_ v: Double) -> String { String(format: v < 0.01 ? "%.1f%%" : "%.0f%%", v * 100) }

    var body: some View {
        let _ = tick
        let bookId = Ledger.currentId()
        let list = Ledger.months(bookId)
        let mo = month.isEmpty ? (list.first ?? Ledger.thisMonth()) : month
        let sp = Ledger.spending(bookId, month: mo)
        let st = Ledger.stats(bookId, month: mo)
        let cur = sp.rows.first { $0.id == hi }
        List {
            Section {
                ChipStrip(items: list.map { ($0, $0) }, selected: mo) { m in if let m { month = m; hi = "" } }
                VStack(alignment: .leading, spacing: Theme.sp2) {
                    Text("\(mo) · 支出").font(.footnote).foregroundStyle(Theme.text2)
                    MoneyText(bookId: bookId, amount: -sp.total, big: true)
                    Text("收入 \(Ledger.money(bookId, st.income))　·　结余 \(Ledger.money(bookId, st.net))　·　共 \(sp.rows.reduce(0) { $0 + $1.count }) 笔支出")
                        .font(.footnote).foregroundStyle(Theme.text3)
                }
            }
            if sp.rows.isEmpty {
                Section { EmptyState(title: "\(mo) 没有支出", desc: "这个月没有记过支出。").listRowBackground(Color.clear) }
            } else {
                Section {
                    ZStack {
                        Donut(rows: sp.rows, hi: hi) { id in hi = hi == id ? "" : id }
                            .frame(width: 200, height: 200)
                        VStack(spacing: 2) {
                            Text(cur?.label ?? "支出").font(.footnote).foregroundStyle(Theme.text2)
                            Text(Ledger.money(bookId, cur?.amount ?? sp.total)).font(.headline).monospacedDigit()
                            Text(cur.map { "占 \(Self.pct($0.share)) · \($0.count) 笔" } ?? "\(sp.rows.count) 类").font(.footnote).foregroundStyle(Theme.text2)
                        }
                        .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity)
                }
                Section("按分类") {
                    ForEach(Array(sp.rows.enumerated()), id: \.element.id) { i, r in
                        Button { hi = hi == r.id ? "" : r.id } label: {
                            HStack(spacing: Theme.sp3) {
                                Circle().fill(Theme.text.opacity(Self.shade(i, sp.rows.count))).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(r.label).fontWeight(hi == r.id ? .semibold : .regular).foregroundStyle(Theme.text)
                                    GeometryReader { g in
                                        Capsule().fill(Theme.text.opacity(Self.shade(i, sp.rows.count)))
                                            .frame(width: max(2, g.size.width * r.share), height: 4)
                                    }
                                    .frame(height: 4)
                                    Text("占 \(Self.pct(r.share)) · \(r.count) 笔").font(.footnote).foregroundStyle(Theme.text2)
                                }
                                Spacer()
                                MoneyText(bookId: bookId, amount: -r.amount)
                            }
                        }
                    }
                }
                if let cur, cur.subs.count > 1 || !(cur.subs.first?.id.isEmpty ?? true) {
                    Section("\(cur.label)的明细") {
                        ForEach(cur.subs) { x in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(x.label)
                                    Text("占这一类 \(Self.pct(x.share)) · \(x.count) 笔").font(.footnote).foregroundStyle(Theme.text2)
                                }
                                Spacer()
                                MoneyText(bookId: bookId, amount: -x.amount)
                            }
                        }
                    }
                }
                Section {} footer: { HelpNote("仅统计已计入余额的支出。待确认的条目不计入，确认后出现在此处。", title: "支出构成") }
            }
        }
        .navigationTitle("支出")
        .onReceive(NotificationCenter.default.publisher(for: .eiraLedgerChanged)) { _ in tick += 1 }
    }
}

/// 环形图：每一类一段，按从大到小同一个颜色由深到浅；点一段高亮它
struct Donut: View {
    let rows: [Ledger.SpendRow]
    let hi: String
    var pick: (String) -> Void

    var body: some View {
        let gap = rows.count > 1 ? 0.004 : 0
        ZStack {
            Circle().stroke(Theme.surface3, lineWidth: 18)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                let start = rows.prefix(i).reduce(0) { $0 + $1.share }
                Circle()
                    .trim(from: start, to: max(start, start + r.share - gap))
                    .stroke(Theme.text.opacity(hi.isEmpty || hi == r.id ? SpendView.shade(i, rows.count) : 0.12),
                            style: StrokeStyle(lineWidth: hi == r.id ? 24 : 18, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .onTapGesture { pick(r.id) }
                    .accessibilityLabel(r.label)
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(14)
    }
}

// MARK: - 分类管理（4.642）

struct CatsView: View {
    @State private var tick = 0
    @State private var problem: String?
    @State private var asking: Ask?
    @State private var text = ""
    @State private var editing: Ledger.Sub?
    @State private var dropping: Ledger.Sub?

    /// 正在填名字的那一件：新大类、某个大类里的新小类、改名
    enum Ask: Identifiable {
        case top, sub(Ledger.Cat), rename(Ledger.Sub)
        var id: String {
            switch self { case .top: return "top"; case .sub(let c): return "sub:\(c.id)"; case .rename(let x): return "re:\(x.id)" }
        }
        var title: String {
            switch self { case .top: return "新的大类"; case .sub(let c): return "\(c.label)里的新小类"; case .rename: return "改名" }
        }
    }

    var body: some View {
        let _ = tick
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            ForEach(Ledger.categories()) { c in
                Section(c.label + (c.custom ? "（自定义）" : "")) {
                    if c.custom {
                        Button("改名或删除「\(c.label)」") { editing = Ledger.Sub(id: c.id, label: c.label, custom: true) }
                    }
                    ForEach(c.subs) { x in
                        if x.custom {
                            Button(x.label) { editing = x }.foregroundStyle(Theme.text)
                        } else {
                            HStack { Text(x.label); Spacer(); Text("内置").foregroundStyle(Theme.text3) }
                        }
                    }
                    if c.id != "transfer" { Button("加一个小类") { text = ""; asking = .sub(c) } }
                }
            }
            Section {} footer: { HelpNote("内置的分类不能改名或删除。自定义的分类所有账本共用，统计时小类计入它所在的大类。", title: "分类管理") }
        }
        .navigationTitle("分类管理")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("新大类") { text = ""; asking = .top } } }
        .alert(asking?.title ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            TextField("最多 8 个字", text: $text)
            Button("确定") { submit() }
            Button("取消", role: .cancel) { asking = nil }
        }
        .confirmationDialog(editing?.label ?? "", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }), titleVisibility: .visible) {
            Button("改名") { if let x = editing { text = x.label; asking = .rename(x) } }
            Button("删除", role: .destructive) { dropping = editing }
        }
        .confirmationDialog("删除「\(dropping?.label ?? "")」", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let x = dropping { run { try Ledger.removeCategory(x.id) } }; dropping = nil }
        } message: { Text("已经记在这一类下的流水不会删除：大类删掉后显示为「其他」，小类删掉后显示为它的大类。") }
    }

    private func submit() {
        guard let a = asking else { return }
        switch a {
        case .top: run { try Ledger.addCategory(text) }
        case .sub(let c): run { try Ledger.addSub(c.id, text) }
        case .rename(let x): run { try Ledger.renameCategory(x.id, text) }
        }
        asking = nil
    }

    private func run(_ job: () throws -> Void) {
        do { try job(); problem = nil } catch { problem = error.localizedDescription }
        tick += 1
    }
}
