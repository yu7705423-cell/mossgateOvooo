import Foundation
import UIKit

/// 问题反馈用的记录：只记「发生了什么」，不记「说了什么」。
///
/// 记的是：每次请求的任务名、接口格式、模型名、状态码、耗时、错误说明；导入的结果；写入失败；启动；闪退摘要。
/// **不记**：聊天内容、人设、记忆、提示词、密钥、接口地址。错误说明进来之前先经 `redact` 去掉像密钥的串。
///
/// 存成一个文本文件，一行一条 JSON，最多留 `limit` 条，超了从最早的删。
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    static let limit = 500
    private let lock = NSLock()

    private var url: URL { AppPaths.root.appendingPathComponent("diagnostics.log") }

    // MARK: - 记

    /// 这几个字段是外来的文字（接口返回的错误说明之类），进来之前去掉像密钥的串、截到 300 字。
    /// 其余字段是代码自己填的（任务名、模型名、状态码），原样记。
    static let freeTextKeys: Set<String> = ["error", "message", "reason"]

    func record(_ kind: String, _ fields: [String: Any] = [:]) {
        var entry: [String: Any] = ["t": Date().millis, "k": kind]
        for (k, v) in fields {
            if Self.freeTextKeys.contains(k), let s = v as? String { entry[k] = Self.redact(s) } else { entry[k] = v }
        }
        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = readLinesLocked()
            lines.append(String(decoding: data, as: UTF8.self))
            if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // 诊断记录本身写不进去：不能再往这里记，也不弹提示打扰用户，只留在系统日志
            NSLog("[diagnostics] 写入失败：%@", error.localizedDescription)
        }
    }

    func entries() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return readLinesLocked().compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    private func readLinesLocked() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: - 去掉像密钥的东西

    private static let secretPatterns: [NSRegularExpression] = [
        #"(?i)bearer\s+\S+"#,
        #"(?i)(api[_-]?key|x-api-key|token|password|secret)["'\s:=]+\S+"#,
        #"\b(sk|pk|rk|ak)-[A-Za-z0-9_\-]{6,}"#,
        // 24 位以上连续的字母数字：多半是密钥或令牌
        #"[A-Za-z0-9_\-]{24,}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func redact(_ s: String) -> String {
        var out = s
        for re in secretPatterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length),
                                              withTemplate: "[已隐去]")
        }
        return String(out.prefix(300))
    }

    // MARK: - 导出

    /// 导出给用户发出去的那一份文字。
    func report() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        var lines: [String] = [
            "Eiraowo 诊断信息",
            "生成时间：\(TimeText.format(Date()))",
            "版本：\(version)（\(build)）",
            "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "设备：\(Self.deviceModel())",
            "",
            "本文件不含聊天内容、人设、记忆、提示词、密钥与接口地址。",
            "",
        ]

        // 数据规模：只有条数
        if let counts = try? Database.shared.counts(), !counts.isEmpty {
            lines.append("[本地数据条数]")
            for (k, v) in counts.sorted(by: { $0.key < $1.key }) { lines.append("\(k)：\(v)") }
            lines.append("")
        }
        if let v = (try? Database.shared.kv(KVKey.dataVersion))?.number {
            lines.append("导入的备份数据版本：\(Int(v))")
        }

        // 接口：只写有几套、各是什么格式与模型，不写地址与密钥
        let s = AppSettings.load()
        lines.append("")
        lines.append("[接口]")
        for p in s.chatPresets {
            var tags: [String] = []
            if p.id == s.mainPreset?.id { tags.append("主用") }
            if p.id == s.fallbackPreset?.id { tags.append("副用") }
            lines.append("\(p.provider.rawValue) \(p.model.isEmpty ? "未填模型" : p.model)\(p.apiKey.isEmpty ? " 未填密钥" : "")\(tags.isEmpty ? "" : " " + tags.joined(separator: "、"))")
        }
        lines.append("自动重试：\(s.retryMax)；失败改用其他接口：\(s.chatFallback ? "开（最多 \(s.failoverMax)）" : "关")")
        lines.append("")

        lines.append("[最近的记录，最早的在前]")
        for e in entries() {
            let t = (e["t"] as? Double).map { TimeText.format(Date(millis: $0)) } ?? "?"
            let k = e["k"] as? String ?? "?"
            let rest = e.filter { $0.key != "t" && $0.key != "k" }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            lines.append("\(t) \(k) \(rest)")
        }
        return lines.joined(separator: "\n")
    }

    static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { buf in
            String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
