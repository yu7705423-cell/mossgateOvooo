import Foundation

// MARK: - 短信的一次回复（网页版 engine.js 的 buildSmsSystem 与 streamSms，4.307）
//
// 身份隔离：没确认之前不注入你的身份资料作为「对方是谁」，性别锚点只写角色自己；开场只写「一个尚未确认身份的号码」。
// 角色照样记得你、记得你们的关系（4.392），那几块照常注入，只是抬头写明是关于谁的（stranger）。
// 每轮 1 到 3 条（smsMin、smsMax），能力只给短信里说得通的几样。
// 和聊天回复同一个出口（主用接口，记一次 chat.reply），**你点一次「回复」调一次**（第 15 条）。
extension Sms {
    /// 网页版 SMS_BLOCKS：只拼这几块，按这个顺序；每轮都变的那几块下沉到聊天记录末尾
    static let blocks = ["lorebook", "character", "loreAfter", "user", "time", "dates", "day", "bond", "state", "pinned", "recent", "memory", "ties", "sms"]

    private static func countText(_ lo: Double, _ hi: Double) -> String {
        let a = max(1, Int(lo.rounded()))
        let b = max(a, Int(hi.rounded()))
        return a == b ? "\(a)" : "\(a) to \(b)"
    }

    /// 身份没确认时那两块的抬头换成「关于谁」（网页版 basic.js 的 user、memory.js 的 buildBond）
    static func asStranger(_ id: String, _ text: String, userName: String) -> String {
        switch id {
        case "user": return text.replacingOccurrences(of: "[对方是谁]", with: "[关于\(userName)]")
        case "bond": return text.replacingOccurrences(of: "[你们之间的关系]", with: "[你和\(userName)之间的关系]")
        default: return text
        }
    }

    static func build(thread: Row, char: Character, settings s: AppSettings, now: Date = Date()) throws -> ChatPrompt.Built {
        let chat = asChat(thread)
        let personas = try Repo.personas()
        let me = try personas.first(where: { $0.id == thread.string("personaId") }) ?? Repo.activePersona(s)
        let known = isKnown(thread)
        let charName = char.row.string("name").isEmpty ? "对方" : char.row.string("name")
        let meName = me?.row.string("name") ?? ""
        let userName = meName.isEmpty ? "the user" : meName
        let names = ["charName": charName, "userName": userName, "number": thread.string("mine"), "myNumber": thread.string("theirs")]

        var out = Templates.render("skeleton.sms-opening", names, settings: s)
        out += "\n" + Templates.render(known ? "skeleton.sms-known" : "skeleton.sms-unknown", names, settings: s)
        let gender = ChatPrompt.genderPiece(char: char, me: known ? me : nil, names: names, settings: s)
        if !gender.isEmpty { out += "\n\n" + gender }

        let msgs = visible(thread.id).filter { !$0.isError }
        let scan = ChatPrompt.scanTextOf(msgs, window: Int(s.num("scanWindow", 6)))
        let budget = Int(s.num("contextBudget", 0))
        let lore = ChatPrompt.activateLore(char: char, scanText: scan, budget: budget > 0 ? Int((Double(budget) * 0.4).rounded()) : 0)
        let rootId = Repo.rootId(of: me?.id ?? "", in: personas)
        let memories = try ChatPrompt.visibleMemories(char: char, chat: chat, rootId: rootId, personas: personas)
        let memoryOn = s.raw["memoryEnabled"]?.bool ?? true
        let recent = memoryOn ? ChatPrompt.recentMemories(memories, limit: Int(s.num("memoryRecent", 10))) : []
        let recalled = memoryOn ? ChatPrompt.recall(memories, scanText: scan, skip: Set(recent.map(\.id)), topK: Int(s.num("memoryTopK", 6)),
                                                    now: now, openDays: ChatPrompt.staleDays(s)) : []
        let parts = ChatPrompt.dataBlocks(chat: chat, char: char, me: me, msgs: msgs, lore: lore, memories: memories, recent: recent,
                                          recalled: recalled, rootId: rootId, settings: s, now: now)
        var hot = ""
        for id in blocks {
            guard let raw = parts[id], !raw.isEmpty else { continue }
            let text = known ? raw : asStranger(id, raw, userName: userName)
            if Layout.volatile.contains(id) { hot += text } else { out += text }
        }
        out += "\n\n" + Templates.render("skeleton.sms-rules", ["count": countText(s.num("smsMin", 1), s.num("smsMax", 3))], settings: s)
        out += ChatPrompt.smsCapabilities(char: char, chat: chat, msgs: msgs, settings: s)
        let core = char.core.trimmingCharacters(in: .whitespacesAndNewlines)
        if !core.isEmpty { out += "\n\n" + Templates.render("skeleton.core", ["core": core], settings: s) }
        let ban = ChatPrompt.banPiece(s)
        if !ban.isEmpty { out += "\n\n" + ban }
        if !gender.isEmpty { out += "\n\n" + gender }

        let memoryDepth = Int(s.num("memoryDepth", 1))
        var tail: [String] = []
        let h = hot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.isEmpty { tail.append(h) }
        if memoryDepth > 0 && !recalled.isEmpty { tail.append(ChatPrompt.recallText(recalled, now: now)) }
        if let t = ChatPrompt.translateTail(chat, settings: s) { tail.append(t) }
        let (messages, seen) = try ChatPrompt.smsHistory(chat: chat, char: char, msgs: msgs, settings: s, tail: tail.joined(separator: "\n\n"),
                                                         tailDepth: max(1, memoryDepth), lore: lore.deep)
        return ChatPrompt.Built(system: out, messages: messages, recalled: recalled.map(\.id), seenImages: seen)
    }

    /// 回一轮。点一次调一次接口；失败不重试（retryMax 默认 0），不落失败的消息，错误交给界面说
    static func reply(threadId: String, onRow: @escaping ChatEngine.OnRow = { _ in }) async throws {
        guard let t = get(threadId) else { throw StoreError(message: "这段短信已不存在") }
        guard let char = answererOf(t) else { throw StoreError(message: "该号码无人使用，不会有回复") }
        if isBlocked(t.string("theirs"), t.string("personaId")) { throw StoreError(message: "已拦截该号码，解除拦截后才能接收回复") }
        if char.archived { throw StoreError(message: "该角色已封存，不能继续对话，未调用接口。解除封存在该角色的编辑资料页。") }
        let s = AppSettings.load()
        let built = try build(thread: t, char: char, settings: s)
        let result = try await Provider.$keepThink.withValue(true) {
            try await AIService.shared.send(task: "chat.reply", charId: char.id, system: built.system, messages: built.messages, retries: 1)
        }
        try? ChatEngine.markRecalled(built.recalled)
        if !built.seenImages.isEmpty {
            let ids = built.seenImages
            Task.detached { await ChatEngine.describeCarried(ids) }
        }
        let chat = asChat(get(threadId) ?? t)
        guard !ChatEngine.plan(raw: result.text, chat: chat, char: char).plan.isEmpty else { throw StoreError(message: "模型返回了空内容") }
        let versions = ChatEngine.Versions(swipes: [result.text], index: 0, served: [ChatEngine.servedEntry(result)])
        try await ChatEngine.write(raw: result.text, chat: chat, char: char, turnId: Ids.make("turn"), versions: versions, onRow: onRow)
        try touch(threadId)
    }
}
