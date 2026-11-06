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
                HelpNote("诊断信息包括版本、设备型号、各类数据的条数、接口的格式与模型名，以及最近 \(Diagnostics.limit) 条请求、导入、错误与闪退记录。不包括聊天内容、人设、记忆、提示词、密钥与接口地址。导出前可在下方查看全文。")
            }

            if let problem {
                Section { Text(problem).foregroundStyle(Theme.danger) }
            }

            Section("全文") {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            WebPromptLabSection()

            Section {
                Button("清空诊断记录", role: .destructive) { confirmClear = true }.foregroundStyle(Theme.dangerText)
            } footer: {
                HelpNote("只清空上方的记录，不影响聊天与其他数据。")
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

/// 「问题反馈」里的「试验」一组（docs/jscore-prompt.md）：一对一聊天的提示词改由网页版的代码拼装。默认关。
/// 这一版 app 里没有网页版的拼装脚本（编译时没取到网页版代码）时整组不出现
struct WebPromptLabSection: View {
    @State private var on = WebPrompt.isOn
    @State private var result: String?
    @State private var problem: String?
    @State private var running = false

    var body: some View {
        if WebPrompt.available {
            Section {
                Toggle("提示词按网页版拼装", isOn: Binding(get: { on }, set: { v in
                    do { try WebPrompt.setOn(v); on = v; problem = nil }
                    catch { problem = "无法保存开关：\(error.localizedDescription)" }
                }))
                Button(running ? "正在测量" : "测量一次拼装耗时") { measure() }.disabled(running)
                if let result {
                    Text(result).font(.caption).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
                }
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
            } header: {
                Text("试验")
            } footer: {
                HelpNote("开启后，一对一聊天的回复改由网页版的代码拼装提示词；拼装失败、或本轮要把图片原图交给聊天模型时，仍由原生版拼装。通话、主动消息、群聊与线下不受影响。测量时用最近一段一对一会话各拼装一次，不调用接口。")
            }
        }
    }

    private func measure() {
        running = true
        result = nil
        Task.detached {
            let text = Self.measureText()
            await MainActor.run { result = text; running = false }
        }
    }

    nonisolated private static func measureText() -> String {
        do {
            guard let chat = try Repo.chats().filter({ !$0.isGroup }).max(by: { $0.lastMessageAt < $1.lastMessageAt }),
                  let char = try Repo.character(chat.characterIds.first ?? "") else { return "没有可用于测量的一对一会话。" }
            let s = AppSettings.load()
            var start = Date()
            let native = try ChatPrompt.build(chat: chat, char: char, settings: s)
            let nativeMs = Date().timeIntervalSince(start) * 1000
            start = Date()
            guard let web = WebPrompt.shared.build(chat: chat, char: char) else {
                return "网页版拼装失败：\(WebPrompt.shared.lastError ?? "原因未知")"
            }
            let webMs = Date().timeIntervalSince(start) * 1000
            let t = web.timing
            func ms(_ v: Double) -> String { String(format: "%.0f", v) }
            return "原生版 \(ms(nativeMs)) 毫秒；网页版 \(ms(webMs)) 毫秒（读库 \(ms(t.read * 1000))、灌表 \(ms(t.feed * 1000))、"
                + "换表 \(ms(t.refill * 1000))、拼装 \(ms(t.build * 1000))），共 \(t.rows) 行、\(t.bytes / 1024) KB；"
                + "脚本加载 \(ms(WebPrompt.shared.loadSeconds * 1000)) 毫秒。两版不一致 \(WebPrompt.compare(native: native, web: web).count) 处，"
                + "构建失败的区块 \(web.failed.count) 个。网页版提交 \(String(web.commit.prefix(10)))。"
        } catch {
            return "测量失败：\(error.localizedDescription)"
        }
    }
}
