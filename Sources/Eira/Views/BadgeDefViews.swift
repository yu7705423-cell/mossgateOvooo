import SwiftUI

/// 自定义互动标识的列表（网页版 BadgeDefs.js）：按当前身份分，点进去编辑
struct BadgeDefsView: View {
    @State private var defs: [BadgeDefs.Def] = []
    @State private var editing: Target?
    @State private var problem: String?

    struct Target: Identifiable, Hashable { let id: String }

    var body: some View {
        List {
            Section {
                ForEach(defs) { d in
                    Button { editing = Target(id: d.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name.isEmpty ? "未命名" : d.name).foregroundStyle(Theme.text)
                            Text([BadgeDefs.ruleText(d), d.charIds.isEmpty ? "未选择角色" : "\(d.charIds.count) 个角色"].joined(separator: " · "))
                                .font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx {
                        do { try BadgeDefs.remove(defs[i].id) } catch { problem = "删除失败：\(error.localizedDescription)" }
                    }
                    reload()
                }
                if defs.isEmpty { Text("尚无自定义标识。").foregroundStyle(Theme.text2) }
                HelpNote("自定义标识只在一对一的会话里生效，需勾选对哪些角色生效。按条件的标识按聊天记录在本机计算，不调用接口；手动颁发的在「互动标识」中点「颁发」。删除一个标识时，各段会话里已经得到的那一枚一并收回。", title: "自定义标识")
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("自定义标识")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = Target(id: "") } label: { NavIcon("plus") }.accessibilityLabel("新建标识")
            }
        }
        .navigationDestination(item: $editing) { t in BadgeDefEditView(defId: t.id.isEmpty ? nil : t.id) }
        .onAppear(perform: reload)
    }

    private func reload() {
        let me = ((try? Repo.activePersona()) ?? nil)?.id ?? ""
        defs = BadgeDefs.list(personaId: me)
    }
}

/// 编辑一个自定义标识
struct BadgeDefEditView: View {
    let defId: String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var desc = ""
    @State private var hint = ""
    @State private var hidden = false
    @State private var how = "rule"
    @State private var metric = "messages"
    @State private var who = "both"
    @State private var word = ""
    @State private var kind = "image"
    @State private var value = 100
    @State private var cond = ""
    @State private var charIds: Set<String> = []
    @State private var chars: [Character] = []
    @State private var problem: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name)
                TextField("说明", text: $desc, axis: .vertical)
                Toggle("隐藏", isOn: $hidden)
                if hidden { TextField("提示（未得到时显示）", text: $hint) }
            }
            Section {
                Picker("达成方式", selection: $how) {
                    ForEach(BadgeDefs.hows.filter { $0.id != "judge" || how == "judge" }, id: \.id) { Text($0.label).tag($0.id) }
                }
                if how == "rule" {
                    Picker("条件", selection: $metric) {
                        ForEach(BadgeDefs.metrics, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    let m = BadgeDefs.metric(metric)
                    if m.who {
                        Picker("谁", selection: $who) { ForEach(BadgeDefs.whos, id: \.id) { Text($0.label).tag($0.id) } }
                    }
                    if m.word { TextField("要数的词", text: $word) }
                    if m.kind {
                        Picker("消息类型", selection: $kind) { ForEach(BadgeDefs.kinds, id: \.id) { Text($0.label).tag($0.id) } }
                    }
                    Stepper("达到 \(value) \(m.unit)", value: $value, in: 1...1_000_000)
                    TextField("数值", value: $value, format: .number).keyboardType(.numberPad)
                } else if how == "judge" {
                    TextField("达成的条件", text: $cond, axis: .vertical)
                    Text("原生版暂不自动判断这一类，可在「互动标识」中手动颁发。").font(.footnote).foregroundStyle(Theme.text2)
                }
            } footer: {
                HelpNote("按条件：按聊天记录在本机计算，达到数值时自动得到，不调用接口。手动颁发：在会话的「互动标识」中点「颁发」。", title: "达成方式")
            }
            Section("对哪些角色生效") {
                ForEach(chars, id: \.id) { c in
                    Toggle(c.displayName, isOn: Binding(get: { charIds.contains(c.id) }, set: { if $0 { charIds.insert(c.id) } else { charIds.remove(c.id) } }))
                }
                if chars.isEmpty { Text("尚无角色。").foregroundStyle(Theme.text2) }
            }
            ProblemSection(text: problem)
        }
        .navigationTitle(defId == nil ? "新建标识" : "编辑标识")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        chars = ((try? Repo.characters()) ?? []).filter { !$0.archived }
        guard let defId, let d = BadgeDefs.get(defId) else { return }
        name = d.name; desc = d.desc; hint = d.hint; hidden = d.hidden; how = d.how
        metric = d.metricId; who = d.who; word = d.word; kind = d.kind; value = d.value; cond = d.cond
        charIds = Set(d.charIds)
    }

    private func save() {
        let me = ((try? Repo.activePersona()) ?? nil)?.id ?? ""
        let f: [String: JSONValue] = [
            "name": .string(name), "desc": .string(desc), "hint": .string(hint), "hidden": .bool(hidden), "how": .string(how),
            "rule": .object(["metric": .string(metric), "who": .string(who), "word": .string(word), "kind": .string(kind), "value": .number(Double(value))]),
            "cond": .string(cond), "charIds": .array(charIds.sorted().map { .string($0) }),
        ]
        do {
            try BadgeDefs.save(id: defId, f, personaId: me)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}
