import Foundation

/// 每一轮到底发出去了什么（网页版 ai/trace.js）。排查提示词用，默认关着，关着时一条都不记。
/// 只在内存里：它是「刚才那几轮发了什么」，不是日志档案；关掉应用就没了。
@MainActor
final class Trace: ObservableObject {
    static let shared = Trace()

    struct Row: Identifiable {
        struct Msg { var role: String; var content: String; var images: Int }
        let id: Int
        let at: Date
        let task: String
        let preset: String
        let model: String
        let system: String
        let messages: [Msg]
        let tokens: Int
        var reply = ""
        var error = ""
        var ms = 0
    }

    @Published private(set) var rows: [Row] = []
    private var seq = 0

    nonisolated static func isOn(_ s: AppSettings = .load()) -> Bool { s.raw["traceOn"]?.bool == true }
    /// 留几条。填 0 表示不限
    nonisolated static func maxOf(_ s: AppSettings = .load()) -> Int {
        guard let n = s.raw["traceMax"]?.number, n.isFinite, n >= 0 else { return 20 }
        return Int(n.rounded())
    }

    /// 粗略估算 token（网页版 tokens.js 的 estimate）：中日韩字符按 0.9，其余按 0.28
    nonisolated static func estimate(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for u in s.utf16 {
            switch u {
            case 0x3000...0x303F, 0x3040...0x30FF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xFF00...0xFFEF: cjk += 1
            default: other += 1
            }
        }
        return Int((Double(cjk) * 0.9 + Double(other) * 0.28).rounded(.up))
    }

    /// 记一次请求，返回编号；没开返回 nil
    func begin(task: String, preset: ChatPreset, system: String, messages: [AIMessage]) -> Int? {
        let s = AppSettings.load()
        guard Self.isOn(s) else { return nil }
        seq += 1
        let msgs = messages.map { Row.Msg(role: $0.role.rawValue, content: $0.content, images: $0.images.count) }
        let tokens = Self.estimate(system) + messages.reduce(0) { $0 + Self.estimate($1.content) }
        rows.insert(Row(id: seq, at: Date(), task: task, preset: preset.name, model: preset.model, system: system,
                        messages: msgs, tokens: tokens), at: 0)
        let cap = Self.maxOf(s)
        if cap > 0 && rows.count > cap { rows.removeLast(rows.count - cap) }
        return seq
    }

    func finish(_ id: Int?, reply: String = "", error: String = "", started: Date) {
        guard let id, let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].reply = reply
        rows[i].error = error
        rows[i].ms = Int(Date().timeIntervalSince(started) * 1000)
    }

    func clear() { rows = []; seq = 0 }

    /// 整条记录导出成文字，供复制
    static func text(_ r: Row) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let head = ["时间：\(f.string(from: r.at))", "任务：\(r.task)", "接口：\(r.preset.isEmpty ? "未命名" : r.preset) · \(r.model.isEmpty ? "未知模型" : r.model)",
                    "耗时：\(r.ms) 毫秒 · 约 \(r.tokens) tokens"].joined(separator: "\n")
        let body = r.messages.enumerated().map { i, m in
            "--- 消息 \(i + 1) · \(m.role)\(m.images > 0 ? " · 含图片" : "") ---\n\(m.content)"
        }.joined(separator: "\n\n")
        return "\(head)\n\n=== system ===\n\(r.system)\n\n=== 消息 ===\n\(body)\n\n=== 回复 ===\n\(r.error.isEmpty ? r.reply : "（失败）" + r.error)"
    }
}
