import Foundation

/// 本群页面打开时，群里接着聊（网页版 ai/groupauto.js，ARCHITECTURE 4.1018）。
///
/// 只在这个群的页面开着、在前台时进行：群资料里打开「本群页面打开时接着聊」，满一个间隔进行一轮，
/// 一轮一次模型调用（任务 group.ambient，不走按人头分调），没有人开口时模型写 [不回复]，不落消息。
/// 默认关（网页版第 15 条），登记在 ExtraCalls 的 groupAmbient。
///
/// 「试过」记在本机，**发请求之前**就记，失败也算试过：下一轮要再等满一个完整间隔。离开页面就停。
enum GroupAmbient {
    struct Last: Equatable {
        var tryAt: Double = 0
        var okAt: Double = 0
        var err = ""
        var silent = false
    }

    nonisolated(unsafe) static var store: UserDefaults = .standard
    private static let key = "eira.groupauto"
    private static let lock = NSLock()

    private static func read() -> [String: [String: Any]] {
        (store.dictionary(forKey: key) as? [String: [String: Any]]) ?? [:]
    }

    private static func rowOf(_ id: String) -> [String: Any] { lock.lock(); defer { lock.unlock() }; return read()[id] ?? [:] }

    private static func patch(_ id: String, _ p: [String: Any?]) {
        lock.lock(); defer { lock.unlock() }
        var all = read()
        var r = all[id] ?? [:]
        for (k, v) in p { r[k] = v }
        all[id] = r
        store.set(all, forKey: key)
    }

    /// 测试用：清掉本机记下的
    static func reset() { lock.lock(); defer { lock.unlock() }; store.removeObject(forKey: key) }

    /// 进到这个群的页面：本次打开从头计数
    static func enter(_ chatId: String, now: Double = Date().millis) { patch(chatId, ["openAt": now, "openN": 0.0]) }
    static func leave(_ chatId: String) { patch(chatId, ["openAt": nil, "openN": nil]) }

    static func lastOf(_ chatId: String) -> Last {
        let r = rowOf(chatId)
        return Last(tryAt: r["tryAt"] as? Double ?? 0, okAt: r["okAt"] as? Double ?? 0,
                    err: r["err"] as? String ?? "", silent: r["silent"] as? Bool ?? false)
    }

    /// 此刻该不该进行一轮。不满足时什么都不记（不算一次尝试）
    static func due(chatId: String, draftEmpty: Bool, busy: Bool, now: Double = Date().millis) -> Bool {
        guard let chat = (try? Repo.chat(chatId)) ?? nil, chat.isGroup else { return false }
        let a = GroupMore.ambient(chat)
        guard a.page, draftEmpty, !busy, !ChatEngine.isReplying(chatId), !Running.has(chatId) else { return false }
        let s = AppSettings.load()
        guard !AIService.chain(task: "group.ambient", group: RouteGroup.of(task: "group.ambient"), settings: s).isEmpty else { return false }
        // 只在当前账号的群里进行
        if !chat.personaId.isEmpty, let active = (try? Repo.activePersona(s)) ?? nil, active.id != chat.personaId { return false }
        guard !GroupChat.speaking(chat, members: GroupChat.members(chat)).isEmpty else { return false }
        let r = rowOf(chatId)
        let openAt = r["openAt"] as? Double
        if a.perOpen > 0 && Int(r["openN"] as? Double ?? 0) >= a.perOpen { return false }
        let lastMsg = ((try? Repo.messages(chatId: chatId, limit: 1)) ?? []).last?.createdAt ?? 0
        let since = max(r["tryAt"] as? Double ?? 0, lastMsg, openAt ?? 0)
        return now - since >= Double(a.pageMin) * 60_000
    }

    /// 进行一轮：先记「试过」，再调一次接口；[不回复] 不落消息。返回落下的消息
    @discardableResult
    static func round(chatId: String, onRow: @escaping ChatEngine.OnRow = { _ in }) async throws -> [Message] {
        guard let chat = try Repo.chat(chatId), chat.isGroup else { throw StoreError(message: "群不存在") }
        let now = Date().millis
        let r = rowOf(chatId)
        var tried: [String: Any?] = ["tryAt": now]
        if r["openAt"] != nil { tried["openN"] = (r["openN"] as? Double ?? 0) + 1 }
        patch(chatId, tried)
        do {
            let members = GroupChat.members(chat)
            guard let lead = GroupChat.speaking(chat, members: members).first else { throw StoreError(message: "群成员都在禁言中，未调用接口") }
            guard Running.claim(chatId) else { return [] }
            defer { Running.release(chatId) }
            let s = AppSettings.load().forChat(chat)
            let built = try ChatPrompt.buildGroup(chat: chat, members: members, settings: s)
            let last = try Repo.messages(chatId: chatId, limit: 5).last(where: { !$0.isError })
            let opening = Templates.render("task.group-ambient", [
                "time": Proactive.timeText(),
                "gap": Proactive.gapText(last.map { now - $0.createdAt } ?? 0),
            ], settings: s)
            let res = try await AIService.shared.send(task: "group.ambient", system: built.system,
                                                      messages: CallEngine.mergeAdjacent(built.messages + [AIMessage(role: .user, content: opening)]))
            let raw = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw StoreError(message: "模型返回了空内容") }
            if raw.range(of: #"^\[\s*不回复\s*\]$"#, options: .regularExpression) != nil {
                patch(chatId, ["okAt": Date().millis, "err": "", "silent": true])
                return []
            }
            let made = try await ChatEngine.write(raw: raw, chat: chat, char: lead, turnId: "ga-\(Int(now))",
                                                  versions: .init(swipes: [raw], index: 0, served: [ChatEngine.servedEntry(res)]),
                                                  instant: true, onRow: onRow)
            patch(chatId, ["okAt": Date().millis, "err": "", "silent": false])
            return made
        } catch {
            patch(chatId, ["err": error.localizedDescription])
            throw error
        }
    }
}
