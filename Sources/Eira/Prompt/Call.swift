import Foundation

/// 通话（网页版 system/call.js 与 engine.js 的 buildCallSystem、streamCall）。
///
/// 不是实时语音，按回合做：你说一句，角色回一句，一轮一次请求。
/// - 提示词只拼一次，整通电话复用；
/// - 每轮回复上限 callMaxTokens（默认 400，填 0 不压）；
/// - 通话中每一轮都不落库，挂断时合成一条通话记录，正文里带着整段对白，角色下次聊天记得电话里说了什么；
/// - 打完自动写一段总结，默认开着（网页版用户明确要求的例外，登记在 ExtraCalls）。
enum CallEngine {
    struct Line: Equatable, Sendable {
        var role: String           // user | char
        var text: String
        var audio: [String] = []   // 这一句合成出来的声音（files 的 id）

        var json: JSONValue {
            var o: [String: JSONValue] = ["role": .string(role), "text": .string(text)]
            if !audio.isEmpty { o["audio"] = .array(audio.map { .string($0) }) }
            return .object(o)
        }
    }

    struct Prepared: Sendable {
        var system: String
        var history: [AIMessage]
    }

    /// 接通时拼一次。聊天记录照常带上，后面不挂此刻的状态与召回。
    static func prepare(chat: Chat, char: Character) throws -> Prepared {
        let s = AppSettings.load().forChat(chat)
        let rule = Templates.render("skeleton.call", ["kind": "a phone call", "camera": "",
                                                       "actions": Templates.get("skeleton.call-voice", settings: s)], settings: s)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        let built = try ChatPrompt.build(chat: chat, char: char, settings: s, call: (rule: rule, script: ""))
        return Prepared(system: built.system, history: built.messages)
    }

    /// 通话中的一轮。opening 是「电话刚接通，你先开口」这一类一次性的指示。
    static func turn(_ p: Prepared, lines: [Line], opening: String = "",
                     onDelta: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let talk = lines.map { AIMessage(role: $0.role == "user" ? .user : .assistant, content: $0.text) }
        let tail = opening.isEmpty ? [] : [AIMessage(role: .user, content: opening)]
        let messages = mergeAdjacent(p.history + talk + tail)
        let max = Int(AppSettings.load().raw["callMaxTokens"]?.number ?? 400)
        let r = try await AIService.shared.send(task: "chat.call", system: p.system, messages: messages,
                                                maxTokens: max, retries: 1, onDelta: onDelta)
        return clean(r.text)
    }

    static func openingLine(outgoing: Bool) -> String {
        Templates.render("task.call-open", ["origin": outgoing ? "; they called you" : "; you called them"], settings: .load())
    }

    /// 去掉思考段；语音通话不写动作，写了也只当括号里的一句。
    static func clean(_ raw: String) -> String {
        ReplyParser.stripThink(raw).0.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 存进聊天记录正文的写法：[动作：…] 换成（…）。
    static func prose(_ text: String) -> String {
        text.replacingOccurrences(of: #"[\[【]\s*动作\s*[:：]\s*([^\]】]*)[\]】]"#, with: "（$1）", options: .regularExpression)
    }

    /// 相邻同角色的合成一条：部分接口不接受连续同角色。带图的不合。
    static func mergeAdjacent(_ list: [AIMessage]) -> [AIMessage] {
        var out: [AIMessage] = []
        for m in list {
            if let last = out.last, last.role == m.role, last.images.isEmpty, m.images.isEmpty {
                out[out.count - 1].content += "\n" + m.content
            } else {
                out.append(m)
            }
        }
        return out
    }

    static func duration(_ sec: Int) -> String {
        let n = max(0, sec)
        return String(format: "%02d:%02d", n / 60, n % 60)
    }

    static func label(direction: String, outcome: String, seconds: Int) -> String {
        switch outcome {
        case "done": return "语音通话 \(duration(seconds))"
        case "missed": return direction == "out" ? "语音通话未接听" : "未接语音通话"
        case "declined": return direction == "out" ? "语音通话已被拒接" : "语音通话已拒接"
        default: return "语音通话已取消"
        }
    }

    /// 挂断：合成一条通话记录。接通过、有对白的，按设置写总结（默认开）。
    @discardableResult
    static func finish(chatId: String, charId: String, direction: String, outcome: String, seconds: Int,
                       lines: [Line], userName: String, charName: String) throws -> Message {
        let me = userName.isEmpty ? "我" : userName
        let body = lines.map { "\($0.role == "user" ? me : (charName.isEmpty ? "对方" : charName))：\(prose($0.text))" }.joined(separator: "\n")
        let out = direction == "out"
        var m = Message.new(chatId: chatId, role: out ? .user : .char, authorId: out ? "me" : charId,
                            content: "[\(label(direction: direction, outcome: outcome, seconds: seconds))]" + (body.isEmpty ? "" : "\n" + body),
                            kind: "call")
        m.row["direction"] = .string(direction)
        m.row["outcome"] = .string(outcome)
        m.row["seconds"] = .number(Double(seconds))
        m.row["callLog"] = .array(lines.map(\.json))
        m.row["callKind"] = .string("voice")
        m.row["status"] = .string("done")
        m = try Repo.append(m)
        if var c = try Repo.chat(chatId) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
        return m
    }

    /// 要不要自动写总结。
    static func autoSummary(outcome: String, lines: [Line]) -> Bool {
        outcome == "done" && !lines.isEmpty && AppSettings.load().raw["callSummary"]?.bool != false
    }

    /// 写一段总结，存在那条通话记录上。语言用这段对话设的翻译语言，没设就跟通话同一种。
    @discardableResult
    static func summarize(messageId: String) async throws -> String {
        guard var row = try Database.shared.get(Collections.messages, id: messageId), row.string("kind") == "call" else {
            throw StoreError(message: "这条不是通话记录")
        }
        let content = row.string("content")
        let body = content.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        guard !body.isEmpty else { throw StoreError(message: "这通电话没有留下内容") }
        let chat = try Repo.chat(row.string("chatId"))
        let lang = chat?.row.string("translateTo").trimmingCharacters(in: .whitespaces) ?? ""
        let s = AppSettings.load()
        let r = try await AIService.shared.send(task: "call.summary",
                                                system: Templates.render("task.call-summary", ["lang": lang.isEmpty ? "the same language as the transcript" : lang], settings: s),
                                                messages: [AIMessage(role: .user, content: body)], maxTokens: 600)
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StoreError(message: "没有生成出内容") }
        guard let fresh = try Database.shared.get(Collections.messages, id: messageId) else { return text }
        row = fresh
        row["callSummary"] = .string(text)
        row.touch()
        try Database.shared.put(Collections.messages, row)
        return text
    }
}
