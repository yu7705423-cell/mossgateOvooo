import Foundation

/// 心声（网页版 extras.js 的 innerMode 与 ai/tasks/inner.js）。每段会话一份：
/// - off：不写；
/// - inline：随回复一起写在最后一行 [心声：…]，不多调接口；
/// - apart：整轮说完之后另调一次，只问刚才那几句话背后在想什么。每轮多一次，默认关。
enum InnerVoice {
    static func mode(_ chat: Chat) -> String {
        let m = chat.row.string("innerMode")
        return m == "inline" || m == "apart" ? m : "off"
    }

    /// 写什么：这段会话自己写的一句，没写用默认那句。
    static func what(_ chat: Chat, settings s: AppSettings) -> String {
        let own = chat.row.string("innerWhat").trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? Templates.get("skeleton.inner-what", settings: s) : own
    }

    /// inline 那一档在提示词里的那一段（预设条目「心声」，默认排在聊天记录之后）。
    static func piece(_ chat: Chat, settings s: AppSettings) -> String {
        guard mode(chat) == "inline" else { return "" }
        return Templates.render("skeleton.inner", ["what": what(chat, settings: s)], settings: s)
    }

    /// apart 那一档：挂在这一轮角色最后说的那一条文字上。失败不抛（这一轮已经发出去的话不受影响），在屏幕上说。
    static func attach(chat: Chat, char: Character, created: [Message]) async -> Message? {
        guard mode(chat) == "apart", let target = created.last(where: { $0.role == .char && $0.kind == "text" }) else { return nil }
        let said = created.filter { $0.kind == "text" }.map(\.content).joined(separator: "\n")
        guard !said.isEmpty else { return nil }
        let s = AppSettings.load()
        let own = chat.row.string("innerWhat").trimmingCharacters(in: .whitespacesAndNewlines)
        let system = Templates.render("task.inner", [
            "charName": char.name,
            "charPersona": char.persona.isEmpty ? "(no character card was written)" : char.persona,
            "own": own.isEmpty ? "" : "\nWhat to write: \(own)",
        ], settings: s)
        do {
            let r = try await AIService.shared.send(task: "inner.voice", system: system,
                                                    messages: [AIMessage(role: .user, content: said)], maxTokens: 1200)
            let text = String(ReplyParser.stripThink(r.text).0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            guard !text.isEmpty, var row = try Database.shared.get(Collections.messages, id: target.id) else { return nil }
            row["inner"] = .string(text)
            row["innerTrans"] = .string("")
            row.touch()
            try Database.shared.put(Collections.messages, row)
            return Message(row: row)
        } catch {
            Problems.report("心声未能生成：\(error.localizedDescription)")
            return nil
        }
    }
}
