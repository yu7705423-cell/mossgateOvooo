import Foundation

/// 群里主动开口（网页版 proactive.js 的 sendGroupProactive / tickGroups，设置在 group.js 的 proactiveOf）。
///
/// 开关存在群上（chat.groupProactive），默认关：这个群冷了一段时间之后，有人先说话。
/// 一次触发一次调用，模型一次写出开口的那几个人（和平常一轮同一条路：主用接口、计一次 chat.reply，网页版 sendGroupProactive
/// 经 streamGroupReply 走 runWith('chat.reply')；「任务用哪套接口」里的「角色主动发消息」管不到群）。只在应用打开时发，后台消息服务器不代发。
/// 落点和角色的存在同一张表里，键是 g:群 id。先排下一次再发，失败也要再等一个完整的间隔。
enum GroupProactive {
    static func key(_ chatId: String) -> String { "g:\(chatId)" }

    static func config(_ chat: Chat?) -> Proactive.Config {
        let p = chat?.row["groupProactive"]?.object ?? [:]
        func hour(_ k: String, _ d: Int) -> Int { p[k]?.number.map { min(23, max(0, Int($0.rounded()))) } ?? d }
        let m = p["minutes"]?.number ?? 120
        return Proactive.Config(on: p["on"]?.bool == true, minutes: max(1, m > 0 ? m : 120),
                                quietFrom: hour("quietFrom", 0), quietTo: hour("quietTo", 8))
    }

    static func save(_ chatId: String, _ c: Proactive.Config) throws {
        guard var chat = try Repo.chat(chatId) else { return }
        chat.row["groupProactive"] = .object(["on": .bool(c.on), "minutes": .number(c.minutes),
                                              "quietFrom": .number(Double(c.quietFrom)), "quietTo": .number(Double(c.quietTo))])
        chat.row.touch()
        try Repo.save(chat)
        Proactive.setNext(key(chatId), c.on ? Date().millis + Proactive.roll(c.minutes) : 0)
    }

    static func nextAt(_ chatId: String) -> Double { Proactive.nextAt(key(chatId)) }

    /// 这一次由群里的人开口：一次请求，落成一轮，未读加上这几条
    @discardableResult
    static func send(chatId: String, onRow: @escaping ChatEngine.OnRow = { _ in }) async throws -> [Message] {
        guard let chat = try Repo.chat(chatId), chat.isGroup else { throw StoreError(message: "群不存在") }
        let members = GroupChat.members(chat)
        guard let lead = GroupChat.speaking(chat, members: members).first else { throw StoreError(message: "群成员都在禁言中，未调用接口") }
        guard Running.claim(chatId) else { return [] }
        defer { Running.release(chatId) }
        let s = AppSettings.load().forChat(chat)
        let built = try ChatPrompt.buildGroup(chat: chat, members: members, settings: s)
        let last = try Repo.messages(chatId: chatId, limit: 5).last(where: { !$0.isError })
        let opening = Templates.render("task.group-proactive", [
            "time": Proactive.timeText(),
            "gap": Proactive.gapText(last.map { Date().millis - $0.createdAt } ?? 0),
        ], settings: s)
        await MainActor.run { Typing.shared.begin(chatId) }
        defer { Task { @MainActor in Typing.shared.end(chatId) } }
        let r = try await AIService.shared.send(task: "chat.reply", system: built.system,
                                                messages: CallEngine.mergeAdjacent(built.messages + [AIMessage(role: .user, content: opening)]),
                                                retries: 1)
        let raw = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw StoreError(message: "模型返回了空内容") }
        let served = ChatEngine.servedEntry(r)
        let made = try await ChatEngine.write(raw: raw, chat: chat, char: lead, turnId: "gp-\(Int(Date().millis))",
                                              versions: .init(swipes: [raw], index: 0, served: [served]), onRow: onRow)
        try Proactive.bumpUnread(chatId, made.count)
        Notifier.post(chatId: chatId, title: GroupChat.title(chat, members: members), text: raw)
        return made
    }

    /// 巡检一轮（Proactive.tick 之后）。holds 为真时应用在后台：群这一档不代发，也不发
    @discardableResult
    static func tick(now: Double = Date().millis, holds: Bool = false) async -> [String] {
        guard !holds else { return [] }
        let s = AppSettings.load()
        guard !AIService.chain(task: "chat.reply", group: RouteGroup.of(task: "chat.reply"), settings: s).isEmpty else { return [] }
        var fired: [String] = []
        for chat in (try? Repo.chats()) ?? [] where chat.isGroup {
            let k = key(chat.id)
            let c = config(chat)
            if !c.on { if Proactive.nextAt(k) > 0 { Proactive.setNext(k, 0) }; continue }
            let next = Proactive.nextAt(k)
            if next <= 0 { Proactive.setNext(k, now + Proactive.roll(c.minutes)); continue }
            if now < next { continue }
            if Proactive.inQuiet(c, Date(millis: now)) { Proactive.setNext(k, Proactive.quietEndsAt(c, Date(millis: now))); continue }
            // 群里正在聊：等聊天停下来
            let held = Proactive.holdUntil(chat, c.minutes, now: now)
            if held > 0 { Proactive.setNext(k, held); continue }
            // 先排下一次，再发：失败也要再等一个完整的间隔
            Proactive.setNext(k, now + Proactive.roll(c.minutes))
            // 能说话的都封存或禁言了、未读堆满了：不调接口
            let cap = Int(s.raw["proactiveMaxUnread"]?.number ?? 3)
            guard !GroupChat.speaking(chat, members: GroupChat.members(chat)).isEmpty, cap <= 0 || chat.unread < cap,
                  !Running.has(chat.id), !ChatEngine.isReplying(chat.id) else { continue }
            fired.append(chat.id)
            do { try await send(chatId: chat.id) }
            catch {
                Diagnostics.shared.record("group-proactive-failed", ["error": error.localizedDescription])
                Problems.report("群「\(GroupChat.title(chat, members: GroupChat.members(chat)))」主动开口失败：\(error.localizedDescription)。下一次按间隔再试。")
            }
        }
        return fired
    }
}
