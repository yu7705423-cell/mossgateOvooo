import Foundation

/// 心愿（网页版 system/wish.js、ai/tasks/wish-judge.js、ai/context/wishes.js，ARCHITECTURE 4.304）。
///
/// 和「约定」分开：约定是两个人说好的事；心愿是某一个人自己的愿望、目标、期待，不一定说出口。
/// 系统只存状态（谁的、写了什么、达成条件、给不给对方看、有没有达成、何时由谁判定），角色的心愿只由角色自己写标记产生（第 22 条）。
///
/// 一行（wishes 域，前缀 ws）：owner（'me' 或角色 id）、charId、personaId、chatId、text、cond、shown、status（open / done）、createdAt、
/// turnId；达成后 doneAt、doneBy（manual / char / summary / judge）、doneNote、doneTurnId。
///
/// **你隐藏的心愿永远不进角色的提示词**，只交给判定那一次请求（随记忆总结或单独判定，判定的是总结模型，不是角色本人）。
/// **角色的私下心愿在你这边完全不显示**，连条数都不显示；达成之后才显示内容与达成时间。
enum Wish {
    static let me = "me"
    static let stOpen = "open", stDone = "done"
    static let collection = "wishes"
    static let by: [String: String] = ["manual": "手动标记", "char": "角色标记", "summary": "总结记忆时判定", "judge": "单独判定"]

    struct Item: Identifiable, Equatable {
        var row: Row
        var id: String { row.id }
        var owner: String { row.string("owner") }
        var mine: Bool { owner == Wish.me }
        var charId: String { row.string("charId") }
        var text: String { row.string("text") }
        var cond: String { row.string("cond") }
        var shown: Bool { row.bool("shown") }
        var isDone: Bool { row.string("status") == Wish.stDone }
        var doneAt: Double { row.number("doneAt") ?? 0 }
        var doneBy: String { row.string("doneBy") }
        var doneNote: String { row.string("doneNote") }
        var created: Double { row.number("createdAt") ?? 0 }
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func personaId() -> String { Diary.personaId() }

    private static func personaOf(_ chatId: String) -> String {
        let p = ((try? Repo.chat(chatId)) ?? nil)?.personaId ?? ""
        return p.isEmpty ? personaId() : p
    }

    private static func samePersona(_ r: Row, _ pid: String) -> Bool {
        let p = r.string("personaId")
        return (p.isEmpty ? pid : p) == pid
    }

    private static func rows() -> [Row] { (try? Database.shared.all(collection)) ?? [] }

    private static func newestFirst(_ list: [Item]) -> [Item] { list.sorted { $0.created > $1.created } }

    // MARK: - 读

    /// 你的心愿（当前身份），新的在前
    static func mine(_ pid: String = personaId()) -> [Item] {
        newestFirst(rows().filter { $0.string("owner") == me && samePersona($0, pid) }.map(Item.init(row:)))
    }

    /// 某个角色自己的全部心愿（含私下的）。只给程序与这个角色自己的提示词用
    static func ownOf(_ charId: String, _ pid: String = personaId()) -> [Item] {
        newestFirst(rows().filter { $0.string("owner") == charId && samePersona($0, pid) }.map(Item.init(row:)))
    }

    /// 角色的心愿里你看得见的：公开的，和已经达成的私下心愿
    static func seenByMe(_ w: Item) -> Bool { !w.mine && (w.shown || w.isDone) }

    static func charsSeen(_ charId: String, _ pid: String = personaId()) -> [Item] { ownOf(charId, pid).filter { seenByMe($0) } }

    /// 有你看得见的心愿的那几个角色
    static func charsWithWishes(_ pid: String = personaId()) -> [Character] {
        var ids: [String] = []
        for r in rows() {
            let w = Item(row: r)
            if !w.mine && samePersona(r, pid) && seenByMe(w) && !ids.contains(w.owner) { ids.append(w.owner) }
        }
        return ids.compactMap { (try? Repo.character($0)) ?? nil }
    }

    /// 你的心愿里，这个角色看得见的：给它看、而且关联它或不关联任何角色的
    static func mineShownTo(_ charId: String, _ pid: String) -> [Item] {
        mine(pid).filter { $0.shown && ($0.charId.isEmpty || $0.charId == charId) }
    }

    static func get(_ id: String) -> Item? { ((try? Database.shared.get(collection, id: id)) ?? nil).map(Item.init(row:)) }

    // MARK: - 你的心愿

    @discardableResult
    static func addMine(text: String, cond: String = "", charId: String = "", shown: Bool = false, pid: String = personaId()) throws -> Item {
        let t = clean(text)
        guard !t.isEmpty else { throw StoreError(message: "请填写心愿内容") }
        let link = !charId.isEmpty && ((try? Repo.character(charId)) ?? nil) != nil ? charId : ""
        let row = Row.new(prefix: "ws", ["owner": .string(me), "personaId": .string(pid), "charId": .string(link),
                                         "text": .string(t), "cond": .string(clean(cond)), "shown": .bool(shown), "status": .string(stOpen)])
        try Database.shared.put(collection, row)
        return Item(row: row)
    }

    @discardableResult
    static func editMine(_ id: String, text: String? = nil, cond: String? = nil, charId: String? = nil, shown: Bool? = nil) throws -> Item? {
        guard var r = try Database.shared.get(collection, id: id), r.string("owner") == me else { return nil }
        if let text { let t = clean(text); if !t.isEmpty { r["text"] = .string(t) } }
        if let cond { r["cond"] = .string(clean(cond)) }
        if let charId { r["charId"] = .string(!charId.isEmpty && ((try? Repo.character(charId)) ?? nil) != nil ? charId : "") }
        if let shown { r["shown"] = .bool(shown) }
        r.touch()
        try Database.shared.put(collection, r)
        return Item(row: r)
    }

    static func remove(_ id: String) throws { try Database.shared.delete(collection, id: id) }

    // MARK: - 达成

    /// 标成达成。你自己点的不弹通知（人就在这一页上）
    @discardableResult
    static func fulfil(_ id: String, by who: String = "manual", note: String = "", turnId: String = "") throws -> Item? {
        guard var r = try Database.shared.get(collection, id: id), r.string("status") != stDone else { return nil }
        r["status"] = .string(stDone)
        r["doneAt"] = .number(Date().millis)
        r["doneBy"] = .string(by[who] != nil ? who : "manual")
        r["doneNote"] = .string(clean(note))
        if !turnId.isEmpty { r["doneTurnId"] = .string(turnId) }
        r.touch()
        try Database.shared.put(collection, r)
        return Item(row: r)
    }

    /// 回到未达成：你点「撤销达成」，或者判定它的那一轮被重新生成
    @discardableResult
    static func reopen(_ id: String) throws -> Item? {
        guard var r = try Database.shared.get(collection, id: id), r.string("status") == stDone else { return nil }
        r["status"] = .string(stOpen)
        r["doneAt"] = .number(0)
        r["doneBy"] = .string("")
        r["doneNote"] = .string("")
        r["doneTurnId"] = .string("")
        r.touch()
        try Database.shared.put(collection, r)
        return Item(row: r)
    }

    // MARK: - 角色写的标记

    /// 角色写「心愿达成」时给的是一小段原话，拿它回头去认自己的哪一条。认不出就不动
    static func findOwnOpen(_ charId: String, _ pid: String, _ text: String) -> Item? {
        let q = clean(text).filter { !$0.isWhitespace }
        let list = ownOf(charId, pid).filter { !$0.isDone }
        guard !q.isEmpty else { return nil }
        return list.first { w in
            let t = w.text.filter { !$0.isWhitespace }
            return !t.isEmpty && (t.contains(q) || q.contains(t))
        }
    }

    /// [心愿：…] / [私下心愿：…]。「内容|达成条件」。同一句已经记着（未达成）就不再记一遍
    @discardableResult
    static func charWrite(charId: String, chatId: String, body: String, shown: Bool, turnId: String = "") throws -> Item? {
        guard !charId.isEmpty, ((try? Repo.character(charId)) ?? nil) != nil else { return nil }
        let bar = body.firstIndex { $0 == "|" || $0 == "｜" }
        let text = clean(bar.map { String(body[..<$0]) } ?? body)
        let cond = clean(bar.map { String(body[body.index(after: $0)...]) } ?? "")
        guard !text.isEmpty else { return nil }
        let pid = personaOf(chatId)
        if ownOf(charId, pid).contains(where: { !$0.isDone && $0.text == text }) { return nil }
        var f: [String: JSONValue] = ["owner": .string(charId), "charId": .string(charId), "personaId": .string(pid), "chatId": .string(chatId),
                                      "text": .string(text), "cond": .string(cond), "shown": .bool(shown), "status": .string(stOpen)]
        if !turnId.isEmpty { f["turnId"] = .string(turnId) }
        let row = Row.new(prefix: "ws", f)
        try Database.shared.put(collection, row)
        return Item(row: row)
    }

    /// [心愿达成：…]。只认这个角色自己的心愿
    @discardableResult
    static func charFulfil(charId: String, chatId: String, body: String, turnId: String = "") throws -> Item? {
        guard let w = findOwnOpen(charId, personaOf(chatId), body) else { return nil }
        return try fulfil(w.id, by: "char", turnId: turnId)
    }

    /// 重新生成那一轮：这一轮写下的心愿删掉，这一轮判定的达成退回去
    static func undoTurn(chatId: String, turnId: String) throws {
        guard !turnId.isEmpty else { return }
        for r in rows() {
            if r.string("turnId") == turnId && r.string("chatId") == chatId { try Database.shared.delete(collection, id: r.id) }
            else if r.string("doneTurnId") == turnId { try reopen(r.id) }
        }
    }

    /// 聊天里落的那一行提示（未落库）。私下的心愿不落；写不成、认不出的不落
    static func effect(_ p: ReplyParser.Part, chat: Chat, char: Character, turnId: String) throws -> Message? {
        let off = Set((AppSettings.load().raw["capsOff"]?.array ?? []).compactMap(\.string))
        guard char.row["canWish"]?.bool != false, !off.contains("wish") else { return nil }
        let name = char.displayName
        if p.type == .wish {
            guard let w = try charWrite(charId: char.id, chatId: chat.id, body: p.text, shown: p.flag, turnId: turnId), w.shown else { return nil }
            var m = Message.new(chatId: chat.id, role: .char, authorId: char.id, content: "[\(name)写下了一个心愿：\(w.text)]", kind: "notice", turnId: turnId)
            m.row["wishId"] = .string(w.id)
            return m
        }
        guard let w = try charFulfil(charId: char.id, chatId: chat.id, body: p.text, turnId: turnId) else { return nil }
        var m = Message.new(chatId: chat.id, role: .char, authorId: char.id, content: "[\(name)的心愿已达成：\(w.text)]", kind: "notice", turnId: turnId)
        m.row["wishId"] = .string(w.id)
        return m
    }

    // MARK: - 判定（随记忆总结 / 单独判定）

    /// 这段会话要判定的那些：未达成的你的心愿（关联这几个角色的、不关联任何角色的，隐藏的也算），和这几个角色自己未达成的心愿
    static func openFor(_ chatId: String) -> [Item] {
        guard let chat = (try? Repo.chat(chatId)) ?? nil else { return [] }
        let pid = chat.personaId.isEmpty ? personaId() : chat.personaId
        let cast = Set(chat.characterIds)
        return rows().map(Item.init(row:)).filter { w in
            !w.isDone && samePersona(w.row, pid) && (w.mine ? (w.charId.isEmpty || cast.contains(w.charId)) : cast.contains(w.owner))
        }
    }

    /// 写给判定模型看的清单，一行一条。人名、正文是数据，照原样
    static func listText(_ list: [Item], userName: String = "User") -> String {
        list.map { w in
            let who = w.mine ? userName : (((try? Repo.character(w.owner)) ?? nil)?.name ?? "Character")
            return "(id:\(w.id)) owner: \(who) | wish: \(w.text)\(w.cond.isEmpty ? "" : " | fulfilled when: \(w.cond)")"
        }.joined(separator: "\n")
    }

    /// 判定结果落库。只认这一次交出去的那几条 id（模型编一个 id 出来不算数）
    @discardableResult
    static func applyJudged(_ v: JSONValue?, sent: [Item], by who: String) -> Int {
        let ok = Set(sent.map(\.id))
        var n = 0
        for r in v?.array ?? [] {
            let id = r.string ?? r["id"]?.string ?? ""
            guard !id.isEmpty, ok.contains(id) else { continue }
            do { if try fulfil(id, by: who, note: r["note"]?.string ?? "") != nil { n += 1 } }
            catch { Problems.report("心愿判定结果未能写入：\(error.localizedDescription)") }
        }
        return n
    }

    /// 随记忆总结一起判定：不多调接口，只多带几行。默认开
    static func inSummary(_ s: AppSettings = .load()) -> Bool { s.raw["wishInSummary"]?.bool != false }

    /// 单独判定：默认关（第 15 条），登记在 ExtraCalls
    static func judgeOn(_ s: AppSettings = .load()) -> Bool { s.raw["wishJudge"]?.bool == true }
    static func judgeEvery(_ s: AppSettings = .load()) -> Int { max(1, Int((s.raw["wishJudgeEvery"]?.number ?? 10).rounded())) }

    private static func talk(_ chatId: String) -> [Message] {
        guard let chat = (try? Repo.chat(chatId)) ?? nil else { return [] }
        let all = ((try? Repo.messages(chatId: chatId)) ?? []).filter {
            !$0.isError && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.kind != "side"
        }
        return Ties.keepDelivered(chat, all)
    }

    /// 上次试过之后的那些。没试过返回 nil。标记那一条被删了（重新生成那一轮）就按时间接
    private static func sinceTried(_ chatId: String, _ all: [Message]) -> [Message]? {
        guard let chat = (try? Repo.chat(chatId)) ?? nil else { return nil }
        let tried = chat.row.string("wishTriedId")
        guard !tried.isEmpty else { return nil }
        if let at = all.firstIndex(where: { $0.id == tried }) { return Array(all[(at + 1)...]) }
        let t = chat.row.number("wishTriedAt") ?? 0
        return t > 0 ? all.filter { $0.createdAt > t } : nil
    }

    /// 该不该判一次：开关开着、有未达成的心愿、上次试过之后又攒够了 N 条角色回复
    static func shouldJudge(_ chatId: String, _ s: AppSettings = .load()) -> Bool {
        guard judgeOn(s), !openFor(chatId).isEmpty else { return false }
        let all = talk(chatId)
        let list = sinceTried(chatId, all) ?? all
        return list.filter { $0.role == .char }.count >= judgeEvery(s)
    }

    /// 判一次（一次请求）。先记「试过」再发，失败也算试过
    @discardableResult
    static func judgeNow(_ chatId: String) async throws -> Int {
        guard var chat = try Repo.chat(chatId) else { throw StoreError(message: "会话不存在") }
        let sent = openFor(chatId)
        guard !sent.isEmpty else { return 0 }
        let all = talk(chatId)
        guard let last = all.last else { return 0 }
        let s = AppSettings.load()
        let since = sinceTried(chatId, all)
        let rows = since.flatMap { $0.isEmpty ? nil : $0 } ?? Diary.recentWindow(all, s)
        chat.row["wishTriedId"] = .string(last.id)
        chat.row["wishTriedAt"] = .number(last.createdAt)
        chat.row.touch()
        try Repo.save(chat)
        let dialogue = rows.map { m -> String in
            let who = m.role == .user ? "User" : (((try? Repo.character(m.authorId)) ?? nil)?.name ?? "Character")
            return "\(who)：\(m.content)"
        }.joined(separator: "\n")
        let system = Templates.render("task.wish-judge", ["dialogue": dialogue, "wishes": listText(sent)], settings: s)
        let r = try await AIService.shared.send(task: "wish.judge", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")], maxTokens: 800)
        guard let j = JSONReply.parse(r.text), j.object != nil else { throw StoreError(message: JSONReply.failure(r.text)) }
        return applyJudged(j["wishesDone"], sent: sent, by: "judge")
    }

    /// 回复落定之后调。条件不满足什么都不做；满足就判一次，不等它
    static func autoJudge(_ chatId: String) {
        guard shouldJudge(chatId) else { return }
        Task.detached {
            do { _ = try await Wish.judgeNow(chatId) }
            catch { Diagnostics.shared.record("wish-judge-failed", ["error": error.localizedDescription]) }
        }
    }

    // MARK: - 进聊天提示词（网页版 context/wishes.js）

    private static func day(_ at: Double) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: Date(millis: at))
        return "\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// 这个角色自己记下的（含私下的）、对方给它看的，最近七天达成的也在。线下不给
    static func block(char: Character, chat: Chat, persona: Persona?, now: Date = Date()) -> String {
        let pid = !chat.personaId.isEmpty ? chat.personaId : (persona?.id ?? personaId())
        let userName = persona?.name ?? "the user"
        let nowMs = now.millis
        func fresh(_ w: Item) -> Bool { !w.isDone || (w.doneAt > 0 && nowMs - w.doneAt < 7 * 86_400_000) }
        let own = ownOf(char.id, pid).filter(fresh)
        let theirs = mineShownTo(char.id, pid).filter(fresh)
        guard !own.isEmpty || !theirs.isEmpty else { return "" }
        func line(_ w: Item, _ tag: String) -> String {
            "- \(w.text)\(w.cond.isEmpty ? "" : "（\(w.cond)）")" + (tag.isEmpty ? "" : " [\(tag)]") + (w.isDone ? " [fulfilled \(day(w.doneAt))]" : "")
        }
        var out: [String] = []
        if !own.isEmpty {
            out.append("Your own wishes. \(userName) can see the ones marked visible; the ones marked hidden stay hidden from \(userName) until fulfilled:")
            out += own.map { line($0, $0.shown || $0.isDone ? "visible" : "hidden") }
        }
        if !theirs.isEmpty {
            out.append("Wishes \(userName) has chosen to show you:")
            out += theirs.map { line($0, "") }
        }
        return "\n\n[心愿]\n" + out.joined(separator: "\n")
    }

    /// 删角色时：它自己的心愿删掉；你的心愿里关联它的改成不关联（网页版 purge.dropCharacter）。Purge 已经做了，这里给测试与别处用
    static func dropCharacter(_ id: String) throws {
        for r in rows() {
            if r.string("owner") == id { try Database.shared.delete(collection, id: r.id) }
            else if r.string("owner") == me && r.string("charId") == id {
                var x = r; x["charId"] = .string(""); x.touch(); try Database.shared.put(collection, x)
            }
        }
    }
}
