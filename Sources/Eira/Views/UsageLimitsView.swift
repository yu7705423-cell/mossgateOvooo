import SwiftUI

/// 「设置 - 用量与上限」：会多花钱的旋钮集中在这一页（网页版第 13、15 条）。
/// 键名与取值范围和网页版一致，导入的设置直接生效。
struct UsageLimitsView: View {
    @State private var retryMax = 0
    @State private var chatFallback = false
    @State private var failoverMax = 1
    @State private var historyLimit = 20
    @State private var today = 0
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("今天已发出的请求", value: "\(today) 次")
            } footer: {
                Text("每次实际发出的请求都计入，失败的也计入。")
            }

            Section {
                Stepper("自动重试：\(retryMax) 次", value: $retryMax, in: 0...3)
            } footer: {
                Text("接口限流或服务端出错时自动再请求一次，每次重试另行计费。设为 0 时失败即停止。最多 3 次。")
            }

            Section {
                Toggle("失败后改用其他接口", isOn: $chatFallback)
                if chatFallback {
                    Stepper(failoverMax == 0 ? "最多改用：全部" : "最多改用：\(failoverMax) 套", value: $failoverMax, in: 0...20)
                }
            } footer: {
                Text("开启后，一套接口请求失败时按主用、副用、其余的顺序改用下一套，每改用一次另行计费。已收到部分回复或手动停止时不改用。设为 0 表示其余接口全部尝试。")
            }

            Section {
                Stepper(historyLimit == 0 ? "携带的历史：全部" : "携带的历史：\(historyLimit) 条", value: $historyLimit, in: 0...2000, step: 10)
            } footer: {
                Text("每次请求附带最近多少条消息。条数越多，每次请求的用量越大。设为 0 表示附带全部历史。")
            }

            if let problem {
                Section { Text(problem).foregroundStyle(Theme.danger) }
            }
        }
        .navigationTitle("用量与上限")
        .onAppear(perform: load)
        .onChange(of: retryMax) { _, _ in save() }
        .onChange(of: chatFallback) { _, _ in save() }
        .onChange(of: failoverMax) { _, _ in save() }
        .onChange(of: historyLimit) { _, _ in save() }
    }

    private func load() {
        let s = AppSettings.load()
        retryMax = s.retryMax
        chatFallback = s.chatFallback
        failoverMax = s.failoverMax
        historyLimit = Int(s.num("historyLimit", 20))
        Task { let n = await Usage.shared.today(); await MainActor.run { today = n } }
    }

    /// 只写用户改过的那几项。刚打开页面时 load 赋值也会触发 onChange，那时和库里一样，不写。
    private func save() {
        var s = AppSettings.load()
        var changed = false
        func set(_ key: String, _ value: JSONValue, _ current: JSONValue) {
            if value != current { s.raw[key] = value; changed = true }
        }
        set("retryMax", .number(Double(retryMax)), .number(Double(s.retryMax)))
        set("chatFallback", .bool(chatFallback), .bool(s.chatFallback))
        set("failoverMax", .number(Double(failoverMax)), .number(Double(s.failoverMax)))
        set("historyLimit", .number(Double(historyLimit)), .number(s.num("historyLimit", 20)))
        guard changed else { return }
        do { try s.save(); problem = nil }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}
