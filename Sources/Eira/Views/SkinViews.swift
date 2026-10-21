import SwiftUI
import UniformTypeIdentifiers

/// 会话的美化（网页版 chat/pages/SkinPage.js）。只此一处：会话设置里「美化」一行进来。
/// 挂哪一份、取下、新建、头像形状与显示头像在这一页；尺寸与颜色在下一页，改的是这一份本身，挂着它的每段会话都跟着变。
struct SkinPageView: View {
    let chatId: String
    @State private var tick = 0
    @State private var problem: String?
    @State private var naming = false
    @State private var newName = ""
    @State private var deleting: Row?
    /// 从文件读出来、等确认的美化包
    @State private var importing: Skins.Pack?
    @State private var picking = false

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
                    HelpNote("取下后美化本身保留，其他会话不受影响。")
                }
                Section {
                    Picker("头像形状", selection: Binding(get: { cur.string("shape") }, set: { v in
                        run { try Skins.update(cur.id) { $0["shape"] = .string(v); Skins.markLate(&$0) } }
                    })) {
                        ForEach(Skins.shapes, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    Picker("显示头像", selection: Binding(get: { Skins.look(cur).show }, set: { v in
                        run { try Skins.setGen(cur.id, "avatar", "show", .string(v)) }
                    })) {
                        ForEach(Skins.faceShow, id: \.id) { Text($0.label).tag($0.id) }
                    }
                } footer: {
                    HelpNote("不显示的那一边连位置一起收起，气泡贴着屏幕边缘。隐藏角色头像后，点头像查看心声随之不可用。")
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
                HelpNote("美化按会话生效：挂上之后只在这段会话中起作用。网页版导出的备份中的美化随备份导入。自定义 CSS 中读得懂的部分按原生样式显示，读不懂的部分与头像框在原生版中不显示，逐条情况在「尺寸与颜色 - 查看还原情况」中列出。")
            }
            Section {
                Button { picking = true } label: { Label("从文件导入", systemImage: "doc") }
                NavigationLink { SkinImportView(chatId: chatId) } label: { Label("粘贴导入", systemImage: "doc.on.clipboard") }
            } header: { Text("导入美化包") } footer: {
                HelpNote("读取网页版导出的美化包：JSON、TXT、DOCX 文件，或复制的一段文字（连同 BEGIN 与 END 两行标记）。导入前列出自定义 CSS 的还原情况；导入后新建一份并挂在这段会话上，不覆盖现有的美化。", title: "导入美化包")
            }
            ShowSection()
        }
        .navigationTitle("美化")
        .navigationBarTitleDisplayMode(.inline)
        .documentPicker(isPresented: $picking, types: [UTType.json, UTType.plainText, UTType(filenameExtension: "docx")].compactMap { $0 }) { urls in
            guard let url = urls.first else { return }
            do { importing = try Skins.parsePack(DocText.read(url)); problem = nil }
            catch { problem = "无法导入：\(error.localizedDescription)" }
        }
        .navigationDestination(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } })) {
            if let importing { SkinImportView(chatId: chatId, pack: importing) { tick += 1 } }
        }
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
                    HelpNote("改动对挂着这一份的每段会话生效。")
                }
                Section {
                    ForEach(Skins.tokens, id: \.id) { t in tokenRow(row, t) }
                } header: { Text("尺寸") } footer: {
                    HelpNote("未设置的一项沿用默认值。")
                }
                bubbleSection(row)
                avatarSection(row)
                if !row.string("css").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        NavigationLink { SkinCssReportView(id: id) } label: {
                            HStack {
                                Text("查看还原情况")
                                Spacer()
                                if let rep = Skins.compiled(row)?.report {
                                    Text("已还原 \(rep.used) 条，未还原 \(rep.skipped) 条").foregroundStyle(Theme.text3)
                                }
                            }
                        }
                    } header: { Text("自定义 CSS") }
                }
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
            HelpNote("选定一边之后，底色与文字颜色只作用于这一边。未设置时沿用主题。")
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

/// 导入一个美化包之前的确认页（网页版 SkinPage 的导入确认，加上自定义 CSS 的还原情况）。
/// 没带包进来时先粘贴一段文字再读。确认后新建一份（重名加后缀，不覆盖）并挂在这段会话上
struct SkinImportView: View {
    let chatId: String
    var onDone: (() -> Void)?
    @State private var pack: Skins.Pack?
    @State private var text = ""
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    init(chatId: String, pack: Skins.Pack? = nil, onDone: (() -> Void)? = nil) {
        self.chatId = chatId
        self.onDone = onDone
        _pack = State(initialValue: pack)
    }

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let pack {
                Section {
                    LabeledContent("名称", value: pack.name)
                    if !pack.author.isEmpty { LabeledContent("作者", value: pack.author) }
                    LabeledContent("作用范围", value: pack.scope.contains("shell") ? "整个应用" : "单段会话")
                }
                let remote = Skins.remoteRefs(pack.css)
                if remote > 0 {
                    Section {
                        Text("该美化引用了 \(remote) 处网络地址。原生版目前不显示美化中的图片，不向这些地址发起请求。")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
                if pack.css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section { Text("这份美化没有自定义 CSS。").foregroundStyle(Theme.text3) }
                } else {
                    CssReportSections(report: Skins.compiled(css: pack.css).report)
                }
                Section {
                    Button("导入") { save(pack) }
                } footer: {
                    Text("导入后将新建一份，不会覆盖现有的美化。")
                }
            } else {
                Section {
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 220)
                } header: { Text("美化包内容") } footer: {
                    HelpNote("粘贴网页版「复制为文字」得到的一段，或 JSON 原文。标记之外的说明文字不影响读取。", title: "粘贴导入")
                }
                Section {
                    Button("读取") {
                        do { pack = try Skins.parsePack(text); problem = nil }
                        catch { problem = error.localizedDescription }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationTitle(pack == nil ? "粘贴导入" : "导入美化包")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save(_ p: Skins.Pack) {
        do {
            let r = try Skins.install(p)
            try Skins.attach(chatId, r.id)
            problem = nil
            onDone?()
            dismiss()
        } catch {
            problem = "导入失败：\(error.localizedDescription)"
        }
    }
}

/// 一份美化的自定义 CSS 在原生版里的还原情况（美化详情页「查看还原情况」）
struct SkinCssReportView: View {
    let id: String

    var body: some View {
        Form {
            if let row = Skins.get(id) {
                if let c = Skins.compiled(row) {
                    CssReportSections(report: c.report)
                } else {
                    Text("这份美化没有自定义 CSS。").foregroundStyle(Theme.text3)
                }
            } else {
                Text("这份美化已不存在").foregroundStyle(Theme.text3)
            }
        }
        .navigationTitle("还原情况")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 还原情况：三个数，再按类别逐条列出选择器、属性与原因
struct CssReportSections: View {
    let report: CssReport

    var body: some View {
        Section {
            LabeledContent("已还原", value: "\(report.used) 条")
            LabeledContent("近似还原", value: "\(report.approx) 条")
            LabeledContent("未还原", value: "\(report.skipped) 条")
        } header: { Text("自定义 CSS 的还原情况") } footer: {
            HelpNote("原生版不运行 CSS。导入与打开会话时，逐条读取写在契约类名（ph- 开头）上的样式：已还原的按原样显示；近似还原的以相近的效果显示，例如阴影的扩散范围、重复渐变、百分比圆角；未还原的不显示，例如图片、动画以及原生版中没有对应元素的类名。CSS 原文完整保留，导出后网页版照常使用。", title: "CSS 的还原情况")
        }
        ForEach([CssReport.Item.Kind.skipped, .approx, .used], id: \.self) { kind in
            let items = report.items.filter { $0.kind == kind }
            if !items.isEmpty {
                Section {
                    DisclosureGroup("\(Self.label(kind)) \(items.count) 条") {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.selector).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text)
                                if !it.property.isEmpty {
                                    Text(it.property).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text2)
                                }
                                if !it.reason.isEmpty {
                                    Text(it.reason).font(.caption).foregroundStyle(Theme.text3)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    static func label(_ k: CssReport.Item.Kind) -> String {
        switch k {
        case .used: return "已还原"
        case .approx: return "近似还原"
        case .skipped: return "未还原"
        }
    }
}
