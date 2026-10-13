import Foundation

/// 实际打出去几次请求的账（网页版 usage.js）。每个真正发请求的出口记一笔，**在发之前记**：
/// 失败也算花过一次（CLAUDE.md 第 15 条）。
///
/// 存在 kv 的 `nativeUsage` 里：{ "2026-10-13": { "chat.reply": 3, ... } }，只留最近 60 天。
actor Usage {
    static let shared = Usage()
    private static let key = "nativeUsage"
    private static let keepDays = 60

    func note(task: String) {
        var all = (try? Database.shared.kv(Self.key))?.object ?? [:]
        let day = Self.today()
        var counts = all[day]?.object ?? [:]
        counts[task] = .number((counts[task]?.number ?? 0) + 1)
        all[day] = .object(counts)
        if all.count > Self.keepDays {
            for old in all.keys.sorted().prefix(all.count - Self.keepDays) { all[old] = nil }
        }
        do { try Database.shared.setKV(Self.key, .object(all)) }
        catch { Problems.report("用量记录写入失败：\(error.localizedDescription)") }
    }

    func today(task: String? = nil) -> Int {
        let counts = (try? Database.shared.kv(Self.key))?[Self.today()]?.object ?? [:]
        if let task { return Int(counts[task]?.number ?? 0) }
        return Int(counts.values.compactMap(\.number).reduce(0, +))
    }

    static func today() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

/// 写入失败之类不能只打日志的问题，集中在这里摆到屏幕上（网页版第 20 条）。
@MainActor
final class Problems: ObservableObject {
    static let shared = Problems()
    @Published var latest: String?

    nonisolated static func report(_ message: String) {
        Task { @MainActor in Problems.shared.latest = message }
    }
}
