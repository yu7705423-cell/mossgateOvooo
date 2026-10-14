import Foundation

/// 一对一线上聊天（任务 chat.reply）的请求怎么拼。照网页版 `ai/engine.js` 的 buildChatSystem 与 buildHistory。
///
/// 原生版第一版拼的是网页版默认布局里不依赖其他功能的那几段：开场、性别锚点、世界书、关系底色、角色卡、
/// 对方是谁、一直记着、更早的摘要、规则、能力、核心设定、禁用词，以及放在历史末尾的时间、最近记下的、相关记忆。
/// 依赖原生版还没有的功能的区块（日程、穿搭、商城……）在网页版里也是没有数据就为空，这里直接不拼。
///
/// 方括号区块抬头（`[你是谁]`、`[相关记忆]`……）是协议，一字不改；英文句子照抄网页版。
enum ChatPrompt {
    struct Built: Sendable {
        var system: String
        var messages: [AIMessage]
        /// 这一轮召回的记忆 id。发送成功之后要记一次「用过」。
        var recalled: [String]
        /// 这一轮把原图交给了模型的那几条消息。发送成功之后标成看过，往后不再重传。
        var seenImages: [String] = []
    }

    /// excludeTurn：重新生成时去掉的那一轮，拿同样的前文重写一遍（网页版 streamReply 的 excludeTurn）。
    static func build(chat: Chat, char: Character, settings s: AppSettings, now: Date = Date(),
                      excludeTurn: String? = nil) throws -> Built {
        let all = try Repo.messages(chatId: chat.id).filter { !$0.isError && (excludeTurn == nil || $0.turnId != excludeTurn) }
        let personas = try Repo.personas()
        let me = try personas.first(where: { $0.id == chat.personaId }) ?? Repo.activePersona(s)
        let charName = char.name.isEmpty ? "对方" : char.name
        let userName = (me?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "对方"
        let names = ["charName": charName, "userName": userName]
        let rootId = Repo.rootId(of: me?.id ?? "", in: personas)

        let scanText = scanTextOf(all, window: Int(s.num("scanWindow", 6)))
        let budget = Int(s.num("contextBudget", 0))
        let lore = activateLore(char: char, scanText: scanText, budget: budget > 0 ? Int((Double(budget) * 0.4).rounded()) : 0)
        let memories = try visibleMemories(char: char, chat: chat, rootId: rootId, personas: personas)
        let memoryOn = s.raw["memoryEnabled"]?.bool ?? true
        let recent = memoryOn ? recentMemories(memories, limit: Int(s.num("memoryRecent", 10))) : []
        let recalled = memoryOn ? recall(memories, scanText: scanText, skip: Set(recent.map(\.id)),
                                         topK: Int(s.num("memoryTopK", 6)), now: now) : []

        // 各段先算出来，先后与开关交给预设的条目顺序（Layout，网页版 4.387）。默认顺序与从前一字不差
        let memoryDepth = Int(s.num("memoryDepth", 1))
        var blocks: [String: String] = [
            "lorebook": loreBlock(lore.before),
            "bond": bondBlock(char: char, rootId: rootId),
            "character": characterBlock(char),
            "loreAfter": loreBlock(lore.after),
            "user": userBlock(me: me, char: char),
            "pinned": pinnedBlock(memories, max: Int(s.num("pinnedMax", 8))),
            "time": timeBlock(char: char, msgs: all, settings: s, now: now),
            "recent": recentBlock(recent, now: now),
        ]
        // 本轮相关记忆：深度 0 时留在设定区，否则贴着对话末尾（固定在聊天记录下面，不参与排序）
        if memoryDepth == 0 && !recalled.isEmpty { blocks["memory"] = recallText(recalled, now: now) }

        var P = Layout.groupPieces(blocks, order: Layout.injectOrder(s))
        P["opening"] = Templates.render("skeleton.opening", names, settings: s)
        let gender = genderPiece(char: char, me: me, names: names, settings: s)
        P["gender"] = gender
        if !chat.summary.isEmpty { P["summary"] = "[更早之前发生过什么]\n\(chat.summary)" }
        P["rules"] = Templates.render("skeleton.rules", ["count": countText(Int(s.num("msgMin", 3)), Int(s.num("msgMax", 9)))], settings: s)
        P["caps"] = capabilities(char: char, chat: chat, msgs: all, settings: s)
        let core = char.core.trimmingCharacters(in: .whitespacesAndNewlines)
        if !core.isEmpty { P["core"] = Templates.render("skeleton.core", ["core": core], settings: s) }
        P["ban"] = banPiece(s)
        P["genderTail"] = gender
        let arranged = Layout.arrange("chat", pieces: P, settings: s, names: names)

        // 放在历史末尾的那一段：条目里排在聊天记录下面的（默认是「此刻的状态」），再加本轮相关记忆
        var tailParts: [String] = []
        if !arranged.tail.isEmpty { tailParts.append(arranged.tail) }
        if memoryDepth > 0 && !recalled.isEmpty { tailParts.append(recallText(recalled, now: now)) }

        let (messages, seen) = history(all, chat: chat, char: char, settings: s, tail: tailParts.joined(separator: "\n\n"),
                                       tailDepth: max(1, memoryDepth), lore: lore.deep)
        return Built(system: arranged.system, messages: messages, recalled: recalled.map(\.id),
                     seenImages: seen)
    }

    // MARK: - 历史

    private static func history(_ all: [Message], chat: Chat, char: Character, settings s: AppSettings,
                                tail: String, tailDepth: Int, lore: [(Int, String)]) -> ([AIMessage], [String]) {
        let window: [Message]
        if s.raw["historyMode"]?.string == "turn" {
            window = takeTurns(all, Int(s.num("historyTurns", 10)))
        } else {
            let limit = Int(s.num("historyLimit", 20))
            window = limit > 0 ? Array(all.suffix(limit)) : all
        }
        let stampOn = (s.raw["injectTime"]?.bool ?? true)
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 识图交给聊天模型时：只带当前这一轮（用户连着发、角色还没回的那几条）里还没被看过的图。
        // 一张图看过一次就不再重传：每轮都传，越聊越慢也越聊越贵（网页版 engine.js 的 imagesFor）
        var turnStart = all.count
        while turnStart > 0 && all[turnStart - 1].role == .user { turnStart -= 1 }
        let currentTurn = Set(all[turnStart...].map(\.id))
        var seen: [String] = []
        func imagesOf(_ m: Message) -> [AIImage] {
            guard s.visionMode == "chat", currentTurn.contains(m.id), m.kind == "image", !m.imageId.isEmpty,
                  m.row.string("vision") != "done",
                  let url = MediaStore.url(.images, id: m.imageId), let data = try? Data(contentsOf: url) else { return [] }
            seen.append(m.id)
            return [AIImage(mediaType: Images.mediaType(ext: url.pathExtension), base64: data.base64EncodedString())]
        }

        var out: [AIMessage] = []
        var prev: Message?
        for raw in window {
            // 正则替换里「发给角色的」那一份（存着的原文不动）
            let m = RegexRules.promptMessage(raw, chat: chat, settings: s)
            var text = (stampOn ? timeLine(m, prev) : "") + withQuote(m, byId)
            if m.isRecalled && m.role == .user {
                let seen = m.row["recalled"]?["seen"]?.bool ?? false
                text = seen ? "[撤回了一条消息：\(m.content)]" : "[撤回了一条消息]"
            }
            if m.role == .char && m.authorId == char.id {
                if m.isRecalled { text += "\n[撤回]" }
                out.append(AIMessage(role: .assistant, content: text))
            } else {
                out.append(AIMessage(role: .user, content: text, images: m.role == .user ? imagesOf(m) : []))
            }
            for r in m.row["reactions"]?.array ?? [] {
                guard let e = r["e"]?.string else { continue }
                let by = r["by"]?.string ?? ""
                let line = "[回应：\(e)：\(excerpt(m.content, 24))]"
                out.append(AIMessage(role: by == "me" ? .user : .assistant, content: line))
            }
            prev = m
        }

        // 相邻同角色的并成一条（用换行）；带图的不并
        var merged: [AIMessage] = []
        for m in out {
            if let last = merged.last, last.role == m.role, last.images.isEmpty, m.images.isEmpty {
                merged[merged.count - 1].content += "\n" + m.content
            }
            else { merged.append(m) }
        }
        if merged.last?.role == .assistant {
            merged.append(AIMessage(role: .user, content: Templates.get("skeleton.follow-up", settings: s)))
        }

        // 按深度插进去：深的先插。尾巴放在 tailDepth 那一层
        var byDepth: [Int: [String]] = [:]
        for (d, c) in lore { byDepth[d, default: []].append(c) }
        var raws: [Int: String] = [:]
        if !tail.isEmpty { raws[tailDepth] = tail }
        for d in Set(byDepth.keys).union(raws.keys).sorted(by: >) {
            var body = ""
            if let entries = byDepth[d], !entries.isEmpty { body = "[世界设定]\n" + entries.joined(separator: "\n") }
            if let raw = raws[d] { body += (body.isEmpty ? "" : "\n\n") + raw }
            let at = max(0, merged.count - d)
            merged.insert(AIMessage(role: .system, content: body), at: at)
        }
        return (merged, seen)
    }

    /// 从后往前数轮：一轮从「前一条不是用户」的那条用户消息开始。0 表示全部。
    private static func takeTurns(_ msgs: [Message], _ n: Int) -> [Message] {
        guard n > 0 else { return msgs }
        var count = 0
        var i = msgs.count - 1
        while i >= 0 {
            if msgs[i].role == .user && (i == 0 || msgs[i - 1].role != .user) {
                count += 1
                if count == n { return Array(msgs[i...]) }
            }
            i -= 1
        }
        return msgs
    }

    private static func timeLine(_ m: Message, _ prev: Message?) -> String {
        let full = "[\(TimeText.format(Date(millis: m.createdAt)))] "
        let newDay = prev.map { TimeText.day(Date(millis: $0.createdAt)) != TimeText.day(Date(millis: m.createdAt)) } ?? true
        if m.role == .char {
            let stamp = m.row.string("stamp")
            if !stamp.isEmpty { return "[\(stamp)] " }
            return newDay ? full : ""
        }
        let gap = prev.map { m.createdAt - $0.createdAt >= 30 * 60_000 } ?? true
        return newDay || gap ? full : ""
    }

    private static func withQuote(_ m: Message, _ byId: [String: Message]) -> String {
        let qid = m.row.string("quoteId")
        let qtext = m.row.string("quoteText")
        guard !qid.isEmpty || !qtext.isEmpty else { return m.content }
        let src = byId[qid]?.content ?? qtext
        return "[引用：\(excerpt(src, 40))]\n\(m.content)"
    }

    private static func excerpt(_ s: String, _ n: Int) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }

    private static func scanTextOf(_ msgs: [Message], window: Int) -> String {
        (window > 0 ? Array(msgs.suffix(window)) : msgs).map(\.content).joined(separator: "\n")
    }

    // MARK: - 系统提示里的各段

    private static func countText(_ lo: Int, _ hi: Int) -> String { lo == hi ? "\(lo)" : "\(lo) to \(hi)" }

    private static func genderPiece(char: Character, me: Persona?, names: [String: String], settings s: AppSettings) -> String {
        var lines: [String] = []
        let cg = char.row.string("gender").trimmingCharacters(in: .whitespaces)
        let ug = (me?.row.string("gender") ?? "").trimmingCharacters(in: .whitespaces)
        if !cg.isEmpty { lines.append("\(names["charName"]!)：\(cg)") }
        if !ug.isEmpty { lines.append("\(names["userName"]!)：\(ug)") }
        guard !lines.isEmpty else { return "" }
        return Templates.render("skeleton.gender", ["lines": lines.joined(separator: "\n")], settings: s)
    }

    private static func characterBlock(_ char: Character) -> String {
        var persona = char.persona
        if let parent = char.parentId, !parent.isEmpty, let p = try? Repo.character(parent) { persona = p.persona }
        var out = ""
        func part(_ head: String, _ v: String) {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out += "\n\n\(head)\n\(t)" }
        }
        part("[你是谁]", persona)
        part("[当前情境]", char.scenario)
        part("[你的说话方式示例]", char.exampleDialogue)
        return out
    }

    private static func userBlock(me: Persona?, char: Character) -> String {
        guard let me else { return "" }
        var bits = ["Name: \(me.name)"]
        let sections = me.row["sections"]?.object ?? [:]
        let labels: [(String, String)] = [("personality", "Personality"), ("likes", "Likes"), ("habits", "Habits"),
                                          ("triggers", "Sore points"), ("life", "Current life")]
        let filled = labels.compactMap { key, en -> String? in
            let t = (sections[key]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : "\(en):\n\(t)"
        }
        let basics = me.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if filled.isEmpty {
            if !basics.isEmpty { bits.append(basics) }
        } else {
            bits.append(((basics.isEmpty ? [] : ["Basics:\n\(basics)"]) + filled).joined(separator: "\n\n"))
        }
        var out = "\n\n[对方是谁]\n" + bits.joined(separator: "\n")
        if let parent = me.parentId, !parent.isEmpty, me.row.string("fateLine").isEmpty {
            out += "\n\n[你和这个人的关系]\nYou have only just met. You do not know each other well."
        }
        return out
    }

    private static func bondBlock(char: Character, rootId: String) -> String {
        let key = rootId.isEmpty ? "root" : rootId
        // 「你们之间」那一块存在 states[根账号].blocks.us；没写过时退回关系底色（网页版 mind.blocksOf、bond.textOf）
        let us = (char.row["states"]?[key]?["blocks"]?["us"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bond = (char.row["bonds"]?[key]?["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = us.isEmpty ? bond : us
        return text.isEmpty ? "" : "\n\n[你们之间的关系]\n\(text)"
    }

    private static func banPiece(_ s: AppSettings) -> String {
        let phrases = Ban.list(s)
        guard !phrases.isEmpty else { return "" }
        let list = phrases.map { "- " + $0.replacingOccurrences(of: "*", with: "…") }.joined(separator: "\n")
        return Templates.render("skeleton.ban", ["list": list], settings: s)
    }

    /// 旁白「每轮至少几行」那一句（网页版 narrationLeast，一字不差）。
    static func narrationLeast(_ v: Double) -> String {
        let n = max(0, Int(v.rounded()))
        if n == 0 { return "" }
        return n == 1 ? " Every reply contains at least one\nnarration line." : " Every reply contains at least \(n) narration lines."
    }

    /// 能力一节。原生版只开回复解析认得的那几项。
    /// 顺序照网页版 CAPS 数组：表情、引用、转账、礼物、位置、外卖、拍一拍、骰子、改备注、回应、不回复、撤回、旁白、时间戳。
    private static func capabilities(char: Character, chat: Chat, msgs: [Message], settings s: AppSettings) -> String {
        let off = Set((s.raw["capsOff"]?.array ?? []).compactMap(\.string))
        let lean = s.raw["promptLean"]?.bool ?? true
        let recent = msgs.suffix(8)
        func used(_ pattern: String) -> Bool {
            recent.contains { $0.content.range(of: pattern, options: .regularExpression) != nil
                || $0.kind.range(of: pattern, options: .regularExpression) != nil }
        }
        var lines: [String] = []
        var details: [String] = []
        func cap(_ id: String, on: Bool, hot: Bool, line: String?, detail: () -> String) {
            guard on, !off.contains(id) || id == "time" else { return }
            if !lean || hot || line == nil { details.append(detail()) } else if let line { lines.append(line) }
        }

        let stickers = stickerNames(char: char, limit: Int(s.num(used(#"^sticker$|[\[【]表情"#) ? "stickerHot" : "stickerCold",
                                                                   used(#"^sticker$|[\[【]表情"#) ? 60 : 12)))
        cap("sticker", on: !stickers.isEmpty, hot: true, line: nil) {
            Templates.render("skeleton.sticker", ["names": stickers], settings: s)
        }
        cap("quote", on: msgs.count >= 2, hot: used(#"[\[【](引用|回复)"#),
            line: "Quote: write a line on its own, [引用：a short excerpt of that message], then what you want to say on the next line") {
            Templates.get("skeleton.quote", settings: s)
        }
        func pending(_ kind: String) -> Bool { msgs.contains { $0.kind == kind && $0.row.string(kind) == "pending" } }
        cap("transfer", on: char.row["canTransfer"]?.bool != false, hot: used(#"^transfer$|[\[【]转账"#) || pending("transfer"),
            line: "Send money: write a line on its own, [转账：amount note]; on receiving money, write [收款] or [退回]") {
            let label = Interact.currencyLabel(s)
            return Templates.render("skeleton.transfer", ["currency": label.isEmpty ? "" : "\nMoney in this conversation is \(label); write amounts on that scale."], settings: s)
        }
        cap("gift", on: char.row["canSendGift"]?.bool != false, hot: used(#"^gift$|[\[【]礼物"#) || pending("gift"),
            line: "Give a gift: write a line on its own, [礼物：cover name | what is inside]; on receiving one, write [拆开] or [拒收]") {
            Templates.get("skeleton.gift", settings: s)
        }
        cap("location", on: char.row["canSendLocation"]?.bool != false, hot: used(#"^location$|[\[【](位置|定位)"#),
            line: "Share your location: write a line on its own, [位置：place name, address]") {
            let tz = char.row.string("timezone")
            return Templates.render("skeleton.location", ["city": tz.isEmpty ? "" : " (you are in \(tz))"], settings: s)
        }
        cap("takeout", on: char.row["canTakeout"]?.bool != false, hot: used(#"^takeout$|[\[【](外卖|请客|代付)"#) || pending("takeout"),
            line: "Order delivery: [外卖：item amount] for yourself, [请客：…] for them, [代付：…] paid by them; for an order they placed, write [要了] or [不要]") {
            Templates.get("skeleton.takeout", settings: s)
        }
        cap("pat", on: char.row["canPat"]?.bool != false, hot: used(#"拍了拍|[\[【]拍"#),
            line: "Nudge: write a line on its own, [拍一拍]") {
            Templates.get("skeleton.pat", settings: s)
        }
        cap("dice", on: char.row["canDice"]?.bool != false, hot: used(#"^dice$|[\[【]骰子"#),
            line: "Roll a die: write a line on its own, [骰子]; the system rolls it, and the result is not knowable this turn") {
            Templates.get("skeleton.dice", settings: s)
        }
        let theirs = chat.row.string("charRemark").trimmingCharacters(in: .whitespaces)
        let mineRemark = char.row.string("remark").trimmingCharacters(in: .whitespaces)
        cap("remark", on: char.row["canRemark"]?.bool != false, hot: used(#"[\[【]备注|将你的备注改为"#),
            line: "Rename the other party in your own contacts: write a line on its own, [备注：new name]. Currently: \(theirs.isEmpty ? "no name set" : theirs)."
                + (mineRemark.isEmpty ? "" : " They have you saved as: \(mineRemark).")) {
            Templates.render("skeleton.remark", ["current": theirs.isEmpty ? "no name set" : theirs,
                                                 "mine": mineRemark.isEmpty ? "your own name" : mineRemark], settings: s)
        }
        cap("react", on: char.row["canReact"]?.bool != false && !msgs.isEmpty,
            hot: recent.contains { !($0.row["reactions"]?.array ?? []).isEmpty || $0.kind == "silence" },
            line: "React to a message with an emoji: write a line on its own, [回应：one emoji：a short excerpt of that message]") {
            Templates.get("skeleton.react", settings: s)
        }
        cap("silence", on: char.row["canSilence"]?.bool == true, hot: recent.contains { $0.kind == "silence" },
            line: "Send nothing this turn: output exactly [不回复] and nothing else") {
            Templates.get("skeleton.silence", settings: s)
        }
        cap("recall", on: char.row["canRecall"]?.bool != false, hot: used(#"[\[【]撤回"#) || recent.contains(where: \.isRecalled),
            line: "Withdraw a message: write [撤回] on its own line directly after that message.") {
            Templates.render("skeleton.recall", ["post": ""], settings: s)
        }
        // 旁白：这段会话打开了才有（网页版 capabilities.js 的 narration）
        cap("narration", on: chat.row.bool("narration"), hot: true, line: nil) {
            Templates.render("skeleton.narration", ["least": narrationLeast(s.raw["narrationMin"]?.number ?? 1)], settings: s)
        }
        let stampOn = (s.raw["injectTime"]?.bool ?? true) && (s.raw["timeStamp"]?.bool ?? true)
        cap("time", on: stampOn, hot: true, line: nil) { Templates.get("skeleton.time", settings: s) }

        var out = ""
        if !lines.isEmpty {
            out += "\n\n" + Templates.render("skeleton.abilities", ["list": lines.map { "\u{00B7} " + $0 }.joined(separator: "\n")], settings: s)
        }
        for d in details { out += "\n\n" + d.trimmingCharacters(in: .whitespacesAndNewlines) }
        return out
    }

    /// 表情名字：各分组轮流取一个，组内用得多的在前；重名的带上分组。一行一个（网页版 stickerNames）。
    private static func stickerNames(char: Character, limit: Int) -> String {
        if char.row["canSendSticker"]?.bool == false { return "" }
        guard let rows = try? Database.shared.all("stickers"), !rows.isEmpty else { return "" }
        let cap = limit > 0 ? limit : Int.max
        func norm(_ n: String) -> String {
            n.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\.(png|jpe?g|gif|webp)$"#, with: "", options: [.regularExpression, .caseInsensitive]).lowercased()
        }
        var counts: [String: Int] = [:]
        for r in rows { counts[norm(r.string("name")), default: 0] += 1 }
        var groups: [String: [Row]] = [:]
        var order: [String] = []
        for r in rows {
            let g = r.string("group").trimmingCharacters(in: .whitespaces).isEmpty ? "默认" : r.string("group").trimmingCharacters(in: .whitespaces)
            if groups[g] == nil { order.append(g) }
            groups[g, default: []].append(r)
        }
        let lists = order.map { g in groups[g]!.sorted { ($0.number("useCount") ?? 0) > ($1.number("useCount") ?? 0) } }
        var out: [String] = []
        var i = 0
        outer: while out.count < cap {
            var any = false
            for list in lists where i < list.count {
                any = true
                let r = list[i]
                let name = r.string("name").trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    let g = r.string("group").trimmingCharacters(in: .whitespaces)
                    out.append((counts[norm(name)] ?? 0) > 1 ? "\(name)（\(g.isEmpty ? "默认" : g)）" : name)
                }
                if out.count >= cap { break outer }
            }
            if !any { break }
            i += 1
        }
        return out.map { "- \($0)" }.joined(separator: "\n")
    }

    // MARK: - 世界书

    private struct Lore { var before: [String] = []; var after: [String] = []; var deep: [(Int, String)] = [] }

    private static func activateLore(char: Character, scanText: String, budget: Int) -> Lore {
        let books = ((try? Repo.lorebooks()) ?? []).filter { $0.purpose == "chat" && ($0.global || char.lorebookIds.contains($0.id)) }
        var hits: [LoreEntry] = []
        for book in books {
            for e in book.entries where e.enabled && !e.isCard && !e.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if hit(e, scanText) { hits.append(e) }
            }
        }
        hits.sort { a, b in
            if a.part != b.part { return a.part == "before" }
            if a.depth != b.depth { return a.depth > b.depth }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.order < b.order
        }
        var lore = Lore()
        var used = 0
        for e in hits {
            let text = e.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if budget > 0 {
                let cost = TokenEstimate.of(text)
                if used + cost > budget { continue }
                used += cost
            }
            if e.depth > 0 { lore.deep.append((e.depth, text)) }
            else if e.part == "before" { lore.before.append(text) }
            else { lore.after.append(text) }
        }
        return lore
    }

    private static func hit(_ e: LoreEntry, _ scan: String) -> Bool {
        if e.constant { return true }
        let hay = e.caseSensitive ? scan : scan.lowercased()
        func any(_ keys: [String]) -> Bool {
            keys.contains { k in
                let key = e.caseSensitive ? k : k.lowercased()
                return !key.isEmpty && hay.contains(key)
            }
        }
        guard any(e.keys) else { return false }
        if !e.secondaryKeys.isEmpty && !any(e.secondaryKeys) { return false }
        if e.probability < 100 { return Double.random(in: 0..<100) < e.probability }
        return true
    }

    private static func loreBlock(_ items: [String]) -> String {
        items.isEmpty ? "" : "\n\n[世界设定]\n" + items.joined(separator: "\n")
    }

    // MARK: - 记忆

    private static let about = ["user": "(about the user) ", "char": "(about yourself) ", "both": "(about both of you) "]

    static func visibleMemories(char: Character, chat: Chat, rootId: String, personas: [Persona]) throws -> [Memory] {
        // 角色本人与小号共用记忆，除非大号关了 altShare
        let root = char.parentId.flatMap { $0.isEmpty ? nil : $0 } ?? char.id
        var family = [root]
        if let rootChar = try Repo.character(root), rootChar.row["altShare"]?.bool != false {
            family += try Repo.characters().filter { $0.parentId == root }.map(\.id)
        }
        return try family.flatMap { try Repo.memories(charId: $0) }.filter { m in
            !m.charId.isEmpty && m.fateHidden.isEmpty
                && (m.scopeChat.isEmpty || m.scopeChat == chat.id)
                && (m.personaId.isEmpty || Repo.rootId(of: m.personaId, in: personas) == rootId)
        }
    }

    private static func isLiveOpen(_ m: Memory) -> Bool { m.kind == .open && m.status == "open" }

    private static func pinnedBlock(_ all: [Memory], max: Int) -> String {
        var list = all.filter { ($0.pinned || $0.taboo) && $0.supersededBy.isEmpty }
            .sorted { ($0.row.number("updatedAt") ?? 0) > ($1.row.number("updatedAt") ?? 0) }
        if max > 0 { list = Array(list.prefix(max)) }
        guard !list.isEmpty else { return "" }
        let keep = list.filter { !$0.taboo }.map { "- \(about[$0.row.string("about")] ?? "")\($0.content)" }
        let taboo = list.filter(\.taboo).map { "- \($0.content)" }
        var parts: [String] = []
        if !keep.isEmpty { parts.append(keep.joined(separator: "\n")) }
        if !taboo.isEmpty {
            parts.append("Do not raise the following yourself. If the other party raises one, you may respond to it.\n" + taboo.joined(separator: "\n"))
        }
        return "\n\n[一直记着]\n" + parts.joined(separator: "\n\n")
    }

    private static func recentMemories(_ all: [Memory], limit: Int) -> [Memory] {
        Array(all.filter { $0.rank != "S" && $0.supersededBy.isEmpty && !$0.pinned && !$0.taboo && $0.kind != .open }
            .sorted { $0.at > $1.at }
            .prefix(max(0, limit)))
    }

    private static func recentBlock(_ list: [Memory], now: Date) -> String {
        guard !list.isEmpty else { return "" }
        let lines = list.map { "- \(TimeText.ago(Date(millis: $0.at), now: now))\u{3000}\(about[$0.row.string("about")] ?? "")\($0.content)" }
        return "\n\n[最近记下的]\n" + lines.joined(separator: "\n")
            + "\nThese are the most recent things you noted about the two of you, newest first. They are here because they are recent, not because they bear on what was just said."
    }

    /// 不用向量的召回：关键词命中，或者字的两两组合在最近几条里出现得够多；再按近期、用过几次、权重加分。
    /// 网页版 context/memory.js 的 recall 的简化版：没有同一时段、最早几条、疲劳这几项，也不做去重换位。
    private static func recall(_ all: [Memory], scanText: String, skip: Set<String>, topK: Int, now: Date) -> [Memory] {
        let scan = scanText.lowercased()
        let scanGrams = bigrams(scan)
        let pool = all.filter { m in
            m.rank != "S" && m.supersededBy.isEmpty && !m.pinned && !m.taboo && !isLiveOpen(m) && !skip.contains(m.id)
        }
        let scored: [(Memory, Double)] = pool.compactMap { m in
            let kw = m.keywords.contains { !$0.isEmpty && scan.contains($0.lowercased()) } ? 1.0 : 0
            let grams = bigrams(m.content.lowercased())
            let cover = grams.isEmpty ? 0 : Double(grams.intersection(scanGrams).count) / Double(grams.count)
            let cue = max(kw, cover)
            let settled = isSettledRecently(m, now: now)
            guard cue >= 0.04 || settled else { return nil }
            let last = max(m.row.created ?? 0, m.row.number("lastUsedAt") ?? 0)
            let days = (now.millis - last) / 86_400_000
            let recentScore = pow(2, -days / 45)
            let strength = log1p(m.row.number("useCount") ?? 0) / log1p(10)
            let weight = (m.row.number("weight") ?? 1) / 2
            let score = cue + 0.35 * recentScore + 0.25 * strength + 0.3 * weight + (settled ? 0.5 : 0)
                + (m.row.string("source") == "manual" ? 0.2 : 0)
            return (m, score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(max(0, topK)).map(\.0)
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard chars.count >= 2 else { return [] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
    }

    private static func isSettledRecently(_ m: Memory, now: Date) -> Bool {
        guard m.kind == .open, m.status == "done" || m.status == "dropped", let done = m.row.number("doneAt") else { return false }
        return now.millis - done <= 14 * 86_400_000
    }

    private static func recallText(_ items: [Memory], now: Date) -> String {
        var left = items
        func take(_ pred: (Memory) -> Bool) -> [Memory] {
            let got = left.filter(pred)
            left.removeAll(where: pred)
            return got
        }
        let groups: [(String, [Memory])] = [
            ("Recently settled:", take { isSettledRecently($0, now: now) }),
            ("Formerly true:", take { $0.kind == .fact && ($0.row.number("validTo") ?? 0) > 0 }),
            ("Always true:", take { $0.kind == .fact && ["fact", "profile", "pattern"].contains($0.row.string("category")) }),
            ("That happened:", take { _ in true }),
        ]
        var out = "[相关记忆]\nNotes that may bear on the present conversation, for reference. Ignore any that\ndo not fit. Where two entries conflict, the one with the later date is current."
        for (head, list) in groups where !list.isEmpty {
            out += "\n\n\(head)\n" + list.map { lineOf($0, now: now) }.joined(separator: "\n")
        }
        return out
    }

    private static func lineOf(_ m: Memory, now: Date) -> String {
        var s = "- "
        if m.at > 0 {
            let d = Date(millis: m.at)
            s += "\(TimeText.day(d)) (\(TimeText.ago(d, now: now))) "
        }
        s += (about[m.row.string("about")] ?? "") + m.content
        let due = m.row.string("dueAt")
        if !due.isEmpty { s += " (due \(due))" }
        if let until = m.row.number("validTo"), until > 0 { s += " (until \(TimeText.day(Date(millis: until))))" }
        if m.kind == .open, m.status == "done" || m.status == "dropped", let done = m.row.number("doneAt") {
            let result = m.row.string("result")
            s += "; \(m.status == "done" ? "settled" : "dropped") on \(TimeText.day(Date(millis: done)))" + (result.isEmpty ? "" : ": \(result)")
        }
        return s
    }

    // MARK: - 时间

    private static func timeBlock(char: Character, msgs: [Message], settings s: AppSettings, now: Date) -> String {
        guard s.raw["injectTime"]?.bool ?? true else { return "" }
        let zone = char.row.string("timezone")
        let charZone = TimeZone(identifier: zone) ?? .current
        var lines: [String] = []
        if !zone.isEmpty {
            lines.append("You are in \(zone). It is now \(TimeText.format(now, zone: charZone)).")
        } else {
            lines.append("It is now \(TimeText.format(now)).")
        }
        let offset = charZone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)
        if offset != 0 {
            let f = DateFormatter()
            f.timeZone = .current
            f.dateFormat = "HH:mm"
            lines.append("The other party is in \(TimeZone.current.identifier), where it is now \(f.string(from: now)), \(diffText(abs(offset) / 60)) from your own clock.")
        }
        // 从当前这一轮用户消息之前的最后一条算
        var i = msgs.count - 1
        while i >= 0 && msgs[i].role == .user { i -= 1 }
        if i >= 0 {
            let minutes = Int((now.millis - msgs[i].createdAt) / 60_000)
            if minutes < 5 { lines.append("The two of you are mid-conversation.") }
            else if minutes < 60 { lines.append("\(minutes) minutes have passed since either of you last spoke.") }
            else if minutes < 1440 { lines.append("\(minutes / 60) hours have passed since either of you last spoke.") }
            else { lines.append("\(minutes / 1440) days have passed since either of you last spoke.") }
        }
        return "\n\n[现在几点]\n" + lines.joined(separator: "\n")
    }

    private static func diffText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hours" : "\(h) hours \(m) minutes"
    }
}

extension AppSettings {
    /// 数值设置，没存取网页版的默认值。
    func num(_ key: String, _ fallback: Double) -> Double { raw[key]?.number ?? fallback }
}

/// 网页版 tokens.js 的粗估：中日韩字 0.9，其余 0.28。
enum TokenEstimate {
    static func of(_ s: String) -> Int {
        var cjk = 0, other = 0
        for u in s.unicodeScalars {
            if (0x3000...0x9FFF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value) || (0xF900...0xFAFF).contains(u.value) { cjk += 1 }
            else { other += 1 }
        }
        return Int((Double(cjk) * 0.9 + Double(other) * 0.28).rounded(.up))
    }
}

/// 时间的几种写法，和网页版 time.js 一致。
enum TimeText {
    /// `YYYY-MM-DD 周X HH:mm`
    static func format(_ d: Date, zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd EEE HH:mm"
        return f.string(from: d)
    }

    static func day(_ d: Date, zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// today / yesterday / N days ago / N weeks ago / N months ago / about a year ago / N years ago
    static func ago(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 14 { return "\(days) days ago" }
        if days < 60 { return "\(Int((Double(days) / 7).rounded())) weeks ago" }
        if days < 365 { return "\(Int((Double(days) / 30).rounded())) months ago" }
        if days < 730 { return "about a year ago" }
        return "\(days / 365) years ago"
    }
}
