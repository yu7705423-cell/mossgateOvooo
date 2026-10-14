import SwiftUI

/// 首页：消息与设置两页。写入失败之类的问题在最上面横一条（网页版第 20 条：不许只记日志）。
struct RootView: View {
    @ObservedObject private var problems = Problems.shared
    @ObservedObject private var settings = SettingsModel.shared
    @State private var onboarding = OnboardingView.needed()
    @State private var tab = 0
    @ObservedObject private var notifier = Notifier.shared

    var body: some View {
        TabView(selection: $tab) {
            ChatListView()
                .tabItem { Label("消息", systemImage: "bubble.left") }.tag(0)
            ContactsView()
                .tabItem { Label("联系", systemImage: "person.2") }.tag(1)
            CanonView()
                .tabItem { Label("设定集", systemImage: "books.vertical") }.tag(2)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(3)
        }
        // 点了通知：回到「消息」，由会话列表打开那一段
        .onChange(of: notifier.openChat) { _, id in if id != nil { tab = 0 } }
        .fullScreenCover(isPresented: $onboarding) {
            OnboardingView { onboarding = false; settings.reload() }
        }
        .preferredColorScheme(AppearanceView.scheme(settings.s))
        .safeAreaInset(edge: .top) {
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
}

#Preview {
    RootView()
}
