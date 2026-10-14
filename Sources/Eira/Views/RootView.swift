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
            HomeScreen(layout: layout, settings: settings.s.raw, unread: unread,
                       open: { opened = OpenedApp(id: $0) },
                       openChat: { id in notifier.openChat = id })
        }
        .safeAreaInset(edge: .top, spacing: 0) { ProblemBanner() }
        // 点了通知或主屏的会话：打开聊天，由会话列表打开那一段
        .onChange(of: notifier.openChat) { _, id in
            if id != nil, opened?.id != "chat" { opened = OpenedApp(id: "chat") }
        }
        .fullScreenCover(item: $opened, onDismiss: refresh) { app in
            AppHost(appId: app.id) { opened = nil }
                .eiraLook()
                .preferredColorScheme(AppearanceView.scheme(settings.s))
        }
        .fullScreenCover(isPresented: $onboarding, onDismiss: refresh) {
            OnboardingView { onboarding = false; settings.reload() }.eiraLook()
        }
        .onReceive(NotificationCenter.default.publisher(for: .eiraChatChanged)) { _ in unread = Shell.chatUnread() }
        .preferredColorScheme(AppearanceView.scheme(settings.s))
    }

    /// 从 app 回到主屏：导入备份、改了外观都可能换掉版式与壁纸，重读一遍。
    private func refresh() {
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
