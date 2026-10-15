import SwiftUI

/// 一个角色的记忆（当前身份下看得到的那些）。按发生日期排，新的在前。
struct MemoryListView: View {
    let charId: String
    @State private var all: [Memory] = []
    @State private var filter = "all"
    @State private var query = ""
    @State private var editing: EditTarget?
    @State private var problem: String?

    struct EditTarget: Identifiable, Hashable { let id: String }
    struct SubPage: Identifiable, Hashable { let id: String }
    @State private var sub: SubPage?

    private static let filters: [(String, String)] = [("all", "全部"), ("event", "事件"), ("fact", "事实"), ("open", "进行中"), ("pinned", "常驻")]

    var body: some View {
        List {
            Section {
                Picker("筛选", selection: $filter) {
                    ForEach(Self.filters.indices, id: \.self) { i in Text(Self.filters[i].1).tag(Self.filters[i].0) }
                }
                .pickerStyle(.segmented)
            }
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            ForEach(shown) { m in
                Button { editing = EditTarget(id: m.id) } label: { row(m) }
                    .foregroundStyle(Theme.bubbleTheirsText)
            }
            if shown.isEmpty {
                Text(all.isEmpty ? "暂无记忆。" : "没有符合条件的记忆。").foregroundStyle(Theme.secondaryText)
            }
        }
        .searchable(text: $query, prompt: "搜索内容或关键词")
        .navigationTitle("记忆")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("现状") { sub = SubPage(id: "state") }
                    Button("历史版本") { sub = SubPage(id: "history") }
                    Button("体检") { sub = SubPage(id: "check") }
                } label: { NavIcon("more") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { editing = EditTarget(id: "") } label: { NavIcon("plus") }.accessibilityLabel("新建记忆")
            }
        }
        .navigationDestination(item: $editing) { t in
            MemoryEditView(memoryId: t.id.isEmpty ? nil : t.id, charId: charId)
        }
        .navigationDestination(item: $sub) { p in
            if p.id == "state" { MemoryStateView(charId: charId) }
            else if p.id == "check" { MemoryCheckView(charId: charId) }
            else { MemoryHistoryView(charId: charId) }
        }
        .onAppear(perform: reload)
    }

    private var shown: [Memory] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return all.filter { m in
            let kindOK: Bool
            switch filter {
            case "event": kindOK = m.kind == .event
            case "fact": kindOK = m.kind == .fact
            case "open": kindOK = m.kind == .open
            case "pinned": kindOK = m.pinned || m.taboo
            default: kindOK = true
            }
            return kindOK && (q.isEmpty || m.content.localizedCaseInsensitiveContains(q)
                              || m.keywords.contains { $0.localizedCaseInsensitiveContains(q) })
        }
    }

    private func row(_ m: Memory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.content.isEmpty ? "（空）" : m.content).lineLimit(3)
                .foregroundStyle(m.supersededBy.isEmpty ? Theme.bubbleTheirsText : Theme.tertiaryText)
            HStack(spacing: 6) {
                Text(meta(m)).font(.caption).foregroundStyle(Theme.secondaryText)
                ForEach(tags(m), id: \.self) { t in
                    Text(t).font(.caption2).foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.tertiaryText))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func meta(_ m: Memory) -> String {
        let kind = ["event": "事件", "fact": "事实", "open": "进行中"][m.kind.rawValue] ?? ""
        let day = m.at > 0 ? TimeText.day(Date(millis: m.at)) : ""
        return [kind, m.rank, day].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    private func tags(_ m: Memory) -> [String] {
        var out: [String] = []
        if m.pinned { out.append("一直记着") }
        if m.taboo { out.append("不要主动提起") }
        if !m.supersededBy.isEmpty { out.append("已被取代") }
        if m.kind == .open && m.status == "done" { out.append("已了结") }
        if m.kind == .open && m.status == "dropped" { out.append("已放弃") }
        return out
    }

    private func reload() {
        do {
            let me = try People.ensureActivePersona()
            all = try Knowledge.memories(charId: charId, personaId: me.id)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// 编辑一条记忆，或新建一条（memoryId 为空）。新建的在点「保存」之前不入库。
struct MemoryEditView: View {
    let memoryId: String?
    let charId: String

    @Environment(\.dismiss) private var dismiss
    @State private var memory: Memory?
    @State private var content = ""
    @State private var kind: Memory.Kind = .fact
    @State private var at = Date()
    @State private var status = "open"
    @State private var hasDue = false
    @State private var due = Date()
    @State private var doneAt = Date()
    @State private var result = ""
    @State private var hasValidTo = false
    @State private var validTo = Date()
    @State private var rank = "B"
    @State private var category = "fact"
    @State private var keywords = ""
    @State private var pinned = false
    @State private var taboo = false
    @State private var confirmDelete = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                TextField("内容", text: $content, axis: .vertical).lineLimit(3...12)
            } header: { Text("内容") } footer: { HelpNote("使用简洁的第三人称陈述。") }

            Section {
                Picker("种类", selection: $kind) {
                    Text("事件").tag(Memory.Kind.event)
                    Text("事实").tag(Memory.Kind.fact)
                    Text("进行中").tag(Memory.Kind.open)
                }
                .pickerStyle(.segmented)
                DatePicker(kind == .fact ? "自哪天起成立" : kind == .open ? "从哪天开始" : "发生日期", selection: $at, displayedComponents: .date)
            } footer: {
                HelpNote("事件是发生过的事；事实是现在成立的事；进行中的事有状态，了结后写明日期与结果。日期随内容一并提供给模型，用于区分先后。")
            }

            if kind == .open {
                Section("状态") {
                    Picker("状态", selection: $status) {
                        Text("进行中").tag("open")
                        Text("已了结").tag("done")
                        Text("已放弃").tag("dropped")
                    }
                    .pickerStyle(.segmented)
                    if status == "open" {
                        Toggle("设定到期日", isOn: $hasDue)
                        if hasDue { DatePicker("到期日", selection: $due, displayedComponents: .date) }
                    } else {
                        DatePicker("了结日期", selection: $doneAt, displayedComponents: .date)
                        TextField("结果（一句话）", text: $result, axis: .vertical)
                    }
                }
            }
            if kind == .fact {
                Section {
                    Toggle("已不再成立", isOn: $hasValidTo)
                    if hasValidTo { DatePicker("失效日期", selection: $validTo, displayedComponents: .date) }
                } footer: {
                    HelpNote("失效的事实不再作为一直成立的事注入，召回时写明到哪天为止。")
                }
            }

            Section {
                Picker("重要级别", selection: $rank) {
                    ForEach(["S", "A", "B", "C"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("关键词，用顿号或逗号隔开", text: $keywords)
                Picker("分类", selection: $category) {
                    ForEach(Knowledge.categories.indices, id: \.self) { i in
                        Text(Knowledge.categories[i].1).tag(Knowledge.categories[i].0)
                    }
                }
            } header: {
                Text("召回")
            } footer: {
                HelpNote("S 级压缩进关系底色常驻，不再逐条注入；A 级命中相关话题时召回；B 级须填写关键词才会被召回；C 级仅存档，不注入。")
            }

            Section {
                Toggle("一直记着", isOn: Binding(get: { pinned }, set: { pinned = $0; if $0 { taboo = false } }))
                Toggle("不要主动提起", isOn: Binding(get: { taboo }, set: { taboo = $0; if $0 { pinned = false } }))
            } footer: {
                HelpNote("两项都会让这条每轮常驻，不参与相关度挑选。「不要主动提起」另外写明角色不主动提这件事，对方先提起时可以回应。两项只能开一项。")
            }

            if memory != nil {
                Section { Button("删除这条记忆", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText) }
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle(memoryId == nil ? "新建记忆" : "编辑记忆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save).disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .confirmationDialog("删除后无法恢复。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let m = memory else { return }
                do { try Knowledge.deleteMemory(m.id); dismiss() } catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard memory == nil, problem == nil else { return }
        do {
            let m: Memory
            if let id = memoryId, let row = try Database.shared.get(Collections.memories, id: id) {
                m = Memory(row: row)
                memory = m
            } else {
                m = Knowledge.newMemory(charId: charId, personaId: try People.ensureActivePersona().id)
            }
            content = m.content; kind = m.kind; at = Date(millis: m.at > 0 ? m.at : Date().millis)
            status = m.status; rank = m.rank.isEmpty ? "B" : m.rank
            category = m.row.string("category").isEmpty ? "fact" : m.row.string("category")
            keywords = m.keywords.joined(separator: "、")
            pinned = m.pinned; taboo = m.taboo
            let dueStr = m.row.string("dueAt")
            hasDue = !dueStr.isEmpty
            if let d = Self.dayFormatter.date(from: dueStr) { due = d }
            if let d = m.row.number("doneAt") { doneAt = Date(millis: d) }
            result = m.row.string("result")
            if let v = m.row.number("validTo"), v > 0 { hasValidTo = true; validTo = Date(millis: v) }
        } catch {
            problem = error.localizedDescription
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func save() {
        do {
            let base = try memory ?? Knowledge.newMemory(charId: charId, personaId: People.ensureActivePersona().id)
            var f = Knowledge.kindPatch(base, to: kind)
            // 分类以用户选的为准；只有「待办」跟着种类走（进行中才是待办）
            if kind != .open { f["category"] = .string(category == "pending" ? (kind == .event ? "event" : "fact") : category) }
            f["content"] = .string(content.trimmingCharacters(in: .whitespacesAndNewlines))
            f["at"] = .number(at.millis)
            f["rank"] = .string(rank)
            f["keywords"] = .array(Knowledge.splitList(keywords).map { .string($0) })
            f["pinned"] = .bool(pinned)
            f["taboo"] = .bool(taboo)
            if kind == .open {
                f["status"] = .string(status)
                if status == "open" {
                    f["dueAt"] = .string(hasDue ? Self.dayFormatter.string(from: due) : "")
                } else {
                    f["doneAt"] = .number(doneAt.millis)
                    f["result"] = .string(result)
                }
            }
            if kind == .fact { f["validTo"] = .number(hasValidTo ? validTo.millis : 0) }
            memory = try Knowledge.save(base, f)
            dismiss()
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
        }
    }
}

/// 一个角色的现状（网页版 memory/App.js 的 StatePage，4.441）：四块每轮常驻，可以手写并锁住；进行中的事可以直接了结
struct MemoryStateView: View {
    let charId: String
    @State private var drafts: [String: String] = [:]
    @State private var tick = 0
    @State private var problem: String?
    @State private var settling: Memory?

    var body: some View {
        let _ = tick
        let me = (try? People.ensureActivePersona())?.id ?? ""
        let key = (try? MemorySummary.stateKey(me)) ?? "root"
        if let c = (try? Repo.character(charId)) ?? nil {
            let st = MemorySummary.stateOf(char: c, key: key)
            let now = Date()
            let open = ((try? Knowledge.memories(charId: charId, personaId: me)) ?? []).filter { ChatPrompt.isOpen($0, now: now) }
            Form {
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
                ForEach(MemorySummary.stateBlocks, id: \.id) { b in
                    Section {
                        TextField("尚未写过", text: Binding(get: { drafts[b.id] ?? st.blocks[b.id] ?? "" }, set: { drafts[b.id] = $0 }), axis: .vertical)
                            .lineLimit(3...12)
                        if drafts[b.id] != nil {
                            Button("保存") { act { try MemorySummary.setState(charId: charId, key: key, block: b.id, text: drafts[b.id] ?? "") }; drafts[b.id] = nil }
                        }
                        Toggle("锁住，不再自动改写", isOn: Binding(get: { st.locks.contains(b.id) },
                                                             set: { v in act { try MemorySummary.lockState(charId: charId, key: key, block: b.id, on: v) } }))
                    } header: { Text(MemorySummary.stateLabels[b.id] ?? b.id) }
                }
                Section {
                    if open.isEmpty { Text("暂无").foregroundStyle(Theme.secondaryText) }
                    ForEach(open) { m in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.content)
                                if m.at > 0 { Text(TimeText.day(Date(millis: m.at))).font(.caption).foregroundStyle(Theme.secondaryText) }
                            }
                            Spacer()
                            Button("了结") { settling = m }.buttonStyle(.borderless)
                        }
                    }
                } header: { Text("进行中的事 \(open.count)") } footer: {
                    HelpNote("这几块每轮常驻，总结记忆时由模型整块改写。手写之后那一块锁住，模型不再改；关掉锁，下次总结时重新改写。「你们之间」即从前的关系底色。总结记忆时还没了结的事记在「进行中的事」里，了结之后不再作为进行中的事注入。", title: "记忆：现状")
                }
            }
            .navigationTitle("\(c.displayName)的现状")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("标为已了结，从此不再作为进行中的事注入。", isPresented: Binding(get: { settling != nil }, set: { if !$0 { settling = nil } }),
                                titleVisibility: .visible, presenting: settling) { m in
                Button("了结") {
                    act {
                        var r = m.row
                        r["status"] = .string("done")
                        r["doneAt"] = .number(Date().millis)
                        r.touch()
                        try Database.shared.put(Collections.memories, r)
                    }
                }
            }
        } else {
            EmptyState(title: "该角色已不存在")
        }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }
}

/// 记忆的历史版本（网页版 HistoryPage.js，4.560）
struct MemoryHistoryView: View {
    let charId: String
    @ObservedObject private var model = SettingsModel.shared
    @State private var tick = 0

    static func when(_ ms: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"
        return f.string(from: Date(millis: ms))
    }

    var body: some View {
        let _ = tick
        let list = MemHistory.list(charId)
        List {
            Section {
                if list.isEmpty { Text("还没有历史版本。第一次自动总结记忆之前会存下第一份。").foregroundStyle(Theme.secondaryText) }
                ForEach(list, id: \.id) { x in
                    NavigationLink { MemorySnapView(snapId: x.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Self.when(x.number("at") ?? 0)) · \(x.string("why").isEmpty ? "自动" : x.string("why"))之前")
                            Text("\(x["memories"]?.array?.count ?? 0) 条记忆").font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            } footer: {
                HelpNote("每次自动总结记忆、重新压缩关系底色之前，存一份当时的全部记忆、现状与关系底色。可以查看与现在的差别，并整份恢复。", title: "记忆：历史版本")
            }
            Section {
                NumberRow(title: "每个角色保留的份数", value: model.number("memSnapKeep", Double(MemHistory.defaultKeep)), unit: "份", placeholder: "不限")
            } footer: {
                HelpNote("填 0 不限。超出的更早的几份自动删除。只占本机存储，不调用接口。")
            }
        }
        .navigationTitle("历史版本")
        .onAppear { model.reload(); tick += 1 }
    }
}

struct MemorySnapView: View {
    let snapId: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    @State private var problem: String?

    private static func clip(_ s: String, _ n: Int = 60) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    var body: some View {
        if let d = MemHistory.diff(snapId) {
            let labels = MemorySummary.stateLabels
            List {
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
                if d.same { Text("与现在相同。").foregroundStyle(Theme.secondaryText) }
                if !d.removed.isEmpty {
                    Section("恢复后放回（\(d.removed.count)）") { ForEach(d.removed.indices, id: \.self) { i in Text(Self.clip(d.removed[i]["content"]?.string ?? "")) } }
                }
                if !d.added.isEmpty {
                    Section("恢复后去掉（\(d.added.count)）") { ForEach(d.added.indices, id: \.self) { i in Text(Self.clip(d.added[i]["content"]?.string ?? "")) } }
                }
                if !d.changed.isEmpty {
                    Section("恢复后改回（\(d.changed.count)）") {
                        ForEach(d.changed.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.clip(d.changed[i].then["content"]?.string ?? ""))
                                Text("现在：\(Self.clip(d.changed[i].now["content"]?.string ?? ""))").font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
                if !d.blocks.isEmpty {
                    Section("现状") {
                        ForEach(d.blocks.indices, id: \.self) { i in
                            let b = d.blocks[i]
                            VStack(alignment: .leading, spacing: 2) {
                                Text(labels[b.id] ?? b.id)
                                Text("那时：\(Self.clip(b.then, 120).isEmpty ? "空" : Self.clip(b.then, 120))\n现在：\(Self.clip(b.now, 120).isEmpty ? "空" : Self.clip(b.now, 120))")
                                    .font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
                if d.bond { Text("关系底色与现在不同，恢复时一并换回。").font(.footnote).foregroundStyle(Theme.secondaryText) }
                Section {
                    Button("恢复到这一份", role: .destructive) { confirm = true }.disabled(d.same).foregroundStyle(Theme.dangerText)
                }
            }
            .navigationTitle(MemoryHistoryView.when(d.snap.number("at") ?? 0))
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("这个角色现在的全部记忆、现状与关系底色将换成这一份。恢复之前会先存一份现在的，可以再恢复回来。",
                                isPresented: $confirm, titleVisibility: .visible) {
                Button("恢复", role: .destructive) {
                    do { try MemHistory.restore(snapId); dismiss() } catch { problem = "未能恢复：\(error.localizedDescription)" }
                }
            }
        } else {
            EmptyState(title: "这一份已不存在")
        }
    }
}

/// 记忆体检（网页版 CheckPage.js）：疑似同一件事的成对条目，点一条保留它，另一条让位；已让位的可以撤回
struct MemoryCheckView: View {
    let charId: String
    @State private var tick = 0
    @State private var problem: String?
    @State private var choice: (keep: Memory, drop: Memory)?

    var body: some View {
        let _ = tick
        let me = (try? People.ensureActivePersona())?.id ?? ""
        let pairs = MemCheck.pairs(charId: charId, personaId: me)
        let gone = MemCheck.superseded(charId: charId, personaId: me)
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if pairs.isEmpty {
                Section { Text("没有发现重复。").foregroundStyle(Theme.secondaryText) } footer: {
                    HelpNote("列出内容高度重合、可能在说同一件事的条目。同一件事留两条时，召回可能把两个版本一起送进去，角色无从判断以哪一条为准。保留其一之后，另一条不再参与召回，但仍保存在库中，可以撤回。", title: "记忆：体检")
                }
            }
            ForEach(pairs) { p in
                Section("相似度 \(Int((p.score * 100).rounded()))%") {
                    ForEach(0..<2, id: \.self) { k in
                        let keep = k == 0 ? p.a : p.b, drop = k == 0 ? p.b : p.a
                        Button { choice = (keep, drop) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(keep.content).foregroundStyle(Theme.text)
                                Text([keep.at > 0 ? TimeText.day(Date(millis: keep.at)) : "", "点击保留这一条"].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
            }
            if !gone.isEmpty {
                Section("已让位 \(gone.count) 条") {
                    ForEach(gone) { m in
                        HStack {
                            Text(m.content).foregroundStyle(Theme.secondaryText)
                            Spacer()
                            Button("撤回") { act { try MemCheck.restore(m.id) } }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("记忆体检")
        .confirmationDialog(choice.map { "保留「\(String($0.keep.content.prefix(60)))」；另一条让位，不再参与召回，仍可撤回。" } ?? "",
                            isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }), titleVisibility: .visible) {
            Button("保留") { if let c = choice { act { try MemCheck.supersede(c.drop.id, by: c.keep.id) } } }
        }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }
}
