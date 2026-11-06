import Foundation

/// 小剧场（网页版 system/theater.js 与 ai/tasks/theater.js，ARCHITECTURE 4.769）。
///
/// 角色按对话自己开一页可以交互的网页。两种写法，由会话自己的设置决定（chat.theater.mode，放在会话菜单里，第 5 条）：
///   inline    角色在回复里直接写整段：[小剧场：主题] HTML [/小剧场]
///   separate  角色只写一行 [小剧场：主题｜一句话梗概]，聊天里落一张封面；你点开时才调一次接口生成（用户点了才调，第 15 条）
/// 单独生成又分两档：free 自由写一页 HTML；template 按选定的那张 HTML 卡片的字段填（样子固定，不跑脚本）。
///
/// 历史里角色读到什么由 inject 决定（每一条也可以单独改）：text 页面里的文字（默认）、code 整段 HTML、none 只有标题。
/// 你在页面里点的那几下（页面调 eira.say）记在 acts 上，跟在后面一行一条 [小剧场互动：…]。
/// 何时开小剧场由角色自己决定（第 22 条），这里不设概率与定时。新功能，默认不注入（NewFeat 的 theater）。
enum Theater {
    static let inline = "inline", separate = "separate"
    static let free = "free", template = "template"
    static let injects = ["text", "code", "none"]
    static let kind = "theater"
    static let task = "theater.page"

    /// 交互记录一条最多多长、最多几条：只是挡住一段写坏的脚本连续不停地报，不是替用户封顶（网页版 ACT_MAX、ACTS_MAX）
    static let actMax = 200
    static let actsMax = 200

    struct Config: Equatable {
        var mode = inline
        var gen = free
        var cardName = ""
        var inject = "text"
        var style = ""
        var words = 0
        var frame = ""
        var bgm = true
        var bgmAuto = true
    }

    /// 网页版 cfgOf：没写过的按 DEFAULTS
    static func cfg(_ chat: Chat?) -> Config {
        let o = chat?.row["theater"]?.object ?? [:]
        var c = Config()
        c.mode = o["mode"]?.string == separate ? separate : inline
        c.gen = o["gen"]?.string == template ? template : free
        c.cardName = o["cardName"]?.string ?? ""
        let inj = o["inject"]?.string ?? "text"
        c.inject = injects.contains(inj) ? inj : "text"
        c.style = o["style"]?.string ?? ""
        let w = o["words"]?.number ?? Double(o["words"]?.string ?? "") ?? 0
        c.words = max(0, Int(w.isFinite ? w : 0))
        c.frame = o["frame"]?.string ?? ""
        c.bgm = o["bgm"]?.bool != false
        c.bgmAuto = o["bgmAuto"]?.bool != false
        return c
    }

    /// 改这段会话的小剧场设置。只动给出的几个键，其余原样（网页版 setCfg）
    static func setCfg(_ chatId: String, _ patch: [String: JSONValue]) throws {
        guard var chat = try Repo.chat(chatId) else { return }
        let c = cfg(chat)
        var o = chat.row["theater"]?.object ?? [:]
        let base: [String: JSONValue] = [
            "mode": .string(c.mode), "gen": .string(c.gen), "cardName": .string(c.cardName), "inject": .string(c.inject),
            "style": .string(c.style), "words": .number(Double(c.words)), "frame": .string(c.frame),
            "bgm": .bool(c.bgm), "bgmAuto": .bool(c.bgmAuto),
        ]
        for (k, v) in base where o[k] == nil { o[k] = v }
        for (k, v) in patch { o[k] = v }
        chat.row["theater"] = .object(o)
        chat.row.touch()
        try Repo.save(chat)
    }

    /// 这项能力开着吗：新功能（按这个角色）选了开启，能力开关里也没关（网页版 theaterCapOn）
    static func capOn(_ char: Character?, _ s: AppSettings = .load()) -> Bool {
        let off = Set((s.raw["capsOff"]?.array ?? []).compactMap(\.string))
        return NewFeat.isOn("theater", s, char: char) && !off.contains("theater")
    }

    // MARK: - 页面里的文字

    private static let blockTag = try! NSRegularExpression(pattern:
        #"</?(?:p|div|br|li|ul|ol|h[1-6]|section|article|header|footer|tr|table|blockquote|details|summary|button|label)\b[^>]*>"#,
        options: [.caseInsensitive])

    /// 去掉样式、脚本与标签，块级元素换行（网页版 textOf）
    static func textOf(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        for tag in ["script", "style", "template", "noscript"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)\\s*>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = blockTag.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "\n")
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 一条小剧场在上下文里的写法（按它自己的 inject）。网页版 promptOf，一字不差
    static func promptOf(_ t: [String: JSONValue]) -> String {
        let title = (t["title"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "小剧场"
        let brief = t["brief"]?.string ?? ""
        let html = t["html"]?.string ?? ""
        let inj = t["inject"]?.string ?? "text"
        let how = injects.contains(inj) ? inj : "text"
        let acts = (t["acts"]?.array ?? []).compactMap(\.string).map { "[小剧场互动：\($0)]" }
        if html.isEmpty { return (["[小剧场：\(title)\(brief.isEmpty ? "" : "｜" + brief)]"] + acts).joined(separator: "\n") }
        let head = "[小剧场：\(title)]"
        if how == "none" { return ([head] + acts).joined(separator: "\n") }
        let body = how == "code" ? html.trimmingCharacters(in: .whitespacesAndNewlines) : textOf(html)
        return ([head, body, "[/小剧场]"] + acts).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - 背景音乐那一行（网页版 bgm.take，4.862）

    private static let bgmMark = try! NSRegularExpression(pattern: #"[\[【]\s*背景音乐\s*[:：]\s*([^\]】\n]*?)\s*[\]】]"#)

    /// 一律从页面里摘掉；摘出来的歌名交回去。原生版的背景音乐播放尚未提供，歌名记在这一条上（bgmQuery），以后做到时直接用
    static func takeBgm(_ text: String) -> (text: String, q: String) {
        let ns = text as NSString
        let ms = bgmMark.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return (text, "") }
        var q = ""
        for m in ms where q.isEmpty {
            q = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
        let out = bgmMark.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out, q)
    }

    // MARK: - 落成一条

    /// 角色写的那一段落成一条消息（不入库，由调用方 append）。html 为空就是封面（单独生成那一档）
    static func make(chat: Chat, char: Character, title: String, brief: String, html page: String, turnId: String) -> Message {
        let c = cfg(chat)
        let bg = takeBgm(page)
        let html = bg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var t: [String: JSONValue] = [
            "title": .string(title.trimmingCharacters(in: .whitespaces).isEmpty ? "小剧场" : title.trimmingCharacters(in: .whitespaces)),
            "brief": .string(brief.trimmingCharacters(in: .whitespaces)),
            "html": .string(html),
            "inject": .string(c.inject),
            "acts": .array([]),
            // 生成的那一档：free 是一页 HTML；template 存卡片名与填好的值（card），画的时候按卡片画
            "gen": .string(html.isEmpty ? c.gen : ""),
        ]
        if !bg.q.isEmpty { t["bgmQuery"] = .string(bg.q) }
        var m = Message.new(chatId: chat.id, role: .char, authorId: char.id, content: promptOf(t), kind: kind, turnId: turnId)
        m.row["theater"] = .object(t)
        return m
    }

    static func message(_ id: String) -> Message? {
        guard let row = (try? Database.shared.get(Collections.messages, id: id)) ?? nil else { return nil }
        let m = Message(row: row)
        return m.kind == kind ? m : nil
    }

    @discardableResult
    private static func patch(_ id: String, _ fn: (inout [String: JSONValue]) -> Void) throws -> Message? {
        guard var m = message(id) else { return nil }
        var t = m.row["theater"]?.object ?? [:]
        let before = t
        fn(&t)
        guard t != before else { return m }
        m.row["theater"] = .object(t)
        m.row["content"] = .string(promptOf(t))
        m.row.touch()
        try Repo.save(m)
        NotificationCenter.default.post(name: .eiraChatChanged, object: m.chatId)
        return m
    }

    /// 改这一条进上下文的方式
    static func setInject(_ id: String, _ inject: String) throws {
        try patch(id) { $0["inject"] = .string(injects.contains(inject) ? inject : "text") }
    }

    /// 你在页面里点了一下（页面调 eira.say）。同一句连着报只记一次
    @discardableResult
    static func act(_ id: String, _ text: String) throws -> Bool {
        // 有意截断：盒子里外来网页传出来的字
        let s = String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(actMax))
        guard !s.isEmpty else { return false }
        var added = false
        try patch(id) { t in
            var acts = (t["acts"]?.array ?? []).compactMap(\.string)
            if acts.last == s || acts.count >= actsMax { return }
            acts.append(s)
            t["acts"] = .array(acts.map { .string($0) })
            added = true
        }
        return added
    }

    /// 清掉交互记录（再看一遍从头来）
    static func clearActs(_ id: String) throws {
        try patch(id) { $0["acts"] = .array([]) }
    }

    /// 单独生成那一档写好了：free 交 html；template 交卡片名与值，html 存一份文字版供上下文用
    static func fillIn(_ id: String, html: String, card: [String: JSONValue]? = nil, bgm: String = "") throws -> Message? {
        let bg = takeBgm(html)
        return try patch(id) { t in
            t["html"] = .string(bg.text.trimmingCharacters(in: .whitespacesAndNewlines))
            t["card"] = card.map { .object($0) } ?? .null
            let q = bg.q.isEmpty ? bgm : bg.q
            if !q.isEmpty { t["bgmQuery"] = .string(q) }
        }
    }

    // MARK: - 打开时生成（网页版 ai/tasks/theater.js）

    static func key(_ msgId: String) -> String { "theater:\(msgId)" }

    /// 文风、字数、框架（网页版 capabilities.theaterNeeds）。没写的不出现。背景音乐那一句要等原生版有了背景音乐才给
    static func needs(_ c: Config, _ s: AppSettings) -> String {
        [c.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ""
            : Templates.render("skeleton.theater-style", ["style": c.style.trimmingCharacters(in: .whitespacesAndNewlines)], settings: s),
         c.words > 0 ? Templates.render("skeleton.theater-words", ["words": String(c.words)], settings: s) : "",
         c.frame.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ""
            : Templates.render("skeleton.theater-frame", ["frame": c.frame.trimmingCharacters(in: .whitespacesAndNewlines)], settings: s)]
            .filter { !$0.isEmpty }.map { "\n" + $0 }.joined()
    }

    /// 能力说明里小剧场那一段：直接写那一档给整段写法与文风；打开时生成那一档只说写一行封面
    static func capText(_ chat: Chat, _ s: AppSettings) -> String {
        let c = cfg(chat)
        if c.mode == separate { return Templates.get("skeleton.theater-cover", settings: s) }
        return Templates.render("skeleton.theater", ["needs": needs(c, s)], settings: s)
    }

    /// 回来的整页：可能包在 ```html 里，也可能照着角色那种写法带了 [小剧场：…] [/小剧场]
    static func pageOf(_ raw: String) -> String {
        var s = ReplyParser.stripThink(raw).0.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = s.range(of: #"[\[【]\s*(?:小剧场|theater)\s*[:：][^\]】\n]*[\]】]"#, options: [.regularExpression, .caseInsensitive]) {
            var rest = String(s[m.upperBound...])
            if let e = rest.range(of: #"[\[【]\s*/\s*(?:小剧场|theater)\s*[\]】]"#, options: [.regularExpression, .caseInsensitive]) {
                rest = String(rest[..<e.lowerBound])
            }
            s = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let f = s.range(of: #"```[a-zA-Z]*[ \t]*\n?([\s\S]*?)```"#, options: .regularExpression) {
            s = String(s[f]).replacingOccurrences(of: #"^```[a-zA-Z]*[ \t]*\n?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    private static func recentOf(_ chatId: String, _ char: Character) -> String {
        let list = ((try? Repo.messages(chatId: chatId, limit: 80)) ?? [])
            .filter { !$0.isError && $0.kind != "side" && $0.kind != kind && !$0.content.isEmpty }
            .suffix(40)
        return list.map { "\($0.role == .user ? "User" : char.name)：\($0.content)" }.joined(separator: "\n")
    }

    /// 点「开幕」：调一次接口，写好这一页。失败抛出，原因写在幕布上
    @discardableResult
    static func generate(_ msgId: String) async throws -> Message? {
        guard let msg = message(msgId) else { throw StoreError(message: "该小剧场已不存在") }
        guard let chat = try Repo.chat(msg.chatId),
              let char = try Repo.character(msg.authorId) ?? chat.characterIds.first.flatMap({ try Repo.character($0) }) else {
            throw StoreError(message: "这段对话已不存在")
        }
        let s = AppSettings.load()
        let c = cfg(chat)
        let t = msg.row["theater"]?.object ?? [:]
        var base: [String: String] = [
            "charName": char.name.isEmpty ? "该角色" : char.name,
            "charPersona": char.persona.isEmpty ? "(no character card was written)" : char.persona,
            "title": (t["title"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "小剧场",
            "brief": (t["brief"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "(none)",
            "recent": { let r = recentOf(msg.chatId, char); return r.isEmpty ? "(none)" : r }(),
            "needs": needs(c, s),
        ]
        if t["gen"]?.string == template {
            guard !c.cardName.isEmpty, let entry = HtmlCard.resolve(bookId: "", entryId: "", name: c.cardName, char: char) else {
                throw StoreError(message: "会话设置里选定的卡片已不存在，可在「小剧场」中重新选择")
            }
            base["name"] = entry.name
            base["card"] = HtmlCard.promptList([entry])
            let r = try await AIService.shared.send(task: task, system: Templates.render("task.theater-card", base, settings: s),
                                                    messages: [AIMessage(role: .user, content: "Fill in the card.")], maxTokens: 3000)
            let text = ReplyParser.stripThink(r.text).0
            var body = text
            if let m = text.range(of: #"[\[【]\s*(?:卡片|card)\s*[:：][^\]】\n]*[\]】]"#, options: [.regularExpression, .caseInsensitive]) {
                body = String(text[m.upperBound...])
                if let e = body.range(of: #"[\[【]\s*/\s*(?:卡片|card)\s*[\]】]"#, options: [.regularExpression, .caseInsensitive]) {
                    body = String(body[..<e.lowerBound])
                }
            }
            let values = HtmlCard.parseValues(body.trimmingCharacters(in: .whitespacesAndNewlines), fields: entry.fields)
            guard !values.isEmpty else { throw StoreError(message: "模型没有给出任何字段内容") }
            // 上下文里用的那一份文字版：按卡片填好的 HTML（textOf 只取字）
            let filled = HtmlCard.fill(entry.card, values: values, sys: ["char": char.name, "user": ""])
            return try fillIn(msgId, html: filled, card: ["name": .string(entry.name), "bookId": .string(entry.bookId),
                                                         "entryId": .string(entry.id), "values": .object(values)],
                              bgm: takeBgm(text).q)
        }
        let r = try await AIService.shared.send(task: task, system: Templates.render("task.theater", base, settings: s),
                                                messages: [AIMessage(role: .user, content: "Write the page.")], maxTokens: 9000)
        let page = pageOf(r.text)
        guard page.range(of: #"<[a-zA-Z]"#, options: .regularExpression) != nil else { throw StoreError(message: "模型没有写出页面") }
        return try fillIn(msgId, html: page)
    }

    // MARK: - 盒子里的那一页（网页版 docOf、sayOf）

    /// 盒子与外面唯一的那条通道：页面里只有 eira.say(text)，往外报一句「你做了什么」
    static let channel = "eiraTheater"

    /// 页面里的桥：最多报 500 次，每次最多 200 字（有意截断：盒子里外来网页传出来的字）
    static let bridge = "(function(){var n=0;window.eira={say:function(t){if(++n>500)return;"
        + "try{window.webkit.messageHandlers.\(channel).postMessage({eiraTheater:1,say:String(t==null?\"\":t).slice(0,200)})}catch(e){}}}})()"

    static let baseCSS = "<style>html,body{margin:0;padding:0;min-height:100%}"
        + "html{-webkit-text-size-adjust:100%;text-size-adjust:100%}"
        + "body{font-family:-apple-system,BlinkMacSystemFont,\"PingFang SC\",\"Helvetica Neue\",\"Microsoft YaHei\",sans-serif;"
        + "overflow-wrap:anywhere;line-height:1.6}img{max-width:100%}</style>"

    /// 角色写的（或单独生成的）那一页，包成整页：CSP 在最前面（不许联网，与主屏自定义组件同一份），桥在页面自己的脚本之前
    static func docOf(_ html: String) -> String {
        CustomWidget.wrap(baseCSS + html, bridge: bridge, images: false)
    }

    /// 外面收到的那一条是不是这个页面报上来的一句（只认主页面）
    static func sayOf(_ body: Any, mainFrame: Bool) -> String? {
        guard mainFrame, let d = body as? [String: Any], (d["eiraTheater"] as? NSNumber)?.intValue == 1,
              let s = d["say"] as? String else { return nil }
        return s
    }
}
