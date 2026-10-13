import SwiftUI

/// 第一次打开：导入网页版的备份，或者从空白开始；再填一套接口。
///
/// 只在库里一条数据都没有、也没走过这一步时出现。读库失败时不出现、也不写任何东西（网页版第 20 条：
/// 读不到不等于没有，拿「没有」去回写会盖掉真的数据）。
struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var step = 0
    @State private var problem: String?

    static let doneKey = "nativeOnboarded"

    /// 要不要出现。读失败一律当作不要。
    static func needed() -> Bool {
        do {
            if try Database.shared.kv(doneKey)?.bool == true { return false }
            return try Database.shared.counts().isEmpty
        } catch {
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if step == 0 {
                    Section {
                        Text("Eiraowo 是小手机的原生版测试版，与网页版并行。原生版的数据与网页版互不相通：从网页版导入的是一份副本，网页版的数据不受影响。")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Section {
                        NavigationLink("导入网页版备份") {
                            ImportView(onDone: { step = 1 })
                        }
                        Button("从空白开始") {
                            do { _ = try People.ensureActivePersona(); step = 1 }
                            catch { problem = error.localizedDescription }
                        }
                    } footer: {
                        Text("在网页版「设置 - 存储」中导出备份，再在此处选择那份文件。")
                    }
                } else {
                    Section {
                        NavigationLink("填写接口") { ApiSettingsView() }
                    } footer: {
                        Text("聊天需要一套接口。导入的备份若含有接口设置，可以跳过这一步。之后也可以在「设置 - 接口」中填写。")
                    }
                    Section {
                        Button("开始使用", action: finish)
                    }
                }
                if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
            }
            .navigationTitle(step == 0 ? "欢迎" : "接口")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("跳过", action: finish)
                }
            }
        }
    }

    private func finish() {
        do {
            try Database.shared.setKV(Self.doneKey, .bool(true))
            onFinish()
        } catch {
            problem = "无法保存：\(error.localizedDescription)"
        }
    }
}
