import SwiftUI

/// 会话的美化（网页版 chat/pages/SkinPage.js）。只此一处：会话设置里「美化」一行进来。
/// 挂哪一份、取下、新建、头像形状与显示头像在这一页；尺寸与颜色在下一页，改的是这一份本身，挂着它的每段会话都跟着变。
struct SkinPageView: View {
    let chatId: String
    @State private var tick = 0
    @State private var problem: String?
    @State private var naming = false
    @State private var newName = ""
    @State private var deleting: Row?

    private var chat: Chat? { _ = tick; return try? Repo.chat(chatId) }
    private var cur: Row? { Skins.get(chat?.row.string("skinId") ?? "") }

    var body: some View {
        let list = { _ = tick; return Skins.all() }()
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if AppSettings.load().raw["skinOff"]?.bool == true {
                Section {
                    Button("开启美化") {
                        run {
                            var st = try AppSettings.loadForWrite()
                            st.raw["skinOff"] = .bool(false)
                            try st.save()
                            NotificationCenter.default.post(name: .eiraSkinChanged, object: nil)
                        }
                    }
                } footer: {
                    Text("美化总开关已在网页版的「外观」中关闭，所有会话均不显示美化。开启后恢复显示。")
                }
            }
            if let cur {
                Section {
                    NavigationLink {
                        SkinEditView(id: cur.id)
                    } label: {
                        HStack {
                            Text(cur.string("name").isEmpty ? "未命名" : cur.string("name"))
                            Spacer()
                            Text("尺寸与颜色").foregroundStyle(Theme.text3)
                        }
                    }
                    Button { run { try Skins.attach(chatId, "") } } label: { Text("从这段会话取下").foregroundStyle(Theme.text) }
                } header: { Text("这段会话") } footer: {
                    Text("取下后美化本身保留，其他会话不受影响。")
                }
                Section {
                    Picker("头像形状", selection: Binding(get: { cur.string("shape") }, set: { v in
                        run { try Skins.update(cur.id) { $0["shape"] = .string(v) } }
                    })) {
                        ForEach(Skins.shapes, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    Picker("显示头像", selection: Binding(get: { Skins.look(cur).show }, set: { v in
                        run { try Skins.setGen(cur.id, "avatar", "show", .string(v)) }
                    })) {
                        ForEach(Skins.faceShow, id: \.id) { Text($0.label).tag($0.id) }
                    }
                } footer: {
                    Text("不显示的那一边连位置一起收起，气泡贴着屏幕边缘。隐藏角色头像后，点头像查看心声随之不可用。")
                }
                let skipped = Skins.skipped(cur)
                if !skipped.isEmpty {
                    Section {
                        Text("这份美化中的\(skipped.joined(separator: "、"))在原生版中不显示，原样保留，导出后网页版照常使用。")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
            }
            Section {
                if list.isEmpty {
                    Text("尚无任何美化").foregroundStyle(Theme.text3)
                }
                ForEach(list) { r in
                    Button { run { try Skins.attach(chatId, r.id) } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.string("name").isEmpty ? "未命名" : r.string("name")).foregroundStyle(Theme.text)
                                Text("已用于 \(Skins.usedBy(r.id)) 段会话").font(.caption).foregroundStyle(Theme.text3)
                            }
                            Spacer()
                            if cur?.id == r.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { deleting = r }
                    }
                }
                Button { newName = ""; naming = true } label: { Label("新建一份", systemImage: "plus") }
            } header: { Text(cur == nil ? "挂一份现成的" : "换一份") } footer: {
                Text("美化按会话生效：挂上之后只在这段会话中起作用。网页版导出的备份中的美化随备份导入；自定义 CSS 与头像框在原生版中不显示。")
            }
        }
        .navigationTitle("美化")
        .navigationBarTitleDisplayMode(.inline)
        .alert("新建一份美化", isPresented: $naming) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("新建") {
                run {
                    let r = try Skins.create(name: newName)
                    try Skins.attach(chatId, r.id)
                }
            }
        }
        .confirmationDialog("删除这份美化", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { r in
            Button("删除", role: .destructive) { run { try Skins.remove(r.id) } }
        } message: { r in
            Text("「\(r.string("name"))」挂在 \(Skins.usedBy(r.id)) 段会话上，删除后这些会话一并取下。此操作不能撤销。")
        }
    }

    private func run(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "无法保存美化：\(error.localizedDescription)" }
        tick += 1
    }
}

/// 一份美化的尺寸与颜色（网页版「美化」app 里令牌与生成器「气泡」一组的子集）。改的是这一份本身
struct SkinEditView: View {
    let id: String
    @State private var tick = 0
    @State private var problem: String?
    @State private var name = ""

    private var row: Row? { _ = tick; return Skins.get(id) }

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let row {
                Section {
                    TextField("名称", text: $name)
                        .onSubmit { run { try Skins.update(id) { $0["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines)) } } }
                } header: { Text("名称") } footer: {
                    Text("改动对挂着这一份的每段会话生效。")
                }
                Section {
                    ForEach(Skins.tokens, id: \.id) { t in tokenRow(row, t) }
                } header: { Text("尺寸") } footer: {
                    Text("未设置的一项沿用默认值。")
                }
                bubbleSection(row)
                avatarSection(row)
            } else {
                Text("这份美化已不存在").foregroundStyle(Theme.text3)
            }
        }
        .navigationTitle("尺寸与颜色")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = row?.string("name") ?? "" }
        .onDisappear {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let row, n != row.string("name") { run { try Skins.update(id) { $0["name"] = .string(n) } } }
        }
    }

    private func tokenRow(_ r: Row, _ t: Skins.Token) -> some View {
        let v = Skins.token(r, t.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(t.label)
                Spacer()
                Text(v.map { "\(Int($0)) 像素" } ?? "默认").foregroundStyle(Theme.text3).monospacedDigit()
                if v != nil {
                    Button("恢复默认") { run { try Skins.setToken(id, t.id, nil) } }.font(.footnote).buttonStyle(.borderless)
                }
            }
            Slider(value: Binding(get: { v ?? t.def }, set: { n in run { try Skins.setToken(id, t.id, n) } }),
                   in: t.min...t.max, step: 1)
        }
    }

    @ViewBuilder private func bubbleSection(_ r: Row) -> some View {
        Section {
            Picker("改哪一边", selection: Binding(get: { Skins.genValue(r, "bubble", "side")?.string ?? "all" }, set: { v in
                run { try Skins.setGen(id, "bubble", "side", .string(v)) }
            })) {
                ForEach(Skins.sides, id: \.id) { Text($0.label).tag($0.id) }
            }
            colorRow("底色", r, "bg")
            colorRow("文字颜色", r, "fg")
        } header: { Text("气泡颜色") } footer: {
            Text("选定一边之后，底色与文字颜色只作用于这一边。未设置时沿用主题。")
        }
    }

    private func colorRow(_ label: String, _ r: Row, _ key: String) -> some View {
        let hex = Skins.genValue(r, "bubble", key)?.string ?? ""
        return HStack {
            ColorPicker(label, selection: Binding(get: { Skins.color(hex) ?? .gray }, set: { c in
                run { try Skins.setGen(id, "bubble", key, .string(Self.hex(c))) }
            }), supportsOpacity: false)
            if !hex.isEmpty {
                Button("清除") { run { try Skins.setGen(id, "bubble", key, nil) } }.font(.footnote).buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private func avatarSection(_ r: Row) -> some View {
        let size = Skins.genValue(r, "avatar", "size").flatMap { $0.number ?? $0.string.flatMap { Double($0) } }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("头像大小")
                    Spacer()
                    Text(size.map { "\(Int($0)) 像素" } ?? "默认").foregroundStyle(Theme.text3).monospacedDigit()
                    if size != nil {
                        Button("恢复默认") { run { try Skins.setGen(id, "avatar", "size", nil) } }.font(.footnote).buttonStyle(.borderless)
                    }
                }
                Slider(value: Binding(get: { size ?? Double(Theme.avatarSize) }, set: { n in
                    run { try Skins.setGen(id, "avatar", "size", .number(n.rounded())) }
                }), in: 16...120, step: 1)
            }
        } header: { Text("头像") }
    }

    static func hex(_ c: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        func h(_ v: CGFloat) -> String { String(format: "%02x", Int((max(0, min(1, v)) * 255).rounded())) }
        return "#" + h(r) + h(g) + h(b)
    }

    private func run(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "无法保存美化：\(error.localizedDescription)" }
        tick += 1
    }
}
