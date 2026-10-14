import SwiftUI

/// 首页：消息与设置两页。写入失败之类的问题在最上面横一条（网页版第 20 条：不许只记日志）。
struct RootView: View {
    @ObservedObject private var problems = Problems.shared
    @ObservedObject private var settings = SettingsModel.shared
    @State private var onboarding = OnboardingView.needed()

    var body: some View {
        TabView {
            ChatListView()
                .tabItem { Label("消息", systemImage: "bubble.left") }
            ContactsView()
                .tabItem { Label("联系", systemImage: "person.2") }
            CanonView()
                .tabItem { Label("设定集", systemImage: "books.vertical") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
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
