import Foundation

/// 「我们」写一段的请求（网页版 engine.js 的 buildWorkSystem、buildWorkHistory、streamWork，ARCHITECTURE 4.117）。
///
/// 和线下同一条链路：同一批 beats 函数、同一个任务 scene.write。多出来的只有三件事：
///   1. 一部作品的设定（主线）
///   2. 可以整套换掉的身份：换的是名字与人设，不是那张脸
///   3. 前面几篇写到哪儿了
///
/// 还有一个开关 carry：关着时这一篇看不见原来那段关系的任何东西（记忆、关系底色、日程、聊天摘要一样都不注入）；
/// 开着时和线下一样，另外带哪几样由这一部的三个开关定（4.396）。
enum WorkPrompt {
    /// 带上原来那段关系时，每一块归哪个开关（网页版 WORK_CARRY）。没列的归「其他每轮注入的内容」
    static let carryKind: [String: String] = [
        "lorebook": "base", "loreAfter": "base", "character": "base", "user": "base",
        "bond": "memory", "state": "memory", "pinned": "memory", "recent": "memory", "memory": "memory", "impress": "memory",
        "bridge": "chat", "privateRecent": "chat",
    ]

    /// 这部作品里换过的那套身份。两样都没换就整段不出现
    static func identityBlock(_ w: Row, _ c: Works.Who, _ m: Works.Who, settings s: AppSettings) -> String {
        var lines: [String] = []
        if c.renamed { lines.append("\(c.baseName.isEmpty ? "对方" : c.baseName) 在这部作品里是「\(c.name)」") }
        if c.hasBase && c.persona != c.basePersona { lines.append("\(c.name)：\(c.persona)") }
        if m.renamed { lines.append("\(m.baseName.isEmpty ? "我" : m.baseName) 在这部作品里是「\(m.name)」") }
        if !m.persona.isEmpty && m.persona != m.basePersona { lines.append("\(m.name)：\(m.persona)") }
        guard !lines.isEmpty else { return "" }
        return Templates.render("skeleton.work-identity", ["lines": lines.joined(separator: "\n"),
                                                          "carry": w.bool("carry") ? Templates.get("skeleton.work-identity-carry", settings: s) : ""], settings: s)
    }

    /// 这一篇的几件事实。是数据，不是指令
    static func chapterSetup(_ w: Row, _ ch: Row, settings s: AppSettings) -> String {
        var lines: [String] = []
        let title = ch.string("title")
        if w.string("kind") == Works.SAGA {
            lines.append("第 \(Int(ch.number("no") ?? 0)) 章" + (title.isEmpty ? "" : "　\(title)"))
        } else if !title.isEmpty { lines.append("题：\(title)") }
        if !ch.string("place").isEmpty { lines.append("地点：\(ch.string("place"))") }
        let now = Works.timeOf(ch.id)
        if !now.isEmpty { lines.append("时刻：\(now)") }
        if !ch.string("note").isEmpty { lines.append("情境：\(ch.string("note"))") }
        guard !lines.isEmpty else { return "" }
        return Templates.render("skeleton.work-chapter", ["lines": lines.joined(separator: "\n")], settings: s)
    }

    /// 前面几篇写到哪儿了。有摘要用摘要，没有就截正文的末尾（不调接口）
    static func prevBlock(_ w: Row, _ ch: Row, settings s: AppSettings) -> String {
        let cap = max(0, Int(s.num("workPrevChars", 600).rounded()))
        let no = ch.number("no") ?? 0
        let lines = Works.chaptersOf(w.id).filter { ($0.number("no") ?? 0) < no }.compactMap { c -> String? in
            let body = Works.digestOf(c.id, chars: cap)
            guard !body.isEmpty else { return nil }
            let t = c.string("title")
            let head = w.string("kind") == Works.SAGA ? "第 \(Int(c.number("no") ?? 0)) 章" + (t.isEmpty ? "" : "　\(t)")
                : (t.isEmpty ? "第 \(Int(c.number("no") ?? 0)) 则" : t)
            return "\(head)\n\(body)"
        }
        guard !lines.isEmpty else { return "" }
        return Templates.render("skeleton.work-prev", ["lines": lines.joined(separator: "\n\n")], settings: s)
    }

    /// 正文附带译文（4.366）：这一部开了、并且这个角色与这个身份的私聊开着翻译才有（网页版 proseTrans）
    static func proseTrans(_ w: Row, charId: String, personaId: String, settings s: AppSettings) -> String {
        guard w.bool("withTrans") else { return "" }
        guard let own = ((try? Repo.chats()) ?? []).first(where: { !$0.isGroup && $0.characterIds == [charId] && $0.personaId == personaId }) else { return "" }
        let lang = own.row.string("translateTo").trimmingCharacters(in: .whitespaces)
        guard !lang.isEmpty else { return "" }
        let extra = own.row.string("translateRules").trimmingCharacters(in: .whitespacesAndNewlines)
        return Templates.render("skeleton.prose-trans", ["lang": lang, "extra": extra.isEmpty ? "" : "\nAdditional requirements: \(extra)"], settings: s)
    }

    /// 写一段。more 是续写；list 是这一篇到此为止的正文（重写时已经去掉那一段及之后的）
    static func build(work w: Row, chapter ch: Row, list: [Row], more: Bool = false, settings s: AppSettings, now: Date = Date()) throws -> ChatPrompt.Built {
        guard let char = w.strings("castIds").first.flatMap({ (try? Repo.character($0)) ?? nil }) else {
            throw StoreError(message: "这部作品的角色已经不在了")
        }
        let chat = try Repo.chat(w.string("chatId"))
        let c = Works.charOf(w), m = Works.meOf(w)
        let names = ["charName": c.name, "userName": m.name]
        let carry = w.bool("carry")
        let take = Works.carryOf(w)
        let budget = ChatPrompt.sceneBudget(s)
        let scan = ChatPrompt.sceneScan(list, s)
        // 不带原来那段关系时，世界书只认这部作品自己挂的那几本
        let loreChar = carry ? char : Character(row: Row(fields: ["id": .string(""), "lorebookIds": .array(w.strings("lorebookIds").map { .string($0) })]))
        var lore = ChatPrompt.activateLore(char: loreChar, scanText: scan, budget: budget > 0 ? Int((Double(budget) * 0.4).rounded()) : 0)
        let anyLore = !lore.before.isEmpty || !lore.after.isEmpty || !lore.deep.isEmpty
        // 正文的历史里没有插深度的地方：按深度插的那几条并进角色后（同线下）
        lore.after += lore.deep.map(\.1)
        let personas = try Repo.personas()
        let me = Works.mePersona(w)
        let rootId = Repo.rootId(of: me?.id ?? "", in: personas)

        var out = Templates.render("skeleton.work-opening", names, settings: s)
        var hot = ""
        var recalled: [Memory] = []
        if carry {
            // 带着原来那段关系走：和线下同一套注入，只是按这一部的三个开关挑
            let theChat = chat ?? Chat(row: Row(fields: ["id": .string(""), "characterIds": .array([.string(char.id)]), "personaId": .string(me?.id ?? "")]))
            let online = try chat.map { try Repo.messages(chatId: $0.id).filter { !$0.isError && !AutoReply.localOnly($0) }.map(AutoReply.forPrompt) } ?? []
            let memories = try ChatPrompt.visibleMemories(char: char, chat: theChat, rootId: rootId, personas: personas)
            let memoryOn = s.raw["memoryEnabled"]?.bool ?? true
            let recent = memoryOn ? ChatPrompt.recentMemories(memories, limit: Int(s.num("memoryRecent", 10))) : []
            // 不带记忆时不召回
            if memoryOn && take["memory"] == true {
                recalled = ChatPrompt.recall(memories, scanText: scan, skip: Set(recent.map(\.id)), topK: Int(s.num("memoryTopK", 6)),
                                             now: now, openDays: ChatPrompt.staleDays(s))
            }
            let blocks = ChatPrompt.dataBlocks(chat: theChat, char: char, me: me, msgs: online, lore: lore, memories: memories, recent: recent,
                                               recalled: recalled, rootId: rootId, settings: s, now: now)
            for id in Layout.resolveOrder(Layout.injectOrder(s)) {
                let kind = carryKind[id] ?? "other"
                guard kind == "base" || take[kind] == true, let text = blocks[id], !text.isEmpty else { continue }
                if Layout.volatile.contains(id) { hot += text } else { out += text }
            }
            if take["memory"] == true, let chat, !chat.summary.isEmpty { out += "\n\n[更早之前发生过什么]\n\(chat.summary)" }
        } else if !c.persona.isEmpty {
            // 不带的那一档：角色是谁仍然要说，但说的是这部作品里的那一个
            out += "\n\n[\(c.name)]\n\(c.persona)"
        }
        // 世界书：作品自己挂的那几本（照网页版 engine.js 原样：只有抬头，见 docs/web-fields.md 的说明）
        if !carry && anyLore {
            out += "\n\n" + Templates.render("skeleton.world", ["text": (lore.before + lore.after).joined(separator: "\n")], settings: s)
        }
        let ident = identityBlock(w, c, m, settings: s)
        if !ident.isEmpty { out += "\n\n" + ident }
        let premise = w.string("premise")
        if !premise.isEmpty { out += "\n\n" + Templates.render("skeleton.work-premise", ["text": premise], settings: s) }
        // 整篇它写，还是我写我的。两选一
        out += "\n\n" + Templates.render(w.bool("solo") ? "skeleton.work-solo" : "skeleton.scene-rules", names, settings: s)
        let setup = chapterSetup(w, ch, settings: s)
        if !setup.isEmpty { out += "\n\n" + setup }
        let plan = Novel.promptLines(w, ch)
        if !plan.isEmpty { out += "\n\n" + Templates.render("skeleton.work-outline", ["lines": plan.joined(separator: "\n")], settings: s) }
        // 上一篇末尾选定的走向（反馈 10）：番外与没有大纲的长篇也带得上
        let lead = ch.string("plan")
        if ch.string("planFrom") == "end" && !lead.isEmpty {
            out += "\n\n" + Templates.render("skeleton.work-lead", ["text": lead, "userName": m.name], settings: s)
        }
        let prev = prevBlock(w, ch, settings: s)
        if !prev.isEmpty { out += "\n\n" + prev }
        if !ch.string("summary").isEmpty { out += "\n\n[这一篇之前发生过什么]\n\(ch.string("summary"))" }
        out += "\n\n" + Templates.get("skeleton.time", settings: s)
        let words = ChatPrompt.wordsOf(w, s)
        if words > 0 { out += "\n\n" + Templates.render("skeleton.scene-length", ["words": "\(words)"], settings: s) }
        let style = Templates.fill(Tone.forScene(w, s), names)
        if !style.isEmpty { out += "\n\n" + Templates.render("skeleton.scene-style", ["text": style], settings: s) }
        let ban = ChatPrompt.banPiece(s)
        if !ban.isEmpty { out += "\n\n" + ban }

        // 历史：我写的是 user，它写的是 assistant；窗口与预算同线下，钉住的那几段不受约束
        let body = list.filter { $0.string("role") != Scenes.DIRECTOR }
        let n = max(0, Int(s.num("sceneWindow", 0)))
        let scope = n > 0 ? Array(body.suffix(n)) : body
        var kept: [Row] = []
        var used = 0
        for b in scope.reversed() {
            let cost = TokenEstimate.of(b.string("text"))
            if budget > 0 && used + cost > budget && !kept.isEmpty { break }
            used += cost
            kept.insert(b, at: 0)
        }
        let inKept = Set(kept.map(\.id))
        let view = (body.filter { $0.bool("pinned") && !inKept.contains($0.id) } + kept).map { b in
            AIMessage(role: b.string("role") == Scenes.ME ? .user : .assistant, content: b.string("text"))
        }
        let md = Int(s.num("memoryDepth", 1))
        let dir = ChatPrompt.directorLines(list)
        let tail = [
            hot.trimmingCharacters(in: .whitespacesAndNewlines),
            carry && md > 0 && !recalled.isEmpty ? ChatPrompt.recallText(recalled, now: now) : "",
            dir.isEmpty ? "" : Templates.render("skeleton.scene-director", ["lines": dir.joined(separator: "\n"), "userName": m.name], settings: s),
            more ? Templates.get("skeleton.scene-more", settings: s) : "",
            // 整篇它写的那一档不提醒「不要写我」：那正是这一档允许的事
            w.bool("solo") ? "" : Templates.render("skeleton.scene-tail", ["userName": m.name], settings: s),
            proseTrans(w, charId: char.id, personaId: chat?.personaId ?? (me?.id ?? ""), settings: s),
            // 结尾的后续选项（反馈 10）：这一部开着才有，贴着输出
            w.bool("endNext") ? Templates.render("skeleton.work-next", ["userName": m.name], settings: s) : "",
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        var merged: [AIMessage] = []
        for msg in view + (tail.isEmpty ? [] : [AIMessage(role: .user, content: tail)]) {
            if let last = merged.last, last.role == msg.role { merged[merged.count - 1].content += "\n" + msg.content }
            else { merged.append(msg) }
        }
        return ChatPrompt.Built(system: out, messages: merged, recalled: recalled.map(\.id))
    }
}

/// 写一段（网页版 apps/us 的 ReadPage writeOne 与 streamWork）。点一次写一段、调一次接口（第 15 条）；
/// 作品不进记忆（4.117）。
enum WorkRun {
    /// 长篇与番外没单独选：跟着「线下的正文」那一组（网页版 4.1091 的 routedPreset）
    static func group(_ s: AppSettings) -> String {
        (s.raw["taskRoutes"]?["work"]?.string ?? "").isEmpty ? "scene" : "work"
    }

    /// 这一部选了自己的正文接口（work.apiId）、并且那一套填全了才用它
    static func preset(_ w: Row, _ s: AppSettings) -> ChatPreset? {
        let id = w.string("apiId")
        guard !id.isEmpty else { return nil }
        return s.chatPresets.first { $0.id == id && $0.usable }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buf = ""
        func add(_ d: String) -> String { lock.lock(); defer { lock.unlock() }; buf += d; return buf }
    }

    /// 写一段。more 接着上一段往下写；rewrite 重写那一段，旧的留作候选。onDraft 收到的是此刻写到哪儿的正文
    @discardableResult
    static func write(chapterId: String, more: Bool = false, rewrite: String = "",
                      onDraft: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Row? {
        guard let ch = Works.getChapter(chapterId), let w = Works.get(ch.string("workId")) else { throw StoreError(message: "这一篇已经不在了") }
        var list = Scenes.beatsOf(chapterId)
        if !rewrite.isEmpty, let i = list.firstIndex(where: { $0.id == rewrite }) { list = Array(list[..<i]) }
        let s = AppSettings.load()
        let built = try WorkPrompt.build(work: w, chapter: ch, list: list, more: more, settings: s)
        let cut = w.bool("endNext")
        let buffer = Buffer()
        let result = try await AIService.shared.send(task: "scene.write", group: group(s), preset: preset(w, s),
                                                     system: built.system, messages: built.messages,
                                                     maxTokens: ChatPrompt.sceneMax(s), retries: 1) { d in
            let all = buffer.add(d)
            onDraft(SceneRun.proseLive(cut ? Works.cutNext(all) : all))
        }
        try? ChatEngine.markRecalled(built.recalled)
        return try settle(result.text, chapterId: chapterId, work: w, more: more, rewrite: rewrite)
    }

    /// 一段原文落成一段正文：摘思考、摘时间、摘后续选项（开着才摘）、拆译文
    static func settle(_ raw: String, chapterId: String, work w: Row, more: Bool, rewrite: String) throws -> Row? {
        let (text, think) = ReplyParser.stripThink(raw)
        let (stamped, stamp) = ReplyParser.stripStamps(text)
        let at = SceneRun.stampInner(stamp)
        let nx: (text: String, items: [String]) = w.bool("endNext") ? Works.takeNext(stamped) : (stamped, [])
        let (body, trans) = SceneRun.splitProse(nx.text)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError(message: "模型返回了空内容") }
        let authorId = w.strings("castIds").first ?? ""
        let beat: Row?
        if !rewrite.isEmpty {
            beat = try Scenes.addSwipe(rewrite, text: body, raw: raw, think: think, at: at, trans: trans)
        } else if more, let last = Scenes.told(chapterId).last {
            beat = try Scenes.appendBeat(last.id, text: body, raw: raw, at: at, trans: trans)
        } else {
            beat = try Scenes.addBeat(sceneId: chapterId, role: Scenes.CHAR, authorId: authorId, text: body, raw: raw, think: think, at: at, trans: trans)
        }
        var patch: [String: JSONValue] = [:]
        if let b = beat, !nx.items.isEmpty {
            patch["endNext"] = .object(["beatId": .string(b.id), "ver": .number(b.number("swipeIndex") ?? 0),
                                        "items": .array(nx.items.map { .string($0) }), "picked": .string("")])
        }
        try Works.updateChapter(chapterId, patch)
        return beat
    }
}
