import SwiftUI

// 角色眼中的你（网页版 apps/contact/ImpressPage.js 与 SelfPages.js 的 OthersPage、MergeSheet，ARCHITECTURE 4.346、4.347）。
// 入口在角色资料页；印象跟着账号走：切换账号后看到的是对那个账号的。

private func dayText(_ day: String) -> String {
    let p = day.split(separator: "-").compactMap { Int($0) }
    return p.count == 3 ? "\(p[1]) 月 \(p[2]) 日" : ""
}

private func stampText(_ at: Double) -> String {
    let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: Date(millis: at))
    return "\(c.month ?? 0) 月 \(c.day ?? 0) 日 " + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

private func nameOf(_ id: String) -> String {
    let n = (try? Repo.character(id))?.row.string("name") ?? ""
    return n.isEmpty ? "已删除的角色" : n
}

private struct Pill: View {
    let text: String
    var strong = false
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(strong ? Theme.surface3 : Theme.surface2, in: Capsule())
            .foregroundStyle(Theme.text2)
    }
}

/// 一个角色眼中的你
struct ImpressPageView: View {
    let charId: String
    @State private var list: [Row] = []
    @State private var notes = 0
    @State private var since = 0
    @State private var mark: Row?
    @State private var draft: Row?
    @State private var busy = false
    @State private var problem: String?
    @State private var pid = ""
    @State private var meName = ""
    @State private var charName = ""
    @State private var showDraft = false

    var body: some View {
        List {
            Section {
                Text("以账号「\(meName)」相处期间形成的印象。依据仅取自你本人的发言。")
                Text("\(mark.flatMap { $0.number("at") }.map { "上次整理：\(stampText($0))。" } ?? "尚未整理。")此后新增 \(since) 条消息\(notes > 0 ? "，已积累 \(notes) 条依据" : "")。")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if draft != nil {
                    Button("查看待确认的整理结果") { showDraft = true }.buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                    Text("上次的整理结果尚未确认。确认或全部舍弃后，方可再次整理。").font(.footnote).foregroundStyle(Theme.text2)
                } else {
                    Button(busy ? "正在整理" : "整理对我的印象 · 调用 1 次", action: run)
                        .buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                        .disabled(busy || (since == 0 && notes == 0))
                    Text("读取上次整理之后的对话与已积累的依据，调用一次接口（副用）。结果先供确认，勾选的内容方才保存。").font(.footnote).foregroundStyle(Theme.text2)
                }
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
            }
            let groups = Impress.levels.map { l in (l, list.filter { Impress.level($0).id == l.id }) }.filter { !$0.1.isEmpty }
            if groups.isEmpty {
                EmptyState(title: "暂无印象", desc: "印象于整理时形成。开启记忆总结后，日常对话将同时积累依据。").listRowBackground(Color.clear)
            }
            ForEach(groups.indices, id: \.self) { i in
                Section {
                    ForEach(groups[i].1, id: \.id) { r in
                        NavigationLink { ImpDetailView(id: r.id) } label: { ImpCard(row: r, charName: charName) }
                    }
                } header: { GroupTitle("\(groups[i].0.label) · \(groups[i].1.count)") }
            }
        }
        .navigationTitle("\(charName)眼中的你")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showDraft) { ImpDraftView(charId: charId) }
        .onAppear(perform: reload)
        // 离开这一页时，这次看到的新印象算看过了（看的时候仍然标着「新」）
        .onDisappear { try? Impress.markSeen(charId, pid) }
    }

    private func reload() {
        let me = try? Repo.activePersona()
        pid = me?.id ?? ""
        meName = me?.name ?? "我"
        charName = (try? Repo.character(charId))?.row.string("name") ?? ""
        list = Impress.list(charId, pid)
        notes = Impress.notes(charId, pid).count
        since = Impress.sinceCount(charId, pid)
        mark = Impress.mark(charId, pid)
        draft = Impress.draft(charId, pid)
    }

    private func run() {
        busy = true; problem = nil
        let (c, p) = (charId, pid)
        Task {
            do {
                try await ImpressTask.organize(charId: c, personaId: p)
                reload()
                showDraft = true
            } catch { problem = error.localizedDescription }
            busy = false
        }
    }
}

private struct ImpCard: View {
    let row: Row
    let charName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.string("text")).font(.system(size: 15))
                if (row.number("seenAt") ?? 0) == 0 { Pill(text: "新", strong: true) }
            }
            if !row.string("voice").isEmpty {
                Text("\(charName)：「\(row.string("voice"))」").font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            let lv = Impress.level(row)
            let last = Impress.days(row).last ?? ""
            let against = Impress.evidence(row["against"]).count
            HStack(spacing: 6) {
                Pill(text: lv.short, strong: lv.id == "sure")
                Text("依据 \(lv.days) 天\(last.isEmpty ? "" : " · 最近 \(dayText(last))")").font(.system(size: 11)).foregroundStyle(Theme.text3)
                if against > 0 { Pill(text: "相反表现 \(against) 次") }
                if (row.number("mergedAt") ?? 0) > 0 { Pill(text: "已合并到人设") }
            }
        }
        .padding(.vertical, 4)
    }
}

/// 一条印象：依据与相反表现
struct ImpDetailView: View {
    let id: String
    @State private var imp: Row?
    @State private var askDrop = false
    @State private var merging = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let imp, imp.string("kind") == "imp", imp.string("state") != "dropped" {
                let cname = nameOf(imp.string("charId"))
                let days = Impress.days(imp)
                let lv = Impress.level(imp)
                Section {
                    Text(imp.string("text")).font(Theme.serif(19))
                    if !imp.string("voice").isEmpty { Text("\(cname)：「\(imp.string("voice"))」").font(.system(size: 14)).foregroundStyle(Theme.text2) }
                    HStack(spacing: 6) {
                        Pill(text: lv.label, strong: lv.id == "sure")
                        Text("依据分布于 \(days.count) 天\(days.first.map { " · 首次 \(dayText($0))" } ?? "")").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }
                }
                Section { evList(Impress.evidence(imp["evidence"])) } header: { GroupTitle("依据") }
                let against = Impress.evidence(imp["against"])
                if !against.isEmpty { Section { evList(against) } header: { GroupTitle("相反表现") } }
                Section {
                    if (imp.number("mergedAt") ?? 0) > 0 {
                        let to = imp["mergedTo"]?["personaId"]?.string ?? ""
                        Text("已合并到人设（\(((try? Repo.personas()) ?? []).first { $0.id == to }?.name ?? "已删除的账号")）").foregroundStyle(Theme.text2)
                    } else {
                        Button("合并到我的人设") { merging = true }.buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                    }
                    Button("内容不准确，删除") { askDrop = true }.buttonStyle(EiraButtonStyle(kind: .danger, full: true))
                } footer: {
                    let t = Impress.thresholds()
                    Text("强度仅按依据分布的天数计算：\(t.seen) 天起为多次观察，\(t.sure) 天起为非常确定。")
                }
                .listRowBackground(Color.clear)
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
            } else {
                EmptyState(title: "该印象已不存在").listRowBackground(Color.clear)
            }
        }
        .navigationTitle("印象详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { imp = Impress.get(id) }
        .confirmationDialog("删除此印象", isPresented: $askDrop, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Impress.drop(id); dismiss() } catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        } message: { Text("\(nameOf(imp?.string("charId") ?? ""))将不再保留此印象，此后整理时亦不再提出相同内容。") }
        .sheet(isPresented: $merging, onDismiss: { imp = Impress.get(id) }) {
            NavigationStack { MergeView(ids: [id], text: imp?.string("text") ?? "") { merging = false } }
        }
    }

    private func evList(_ list: [[String: JSONValue]]) -> some View {
        ForEach(Array(list.sorted { ($0["at"]?.number ?? 0) < ($1["at"]?.number ?? 0) }.enumerated()), id: \.offset) { _, e in
            VStack(alignment: .leading, spacing: 2) {
                Text(stampText(e["at"]?.number ?? 0)).font(.system(size: 11)).foregroundStyle(Theme.text3)
                Text("「\(e["quote"]?.string ?? "")」").font(.system(size: 14))
            }
        }
    }
}

/// 整理结果：勾选收下
struct ImpDraftView: View {
    let charId: String
    @State private var draft: Row?
    @State private var off = Set<String>()
    @State private var askNone = false
    @State private var problem: String?
    @State private var charName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let d = draft {
                let fresh = d["fresh"]?.array ?? []
                let support = d["support"]?.array ?? []
                let against = d["against"]?.array ?? []
                Section {} footer: { Text("勾选的内容确认后方才保存。未勾选的新印象不予保存，其依据仍将保留，可供下次整理使用。") }
                if fresh.isEmpty && support.isEmpty && against.isEmpty {
                    EmptyState(title: "本次未发现新内容", desc: "此期间的对话中未发现有依据的新内容。").listRowBackground(Color.clear)
                }
                if !fresh.isEmpty {
                    Section {
                        ForEach(fresh.indices, id: \.self) { i in
                            let ev = Impress.evidence(fresh[i]["evidence"])
                            pickRow("fresh:\(i)") {
                                Text(fresh[i]["text"]?.string ?? "")
                                if let v = fresh[i]["voice"]?.string, !v.isEmpty { Text("\(charName)：「\(v)」").font(.system(size: 13)).foregroundStyle(Theme.text2) }
                                let lv = Impress.level(days: Impress.days(ev).count)
                                HStack(spacing: 6) {
                                    Pill(text: lv.short)
                                    Text("依据 \(ev.count) 条，分布于 \(lv.days) 天").font(.system(size: 11)).foregroundStyle(Theme.text3)
                                }
                                Text(quotes(ev)).font(.system(size: 12)).foregroundStyle(Theme.text2)
                            }
                        }
                    } header: { GroupTitle("新的印象 · \(fresh.count)") }
                }
                if !support.isEmpty {
                    Section {
                        ForEach(support.indices, id: \.self) { i in
                            if let imp = Impress.get(support[i]["id"]?.string ?? "") {
                                let ev = Impress.evidence(support[i]["evidence"])
                                let before = Impress.level(imp)
                                let after = Impress.level(days: Impress.days(Impress.evidence(imp["evidence"]) + ev).count)
                                pickRow("support:\(i)") {
                                    Text(imp.string("text"))
                                    Text("新增 \(after.days - before.days) 天\(after.id != before.id ? "，\(before.short) 升为 \(after.short)" : "")").font(.system(size: 11)).foregroundStyle(Theme.text3)
                                    Text(quotes(ev)).font(.system(size: 12)).foregroundStyle(Theme.text2)
                                }
                            }
                        }
                    } header: { GroupTitle("已有印象的新依据 · \(support.count)") }
                }
                if !against.isEmpty {
                    Section {
                        ForEach(against.indices, id: \.self) { i in
                            if let imp = Impress.get(against[i]["id"]?.string ?? "") {
                                pickRow("against:\(i)") {
                                    Text(imp.string("text"))
                                    Text(quotes(Impress.evidence(against[i]["evidence"]))).font(.system(size: 12)).foregroundStyle(Theme.text2)
                                }
                            }
                        }
                    } header: { GroupTitle("相反表现 · \(against.count)") }
                }
                let empty = fresh.isEmpty && support.isEmpty && against.isEmpty
                Section {
                    Button(empty ? "完成" : "确认所选", action: take).buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                    if !empty { Button("全部舍弃") { askNone = true }.buttonStyle(EiraButtonStyle(kind: .ghost, full: true)) }
                }
                .listRowBackground(Color.clear)
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
            } else {
                EmptyState(title: "暂无待确认的整理结果").listRowBackground(Color.clear)
            }
        }
        .navigationTitle("整理结果")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if draft != nil { ToolbarItem(placement: .confirmationAction) { Button("确认", action: take) } } }
        .confirmationDialog("全部舍弃", isPresented: $askNone, titleVisibility: .visible) {
            Button("全部舍弃", role: .destructive) {
                do { if let d = draft { try Impress.discard(d.id) }; dismiss() } catch { problem = error.localizedDescription }
            }
        } message: { Text("新印象的依据仍将保留，可供下次整理使用。") }
        .onAppear {
            let pid = (try? Repo.activePersona())?.id ?? ""
            draft = Impress.draft(charId, pid)
            charName = (try? Repo.character(charId))?.row.string("name") ?? ""
        }
    }

    private func quotes(_ ev: [[String: JSONValue]]) -> String { ev.map { "「\($0["quote"]?.string ?? "")」" }.joined(separator: " ") }

    private func pickRow<C: View>(_ key: String, @ViewBuilder _ content: () -> C) -> some View {
        Button {
            if off.contains(key) { off.remove(key) } else { off.insert(key) }
        } label: {
            HStack(alignment: .top, spacing: Theme.sp3) {
                Image(systemName: off.contains(key) ? "circle" : "checkmark.circle.fill").foregroundStyle(Theme.text)
                VStack(alignment: .leading, spacing: 4) { content() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func take() {
        guard let d = draft else { return }
        func picked(_ group: String) -> Set<Int> {
            Set((d[group]?.array ?? []).indices.filter { !off.contains("\(group):\($0)") })
        }
        do {
            try Impress.accept(d.id, fresh: picked("fresh"), support: picked("support"), against: picked("against"))
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

/// 别人眼中的我：几位角色都注意到的那几组，按角色列出；对照（调一次接口）
struct OthersView: View {
    let personaId: String
    @State private var tab = "shared"
    @State private var summary: Impress.Summary?
    @State private var left = 0
    @State private var compared = false
    @State private var byChar: [String] = []
    @State private var busy = false
    @State private var problem: String?
    @State private var merging: Impress.Shared?

    var body: some View {
        List {
            Picker("", selection: $tab) {
                Text("共同印象").tag("shared")
                Text("按角色").tag("chars")
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            if let s = summary {
                if tab == "shared" {
                    ForEach(s.shared) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(g.charIds.map(nameOf).joined(separator: "、")) 均有此印象").font(.system(size: 12)).foregroundStyle(Theme.text3)
                            Text(g.text)
                            ForEach(g.items.filter { !$0.string("voice").isEmpty }, id: \.id) { r in
                                Text("\(nameOf(r.string("charId")))：「\(r.string("voice"))」").font(.system(size: 13)).foregroundStyle(Theme.text2)
                            }
                            HStack {
                                Pill(text: "\(g.charIds.count) 位 · \(g.days) 天", strong: true)
                                if g.items.allSatisfy({ ($0.number("mergedAt") ?? 0) > 0 }) { Pill(text: "已合并到人设") }
                                else { Button("合并到我的人设") { merging = g }.font(.system(size: 13)).buttonStyle(.borderless) }
                            }
                        }
                    }
                    if s.shared.isEmpty {
                        Text(compared ? "目前没有多位角色的共同印象。" : "点击下方「对照」，找出多位角色各自形成的相同印象。").font(.footnote).foregroundStyle(Theme.text2)
                    }
                    Section {
                        Button(busy ? "正在对照" : "对照各角色的印象 · 调用 1 次", action: run)
                            .buttonStyle(EiraButtonStyle(kind: s.shared.isEmpty ? .primary : .ghost, full: true))
                            .disabled(busy || s.chars < 2 || (compared && left == 0))
                    } footer: {
                        Text(s.chars < 2 ? "至少需要两位角色的印象方可对照。" : compared && left == 0 ? "上次对照之后未新增印象。"
                             : "将 \(s.total) 条印象的正文交由模型分组，找出内容相同的印象，调用一次接口（副用）。\(compared ? "上次对照之后新增 \(left) 条。" : "")分组结果仅供你查看，不提供给任何角色；各角色的印象仍独立形成，互不可见。")
                    }
                } else {
                    ForEach(byChar, id: \.self) { id in
                        NavigationLink { ImpressPageView(charId: id) } label: {
                            IconRow(title: "\(nameOf(id))眼中的你", icon: "eye", value: "\(Impress.list(id, personaId).count) 条")
                        }
                    }
                    if byChar.isEmpty { Text("暂无。在角色资料页整理该角色对你的印象。").font(.footnote).foregroundStyle(Theme.text2) }
                }
            }
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
        }
        .navigationTitle("别人眼中的我")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(item: $merging, onDismiss: reload) { g in
            NavigationStack { MergeView(ids: g.items.map(\.id), text: g.text, personaId: personaId) { merging = nil } }
        }
    }

    private func reload() {
        summary = Impress.summary(personaId)
        left = Impress.uncompared(personaId)
        compared = Impress.groupsRow(personaId) != nil
        var ids: [String] = []
        for r in Impress.allKept(personaId) {
            let c = r.string("charId")
            if !ids.contains(c), (try? Repo.character(c)) != nil { ids.append(c) }
        }
        byChar = ids
    }

    private func run() {
        busy = true; problem = nil
        let p = personaId
        Task {
            do { try await ImpressTask.compare(personaId: p) } catch { problem = error.localizedDescription }
            reload()
            busy = false
        }
    }
}

/// 合并到我的人设：改写措辞、选账号与分区。另起一行接在那一分区末尾
struct MergeView: View {
    let ids: [String]
    @State var text: String
    var personaId = ""
    var done: () -> Void
    @State private var pid = ""
    @State private var key = "personality"
    @State private var people: [Persona] = []
    @State private var problem: String?

    init(ids: [String], text: String, personaId: String = "", done: @escaping () -> Void) {
        self.ids = ids
        _text = State(initialValue: text)
        self.personaId = personaId
        self.done = done
    }

    var body: some View {
        Form {
            Section {
                TextField("内容", text: $text, axis: .vertical).lineLimit(2...8)
            } footer: { Text("可改写为自己的表述，改动不影响角色的原始表述。") }
            Section("合并至账号") {
                Picker("账号", selection: $pid) { ForEach(people) { Text($0.name).tag($0.id) } }
            }
            Section {
                Picker("分区", selection: $key) { ForEach(SelfProfile.sections) { Text($0.label).tag($0.id) } }
            } header: { Text("合并至分区") } footer: {
                Text("将另起一行追加至该分区末尾，以账号「\(people.first { $0.id == pid }?.name ?? "")」聊天时所有角色均可读到。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("合并到我的人设")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", action: done) }
            ToolbarItem(placement: .confirmationAction) {
                Button("合并") {
                    do { try Impress.merge(ids, personaId: pid, key: key, text: text); done() }
                    catch { problem = error.localizedDescription }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pid.isEmpty)
            }
        }
        .onAppear {
            let all = (try? Repo.personas()) ?? []
            var ordered: [Persona] = []
            for r in all where (r.parentId ?? "").isEmpty { ordered.append(r); ordered += all.filter { $0.parentId == r.id } }
            people = ordered
            if pid.isEmpty { pid = personaId.isEmpty ? ((try? Repo.activePersona())?.id ?? "") : personaId }
        }
    }
}
