import Foundation

/// 翻译这一条（网页版 MsgMenu 的 translateOne 与 ai/translate.js 的 payload，ARCHITECTURE 4.298）。
///
/// 开了翻译的会话里，角色的一条正文或语音没带译文、或者译文不对，单独翻这一条。
/// 只送这一句和这段会话的翻译要求，人设、记忆、历史一个字都不送。
/// 用户点了才调，一次一条（手动的不算自动多调）。
enum TranslateOne {
    /// 翻译要求：设置里对所有对话生效的那一栏，加上这段对话自己的（网页版 4.588），两处同时生效
    static func rulesOf(_ chat: Chat, _ s: AppSettings) -> String {
        [s.raw["translateRules"]?.string ?? "", chat.row.string("translateRules")]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 要翻的那一段：语音取说的话，文字取正文，其余没有
    static func source(_ m: Message) -> String {
        switch m.kind {
        case "voice": return MessageActions.bodyText(m)
        case "text", "": return m.content.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return ""
        }
    }

    /// 这一条能不能翻：会话开了翻译、是角色说的、有可翻的正文
    static func can(_ m: Message, lang: String) -> Bool {
        !lang.isEmpty && m.role != .user && !m.isError && !m.isRecalled && !source(m).isEmpty
    }

    static func payload(_ texts: [String], lang: String, extra: String, settings: AppSettings) -> (system: String, user: String) {
        let rules = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = Templates.render("task.translate", [
            "lang": lang.isEmpty ? "中文" : lang,
            "extra": rules.isEmpty ? "" : "\n## Additional requirements for this conversation\n\(rules)\n",
        ], settings: settings)
        let user = texts.enumerated().map { "\($0.offset + 1). \($0.element.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
        return (system, user)
    }

    /// 模型回来的东西理成几行：{"lines":[…]}、整个是数组、换了键名、整批挤在一条里，或者直接回了译文
    static func rows(_ raw: String, want: Int) -> [String] {
        let strip: (String) -> String = {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^\d+\s*[.、)）]\s*"#, with: "", options: .regularExpression)
        }
        var rows: [String] = []
        if let j = JSONReply.parse(raw) {
            if case .array(let a) = j { rows = a.compactMap(\.string) }
            else if case .object(let o) = j {
                for k in ["lines", "translations", "output"] {
                    if case .array(let a)? = o[k] { rows = a.compactMap(\.string); break }
                }
            }
            if rows.count == 1 && want > 1 && rows[0].contains("\n") {
                rows = rows[0].split(separator: "\n").map(String.init)
            }
            return rows.map(strip).filter { !$0.isEmpty }
        }
        // 没按 JSON 回、直接回了译文：一句对一句，或者行数正好对得上
        let body = ReplyParser.stripThink(raw).0
            .replacingOccurrences(of: #"^```\w*\s*|```\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.first != "{", body.first != "[" else { return [] }
        let lines = body.split(separator: "\n").map { strip(String($0)) }.filter { !$0.isEmpty }
        if want == 1 { return [lines.joined(separator: " ")] }
        return lines.count == want ? lines : []
    }

    /// 翻一条，写回这条消息的译文。走副用接口（任务 translate.lines）
    static func run(_ m: Message, chat: Chat) async throws -> Message {
        let src = source(m)
        let lang = chat.row.string("translateTo")
        guard can(m, lang: lang) else { throw StoreError(message: "这一条不能翻译") }
        let s = AppSettings.load()
        let p = payload([src], lang: lang, extra: rulesOf(chat, s), settings: s)
        let r = try await AIService.shared.send(task: "translate.lines", preset: s.translatePreset, system: p.system,
                                                messages: [AIMessage(role: .user, content: p.user)],
                                                maxTokens: max(600, src.count * 4), retries: 1)
        guard let out = rows(r.text, want: 1).first, !out.isEmpty else { throw StoreError(message: "没有得到译文") }
        guard let fresh = try Repo.messages(chatId: m.chatId).first(where: { $0.id == m.id }) else {
            throw StoreError(message: "这条消息已不存在")
        }
        return try MessageActions.setTranslation(fresh, out)
    }

    // MARK: - 单独那套翻译接口（网页版 reply.js 的 startTranslate / applyTranslate）

    /// 这一轮落下的几条里要翻的：文字、语音、旁白没有译文的，文字上的心声没有译文的。一批一次请求
    static func items(_ created: [Message]) -> [(id: String, field: String, text: String)] {
        var out: [(id: String, field: String, text: String)] = []
        for m in created where m.role == .char && !m.isError {
            switch m.kind {
            case "text", "voice":
                let t = source(m)
                if !t.isEmpty && m.row.string("translation").isEmpty { out.append((m.id, "translation", t)) }
            case "narration":
                let t = m.row.string("narration").isEmpty ? m.content : m.row.string("narration")
                if !t.isEmpty && m.row.string("translation").isEmpty { out.append((m.id, "translation", t)) }
            default: break
            }
            let inner = m.row.string("inner")
            if m.kind == "text" && !inner.isEmpty && m.row.string("innerTrans").isEmpty { out.append((m.id, "innerTrans", inner)) }
        }
        return out
    }

    /// 开了单独的翻译接口时，这一轮的译文由它来给。翻译挂了不连累这一轮：原文已经发出去，少一行译文而已
    @discardableResult
    static func applyApi(chat: Chat, created: [Message]) async -> Int {
        let s = AppSettings.load()
        let lang = chat.row.string("translateTo").trimmingCharacters(in: .whitespaces)
        guard !lang.isEmpty, s.translateMode == "api", let preset = s.translatePreset else { return 0 }
        let list = items(created)
        guard !list.isEmpty else { return 0 }
        let p = payload(list.map(\.text), lang: lang, extra: rulesOf(chat, s), settings: s)
        do {
            let r = try await AIService.shared.send(task: "translate.lines", preset: preset, system: p.system,
                                                    messages: [AIMessage(role: .user, content: p.user)],
                                                    maxTokens: max(600, list.map(\.text).joined().count * 4))
            let out = rows(r.text, want: list.count)
            var n = 0
            for (k, it) in list.enumerated() where k < out.count {
                let t = out[k].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t.filter({ !$0.isWhitespace }) != it.text.filter({ !$0.isWhitespace }),
                      var row = try Database.shared.get(Collections.messages, id: it.id) else { continue }
                row[it.field] = .string(t)
                row.touch()
                try Database.shared.put(Collections.messages, row)
                n += 1
            }
            if n > 0 { await MainActor.run { NotificationCenter.default.post(name: .eiraChatChanged, object: chat.id) } }
            return n
        } catch {
            Diagnostics.shared.record("translate-failed", ["error": error.localizedDescription])
            return 0
        }
    }
}
