import Foundation
import UIKit

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
    /// 视频通话要说一句是视频：画面挂在对方的话上，不说模型不知道那是摄像头；对方看得见，动作单独写成 [动作：…]（网页版 4.483）。
    /// 这段对话设了翻译语言时，每句后面跟 [译文：…]，同一次回复里写，不另调接口（网页版 4.633）
    static func prepare(chat: Chat, char: Character, video: Bool = false) throws -> Prepared {
        let s = AppSettings.load().forChat(chat)
        let lang = transLang(chat)
        let rule = Templates.render("skeleton.call", [
            "kind": video ? "a video call" : "a phone call",
            "camera": video ? "Images attached to their turns are frames from their camera." : "",
            "actions": Templates.get(video ? "skeleton.call-video" : "skeleton.call-voice", settings: s),
            "translation": lang.isEmpty ? Templates.get("skeleton.call-notrans", settings: s)
                : Templates.render("skeleton.call-translate", ["lang": lang], settings: s),
        ], settings: s)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        // 语音台本：开着时由通话模型在台词里直接标停顿与情绪，不另调接口；规则是用户的语音世界书，整本给出
        var script = ""
        if PromptWrite.voiceOn(s) {
            let rules = PromptWrite.voiceBook(char: char)
            script = Templates.render("skeleton.call-script", ["rules": rules.isEmpty ? "" : "Delivery rules written by the user:\n\(rules)"], settings: s)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let built = try ChatPrompt.build(chat: chat, char: char, settings: s, call: (rule: rule, script: script))
        return Prepared(system: built.system, history: built.messages)
    }

    /// 通话中的一轮。opening 是「电话刚接通，你先开口」这一类一次性的指示。
    /// image：视频通话里我这边摄像头的那一帧，挂在我最后说的那句上；挂不上就自己起一条（网页版 streamCall）
    static func turn(_ p: Prepared, lines: [Line], opening: String = "", image: AIImage? = nil,
                     onDelta: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let talk = lines.map { AIMessage(role: $0.role == "user" ? .user : .assistant, content: $0.text) }
        let tail = opening.isEmpty ? [] : [AIMessage(role: .user, content: opening)]
        var messages = mergeAdjacent(p.history + talk + tail)
        if let image {
            if let i = messages.lastIndex(where: { $0.role == .user }) { messages[i].images.append(image) }
            else { messages.append(AIMessage(role: .user, content: "(this is the view from my side)", images: [image])) }
        }
        let max = Int(AppSettings.load().raw["callMaxTokens"]?.number ?? 400)
        let r = try await AIService.shared.send(task: "chat.call", system: p.system, messages: messages,
                                                maxTokens: max, retries: 1, onDelta: onDelta)
        return clean(r.text)
    }

    static func openingLine(outgoing: Bool) -> String {
        Templates.render("task.call-open", ["origin": outgoing ? "; they called you" : "; you called them"], settings: .load())
    }

    /// 去掉思考段。动作与译文原样留着：下一轮还给模型时它看得到自己的写法
    static func clean(_ raw: String) -> String {
        ReplyParser.stripThink(raw).0.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 存进聊天记录正文的写法：[动作：…] 换成（…）。
    static func prose(_ text: String) -> String {
        text.replacingOccurrences(of: actRe, with: "（$1）", options: .regularExpression)
    }

    /// 随回复写译文的那一档才在通话里写 [译文：…]：这段对话设了翻译语言
    static func transLang(_ chat: Chat) -> String {
        chat.row.string("translateTo").trimmingCharacters(in: .whitespaces)
    }

    // 动作与译文（网页版 call.js 的 ACT、TR 与没写完的那半个）
    static let actRe = #"[\[【]\s*动作\s*[:：]\s*([^\]】]*)[\]】]"#
    static let transRe = #"[ \t]*[\[【]\s*译文\s*[:：]\s*([^\]】]*)[\]】]"#
    private static let actHalf = #"[\[【](\s*动(\s*作(\s*[:：][^\]】]*)?)?)?\s*$"#
    private static let transHalf = #"[\[【](\s*译(\s*文(\s*[:：][^\]】]*)?)?)?\s*$"#

    private static func drop(_ s: String, _ p: String) -> String {
        s.replacingOccurrences(of: p, with: "", options: .regularExpression)
    }

    /// 念出来的部分：动作、译文不念，没写完的那半个从开口处起不念
    static func speakable(_ text: String) -> String {
        drop(drop(drop(drop(text, transRe), transHalf), actRe), actHalf).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 字幕：动作换成（…），译文另起一行；流式时没写完的半个先不显示
    static func subtitle(_ text: String) -> String {
        let t = VoiceScript.plain(drop(drop(text, transHalf), actHalf))
        return prose(t).replacingOccurrences(of: transRe, with: "\n$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 最近一个写完的动作（画面上叠着的那一行）
    static func lastAct(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: actRe) else { return "" }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let v = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        return ""
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

    static func label(direction: String, outcome: String, seconds: Int, video: Bool = false) -> String {
        let what = video ? "视频通话" : "语音通话"
        switch outcome {
        case "done": return "\(what) \(duration(seconds))"
        case "missed": return direction == "out" ? "\(what)未接听" : "未接\(what)"
        case "declined": return direction == "out" ? "\(what)已被拒接" : "\(what)已拒接"
        default: return "\(what)已取消"
        }
    }

    /// 挂断：合成一条通话记录。接通过、有对白的，按设置写总结（默认开）。
    @discardableResult
    static func finish(chatId: String, charId: String, direction: String, outcome: String, seconds: Int,
                       lines: [Line], userName: String, charName: String, video: Bool = false) throws -> Message {
        let me = userName.isEmpty ? "我" : userName
        let body = lines.map { "\($0.role == "user" ? me : (charName.isEmpty ? "对方" : charName))：\(prose($0.text))" }.joined(separator: "\n")
        let out = direction == "out"
        var m = Message.new(chatId: chatId, role: out ? .user : .char, authorId: out ? "me" : charId,
                            content: "[\(label(direction: direction, outcome: outcome, seconds: seconds, video: video))]" + (body.isEmpty ? "" : "\n" + body),
                            kind: "call")
        m.row["direction"] = .string(direction)
        m.row["outcome"] = .string(outcome)
        m.row["seconds"] = .number(Double(seconds))
        m.row["callLog"] = .array(lines.map(\.json))
        m.row["callKind"] = .string(video ? "video" : "voice")
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

    // MARK: - 角色打进来（网页版 call.ring，回复里的 [去电]）

    /// 角色在回复里写了 [去电]。正看着这段对话就响铃；不在就直接记一条未接来电（网页版：人不在这段对话里就不响铃）。
    /// 打不打由角色自己决定（第 22 条）；这里只落成状态，不调接口。接起来之后每轮的花费和自己打出去一样
    @MainActor
    static func ring(chatId: String, charId: String, video: Bool = false) {
        if UIApplication.shared.applicationState == .active && Notifier.shared.visibleChat == chatId {
            NotificationCenter.default.post(name: .eiraIncomingCall, object: chatId, userInfo: ["video": video])
            return
        }
        do { try missed(chatId: chatId, charId: charId, video: video) }
        catch { Problems.report("未接来电未能记下：\(error.localizedDescription)") }
    }

    /// 记一条未接来电
    @discardableResult
    static func missed(chatId: String, charId: String, video: Bool = false) throws -> Message {
        let m = try finish(chatId: chatId, charId: charId, direction: "in", outcome: "missed", seconds: 0, lines: [], userName: "", charName: "", video: video)
        if var c = try Repo.chat(chatId) {
            c.row["unread"] = .number(Double(c.unread + 1))
            try Repo.save(c)
        }
        NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
        return m
    }
}

extension Notification.Name {
    /// 角色打来电话（object 是 chatId）。正开着那段会话的页面弹出来电
    static let eiraIncomingCall = Notification.Name("eira.incomingCall")
}
