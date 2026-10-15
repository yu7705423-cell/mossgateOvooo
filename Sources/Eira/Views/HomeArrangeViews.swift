import PhotosUI
import SwiftUI

/// 主屏整理时点开的几页（网页版 screens/home 的 CellEditor、Picker、FolderEdit、WidgetEditor）。
/// 改动一律经 `HomeArrange.apply`：先读到库里那一份再改再存，读不到不改（网页版第 20 条）。
typealias HomeApply = ((inout HomeLayout) throws -> Void) -> Bool

/// 整理模式下点了哪里
enum ArrangeTarget: Identifiable {
    case cell(Shell.Cell, page: Int)
    case slot(page: Int, x: Int, y: Int)
    case dock(Int, app: String)

    var id: String {
        switch self {
        case .cell(let c, _): return "c-\(c.id)"
        case let .slot(p, x, y): return "s-\(p)-\(x)-\(y)"
        case let .dock(i, _): return "d-\(i)"
        }
    }
}

/// 原生版画得出来的小组件，与网页版同样的尺寸
enum HomeWidgets {
    struct Def: Identifiable {
        let id: String
        let label: String
        let sizes: [(Int, Int)]
        let editable: Bool
    }
    static let all: [Def] = [
        Def(id: "player", label: "播放器横条", sizes: [(4, 2)], editable: true),
        Def(id: "note", label: "文字块", sizes: [(2, 1), (2, 2), (4, 1), (4, 2)], editable: true),
        Def(id: "photo", label: "图片块", sizes: [(2, 2), (4, 2), (2, 1)], editable: true),
        Def(id: "recent-chats", label: "最近会话", sizes: [(2, 2), (4, 2)], editable: false),
    ] + MoreWidgets.all.map { Def(id: $0.id, label: $0.label, sizes: $0.sizes, editable: !$0.fields.isEmpty) }
    static func def(_ id: String) -> Def? { all.first { $0.id == id } }
    static func label(_ id: String) -> String { def(id)?.label ?? "小组件" }
}

/// 点一个位置弹出的那一列（格子、空位、底栏）
struct ArrangeMenu: View {
    let target: ArrangeTarget
    let settings: [String: JSONValue]
    let apply: HomeApply
    /// 「移动到别处」：交给主屏进入选目标的状态
    var startMove: (HomeLayout.Spot) -> Void
    var close: () -> Void

    @State private var titleText = ""
    @State private var naming = false

    var body: some View {
        NavigationStack {
            List {
                switch target {
                case let .cell(c, page):
                    cellRows(c, page: page)
                case let .slot(page, x, y):
                    placeRows(page: page, x: x, y: y, replacing: nil)
                    NavigationLink("新建文件夹") {
                        FolderEditView(mode: .new(page: page, x: x, y: y, preset: []), settings: settings, apply: apply, done: close)
                    }
                case let .dock(i, app):
                    NavigationLink("图标与名称") { IconEditView(appId: app) { close() } }
                    Button("移动到别处") { startMove(.dock(i)); close() }
                    Button("移除", role: .destructive) { if apply({ $0.removeDock(i) }) { close() } }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭", action: close) } }
            .alert("小组件名称", isPresented: $naming) {
                TextField("留空则不显示名称", text: $titleText)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    if case let .cell(c, _) = target, apply({ $0.setMeta(c.id, title: titleText) }) { close() }
                }
            }
        }
    }

    private var title: String {
        switch target {
        case .cell(let c, _):
            switch c.kind {
            case "folder": return c.name.isEmpty ? "文件夹" : c.name
            case "app": return Shell.look(c.ref, settings: settings)?.name ?? "这个位置"
            default: return c.title.isEmpty ? HomeWidgets.label(c.ref) : c.title
            }
        case .slot: return "这个空位"
        case .dock(_, let app): return Shell.look(app, settings: settings)?.name ?? "底栏"
        }
    }

    @ViewBuilder private func placeRows(page: Int, x: Int, y: Int, replacing: String?) -> some View {
        NavigationLink("放一个小组件") {
            WidgetPickerView(settings: settings) { ref, w, h in
                put(["kind": .string("widget"), "ref": .string(ref), "w": .number(Double(w)), "h": .number(Double(h))],
                    page: page, x: x, y: y, replacing: replacing)
            }
        }
        NavigationLink("放一个应用") {
            AppPickerView(settings: settings) { id in
                put(["kind": .string("app"), "ref": .string(id), "w": .number(1), "h": .number(1)], page: page, x: x, y: y, replacing: replacing)
            }
        }
    }

    private func put(_ next: [String: JSONValue], page: Int, x: Int, y: Int, replacing: String?) {
        let ok = apply { h in
            if let replacing { try h.replace(replacing, with: next) } else { try h.place(page: page, x: x, y: y, next) }
        }
        if ok { close() }
    }

    @ViewBuilder private func cellRows(_ c: Shell.Cell, page: Int) -> some View {
        if c.kind == "folder" {
            NavigationLink("编辑文件夹") {
                FolderEditView(mode: .edit(c.id, name: c.name, apps: c.apps), settings: settings, apply: apply, done: close)
            }
            NavigationLink("取出一个应用") {
                List(c.apps.compactMap { Shell.look($0, settings: settings) }, id: \.id) { a in
                    Button(a.name) { if apply({ try $0.takeOut(c.id, app: a.id) }) { close() } }
                }
                .navigationTitle("取出一个应用")
            }
        } else {
            Section {
                placeRows(page: page, x: c.x, y: c.y, replacing: c.id)
                if c.kind == "app" {
                    NavigationLink("新建文件夹") {
                        FolderEditView(mode: .new(page: page, x: c.x, y: c.y, preset: [c.ref]), settings: settings, apply: apply, done: close)
                    }
                }
            } footer: {
                HelpNote("放小组件或应用：放下的内容换掉这一格原来的内容，挡住的格子自动让开。新建文件夹：把这个应用和别的应用收进一格。", title: "主屏整理：这一格")
            }
        }
        Section {
            if c.kind == "widget" {
                Button("名称") { titleText = c.title; naming = true }
                if HomeWidgets.def(c.ref)?.editable == true {
                    NavigationLink("编辑内容") {
                        if let more = MoreWidgets.all.first(where: { $0.id == c.ref }) {
                            WidgetFieldsView(cell: c, def: more, apply: apply, done: close)
                        } else {
                            WidgetEditView(cell: c, apply: apply, done: close)
                        }
                    }
                }
            }
            if c.kind == "app" {
                NavigationLink("图标与名称") { IconEditView(appId: c.ref) { close() } }
                let folders = (try? HomeLayout.begin(settings: settings))?.folders ?? []
                if !folders.isEmpty {
                    NavigationLink("装进已有的文件夹") {
                        List(folders.indices, id: \.self) { i in
                            let f = folders[i]
                            Button(f["name"]?.string ?? "文件夹") {
                                if apply({ try $0.putInFolder(HomeLayout.id(f), app: c.ref) }) { close() }
                            }
                        }
                        .navigationTitle("装进哪个文件夹")
                    }
                }
            }
            if c.kind == "app" || c.kind == "folder" {
                Picker("名称显示", selection: Binding(get: { c.label }, set: { v in if apply({ $0.setMeta(c.id, label: v) }) { close() } })) {
                    Text("跟随全局").tag("")
                    Text("显示").tag("show")
                    Text("隐藏").tag("hide")
                }
            }
            Button("移动到别处") { startMove(.cell(c.id)); close() }
        } footer: {
            HelpNote("移动到别处：接着点想放到的位置，翻页后再点也可以，占着的会自动让开。名称显示：单独设置这一格是否显示名称，跟随全局时按「设置 - 主题」的设置。", title: "主屏整理：移动与名称")
        }
        Section {
            Button("移除", role: .destructive) { if apply({ $0.remove(c.id) }) { close() } }
        } footer: {
            Text(c.kind == "widget" ? "从主界面移除该小组件。" : "从主界面移除。之后可在「设置 - 主题」中放回，或在任意空位重新放置。")
        }
    }
}

/// 选一个小组件：每种尺寸一张卡片，画的就是它本身
struct WidgetPickerView: View {
    let settings: [String: JSONValue]
    var pick: (String, Int, Int) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(cards, id: \.key) { card in
                    Button { pick(card.def.id, card.w, card.h) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            preview(card)
                            Text(card.def.label).font(.subheadline).foregroundStyle(Theme.text)
                            Text("\(card.w) x \(card.h)").font(.caption).foregroundStyle(Theme.text2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.pad * 2)
        }
        .navigationTitle("选一个小组件")
        .navigationBarTitleDisplayMode(.inline)
    }

    struct Card { let def: HomeWidgets.Def; let w: Int; let h: Int; var key: String { "\(def.id)-\(w)x\(h)" } }
    private var cards: [Card] { HomeWidgets.all.flatMap { d in d.sizes.map { Card(def: d, w: $0.0, h: $0.1) } } }

    private func preview(_ c: Card) -> some View {
        let unit: CGFloat = 64, gap: CGFloat = 12
        let cell = Shell.Cell(id: "pick-\(c.key)", kind: "widget", ref: c.def.id, x: 0, y: 0, w: c.w, h: c.h, name: "", apps: [],
                              label: "", coverIcon: "", coverImageId: "", config: [:])
        return HomeWidget(cell: cell, home: HomeLook(wallpaper: false, dark: scheme == .dark, s: settings), open: { _ in }, openChat: { _ in })
            .frame(width: CGFloat(c.w) * unit + CGFloat(c.w - 1) * gap, height: CGFloat(c.h) * unit + CGFloat(c.h - 1) * gap)
            .allowsHitTesting(false)
    }
}

/// 选一个应用：已经摆着的也可以选，选了就从原处挪过来
struct AppPickerView: View {
    let settings: [String: JSONValue]
    var pick: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 18) {
                ForEach(Shell.apps.compactMap { Shell.look($0.id, settings: settings) }, id: \.id) { l in
                    Button { pick(l.id) } label: {
                        VStack(spacing: 5) {
                            AppTileView(look: l, size: 52, home: HomeLook(wallpaper: false, dark: scheme == .dark, s: settings))
                            Text(l.name).font(.system(size: 11)).lineLimit(1).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .buttonStyle(TilePress())
                }
            }
            .padding(Theme.pad * 2)
        }
        .navigationTitle("选一个应用")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 新建或改一个文件夹：名字，与里面装哪几个应用
struct FolderEditView: View {
    enum Mode {
        case new(page: Int, x: Int, y: Int, preset: [String])
        case edit(String, name: String, apps: [String])
    }
    let mode: Mode
    let settings: [String: JSONValue]
    let apply: HomeApply
    var done: () -> Void

    @State private var name = ""
    @State private var chosen: [String] = []
    @State private var loaded = false

    var body: some View {
        Form {
            Section("名称") { TextField("文件夹", text: $name) }
            Section {
                ForEach(Shell.apps.compactMap { Shell.look($0.id, settings: settings) }, id: \.id) { l in
                    Button {
                        if let i = chosen.firstIndex(of: l.id) { chosen.remove(at: i) } else { chosen.append(l.id) }
                    } label: {
                        HStack {
                            Text(l.name).foregroundStyle(Theme.text)
                            Spacer()
                            if chosen.contains(l.id) { Image(systemName: "checkmark").foregroundStyle(Theme.text) }
                        }
                    }
                }
            } header: {
                Text("里面的应用")
            } footer: {
                HelpNote("选中的应用从原来的位置移进文件夹。全部取消后，文件夹一并移除。", title: "文件夹")
            }
        }
        .navigationTitle(isNew ? "新建文件夹" : "编辑文件夹")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    let ok = apply { h in
                        switch mode {
                        case let .new(page, x, y, _): try h.newFolder(page: page, x: x, y: y, apps: chosen, name: name)
                        case let .edit(id, _, _): try h.setFolder(id, name: name, apps: chosen)
                        }
                    }
                    if ok { done() }
                }
                .disabled(isNew && chosen.isEmpty)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            switch mode {
            case let .new(_, _, _, preset): name = "文件夹"; chosen = preset
            case let .edit(_, n, apps): name = n; chosen = apps
            }
        }
    }

    private var isNew: Bool { if case .new = mode { return true }; return false }
}

/// 改小组件的内容：文字、字号、衬线、图片、对齐（网页版 WidgetEditor 里这几样）
struct WidgetEditView: View {
    let cell: Shell.Cell
    let apply: HomeApply
    var done: () -> Void

    @State private var lines = ["", "", ""]
    @State private var sizes = ["lg", "sm", "sm"]
    @State private var serif = false
    @State private var right = false
    @State private var cover = ""
    @State private var item: PhotosPickerItem?
    @State private var problem: String?
    @State private var loaded = false

    private var lineCount: Int { cell.ref == "player" ? 3 : cell.ref == "note" ? 2 : 1 }
    private var hasCover: Bool { cell.ref == "player" || cell.ref == "photo" }

    var body: some View {
        Form {
            Section {
                ForEach(0..<lineCount, id: \.self) { i in
                    TextField(cell.ref == "photo" ? "图片上的一行字" : "第 \(i + 1) 行", text: $lines[i])
                    if cell.ref != "photo" {
                        Picker("字号", selection: $sizes[i]) {
                            Text("大").tag("lg"); Text("中").tag("md"); Text("小").tag("sm")
                        }
                        .pickerStyle(.segmented)
                    }
                }
            } header: { Text("文字") }
            if cell.ref != "photo" {
                Section {
                    Toggle("衬线字体", isOn: $serif)
                    if cell.ref == "player" { Toggle("文字靠右", isOn: $right) }
                }
            }
            if hasCover {
                Section {
                    if !cover.isEmpty {
                        LocalImage(id: cover, maxPixel: 400).frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    PhotosPicker(selection: $item, matching: .images) { Text(cover.isEmpty ? "选择图片" : "更换图片") }
                    if !cover.isEmpty { Button("去掉图片", role: .destructive) { cover = "" } }
                } header: { Text("图片") }
            }
            ProblemSection(text: problem)
        }
        .navigationTitle(HomeWidgets.label(cell.ref))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    var cfg: [String: JSONValue] = [:]
                    for i in 0..<lineCount {
                        cfg["line\(i + 1)"] = .string(lines[i])
                        if cell.ref != "photo" { cfg["size\(i + 1)"] = .string(sizes[i]) }
                    }
                    if cell.ref != "photo" { cfg["serif"] = .bool(serif) }
                    if cell.ref == "player" { cfg["align"] = .string(right ? "right" : "left") }
                    if hasCover { cfg["cover"] = .string(cover) }
                    if apply({ $0.setConfig(cell.id, cfg) }) { done() }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let defaults = ["lg", "sm", "sm"]
            for i in 0..<3 {
                lines[i] = cell.config["line\(i + 1)"]?.string ?? ""
                sizes[i] = cell.config["size\(i + 1)"]?.string ?? defaults[i]
            }
            serif = cell.config["serif"]?.bool == true
            right = cell.config["align"]?.string == "right"
            cover = cell.config["cover"]?.string ?? ""
        }
        .onChange(of: item) { _, it in
            guard let it else { return }
            Task {
                do {
                    guard let data = try await it.loadTransferable(type: Data.self) else { throw StoreError(message: "无法读取所选图片") }
                    let id = try Images.save(data, maxPixel: Images.photoMax)
                    await MainActor.run { cover = id }
                } catch {
                    await MainActor.run { problem = "图片未能保存：\(error.localizedDescription)" }
                }
            }
        }
    }
}

/// 「设置 - 主题」里列出移除过的应用，点一下放回主界面
struct RemovedAppsSection: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var ids: [String] = []
    @State private var problem: String?

    var body: some View {
        Section {
            if ids.isEmpty {
                Text("没有移除过的应用。").foregroundStyle(Theme.text2)
            }
            ForEach(ids, id: \.self) { id in
                HStack {
                    Text(Shell.look(id, settings: model.s.raw)?.name ?? id)
                    Spacer()
                    Button("放回") { restore(id) }.buttonStyle(.borderless)
                }
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("移除过的应用")
        } footer: {
            HelpNote("在主界面长按空白处，或长按图标选择「整理主屏幕」，可以挪动图标、放小组件、建文件夹或移除。移除的应用列在这里，点「放回」后放到主界面的空位上。", title: "移除过的应用")
        }
        .onAppear(perform: load)
    }

    private func load() {
        do { ids = try HomeLayout.begin(settings: model.s.raw).removedApps }
        catch { problem = "读不到主屏版式：\(error.localizedDescription)" }
    }

    private func restore(_ id: String) {
        do {
            var h = try HomeLayout.begin(settings: model.s.raw)
            h.restore(id)
            try h.save()
            load()
        } catch {
            problem = "未能放回：\(error.localizedDescription)"
        }
    }
}

/// 其余小组件的内容：按各自登记的几项（图片、文字、角色）逐项填（网页版 WidgetEditor 的 fields）
struct WidgetFieldsView: View {
    let cell: Shell.Cell
    let def: MoreWidgets.Def
    let apply: HomeApply
    var done: () -> Void

    @State private var values: [String: String] = [:]
    @State private var chars: [Character] = []
    @State private var picking: String?
    @State private var item: PhotosPickerItem?
    @State private var problem: String?
    @State private var loaded = false

    var body: some View {
        Form {
            ForEach(def.fields, id: \.key) { f in
                Section {
                    switch f.kind {
                    case "image":
                        let id = values[f.key] ?? ""
                        if !id.isEmpty {
                            LocalImage(id: id, maxPixel: 400).frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Button(id.isEmpty ? "选择图片" : "更换图片") { picking = f.key }
                        if !id.isEmpty { Button("去掉图片", role: .destructive) { values[f.key] = "" } }
                    case "char":
                        Picker("角色", selection: Binding(get: { values[f.key] ?? "" }, set: { values[f.key] = $0 })) {
                            Text("默认").tag("")
                            ForEach(chars, id: \.id) { c in Text(c.displayName).tag(c.id) }
                        }
                    default:
                        TextField(f.placeholder.isEmpty ? f.label : f.placeholder, text: Binding(get: { values[f.key] ?? "" }, set: { values[f.key] = $0 }))
                    }
                } header: {
                    Text(f.label)
                } footer: {
                    if f.kind == "image" && !f.placeholder.isEmpty { Text(f.placeholder) }
                }
            }
            ProblemSection(text: problem)
        }
        .navigationTitle(def.label)
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(isPresented: Binding(get: { picking != nil }, set: { if !$0 && item == nil { picking = nil } }), selection: $item, matching: .images)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    var cfg: [String: JSONValue] = [:]
                    for f in def.fields {
                        let v = values[f.key] ?? ""
                        cfg[f.key] = f.kind == "image" && v.isEmpty ? .null : .string(v)
                    }
                    if apply({ $0.setConfig(cell.id, cfg) }) { done() }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            for f in def.fields { values[f.key] = cell.config[f.key]?.string ?? "" }
            chars = ((try? Repo.characters()) ?? []).filter { !$0.archived }
        }
        .onChange(of: item) { _, it in
            guard let it, let key = picking else { return }
            item = nil
            picking = nil
            Task {
                do {
                    guard let data = try await it.loadTransferable(type: Data.self) else { throw StoreError(message: "无法读取所选图片") }
                    let id = try Images.save(data, maxPixel: Images.photoMax)
                    await MainActor.run { values[key] = id }
                } catch {
                    await MainActor.run { problem = "图片未能保存：\(error.localizedDescription)" }
                }
            }
        }
    }
}
