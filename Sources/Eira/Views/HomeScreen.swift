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
struct HomeScreen: View {
    let layout: Shell.Layout
    let settings: [String: JSONValue]
    let unread: Int
    var zoom: Namespace.ID?
    var open: (String) -> Void
    var openChat: (String) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var page = 0
    @State private var folder: Shell.Cell?
    /// 长按图标换图标与名称
    @State private var editingIcon: String?

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
                            grid(p, size: size)
                                .frame(width: g.size.width, height: g.size.height, alignment: .top)
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
                .padding(.top, 12)
                dots
                if !layout.dockHidden { dock(tile: min(tile, cellSize(width: gridW, height: .infinity) * HomeLook.tileRatio * home.tileScale), width: geo.size.width) }
            }
        }
        .onAppear { page = min(max(0, layout.currentPage), layout.pages.count - 1) }
        .sheet(item: Binding(get: { editingIcon.map { IconTarget(id: $0) } }, set: { editingIcon = $0?.id })) { t in
            NavigationStack { IconEditView(appId: t.id) { editingIcon = nil } }
        }
        .sheet(item: $folder) { f in
            FolderSheet(cell: f, settings: settings, home: home) { id in folder = nil; open(id) }
                .presentationDetents([.medium])
        }
    }

    struct IconTarget: Identifiable { var id: String }

    @ViewBuilder private func iconMenu(_ appId: String) -> some View {
        Button { editingIcon = appId } label: { Label("更换图标与名称", systemImage: "paintbrush") }
    }

    /// 格子边长（网页版 HomeScreen 的 measure）：先按宽度均分，再看这个高度放不放得下所有页里最高的那一页。
    private func cellSize(width: CGFloat, height: CGFloat) -> CGFloat {
        let gap = HomeLook.gap
        let byW = (width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        guard height.isFinite, height > 0 else { return max(44, byW.rounded(.down)) }
        let fitRows = max(4, Int(((height + gap) / (byW + gap)).rounded(.down)))
        let need = layout.pages.map { p in max(6, p.cells.map { $0.y + $0.h }.max() ?? 0) }.max() ?? 6
        let rows = max(need, fitRows)
        let byH = (height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return max(44, min(byW, byH).rounded(.down))
    }

    private func grid(_ p: Shell.Page, size: CGFloat) -> some View {
        let gap = HomeLook.gap
        let total = CGFloat(cols) * size + CGFloat(cols - 1) * gap
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: total, height: 1)
            ForEach(p.cells.filter { $0.x + $0.w <= cols }) { c in
                cell(c, size: size)
                    .frame(width: CGFloat(c.w) * size + CGFloat(c.w - 1) * gap,
                           height: CGFloat(c.h) * size + CGFloat(c.h - 1) * gap, alignment: .top)
                    .offset(x: CGFloat(c.x) * (size + gap), y: CGFloat(c.y) * (size + gap))
            }
        }
        .frame(width: total, alignment: .topLeading)
    }

    @ViewBuilder private func cell(_ c: Shell.Cell, size: CGFloat) -> some View {
        let tile = size * HomeLook.tileRatio * home.tileScale
        switch c.kind {
        case "app":
            if let look = Shell.look(c.ref, settings: settings) {
                Button { open(c.ref) } label: {
                    labeled(AppTileView(look: look, size: tile, badge: c.ref == "chat" ? unread : 0, home: home).zoomSource(c.ref, zoom),
                            name: look.name, show: Shell.showLabel(look.label, settings: settings))
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
        default:
            HomeWidget(cell: c, home: home, open: open, openChat: openChat)
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

    /// 底栏（网页版 Dock）：只排有 app 的几格，胶囊按个数收窄、居中。
    private func dock(tile: CGFloat, width: CGFloat) -> some View {
        let shown = layout.dock.compactMap { $0 }.compactMap { Shell.look($0, settings: settings) }
        let inner = width - HomeLook.sidePad * 2
        let slotW = (inner - 24 - 2 - 3 * 8) / 4
        let n = CGFloat(max(1, shown.count))
        let named = shown.map { Shell.showLabel($0.label, inDock: true, settings: settings) }
        return HStack(spacing: 8) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, look in
                Button { open(look.id) } label: {
                    VStack(spacing: 5) {
                        AppTileView(look: look, size: tile, badge: look.id == "chat" ? unread : 0, home: home)
                            .zoomSource(look.id, zoom)
                        if named[i] { Text(look.name).font(.system(size: 11)).lineLimit(1).foregroundStyle(home.nameColor) }
                    }
                    .frame(width: slotW)
                }
                .buttonStyle(TilePress())
                .accessibilityLabel(look.name)
                .contextMenu { iconMenu(look.id) }
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
