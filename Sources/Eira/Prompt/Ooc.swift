import Foundation

/// 场外（Meta 模式，网页版 system/ooc.js 与 ai/tasks/ooc.js，ARCHITECTURE 4.819）。
///
/// 三件事，都挂在这一段会话上（chat.ooc），开关在会话菜单「场外」那一页（网页版第 5 条），单聊才有：
///   一、场外问答（默认关）：输入栏上方的「场外」，或以触发词开头（默认 ooc）。发出去的是这一轮照常拼好的上下文，
///       末尾接一段「对照角色卡复盘」的说明（四家各一份，templates.json 的 task.ooc-review-*）。问与答都落成 kind ooc，
///       角色读不读得到由「角色可见」决定，默认读不到。不进记忆。一次提问一次请求，任务 chat.ooc。
///   二、自动检查（默认关，第 15 条，登记在 ExtraCalls 的 oocCheck）：每轮回复落下之后另起一次（任务 ooc.check），
///       **先在这一轮第一条上记 oocCheck: tried 再发**，同一轮不再自动检查第二次；结果 ok / issues / failed 写在那一条上。
///       发现冲突时只标出，或者按检查结果重写这一轮（oocRewrite，次数由「最多自动重写几次」定，默认 1）。
///   三、存为世界书：场外的答复、检查结果、长按的消息，存成一条常驻条目。默认存进「角色名 的纠偏」（书上记 oocFor，第一次存时建，挂到角色上）。
enum Ooc {
    static let kind = "ooc"
    struct Style: Hashable, Sendable { let value: String; let label: String }
    static let styles: [Style] = [
        Style(value: "auto", label: "按模型自动选择"), Style(value: "claude", label: "Claude"), Style(value: "gpt", label: "GPT"),
        Style(value: "gemini", label: "Gemini"), Style(value: "deepseek", label: "DeepSeek"), Style(value: "custom", label: "自定义"),
    ]

    struct Cfg: Equatable {
        var on = false
        var trigger = "ooc"
        var visible = false
        var style = "auto"
        var customReview = ""
        var customCheck = ""
        var check = false
        var checkMode = "mark"
        var rewriteMax = 1
        var bookId = ""
    }

    static func cfg(_ c: Chat?, lorebooks: [Lorebook]? = nil) -> Cfg {
        let o = c?.row["ooc"]?.object ?? [:]
        var out = Cfg()
        out.on = o["on"]?.bool == true
        out.visible = o["visible"]?.bool == true
        out.check = o["check"]?.bool == true
        out.checkMode = o["checkMode"]?.string == "rewrite" ? "rewrite" : "mark"
        out.rewriteMax = max(0, Int((o["rewriteMax"]?.number ?? 1).rounded()))
        let st = o["style"]?.string ?? ""
        out.style = styles.contains { $0.value == st } ? st : "auto"
        out.trigger = (o["trigger"]?.string ?? "ooc").trimmingCharacters(in: .whitespaces)
        out.customReview = o["customReview"]?.string ?? ""
        out.customCheck = o["customCheck"]?.string ?? ""
        let bid = o["bookId"]?.string ?? ""
        out.bookId = !bid.isEmpty && (lorebooks ?? ((try? Repo.lorebooks()) ?? [])).contains { $0.id == bid } ? bid : ""
        return out
    }

    static func set(_ chatId: String, _ patch: [String: JSONValue]) throws {
        guard var c = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
        var o = c.row["ooc"]?.object ?? [:]
        for (k, v) in patch { o[k] = v }
        c.row["ooc"] = .object(o)
        c.row.touch()
        try Repo.save(c)
        NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
    }

    static func menuLabel(_ c: Chat) -> String {
        let x = cfg(c)
        return x.on || x.check ? "已开启" : "关闭"
    }

    /// 这句话是不是场外：开着、并且以触发词开头（不分大小写，后面跟空格或冒号）。是就交回去掉触发词的那一段
    static func triggered(_ c: Chat?, _ text: String) -> String? {
        let x = cfg(c)
        guard x.on, !x.trigger.isEmpty else { return nil }
        let esc = NSRegularExpression.escapedPattern(for: x.trigger)
        guard let re = try? NSRegularExpression(pattern: #"^\s*"# + esc + #"(?:[\s:：,，]+|$)([\s\S]*)$"#, options: [.caseInsensitive]),
              let m = ReplyParser.match(re, text) else { return nil }
        return m[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 进历史之前：不可见时场外的问答一条都不带；可见时写成两种标记，角色读得出那是场外的话
    static func forPrompt(_ c: Chat?, _ m: Message, visible: Bool? = nil) -> Message? {
        guard m.kind == kind else { return m }
        guard visible ?? cfg(c).visible, !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var out = m
        out.row["kind"] = .string("text")
        out.row["content"] = .string(m.role == .user ? "[场外：\(m.content)]" : "[场外回复：\(m.content)]")
        return out
    }

    /// 四份里用哪一份：按这一轮要用的模型名认，认不出的用 Claude 那一份
    static func styleOf(_ c: Chat?, model: String) -> String {
        let s = cfg(c).style
        if s != "auto" { return s }
        let m = model.lowercased()
        if m.contains("deepseek") { return "deepseek" }
        if m.contains("gemini") || m.contains("gemma") { return "gemini" }
        if m.contains("claude") || m.contains("anthropic") { return "claude" }
        if m.contains("gpt") || m.range(of: #"(^|[^a-z])o\d"#, options: .regularExpression) != nil { return "gpt" }
        return "claude"
    }

    /// 存进世界书的那一条的标题：【错误分类】那一栏，没有就用时间
    static func titleOf(_ text: String, now: Date = Date()) -> String {
        if let r = text.range(of: #"[【\[]\s*错误分类\s*[】\]]\s*[^\n]+"#, options: .regularExpression) {
            let line = String(text[r]).replacingOccurrences(of: #"^[【\[]\s*错误分类\s*[】\]]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "「", with: "").replacingOccurrences(of: "」", with: "").trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return String(line.prefix(30)) }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M-d HH:mm"
        return "纠偏 \(f.string(from: now))"
    }

    struct Issue: Equatable, Sendable {
        var card: String
        var reply: String
        var fix: String
    }

    static func issues(of m: Message) -> [Issue] {
        (m.row["oocIssues"]?.array ?? []).compactMap { v in
            guard let o = v.object else { return nil }
            let i = Issue(card: o["card"]?.string ?? "", reply: o["reply"]?.string ?? "", fix: o["fix"]?.string ?? "")
            return i.card.isEmpty && i.reply.isEmpty && i.fix.isEmpty ? nil : i
        }
    }

    /// 检查结果写成可以存的一段
    static func issuesText(_ list: [Issue]) -> String {
        list.map { i in
            [i.card.isEmpty ? "" : "【角色卡原文】\(i.card)", i.reply.isEmpty ? "" : "【违规行为】\(i.reply)", i.fix.isEmpty ? "" : "【修正逻辑】\(i.fix)"]
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// 交给重写那一轮的修正说明：检查结果写成英文提示里的一段（原文照引）
    static func correctionOf(_ list: [Issue]) -> String {
        list.enumerated().map { n, i in
            "\(n + 1). Card: \(i.card.isEmpty ? "-" : i.card)\n   Draft: \(i.reply.isEmpty ? "-" : i.reply)\n   Fix: \(i.fix.isEmpty ? "-" : i.fix)"
        }.joined(separator: "\n")
    }

    // MARK: - 存为世界书

    /// 一条常驻条目（与网页版 save 同一组字段）
    static func entry(_ body: String, title: String) -> JSONValue {
        .object(["id": .string(Ids.make("e")), "comment": .string(title), "keys": .array([]), "secondaryKeys": .array([]),
                 "content": .string(body), "enabled": .bool(true), "constant": .bool(true), "priority": .number(100),
                 "order": .number(0), "part": .string("before"), "depth": .number(0), "caseSensitive": .bool(false),
                 "probability": .number(100)])
    }

    private static func bookName(_ char: Character?) -> String { "\(char?.name ?? "角色") 的纠偏" }

    /// 这个角色的纠偏书：记在书上（oocFor），没有就建一本；挂到角色上
    static func bookFor(_ charId: String) throws -> Row {
        guard var char = try Repo.character(charId) else { throw StoreError(message: "该角色已不存在") }
        let book: Row
        if let have = ((try? Repo.lorebooks()) ?? []).first(where: { $0.row.string("oocFor") == charId }) {
            book = have.row
        } else {
            book = Row.new(prefix: "lb", ["name": .string(bookName(char)), "description": .string(""), "global": .bool(false),
                                          "entries": .array([]), "oocFor": .string(charId)])
            try Database.shared.put(Collections.lorebooks, book)
        }
        if !char.lorebookIds.contains(book.id) {
            char.row["lorebookIds"] = .array((char.lorebookIds + [book.id]).map { .string($0) })
            char.row.touch()
            try Database.shared.put(Collections.characters, char.row)
        }
        return book
    }

    /// 存成一条常驻条目。bookId 为空时存进「场外」页选的那一本，没选就是这个角色的纠偏书。回书名
    @discardableResult
    static func save(_ chatId: String, text: String, bookId: String = "", title: String = "") throws -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw StoreError(message: "内容不能为空") }
        guard let chat = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
        let want = bookId.isEmpty ? cfg(chat).bookId : bookId
        var book: Row
        if !want.isEmpty, let b = try Database.shared.get(Collections.lorebooks, id: want) { book = b }
        else if let charId = chat.characterIds.first { book = try bookFor(charId) }
        else { throw StoreError(message: "这段会话没有角色") }
        book["entries"] = .array((book["entries"]?.array ?? []) + [entry(body, title: title.isEmpty ? titleOf(body) : title)])
        book.touch()
        try Database.shared.put(Collections.lorebooks, book)
        return book.string("name").isEmpty ? "未命名世界书" : book.string("name")
    }

    /// 「存为世界书」存到哪一本，写在确认页上
    static func targetName(_ chatId: String) -> String {
        let chat = (try? Repo.chat(chatId)) ?? nil
        let books = (try? Repo.lorebooks()) ?? []
        if let b = books.first(where: { $0.id == cfg(chat, lorebooks: books).bookId }) { return b.name.isEmpty ? "未命名世界书" : b.name }
        let charId = chat?.characterIds.first ?? ""
        if let have = books.first(where: { $0.row.string("oocFor") == charId }) { return have.name }
        return bookName(((try? Repo.character(charId)) ?? nil))
    }

    // MARK: - 提示词

    /// 场外那一轮末尾接的复盘说明。自定义的可以用 {{note}} 与 {{char}}；没写 {{note}} 就把你的话接在后面
    static func reviewText(_ c: Chat?, char: Character, note: String, model: String, settings s: AppSettings) -> String {
        let x = cfg(c)
        let style = styleOf(c, model: model)
        let vars = ["note": note.trimmingCharacters(in: .whitespacesAndNewlines), "char": char.name]
        if style == "custom" && !x.customReview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let own = x.customReview
            return Templates.fill(own, vars) + (own.range(of: #"\{\{\s*note\s*\}\}"#, options: .regularExpression) != nil ? "" : "\n\n\(vars["note"] ?? "")")
        }
        return Templates.render("task.ooc-review-\(style == "custom" ? "claude" : style)", vars, settings: s)
    }

    /// 自动检查那一次发什么。DeepSeek 那一份不用系统提示词，说明与材料一起放进用户消息（R1 的官方建议）
    static func checkParts(_ c: Chat?, char: Character, card: String, lore: String, context: String, reply: String,
                           model: String, settings s: AppSettings) -> (system: String, user: String) {
        let x = cfg(c)
        let style = styleOf(c, model: model)
        let data = Templates.render("task.ooc-check-data", [
            "char": char.name, "card": card.isEmpty ? "(empty)" : card, "lore": lore.isEmpty ? "(empty)" : lore,
            "context": context.isEmpty ? "(empty)" : context, "reply": reply,
        ], settings: s)
        let rule = style == "custom" && !x.customCheck.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? x.customCheck : Templates.get("task.ooc-check-\(style == "custom" ? "claude" : style)", settings: s)
        return style == "deepseek" ? ("", "\(rule)\n\n\(data)") : (rule, data)
    }

    private static func modelFor(_ task: String, _ s: AppSettings) -> String {
        AIService.chain(task: task, group: RouteGroup.of(task: task), settings: s).first?.model ?? ""
    }

    // MARK: - 场外问答

    /// 提问：问与答都落成 kind ooc。上下文照常拼（角色卡、世界书都在），末尾接复盘说明。一次提问一次请求。
    /// 问的那一条先落库（失败也留着，屏幕上说），答复成功才落
    @discardableResult
    static func ask(chatId: String, note: String, onAsk: @escaping @Sendable (Message) -> Void = { _ in },
                    onDelta: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Message {
        guard let chat = try Repo.chat(chatId), let charId = chat.characterIds.first, let char = try Repo.character(charId) else {
            throw StoreError(message: "这段会话的角色不存在")
        }
        let s = AppSettings.load().forChat(chat)
        // 先拼再落问的那一条：问的那一句写在末尾的说明里，不再在历史里出现一次
        var built = try ChatPrompt.build(chat: chat, char: char, settings: s)
        let tail = reviewText(chat, char: char, note: note, model: modelFor("chat.ooc", s), settings: s)
        append(&built.messages, tail)
        var ask = Message.new(chatId: chatId, role: .user, authorId: "me", content: note, kind: kind)
        ask = try Repo.append(ask)
        try touchChat(chatId)
        onAsk(ask)
        let r = try await LastSent.$chat.withValue(chatId) {
            try await AIService.shared.send(task: "chat.ooc", system: built.system, messages: built.messages, onDelta: onDelta)
        }
        let text = ReplyParser.stripThink(r.text).0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StoreError(message: "模型返回了空内容") }
        let ans = try Repo.append(Message.new(chatId: chatId, role: .char, authorId: char.id, content: text, kind: kind))
        try touchChat(chatId)
        return ans
    }

    /// 末尾接一段：最后一条是你说的（没有图）就并进去，和网页版 mergeAdjacent 一样用换行接
    static func append(_ list: inout [AIMessage], _ text: String) {
        guard !text.isEmpty else { return }
        if let last = list.last, last.role == .user, last.images.isEmpty { list[list.count - 1].content += "\n" + text }
        else { list.append(AIMessage(role: .user, content: text)) }
    }

    private static func touchChat(_ chatId: String) throws {
        guard var c = try Repo.chat(chatId) else { return }
        c.row["lastMessageAt"] = .number(Date().millis)
        c.row.touch()
        try Repo.save(c)
    }

    // MARK: - 自动检查

    /// 这一轮该不该自动检查：开着、单聊、这一轮第一条上还没有记过（试过的不再自动试）
    static func due(_ c: Chat?, head: Message?) -> Bool {
        guard let c, let head, !c.isGroup, cfg(c).check else { return false }
        return head.row["oocCheck"] == nil || head.row["oocCheck"]?.isNull == true
    }

    private static func said(_ m: Message) -> Bool { !m.isError && !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && m.kind != kind }

    /// 检查最后一轮。条件不满足交回 nil；失败时抛出，结果已经写在那一条上。force：手动点的，不看开关与记号
    @discardableResult
    static func check(chatId: String, force: Bool = false) async throws -> [Issue]? {
        guard let chat = try Repo.chat(chatId), let turn = try ChatEngine.lastTurn(chatId: chatId), var head = turn.rows.first else { return nil }
        if !force && !due(chat, head: head) { return nil }
        guard let charId = chat.characterIds.first, let char = try Repo.character(charId) else { return nil }
        // 先记试过（第 15 条）：成功失败都算，同一轮不再自动检查
        head.row["oocCheck"] = .string("tried")
        head.row["oocIssues"] = .array([])
        head.row["oocError"] = .string("")
        try Repo.save(head)
        let ids = Set(turn.rows.map(\.id))
        let reply = turn.rows.map(\.content).filter { !$0.isEmpty }.joined(separator: "\n")
        let before = try Repo.messages(chatId: chatId, limit: 80).filter { said($0) && !ids.contains($0.id) && $0.createdAt <= head.createdAt }
        let s = AppSettings.load().forChat(chat)
        let context = before.suffix(12).map { m in
            "\(m.role == .user ? "User" : (((try? Repo.character(m.authorId)) ?? nil)?.name ?? char.name)): \(m.content)"
        }.joined(separator: "\n")
        let lore = ChatPrompt.selectLore(char: char, scanText: [context, reply].joined(separator: "\n"), budget: 0).items
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let card = [char.persona, char.scenario].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let parts = checkParts(chat, char: char, card: card, lore: lore, context: context, reply: reply, model: modelFor("ooc.check", s), settings: s)
        do {
            let r = try await AIService.shared.send(task: "ooc.check", system: parts.system, messages: [AIMessage(role: .user, content: parts.user)],
                                                    maxTokens: 1200)
            guard let j = JSONReply.parse(r.text)?.object else { throw StoreError(message: JSONReply.failure(r.text)) }
            let list: [Issue] = (j["issues"]?.array ?? []).compactMap { v in
                guard let o = v.object else { return nil }
                let i = Issue(card: (o["card"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              reply: (o["reply"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              fix: (o["fix"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                return i.card.isEmpty && i.reply.isEmpty && i.fix.isEmpty ? nil : i
            }
            let bad = j["ok"]?.bool == false && !list.isEmpty
            if var h = try Database.shared.get(Collections.messages, id: head.id).map(Message.init(row:)) {
                h.row["oocCheck"] = .string(bad ? "issues" : "ok")
                h.row["oocIssues"] = .array(bad ? list.map { JSONValue.object(["card": .string($0.card), "reply": .string($0.reply), "fix": .string($0.fix)]) } : [])
                try Repo.save(h)
            }
            return bad ? list : []
        } catch {
            if var h = (try? Database.shared.get(Collections.messages, id: head.id)).map(Message.init(row:)) {
                h.row["oocCheck"] = .string("failed")
                h.row["oocError"] = .string(error.localizedDescription)
                try? Repo.save(h)
            }
            throw error
        }
    }

    /// 一轮回复落下之后（网页版 Conversation 的 oocAfter）：检查这一轮；开了自动重写、还没到次数、真有冲突，就按结果重写一次，
    /// 重写后的再检查。round 是已经自动重写过几次；手动点「按检查结果重写」之后传 Int.max，只检查不再重写。
    /// 交回要在屏幕上说的一句（检查没完成、发现冲突正在重写），没有就是 nil
    static func after(chatId: String, round: Int = 0, onRow: @escaping ChatEngine.OnRow = { _ in },
                      say: @escaping @Sendable (String) -> Void = { _ in }) async {
        guard let chat = try? Repo.chat(chatId), let turn = try? ChatEngine.lastTurn(chatId: chatId), due(chat, head: turn.rows.first) else { return }
        let x = cfg(chat)
        do {
            guard let found = try await check(chatId: chatId), !found.isEmpty else { return }
            guard x.checkMode == "rewrite", round < x.rewriteMax else { return }
            say("OOC 检查发现 \(found.count) 处冲突，按检查结果重写")
            try await rewrite(chatId: chatId, issues: found, round: round + 1, onRow: onRow, say: say)
        } catch {
            say("OOC 检查未完成：\(error.localizedDescription)")
        }
    }

    /// 按检查结果重写这一轮：和重新生成同一条路，末尾多一段修正说明，原回复留在候选里
    static func rewrite(chatId: String, issues: [Issue], round: Int, onRow: @escaping ChatEngine.OnRow = { _ in },
                        say: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try await ChatEngine.reply(chatId: chatId, regenerate: true, correction: correctionOf(issues), onRow: onRow)
        await after(chatId: chatId, round: round, onRow: onRow, say: say)
    }

    /// 会话页上要在哪一条下面画检查结果：这一轮的最后一条 → 这一轮的第一条（发现冲突或没检查完、没点忽略的）
    static func endsOf(_ msgs: [Message]) -> [String: Message] {
        var heads: [String: Message] = [:]
        var tails: [String: String] = [:]
        for m in msgs where !m.turnId.isEmpty && m.role == .char {
            if heads[m.turnId] == nil { heads[m.turnId] = m }
            tails[m.turnId] = m.id
        }
        var out: [String: Message] = [:]
        for (t, h) in heads where !h.row.bool("oocDismissed") {
            let st = h.row.string("oocCheck")
            if st == "issues" || st == "failed", let tail = tails[t] { out[tail] = h }
        }
        return out
    }
}
