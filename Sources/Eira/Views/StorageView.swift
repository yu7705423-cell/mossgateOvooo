import SwiftUI

/// 「设置 - 存储与备份」：占用统计、导入导出、清空数据（网页版 StoragePage）。
struct StorageView: View {
    @State private var counts: [String: Int] = [:]
    @State private var mediaBytes = 0
    @State private var dbBytes = 0
    @State private var loadError: String?
    @State private var confirmWipe = false
    @State private var wipeProblem: String?
    @State private var wiped = false

    var body: some View {
        List {
            Section("占用") {
                if let loadError {
                    Text(loadError).foregroundStyle(Theme.danger)
                } else {
                    LabeledContent("数据", value: Self.size(dbBytes))
                    LabeledContent("图片与文件", value: Self.size(mediaBytes))
                }
            }
            Section("本地数据") {
                if counts.values.allSatisfy({ $0 == 0 }) {
                    Text("暂无数据").foregroundStyle(Theme.secondaryText)
                } else {
                    ForEach(Self.shown) { item in
                        LabeledContent(item.label, value: "\(counts[item.key] ?? 0)")
                    }
                    LabeledContent("其余数据域", value: "\(otherCount)")
                }
            }
            Section {
                NavigationLink("导入网页版备份") { ImportView(onDone: reload) }
                NavigationLink("导出备份") { ExportView() }
            } header: {
                Text("备份")
            } footer: {
                Text("导出的备份可以在网页版「设置 - 存储与备份」中恢复。")
            }
            Section {
                Button("清空全部数据", role: .destructive) { confirmWipe = true }.foregroundStyle(Theme.dangerText)
                if let wipeProblem { Text(wipeProblem).foregroundStyle(Theme.danger) }
                if wiped { Text("已清空。").foregroundStyle(Theme.secondaryText) }
            } footer: {
                Text("角色卡、世界书、记忆、聊天记录等全部数据与图片、文件将全部删除，且无法恢复。接口配置与密钥保留。")
            }
        }
        .navigationTitle("存储与备份")
        .onAppear(perform: reload)
        .confirmationDialog("全部数据与图片、文件将被删除，且无法恢复。接口配置与密钥保留。",
                            isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("全部删除", role: .destructive, action: wipe)
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
            mediaBytes = try Database.shared.mediaBytes()
            let url = Database.defaultURL
            dbBytes = ["", "-wal"].reduce(0) { sum, suffix in
                let path = url.path + suffix
                return sum + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0)
            }
            loadError = nil
        } catch {
            loadError = "读取失败：\(error.localizedDescription)"
        }
        SettingsModel.shared.reload()
    }

    private func wipe() {
        do {
            try Wipe.all()
            wipeProblem = nil
            wiped = true
        } catch {
            wipeProblem = "清空失败，数据未改动：\(error.localizedDescription)"
        }
        reload()
    }

    static func size(_ bytes: Int) -> String {
        let n = Double(max(0, bytes))
        if n < 1024 { return "\(Int(n)) B" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", n / 1024) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1f MB", n / 1024 / 1024) }
        return String(format: "%.2f GB", n / 1024 / 1024 / 1024)
    }
}
