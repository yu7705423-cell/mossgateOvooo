import SwiftUI
import UniformTypeIdentifiers

/// 「设定集」（网页版 apps/preset，ARCHITECTURE 4.386）：角色读到什么、角色怎么写、角色能做什么。
struct CanonView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var loreCount = 0
    @State private var memoryCount = 0
    @State private var hero = true

    var body: some View {
        NavigationStack {
            List {
                HeroHeader(eyebrow: "CANON", title: "设定集", shown: $hero)
                Section {
                    NavigationLink { LorebookListView() } label: { IconRow(title: "世界书", icon: "book", value: "\(loreCount) 本") }
                    NavigationLink { MemoryCharsView() } label: { IconRow(title: "记忆", icon: "brain", value: "\(memoryCount) 条") }
                } header: { GroupTitle("角色知道什么") }
                Section {
                    NavigationLink { PresetListView() } label: {
                        IconRow(title: "预设", icon: "layers", value: Presets.name(model.s, Presets.activeId(model.s)))
                    }
                    NavigationLink { RegexListView() } label: {
                        let n = RegexRules.list(model.s).filter(\.on).count
                        IconRow(title: "正则替换", icon: "code", value: n > 0 ? "\(n) 条开启" : "未设置")
                    }
                    NavigationLink { BanView() } label: {
                        IconRow(title: "不要写这些", icon: "filter", value: Ban.list(model.s).isEmpty ? "未设置" : "\(Ban.list(model.s).count) 条")
                    }
                } header: { GroupTitle("角色怎么写") }
                Section {
                    NavigationLink { CapsView() } label: {
                        IconRow(title: "能力", icon: "sliders", value: "开启 \(CapsView.onCount(model.s)) / \(CapsView.caps.count)")
                    }
                } header: { GroupTitle("角色能做什么") }
            }
            .heroTitle("设定集", heroShown: hero)
            .onAppear {
                model.reload()
                let counts = (try? Database.shared.counts()) ?? [:]
                loreCount = counts[Collections.lorebooks] ?? 0
                memoryCount = counts[Collections.memories] ?? 0
            }
        }
    }

}

/// 记忆按角色分开，先选角色。
struct MemoryCharsView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var chars: [Character] = []
    @State private var problem: String?
    var body: some View {
        List {
            Section {
                Toggle("角色读得到记忆", isOn: model.bool("memoryEnabled", true))
            } footer: {
                HelpNote("关闭后记忆不写进提示词，也不自动总结。手动「立即总结」不受影响。")
            }
            Section {
                LabeledContent("自动总结", value: MemorySummary.autoText(model.s))
            } footer: {
                HelpNote("自动总结的开关与触发条件在会话菜单的「记忆总结」中设置，对所有会话生效。", title: "记忆：自动总结")
            }
            Section {
                NumberRow(title: "一次总结的条数", value: model.number("memoryBatch", 200), unit: "条", placeholder: "全部")
                NumberRow(title: "总结记忆的输出上限", value: model.number("memoryExtractMaxTokens", 0), unit: "token", placeholder: "不限")
            } footer: {
                Text("输出上限偏小时会在半路截断，那一次照样计费。")
                HelpNote("没设「按轮数自动总结」时，一次总结最多拿最早的这么多条消息去拼请求，填 0 表示一次全拿；剩下的下次接着总结。设了轮数时一次总结的是最早的那么多轮，此项不起作用。输出上限偏小时会在半路截断，那一次照样计费。")
            }
            ProblemSection(text: model.problem)
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
    @State private var importing = false

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
                Button("导入预设") { importing = true }
            } footer: {
                HelpNote("一套预设是发给模型的条目顺序：线上聊天、线下、群聊、通话各一份，可以调整先后、开关、添加自己的条目，另有每轮条数等参数。全局使用一套；每段对话可以在会话设置中另选一套。新建时复制全局使用中的那一套。")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("预设")
        .navigationDestination(item: $opening) { t in PresetEditView(presetId: t.id) }
        .documentPicker(isPresented: $importing, types: [.json]) { urls in
            guard let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                var failure: Error?
                model.update { do { _ = try Presets.importData(&$0, data) } catch { failure = error } }
                if let failure { model.problem = failure.localizedDescription }
            } catch { model.problem = "无法读取文件：\(error.localizedDescription)" }
        }
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
    @State private var exported: URL?

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
                    if let exported {
                        ShareLink(item: exported) { Label("存储或发送导出的预设", systemImage: "square.and.arrow.up") }
                    }
                    Picker("情形", selection: $mode) {
                        ForEach(Layout.modes) { m in Text(m.label).tag(m.id) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    HelpNote("从上到下即发给模型的顺序。点右上角「排序」后拖动调整位置；关闭的一条不发送。标为「必需」的关系到回复能否被正确拆分，不能关闭；标为「跟随开关」的由各自功能的开关决定，在这里只调整位置。")
                }
                Section {
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
                    Button("添加条目") { addEntry() }
                    // 思维链（网页版 4.580）：一套预设只有一条，有了就不再显示入口
                    if !Layout.customs(v).contains(where: { $0.think }) {
                        Button("添加思维链") { addEntry(think: true) }
                    }
                } header: {
                    Text("条目")
                } footer: {
                    HelpNote("自己写思考的步骤。模型在回复前按这些步骤思考，思考内容不显示在聊天中，长按消息可查看。", title: "添加思维链")
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
                        Button("导出") {
                            do { exported = try Presets.exportFile(model.s, presetId) }
                            catch { model.problem = "导出失败：\(error.localizedDescription)" }
                        }
                        if !isActive { Button("删除", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText) }
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
                             sub: (c?.think == true ? "思维链 · " : "") + (text.isEmpty ? "尚未填写" : String(text.prefix(40))), follow: "", locked: false,
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

    private func addEntry(think: Bool = false) {
        let id = Ids.make("c")
        var list = items
        let h = list.firstIndex { $0.id == Layout.history } ?? list.count
        list.insert(Layout.Item(id: "custom:\(id)", on: true), at: h)
        var entry: [String: JSONValue] = ["id": .string(id), "name": .string(think ? "思维链" : "新条目"), "text": .string("")]
        if think { entry["think"] = .bool(true) }
        let customs = (v.raw["promptCustom"]?.array ?? []) + [.object(entry)]
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
            HelpNote("每轮条数：线上聊天与群聊每轮回复分几条发出。旁白每轮至少：开启旁白时生效，填 0 表示不要求。按需注入：开启时平时只给能力清单，某项能力最近用到时才注入完整说明；关闭后开启的能力每轮都注入完整说明。")
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
            Text("条数越多，每次请求的用量越大。")
            HelpNote("历史范围：每次请求附带最近多少条消息或多少轮，填 0 表示全部。条数越多，每次请求的用量越大。扫描窗口：世界书与记忆在最近若干条消息中匹配关键词，填 0 表示整段对话。注入预算：世界书、记忆与对话历史的 token 上限，填 0 表示不截断。")
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
                            Text(TemplateLabels.of(id)).foregroundStyle(Theme.bubbleTheirsText)
                            Text("仍按修改后的版本生效").font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            } header: {
                Text("以前修改过的内置提示词")
            } footer: {
                HelpNote("这些段落含有应用需要读取的格式，现已不开放修改。以前改过的版本继续生效；恢复默认后不能再改。")
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
                    HelpNote("这一段含有应用需要读取的格式，由应用维护，不开放修改。需要补充要求时，可添加自己的条目并拖到它的前后。", title: "锁定的内置段落")
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
                    Text("恢复后不能再修改。")
                    HelpNote("恢复后这一段改用内置版本，并且不再能修改。")
                }
            }
            .navigationTitle(TemplateLabels.of(id))
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
            Section("名称") { TextField(entry.think ? "思维链" : "例：文风", text: $name) }
            if entry.think {
                // 思维链（网页版 4.580）：内容是思考的步骤，由用户写；发送时前面加一行固定的格式说明
                Section {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("每行一步，例如：\n1. 梳理对方这句话的意思\n2. 对照角色的人设与当前处境\n3. 决定这一轮要说什么")
                                .foregroundStyle(Theme.tertiaryText).padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text).frame(minHeight: 200)
                    }
                } header: {
                    Text("思考的步骤")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("思考的文字同样计入回复长度，开启后每轮回复会变长、费用相应增加；不增加请求次数。内容为空时整条不发送。")
                        HelpNote("按原文发送。发送时前面附上一行固定的格式说明：回复之前先在 <thinking></thinking> 中按这些步骤思考，这一段在显示前去除，不算作消息。思考的内容在长按消息后的「查看思考」中查看。{{charName}} 与 {{userName}} 填入角色名与用户名。", title: "思考的步骤")
                    }
                }
            } else {
                Section {
                    TextEditor(text: $text).frame(minHeight: 200)
                } header: {
                    Text("内容")
                } footer: {
                    HelpNote("按原文发送。{{charName}} 与 {{userName}} 填入角色名与用户名。")
                }
            }
            Section { Button("删除这个条目", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText) }
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
                HelpNote(group == "now"
                     ? "这几项每轮都会变化，放在聊天记录下面时不影响前面内容的缓存。拖动调整组内先后。"
                     : "拖动调整组内先后。原生版尚未提供的功能也列在这里，没有内容时不发送。", title: "提示词条目分组")
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
                HelpNote(required.isEmpty
                     ? "{{charName}} 与 {{userName}} 填入角色名与用户名，可删去。"
                     : "\(required.joined(separator: " ")) 由应用填入，必须保留。{{charName}} 与 {{userName}} 填入角色名与用户名，可删去。", title: "编辑提示词段落")
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

// MARK: - 内置提示词的名称

/// 内置提示词各段的中文名（网页版 preset/prompt/TemplatesPage.js 的 LABELS，逐字照抄，只留原生版 templates.json 里有的）。
/// 「以前修改过的内置提示词」按它显示，没有名称的显示内部 id（网页版 labelOf）
enum TemplateLabels {
    static func of(_ id: String) -> String { labels[id] ?? id }

    static let labels: [String: String] = [
        "skeleton.opening": "骨架 · 身份开场",
        "skeleton.scene-opening": "线下 · 开场",
        "skeleton.scene-rules": "线下 · 正文规则",
        "skeleton.scene-length": "线下 · 篇幅",
        "skeleton.scene-setup": "线下 · 场次设定",
        "skeleton.scene-director": "线下 · 场外指示",
        "skeleton.scene-style": "线下 · 文风",
        "skeleton.scene-more": "线下 · 续写",
        "skeleton.scene-tail": "线下 · 收尾提醒（贴着输出）",
        "skeleton.prose-trans": "线下、长篇、番外 · 附带译文",
        "task.scene-summary": "任务 · 线下收场摘要",
        "skeleton.work-opening": "我们 · 开场",
        "skeleton.work-solo": "我们 · 正文规则（整篇它写）",
        "skeleton.work-premise": "我们 · 这部作品",
        "skeleton.work-identity": "我们 · 这部作品里的身份",
        "skeleton.work-identity-carry": "我们 · 带着记忆时身份那一句",
        "skeleton.work-chapter": "我们 · 这一篇",
        "skeleton.work-prev": "我们 · 前面各篇的进展",
        "task.work-summary": "任务 · 我们收篇摘要",
        "task.bond": "任务 · 压缩关系底色",
        "task.core": "任务 · 压缩核心设定",
        "skeleton.gender": "骨架 · 性别锚点",
        "skeleton.world": "骨架 · 世界规则抬头",
        "skeleton.rules": "骨架 · 消息规则",
        "skeleton.core": "骨架 · 核心设定",
        "skeleton.sticker": "骨架 · 可用表情",
        "skeleton.quote": "骨架 · 引用某一句",
        "skeleton.time": "骨架 · 先写出时间",
        "skeleton.ban": "骨架 · 不要写这些",
        "skeleton.todo": "骨架 · 待办",
        "skeleton.wish": "骨架 · 心愿",
        "skeleton.acquire": "骨架 · 入手记录",
        "skeleton.mall": "骨架 · 商城",
        "skeleton.slip": "骨架 · 纸条",
        "skeleton.alt": "骨架 · 小号",
        "skeleton.friend-moments": "骨架 · 认识的人的朋友圈（点赞、评论、转发）",
        "skeleton.forum": "骨架 · 论坛（转发帖子）",
        "skeleton.ties": "骨架 · 好友与拉黑",
        "skeleton.sms-opening": "骨架 · 短信开场",
        "skeleton.sms-unknown": "骨架 · 短信：身份未确认",
        "skeleton.sms-known": "骨架 · 短信：身份已确认",
        "skeleton.sms-rules": "骨架 · 短信规则",
        "skeleton.sms-send": "骨架 · 发短信与借号",
        "skeleton.sms-id": "骨架 · 短信里认出对方",
        "skeleton.translate": "骨架 · 顺带给出译文",
        "skeleton.translate-marked": "骨架 · 译文：哪几种标记各跟一句译文",
        "skeleton.translate-voice": "骨架 · 译文：语音只译说出口的话",
        "skeleton.translate-tail": "骨架 · 译文提醒（贴着输出）",
        "task.translate": "任务 · 单独的翻译接口",
        "skeleton.transfer": "骨架 · 转账",
        "skeleton.location": "骨架 · 位置",
        "skeleton.abilities": "骨架 · 能力清单",
        "skeleton.image": "骨架 · 发图片",
        "skeleton.voice": "骨架 · 发语音",
        "skeleton.gift": "骨架 · 送礼物",
        "skeleton.listen": "骨架 · 一起听歌",
        "skeleton.mcp": "骨架 · 调用工具（MCP）",
        "skeleton.joint": "骨架 · 情侣账户与亲属卡",
        "skeleton.pact": "骨架 · 约定",
        "skeleton.inner": "骨架 · 心声（随回复一起）",
        "task.inner": "任务 · 心声（单独生成）",
        "task.gacha-gen": "任务 · 扭蛋机批量生成",
        "skeleton.pass": "骨架 · 门禁卡与钥匙",
        "task.idcard-read": "任务 · 从角色卡读证件",
        "skeleton.ticket": "骨架 · 票券",
        "skeleton.group-say": "骨架 · 在群里发消息",
        "skeleton.member": "骨架 · 会员卡",
        "skeleton.inner-card": "骨架 · 心声卡片（随回复一起）",
        "skeleton.inner-group": "骨架 · 群聊的心声",
        "task.inner-card": "任务 · 心声卡片（单独生成）",
        "task.inner-trans": "任务 · 心声的译文（单独生成）",
        "task.json-trans": "任务 · 译文（朋友圈等）",
        "task.json-trans-fields": "任务 · 译文（信、日记、角色手机等多个字段）",
        "task.text-trans": "任务 · 译文（读后感、段评、年度回顾）",
        "skeleton.pat": "骨架 · 拍一拍",
        "skeleton.remark": "骨架 · 改备注",
        "skeleton.follow-up": "骨架 · 对方未回复时接着说",
        "skeleton.recall": "骨架 · 撤回",
        "skeleton.recall-post": "骨架 · 撤回动态",
        "skeleton.dice": "骨架 · 骰子",
        "skeleton.group-dm": "骨架 · 群里发私信",
        "skeleton.group-nick": "骨架 · 群昵称",
        "skeleton.group-admin": "骨架 · 群管理",
        "skeleton.takeout": "骨架 · 点外卖",
        "skeleton.avatar": "骨架 · 换头像",
        "skeleton.ring": "骨架 · 打电话",
        "skeleton.call": "骨架 · 通话中",
        "skeleton.call-notrans": "骨架 · 通话中不带译文",
        "skeleton.call-translate": "骨架 · 通话中逐句译文",
        "skeleton.call-voice": "骨架 · 语音通话的动作",
        "skeleton.call-video": "骨架 · 视频通话的动作",
        "task.call-open": "任务 · 通话接通后开口",
        "skeleton.group": "骨架 · 群聊说明（每个角色单独调用时）",
        "skeleton.group-opening": "骨架 · 群聊开场（一次调用写整轮）",
        "skeleton.group-rules": "骨架 · 群聊格式",
        "skeleton.group-mention": "骨架 · 群聊点名",
        "skeleton.call-script": "骨架 · 通话台本标记",
        "task.voice-script": "任务 · 语音台本",
        "task.call-summary": "任务 · 通话总结",
        "skeleton.video": "骨架 · 发视频",
        "task.appearance": "任务 · 从人设里抽外貌",
        "task.image-prompt": "任务 · 写生图提示词",
        "task.video-prompt": "任务 · 写视频提示词",
        "task.group-proactive": "任务 · 群里主动开口",
        "skeleton.award": "骨架 · 颁发标识",
        "skeleton.outfit": "骨架 · 搭配衣帽间里的衣物",
        "skeleton.narration": "骨架 · 旁白",
        "skeleton.card": "骨架 · HTML 卡片",
        "skeleton.lockcode": "骨架 · 改锁屏密码",
        "skeleton.closet-act": "骨架 · 衣帽间：换上、借走、借给、归还",
        "skeleton.scene-closet": "骨架 · 线下的衣帽间标记与塞进包里",
        "task.year-note": "任务 · 年度回顾里的一段话",
        "task.memory-extract": "任务 · 提取记忆",
        "task.memory-who": "任务 · 提取记忆：谁是谁",
        "task.memory-who-group": "任务 · 提取记忆：谁是谁（联机群）",
        "task.memory-lore": "任务 · 记忆总结用的世界书",
        "task.wish-check": "任务 · 提取记忆时顺带判定心愿",
        "task.badge-check": "任务 · 提取记忆时顺带判定自定义标识",
        "task.user-sched": "任务 · 导入我的日程（文件与截图）",
        "task.wish-judge": "任务 · 单独判定心愿",
        "task.memory-import": "任务 · 从文本导入记忆",
        "task.chat-summarize": "任务 · 压缩历史",
        "task.card-import": "任务 · 导入角色卡",
        "task.npc-batch": "任务 · 批量生成 NPC",
        "task.npc-tool": "工具箱 · NPC 生成器",
        "task.user-tool": "工具箱 · User 生成器",
        "task.pet-tool": "工具箱 · 宠物生成器",
        "task.monitor": "监控 · 生成记录",
        "task.world-build": "工具箱 · 世界观生成器",
        "task.world-module": "工具箱 · 世界观：重写一个模块",
        "task.world-tags": "工具箱 · 世界观：批量生成标签",
        "task.lore-outline": "工具箱 · 世界书：大纲",
        "task.lore-body": "工具箱 · 世界书：正文",
        "task.lore-examples": "工具箱 · 世界书：示例",
        "task.lore-selfcheck": "工具箱 · 世界书：自检",
        "task.lore-review": "工具箱 · 世界书：独立审查",
        "task.lore-revise": "工具箱 · 世界书：修订",
        "task.extra-compile": "工具箱 · 番外：AI 整理",
        "task.extra-storyline": "工具箱 · 番外：编主线",
        "task.extra-tags": "工具箱 · 番外：批量生成标签",
        "skeleton.face-opening": "骨架 · 线下开场（会话里切到线下）",
        "skeleton.face-mark": "骨架 · 以下当面（历史里的分界）",
        "skeleton.scene-mark": "线上历史 · 线下见面那一段的开头",
        "skeleton.group-chat-mark": "群聊历史 · 线下那一段之后回到群里",
        "skeleton.phone-mark": "骨架 · 以下在手机上（历史里的分界）",
        "skeleton.work-outline": "骨架 · 长篇大纲",
        "task.novel-synopsis": "长篇向导 · 简介",
        "task.novel-identity": "任务 · 按作品的世界改写身份",
        "task.novel-outline": "长篇向导 · 总纲",
        "task.novel-volume": "长篇向导 · 一卷的章纲",
        "task.novel-branches": "长篇 · 章末几个走向",
        "task.novel-replan": "长篇 · 重排后续大纲",
        "skeleton.file": "骨架 · 文件",
        "skeleton.file-fill": "骨架 · 填写对方发来的文件",
        "task.file-fill": "任务 · 让角色填写文件",
        "task.cardgen": "工具箱 · HTML 卡片生成器",
        "task.cardgen-edit": "工具箱 · HTML 卡片：修改",
        "task.card-fill": "任务 · 卡片「帮我填」",
        "task.event-batch": "任务 · 批量生成随机事件",
        "task.day-plan": "任务 · 排当天的日程",
        "task.health-day": "任务 · 生成角色当天的健康记录",
        "task.diary": "任务 · 角色写日记",
        "task.drama-plot": "任务 · 音声：剧情",
        "task.drama-anchors": "任务 · 音声：性格锚点",
        "task.drama-script": "任务 · 音声：台本",
        "task.impress": "任务 · 整理对我的印象",
        "task.impress-compare": "任务 · 对照几位角色的印象",
        "task.impress-note": "任务 · 总结记忆时顺带记下印象的依据",
        "skeleton.drafts": "骨架 · 草稿箱",
        "task.letter": "任务 · 角色写信",
        "skeleton.image-en": "骨架 · 图片描述写英文",
        "task.image-translate": "任务 · 生图提示词译成英文",
        "task.letter-moment": "任务 · 总结时顺带看写信的时刻",
        "task.snap": "任务 · 角色自己往相册存照片",
        "task.recipe-batch": "任务 · 批量生成食谱",
        "task.recipe-search": "任务 · 联网搜索吃处",
        "skeleton.agenda": "骨架 · 今天的安排",
        "task.proactive": "任务 · 主动发起对话",
        "task.emo": "任务 · 深夜主动发起",
        "task.vision-describe": "任务 · 识图描述",
        "task.xhs-vision": "任务 · 链接卡片图片描述",
        "task.face-describe": "任务 · 读取角色外貌",
        "task.asr-tone": "任务 · 语音转写与语气",
        "task.moment-create": "任务 · 发朋友圈",
        "task.moment-song": "任务 · 动态附带歌曲",
        "task.moment-recall": "任务 · 回复评论后撤回动态",
        "task.closet-vision": "任务 · 衣帽间识图",
        "task.closet-image": "任务 · 衣帽间按描述生图",
        "task.closet-wardrobe": "任务 · 按角色设定生成衣帽间",
        "task.collect-gen": "任务 · 按角色设定生成收藏馆",
        "task.collect-image": "任务 · 收藏馆按外观生图",
        "task.mall-image": "任务 · 商城按描述词生图",
        "task.mall-nick": "任务 · 生成角色的商城昵称",
        "task.mall-refresh": "任务 · 商城刷新",
        "task.forum-refresh": "任务 · 论坛刷新版块",
        "task.forum-replies": "任务 · 论坛加载更多回复",
        "task.forum-court": "任务 · 论坛小法庭陪审发言",
        "task.forum-dm": "任务 · 论坛私信回复",
        "task.mall-value": "任务 · 商城拍卖估价",
        "task.mall-charlist": "任务 · 角色自己挂东西",
        "task.mall-npc-reply": "任务 · 商城私聊里买家或卖家回复",
        "task.mall-char-reply": "任务 · 商城私聊里角色回复",
        "task.char-money": "任务 · 按角色卡生成角色的钱",
        "task.closet-daily": "任务 · 角色的每日穿搭",
        "task.closet-daily-weather": "任务 · 每日穿搭的天气约束",
        "task.moment-comment": "任务 · 评论动态",
        "task.moment-reply": "任务 · 回复评论",
        "task.moment-reply-thread": "任务 · 回复别人动态下的评论",
        "task.scenario-seeds": "任务 · 生成近况",
        "skeleton.watch": "骨架 · 一起看",
        "task.watch-outline": "任务 · 影片分段提纲",
        "task.review": "任务 · 看完之后写观后感",
        "skeleton.trip": "骨架 · 出行",
        "task.trip-tickets": "任务 · 联网找票",
        "task.trip-tickets-guess": "任务 · 估算票价",
        "task.trip-plan": "任务 · 联网检索攻略",
        "task.trip-plan-guess": "任务 · 估算攻略",
        "task.shelf-batch": "任务 · 批量生成读过的书",
        "task.impression": "任务 · 一本书留下的印象",
        "task.read-ahead": "任务 · 挑出想评的段落",
        "task.para-one": "任务 · 对某一段的评论",
        "task.para-crew": "任务 · 同读的几个人的评论",
        "task.para-readers": "任务 · 读者们的评论",
        "skeleton.keepphoto": "骨架 · 存图",
        "task.phone-crop": "任务 · 存图时的裁切",
        "task.phone-lock": "任务 · 角色手机的锁屏密码",
        "task.phone-notes": "任务 · 角色手机的备忘录",
        "task.phone-visits": "任务 · 角色手机的浏览记录",
        "task.phone-album": "任务 · 角色手机的相册",
        "task.phone-chats": "任务 · 角色手机的会话列表",
        "task.phone-chat": "任务 · 角色手机里的某段对话",
        "task.phone-reply": "任务 · 角色手机里对方的回复",
    ]
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

    /// 一条词条编译成正则：星号代替中间最多十二个字（不跨行），空白当可有可无，不分大小写（网页版 reOf）。
    static func regex(_ phrase: String) -> NSRegularExpression? {
        let body = phrase.trimmingCharacters(in: .whitespaces).components(separatedBy: "*")
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: #"\s+"#, with: #"\\s*"#, options: .regularExpression) }
            .joined(separator: "[^\\n]{0,12}")
        guard !body.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: body, options: [.caseInsensitive])
    }

    /// 这段话踩了哪几条。回来的是词条原文。
    static func scan(_ text: String, _ phrases: [String]) -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return phrases.filter { regex($0)?.firstMatch(in: text, range: range) != nil }
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
                HelpNote("列出不希望角色使用的词句，每行一条。该列表对所有角色生效，默认为空。列出的内容会写入每一轮的提示词。星号代替中间最多十二个字，不跨行，例如「把*揉进骨血里」。")
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
    @State private var query = ""

    struct Cap: Identifiable {
        let id: String
        let label: String
        let group: String
        let info: String
    }

    /// 原生版会拼进提示词、能在这里关的那几样（网页版 CapsPage 的 INFO，分组与说明同一份）。
    /// 时间戳、译文是解析格式的一部分，旁白、心声的开关在会话里，这里不列（网页版 PROTOCOL、OWN_SWITCH）
    static let caps = [
        Cap(id: "image", label: "发图片", group: "消息", info: "角色可以发送图片。生成图片需另外配置生图接口"),
        Cap(id: "voice", label: "发语音", group: "消息", info: "角色可以发送语音消息"),
        Cap(id: "sticker", label: "发表情", group: "消息", info: "角色可以发送表情包里的表情"),
        Cap(id: "keepphoto", label: "往自己相册存图", group: "消息", info: "角色可以把聊天中的图片存进自己的相册。另需在「角色手机 - 相册」中为该角色开启"),
        Cap(id: "quote", label: "引用消息", group: "消息", info: "角色可以引用某一条消息再回复"),
        Cap(id: "recall", label: "撤回", group: "消息", info: "角色可以撤回自己的消息"),
        Cap(id: "react", label: "回应消息", group: "消息", info: "角色可以对某一条消息贴一个 emoji 回应"),
        Cap(id: "silence", label: "不回复", group: "消息", info: "角色可以选择不回复，此时会话中显示「已读，未回复」。「角色能力」中的开关默认关闭"),
        Cap(id: "transfer", label: "转账", group: "互动", info: "角色可以转账，以及收下或退回用户的转账"),
        Cap(id: "gift", label: "送礼物", group: "互动", info: "角色可以送礼物"),
        Cap(id: "takeout", label: "外卖与请客", group: "互动", info: "角色可以点外卖或请客"),
        Cap(id: "pat", label: "拍一拍", group: "互动", info: "角色可以拍一拍"),
        Cap(id: "lockcode", label: "改锁屏密码", group: "互动", info: "角色可以修改自己的锁屏密码。距上次修改不满「角色能力」中设定的天数（默认 30）时不提供，聊到密码时除外"),
        Cap(id: "avatar", label: "换头像", group: "互动", info: "角色可以从头像库中挑一张换上。头像库为空时不提供"),
        Cap(id: "remark", label: "改备注", group: "互动", info: "角色可以修改给用户的备注"),
        Cap(id: "dice", label: "骰子", group: "互动", info: "角色可以掷骰子"),
        Cap(id: "award", label: "颁发标识", group: "互动", info: "角色可以给用户颁发一枚互动标识，记进这段对话的标识收藏。删掉那一条消息时标识一并收回"),
        Cap(id: "card", label: "HTML 卡片", group: "消息", info: "角色可以按世界书里的卡片条目发一张卡片。只有常驻的、或最近几条消息里出现了关键词的卡片才提供"),
        Cap(id: "groupnick", label: "改群昵称", group: "群聊", info: "群里的角色可以修改自己的群昵称，群里出现一行提示"),
        Cap(id: "groupadmin", label: "群管理", group: "群聊", info: "群里有管理员时，管理员可以禁言、解除禁言、开关全员禁言、修改普通成员的群昵称。管不了群主与其他管理员"),
        Cap(id: "ties", label: "好友与拉黑", group: "社交", info: "角色可以加好友、拉黑或解除"),
        Cap(id: "agenda", label: "日程事项", group: "生活", info: "角色可以安排日程事项"),
        Cap(id: "pact", label: "约定", group: "互动", info: "角色可以与用户立下约定，完成后标记"),
        Cap(id: "location", label: "共享位置", group: "生活", info: "角色可以共享位置"),
        Cap(id: "listen", label: "一起听、点歌、分享歌曲与歌单", group: "一起", info: "角色可以邀请一起听、点歌、分享歌曲与歌单"),
        Cap(id: "ring", label: "打电话过来", group: "一起", info: "角色可以给用户打语音电话。正在看这段会话时响铃，否则记为未接来电。接听后每说一轮调用一次接口，与自己打出去相同"),
    ]
    static let groups = ["消息", "互动", "社交", "生活", "一起", "群聊"]
    /// 开关不在这里的
    static let elsewhere: [(label: String, info: String)] = [
        ("旁白", "开关在会话菜单的「旁白」中"), ("心声", "开关、写法与样式在会话菜单的「心声」中"),
    ]
    static let always: [String] = ["时间戳", "译文"]

    static func off(_ s: AppSettings) -> Set<String> {
        Set((s.raw["capsOff"]?.array ?? []).compactMap(\.string))
    }

    static func onCount(_ s: AppSettings) -> Int {
        let o = off(s)
        return caps.filter { !o.contains($0.id) }.count
    }

    var body: some View {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hit = { (c: Cap) in key.isEmpty || c.label.contains(key) || c.info.contains(key) }
        Form {
            Section {
                HStack {
                    Text("已开启 \(Self.onCount(model.s)) / \(Self.caps.count)").foregroundStyle(Theme.text2)
                    Spacer()
                    Button("全部开启") { setAll(true) }.buttonStyle(.borderless)
                    Button("全部关闭") { setAll(false) }.buttonStyle(.borderless)
                }
                .font(.footnote)
            } footer: {
                HelpNote("关闭的能力不写进提示词，角色不知道有这项功能。对所有角色生效，「角色能力」中的同一项随之不生效（该页会注明）；只让某一个角色不发图、不发语音，在与该角色的会话菜单中的「角色能力」设置。关闭某项不会删除已有的记录。预设里的「能力说明」一条跟随这里与「角色能力」的开关，不能在预设里单独关闭。", title: "能力开关")
            }
            if key.isEmpty {
                Section {
                    ForEach(NewFeat.features, id: \.id) { f in
                        Toggle(isOn: featureBinding(f.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.label)
                                if NewFeat.decided(f.id, model.s).isEmpty {
                                    Text("尚未选择").font(.footnote).foregroundStyle(Theme.text3)
                                }
                            }
                        }
                    }
                } header: { Text("新功能") } footer: {
                    HelpNote("新加的功能默认不写进提示词，开启后才生效。宠物、测试问卷所在的 app 原生版尚未提供，这里的选择与网页版共用同一个设置。", title: "新功能")
                }
            }
            ForEach(Self.groups, id: \.self) { g in
                let items = Self.caps.filter { $0.group == g && hit($0) }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { c in
                            Toggle(isOn: binding(c.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.label)
                                    if Self.off(model.s).contains(c.id) {
                                        Text("已关闭：「角色能力」与各处对这一项的开关不再生效").font(.footnote).foregroundStyle(Theme.text3)
                                    }
                                }
                            }
                        }
                    } header: { Text("\(g) · \(items.count) 项") }
                }
            }
            if key.isEmpty {
                Section {
                    ForEach(Self.elsewhere, id: \.label) { e in
                        LabeledContent(e.label) { Text(e.info).font(.footnote).foregroundStyle(Theme.text3) }
                    }
                } header: { Text("开关在会话中") }
                Section {
                    ForEach(Self.always, id: \.self) { Text($0) }
                } header: { Text("始终开启") } footer: {
                    HelpNote("这几项是解析格式的一部分，关闭后应用读不出模型写的那几行。", title: "始终开启")
                }
            }
            ProblemSection(text: model.problem)
        }
        .searchable(text: $query, prompt: "搜索能力")
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

    /// 全部开启只清掉这里列出的那几样；网页版有、原生版还没有的能力，关过的照旧关着
    private func setAll(_ on: Bool) {
        let mine = Set(Self.caps.map(\.id))
        var list = (model.s.raw["capsOff"]?.array ?? []).compactMap(\.string).filter { !mine.contains($0) }
        if !on { list += Self.caps.map(\.id) }
        model.set("capsOff", .array(list.map { .string($0) }))
    }

    private func featureBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { NewFeat.isOn(id, model.s) }, set: { v in model.update { NewFeat.set(id, v, &$0) } })
    }
}

// MARK: - 正则替换

struct RegexListView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var opening: Target?
    @State private var importing = false
    @State private var exported: URL?
    @State private var note: String?

    struct Target: Identifiable, Hashable { let id: String }

    var body: some View {
        List {
            Section {
                ForEach(RegexRules.list(model.s)) { r in
                    HStack {
                        Button { opening = Target(id: r.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name.isEmpty ? "未命名规则" : r.name).foregroundStyle(Theme.bubbleTheirsText)
                                Text(summary(r)).font(.footnote).foregroundStyle(summaryIsError(r) ? Theme.danger : Theme.secondaryText)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { r.on }, set: { v in patch(r.id, ["on": .bool(v)]) })).labelsHidden()
                    }
                }
                .onMove { from, to in
                    var rules = model.s.raw["regexRules"]?.array ?? []
                    rules.move(fromOffsets: from, toOffset: to)
                    model.set("regexRules", .array(rules))
                }
                Button("新建规则") {
                    let row = RegexRules.blank(name: "规则 \(RegexRules.list(model.s).count + 1)")
                    model.update { $0.raw["regexRules"] = .array(($0.raw["regexRules"]?.array ?? []) + [.object(row)]) }
                    if model.problem == nil, let id = row["id"]?.string { opening = Target(id: id) }
                }
                Button("导入规则") { importing = true }
                if !RegexRules.list(model.s).isEmpty {
                    Button("导出全部规则") {
                        do { exported = try RegexRules.exportFile(model.s) } catch { model.problem = "未能导出：\(error.localizedDescription)" }
                    }
                }
                if let exported {
                    ShareLink(item: exported) { Label("存储或发送导出的规则", systemImage: "square.and.arrow.up") }
                }
                if let note { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) }
            } footer: {
                HelpNote("把消息里的字词换成别的写法。每条规则可以只改屏幕上的显示、只改发给角色的聊天记录，或两边都改。存着的原文不变，关闭规则后立即恢复原样。规则按列表顺序依次套用，长按拖动调整先后。导入读本应用（网页版或原生版）导出的规则文件，接在现有规则后面。不调用接口。", title: "正则替换")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("正则替换")
        .navigationDestination(item: $opening) { t in RegexEditView(ruleId: t.id) }
        .documentPicker(isPresented: $importing, types: [.json]) { urls in
            guard let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                var failure: Error?
                var n = 0
                model.update { do { n = try RegexRules.importData(&$0, data) } catch { failure = error } }
                if let failure { model.problem = failure.localizedDescription } else if model.problem == nil { note = "已导入 \(n) 条规则" }
            } catch { model.problem = "无法读取文件：\(error.localizedDescription)" }
        }
        .onAppear { model.reload() }
    }

    private func summaryIsError(_ r: RegexRules.Rule) -> Bool { !RegexRules.compile(r).1.isEmpty }

    private func summary(_ r: RegexRules.Rule) -> String {
        let err = RegexRules.compile(r).1
        if !err.isEmpty { return "正则有误：\(err)" }
        if r.find.isEmpty { return "尚未填写查找内容" }
        let mode = RegexRules.modes.first { $0.id == r.mode }?.label ?? "只改显示"
        let who = [r.who.contains("char") ? "角色的消息" : "", r.who.contains("user") ? "我的消息" : ""].filter { !$0.isEmpty }.joined(separator: "、")
        return [mode, who.isEmpty ? "未选" : who, r.charIds.isEmpty ? "全部角色" : "\(r.charIds.count) 个角色"].joined(separator: " · ")
    }

    private func patch(_ id: String, _ fields: [String: JSONValue]) {
        model.update {
            $0.raw["regexRules"] = .array(($0.raw["regexRules"]?.array ?? []).map { v in
                guard v["id"]?.string == id, case .object(var o) = v else { return v }
                o.merge(fields) { _, n in n }
                return .object(o)
            })
        }
    }
}

struct RegexEditView: View {
    let ruleId: String
    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var chars: [Character] = []
    @State private var probe = ""
    @State private var confirmDelete = false

    private var rule: RegexRules.Rule? { RegexRules.list(model.s).first { $0.id == ruleId } }

    var body: some View {
        Form {
            if let r = rule {
                Section {
                    TextField("名称", text: text("name"))
                    TextField("查找", text: text("find")).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("替换为", text: text("replace")).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("按正则表达式查找", isOn: flag("regex", false))
                    Toggle("区分大小写", isOn: flag("caseSensitive", true))
                } footer: {
                    let err = RegexRules.compile(r).1
                    Text(err.isEmpty ? (r.isRegex ? "替换里可以写 $1、$2 引用分组。" : "按原文查找，替换里的符号原样写出。") : "正则有误：\(err)")
                        .foregroundStyle(err.isEmpty ? Theme.secondaryText : Theme.danger)
                }
                Section("改哪里") {
                    Picker("改哪里", selection: text("mode")) {
                        ForEach(RegexRules.modes.indices, id: \.self) { i in Text(RegexRules.modes[i].label).tag(RegexRules.modes[i].id) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                Section("作用于") {
                    Toggle("角色的消息", isOn: member("who", "char", r.who))
                    Toggle("我的消息", isOn: member("who", "user", r.who))
                    Toggle("线上聊天", isOn: member("where", "online", r.whereList))
                    Toggle("线下正文", isOn: member("where", "offline", r.whereList))
                }
                Section {
                    ForEach(chars) { c in
                        Toggle(c.name, isOn: member("charIds", c.id, r.charIds))
                    }
                } header: {
                    Text("适用的角色")
                } footer: {
                    HelpNote("一个都不选表示全部角色。")
                }
                Section {
                    TextField("输入一段文字试一试", text: $probe, axis: .vertical)
                    if !probe.isEmpty {
                        Text(RegexRules.apply(r, probe)).font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                } header: {
                    Text("试一试")
                }
                Section { Button("删除这条规则", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText) }
                ProblemSection(text: model.problem)
            } else {
                Text("这条规则已删除。").foregroundStyle(Theme.secondaryText)
            }
        }
        .navigationTitle(rule?.name.isEmpty == false ? rule!.name : "规则")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除后无法恢复。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                model.update { $0.raw["regexRules"] = .array(($0.raw["regexRules"]?.array ?? []).filter { $0["id"]?.string != ruleId }) }
                dismiss()
            }
        }
        .onAppear { chars = ((try? Repo.characters()) ?? []).filter { !$0.row.bool("isNpc") && $0.row.string("parentId").isEmpty } }
    }

    private func patch(_ fields: [String: JSONValue]) {
        model.update {
            $0.raw["regexRules"] = .array(($0.raw["regexRules"]?.array ?? []).map { v in
                guard v["id"]?.string == ruleId, case .object(var o) = v else { return v }
                o.merge(fields) { _, n in n }
                return .object(o)
            })
        }
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { rule?.json[key]?.string ?? (key == "mode" ? "display" : "") }, set: { patch([key: .string($0)]) })
    }

    private func flag(_ key: String, _ def: Bool) -> Binding<Bool> {
        Binding(get: { rule?.json[key]?.bool ?? def }, set: { patch([key: .bool($0)]) })
    }

    private func member(_ key: String, _ value: String, _ current: [String]) -> Binding<Bool> {
        Binding(get: { current.contains(value) }, set: { on in
            var next = current.filter { $0 != value }
            if on { next.append(value) }
            patch([key: .array(next.map { .string($0) })])
        })
    }
}
