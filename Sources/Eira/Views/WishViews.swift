import SwiftUI

/// 心愿（网页版 apps/wish，ARCHITECTURE 4.304、4.317）。两个页签：我的、角色的。
///
/// 你的心愿：写下、改、选关联哪个角色、给不给那个角色看、手动标达成。
/// 角色的心愿：只列你看得见的（公开的，和已经达成的私下心愿）。未达成的私下心愿一个字都不出现，连条数都不显示。
/// 星空卡片（4.317）不显示常驻文字：一片小星点，已达成的心愿各点亮一颗大一些的星。原生版没有全景天球与流星。
struct WishHomeView: View {
    @State private var tab = "mine"
    @State private var hero = true
    @State private var tick = 0
    @State private var writing = false

    var body: some View {
        let _ = tick
        let all = Wish.mine()
        List {
            HeroHeader(eyebrow: "WISHES", title: "心愿", shown: $hero)
            Picker("", selection: $tab) {
                Text("我的").tag("mine")
                Text("角色的").tag("chars")
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if tab == "mine" {
                if all.isEmpty {
                    EmptyState(title: "还没有心愿", desc: "心愿是自己的愿望、目标或期待。可以选择是否给角色看；未公开的心愿同样参与达成判定。")
                        .listRowBackground(Color.clear)
                    Button("写下一个心愿") { writing = true }
                } else {
                    WishSky(lit: all.filter { $0.isDone }.count, seed: "me")
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    let open = all.filter { !$0.isDone }
                    let done = all.filter { $0.isDone }
                    if !open.isEmpty { Section { ForEach(open) { row($0) } } header: { GroupTitle("未达成") } }
                    if !done.isEmpty { Section { ForEach(done) { row($0) } } header: { GroupTitle("已达成") } }
                }
            } else {
                let chars = Wish.charsWithWishes()
                if chars.isEmpty {
                    EmptyState(title: "暂无可查看的心愿", desc: "角色公开的心愿会显示在这里。角色未公开的心愿在达成之后才显示内容与达成时间。")
                        .listRowBackground(Color.clear)
                }
                ForEach(chars) { c in
                    let seen = Wish.charsSeen(c.id)
                    let open = seen.filter { !$0.isDone }.count
                    NavigationLink { WishCharView(charId: c.id) } label: {
                        HStack(spacing: Theme.pad) {
                            Avatar(imageId: c.avatar, name: c.displayName, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.displayName)
                                Text([open > 0 ? "\(open) 条未达成" : "", seen.count - open > 0 ? "\(seen.count - open) 条已达成" : ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .heroTitle("心愿", heroShown: hero)
        .toolbar {
            if tab == "mine" {
                ToolbarItem(placement: .primaryAction) { Button { writing = true } label: { NavIcon("plus") }.accessibilityLabel("添加") }
            }
        }
        .sheet(isPresented: $writing, onDismiss: { tick += 1 }) { NavigationStack { WishEditView(id: nil) } }
        .onAppear { tick += 1 }
    }

    private func row(_ w: Wish.Item) -> some View {
        NavigationLink { WishEditView(id: w.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(w.text)
                Text(WishText.bits(w)).font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

enum WishText {
    static func day(_ ms: Double) -> String { ms > 0 ? Health.dateKey(Date(millis: ms)) : "" }
    static func done(_ w: Wish.Item) -> String { "达成于 \(day(w.doneAt)) · \(Wish.by[w.doneBy] ?? Wish.by["manual"] ?? "")" }
    static func charName(_ id: String) -> String { ((try? Repo.character(id)) ?? nil)?.displayName ?? "" }
    static func bits(_ w: Wish.Item) -> String {
        [w.charId.isEmpty ? "不关联角色" : "关联 \(charName(w.charId).isEmpty ? "已删除的角色" : charName(w.charId))",
         w.shown ? "给角色看" : "未公开", w.isDone ? done(w) : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// 星空卡片：固定的一片小星点，加上按种子撒在固定位置的几颗亮星，已达成几条亮几颗。没有任何常驻文字
struct WishSky: View {
    let lit: Int
    let seed: String

    private static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h ^= UInt64(b); h = h &* 1099511628211 }
        return h
    }

    var body: some View {
        Canvas { ctx, size in
            var g = SplitMix(state: 137)
            for _ in 0..<500 {
                let x = g.next() * size.width
                let y = g.next() * size.height
                let r = 0.3 + pow(g.next(), 3) * 1.1
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(0.15 + g.next() * 0.5)))
            }
            var s = SplitMix(state: Self.hash(seed))
            for i in 0..<max(0, lit) {
                let x = (0.1 + s.next() * 0.8) * size.width
                let y = (0.15 + s.next() * 0.7) * size.height
                let r = 2.6 + Double(i % 3) * 0.6
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.92)))
                ctx.fill(Path(ellipseIn: CGRect(x: x - r * 2.4, y: y - r * 2.4, width: r * 4.8, height: r * 4.8)), with: .color(.white.opacity(0.08)))
            }
        }
        .frame(height: 150)
        .background(Theme.curtain)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
        .padding(.horizontal, Theme.sp4)
        .accessibilityHidden(true)
    }
}

/// 固定种子的伪随机，同一个人每次落在同一处
struct SplitMix {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}

/// 写一条新的，或者改一条已有的（你的心愿）
struct WishEditView: View {
    let id: String?
    @State private var text = ""
    @State private var cond = ""
    @State private var charId = ""
    @State private var shown = false
    @State private var loaded = false
    @State private var problem: String?
    @State private var confirmDelete = false
    @State private var cur: Wish.Item?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if id != nil && cur == nil && loaded {
                EmptyState(title: "这条心愿已不存在")
            } else {
                Section {
                    TextField("例如 希望角色能记住我不吃香菜", text: $text, axis: .vertical).lineLimit(2...6)
                } header: { GroupTitle("心愿") }
                Section {
                    TextField("例如 角色主动在点菜时避开香菜", text: $cond, axis: .vertical)
                } header: { GroupTitle("达成条件") } footer: {
                    HelpNote("写明怎样算达成，判定时照此判断。留空时按心愿本身判断。", title: "达成条件")
                }
                Section {
                    Picker("关联角色", selection: $charId) {
                        Text("不关联角色").tag("")
                        ForEach(((try? Repo.characters()) ?? []).filter { ($0.parentId ?? "").isEmpty }) { Text($0.displayName).tag($0.id) }
                    }
                    Toggle("给角色看", isOn: $shown)
                } footer: {
                    Text(shown ? (charId.isEmpty ? "所有角色都能看到这条心愿。" : "关联的角色能看到这条心愿。")
                         : "角色看不到这条心愿。未公开的心愿仍参与达成判定，判定由总结模型进行，不经过角色本人。")
                }
                if let w = cur {
                    Section {
                        if w.isDone {
                            LabeledContent("已达成", value: [WishText.done(w), w.doneNote].filter { !$0.isEmpty }.joined(separator: " · "))
                            Button("撤销达成") { act { _ = try Wish.reopen(w.id) } }
                        } else {
                            Button("标记为已达成") { act { _ = try Wish.fulfil(w.id, by: "manual") } }
                        }
                        Button("删除这条心愿", role: .destructive) { confirmDelete = true }
                    }
                }
                ProblemSection(text: problem)
            }
        }
        .navigationTitle(id == nil ? "写下心愿" : "心愿")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } } }
        .onAppear(perform: load)
        .confirmationDialog("删除心愿", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { act { if let id { try Wish.remove(id) } }; dismiss() }
        } message: { Text("删除后无法恢复。") }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let id, let w = Wish.get(id), w.mine else { return }
        cur = w
        text = w.text; cond = w.cond; charId = w.charId; shown = w.shown
    }

    private func act(_ body: () throws -> Void) {
        do { try body(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        if let id { cur = Wish.get(id) }
    }

    private func save() {
        do {
            if let w = cur { try Wish.editMine(w.id, text: text, cond: cond, charId: charId, shown: shown) }
            else { try Wish.addMine(text: text, cond: cond, charId: charId, shown: shown) }
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

/// 一个角色的心愿里你看得见的那些，以及「现在判定」（调一次接口）
struct WishCharView: View {
    let charId: String
    @State private var tick = 0
    @State private var busy = false
    @State private var note: String?
    @State private var problem: String?

    var body: some View {
        let _ = tick
        let seen = Wish.charsSeen(charId)
        let chat = Diary.chatWith(charId)
        List {
            if !seen.isEmpty {
                WishSky(lit: seen.filter { $0.isDone }.count, seed: charId).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            let open = seen.filter { !$0.isDone }
            let done = seen.filter { $0.isDone }
            if !open.isEmpty {
                Section {
                    ForEach(open) { w in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.text)
                            if !w.cond.isEmpty { Text("达成条件：\(w.cond)").font(.footnote).foregroundStyle(Theme.secondaryText) }
                        }
                    }
                } header: { GroupTitle("未达成") }
            }
            if !done.isEmpty {
                Section {
                    ForEach(done) { w in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.text)
                            Text([w.shown ? "" : "未公开的心愿", WishText.done(w), w.doneNote].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                } header: { GroupTitle("已达成") }
            }
            if seen.isEmpty { EmptyState(title: "暂无可查看的心愿").listRowBackground(Color.clear) }
            if let chat {
                Section {
                    Button(busy ? "正在判定" : "现在判定") { judge(chat.id) }.disabled(busy)
                } footer: {
                    Text("每次点击调用一次接口，走副用接口。")
                    HelpNote("「现在判定」读取与该角色私聊的最近消息，判断你们双方未达成的心愿（包括未公开的）是否已经达成。", title: "现在判定")
                }
            }
            if let note { Section { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) } }
            ProblemSection(text: problem)
        }
        .navigationTitle("\(WishText.charName(charId))的心愿")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func judge(_ chatId: String) {
        busy = true
        note = nil
        Task {
            do {
                let n = try await Wish.judgeNow(chatId)
                note = n > 0 ? "\(n) 条心愿判定为达成" : "没有判定为达成的心愿"
                problem = nil
            } catch { problem = "判定失败：\(error.localizedDescription)" }
            busy = false
            tick += 1
        }
    }
}
