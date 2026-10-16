import SwiftUI

/// 外壳（网页版 shell/Root.js）：主屏上点图标，app 整屏打开；底部那一条点一下或往上一推回到主屏。
/// 写入失败之类的问题在最上面横一条（网页版第 20 条：不许只记日志）。
struct RootView: View {
    @ObservedObject private var settings = SettingsModel.shared
    @ObservedObject private var notifier = Notifier.shared
    @State private var onboarding = OnboardingView.needed()
    @State private var layout = Shell.layout()
    @State private var opened: OpenedApp?
    @State private var unread = Shell.chatUnread()
    /// 锁屏：打开应用时先显示（网页版 showLockScreen，没写过按开启）
    @State private var locked = AppSettings.load().raw["showLockScreen"]?.bool != false || PinLock.hasPin()
    /// 打开 app 时从那个图标放大出来、关上时缩回去（iOS 18 起）
    @Namespace private var appZoom

    struct OpenedApp: Identifiable { var id: String }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !layout.wallpaperHome.isEmpty {
                GeometryReader { g in
                    LocalImage(id: layout.wallpaperHome, maxPixel: max(g.size.width, g.size.height) * 3)
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
            }
            HomeScreen(layout: layout, settings: settings.s.raw, unread: unread, zoom: appZoom,
                       open: { opened = OpenedApp(id: $0) },
                       openChat: { id in notifier.openChat = id },
                       changed: { layout = Shell.layout() })
        }
        // 换了配色或字号：主屏整个重画一遍，取色时读到新的那一套。打开的 app 下次打开时换上
        .id("\(Palette.key)|\(Palette.fontScale)|\(Fonts.key)")
        .overlay {
            if locked && !onboarding {
                LockScreenView(wallpaper: layout.wallpaperLock) { chat in
                    withAnimation(.easeOut(duration: 0.25)) { locked = false }
                    // 锁着时点了系统通知的那一段，解锁之后正好落在那儿
                    if let pending = chat ?? notifier.openChat {
                        notifier.openChat = pending
                        if opened?.id != "chat" { opened = OpenedApp(id: "chat") }
                    }
                }
                .transition(.move(edge: .top))
                .zIndex(1)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ProblemBanner() }
        // 点了通知或主屏的会话：打开聊天，由会话列表打开那一段
        .onChange(of: notifier.openChat) { _, id in
            guard id != nil else { return }
            // 设了锁屏密码：等解锁之后再打开（网页版 pinlock：门挂在外壳上）
            if locked && PinLock.hasPin() { return }
            locked = false
            if opened?.id != "chat" { opened = OpenedApp(id: "chat") }
        }
        .fullScreenCover(item: $opened, onDismiss: refresh) { app in
            AppHost(appId: app.id) { opened = nil }
                .eiraLook()
                .preferredColorScheme(AppearanceView.scheme(settings.s))
                .zoomFrom(app.id, appZoom)
        }
        .fullScreenCover(isPresented: $onboarding, onDismiss: refresh) {
            OnboardingView { onboarding = false; settings.reload() }.eiraLook()
        }
        .onReceive(NotificationCenter.chatChangesSettled) { _ in unread = Shell.chatUnread() }
        // 主屏自己的整理流程之外改了版式（自定义组件存数据、点空的自定义组件改内容）：重读一遍
        .onReceive(NotificationCenter.default.publisher(for: .eiraHomeLayoutChanged)) { _ in layout = Shell.layout() }
        .preferredColorScheme(AppearanceView.scheme(settings.s))
    }

    /// 从 app 回到主屏：导入备份、改了外观都可能换掉版式与壁纸，重读一遍。
    private func refresh() {
        // 定时寄出的信：到点了就寄（投递时间用当初定的时刻）
        Space.deliverDue()
        settings.reload()
        layout = Shell.layout()
        unread = Shell.chatUnread()
    }
}

/// 一个整屏打开的 app。原生版还没做的，显示一页说明。
struct AppHost: View {
    let appId: String
    var close: () -> Void

    var body: some View {
        // 横条画在屏幕最底下系统横条那一块（安全区以下），不占页面的地方：从前用 safeAreaInset 垫了一块白底，
        // 页面底下多出一截，iOS 26 放在底部的搜索框被它压住
        GeometryReader { g in
            let inset = g.safeAreaInsets.bottom
            content
                .frame(width: g.size.width, height: g.size.height)
                .overlay(alignment: .bottom) {
                    HomeBar(height: max(inset, 20), close: close).offset(y: inset)
                }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ProblemBanner() }
        .persistentSystemOverlays(.hidden)
        // 左缘右滑：关掉弹出来的那一层，或者在第一页时回到主屏
        .background(EdgeBack(close: close))
    }

    @ViewBuilder private var content: some View {
        switch appId {
        case "chat": ChatAppView()
        case "contact": ContactsView()
        case "preset": CanonView()
        case "settings": SettingsView()
        case "diary": NavigationStack { DiaryHomeView() }
        case "daily": NavigationStack { DailyHomeView() }
        case "music": NavigationStack { MusicHomeView() }
        case "album": NavigationStack { AlbumHomeView() }
        case "space": NavigationStack { SpaceHomeView() }
        case "health": NavigationStack { HealthHomeView() }
        case "theirs": NavigationStack { TheirsPickView() }
        default: UnsupportedAppView(name: Shell.app(appId)?.name ?? appId)
        }
    }
}

/// 底部那一条（网页版 .home-indicator）：点一下回到主屏。
/// 只占屏幕最底下系统横条那一块（安全区以下），透明、不垫底色，页面内容照旧铺到它上面为止。
/// 系统自己的横条在 app 打开时藏起来，同一个位置不放两条。往上推仍归系统（回到手机桌面）。
struct HomeBar: View {
    var height: CGFloat
    var close: () -> Void

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.35))
            .frame(width: 108, height: 4)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .frame(height: height)
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .accessibilityElement()
            .accessibilityLabel("返回主屏")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { close() }
    }
}

struct UnsupportedAppView: View {
    let name: String

    var body: some View {
        NavigationStack {
            ScrollView {
                EmptyState(title: "「\(name)」尚未支持",
                           desc: "原生版暂未完成该应用。导入的数据已完整保存，完成后即可在此查看；在此之前可在网页版中使用。")
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 写入失败等问题的横条。
struct ProblemBanner: View {
    @ObservedObject private var problems = Problems.shared

    var body: some View {
        if let latest = problems.latest {
            HStack {
                Text(latest).font(.footnote).foregroundStyle(Theme.danger)
                Spacer()
                Button("关闭") { problems.latest = nil }.font(.footnote)
            }
            .padding(Theme.pad)
            .background(Theme.groupedBackground)
        }
    }
}

#Preview {
    RootView()
}

extension View {
    /// 打开 app 的动画从这个图标起（iOS 18 起；更早的系统照旧从下往上推）
    @ViewBuilder func zoomSource(_ id: String, _ ns: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let ns {
            matchedTransitionSource(id: id, in: ns)
        } else {
            self
        }
    }

    /// 整屏打开的 app 从对应的图标放大出来，关上时缩回图标
    @ViewBuilder func zoomFrom(_ id: String, _ ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: ns))
        } else {
            self
        }
    }
}
