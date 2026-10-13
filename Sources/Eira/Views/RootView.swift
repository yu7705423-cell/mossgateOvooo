import SwiftUI

/// 骨架阶段的首页：导入网页版备份，看本地库里有什么。
struct RootView: View {
    @State private var counts: [String: Int] = [:]
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("导入网页版备份") {
                        ImportView(onDone: reload)
                    }
                }
                Section("本地数据") {
                    if let loadError {
                        Text(loadError).foregroundStyle(.red)
                    } else if counts.isEmpty {
                        Text("暂无数据").foregroundStyle(.secondary)
                    } else {
                        ForEach(Self.shown) { item in
                            LabeledContent(item.label, value: "\(counts[item.key] ?? 0)")
                        }
                        LabeledContent("其余数据域", value: "\(otherCount)")
                    }
                }
            }
            .navigationTitle("Eiraowo")
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
