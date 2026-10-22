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
                NavigationLink { SkinImportView(chatId: chatId, mode: .css) } label: { Label("粘贴 CSS", systemImage: "chevron.left.forwardslash.chevron.right") }
            } header: { Text("导入美化包") } footer: {
                HelpNote("读取网页版导出的美化包：JSON、TXT、DOCX 文件，或复制的一段文字（连同 BEGIN 与 END 两行标记）。也可以直接粘贴一段 CSS，作为一份只含自定义 CSS 的美化。导入前列出自定义 CSS 的还原情况；导入后新建一份并挂在这段会话上，不覆盖现有的美化。", title: "导入美化包")
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
/// 没带包进来时先粘贴一段文字再读：美化包（标记包着的一段或 JSON），或直接一段 CSS（在内存里包成只有 CSS 的一份）。
/// 确认后新建一份（重名加后缀，不覆盖）并挂在这段会话上，随后在后台把格子表达不了的部分画成图（含下载 CSS 里引用的图片）
struct SkinImportView: View {
    enum Mode: String, CaseIterable { case pack, css }

    let chatId: String
    var onDone: (() -> Void)?
    @State private var pack: Skins.Pack?
    @State private var mode: Mode
    @State private var text = ""
    @State private var cssName = ""
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    init(chatId: String, pack: Skins.Pack? = nil, mode: Mode = .pack, onDone: (() -> Void)? = nil) {
        self.chatId = chatId
        self.onDone = onDone
        _pack = State(initialValue: pack)
        _mode = State(initialValue: mode)
    }

    /// 粘贴的一段 CSS 包成一份美化：名称不填时为「自定义 CSS」，作用于单段会话
    static func cssPack(name: String, css: String) -> Skins.Pack {
        var p = Skins.Pack()
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.name = n.isEmpty ? "自定义 CSS" : String(n.prefix(80))
        p.scope = ["chat"]
        p.css = css
        return p
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
                        Text("导入时下载 \(remote) 张网络图片存到本机，之后不再联网。")
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
                    Picker("内容", selection: $mode) {
                        Text("美化包").tag(Mode.pack)
                        Text("粘贴 CSS").tag(Mode.css)
                    }
                    .pickerStyle(.segmented)
                }
                if mode == .css {
                    Section {
                        TextField("自定义 CSS", text: $cssName)
                    } header: { Text("名称") }
                }
                Section {
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 220)
                } header: { Text(mode == .css ? "CSS" : "美化包内容") } footer: {
                    if mode == .css {
                        HelpNote("粘贴按网页版美化契约写的 CSS（ph- 开头的类名与 --ph- 开头的变量）。读取后新建一份只含这段 CSS 的美化，作用于单段会话；名称不填时为「自定义 CSS」。", title: "粘贴 CSS")
                    } else {
                        HelpNote("粘贴网页版「复制为文字」得到的一段，或 JSON 原文。标记之外的说明文字不影响读取。", title: "粘贴导入")
                    }
                }
                Section {
                    Button("读取") {
                        if mode == .css {
                            pack = Self.cssPack(name: cssName, css: text); problem = nil
                        } else {
                            do { pack = try Skins.parsePack(text); problem = nil }
                            catch { problem = error.localizedDescription }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationTitle(pack == nil ? (mode == .css ? "粘贴 CSS" : "粘贴导入") : "导入美化包")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save(_ p: Skins.Pack) {
        do {
            let r = try Skins.install(p)
            try Skins.attach(chatId, r.id)
            problem = nil
            // 格子表达不了的部分由 Skins.install 交给画图的一边在后台画（顺带下载 CSS 里引用的网络图片），这里不再请
            onDone?()
            dismiss()
        } catch {
            problem = "导入失败：\(error.localizedDescription)"
        }
    }
}

/// 一份美化的自定义 CSS 在原生版里的还原情况（美化详情页「查看还原情况」）：
/// 读成格子的逐条情况，以及格子表达不了、画成图的那几块（画了几张、哪几块没画成与原因、重新绘制）
struct SkinCssReportView: View {
    let id: String
    @State private var tick = 0
    @State private var drawing = false
    @State private var problem: String?

    private var row: Row? { _ = tick; return Skins.get(id) }

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let row {
                if let c = Skins.compiled(row) {
                    Section {
                        NavigationLink { SkinCompareView(id: id) } label: { Text("对照") }
                    } footer: {
                        HelpNote("同一页示例会话在网页版与原生版中的效果，上下排列或叠加显示，可切换浅色与深色，便于比对还原的差异。", title: "对照")
                    }
                    rasterSection(row)
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
        .onReceive(NotificationCenter.default.publisher(for: .eiraSkinChanged)) { _ in tick += 1 }
    }

    @ViewBuilder private func rasterSection(_ row: Row) -> some View {
        let set = Skins.raster(row)
        Section {
            if drawing {
                HStack {
                    Text("正在绘制")
                    Spacer()
                    ProgressView()
                }
            } else if let set {
                LabeledContent("已绘制", value: "\(set.images.count) 张")
                if !set.remote.isEmpty {
                    LabeledContent("已下载的网络图片", value: "\(set.remote.count) 张")
                }
                LabeledContent("未能绘制", value: "\(set.failures.count) 处")
            } else {
                Text("尚未绘制").foregroundStyle(Theme.text3)
            }
            Button("重新绘制") { redraw() }
                .disabled(drawing)
        } header: { Text("绘制成图片的部分") } footer: {
            HelpNote("原生元素表达不了的纯视觉部分，例如图片背景、伪元素装饰、替换的图标，导入或打开会话时按 CSS 原样绘制成图片存到本机，之后只读图片；写了深色规则的部分另绘制一份深色的，按结构写的部分（同一轮的第一个或最后一个气泡、连发、奇偶行）另绘制一份。CSS 引用的网络图片在导入时下载一次，打开会话时不联网；「重新绘制」时补下载尚未下载的图片。CSS 改动后自动重新绘制；「重新绘制」按当前的 CSS 重新绘制全部图片。", title: "绘制成图片的部分")
        }
        if let set, !set.failures.isEmpty {
            Section {
                DisclosureGroup("未能绘制 \(set.failures.count) 处") {
                    ForEach(set.failures.keys.sorted(), id: \.self) { k in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text)
                            Text(set.failures[k] ?? "").font(.caption).foregroundStyle(Theme.text3)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    /// 重新绘制：先把这一份记着的 CSS 哈希清掉（画图的一边据此认定已过期），再请它画。
    /// 存着的图不删（原生版不删图，规约第 20 条），画好之后换成新的
    private func redraw() {
        do {
            try Skins.update(id) { r in
                if var o = r["nativeRaster"]?.object {
                    o["cssHash"] = .string("")
                    r["nativeRaster"] = .object(o)
                } else {
                    r["nativeRaster"] = nil
                }
            }
            problem = nil
        } catch {
            problem = "无法重新绘制：\(error.localizedDescription)"
            return
        }
        drawing = true
        let skinId = id
        Task { @MainActor in
            // 用户点的：网络图片已下载过的照用，没下载过的这时下载
            await CssRasterizer.ensure(skinId: skinId, fetchRemote: true)
            drawing = false
            tick += 1
        }
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
