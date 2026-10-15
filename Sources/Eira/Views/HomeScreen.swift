import SwiftUI

/// 主屏的颜色与尺寸，照网页版 tokens.css、shell.css（旧版那一套，网页版默认）。
/// 设置里改过的（图标底板、底栏颜色、图标颜色、名称颜色、图标大小、图标阴影）按 look.js 的读法盖上去。
struct HomeLook {
    var wallpaper: Bool
    var dark: Bool
    var s: [String: JSONValue]

    static let gap: CGFloat = 14          // --grid-gap
    static let sidePad: CGFloat = 20      // --sp-5
    static let tileRatio: CGFloat = 0.6   // --tile-ratio

    /// {color:'#rrggbb', alpha:0..100} → 颜色（网页版 plateOf）
    static func plate(_ v: JSONValue?) -> Color? {
        guard let o = v?.object, let hex = o["color"]?.string, let c = Color(hex: hex) else { return nil }
        let a = max(0, min(100, (o["alpha"]?.number ?? 60).rounded()))
        return c.opacity(a / 100)
    }

    var capsuleBg: Color {
        switch (wallpaper, dark) {
        case (false, false): return Color.black.opacity(0.045)
        case (false, true): return Color.white.opacity(0.08)
        case (true, false): return Color.white.opacity(0.58)
        case (true, true): return Color.black.opacity(0.52)
        }
    }
    var capsuleBorder: Color {
        guard wallpaper else { return .clear }
        return Color.white.opacity(dark ? 0.16 : 0.40)
    }
    var widgetBg: Color {
        switch (wallpaper, dark) {
        case (false, false): return .white
        case (false, true): return Color(white: 0.043)
        case (true, false): return Color.white.opacity(0.72)
        case (true, true): return Color.black.opacity(0.62)
        }
    }
    var tilePlate: Color? { Self.plate(s["tilePlate"]) }
    var tileBg: Color { tilePlate ?? (wallpaper ? capsuleBg : .white) }
    var dockBg: Color { Self.plate(s["dockColor"]) ?? tilePlate ?? capsuleBg }
    var iconColor: Color { s["iconColor"]?.string.flatMap(Color.init(hex:)) ?? .black }
    var tileShadow: Bool { !wallpaper && s["iconShadow"]?.bool != false }
    var nameColor: Color {
        if let c = s["iconLabelColor"]?.string.flatMap(Color.init(hex:)) { return c }
        return wallpaper ? .white : Theme.secondaryText
    }
    var text: Color { wallpaper ? (dark ? .white : .black) : .primary }
    var subText: Color { text.opacity(0.45) }
    var tileScale: CGFloat {
        let n = s["iconScale"]?.number ?? 1
        guard n > 0 else { return 1 }
        return CGFloat((max(0.7, min(1.2, n)) * 100).rounded() / 100)
    }
}

extension Color {
    /// #rrggbb
    init?(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let n = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
    }
}

/// 一个 app 图标（网页版 AppTile）：换过图片显示图片，否则白底黑线条图标。
struct AppTileView: View {
    let look: Shell.Look
    let size: CGFloat
    var badge = 0
    let home: HomeLook

    var body: some View {
        let radius = size * 0.24
        ZStack {
            if !look.imageId.isEmpty {
                let pct = look.scale > 0 ? look.scale / 100 : 1
                LocalImage(id: look.imageId, maxPixel: size * 3, fit: true)
                    .frame(width: size * pct, height: size * pct)
            } else {
                SvgIcon(name: look.icon, size: size * 0.52, color: home.iconColor)
            }
        }
        .frame(width: size, height: size)
        .background {
            if !(look.bare && !look.imageId.isEmpty) {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(home.tileBg)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(home.capsuleBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(home.tileShadow ? (home.dark ? 0.55 : 0.13) : 0), radius: 4, y: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: look.bare && !look.imageId.isEmpty ? 0 : radius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if badge > 0 {
                Text(badge > 99 ? "99+" : "\(badge)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Capsule().fill(Color.primary))
                    .offset(x: 4, y: -4)
                    .accessibilityLabel("\(badge) 条未读")
            }
        }
    }
}

/// 主屏：壁纸、一页页的格子、翻页圆点、底栏。点图标由外面打开 app。
/// 长按进整理模式（网页版 HomeScreen 的 edit）：点一格出菜单，点空位放东西，按住拖到别处，
/// 「移动到别处」之后翻页再点目标也可以；底栏同样能放能换。每一步都先读到库里那份再改再存。
struct HomeScreen: View {
    let layout: Shell.Layout
    let settings: [String: JSONValue]
    let unread: Int
    var zoom: Namespace.ID?
    var open: (String) -> Void
    var openChat: (String) -> Void
    /// 版式改了，外面重读一遍
    var changed: () -> Void = {}

    @Environment(\.colorScheme) private var scheme
    @State private var page = 0
    @State private var folder: Shell.Cell?
    /// 长按图标换图标与名称
    @State private var editingIcon: String?
    /// 整理模式
    @State private var editing = false
    /// 「移动到别处」选中的那一个，等着点目标
    @State private var picked: HomeLayout.Spot?
    @State private var target: ArrangeTarget?
    /// 一屏放得下几行（量出来的，至少 6）
    @State private var fitRows = HomeLayout.minRows

    private var home: HomeLook { HomeLook(wallpaper: !layout.wallpaperHome.isEmpty, dark: scheme == .dark, s: settings) }
    private var cols: Int { Shell.cols(settings) }

    var body: some View {
        GeometryReader { geo in
            let gridW = geo.size.width - HomeLook.sidePad * 2
            let byW = (gridW - HomeLook.gap * CGFloat(cols - 1)) / CGFloat(cols)
            let tile = byW * HomeLook.tileRatio * home.tileScale
            VStack(spacing: 0) {
                GeometryReader { g in
                    let size = cellSize(width: gridW, height: g.size.height)
                    TabView(selection: $page) {
                        ForEach(Array(layout.pages.enumerated()), id: \.offset) { i, p in
                            grid(p, index: i, size: size)
                                .frame(width: g.size.width, height: g.size.height, alignment: .top)
                                .contentShape(Rectangle())
                                // 整理时这一手势让开，按住是拖动
                                .gesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in enterEdit() },
                                         including: editing ? .subviews : .all)
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .task(id: g.size.height) {
                        let n = Int(((g.size.height + HomeLook.gap) / (byW + HomeLook.gap)).rounded(.down))
                        fitRows = max(HomeLayout.minRows, n)
                    }
                }
                .padding(.top, 12)
                dots
                if editing { editBar }
                if !layout.dockHidden { dock(tile: min(tile, cellSize(width: gridW, height: .infinity) * HomeLook.tileRatio * home.tileScale), width: geo.size.width) }
            }
        }
        .onAppear { page = min(max(0, layout.currentPage), layout.pages.count - 1) }
        .onChange(of: layout.pages.count) { _, n in if page >= n { page = max(0, n - 1) } }
        .sheet(item: Binding(get: { editingIcon.map { IconTarget(id: $0) } }, set: { editingIcon = $0?.id })) { t in
            NavigationStack { IconEditView(appId: t.id) { editingIcon = nil } }
        }
        .sheet(item: $folder) { f in
            FolderSheet(cell: f, settings: settings, home: home) { id in folder = nil; open(id) }
                .presentationDetents([.medium])
        }
        .sheet(item: $target, onDismiss: changed) { t in
            ArrangeMenu(target: t, settings: settings, apply: apply, startMove: { picked = $0 }, close: { target = nil })
                .presentationDetents([.medium, .large])
        }
    }

    struct IconTarget: Identifiable { var id: String }
    struct DockSlot: Identifiable { var id: Int; var look: Shell.Look? }

    @ViewBuilder private func iconMenu(_ appId: String) -> some View {
        Button { enterEdit() } label: { Label("整理主屏幕", systemImage: "square.grid.2x2") }
        Button { editingIcon = appId } label: { Label("更换图标与名称", systemImage: "paintbrush") }
    }

    private func enterEdit() {
        picked = nil
        withAnimation(.easeOut(duration: 0.2)) { editing = true }
    }

    /// 先读到库里那一份再改再存。读不到、改不了的在屏幕上说
    private func apply(_ f: (inout HomeLayout) throws -> Void) -> Bool {
        do {
            var h = try HomeLayout.begin(settings: settings, cap: fitRows)
            try f(&h)
            try h.save()
            changed()
            return true
        } catch let e as HomeLayout.Failure {
            Problems.report(e.reason)
        } catch {
            Problems.report("主屏版式未能保存：\(error.localizedDescription)")
        }
        return false
    }

    /// 在网格里最多用到几行；整理时多留一行（已经到一屏放得下的行数就不多留）
    private func neededRows(_ p: Shell.Page) -> Int {
        let need = p.cells.map { $0.y + $0.h }.max() ?? 0
        return max(HomeLayout.minRows, need + (editing && need < fitRows ? 1 : 0))
    }

    /// 格子边长（网页版 HomeScreen 的 measure）：先按宽度均分，再看这个高度放不放得下所有页里最高的那一页。
    private func cellSize(width: CGFloat, height: CGFloat) -> CGFloat {
        let gap = HomeLook.gap
        let byW = (width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        guard height.isFinite, height > 0 else { return max(44, byW.rounded(.down)) }
        let fitRows = max(4, Int(((height + gap) / (byW + gap)).rounded(.down)))
        let need = layout.pages.map(neededRows).max() ?? 6
        let rows = max(need, fitRows)
        let byH = (height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return max(44, min(byW, byH).rounded(.down))
    }

    private func grid(_ p: Shell.Page, index: Int, size: CGFloat) -> some View {
        let gap = HomeLook.gap
        let total = CGFloat(cols) * size + CGFloat(cols - 1) * gap
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: total, height: 1)
            if editing {
                ForEach(freeSlots(p), id: \.self) { xy in
                    slot(page: index, x: xy[0], y: xy[1], size: size)
                        .offset(x: CGFloat(xy[0]) * (size + gap), y: CGFloat(xy[1]) * (size + gap))
                }
            }
            ForEach(p.cells.filter { $0.x + $0.w <= cols }) { c in
                Group {
                    if editing { editCell(c, page: index, size: size) } else { cell(c, size: size) }
                }
                .frame(width: CGFloat(c.w) * size + CGFloat(c.w - 1) * gap,
                       height: CGFloat(c.h) * size + CGFloat(c.h - 1) * gap, alignment: .top)
                .offset(x: CGFloat(c.x) * (size + gap), y: CGFloat(c.y) * (size + gap))
            }
        }
        .frame(width: total, alignment: .topLeading)
    }

    private func freeSlots(_ p: Shell.Page) -> [[Int]] {
        var taken = Set<String>()
        for c in p.cells { for dy in 0..<c.h { for dx in 0..<c.w { taken.insert("\(c.x + dx),\(c.y + dy)") } } }
        var out: [[Int]] = []
        for y in 0..<neededRows(p) { for x in 0..<cols where !taken.contains("\(x),\(y)") { out.append([x, y]) } }
        return out
    }

    // MARK: - 整理模式

    private func slot(page: Int, x: Int, y: Int, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
            .strokeBorder(home.subText.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .overlay(Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(home.subText))
            .frame(width: size * HomeLook.tileRatio * home.tileScale, height: size * HomeLook.tileRatio * home.tileScale)
            .frame(width: size, height: size, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture {
                if let picked { move(picked, to: .slot(page: page, x: x, y: y)) } else { target = .slot(page: page, x: x, y: y) }
            }
            .dropDestination(for: String.self) { items, _ in drop(items.first, to: .slot(page: page, x: x, y: y)) }
            .accessibilityLabel("空位")
    }

    private func editCell(_ c: Shell.Cell, page: Int, size: CGFloat) -> some View {
        let isPicked = picked == .cell(c.id)
        return cell(c, size: size)
            .allowsHitTesting(false)
            .scaleEffect(isPicked ? 0.86 : 0.94)
            .overlay {
                if isPicked {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(home.text, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let p = picked {
                    if p == .cell(c.id) { picked = nil } else { move(p, to: .cell(c.id)) }
                } else {
                    target = .cell(c, page: page)
                }
            }
            .draggable("cell:\(c.id)")
            .dropDestination(for: String.self) { items, _ in drop(items.first, to: .cell(c.id)) }
    }

    private func spot(_ payload: String?) -> HomeLayout.Spot? {
        guard let payload else { return nil }
        if payload.hasPrefix("cell:") { return .cell(String(payload.dropFirst(5))) }
        if payload.hasPrefix("dock:"), let i = Int(payload.dropFirst(5)) { return .dock(i) }
        return nil
    }

    private func drop(_ payload: String?, to dest: HomeLayout.Spot) -> Bool {
        guard let src = spot(payload), src != dest else { return false }
        move(src, to: dest)
        return true
    }

    /// 挪过去。应用落在文件夹上就装进去
    private func move(_ src: HomeLayout.Spot, to dest: HomeLayout.Spot) {
        picked = nil
        _ = apply { h in
            if case .cell(let tid) = dest, let t = h.locate(tid), HomeLayout.kind(t.cell) == "folder" {
                var app: String?
                if case .cell(let sid) = src, let s = h.locate(sid), HomeLayout.kind(s.cell) == "app" { app = HomeLayout.ref(s.cell) }
                if case .dock(let i) = src { app = h.dock[i] }
                if let app { try h.putInFolder(tid, app: app); return }
            }
            try h.move(src, to: dest)
        }
    }

    private var editBar: some View {
        VStack(spacing: 8) {
            Text(picked == nil
                 ? "按住拖到想放的位置，停在文件夹上可装入。点一下更换内容、移动或移除，点空位放应用、小组件或文件夹。"
                 : "点目标位置完成移动，翻页后再点也可以。")
                .font(.system(size: 12)).foregroundStyle(home.subText).multilineTextAlignment(.center)
            HStack(spacing: 18) {
                if picked != nil {
                    Button("取消移动") { picked = nil }
                }
                Button {
                    if apply({ _ = $0.addPage() }) { page = layout.pages.count }
                } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                    .accessibilityLabel("新建一页")
                if page > 0, layout.pages.indices.contains(page), layout.pages[page].cells.isEmpty {
                    Button(role: .destructive) {
                        let i = page
                        if apply({ $0.removePage(i) }) { page = max(0, i - 1) }
                    } label: { Image(systemName: "trash") }
                        .accessibilityLabel("删除这一页")
                }
                Spacer()
                Button("完成") {
                    picked = nil
                    _ = apply { $0.heal() }
                    withAnimation(.easeOut(duration: 0.2)) { editing = false }
                }
                .buttonStyle(.bordered)
            }
            .foregroundStyle(home.text)
        }
        .padding(.horizontal, HomeLook.sidePad)
        .padding(.bottom, 4)
    }

    @ViewBuilder private func cell(_ c: Shell.Cell, size: CGFloat) -> some View {
        let tile = size * HomeLook.tileRatio * home.tileScale
        switch c.kind {
        case "app":
            if let look = Shell.look(c.ref, settings: settings) {
                Button { open(c.ref) } label: {
                    labeled(AppTileView(look: look, size: tile, badge: c.ref == "chat" ? unread : 0, home: home).zoomSource(c.ref, zoom),
                            name: look.name, show: Shell.showLabel(c.label.isEmpty ? look.label : c.label, settings: settings))
                }
                .buttonStyle(TilePress())
                .accessibilityLabel(look.name)
                .contextMenu { iconMenu(c.ref) }
            }
        case "folder":
            Button { folder = c } label: {
                labeled(FolderTileView(cell: c, settings: settings, size: tile, home: home),
                        name: c.name.isEmpty ? "文件夹" : c.name, show: Shell.showLabel(c.label, settings: settings))
            }
            .buttonStyle(TilePress())
            .contextMenu { Button { enterEdit() } label: { Label("整理主屏幕", systemImage: "square.grid.2x2") } }
        default:
            VStack(spacing: 5) {
                HomeWidget(cell: c, home: home, open: open, openChat: openChat)
                if !c.title.isEmpty {
                    Text(c.title).font(.system(size: 11)).lineLimit(1).foregroundStyle(home.nameColor)
                }
            }
            .contextMenu { Button { enterEdit() } label: { Label("整理主屏幕", systemImage: "square.grid.2x2") } }
        }
    }

    private func labeled<V: View>(_ tile: V, name: String, show: Bool) -> some View {
        VStack(spacing: 5) {
            tile
            if show {
                Text(name).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(home.nameColor)
                    .shadow(color: home.wallpaper ? .black.opacity(0.55) : .clear, radius: 1.5, y: 1)
            }
        }
        .frame(maxHeight: .infinity, alignment: show ? Alignment.top : Alignment.center)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(layout.pages.indices, id: \.self) { i in
                Circle()
                    .fill(i == page ? (home.wallpaper ? Color.white : Theme.secondaryText)
                                    : (home.wallpaper ? Color.white.opacity(0.45) : Color(uiColor: .systemGray4)))
                    .frame(width: 6, height: 6)
                    .onTapGesture { withAnimation { page = i } }
                    .accessibilityLabel("第\(i + 1)页")
            }
        }
        .padding(.vertical, 12)
        .opacity(layout.pages.count > 1 ? 1 : 0)
    }

    /// 底栏（网页版 Dock）：只排有 app 的几格，胶囊按个数收窄、居中。整理时四格都画出来，空的也能放
    private func dock(tile: CGFloat, width: CGFloat) -> some View {
        let slots = layout.dock.enumerated().map { i, id in DockSlot(id: i, look: id.flatMap { Shell.look($0, settings: settings) }) }
        let shown = editing ? slots : slots.filter { $0.look != nil }
        let inner = width - HomeLook.sidePad * 2
        let slotW = (inner - 24 - 2 - 3 * 8) / 4
        let n = CGFloat(max(1, shown.count))
        return HStack(spacing: 8) {
            ForEach(shown) { d in
                dockSlot(d.id, look: d.look, tile: tile, slotW: slotW)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(width: n * slotW + (n - 1) * 8 + 24 + 2)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(home.dockBg))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(home.capsuleBorder, lineWidth: 1))
        .opacity(shown.isEmpty ? 0 : 1)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder private func dockSlot(_ i: Int, look: Shell.Look?, tile: CGFloat, slotW: CGFloat) -> some View {
        if editing {
            let isPicked = picked == .dock(i)
            Group {
                if let look {
                    AppTileView(look: look, size: tile, home: home)
                        .scaleEffect(isPicked ? 0.86 : 0.94)
                        .overlay { if isPicked { RoundedRectangle(cornerRadius: tile * 0.24).strokeBorder(home.text, lineWidth: 1.5) } }
                        .draggable("dock:\(i)")
                } else {
                    RoundedRectangle(cornerRadius: tile * 0.24, style: .continuous)
                        .strokeBorder(home.subText.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(width: tile, height: tile)
                }
            }
            .frame(width: slotW, height: tile)
            .contentShape(Rectangle())
            .onTapGesture {
                if let p = picked {
                    if p == .dock(i) { picked = nil } else { move(p, to: .dock(i)) }
                } else if let look {
                    target = .dock(i, app: look.id)
                }
            }
            .dropDestination(for: String.self) { items, _ in drop(items.first, to: .dock(i)) }
        } else if let look {
            let named = Shell.showLabel(look.label, inDock: true, settings: settings)
            Button { open(look.id) } label: {
                VStack(spacing: 5) {
                    AppTileView(look: look, size: tile, badge: look.id == "chat" ? unread : 0, home: home)
                        .zoomSource(look.id, zoom)
                    if named { Text(look.name).font(.system(size: 11)).lineLimit(1).foregroundStyle(home.nameColor) }
                }
                .frame(width: slotW)
            }
            .buttonStyle(TilePress())
            .accessibilityLabel(look.name)
            .contextMenu { iconMenu(look.id) }
        }
    }
}

/// 按下去缩一点（网页版 .cell-app:active .app-tile { scale(.93) }）。
struct TilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 文件夹：一格里四个缩小的图标；换过封面就显示封面（网页版 FolderTile）。
struct FolderTileView: View {
    let cell: Shell.Cell
    let settings: [String: JSONValue]
    let size: CGFloat
    let home: HomeLook

    var body: some View {
        if !cell.coverImageId.isEmpty || !cell.coverIcon.isEmpty {
            AppTileView(look: Shell.Look(id: cell.id, name: cell.name, icon: cell.coverIcon.isEmpty ? "folder" : cell.coverIcon,
                                         imageId: cell.coverImageId, scale: 0, bare: false, label: ""),
                        size: size, home: home)
        } else {
            let looks = cell.apps.compactMap { Shell.look($0, settings: settings) }.prefix(4)
            let mini = (size - size * 0.12 * 3) / 2
            LazyVGrid(columns: [GridItem(.fixed(mini), spacing: size * 0.12), GridItem(.fixed(mini))], spacing: size * 0.12) {
                ForEach(Array(looks), id: \.id) { l in
                    AppTileView(look: l, size: mini, home: HomeLook(wallpaper: false, dark: home.dark, s: home.s))
                }
            }
            .padding(size * 0.12)
            .frame(width: size, height: size, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(home.tileBg))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(home.capsuleBorder, lineWidth: 1))
        }
    }
}

/// 点开的文件夹。
struct FolderSheet: View {
    let cell: Shell.Cell
    let settings: [String: JSONValue]
    let home: HomeLook
    var open: (String) -> Void

    var body: some View {
        let looks = cell.apps.compactMap { Shell.look($0, settings: settings) }
        VStack(alignment: .leading, spacing: 20) {
            Text(cell.name.isEmpty ? "文件夹" : cell.name).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 18) {
                ForEach(looks, id: \.id) { l in
                    Button { open(l.id) } label: {
                        VStack(spacing: 5) {
                            AppTileView(look: l, size: 52, home: HomeLook(wallpaper: false, dark: home.dark, s: home.s))
                            Text(l.name).font(.system(size: 11)).lineLimit(1).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .buttonStyle(TilePress())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

/// 小组件。原生版先做了播放器横条、文字块、图片块与最近会话；其余的先画一块空卡片占住位置。
struct HomeWidget: View {
    let cell: Shell.Cell
    let home: HomeLook
    var open: (String) -> Void
    var openChat: (String) -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(cell.config["bare"]?.bool == true ? Color.clear : home.widgetBg))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(home.capsuleBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(home.wallpaper ? 0 : (home.dark ? 0.6 : 0.10)), radius: 8, y: 4)
    }

    @ViewBuilder private var content: some View {
        switch cell.ref {
        case "player": player
        case "note": note
        case "photo": photo
        case "recent-chats": RecentChatsWidget(home: home, open: open, openChat: openChat)
        default:
            Text("此组件暂未支持").font(.system(size: 12)).foregroundStyle(home.subText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func str(_ k: String) -> String { cell.config[k]?.string ?? "" }

    private func lineFont(_ size: String) -> Font {
        let serif = cell.config["serif"]?.bool == true
        let pt: CGFloat = size == "lg" ? 20 : size == "md" ? 15 : 12
        return .system(size: pt, weight: size == "lg" ? .medium : .regular, design: serif ? .serif : .default)
    }

    private static let defaultSizes = ["1": "lg", "2": "sm", "3": "sm"]

    private var lines: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(["1", "2", "3"], id: \.self) { n in
                let t = str("line\(n)")
                if !t.isEmpty {
                    Text(t).font(lineFont(cell.config["size\(n)"]?.string ?? Self.defaultSizes[n] ?? "sm"))
                        .foregroundStyle(n == "1" ? home.text : home.subText).lineLimit(2)
                }
            }
        }
    }

    private var player: some View {
        let cover = str("cover")
        let empty = cover.isEmpty && ["1", "2", "3"].allSatisfy { str("line\($0)").isEmpty }
        return HStack(spacing: 14) {
            if !cover.isEmpty {
                LocalImage(id: cover, maxPixel: 300).aspectRatio(1, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if empty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Date(), format: .dateTime.month().day()).font(.system(size: 20, weight: .medium)).foregroundStyle(home.text)
                    Text(Date(), format: .dateTime.weekday(.wide)).font(.system(size: 12)).foregroundStyle(home.subText)
                }
            } else {
                lines
            }
            Spacer(minLength: 0)
            SvgIcon(name: "music", size: 18, color: home.subText).frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .multilineTextAlignment(cell.config["align"]?.string == "right" ? .trailing : .leading)
    }

    private var note: some View {
        lines.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var photo: some View {
        let id = str("cover")
        return ZStack(alignment: .bottomLeading) {
            if id.isEmpty {
                SvgIcon(name: "image", size: 24, color: home.subText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LocalImage(id: id, maxPixel: 900)
            }
            if !str("line1").isEmpty {
                Text(str("line1")).font(.system(size: 12)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2).padding(12)
            }
        }
    }
}

/// 最近会话：当前身份最近的两段，点哪一行进哪一段（网页版 recent-chats）。
struct RecentChatsWidget: View {
    let home: HomeLook
    var open: (String) -> Void
    var openChat: (String) -> Void

    struct Row: Identifiable { var id: String; var title: String; var sub: String }
    @State private var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SvgIcon(name: "message", size: 15, color: home.subText)
                Text("最近会话").font(.system(size: 12)).foregroundStyle(home.subText)
            }
            if rows.isEmpty {
                Text("还没有会话").font(.system(size: 12)).foregroundStyle(home.subText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
                ForEach(rows) { r in
                    Button { openChat(r.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.system(size: 14, weight: .medium)).foregroundStyle(home.text).lineLimit(1)
                            Text(r.sub).font(.system(size: 12)).foregroundStyle(home.subText).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture { open("chat") }
        .task { load() }
        .onReceive(NotificationCenter.chatChangesSettled) { _ in load() }
    }

    private func load() {
        let s = AppSettings.load()
        let active = s.raw["activePersonaId"]?.string ?? ""
        var chats = ((try? Repo.chats()) ?? []).sorted { $0.lastMessageAt > $1.lastMessageAt }
        let mine = chats.filter { $0.personaId == active }
        if !active.isEmpty && !mine.isEmpty { chats = mine }
        rows = chats.prefix(2).map { c in
            let first = c.characterIds.first.flatMap { try? Repo.character($0) }
            let title = c.isGroup ? (c.title.isEmpty ? "群聊" : c.title) : (first?.displayName ?? (c.title.isEmpty ? "会话" : c.title))
            let last = (try? Repo.messages(chatId: c.id, limit: 1))?.last
            let sub = last.map { $0.isRecalled ? "撤回了一条消息" : $0.content } ?? ""
            return Row(id: c.id, title: title, sub: sub)
        }
    }
}
