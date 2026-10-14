import Foundation

/// 全部模型请求的唯一出口（网页版第 10 条：组件里不直接发请求）。
///
/// - 挑哪一套接口：任务组改用的那套 > 主用任务走主用 > 记忆任务走记忆接口 > 其余走副用（网页版 engine.js 的 presetFor）；
/// - 一次最多两个请求同时在跑；
/// - 自动重试取调用方给的次数与用户设的 retryMax 里较小的那个，retryMax 默认 0；
/// - 失败后换一套接口只在用户打开 chatFallback 时做，默认关，最多换 failoverMax 套；
/// - 已经收到一部分正文、或用户取消的，不重试也不换；
/// - 每一次真正发出去之前记一笔账（Usage）。
actor AIService {
    static let shared = AIService()

    /// 这几个任务是用户正盯着屏幕等的，走主用。
    static let mainTasks: Set<String> = ["chat.reply", "chat.call", "scene.write"]
    /// 这几个走记忆接口，没单独配就跟副用。
    static let memoryTasks: Set<String> = ["memory.extract", "memory.bond", "memory.import", "link.tidy",
                                           "chat.summarize", "scene.summary", "work.summary"]

    struct Result: Sendable {
        var text: String
        var presetId: String
        var presetName: String
    }

    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit = 2

    /// - Parameters:
    ///   - task: 任务名，和网页版一致（chat.reply、memory.extract……），记账和挑接口都看它
    ///   - group: 任务组（settings.taskRoutes 的键）。不传时按任务名在 RouteGroup 里找
    ///   - preset: 指定只用这一套（识图接口、测试连接）。给了就不挑、也不换
    ///   - retries: 这件事最多值得重试几次。实际次数还要和用户的 retryMax 取小
    func send(task: String, group: String? = nil, preset only: ChatPreset? = nil, system: String, messages: [AIMessage],
              maxTokens: Int = 0, retries: Int = 0,
              onDelta: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Result {
        let settings = AppSettings.load()
        let chain = only.map { $0.usable ? [$0] : [] } ?? Self.chain(task: task, group: group ?? RouteGroup.of(task: task), settings: settings)
        guard !chain.isEmpty else {
            Diagnostics.shared.record("request-skipped", ["task": task, "reason": "没有可用的接口"])
            throw AIError(status: nil, message: "没有可用的接口。请在「设置 - 接口」中填写密钥与模型。")
        }

        await acquire()
        defer { release() }

        let tries = min(max(0, retries), settings.retryMax)
        var lastError: AIError?
        for preset in chain {
            for attempt in 0...tries {
                try Task.checkCancellation()
                await Usage.shared.note(task: task)
                let started = Date()
                func log(_ status: Int?, _ error: String?) {
                    var f: [String: Any] = ["task": task, "provider": preset.provider.rawValue, "model": preset.model,
                                            "ms": Int(Date().timeIntervalSince(started) * 1000), "attempt": attempt]
                    if let status { f["status"] = status }
                    if let error { f["error"] = error }
                    Diagnostics.shared.record(error == nil ? "request" : "request-failed", f)
                }
                do {
                    let text = try await Provider.send(
                        preset,
                        .init(system: system, messages: messages,
                              maxTokens: maxTokens > 0 ? maxTokens : (Self.mainTasks.contains(task) ? 0 : settings.taskMaxTokens),
                              stream: settings.streams,
                              cache: settings.promptCache && ["chat.reply", "chat.call", "chat.proactive", "scene.write"].contains(task)),
                        idleSeconds: settings.streamIdleSec,
                        onDelta: onDelta)
                    log(200, nil)
                    return Result(text: text, presetId: preset.id, presetName: preset.name)
                } catch let e as AIError {
                    log(e.status, e.cancelled ? "已取消" : e.message + (e.partial.isEmpty ? "" : "（已收到部分回复）"))
                    lastError = e
                    if e.cancelled || !e.partial.isEmpty { throw e }
                    guard e.retryable, attempt < tries else { break }
                    try await Task.sleep(nanoseconds: UInt64(600_000_000 * (1 << attempt)))
                }
            }
        }
        throw lastError ?? AIError(status: nil, message: "请求失败")
    }

    /// 依次要试的接口。没开 chatFallback 时只有挑中的那一套。
    static func chain(task: String, group: String?, settings s: AppSettings) -> [ChatPreset] {
        let main = s.mainPreset.flatMap { $0.usable ? $0 : nil }
        let fallback = s.fallbackPreset.flatMap { $0.usable ? $0 : nil }

        let picked: ChatPreset?
        if let group, let routed = s.routedPreset(group: group) {
            picked = routed
        } else if mainTasks.contains(task) {
            picked = main ?? fallback
        } else if memoryTasks.contains(task), let mem = s.memoryPreset {
            picked = mem
        } else {
            picked = fallback ?? main
        }
        guard let picked else { return [] }
        guard s.chatFallback else { return [picked] }

        var out: [ChatPreset] = []
        for p in [picked, main, fallback].compactMap({ $0 }) + s.chatPresets.filter(\.usable)
        where !out.contains(where: { $0.id == p.id }) {
            out.append(p)
        }
        // failoverMax 是「换几套」，不含第一套；0 表示其余的全试
        let max = s.failoverMax
        return max == 0 ? out : Array(out.prefix(1 + max))
    }

    private func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { running -= 1 }
        else { waiters.removeFirst().resume() }
    }
}
