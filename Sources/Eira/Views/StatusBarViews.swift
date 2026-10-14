import SwiftUI

/// 会话里那一块状态栏（网页版 StatusBits.StatusBlock）：一行一栏，自定义的可以画成进度条
struct StatusBlockView: View {
    let message: Message
    let items: [String: StatusBar.Item]

    var body: some View {
        let vals = StatusBar.values(message)
        if !vals.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(vals.enumerated()), id: \.offset) { _, v in
                    HStack(spacing: Theme.sp2) {
                        Text(v.label).font(.system(size: 11)).foregroundStyle(Theme.text3)
                        if let it = items[v.id], it.show == "bar", let pct = StatusBar.percent(it, v.value) {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.surface3)
                                    Capsule().fill(Theme.text2).frame(width: g.size.width * CGFloat(pct) / 100)
                                }
                            }
                            .frame(height: 4)
                            Text(v.value).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.text2)
                        } else {
                            Text(v.value).font(.system(size: 12)).foregroundStyle(Theme.text2)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.sp3).padding(.vertical, Theme.sp2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.groupFill, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
            .padding(.horizontal, Theme.pad)
            .accessibilityElement(children: .combine)
        }
    }
}

/// 状态栏的设置（网页版 /status/:chatId）。只此一处（会话设置里「状态栏」一行进来）。原生版只有线上那一套
struct StatusBarSettingsView: View {
    let chatId: String
    @State private var cfg = StatusBar.Config()
    @State private var problem: String?
    @State private var editing: StatusBar.Item?

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Toggle("状态栏", isOn: Binding(get: { cfg.on }, set: { cfg.on = $0; save() }))
            } footer: {
                Text("开启后，角色每轮回复末尾一并写出状态栏的值，与回复同一次调用，不多调用接口。状态栏显示在这一轮的消息旁，不算作消息。")
            }
            if cfg.on {
                Section {
                    Toggle("带进下一轮", isOn: Binding(get: { cfg.carry }, set: { cfg.carry = $0; save() }))
                    Picker("显示位置", selection: Binding(get: { cfg.at }, set: { cfg.at = $0; save() })) {
                        ForEach(StatusBar.places, id: \.id) { Text($0.label).tag($0.id) }
                    }
                } footer: {
                    Text("带进下一轮开启时，上一轮的值作为当前状态交给角色；关闭时每轮给初始值。")
                }
                Section {
                    ForEach(cfg.items.filter(\.supported)) { it in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.label)
                                Text(it.custom ? (it.desc.isEmpty ? "自定义" : it.desc) : it.desc)
                                    .font(.caption).foregroundStyle(Theme.text3).lineLimit(2)
                            }
                            Spacer()
                            if it.custom {
                                Button("编辑") { editing = it }.font(.footnote).buttonStyle(.borderless)
                            }
                            Toggle("", isOn: Binding(get: { it.on }, set: { v in setItem(it.id) { $0.on = v } }))
                                .labelsHidden()
                        }
                        .swipeActions {
                            if it.custom {
                                Button("删除", role: .destructive) { cfg.items.removeAll { $0.id == it.id }; save() }
                            }
                        }
                    }
                    .onMove { from, to in
                        var shown = cfg.items.filter(\.supported)
                        shown.move(fromOffsets: from, toOffset: to)
                        cfg.items = shown + cfg.items.filter { !$0.supported }
                        save()
                    }
                    Button("添加栏目") {
                        editing = StatusBar.Item(id: StatusBar.newCustomId(), kind: "custom", on: true, label: "")
                    }
                } header: {
                    HStack { Text("栏目"); Spacer(); EditButton().font(.footnote) }
                } footer: {
                    Text("时间读取这段会话的时间设置，不由角色填写；其余栏目每轮由角色填写。自定义栏目可写说明、初始值与变化规则，规则原样交给角色。")
                }
            }
        }
        .navigationTitle("状态栏")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .sheet(item: $editing) { it in
            NavigationStack {
                CustomItemEditor(item: it) { saved in
                    if let i = cfg.items.firstIndex(where: { $0.id == saved.id }) { cfg.items[i] = saved } else { cfg.items.append(saved) }
                    save()
                    editing = nil
                }
            }
        }
    }

    private func setItem(_ id: String, _ change: (inout StatusBar.Item) -> Void) {
        guard let i = cfg.items.firstIndex(where: { $0.id == id }) else { return }
        change(&cfg.items[i])
        save()
    }

    private func load() {
        guard let c = try? Repo.chat(chatId) else { return }
        cfg = StatusBar.config(c)
    }

    private func save() {
        do { try StatusBar.save(chatId, cfg); problem = nil }
        catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}

/// 自定义栏目：名称、说明、初始值、变化规则、显示成文字或进度条
private struct CustomItemEditor: View {
    @State var item: StatusBar.Item
    var onSave: (StatusBar.Item) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("名称（例如：好感度）", text: $item.label)
                TextField("说明", text: $item.desc, axis: .vertical).lineLimit(1...4)
                TextField("初始值", text: $item.initial)
                TextField("变化规则（原样交给角色）", text: $item.rule, axis: .vertical).lineLimit(1...4)
            }
            Section {
                Picker("显示成", selection: $item.show) {
                    Text("文字").tag("text")
                    Text("进度条").tag("bar")
                }
                .pickerStyle(.segmented)
                if item.show == "bar" {
                    HStack {
                        Text("最小值")
                        TextField("0", value: $item.min, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("最大值")
                        TextField("100", value: $item.max, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }
            } footer: {
                Text(item.show == "bar" ? "按最小值与最大值换算进度条的长度；角色写的不是数字时只显示文字。" : "")
            }
        }
        .navigationTitle(item.label.isEmpty ? "添加栏目" : item.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    item.label = String(item.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
                    if item.max == item.min { item.max = item.min + 100 }
                    onSave(item)
                }
                .disabled(item.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
