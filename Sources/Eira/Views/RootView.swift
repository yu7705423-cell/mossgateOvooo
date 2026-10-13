import SwiftUI

/// 首页：消息与设置两页。写入失败之类的问题在最上面横一条（网页版第 20 条：不许只记日志）。
struct RootView: View {
    @ObservedObject private var problems = Problems.shared
    @State private var onboarding = OnboardingView.needed()

    var body: some View {
        TabView {
            ChatListView()
                .tabItem { Label("消息", systemImage: "bubble.left") }
            ContactsView()
                .tabItem { Label("联系", systemImage: "person.2") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .fullScreenCover(isPresented: $onboarding) {
            OnboardingView { onboarding = false }
        }
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

/// 设置列表只放全局的东西：接口、用量、存储（网页版第 5 条）。
struct SettingsView: View {
    @State private var counts: [String: Int] = [:]
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("接口") { ApiSettingsView() }
                    NavigationLink("用量与上限") { UsageLimitsView() }
                }
                Section {
                    NavigationLink("问题反馈") { FeedbackView() }
                }
                Section("设定") {
                    NavigationLink("世界书") { LorebookListView() }
                }
                Section("存储") {
                    NavigationLink("导入网页版备份") { ImportView(onDone: reload) }
                    NavigationLink("导出备份") { ExportView() }
                }
                Section("本地数据") {
                    if let loadError {
                        Text(loadError).foregroundStyle(Theme.danger)
                    } else if counts.isEmpty {
                        Text("暂无数据").foregroundStyle(Theme.secondaryText)
                    } else {
                        ForEach(Self.shown) { item in
                            LabeledContent(item.label, value: "\(counts[item.key] ?? 0)")
                        }
                        LabeledContent("其余数据域", value: "\(otherCount)")
                    }
                }
            }
            .navigationTitle("设置")
            .onAppear(perform: reload)
        }
    }

    private struct Shown: Identifiable {
        let key: String
        let label: String
        var id: String { key }
    }

    private static let shown: [Shown] = [
        Shown(key: Collections.characters, label: "角色"),
        Shown(key: Collections.chats, label: "会话"),
        Shown(key: Collections.messages, label: "消息"),
        Shown(key: Collections.memories, label: "记忆"),
        Shown(key: Collections.lorebooks, label: "世界书"),
        Shown(key: Collections.personas, label: "我的身份"),
    ]

    private var otherCount: Int {
        let main = Set(Self.shown.map(\.key))
        return counts.filter { !main.contains($0.key) && $0.value > 0 }.count
    }

    private func reload() {
        do {
            counts = try Database.shared.counts()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

#Preview {
    RootView()
}
