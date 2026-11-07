import SwiftUI
import UniformTypeIdentifiers

// 「美化」app（网页版 apps/skin：Gallery.js 的文件夹首页、App.js 的美化库与每一份的详情）。
//
// 与会话菜单「主题」的分工（一个功能一个入口，网页版第 28 条第 3 项）：
//   美化 app 是美化库：新建、导入、编辑器、自定义 CSS、导出、删除，以及别处能写样式的地方的汇总；
//   会话菜单「主题」（ThemeGalleryView）只管「这段会话挂哪一份」：挂上、换一份、取下。要改一份主题本身，从那里点进来
//   的是这里的同一个详情页（SkinOneView），不另画一份。全部会话的默认也只有一页（ThemeGalleryView(chatId: nil)），
//   这里的「应用美化」与「设置 - 主题 - 聊天主题」都跳到它。
// 主题（原生的格子）与网页版美化（令牌、编辑器、手写 CSS）是同一行（skins 这一域），样式只有一条路（ChatTheme.resolve）。
// 设置 app 从不套主题；总开关在「设置 - 主题」（settings.skinOff），关着时这里写明。

/// 美化 app 里推进去的几页
enum SkinRoute: Hashable {
    case go(SkinPlaces.Go)
    case library
    case editor(String)
    case one(String)
}

struct SkinAppView: View {
    var body: some View {
        NavigationStack {
            SkinHomeView()
                .navigationDestination(for: SkinRoute.self) { SkinRouteView(route: $0) }
        }
    }
}

struct SkinRouteView: View {
    let route: SkinRoute

    var body: some View {
        switch route {
        case .library: SkinLibraryView(chatId: nil)
        case .editor(let id): SkinEditorView(id: id)
        case .one(let id): SkinOneView(id: id)
        case .go(let g):
            switch g {
            case .skin(let id): SkinOneView(id: id)
            case .global: ThemeGalleryView(chatId: nil)
            case .status(let chatId): StatusBarSettingsView(chatId: chatId)
            case .stage(let sceneId): StageLookView(sceneId: sceneId)
            case .card(let book, let entry): LoreEntryEditView(bookId: book, entryId: entry)
            }
        }
    }
}

// MARK: - 首页：一排排文件夹

struct SkinHomeView: View {
    @State private var tick = 0
    @State private var opened: String?
    @State private var lifted: SkinPlaces.Item?
    @State private var naming = false
    @State private var newName = ""
    @State private var problem: String?
    @State private var heroShown = true
    /// 首页上点出来要推进去的那一页（新建之后、放大看里点「编辑」）
    @State private var pending: SkinRoute?

    /// 文件夹与卡片的大小（网页版 4.844）：大一行两个，中三个，小四个。记在 settings.skinGallerySize
    static let sizes: [(id: String, label: String, n: Int)] = [("lg", "大", 2), ("md", "中", 3), ("sm", "小", 4)]

    private var settings: AppSettings { _ = tick; return AppSettings.load() }
    private var size: (id: String, label: String, n: Int) {
        let v = settings.raw["skinGallerySize"]?.string ?? ""
        return Self.sizes.first { $0.id == v } ?? Self.sizes[0]
    }
    private var cats: [SkinPlaces.Category] { _ = tick; return SkinPlaces.categories(settings: settings) }

    var body: some View {
        let list = cats
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sp4) {
                HeroHeader(eyebrow: "THEMES", title: "美化", shown: $heroShown)
                    .padding(.horizontal, Theme.sp4)
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal, Theme.sp4) }
                if settings.raw["skinOff"]?.bool == true { offNote }
                actions
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.sp3), count: size.n), spacing: Theme.sp4) {
                    ForEach(list) { c in
                        Button { withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { opened = c.id } } label: {
                            SkinFolderTile(cat: c, small: size.n > 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.sp4)
                Text("点一个文件夹打开，点里面的一样放大查看。编辑的地方仍在各自起作用的位置，放大后点「编辑」进入。")
                    .font(.footnote).foregroundStyle(Theme.text3)
                    .padding(.horizontal, Theme.sp4).padding(.bottom, Theme.sp8)
            }
        }
        .background(Theme.background)
        .heroTitle("美化", heroShown: heroShown)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    ForEach(Self.sizes, id: \.id) { s in
                        Button { setSize(s.id) } label: {
                            if size.id == s.id { Label("\(s.label)（一行 \(s.n) 个）", systemImage: "checkmark") } else { Text("\(s.label)（一行 \(s.n) 个）") }
                        }
                    }
                } label: { Image(systemName: "square.grid.2x2") }
                .accessibilityLabel("显示大小")
                Button("新建") { newName = ""; naming = true }
            }
        }
        .overlay {
            if let id = opened, let c = list.first(where: { $0.id == id }) {
                SkinFolderLayer(cat: c, columns: size.n, lifted: $lifted, onClose: close, onNew: { newName = ""; naming = true },
                                onGo: { go in opened = nil; path(go) })
                    .zIndex(1)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .overlay {
            if let it = lifted {
                SkinLightbox(item: it, onClose: { withAnimation(.easeOut(duration: 0.25)) { lifted = nil } }) { go in
                    lifted = nil
                    opened = nil
                    path(go)
                }
                .zIndex(2)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        // 文件夹或放大看开着时：左缘右滑先关它们，不离开这一页
        .background(RefuseEdgeBack(active: opened != nil || lifted != nil))
        .onReceive(NotificationCenter.default.publisher(for: .eiraSkinChanged)) { _ in tick += 1 }
        .onAppear { tick += 1 }
        .alert("新建一份美化", isPresented: $naming) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("新建") { create() }
        }
        .navigationDestination(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let pending { SkinRouteView(route: pending) }
        }
    }

    private func path(_ go: SkinPlaces.Go) { pending = .go(go) }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { lifted = nil; opened = nil }
    }

    private var offNote: some View {
        VStack(alignment: .leading, spacing: Theme.sp2) {
            Text("总开关已在「设置 - 主题」中关闭，所有会话均不显示主题与美化。").font(.footnote).foregroundStyle(Theme.text2)
            Button("开启主题与美化") {
                do {
                    var st = try AppSettings.loadForWrite()
                    st.raw["skinOff"] = .bool(false)
                    try st.save()
                    NotificationCenter.default.post(name: .eiraSkinChanged, object: nil)
                    problem = nil
                } catch { problem = "无法保存设置：\(error.localizedDescription)" }
                tick += 1
            }
            .font(.footnote)
        }
        .padding(Theme.sp3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.groupFill, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
        .padding(.horizontal, Theme.sp4)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            NavigationLink(value: SkinRoute.library) {
                IconRow(title: "导入美化包与全部美化", icon: "download", value: "\(Skins.all().count) 份")
                    .padding(.horizontal, Theme.sp3)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Theme.sp1)
        .background(Theme.groupFill, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
        .padding(.horizontal, Theme.sp4)
    }

    private func setSize(_ id: String) {
        do {
            var s = try AppSettings.loadForWrite()
            s.raw["skinGallerySize"] = .string(id)
            try s.save()
            problem = nil
        } catch { problem = "无法保存设置：\(error.localizedDescription)" }
        tick += 1
    }

    private func create() {
        do {
            let r = try ChatTheme.create(name: newName)
            problem = nil
            opened = nil
            // 新建的直接进编辑器（网页版 4.836）；编辑器没有打包进来时进这一份的详情
            pending = SkinGen.shared.available ? .editor(r.id) : .one(r.id)
        } catch { problem = "未能新建：\(error.localizedDescription)" }
        tick += 1
    }
}

/// 首页的一个文件夹：露出最前面那一张纸（正在用的在前）
struct SkinFolderTile: View {
    let cat: SkinPlaces.Category
    var small = false

    var body: some View {
        let items = cat.items
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous).fill(Theme.surface3)
                if let first = items.first {
                    SkinThumb(item: first)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                        .padding(EdgeInsets(top: Theme.sp2, leading: Theme.sp3, bottom: Theme.sp5, trailing: Theme.sp3))
                }
                RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous).fill(Theme.surface2)
                    .frame(height: small ? 22 : 30)
                    .overlay(alignment: .leading) {
                        Image(systemName: cat.icon).font(.system(size: small ? 11 : 14)).foregroundStyle(Theme.text2).padding(.leading, Theme.sp2)
                    }
            }
            .aspectRatio(0.82, contentMode: .fit)
            Text(cat.title).font(.system(size: small ? 12 : 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Text(cat.using.isEmpty ? "未使用" : "正在使用 \(cat.using.count)").font(.system(size: small ? 10 : 12)).foregroundStyle(Theme.text3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cat.title)，\(cat.using.isEmpty ? "未使用" : "正在使用 \(cat.using.count)")")
        .accessibilityAddTraits(.isButton)
    }
}

/// 一样东西现在的样子
struct SkinThumb: View {
    let item: SkinPlaces.Item
    var big = false
    @Environment(\.colorScheme) private var env

    var body: some View {
        switch item.preview {
        case .skin(let id)?:
            if let r = ChatTheme.row(id) {
                let t = ChatTheme.resolve(row: r)
                let dark = t.scheme == "dark" ? true : t.scheme == "light" ? false : env == .dark
                GeometryReader { g in
                    let w: CGFloat = big ? 340 : 220
                    let k = g.size.width / w
                    ThemePreview(theme: t, dark: dark, compact: !big)
                        .frame(width: w, height: g.size.height / max(k, 0.01))
                        .scaleEffect(k, anchor: .topLeading)
                        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                }
                .allowsHitTesting(false)
            } else { empty }
        case .code(let text)?:
            let lines = text.components(separatedBy: "\n")
            ScrollView(big ? .vertical : []) {
                Text(big ? text : lines.prefix(9).joined(separator: "\n"))
                    .font(.system(size: big ? 12 : 8, design: .monospaced))
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(big ? Theme.sp3 : 6)
            }
            .background(Theme.surface)
        case nil:
            empty
        }
    }

    private var empty: some View {
        ZStack {
            Theme.surface
            Image(systemName: "square.dashed").font(.system(size: big ? 40 : 22)).foregroundStyle(Theme.text3)
        }
    }
}

/// 打开的文件夹：从首页那个位置放大到屏幕中间，里面一张张纸，正在用的排在前面、标着「使用中」
struct SkinFolderLayer: View {
    let cat: SkinPlaces.Category
    let columns: Int
    @Binding var lifted: SkinPlaces.Item?
    var onClose: () -> Void
    var onNew: () -> Void
    var onGo: (SkinPlaces.Go) -> Void

    var body: some View {
        let items = cat.items
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: Theme.sp3) {
                HStack {
                    Text(cat.title).font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button("关闭", action: onClose).font(.system(size: 14))
                }
                Text(countLine(items.count)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                if items.isEmpty {
                    Text("在\(cat.place)中编写后，这里显示它现在的样子。").font(.footnote).foregroundStyle(Theme.text2)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.sp3), count: max(2, columns)), spacing: Theme.sp3) {
                            ForEach(items) { it in
                                Button { withAnimation(.easeOut(duration: 0.25)) { lifted = it } } label: { paper(it) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 440)
                }
                Text("\(cat.desc)。编辑位置：\(cat.place)。").font(.caption).foregroundStyle(Theme.text3)
                if cat.canNew || cat.go != nil {
                    HStack {
                        if cat.canNew { Button("新建", action: onNew).buttonStyle(EiraButtonStyle(kind: .ghost)) }
                        if let go = cat.go {
                            Button("打开编辑页") { onGo(go) }.buttonStyle(EiraButtonStyle(kind: .ghost))
                        }
                    }
                }
            }
            .padding(Theme.sp4)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.rXl, style: .continuous))
            .padding(Theme.sp4)
        }
        // 左缘右滑：收起这个文件夹
        .gesture(DragGesture(minimumDistance: 20).onEnded { v in
            if v.startLocation.x < 28 && v.translation.width > 60 && abs(v.translation.height) < 80 { onClose() }
        })
    }

    private func countLine(_ total: Int) -> String {
        let head = cat.using.isEmpty ? "没有在使用" : "正在使用 \(cat.using.count)"
        return total > cat.using.count ? "\(head) · 共 \(total)" : head
    }

    private func paper(_ it: SkinPlaces.Item) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SkinThumb(item: it)
                .aspectRatio(0.75, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                    .strokeBorder(it.on ? Theme.text : Theme.border, lineWidth: it.on ? 2 : 1))
            Text(it.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(it.on ? "使用中" : "未使用").font(.system(size: 10)).foregroundStyle(Theme.text3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("查看「\(it.title)」，\(it.on ? "使用中" : "未使用")")
        .accessibilityAddTraits(.isButton)
    }
}

/// 放大看：这一张放到屏幕中间，背景变暗，下面「编辑」带到那一处。点暗处、关闭或左缘右滑收起
struct SkinLightbox: View {
    let item: SkinPlaces.Item
    var onClose: () -> Void
    var onEdit: (SkinPlaces.Go) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(spacing: Theme.sp3) {
                SkinThumb(item: item, big: true)
                    .aspectRatio(0.75, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
                    .frame(maxWidth: 360)
                Text(item.sub.isEmpty ? item.title : "\(item.title) · \(item.sub)")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                HStack(spacing: Theme.sp4) {
                    if let go = item.go {
                        Button("编辑") { onEdit(go) }.buttonStyle(LightboxButton())
                    }
                    Button("关闭", action: onClose).buttonStyle(LightboxButton())
                }
            }
            .padding(Theme.sp5)
        }
        .gesture(DragGesture(minimumDistance: 20).onEnded { v in
            if v.startLocation.x < 28 && v.translation.width > 60 && abs(v.translation.height) < 80 { onClose() }
        })
    }

    struct LightboxButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.sp5).frame(minHeight: 40)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
                .opacity(configuration.isPressed ? 0.6 : 1)
        }
    }
}

// MARK: - 美化库：导入与全部美化（网页版 /list）

struct SkinLibraryView: View {
    /// 从会话菜单进来时：导入的那一份一并挂在这段会话上
    let chatId: String?
    @State private var tick = 0
    @State private var picking = false
    @State private var importing: Skins.Pack?
    @State private var problem: String?

    var body: some View {
        let mine = { _ = tick; return Skins.all() }()
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Button { picking = true } label: { Label("从文件导入", systemImage: "doc") }
                NavigationLink { SkinImportView(chatId: chatId ?? "") } label: { Label("粘贴导入", systemImage: "doc.on.clipboard") }
                NavigationLink { SkinImportView(chatId: chatId ?? "", mode: .css) } label: {
                    Label("粘贴 CSS", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } header: { GroupTitle("导入") } footer: {
                HelpNote("读取本应用导出的美化包与主题：JSON、TXT、DOCX 文件，或复制的一段文字（连同 BEGIN 与 END 两行标记）。也可以直接粘贴一段 CSS，作为一份只含自定义 CSS 的美化。导入后新建一份，不覆盖现有的美化；从会话菜单进来时一并挂在这段会话上。只认本应用自己的格式，不导入别家的角色卡与主题格式。", title: "导入美化包")
            }
            Section {
                NavigationLink { ThemeGalleryView(chatId: nil) } label: {
                    IconRow(title: "应用美化", icon: "grid", value: ThemeGalleryView.globalLabel(AppSettings.load()))
                }
            } footer: {
                HelpNote("全部会话的默认主题：没有单独挂主题的会话使用它。与「设置 - 主题 - 聊天主题」是同一页。", title: "应用美化")
            }
            Section {
                if mine.isEmpty {
                    Text("还没有任何美化。在首页右上角新建，或从上面导入。").foregroundStyle(Theme.text3)
                }
                ForEach(mine, id: \.id) { r in
                    NavigationLink { SkinOneView(id: r.id) } label: {
                        HStack(spacing: Theme.sp3) {
                            ThemeCard(row: r, small: true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ThemeGalleryView.name(r))
                                let n = Skins.usedBy(r.id)
                                Text(n > 0 ? "已用于 \(n) 段会话" : "尚未用于任何会话").font(.caption).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                }
            } header: { GroupTitle("共 \(mine.count) 份") }
            Section {
                ForEach(ChatTheme.builtins, id: \.id) { r in
                    NavigationLink { SkinOneView(id: r.id) } label: {
                        HStack(spacing: Theme.sp3) {
                            ThemeCard(row: r, small: true)
                            Text(ThemeGalleryView.name(r))
                        }
                    }
                }
            } header: { GroupTitle("内置（\(ChatTheme.builtins.count)）") }
        }
        .navigationTitle("全部美化")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .eiraSkinChanged)) { _ in tick += 1 }
        .documentPicker(isPresented: $picking, types: [UTType.json, UTType.plainText, UTType(filenameExtension: "docx")].compactMap { $0 }) { urls in
            guard let url = urls.first else { return }
            do { importing = try Skins.parsePack(DocText.read(url)); problem = nil }
            catch { problem = "无法导入：\(error.localizedDescription)" }
        }
        .navigationDestination(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } })) {
            if let importing { SkinImportView(chatId: chatId ?? "", pack: importing) { tick += 1 } }
        }
    }
}
