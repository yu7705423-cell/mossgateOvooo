import SwiftUI
import UniformTypeIdentifiers

/// 导入网页版「设置 - 存储」导出的备份。
struct ImportView: View {
    var onDone: () -> Void

    @State private var picking = false
    @State private var file: URL?
    @State private var password = ""
    @State private var needPass = false
    @State private var running = false
    @State private var progress = 0.0
    @State private var report: BackupImporter.Report?
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Button(file == nil ? "选择备份文件" : "重新选择") { picking = true }
                    .disabled(running)
                if let file {
                    LabeledContent("文件", value: file.lastPathComponent)
                }
            } footer: {
                Text("支持网页版导出的完整备份（.zip）、仅数据备份（.json）与加了口令的备份。导入会替换原生版里现有的全部数据，且无法撤销；网页版的数据不受影响。")
            }

            if needPass {
                Section("备份口令") {
                    SecureField("口令", text: $password)
                        .textContentType(.password)
                }
            }

            if file != nil {
                Section {
                    Button("开始导入", action: start)
                        .disabled(running || (needPass && password.isEmpty))
                    if running {
                        ProgressView(value: progress)
                    }
                }
            }

            if let failure {
                Section("导入失败") {
                    Text(failure).foregroundStyle(.red)
                }
            }

            if let report {
                Section("导入完成") {
                    LabeledContent("记录", value: "\(report.rows)")
                    LabeledContent("数据域", value: "\(report.collections)")
                    LabeledContent("图片与文件", value: "\(report.media)")
                    LabeledContent("数据版本", value: "\(report.dataVersion)")
                    if report.keptLocalServices {
                        Text("备份中不含接口设置，已保留原生版现有的接口设置。")
                            .foregroundStyle(.secondary)
                    }
                    if !report.bad.isEmpty {
                        Text("以下 \(report.bad.count) 项无法读取，未导入：\(report.bad.prefix(10).joined(separator: "、"))\(report.bad.count > 10 ? " 等" : "")")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("导入网页版备份")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .json, .data, .item]) { result in
            switch result {
            case .success(let url):
                file = url
                report = nil
                failure = nil
                needPass = isSealed(url)
            case .failure(let error):
                failure = error.localizedDescription
            }
        }
    }

    private func isSealed(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: Vault.headLength)) ?? Data()
        return Vault.isSealed(head)
    }

    private func start() {
        guard let file else { return }
        running = true
        progress = 0
        failure = nil
        report = nil
        let pass = password
        Task.detached(priority: .userInitiated) {
            do {
                let r = try BackupImporter.run(file: file, password: pass) { p in
                    Task { @MainActor in progress = p }
                }
                await MainActor.run {
                    report = r
                    running = false
                    onDone()
                }
            } catch {
                let message = error.localizedDescription
                var wantsPass = false
                if case .needPass? = error as? Vault.Failure { wantsPass = true }
                await MainActor.run {
                    failure = message
                    if wantsPass { needPass = true }
                    running = false
                }
            }
        }
    }
}
