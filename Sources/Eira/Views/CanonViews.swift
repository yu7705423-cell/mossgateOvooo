import SwiftUI

/// 「设定集」（网页版 apps/preset，ARCHITECTURE 4.386）：角色读到什么、角色怎么写、角色能做什么。
struct CanonView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var loreCount = 0
    @State private var memoryCount = 0

    var body: some View {
        NavigationStack {
            List {
                Section("角色知道什么") {
                    NavigationLink { LorebookListView() } label: { row("世界书", "book.closed", "\(loreCount) 本") }
                    NavigationLink { MemoryCharsView() } label: { row("记忆", "brain", "\(memoryCount) 条") }
                }
                Section("角色怎么写") {
                    NavigationLink { PresetListView() } label: {
                        row("预设", "slider.horizontal.3", Presets.name(model.s, Presets.activeId(model.s)))
                    }
                    NavigationLink { BanView() } label: {
                        row("不要写这些", "nosign", Ban.list(model.s).isEmpty ? "未设置" : "\(Ban.list(model.s).count) 条")
                    }
                }
                Section("角色能做什么") {
                    NavigationLink { CapsView() } label: {
                        row("能力", "list.bullet", "开启 \(CapsView.onCount(model.s)) / \(CapsView.caps.count)")
                    }
                }
            }
            .navigationTitle("设定集")
            .onAppear {
                model.reload()
                let counts = (try? Database.shared.counts()) ?? [:]
                loreCount = counts[Collections.lorebooks] ?? 0
                memoryCount = counts[Collections.memories] ?? 0
            }
        }
    }

    private func row(_ title: String, _ icon: String, _ value: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value).foregroundStyle(Theme.secondaryText)
        }
    }
}

/// 记忆按角色分开，先选角色。
struct MemoryCharsView: View {
    @State private var chars: [Character] = []
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            ForEach(chars) { c in
                NavigationLink { MemoryListView(charId: c.id) } label: {
                    HStack(spacing: Theme.gap) {
                        Avatar(imageId: c.avatar, name: c.name)
                        Text(c.name)
                    }
                }
            }
            if chars.isEmpty && problem == nil { Text("暂无角色。").foregroundStyle(Theme.secondaryText) }
        }
        .navigationTitle("记忆")
        .onAppear {
            do { chars = try Repo.characters().filter { !$0.row.bool("isNpc") && $0.row.string("parentId").isEmpty }; problem = nil }
            catch { problem = "读取失败：\(error.localizedDescription)" }
        }
    }
}

// MARK: - 预设

struct PresetListView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var opening: Target?

    struct Target: Identifiable, Hashable { let id: String }

    var body: some View {
        List {
            Section {
                ForEach(Presets.list(model.s)) { p in
                    Button { opening = Target(id: p.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundStyle(Theme.bubbleTheirsText)
                                Text(status(p.id)).font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            if p.id == Presets.activeId(model.s) { Image(systemName: "checkmark").foregroundStyle(Theme.secondaryText) }
                        }
                    }
                }
                Button("新建预设") {
                    var made = ""
                    model.update { made = Presets.duplicate(&$0) }
                    if !made.isEmpty, model.problem == nil { opening = Target(id: made) }
                }
            } footer: {
                Text("一套预设是发给模型的条目顺序：线上聊天、线下、群聊、通话各一份，可以调整先后、开关、添加自己的条目，另有每轮条数等参数。全局使用一套；每段对话可以在会话设置中另选一套。新建时复制全局使用中的那一套。")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("预设")
        .navigationDestination(item: $opening) { t in PresetEditView(presetId: t.id) }
        .onAppear { model.reload() }
    }

    private func status(_ id: String) -> String {
        let n = Presets.chatsUsing(id).count
        let parts = [id == Presets.activeId(model.s) ? "全局使用中" : "", n > 0 ? "\(n) 段对话在用" : ""].filter { !$0.isEmpty }
        return parts.isEmpty ? "未使用" : parts.joined(separator: " · ")
    }
}

struct PresetEditView: View {
    let presetId: String

    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "chat"
    @State private var sheet: SheetKind?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var editMode: EditMode = .inactive

    enum SheetKind: Identifiable {
        case custom(String), group(String), template(String), info(String, String), legacy(String)
        var id: String {
            switch self {
            case .custom(let x): return "c:" + x
            case .group(let x): return "g:" + x
            case .template(let x): return "t:" + x
            case .info(let x, _): return "i:" + x
            case .legacy(let x): return "l:" + x
            }
        }
    }

    private var v: AppSettings { Presets.values(model.s, presetId) }
    private var isActive: Bool { Presets.activeId(model.s) == presetId }
    private var exists: Bool { Presets.list(model.s).contains { $0.id == presetId } }

    var body: some View {
        List {
            if !exists {
                Text("这套预设已删除。").foregroundStyle(Theme.secondaryText)
            } else {
                Section {
                    if !isActive {
                        Text("这一套未在全局使用。修改直接保存在这一套里，设为全局使用或在会话设置中选用后生效。")
                            .font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                    Picker("情形", selection: $mode) {
                        ForEach(Layout.modes) { m in Text(m.label).tag(m.id) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("从上到下即发给模型的顺序。点右上角「排序」后拖动调整位置；关闭的一条不发送。标为「必需」的关系到回复能否被正确拆分，不能关闭；标为「跟随开关」的由各自功能的开关决定，在这里只调整位置。原生版目前只发送线上聊天这一份，其余三份照样保存，供网页版使用。")
                }
                Section("条目") {
                    ForEach(items) { it in itemRow(it) }
                        .onMove(perform: move)
                    ForEach(Layout.fixedTail[mode] ?? [], id: \.self) { t in
                        HStack {
                            Image(systemName: "lock").foregroundStyle(Theme.tertiaryText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t)
                                Text("固定贴着最后一条消息").font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .moveDisabled(true)
                    }
                    Button("添加条目", action: addEntry)
                }
                params
                legacy
                ProblemSection(text: model.problem)
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(Presets.name(model.s, presetId))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if exists {
                ToolbarItem(placement: .primaryAction) {
                    Button(editMode.isEditing ? "完成" : "排序") { editMode = editMode.isEditing ? .inactive : .active }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu("更多") {
                        if !isActive { Button("设为全局使用") { model.update { Presets.activate(&$0, presetId) } } }
                        Button("重命名") { newName = Presets.name(model.s, presetId); renaming = true }
                        Button("复制一份") { model.update { Presets.duplicate(&$0, from: presetId) } }
                        if !isActive { Button("删除", role: .destructive) { confirmDelete = true } }
                    }
                }
            }
        }
        .alert("重命名", isPresented: $renaming) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") { model.update { Presets.rename(&$0, presetId, newName) } }
        }
        .confirmationDialog(deleteMessage, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: remove)
        }
        .sheet(item: $sheet) { s in
            NavigationStack { sheetBody(s) }
        }
    }

    // MARK: 条目

    private var items: [Layout.Item] { Layout.resolve(mode, v) }

    private struct Described {
        var title: String
        var tag: String
        var sub: String
        var follow: String
        var locked: Bool
        var tap: SheetKind?
    }

    private func describe(_ it: Layout.Item) -> Described {
        if it.id.hasPrefix("grp:") {
            let g = String(it.id.dropFirst(4))
            let ids = Layout.blocksOf(g, Layout.injectOrder(v))
            let sub = ids.count > 1 ? ids.map { Layout.blockMeta[$0]?.label ?? $0 }.joined(separator: "、")
                                    : (ids.first.flatMap { Layout.blockMeta[$0]?.desc } ?? "")
            return Described(title: Layout.groups[g]?.label ?? g, tag: "数据", sub: sub, follow: Layout.followOf(it.id),
                             locked: false, tap: .group(g))
        }
        if it.id.hasPrefix("custom:") {
            let c = Layout.customs(v).first { "custom:\($0.id)" == it.id }
            let text = (c?.text ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return Described(title: (c?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "未命名条目", tag: "自己加的",
                             sub: text.isEmpty ? "尚未填写" : String(text.prefix(40)), follow: "", locked: false,
                             tap: c.map { .custom($0.id) })
        }
        let seg = Layout.segments[it.id] ?? Layout.Segment(label: it.id, desc: "")
        let data: Set<String> = ["faceSetup", "summary", "sceneSummary", "ident", "members", "setup", "style", "core", "length"]
        let tpl = seg.edit[mode]
        let tap: SheetKind? = tpl.map { .template($0) } ?? (data.contains(it.id) ? nil : .info(seg.label, seg.desc))
        return Described(title: seg.label, tag: data.contains(it.id) ? "数据" : "系统", sub: seg.desc,
                         follow: seg.follow, locked: seg.locked, tap: tap)
    }

    @ViewBuilder
    private func itemRow(_ it: Layout.Item) -> some View {
        if it.id == Layout.history {
            VStack(alignment: .leading, spacing: 2) {
                Text("聊天记录").fontWeight(.semibold)
                Text(mode == "call" ? "通话中说过的话" : "上面的内容放在最前；下面的内容贴着最后一条消息")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            .moveDisabled(mode == "call")
        } else {
            let d = describe(it)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(d.title)
                        Text(d.tag).font(.caption2).foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.tertiaryText))
                    }
                    if !d.sub.isEmpty { Text(d.sub).font(.footnote).foregroundStyle(Theme.secondaryText) }
                    if !d.follow.isEmpty && !d.locked { Text(d.follow).font(.footnote).foregroundStyle(Theme.tertiaryText) }
                }
                .contentShape(Rectangle())
                .onTapGesture { if let t = d.tap { sheet = t } }
                Spacer()
                if d.locked {
                    Text("必需").font(.footnote).foregroundStyle(Theme.secondaryText)
                } else if !d.follow.isEmpty {
                    Text("跟随开关").font(.footnote).foregroundStyle(Theme.secondaryText)
                } else {
                    Toggle("", isOn: Binding(get: { it.on }, set: { toggle(it, $0) })).labelsHidden()
                }
            }
            .opacity(it.on || Layout.isFixed(it.id) ? 1 : 0.5)
        }
    }

    private func saveItems(_ list: [Layout.Item], extra: [String: JSONValue?] = [:]) {
        var layout = v.raw["promptLayout"]?.object ?? [:]
        layout[mode] = .array(list.map { .object(["id": .string($0.id), "on": .bool($0.on)]) })
        var patch = extra
        patch["promptLayout"] = .object(layout)
        model.update { Presets.patch(&$0, presetId, patch) }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        var list = items
        list.move(fromOffsets: from, toOffset: to)
        // 通话的聊天记录固定在最后
        if mode == "call", let h = list.firstIndex(where: { $0.id == Layout.history }) { list.append(list.remove(at: h)) }
        saveItems(list)
    }

    private func toggle(_ it: Layout.Item, _ on: Bool) {
        saveItems(items.map { $0.id == it.id ? Layout.Item(id: $0.id, on: on) : $0 })
    }

    private func addEntry() {
        let id = Ids.make("c")
        var list = items
        let h = list.firstIndex { $0.id == Layout.history } ?? list.count
        list.insert(Layout.Item(id: "custom:\(id)", on: true), at: h)
        let customs = (v.raw["promptCustom"]?.array ?? []) + [.object(["id": .string(id), "name": .string("新条目"), "text": .string("")])]
        saveItems(list, extra: ["promptCustom": .array(customs)])
        if model.problem == nil { sheet = .custom(id) }
    }

    private var deleteMessage: String {
        let n = Presets.chatsUsing(presetId).count
        return n > 0 ? "\(n) 段对话在用这一套，删除后它们改为跟随全局。" : "删除后不可恢复。"
    }

    private func remove() {
        var failure: String?
        model.update {
            do { try Presets.remove(&$0, presetId) } catch { failure = error.localizedDescription }
        }
        if let failure { model.problem = failure; return }
        guard model.problem == nil else { return }
        do { try Presets.releaseChats(presetId) }
        catch { model.problem = "预设已删除，但改回跟随全局的会话未能保存：\(error.localizedDescription)" }
        dismiss()
    }

    // MARK: 参数

    private func num(_ key: String, _ def: Double) -> Binding<Double> {
        Binding(get: { v.raw[key]?.number ?? def },
                set: { n in model.update { Presets.patch(&$0, presetId, [key: .number(n)]) } })
    }

    /// 下限改大时上限跟着改；上限不小于下限。
    private func pair(_ lo: String, _ hi: String, _ dl: Double, _ dh: Double) -> (Binding<Double>, Binding<Double>) {
        let l = Binding(get: { v.raw[lo]?.number ?? dl }, set: { n in
            let h = v.raw[hi]?.number ?? dh
            var patch: [String: JSONValue?] = [lo: .number(n)]
            if n > h { patch[hi] = .number(n) }
            model.update { Presets.patch(&$0, presetId, patch) }
        })
        let h = Binding(get: { v.raw[hi]?.number ?? dh }, set: { n in
            model.update { Presets.patch(&$0, presetId, [hi: .number(max(n, v.raw[lo]?.number ?? dl))]) }
        })
        return (l, h)
    }

    @ViewBuilder
    private var params: some View {
        let msg = pair("msgMin", "msgMax", 3, 9)
        let sms = pair("smsMin", "smsMax", 1, 3)
        let syn = pair("synopsisMin", "synopsisMax", 400, 800)
        let byTurn = v.raw["historyMode"]?.string == "turn"
        Section {
            NumberRow(title: "每轮至少", value: msg.0, unit: "条", range: 1...Double(Int32.max))
            NumberRow(title: "每轮至多", value: msg.1, unit: "条", range: 1...Double(Int32.max))
            NumberRow(title: "短信每轮至少", value: sms.0, unit: "条", range: 1...Double(Int32.max))
            NumberRow(title: "短信每轮至多", value: sms.1, unit: "条", range: 1...Double(Int32.max))
            NumberRow(title: "旁白每轮至少", value: num("narrationMin", 1), unit: "行")
            NumberRow(title: "长篇简介至少", value: syn.0, unit: "字", range: 50...Double(Int32.max))
            NumberRow(title: "长篇简介至多", value: syn.1, unit: "字", range: 50...Double(Int32.max))
            Toggle("按需注入", isOn: Binding(get: { v.raw["promptLean"]?.bool ?? true },
                                          set: { b in model.update { Presets.patch(&$0, presetId, ["promptLean": .bool(b)]) } }))
        } header: {
            Text("参数")
        } footer: {
            Text("每轮条数：线上聊天与群聊每轮回复分几条发出。旁白每轮至少：开启旁白时生效，填 0 表示不要求。按需注入：开启时平时只给能力清单，某项能力最近用到时才注入完整说明；关闭后开启的能力每轮都注入完整说明。")
        }
        Section {
            Picker("历史范围", selection: Binding(get: { byTurn ? "turn" : "count" },
                                              set: { m in model.update { Presets.patch(&$0, presetId, ["historyMode": .string(m)]) } })) {
                Text("按条数").tag("count")
                Text("按轮次").tag("turn")
            }
            .pickerStyle(.segmented)
            if byTurn {
                NumberRow(title: "携带最近", value: num("historyTurns", 10), unit: "轮", placeholder: "全部")
            } else {
                NumberRow(title: "携带最近", value: num("historyLimit", 20), unit: "条", placeholder: "全部")
            }
            NumberRow(title: "扫描窗口", value: num("scanWindow", 6), unit: "条", placeholder: "全部")
            NumberRow(title: "注入预算", value: num("contextBudget", 0), unit: "token", placeholder: "不限")
        } footer: {
            Text("历史范围：每次请求附带最近多少条消息或多少轮，填 0 表示全部。条数越多，每次请求的用量越大。扫描窗口：世界书与记忆在最近若干条消息中匹配关键词，填 0 表示整段对话。注入预算：世界书、记忆与对话历史的 token 上限，填 0 表示不截断。")
        }
    }

    // MARK: 以前改过、现在锁定的内置提示词

    private var legacyIds: [String] {
        let mine = v.raw["promptTemplates"]?.object ?? [:]
        return mine.keys.filter { id in
            guard let d = Templates.defaults[id], !Layout.editable.contains(id) else { return false }
            return mine[id]?.string != d
        }.sorted()
    }

    @ViewBuilder
    private var legacy: some View {
        if !legacyIds.isEmpty {
            Section {
                ForEach(legacyIds, id: \.self) { id in
                    Button { sheet = .legacy(id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(id).foregroundStyle(Theme.bubbleTheirsText)
                            Text("仍按修改后的版本生效").font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            } header: {
                Text("以前修改过的内置提示词")
            } footer: {
                Text("这些段落含有应用需要读取的格式，现已不开放修改。以前改过的版本继续生效；恢复默认后不能再改。")
            }
        }
    }

    // MARK: 弹出页

    @ViewBuilder
    private func sheetBody(_ s: SheetKind) -> some View {
        switch s {
        case .custom(let id):
            if let c = Layout.customs(v).first(where: { $0.id == id }) {
                CustomEntryEditor(entry: c, onSave: saveCustom, onDelete: { dropCustom(id) })
            }
        case .group(let g):
            GroupOrderView(group: g, order: Layout.injectOrder(v)) { order in
                model.update { Presets.patch(&$0, presetId, ["injectOrder": .array(order.map { .string($0) })]) }
            }
        case .template(let id):
            TemplateEditor(templateId: id, current: v.raw["promptTemplates"]?.object?[id]?.string) { text in
                var all = v.raw["promptTemplates"]?.object ?? [:]
                all[id] = text.map { .string($0) }
                model.update { Presets.patch(&$0, presetId, ["promptTemplates": .object(all)]) }
            }
        case .info(let title, let desc):
            Form {
                Section {
                    Text(desc)
                } footer: {
                    Text("这一段含有应用需要读取的格式，由应用维护，不开放修改。需要补充要求时，可添加自己的条目并拖到它的前后。")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
        case .legacy(let id):
            Form {
                Section { Text(v.raw["promptTemplates"]?.object?[id]?.string ?? "").font(.footnote.monospaced()) }
                Section {
                    Button("恢复默认", role: .destructive) {
                        var all = v.raw["promptTemplates"]?.object ?? [:]
                        all[id] = nil
                        model.update { Presets.patch(&$0, presetId, ["promptTemplates": .object(all)]) }
                        sheet = nil
                    }
                } footer: {
                    Text("恢复后这一段改用内置版本，并且不再能修改。")
                }
            }
            .navigationTitle(id)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sheet = nil } } }
        }
    }

    private func saveCustom(_ c: Layout.Custom) {
        var o = c.json
        o["name"] = .string(c.name.trimmingCharacters(in: .whitespaces).isEmpty ? "未命名条目" : c.name.trimmingCharacters(in: .whitespaces))
        o["text"] = .string(c.text)
        let list = (v.raw["promptCustom"]?.array ?? []).map { $0["id"]?.string == c.id ? JSONValue.object(o) : $0 }
        model.update { Presets.patch(&$0, presetId, ["promptCustom": .array(list)]) }
        sheet = nil
    }

    private func dropCustom(_ id: String) {
        let list = (v.raw["promptCustom"]?.array ?? []).filter { $0["id"]?.string != id }
        model.update { Presets.patch(&$0, presetId, ["promptCustom": .array(list)]) }
        sheet = nil
    }
}

/// 自己加的条目：名字、正文、删除。
struct CustomEntryEditor: View {
    let entry: Layout.Custom
    let onSave: (Layout.Custom) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("名称") { TextField("例：文风", text: $name) }
            Section {
                TextEditor(text: $text).frame(minHeight: 200)
            } header: {
                Text("内容")
            } footer: {
                Text("按原文发送。{{charName}} 与 {{userName}} 填入角色名与用户名。")
            }
            Section { Button("删除这个条目", role: .destructive) { confirmDelete = true } }
        }
        .navigationTitle(entry.name.isEmpty ? "条目" : entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { var c = entry; c.name = name; c.text = text; onSave(c) }
            }
        }
        .confirmationDialog("四种情形里的这一条一并删除。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: onDelete)
        }
        .onAppear { name = entry.name; text = entry.text }
    }
}

/// 一组注入区块：组里的先后（injectOrder）。
struct GroupOrderView: View {
    let group: String
    let order: [String]?
    let onSave: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ids: [String] = []

    var body: some View {
        List {
            Section {
                ForEach(ids, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Layout.blockMeta[id]?.label ?? id)
                        if let d = Layout.blockMeta[id]?.desc, !d.isEmpty {
                            Text(d).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                .onMove { from, to in
                    var next = ids
                    next.move(fromOffsets: from, toOffset: to)
                    ids = next
                    save()
                }
            } footer: {
                Text(group == "now"
                     ? "这几项每轮都会变化，放在聊天记录下面时不影响前面内容的缓存。拖动调整组内先后。"
                     : "拖动调整组内先后。原生版尚未提供的功能也列在这里，没有内容时不发送。")
            }
        }
        .environment(\.editMode, .constant(ids.count > 1 ? .active : .inactive))
        .navigationTitle(Layout.groups[group]?.label ?? group)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .onAppear { ids = Layout.blocksOf(group, order) }
    }

    /// 组里的几块按新的先后放回整份顺序里它们原来占的那几个位置。
    private func save() {
        var all = Layout.resolveOrder(order)
        let slots = all.indices.filter { Layout.groupOf(all[$0]) == group }
        for (k, i) in slots.enumerated() where k < ids.count { all[i] = ids[k] }
        onSave(all)
    }
}

/// 改一段内置措辞。保存前核对：默认文本里由程序填的那几处一个都不能少（网页版 TemplateSheet）。
struct TemplateEditor: View {
    let templateId: String
    let current: String?
    /// nil 表示恢复默认（去掉这一项）
    let onSave: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    private var def: String { Templates.defaults[templateId] ?? "" }

    private var required: [String] {
        let re = try! NSRegularExpression(pattern: #"\{\{\w+\}\}"#)
        let ns = def as NSString
        var out: [String] = []
        for m in re.matches(in: def, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range)
            if t != "{{charName}}" && t != "{{userName}}" && !out.contains(t) { out.append(t) }
        }
        return out
    }

    private var missing: [String] { required.filter { !draft.contains($0) } }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draft).font(.footnote.monospaced()).frame(minHeight: 260)
            } footer: {
                Text(required.isEmpty
                     ? "{{charName}} 与 {{userName}} 填入角色名与用户名，可删去。"
                     : "\(required.joined(separator: " ")) 由应用填入，必须保留。{{charName}} 与 {{userName}} 填入角色名与用户名，可删去。")
            }
            if !missing.isEmpty {
                Section { Text("缺少 \(missing.joined(separator: " "))，无法保存。").foregroundStyle(Theme.danger) }
            }
            Section { Button("恢复默认") { draft = def } }
        }
        .navigationTitle(templateId)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { onSave(draft == def ? nil : draft); dismiss() }.disabled(!missing.isEmpty)
            }
        }
        .onAppear { draft = (current?.isEmpty == false ? current : nil) ?? def }
    }
}

// MARK: - 不要写这些

/// 用户自己列的禁写词（网页版 system/ban.js）。默认一条都没有，内置也不给。
enum Ban {
    static func list(_ s: AppSettings) -> [String] {
        let raw: [String]
        switch s.raw["banPhrases"] {
        case .array(let a)?: raw = a.compactMap(\.string)
        case .string(let t)?: raw = t.components(separatedBy: .newlines)
        default: raw = []
        }
        var out: [String] = []
        for x in raw {
            let t = x.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// 去掉星号与空格后不到两个字的，几乎每段话都会命中。
    static func tooBroad(_ p: String) -> Bool {
        p.replacingOccurrences(of: "*", with: "").filter { !$0.isWhitespace }.count < 2
    }
}

struct BanView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text).frame(minHeight: 220).focused($focused)
            } header: {
                Text("词句列表")
            } footer: {
                Text("列出不希望角色使用的词句，每行一条。该列表对所有角色生效，默认为空。列出的内容会写入每一轮的提示词。星号代替中间最多十二个字，不跨行，例如「把*揉进骨血里」。")
            }
            let broad = Ban.list(model.s).filter(Ban.tooBroad)
            if !broad.isEmpty {
                Section {
                    Text("以下条目过短，几乎每段话都会命中：\(broad.joined(separator: "、"))").foregroundStyle(Theme.danger)
                }
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("不要写这些")
        .onAppear { text = Ban.list(model.s).joined(separator: "\n") }
        .onChange(of: focused) { _, f in if !f { save() } }
        .onDisappear(perform: save)
    }

    private func save() {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines != Ban.list(model.s) else { return }
        model.set("banPhrases", .array(lines.map { .string($0) }))
    }
}

// MARK: - 能力

/// 能力开关（网页版 CapsPage）。关掉的不写进提示词，角色不知道有这项功能。对所有角色生效。
/// 原生版只列回复解析认得的几项；capsOff 里网页版其余能力的开关原样留着。
struct CapsView: View {
    @ObservedObject private var model = SettingsModel.shared

    struct Cap: Identifiable {
        let id: String
        let label: String
        let info: String
    }

    static let caps = [
        Cap(id: "sticker", label: "表情", info: "角色可以发送表情包里的表情"),
        Cap(id: "quote", label: "引用", info: "角色可以引用某一条消息再回复"),
        Cap(id: "recall", label: "撤回", info: "角色可以撤回自己的消息"),
        Cap(id: "dice", label: "骰子", info: "角色可以掷骰子"),
    ]

    static func off(_ s: AppSettings) -> Set<String> {
        Set((s.raw["capsOff"]?.array ?? []).compactMap(\.string))
    }

    static func onCount(_ s: AppSettings) -> Int {
        let o = off(s)
        return caps.filter { !o.contains($0.id) }.count
    }

    var body: some View {
        Form {
            Section {
                ForEach(Self.caps) { c in
                    Toggle(isOn: binding(c.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.label)
                            Text(c.info + (Self.off(model.s).contains(c.id) ? "。已关闭：角色卡与各处对这一项的开关不再生效" : ""))
                                .font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            } footer: {
                Text("关闭的能力不写进提示词，角色不知道有这项功能。对所有角色生效。旁白的开关在会话设置中。网页版其余能力的开关原样保留，原生版提供这些功能后一并列出。")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("能力")
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { !Self.off(model.s).contains(id) },
                set: { want in
                    var list = (model.s.raw["capsOff"]?.array ?? []).compactMap(\.string).filter { $0 != id }
                    if !want { list.append(id) }
                    model.set("capsOff", .array(list.map { .string($0) }))
                })
    }
}
