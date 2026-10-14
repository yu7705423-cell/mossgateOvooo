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
                Button { editing = EditTarget(id: "") } label: { NavIcon("plus") }.accessibilityLabel("新建记忆")
            }
        }
        .navigationDestination(item: $editing) { t in
            MemoryEditView(memoryId: t.id.isEmpty ? nil : t.id, charId: charId)
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
            } header: { Text("内容") } footer: { Text("使用简洁的第三人称陈述。") }

            Section {
                Picker("种类", selection: $kind) {
                    Text("事件").tag(Memory.Kind.event)
                    Text("事实").tag(Memory.Kind.fact)
                    Text("进行中").tag(Memory.Kind.open)
                }
                .pickerStyle(.segmented)
                DatePicker(kind == .fact ? "自哪天起成立" : kind == .open ? "从哪天开始" : "发生日期", selection: $at, displayedComponents: .date)
            } footer: {
                Text("事件是发生过的事；事实是现在成立的事；进行中的事有状态，了结后写明日期与结果。日期随内容一并提供给模型，用于区分先后。")
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
                    Text("失效的事实不再作为一直成立的事注入，召回时写明到哪天为止。")
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
                Text("S 级压缩进关系底色常驻，不再逐条注入；A 级命中相关话题时召回；B 级须填写关键词才会被召回；C 级仅存档，不注入。")
            }

            Section {
                Toggle("一直记着", isOn: Binding(get: { pinned }, set: { pinned = $0; if $0 { taboo = false } }))
                Toggle("不要主动提起", isOn: Binding(get: { taboo }, set: { taboo = $0; if $0 { pinned = false } }))
            } footer: {
                Text("两项都会让这条每轮常驻，不参与相关度挑选。「不要主动提起」另外写明角色不主动提这件事，对方先提起时可以回应。两项只能开一项。")
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
