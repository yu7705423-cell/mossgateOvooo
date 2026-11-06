import SwiftUI

/// 每一块各自折起、展开（网页版 StatusBits 的 own，ARCHITECTURE 4.857）。设置里的「默认」是还没点过的那几块的样子，
/// 点过的记在这里（按会话、线上、这一块），离开会话页再回来照旧；关掉应用后回到默认。只在内存里，不落库
@MainActor
final class StatusFolds: ObservableObject {
    static let shared = StatusFolds()
    @Published private(set) var own: [String: Bool] = [:]

    nonisolated static func key(chatId: String, msgId: String, top: Bool) -> String { "\(chatId):\(StatusBar.mode):\(top ? "b" : "a")-\(msgId)" }

    func folded(_ key: String, _ cfg: StatusBar.Config) -> Bool { cfg.fold && (own[key] ?? cfg.folded) }

    func toggle(_ key: String, _ cfg: StatusBar.Config) {
        let next = !folded(key, cfg)
        if next == cfg.folded { own[key] = nil } else { own[key] = next }
    }
}

/// 会话里那一块状态栏（网页版 StatusBits.StatusBlock）：一行一栏，自定义的可以画成进度条。
/// 开了「可以折叠」时右上角一个箭头，点整块即可折起展开；折起时只剩标题那一行，展开后标题留在最上面加粗（4.802、4.857）。
/// 设了最大高度时超出的在框里滚动，不带着聊天一起滚
struct StatusBlockView: View {
    let message: Message
    let items: [String: StatusBar.Item]
    var cfg = StatusBar.Config()
    var maxHeight: Double?
    var foldKey = ""
    @ObservedObject private var folds = StatusFolds.shared
    @State private var bodyHeight: CGFloat = 0

    var body: some View {
        let vals = StatusBar.values(message)
        if !vals.isEmpty {
            let folded = folds.folded(foldKey, cfg)
            VStack(alignment: .leading, spacing: 4) {
                if cfg.fold {
                    HStack(alignment: .top, spacing: Theme.sp2) {
                        let brief = StatusBar.briefOf(cfg, vals)
                        Text(brief.isEmpty ? "状态栏" : brief)
                            .font(.system(size: 12, weight: folded ? .regular : .semibold))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(folded ? 1 : nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                            .rotationEffect(.degrees(folded ? 0 : 180))
                    }
                }
                if !folded {
                    if let mh = maxHeight {
                        ScrollView {
                            rows(vals)
                                .background(GeometryReader { g in
                                    Color.clear
                                        .onAppear { bodyHeight = g.size.height }
                                        .onChange(of: g.size.height) { _, h in bodyHeight = h }
                                })
                        }
                        .frame(height: min(max(bodyHeight, 1), CGFloat(mh)))
                        .scrollBounceBehavior(.basedOnSize)
                    } else {
                        rows(vals)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 美化里写了 .ph-status 就照它画，没写照原样
            .modifier(PhSurface(hooks: ["status"], fallback: PhFallback(fill: Theme.groupFill, radius: Theme.rMd,
                                                                     padH: Theme.sp3, padV: Theme.sp2, alignment: .leading)))
            .contentShape(Rectangle())
            .onTapGesture { if cfg.fold { withAnimation(.easeOut(duration: 0.15)) { folds.toggle(foldKey, cfg) } } }
            .padding(.horizontal, Theme.pad)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(cfg.fold ? .isButton : [])
            .accessibilityHint(cfg.fold ? (folded ? "展开状态栏" : "折叠状态栏") : "")
        }
    }

    private func rows(_ vals: [(id: String, label: String, value: String)]) -> some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 状态栏的设置（网页版 /status/:chatId）。只此一处（会话设置里「状态栏」一行进来）。原生版只有线上那一套
struct StatusBarSettingsView: View {
    let chatId: String
    @State private var cfg = StatusBar.Config()
    @State private var problem: String?
    @State private var editing: StatusBar.Item?
    @State private var mhText = ""

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Toggle("状态栏", isOn: Binding(get: { cfg.on }, set: { cfg.on = $0; save() }))
            } footer: {
                HelpNote("开启后，角色每轮回复末尾一并写出状态栏的值，与回复同一次调用，不多调用接口。状态栏显示在这一轮的消息旁，不算作消息。")
            }
            if cfg.on {
                Section {
                    Toggle("带进下一轮", isOn: Binding(get: { cfg.carry }, set: { cfg.carry = $0; save() }))
                    Picker("显示位置", selection: Binding(get: { cfg.at }, set: { cfg.at = $0; save() })) {
                        ForEach(StatusBar.places, id: \.id) { Text($0.label).tag($0.id) }
                    }
                } footer: {
                    HelpNote("带进下一轮开启时，上一轮的值作为当前状态交给角色；关闭时每轮给初始值。")
                }
                Section {
                    Toggle("可以折叠", isOn: Binding(get: { cfg.fold }, set: { cfg.fold = $0; cfg.folded = true; save() }))
                    if cfg.fold {
                        Picker("默认", selection: Binding(get: { cfg.folded }, set: { cfg.folded = $0; save() })) {
                            Text("折起").tag(true)
                            Text("展开").tag(false)
                        }
                        TextField("标题内容，例如：{{心情}} · {{所在地}}", text: Binding(get: { cfg.brief }, set: { cfg.brief = $0; save() }))
                        let names = cfg.items.filter { $0.on && $0.supported }.map { "{{\($0.label)}}" }.joined(separator: " ")
                        Text("可用：\(names.isEmpty ? "（尚未开启栏目）" : names)").font(.caption).foregroundStyle(Theme.text3)
                    }
                } header: { Text("折叠") } footer: {
                    HelpNote("开启后，点状态栏的任意位置即可折起、展开，每一块各自折起、展开。折起时显示标题内容，展开后这一行留在最上面作为标题。标题内容用 {{栏目名称}} 引用那一栏的值，不填则把各栏的值接成一行。尚未点过的状态栏按「默认」显示；点过的保持各自的样子，直到关闭应用。", title: "状态栏：折叠")
                }
                Section {
                    HStack {
                        Text("最大高度")
                        TextField("不限", text: $mhText)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .onSubmit(saveMH)
                        Text("pt").foregroundStyle(Theme.text3)
                    }
                    .onChange(of: mhText) { _, _ in saveMH() }
                } header: { Text("样式") } footer: {
                    HelpNote("最大高度在 40 到 1200 之间。超出的部分在框内滚动。不填则不限高度。只对这段会话生效。", title: "状态栏：最大高度")
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
                    HelpNote("时间读取这段会话的时间设置，不由角色填写；其余栏目每轮由角色填写。自定义栏目可写说明、初始值与变化规则，规则原样交给角色。")
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
        mhText = StatusBar.maxHeight(c).map { String(Int($0)) } ?? ""
    }

    /// 填的是数字才存（钳在 40 到 1200）；清空即不限。输入到一半（比如 1）时也照存，存的是钳过的值，框里照旧是输入的字
    private func saveMH() {
        let t = mhText.trimmingCharacters(in: .whitespaces)
        let v = Double(t)
        guard t.isEmpty || v != nil else { return }
        do { try StatusBar.setMaxHeight(chatId, t.isEmpty ? nil : v); problem = nil }
        catch { problem = "未能保存：\(error.localizedDescription)" }
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
                HelpNote(item.show == "bar" ? "按最小值与最大值换算进度条的长度；角色写的不是数字时只显示文字。" : "")
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
