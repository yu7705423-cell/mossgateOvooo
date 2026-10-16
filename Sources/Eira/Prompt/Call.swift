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
    /// 一句原文、一句译文（网页版 call.js 的 segs，4.633）
    struct Seg: Equatable, Sendable {
        var t: String
        var tr: String
    }

    struct Line: Equatable, Sendable {
        var role: String           // user | char
        var text: String
        var audio: [String] = []   // 这一句合成出来的声音（files 的 id）
        /// 台词后面括起来的那一截正好是这段对话要的译文时，直接当译文（4.478）
        var trans: String = ""
        /// 单独的翻译接口逐句翻回来的（4.633）
        var segs: [Seg] = []

        var json: JSONValue {
            var o: [String: JSONValue] = ["role": .string(role), "text": .string(text)]
            if !audio.isEmpty { o["audio"] = .array(audio.map { .string($0) }) }
            if !trans.isEmpty { o["trans"] = .string(trans) }
            if !segs.isEmpty { o["segs"] = CallEngine.segsJSON(segs) }
            return .object(o)
        }
    }

    static func segsJSON(_ segs: [Seg]) -> JSONValue {
        .array(segs.map { .object(["t": .string($0.t), "tr": .string($0.tr)]) })
    }

    struct Prepared: Sendable {
        var system: String
        var history: [AIMessage]
    }

    /// 接通时拼一次。聊天记录照常带上，后面不挂此刻的状态与召回。
    /// 视频通话要说一句是视频：画面挂在对方的话上，不说模型不知道那是摄像头；对方看得见，动作单独写成 [动作：…]（网页版 4.483）。
    /// 这段对话设了翻译语言、并且译文是「随回复一起」时，每句后面跟 [译文：…]，同一次回复里写，不另调接口；
    /// 单独配了翻译接口的，模型不写译文，一轮说完逐句交给那个接口（网页版 inlineLang，4.633）
    static func prepare(chat: Chat, char: Character, video: Bool = false) throws -> Prepared {
        let s = AppSettings.load().forChat(chat)
        let lang = transLang(chat, settings: s)
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

    /// 随回复写译文的那一档才在通话里写 [译文：…]：这段对话设了翻译语言，并且没有单独配翻译接口（网页版 inlineLang）
    static func transLang(_ chat: Chat, settings: AppSettings = .load()) -> String {
        settings.translateMode == "inline" ? targetLang(chat) : ""
    }

    /// 这段对话设的翻译语言，不论译文怎么来
    static func targetLang(_ chat: Chat?) -> String {
        chat?.row.string("translateTo").trimmingCharacters(in: .whitespaces) ?? ""
    }

    // 动作与译文（网页版 call.js 的 ACT、TR 与没写完的那半个）
    static let actRe = #"[\[【]\s*动作\s*[:：]\s*([^\]】]*)[\]】]"#
    static let transRe = #"[ \t]*[\[【]\s*译文\s*[:：]\s*([^\]】]*)[\]】]"#
    private static let actHalf = #"[\[【](\s*动(\s*作(\s*[:：][^\]】]*)?)?)?\s*$"#
    private static let transHalf = #"[\[【](\s*译(\s*文(\s*[:：][^\]】]*)?)?)?\s*$"#

    private static func drop(_ s: String, _ p: String) -> String {
        s.replacingOccurrences(of: p, with: "", options: .regularExpression)
    }

    /// 念出来的部分：动作、译文不念，没写完的那半个从开口处起不念。
    /// 行首或句末标点之后开始、整段括起来的那一截也不念，没收口的括号从开口处起全不念（网页版 call.js speakable，4.478）
    static func speakable(_ text: String) -> String {
        dropParens(drop(drop(drop(drop(text, transRe), transHalf), actRe), actHalf)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 括起来的那一截从哪儿开始算（网页版 PAREN_AT）
    private static let parenAt = try? NSRegularExpression(pattern: #"(^|[\n。！？!?…；;])(\s*)[（(]"#)

    static func dropParens(_ text: String) -> String {
        guard let re = parenAt else { return text }
        var t = text
        var out = ""
        while true {
            let ns = t as NSString
            guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { out += t; break }
            let start = m.range.location + m.range(at: 1).length + m.range(at: 2).length
            out += ns.substring(to: start)
            let after = ns.substring(from: start + 1)
            guard let close = after.range(of: #"[)）]"#, options: .regularExpression) else { break }
            t = String(after[close.upperBound...])
        }
        return out
    }

    // 末尾整段括起来的那一截（网页版 splitNote 的正则）
    private static let noteAtEnd = try? NSRegularExpression(pattern: #"(^|[\n。！？!?…；;])\s*[（(]([^()（）]+)[)）]\s*$"#)

    /// 末尾整段括起来的那几截：main 是前面的台词，note 是括号里的内容（网页版 call.js splitNote）
    static func splitNote(_ text: String) -> (main: String, note: String) {
        var main = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var notes: [String] = []
        guard let re = noteAtEnd else { return (main, "") }
        while true {
            let ns = main as NSString
            guard let m = re.firstMatch(in: main, range: NSRange(location: 0, length: ns.length)) else { break }
            notes.insert(ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines), at: 0)
            main = ns.substring(to: m.range.location + m.range(at: 1).length).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (main, notes.joined(separator: "\n"))
    }

    private static func bare(_ s: String) -> String {
        s.replacingOccurrences(of: #"[\s\p{P}\p{S}]"#, with: "", options: .regularExpression)
    }

    /// 去掉空白、标点、符号之后一字不差（网页版 sameWords）
    static func sameWords(_ a: String, _ b: String) -> Bool { !bare(a).isEmpty && bare(a) == bare(b) }

    /// 去掉空白之后一字不差（网页版 translate.sameText）
    static func sameText(_ a: String, _ b: String) -> Bool {
        a.filter { !$0.isWhitespace } == b.filter { !$0.isWhitespace }
    }

    /// 去掉译文（写完的与没写完的那半个）（网页版 dropTrans）
    static func dropTrans(_ text: String) -> String {
        drop(drop(text, transRe), transHalf)
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一轮说完：台词后面括起来的那一截和原话一样就扔掉；是这段对话要的译文就直接当译文，不再调翻译接口；
    /// 其余留在字幕里，照样不念（网页版 call.js turn 的收尾，4.478）。
    /// text 仍是带台本标记的原文（下一轮原样还给模型），trans 是括号里那句译文
    static func settle(_ raw: String, chat: Chat?) -> (text: String, trans: String) {
        let whole = dropTrans(VoiceScript.plain(raw))
        let (main, note) = splitNote(whole)
        guard !note.isEmpty, !main.isEmpty else { return (raw, "") }
        let lang = targetLang(chat)
        let dup = sameWords(note, main)
        let isTrans = !dup && !lang.isEmpty && alreadyIn(note, lang) && !alreadyIn(main, lang)
        guard dup || isTrans else { return (raw, "") }
        let cut = splitNote(raw)
        // 原文末尾还挂着别的（随回复写的 [译文：…]）切不出来时，用去掉标记的那一句
        let text = cut.note.isEmpty ? main : (cut.main.isEmpty ? raw : cut.main)
        // 随回复逐句写了译文的，以那份为准
        let inline = raw.range(of: transRe, options: .regularExpression) != nil
        return (text, isTrans && !inline ? note : "")
    }

    /// 字幕：动作换成（…），译文另起一行；流式时没写完的半个先不显示
    static func subtitle(_ text: String) -> String {
        let t = VoiceScript.plain(drop(drop(text, transHalf), actHalf))
        return prose(t).replacingOccurrences(of: transRe, with: "\n$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一句的字幕：翻译接口逐句翻回来的，一句原文下面一句译文；括号里那句译文另起一行
    static func subtitle(text: String, trans: String, segs: [Seg]) -> String {
        if segs.contains(where: { !$0.tr.isEmpty }) {
            return segs.map { s in
                let t = subtitle(s.t)
                return s.tr.isEmpty ? t : (t.isEmpty ? s.tr : t + "\n" + s.tr)
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        let t = subtitle(text)
        return trans.isEmpty ? t : t + "\n" + trans
    }

    static func subtitle(_ line: Line) -> String { subtitle(text: line.text, trans: line.trans, segs: line.segs) }

    /// 通话记录里存的那一句（callLog 的一项）
    static func subtitle(log: [String: JSONValue]) -> String {
        let segs = (log["segs"]?.array ?? []).compactMap(\.object).map { Seg(t: $0["t"]?.string ?? "", tr: $0["tr"]?.string ?? "") }
        return subtitle(text: log["text"]?.string ?? "", trans: log["trans"]?.string ?? "", segs: segs)
    }

    /// 说出口的那部分：动作去掉，前后各段以空格相接（网页版 sayOf）
    static func sayOf(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: actRe) else { return text }
        let ns = text as NSString
        var parts: [String] = []
        var at = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            at = m.range.location + m.range.length
        }
        parts.append(drop(ns.substring(from: at), actHalf))
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - 逐句译文（网页版 call.js transLine，4.633）

    /// 单独配了翻译接口时，一轮说完把每一句交给它翻，一句一个译文。随回复写译文那一档不翻（译文已在同一次回复里）。
    /// 已经是目标语言的句子不送；整轮都是目标语言就不调接口。一轮一次请求，不重试；没翻出来回 nil
    static func translateLine(chat: Chat, text: String) async throws -> [Seg]? {
        let s = AppSettings.load()
        let lang = targetLang(chat)
        guard !lang.isEmpty, !text.isEmpty, s.translateMode == "api", let preset = s.translatePreset else { return nil }
        // 按句末标点切成一句一句；[动作：…] 跟着它所在的那一句留在字幕上，但不送去翻（4.483）
        let src = dropTrans(VoiceScript.plain(text))
        var chunks: [String] = []
        if let re = try? NSRegularExpression(pattern: #"(?:[\[【]\s*动作[^\]】]*[\]】]|[^。！？!?…；;\n])+[。！？!?…；;]*"#) {
            let ns = src as NSString
            chunks = re.matches(in: src, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        }
        if chunks.isEmpty { chunks = [src] }
        chunks = chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let sents = chunks.map { (c: $0, say: sayOf($0)) }
        var todo: [String] = []
        for x in sents where !x.say.isEmpty && !alreadyIn(x.say, lang) && !todo.contains(x.say) { todo.append(x.say) }
        // 已经是目标语言：不翻，不显示第二行（中译中）
        guard !todo.isEmpty else { return nil }
        let p = TranslateOne.payload(todo, lang: lang, extra: TranslateOne.rulesOf(chat, s), settings: s)
        let r = try await AIService.shared.send(task: "translate.lines", preset: preset, system: p.system,
                                                messages: [AIMessage(role: .user, content: p.user)],
                                                maxTokens: max(600, todo.joined().count * 4))
        let out = TranslateOne.rows(r.text, want: todo.count)
        var map: [String: String] = [:]
        for (i, x) in todo.enumerated() { map[x] = i < out.count ? out[i].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
        let segs = sents.map { x -> Seg in
            let tr = map[x.say] ?? ""
            return Seg(t: x.c, tr: tr.isEmpty || sameText(tr, x.say) ? "" : tr)
        }
        return segs.contains(where: { !$0.tr.isEmpty }) ? segs : nil
    }

    /// 翻得比挂断慢时，写回刚落下的那条通话记录（网页版：不补回去的话最后那一句在记录里永远没有译文）
    static func storeSegs(messageId: String, index: Int, text: String, segs: [Seg]) throws {
        guard var row = try Database.shared.get(Collections.messages, id: messageId),
              var log = row["callLog"]?.array, log.indices.contains(index),
              var o = log[index].object, o["text"]?.string == text else { return }
        o["segs"] = segsJSON(segs)
        log[index] = .object(o)
        row["callLog"] = .array(log)
        row.touch()
        try Database.shared.put(Collections.messages, row)
    }

    // MARK: - 已经是那种语言了就不翻（网页版 translate.js 的 SAME 与 alreadyIn，4.570）

    private static func hits(_ t: String, _ p: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: p) else { return 0 }
        return re.numberOfMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length))
    }

    private static func has(_ t: String, _ p: String) -> Bool { hits(t, p) > 0 }

    private static func isZh(_ t: String) -> Bool {
        let han = hits(t, #"[\u4e00-\u9fff]"#)
        let letters = t.replacingOccurrences(of: #"[^\p{L}]"#, with: "", options: .regularExpression)
        return han > 0 && !has(t, #"[\u3040-\u30ff\uac00-\ud7af]"#) && han * 2 >= hits(t, "[A-Za-z]")
            && !has(t, #"[A-Za-z]+['’]?[A-Za-z]*[ \t]+['’]?[A-Za-z]"#)
            && !has(t, #"[\u00c0-\u024f]"#)
            && !has(letters, #"[^\p{Script=Han}\p{Script=Latin}]"#)
    }

    /// 这句话是不是已经是 lang 那种语言了。只认中文、日文、韩文、英文；看不出来一律当作不是
    static func alreadyIn(_ text: String, _ lang: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = lang.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !l.isEmpty else { return false }
        let langIs: (String) -> Bool = { l.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        if langIs(#"中文|汉语|漢語|简体|简中|繁体|繁體|繁中|chinese|^zh"#) { return isZh(t) }
        if langIs(#"日[语語文本]|japanese|^ja"#) { return has(t, #"[\u3040-\u30ff]"#) }
        if langIs(#"韩|韓|朝鲜|korean|^ko"#) { return has(t, #"[\uac00-\ud7af]"#) }
        if langIs(#"英|english|^en"#) { return has(t, "[A-Za-z]") && !has(t, #"[\u3040-\u30ff\u4e00-\u9fff\uac00-\ud7af]"#) }
        return false
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

    // MARK: - 接不接你的来电（网页版 call.answerOf / willAnswer，ARCHITECTURE 4.170）
    //
    // 默认总是接。角色卡上「接听你的来电」选了「按作息」（callAnswer: 'schedule'）才看「主动发起对话」里的免打扰时段：
    // 时段内 15% 接，其余时间 90% 接。不为「接不接」单独跑一次模型（第 15 条）。角色打给你的那一路不受影响

    /// 角色卡上的选项，取值与网页版一致：always（默认）/ schedule
    static let answerChoices: [(value: String, label: String)] = [("always", "总是接听"), ("schedule", "按作息")]

    static func answerOf(_ char: Character?) -> String { char?.row["callAnswer"]?.string == "schedule" ? "schedule" : "always" }

    /// 选项下面那一句说明（网页版 AbilitiesPage 的 info），写出当前的免打扰时段
    static func answerInfo(_ char: Character?) -> String {
        if answerOf(char) == "always" { return "你打过去，角色总会接听。" }
        let c = Proactive.config(char)
        let span = c.quietFrom == c.quietTo ? "当前未设置" : "\(c.quietFrom):00 到 \(c.quietTo):00"
        return "按「主动发起对话」中的免打扰时段（\(span)）：时段内多半不接，其余时间偶尔不接，未接时记一条未接来电。"
    }

    /// 这一通接不接。roll 是 0 到 1 之间掷出来的数，测试里传定值
    static func willAnswer(_ char: Character, at date: Date = Date(), roll: Double = Double.random(in: 0..<1)) -> Bool {
        if answerOf(char) == "always" { return true }
        return roll < (Proactive.inQuiet(Proactive.config(char), date) ? 0.15 : 0.9)
    }

    /// 拨出去先响一会儿再接通：2.5 到 6 秒（网页版 dial 的 2500 + random * 3500 毫秒），立刻接通反而假
    static func dialWait(roll: Double = Double.random(in: 0...1)) -> TimeInterval { 2.5 + 3.5 * min(1, max(0, roll)) }

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
