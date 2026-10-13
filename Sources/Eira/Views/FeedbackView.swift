import SwiftUI
import UIKit

/// 「设置 - 问题反馈」：把诊断信息导出成一个文本文件，发给开发者。
struct FeedbackView: View {
    @State private var text = ""
    @State private var file: URL?
    @State private var copied = false
    @State private var confirmClear = false
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                if let file {
                    ShareLink(item: file) { Label("导出诊断信息", systemImage: "square.and.arrow.up") }
                }
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制诊断信息", systemImage: "doc.on.doc")
                }
            } footer: {
                Text("诊断信息包括版本、设备型号、各类数据的条数、接口的格式与模型名，以及最近 \(Diagnostics.limit) 条请求、导入、错误与闪退记录。不包括聊天内容、人设、记忆、提示词、密钥与接口地址。导出前可在下方查看全文。")
            }

            if let problem {
                Section { Text(problem).foregroundStyle(Theme.danger) }
            }

            Section("全文") {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section {
                Button("清空诊断记录", role: .destructive) { confirmClear = true }
            } footer: {
                Text("只清空上方的记录，不影响聊天与其他数据。")
            }
        }
        .navigationTitle("问题反馈")
        .onAppear(perform: refresh)
        .confirmationDialog("清空后无法恢复。", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                Diagnostics.shared.clear()
                refresh()
            }
        }
    }

    private func refresh() {
        text = Diagnostics.shared.report()
        copied = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Eiraowo-诊断信息.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            file = url
            problem = nil
        } catch {
            file = nil
            problem = "无法生成诊断文件：\(error.localizedDescription)。可改用「复制诊断信息」。"
        }
    }
}
