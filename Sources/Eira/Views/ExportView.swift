import SwiftUI

/// 「设置 - 导出备份」：导出成网页版能恢复的备份。
struct ExportView: View {
    @State private var media = true
    @State private var keys = false
    @State private var password = ""
    @State private var running = false
    @State private var progress = 0.0
    @State private var result: BackupExporter.Result?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Toggle("包含图片与文件", isOn: $media)
            } footer: {
                HelpNote(media ? "导出为 ZIP，网页版恢复后图片与文件齐全。" : "只导出数据，为一份 JSON 文件；网页版恢复后图片与文件缺失。")
            }
            Section {
                Toggle("包含接口与密钥", isOn: $keys)
            } footer: {
                Text(keys ? "文件中含有接口密钥。发给他人或放进网盘时，等于交出了密钥。" : "不含接口与密钥。在网页版恢复后，网页版现有的接口设置保持不变。")
                    .foregroundStyle(keys ? Theme.danger : Theme.secondaryText)
            }
            Section {
                SecureField("备份口令（可留空）", text: $password)
            } footer: {
                Text("口令丢失则无法解开。")
                HelpNote("填写后整份加密，恢复时须输入同一口令。口令丢失则无法解开，没有其他办法找回。", title: "加密口令")
            }
            Section {
                Button(running ? "正在导出" : "导出", action: start).disabled(running)
                if running { ProgressView(value: progress) }
            } footer: {
                Text("恢复会替换网页版里现有的全部数据。")
                HelpNote("在网页版「设置 - 存储」中恢复这份文件。恢复会替换网页版里现有的全部数据。", title: "导出")
            }
            if let result {
                Section("导出完成") {
                    LabeledContent("记录", value: "\(result.rows)")
                    LabeledContent("图片与文件", value: "\(result.media)")
                    LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file))
                    ShareLink(item: result.file) { Label("存储或发送这份文件", systemImage: "square.and.arrow.up") }
                }
            }
            if let problem { Section("导出失败") { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("导出备份")
    }

    private func start() {
        running = true
        progress = 0
        result = nil
        problem = nil
        let options = BackupExporter.Options(media: media, keys: keys, password: password)
        Task.detached(priority: .userInitiated) {
            do {
                let r = try BackupExporter.run(options) { p in Task { @MainActor in progress = p } }
                await MainActor.run { result = r; running = false }
            } catch {
                let message = error.localizedDescription
                Diagnostics.shared.record("export-failed", ["error": message])
                await MainActor.run { problem = message; running = false }
            }
        }
    }
}
