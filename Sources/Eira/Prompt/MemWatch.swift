import Foundation
import SwiftUI
import UIKit

/// 自动总结的另外两条触发（网页版 system/ai/memwatch.js，ARCHITECTURE 4.441）：离开会话一段时间、隔夜。
///
/// 对话结束是天然的整理点。从前只在发消息时才想起总结，人停下来不聊，最后那一段永远不总结。
///
///   离开：从一段会话退出来（换了会话、回主界面、应用退到后台）N 分钟后，积压至少两轮就总结（autoSummarizeIdle，0 为不看）
///   隔夜：打开应用、回到前台时，积压里最后一条是前一天或更早的就总结（autoSummarizeOvernight）
///
/// 两条各自一个开关，都默认关（第 15 条）。都走 MemorySummary.extract 的「先记试过再发」：失败那一次记了标记，
/// 同一段积压不会再被这两条反复触发（sinceTried 不够两轮）。封存的会话不总结（4.557）。
/// 正在看哪段会话读 Notifier.visibleChat（会话页自己登记），这里隔两秒看一眼有没有换，不调接口。
@MainActor
enum MemWatch {
    static let idleMinRounds = 2

    private static var timers: [String: Task<Void, Never>] = [:]
    private static var lastChat: String?
    private static var running = false
    private static var watcher: Task<Void, Never>?

    nonisolated static func memoryOn(_ s: AppSettings) -> Bool { s.raw["memoryEnabled"]?.bool ?? true }
    nonisolated static func idleMinutes(_ s: AppSettings) -> Int { max(0, Int((s.raw["autoSummarizeIdle"]?.number ?? 0).rounded())) }
    nonisolated static func overnightOn(_ s: AppSettings) -> Bool { s.raw["autoSummarizeOvernight"]?.bool == true }

    /// 积压够不够离开那一条（至少两轮）
    nonisolated static func enough(chatId: String) -> Bool {
        MemorySummary.roundsIn((try? MemorySummary.sinceTried(chatId: chatId)) ?? []) >= idleMinRounds
    }

    // MARK: - 接到外壳上

    /// 前后台切换（EiraApp 的 scenePhase）：回到前台看隔夜、开始盯着换会话；退到后台算离开正在看的那段
    static func scene(_ phase: ScenePhase) {
        switch phase {
        case .active:
            watch()
            Task { _ = await overnight() }
        case .background:
            if let c = lastChat ?? Notifier.shared.visibleChat { left(c) }
        default: break
        }
    }

    /// 隔两秒看一眼正在看的会话换没换；换了就算离开上一段
    private static func watch() {
        guard watcher == nil else { return }
        watcher = Task { @MainActor in
            while !Task.isCancelled {
                let cur = Notifier.shared.visibleChat
                if cur != lastChat {
                    if let prev = lastChat { left(prev) }
                    lastChat = cur
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - 离开

    /// 离开了某段会话：N 分钟后看一眼。设置在那一刻读，没开就不排
    static func left(_ chatId: String, settings s: AppSettings = .load()) {
        guard !chatId.isEmpty, memoryOn(s) else { return }
        let minutes = idleMinutes(s)
        guard minutes > 0 else { return }
        timers[chatId]?.cancel()
        timers[chatId] = Task { @MainActor in
            // 默认是连续时钟：手机锁屏、应用挂起的那段时间也算在内
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            timers[chatId] = nil
            _ = await idleFire(chatId)
        }
    }

    /// 离开的时间到了：期间又回到这段会话（且在前台）就不算离开；积压不够两轮不总结
    @discardableResult
    static func idleFire(_ chatId: String, viewing: String? = nil, active: Bool? = nil) async -> MemorySummary.Counts? {
        let s = AppSettings.load()
        guard memoryOn(s), idleMinutes(s) > 0 else { return nil }
        let isActive = active ?? (UIApplication.shared.applicationState == .active)
        if isActive && (viewing ?? Notifier.shared.visibleChat) == chatId { return nil }
        guard (try? Repo.chat(chatId)) != nil, enough(chatId: chatId) else { return nil }
        return await run(chatId)
    }

    // MARK: - 隔夜

    /// 积压里最后一条是前一天或更早的那些会话（按「我」所在时区与时间感知的世界时刻分天，网页版 overnightDue）
    nonisolated static func overnightDue(now: Date = Date(), settings s: AppSettings = .load()) -> [String] {
        let today = dayKey(now.millis, s)
        return ((try? Repo.chats()) ?? []).filter { c in
            let since = (try? MemorySummary.sinceTried(chatId: c.id)) ?? []
            guard MemorySummary.roundsIn(since) >= 1, since.count >= 2, let last = since.last, last.createdAt > 0 else { return false }
            return dayKey(last.createdAt, s) < today
        }.map(\.id)
    }

    nonisolated static func dayKey(_ ms: Double, _ s: AppSettings) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Clock.zone(Clock.userZone(s))
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Clock.toWorld(ms, s))
    }

    /// 隔夜那一条：开着就把该总结的几段各总结一次。回总结成功了几段
    @discardableResult
    static func overnight(now: Date = Date()) async -> Int {
        let s = AppSettings.load()
        guard memoryOn(s), overnightOn(s) else { return 0 }
        var n = 0
        for id in overnightDue(now: now, settings: s) {
            if await run(id) != nil { n += 1 }
        }
        return n
    }

    // MARK: - 总结

    /// 追平（网页版 extractAll）：最多连续 autoSummarizeCatchUp 批（默认 1）。每批之前 extract 先记「试过」再发；
    /// 失败只记诊断，不打断别的事。同一时刻只跑一段
    private static func run(_ chatId: String) async -> MemorySummary.Counts? {
        guard let chat = try? Repo.chat(chatId), !Archive.chatArchived(chat) else { return nil }
        guard !running else { return nil }
        running = true
        defer { running = false }
        let s = AppSettings.load()
        let catchUp = max(0, Int((s.raw["autoSummarizeCatchUp"]?.number ?? 1).rounded()))
        let batch = max(0, Int((s.raw["memoryBatch"]?.number ?? 200).rounded()))
        let every = max(0, Int((s.raw["autoSummarizeInterval"]?.number ?? 0).rounded()))
        var sum = MemorySummary.Counts()
        var runs = 0
        do {
            while try MemorySummary.pending(chatId: chatId).count >= 2 && (catchUp == 0 || runs < catchUp) {
                let r = try await MemorySummary.extract(chatId: chatId)
                runs += 1
                sum.added += r.added; sum.updated += r.updated; sum.closed += r.closed; sum.state += r.state
                // 一次全吃的（不分批、不按轮数），吃完就没了
                if batch == 0 && every == 0 { break }
            }
        } catch {
            Diagnostics.shared.record("memory-extract-failed", ["error": error.localizedDescription, "why": "memwatch"])
            return nil
        }
        return sum
    }
}
