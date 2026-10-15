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
    /// call：通话时的两段规则（通话规则、语音台本）。给了就按「通话」那一份条目顺序拼，聊天记录后面不挂此刻的状态与召回。
    static func build(chat chat0: Chat, char: Character, settings s: AppSettings, now: Date = Date(),
                      excludeTurn: String? = nil, call: (rule: String, script: String)? = nil) throws -> Built {
        var chat = chat0
        // 通话里不让模型在台词后面夹译文：拼提示词时把这段对话的翻译摘掉（网页版 call.js 的 plain）
        if call != nil { chat.row["translateTo"] = .string("") }
        // 我发的被角色拒收的不进历史（网页版 ties.keepDelivered）
        let all = Ties.keepDelivered(chat, try Repo.messages(chatId: chat.id).filter { !$0.isError && (excludeTurn == nil || $0.turnId != excludeTurn) })
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
                                         topK: Int(s.num("memoryTopK", 6)), now: now, openDays: staleDays(s)) : []

        // 各段先算出来，先后与开关交给预设的条目顺序（Layout，网页版 4.387）。默认顺序与从前一字不差
        let memoryDepth = Int(s.num("memoryDepth", 1))
        var blocks: [String: String] = [
            "lorebook": loreBlock(lore.before),
            "bond": bondBlock(char: char, rootId: rootId),
            "state": stateBlock(char: char, rootId: rootId, memories: memories, settings: s, now: now),
            "character": characterBlock(char),
            "loreAfter": loreBlock(lore.after),
            "user": userBlock(me: me, char: char),
            "pinned": pinnedBlock(memories, max: Int(s.num("pinnedMax", 8))),
            "time": timeBlock(char: char, msgs: all, settings: s, now: now),
            "recent": recentBlock(recent, now: now),
            "diary": Diary.block(char: char, pid: me?.id ?? "", userName: me?.name ?? "the user", now: now),
            "day": DayPlan.block(char, at: now),
            "music": Netease.block(char, now: now.millis),
            "moments": Moments.block(char: char, userName: me?.name ?? "对方", now: now),
            "ties": Ties.block(char, chat: chat, userName: me?.name ?? "the user"),
            // 情侣空间：在一起多少天、快到的纪念日、没完成的约定。在空间里单独开启，默认不注入
            "space": Space.block(chat, now: now),
            // 身体状况：你的那一份在「健康 - 设置」里开（默认关），角色那一份跟着它的 healthOn
            "health": Health.block(char: char, userName: me?.name ?? "", settings: s),
            // 你的日程（「日常 - 我的日程」）：没有日程时为空；不给这个角色看的整段不给
            // 代发与手机上的对话（角色手机）：只取有代发参与的那几句
            "proxy": Theirs.proxyBlock(char: char, personaId: chat.personaId, userName: me?.name ?? "", settings: s),
            "userSched": UserSched.block(char: char, personaId: chat.personaId, userName: me?.name ?? "", settings: s, at: now),
        ]
        // 本轮相关记忆：深度 0 时留在设定区，否则贴着对话末尾（固定在聊天记录下面，不参与排序）
        if memoryDepth == 0 && !recalled.isEmpty { blocks["memory"] = recallText(recalled, now: now) }
        // 基线之后新加的区块：用户开了才进（网页版 4.486）
        blocks = blocks.filter { NewFeat.blockOn($0.key, s) }

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
        P["inner"] = InnerVoice.piece(chat, settings: s)
        // 状态栏：开着、有要模型写的栏目时才出现（网页版 4.399）。通话里没有
        if call == nil { P["status"] = StatusBar.piece(chat, msgs: all, names: names, settings: s) }
        if let call {
            P["call"] = call.rule
            P["callScript"] = call.script
        }
        let arranged = Layout.arrange(call == nil ? "chat" : "call", pieces: P, settings: s, names: names)

        // 放在历史末尾的那一段：条目里排在聊天记录下面的（默认是「此刻的状态」），再加本轮相关记忆。通话里没有这一段
        var tailParts: [String] = []
        if !arranged.tail.isEmpty { tailParts.append(arranged.tail) }
        if call == nil && memoryDepth > 0 && !recalled.isEmpty { tailParts.append(recallText(recalled, now: now)) }
        if let t = translateTail(chat, settings: s) { tailParts.append(t) }

        let (messages, seen) = history(all, chat: chat, char: char, settings: s, tail: tailParts.joined(separator: "\n\n"),
                                       tailDepth: max(1, memoryDepth), lore: lore.deep)
        return Built(system: arranged.system, messages: messages, recalled: recalled.map(\.id),
                     seenImages: seen)
    }

    // MARK: - 历史

    /// group：群聊时成员 id 对应群里显示的名字。成员说的话都算 assistant，前面带着名字 ——
    /// 和它要写出来的格式一模一样，历史就是示范（网页版 buildGroupHistory）。
    private static func history(_ all: [Message], chat: Chat, char: Character, settings s: AppSettings,
                                tail: String, tailDepth: Int, lore: [(Int, String)],
                                group: [String: String]? = nil) -> ([AIMessage], [String]) {
        let window: [Message]
        if s.raw["historyMode"]?.string == "turn" {
            window = takeTurns(all, Int(s.num("historyTurns", 10)))
        } else {
            let limit = Int(s.num("historyLimit", 20))
            window = limit > 0 ? Array(all.suffix(limit)) : all
        }
        let stampOn = Clock.enabled(s)
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
        let lastFile = ChatFiles.lastWithText(window)
        for raw in window {
            // 正则替换里「发给角色的」那一份（存着的原文不动）
            let m = RegexRules.promptMessage(raw, chat: chat, settings: s)
            var text = (stampOn ? timeLine(m, prev) : "") + withQuote(m, byId)
            // 分享的歌带上歌词（「用量与上限」里可以关、可以只带前几句）
            if m.kind == "song" { text += songLyric(m, s) }
            // 文件：只有最近一份带正文，更早的只带文件名（网页版 4.271）
            if m.id == lastFile && !m.isRecalled { text += "\n" + ChatFiles.body(m, s) }
            if m.isRecalled && m.role == .user {
                let seen = m.row["recalled"]?["seen"]?.bool ?? false
                text = seen ? "[撤回了一条消息：\(m.content)]" : "[撤回了一条消息]"
            }
            if let group, m.role == .char {
                if m.isRecalled { text += "\n[撤回]" }
                let tr = chat.row.string("translateTo").isEmpty ? "" : m.row.string("translation")
                out.append(AIMessage(role: .assistant, content: "\(group[m.authorId] ?? "某人")：\(text)\(tr.isEmpty ? "" : " [译文：\(tr)]")"))
            } else if m.role == .char && m.authorId == char.id {
                if m.isRecalled { text += "\n[撤回]" }
                // 角色从前那几条带着译文读回去（网页版 engine.js）：历史里没有译文，模型接着就不写了
                let tr = chat.row.string("translateTo").isEmpty ? "" : m.row.string("translation").trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(AIMessage(role: .assistant, content: tr.isEmpty ? text : "\(text) [译文：\(tr)]"))
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

    /// 历史里的时间（网页版 engine.js 的 timeLine）：按我的时区写，虚拟时间时整条时间线一起平移
    private static func timeLine(_ m: Message, _ prev: Message?) -> String {
        let s = AppSettings.load()
        let uz = Clock.zone(Clock.userZone(s))
        let full = "[\(TimeText.format(Clock.toWorld(m.createdAt, s), zone: uz))] "
        let newDay = prev.map { TimeText.day(Clock.toWorld($0.createdAt, s), zone: uz) != TimeText.day(Clock.toWorld(m.createdAt, s), zone: uz) } ?? true
        if m.role == .char {
            let stamp = m.row.string("stamp")
            if !stamp.isEmpty { return "[\(stamp)] " }
            return newDay ? full : ""
        }
        let gap = prev.map { m.createdAt - $0.createdAt >= 30 * 60_000 } ?? true
        return newDay || gap ? full : ""
    }

    static func songLyric(_ m: Message, _ s: AppSettings) -> String {
        guard s.raw["songLyric"]?.bool != false else { return "" }
        if m.row.bool("songPure") { return "\n[歌词]\n纯音乐" }
        let lines = m.row.string("songLyric").components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        let n = Int(s.raw["songLyricLines"]?.number ?? 20)
        return "\n[歌词]\n" + (n > 0 ? Array(lines.prefix(n)) : lines).joined(separator: "\n")
    }

    private static func withQuote(_ m: Message, _ byId: [String: Message]) -> String {
        // 封到某一天才能拆的信：那天之前只有信封（网页版 4.336）
        if Space.sealed(m) { return Space.sealedText(m) }
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
    /// 顺序照网页版 CAPS 数组：图片、语音、表情、引用、转账、礼物、位置、外卖、拍一拍、骰子、改备注、回应、不回复、撤回、旁白、时间戳。
    /// 群聊里说得通的那几样（网页版 GROUP_CAPS）。转账、礼物这些是「你和我」之间的事，群里没有一个对象可以接。
    /// 拼进提示词的区块 id（RuleFixTests 核对它们都登记过）
    static let blockIds = ["lorebook", "bond", "state", "character", "loreAfter", "user", "pinned", "time", "recent",
                           "diary", "day", "music", "moments", "ties", "memory", "space", "health"]
    /// 拼进提示词的能力 id（RuleFixTests 核对它们都登记过）
    static let capIds = ["image", "voice", "ties", "listen", "agenda", "pact", "sticker", "keepphoto", "quote", "transfer", "gift", "location", "takeout",
                         "lockcode", "pat", "dice", "remark", "react", "silence", "recall", "narration", "time", "translate"]
    static let protocolCaps: Set<String> = ["time", "translate"]
    static let ownSwitchCaps: Set<String> = ["narration", "inner", "dm", "alt", "drafts"]

    private static let groupCaps: Set<String> = ["image", "video", "voice", "sticker", "quote", "dice", "time", "translate", "narration", "inner", "ties"]

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
            // 关掉的不进；解析格式的一部分（时间戳、译文）与自己有开关的（旁白、心声）不受这里管（网页版 PROTOCOL、OWN_SWITCH）
            guard on, !off.contains(id) || protocolCaps.contains(id) || ownSwitchCaps.contains(id) else { return }
            guard NewFeat.capOn(id, s) else { return }
            if chat.isGroup && !groupCaps.contains(id) { return }
            if !lean || hot || line == nil { details.append(detail()) } else if let line { lines.append(line) }
        }

        // 发图片：配好了生图接口、角色卡没关掉才有（网页版 CAPS 的 image）
        let img = s.activeImage
        let en = img?.promptLang == "en"
        cap("image", on: s.imageReady && char.row["canSendImage"]?.bool != false, hot: used(#"^image$|[\[【](图片|照片)"#),
            line: "Send an image: write a line on its own, [图片：a description of the image\(en ? ", in English" : "")]") {
            [Templates.get("skeleton.image", settings: s), ImageGen.styleAsk(s), en ? Templates.get("skeleton.image-en", settings: s) : ""]
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
        cap("voice", on: VoiceGen.canSpeak(char, s), hot: used(#"^voice$|[\[【]语音"#),
            line: "Send a voice message: write a line on its own, [语音：what you say]") {
            Templates.get("skeleton.voice", settings: s)
        }
        // 一起听、点歌、分享歌曲与歌单（网页版 capabilities.js 的 listen）。原生版直连网易云，曲库空着也能搜
        let listening = MusicListen.active(chat.id)
        // 好友与拉黑（网页版 capabilities.js 的 ties）：改自己这一方，群聊也可用
        cap("ties", on: true, hot: used(#"[\[【](拉黑|解除拉黑|删除好友|添加好友|通过好友申请)"#),
            line: "Block someone or remove them from your contacts: write a line on its own, [拉黑：name] or [删除好友：name]; undo with [解除拉黑：name] or [添加好友：name]") {
            Templates.get("skeleton.ties", settings: s)
        }
        cap("listen", on: char.row["canListen"]?.bool != false, hot: listening || used(#"^(listen|song)$|[\[【](一起听|点歌|建歌单|加入歌单|分享歌曲)"#),
            line: "Music: [一起听] to listen together, [点歌：song title - artist] to change the track, [分享歌曲：song title - artist] to send a song, [加入歌单：playlist | song - artist] to keep songs") {
            Templates.get("skeleton.listen", settings: s)
        }
        // 今天的安排：今天排了日程才有，一直给全文（网页版 capabilities.js 的 agenda，always）
        cap("agenda", on: DayPlan.brief(char) != nil, hot: true, line: nil) {
            Templates.get("skeleton.agenda", settings: s)
        }
        // 约定（网页版 capabilities.js 的 pact）：还欠着约定就一直给全文，它得知道「完成」怎么写才标得掉
        let openPact = msgs.contains { $0.kind == "pact" && $0.row.string("pact") == Space.pactOpen }
        cap("pact", on: char.row["canPact"]?.bool != false, hot: used(#"^pact$|[\[【]约定"#) || openPact,
            line: "Make a promise: write a line on its own, [约定：the thing]; when it is fulfilled, write [约定完成：the thing]") {
            Templates.get("skeleton.pact", settings: s)
        }
        let stickers = stickerNames(char: char, limit: Int(s.num(used(#"^sticker$|[\[【]表情"#) ? "stickerHot" : "stickerCold",
                                                                   used(#"^sticker$|[\[【]表情"#) ? 60 : 12)))
        cap("sticker", on: !stickers.isEmpty, hot: true, line: nil) {
            Templates.render("skeleton.sticker", ["names": stickers], settings: s)
        }
        // 往自己那台手机的相册里存一张。开关在「角色手机 - 相册」，默认关
        cap("keepphoto", on: Theirs.keepOn(char.id), hot: used(#"[\[【]存图"#),
            line: "Save a photo to your own phone: write a line on its own, [存图：what you are keeping]. A photo just sent to you is the one saved") {
            Templates.get("skeleton.keepphoto", settings: s)
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
        // 改自己手机的锁屏密码（网页版 4.222）：离上一次改不满设定的天数就不给，这一轮刚聊到密码时照样给。不告诉它现在的密码
        cap("lockcode", on: char.row["canChangeLock"]?.bool != false && chat.characterIds.count <= 1
                && (Theirs.lockCooled(char) || Theirs.askedLock(Array(msgs))),
            hot: Theirs.askedLock(Array(msgs)) || used(#"[\[【]改密码"#),
            line: "Change the passcode of your own phone: write a line on its own, [改密码：new digits｜what the digits are]") {
            Templates.get("skeleton.lockcode", settings: s)
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
        let stampOn = Clock.stampOn(s)
        cap("time", on: stampOn, hot: true, line: nil) { Templates.get("skeleton.time", settings: s) }
        // 译文：这段会话设了目标语言时，每条消息同一行跟一句 [译文：…]（随回复一起那一档，不多调接口）。
        // 「这几种标记各跟一句译文」只列这段会话实际开着的那几样（网页版 4.373）
        let lang = chat.row.string("translateTo").trimmingCharacters(in: .whitespaces)
        cap("translate", on: !lang.isEmpty, hot: true, line: nil) {
            var marks: [String] = []
            let voiceOn = VoiceGen.canSpeak(char, s) && !off.contains("voice") && !(chat.isGroup && !groupCaps.contains("voice"))
            if voiceOn { marks.append("[语音：…]") }
            if chat.row.bool("narration") { marks.append("[旁白：…]") }
            if InnerVoice.mode(chat) == "inline" { marks.append("[心声：…]") }
            let list = marks.count > 1 ? marks.dropLast().joined(separator: ", ") + " and " + marks.last! : (marks.first ?? "")
            let marked = [voiceOn ? Templates.get("skeleton.translate-voice", settings: s) : "",
                          list.isEmpty ? "" : Templates.render("skeleton.translate-marked", ["list": list], settings: s)]
                .filter { !$0.isEmpty }.joined(separator: " ")
            return Templates.render("skeleton.translate", ["lang": lang, "marked": marked.isEmpty ? "" : " " + marked], settings: s)
        }

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

    /// 这段文字会激活哪些条目（按注入的先后），以及一共估算多少 token。激活预览与拼提示词用同一份
    static func selectLore(char: Character, scanText: String, budget: Int) -> (items: [LoreEntry], used: Int) {
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
        var out: [LoreEntry] = []
        var used = 0
        for e in hits {
            let cost = TokenEstimate.of(e.content.trimmingCharacters(in: .whitespacesAndNewlines))
            if budget > 0 && used + cost > budget { continue }
            used += cost
            out.append(e)
        }
        return (out, used)
    }

    private static func activateLore(char: Character, scanText: String, budget: Int) -> Lore {
        var lore = Lore()
        for e in selectLore(char: char, scanText: scanText, budget: budget).items {
            let text = e.content.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// 译文提醒：格式要求开头说一遍、末尾再说一遍，长对话里才不会丢（网页版 skeleton.translate-tail）
    static func translateTail(_ chat: Chat, settings s: AppSettings) -> String? {
        let lang = chat.row.string("translateTo").trimmingCharacters(in: .whitespaces)
        guard !lang.isEmpty else { return nil }
        return Templates.render("skeleton.translate-tail", ["lang": lang], settings: s)
    }

    // MARK: 进行中的事与「现状」（网页版 context/memory.js 的 isOpen、isLive、stateLines、buildState）

    /// 挂的那个日子，按当天结束算（「周三」那天当天不算过期）。没有日子为 0
    static func dueTime(_ m: Memory) -> Double {
        let d = m.row.string("dueAt")
        let p = d.split(separator: "-").compactMap { Int($0) }
        guard d.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, p.count == 3,
              let t = Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 23, minute: 59, second: 59))
        else { return 0 }
        return t.millis
    }

    /// 还没了结：过了挂的日子三天之后不算
    static func isOpen(_ m: Memory, now: Date) -> Bool {
        guard m.kind == .open, m.status == "open", m.supersededBy.isEmpty else { return false }
        let due = dueTime(m)
        return due == 0 || now.millis <= due + 3 * 86_400_000
    }

    /// 还常驻在现状块里的：没挂日子的，记下之后超过 openStaleDays 天（默认 3，0 为一直）就不再常驻，交给召回
    static func isLive(_ m: Memory, now: Date, days: Int) -> Bool {
        guard isOpen(m, now: now) else { return false }
        if dueTime(m) > 0 || days == 0 { return true }
        return now.millis - m.at <= Double(days) * 86_400_000
    }

    private static func staleDays(_ s: AppSettings) -> Int { max(0, Int(s.num("openStaleDays", 3))) }

    static func stateLines(_ all: [Memory], settings s: AppSettings, now: Date) -> [String] {
        let max = Swift.max(0, Int(s.num("openMax", 10)))
        let live = all.filter { isLive($0, now: now, days: staleDays(s)) }.sorted { $0.at < $1.at }
        let keep = max > 0 && live.count > max ? Array(live.suffix(max)) : live
        return keep.map { m in
            let day = m.at > 0 ? TimeText.day(Date(timeIntervalSince1970: m.at / 1000)) + " " : ""
            let due = m.row.string("dueAt")
            return "- \(day)\(about[m.row.string("about")] ?? "")\(m.content)\(due.isEmpty ? "" : " (due \(due))")"
        }
    }

    /// [现状]：关于你、关于自己、最近（总结记忆时整块改写），以及进行中的事。记忆总开关关着时不给
    static func stateBlock(char: Character, rootId: String, memories: [Memory], settings s: AppSettings, now: Date) -> String {
        guard s.raw["memoryEnabled"]?.bool ?? true else { return "" }
        let key = rootId.isEmpty ? "root" : rootId
        let cur = char.row["states"]?[key]
        func text(_ id: String) -> String { (cur?["blocks"]?[id]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let open = stateLines(memories, settings: s, now: now)
        var parts: [String] = []
        if !text("user").isEmpty { parts.append("About the user:\n\(text("user"))") }
        if !text("self").isEmpty { parts.append("About yourself:\n\(text("self"))") }
        if !text("recent").isEmpty { parts.append("Lately:\n\(text("recent"))") }
        if !open.isEmpty { parts.append("Ongoing, not yet settled:\n\(open.joined(separator: "\n"))") }
        guard !parts.isEmpty else { return "" }
        let at = cur?["at"]?.number ?? 0
        let asOf = at > 0 ? " (as of \(TimeText.day(Date(timeIntervalSince1970: at / 1000))), \(TimeText.ago(Date(timeIntervalSince1970: at / 1000), now: now)))" : ""
        return "\n\n[现状]\(asOf)\n\(parts.joined(separator: "\n\n"))"
    }

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
    private static func recall(_ all: [Memory], scanText: String, skip: Set<String>, topK: Int, now: Date, openDays: Int = 3) -> [Memory] {
        let scan = scanText.lowercased()
        let scanGrams = bigrams(scan)
        let pool = all.filter { m in
            m.rank != "S" && m.supersededBy.isEmpty && !m.pinned && !m.taboo && !isLive(m, now: now, days: openDays) && !skip.contains(m.id)
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

    /// 现在几点（网页版 context/basic.js 的 time）。角色明确设过时区才写地名，两边不在一个时区才说时差
    private static func timeBlock(char: Character, msgs: [Message], settings s: AppSettings, now real: Date) -> String {
        guard Clock.enabled(s) else { return "" }
        let n = Clock.now(s, real: real)
        let cz = Clock.charZone(char, s)
        let uz = Clock.userZone(s)
        let named = !char.row.string("timezone").isEmpty
        var lines = [named ? "You are in \(Clock.label(cz)). It is now \(TimeText.format(n, zone: Clock.zone(cz)))."
                           : "It is now \(TimeText.format(n, zone: Clock.zone(cz)))."]
        let d = Clock.zoneDiff(cz, uz, at: n)
        if d != 0 {
            lines.append("The other party is in \(Clock.label(uz)), where it is now \(Clock.clockOnly(n, zone: uz)), \(diffText(abs(d))) from your own clock.")
        }
        // 从当前这一轮用户消息之前的最后一条算；量的是真实时间
        var i = msgs.count - 1
        while i >= 0 && msgs[i].role == .user { i -= 1 }
        if i >= 0 {
            let minutes = Int((real.millis - msgs[i].createdAt) / 60_000)
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

// MARK: - 群聊（网页版 engine.js 的 buildGroupSystem 与 buildGroupHistory）

extension ChatPrompt {
    /// 设定区分两层：全群一份（世界书取各人的并集、你是谁、时间）；每人一份（人设、情境、示例、核心设定、关系、钉住的、最近记下的、本轮召回）。
    static func buildGroup(chat: Chat, members: [Character], settings s: AppSettings, now: Date = Date(),
                           excludeTurn: String? = nil) throws -> Built {
        guard let lead = members.first else { throw StoreError(message: "群里没有成员") }
        let all = try Repo.messages(chatId: chat.id).filter { !$0.isError && (excludeTurn == nil || $0.turnId != excludeTurn) }
        let personas = try Repo.personas()
        let me = try personas.first(where: { $0.id == chat.personaId }) ?? Repo.activePersona(s)
        let userName = (me?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "对方"
        let rootId = Repo.rootId(of: me?.id ?? "", in: personas)
        let scanText = scanTextOf(all, window: Int(s.num("scanWindow", 6)))
        let budget = Int(s.num("contextBudget", 0))
        let memoryOn = s.raw["memoryEnabled"]?.bool ?? true
        let memoryDepth = Int(s.num("memoryDepth", 1))

        // 世界书：成员各自激活，取并集
        var before: [String] = [], after: [String] = [], deep: [(Int, String)] = []
        for c in members {
            let l = activateLore(char: c, scanText: scanText, budget: budget > 0 ? Int((Double(budget) * 0.4).rounded()) : 0)
            for x in l.before where !before.contains(x) { before.append(x) }
            for x in l.after where !after.contains(x) { after.append(x) }
            for x in l.deep where !deep.contains(where: { $0.1 == x.1 }) { deep.append(x) }
        }

        var recalledIds: [String] = []
        var memberBlocks: [String] = []
        for c in members {
            var lines = ["[成员：\(c.name)]"]
            func add(_ head: String?, _ v: String) {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { lines.append(head.map { "\($0)\n\(t)" } ?? t) }
            }
            add(nil, c.persona)
            add("[当前情境]", c.scenario)
            add("[说话方式示例]", c.exampleDialogue)
            add("[核心设定]", c.core)
            let memories = try visibleMemories(char: c, chat: chat, rootId: rootId, personas: personas)
            let recent = memoryOn ? recentMemories(memories, limit: Int(s.num("memoryRecent", 10))) : []
            let body = [bondBlock(char: c, rootId: rootId), stateBlock(char: c, rootId: rootId, memories: memories, settings: s, now: now),
                        pinnedBlock(memories, max: Int(s.num("pinnedMax", 8))), recentBlock(recent, now: now)]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            add(nil, body)
            if memoryOn {
                let r = recall(memories, scanText: scanText, skip: Set(recent.map(\.id)), topK: Int(s.num("memoryTopK", 6)), now: now, openDays: staleDays(s))
                if !r.isEmpty { add(nil, recallText(r, now: now)); recalledIds += r.map(\.id) }
            }
            memberBlocks.append(lines.joined(separator: "\n\n"))
        }

        let blocks: [String: String] = [
            "lorebook": loreBlock(before), "loreAfter": loreBlock(after),
            "user": userBlock(me: me, char: lead),
            "time": timeBlock(char: lead, msgs: all, settings: s, now: now),
        ]
        var P = Layout.groupPieces(blocks, order: Layout.injectOrder(s))
        let names = members.map(\.name).joined(separator: "、")
        P["groupOpening"] = Templates.render("skeleton.group-opening", ["userName": userName, "names": names], settings: s)
        P["members"] = memberBlocks.joined(separator: "\n\n")
        if !chat.summary.isEmpty { P["summary"] = "[更早之前发生过什么]\n\(chat.summary)" }
        P["groupRules"] = Templates.render("skeleton.group-rules", ["userName": userName, "example": lead.name], settings: s)
        P["rules"] = Templates.render("skeleton.rules", ["count": countText(Int(s.num("msgMin", 3)), Int(s.num("msgMax", 9)))], settings: s)
        P["caps"] = capabilities(char: lead, chat: chat, msgs: all, settings: s)
        P["inner"] = InnerVoice.piece(chat, settings: s)
        P["ban"] = banPiece(s)
        // 性别锚点：人多，放在贴着输出的末尾
        var gl = members.compactMap { c -> String? in
            let g = c.row.string("gender").trimmingCharacters(in: .whitespaces)
            return g.isEmpty ? nil : "\(c.name)：\(g)"
        }
        let ug = (me?.row.string("gender") ?? "").trimmingCharacters(in: .whitespaces)
        if !ug.isEmpty { gl.append("\(userName)：\(ug)") }
        if !gl.isEmpty { P["genderTail"] = Templates.render("skeleton.gender", ["lines": gl.joined(separator: "\n")], settings: s) }
        let arranged = Layout.arrange("group", pieces: P, settings: s, names: ["userName": userName])

        // 末尾：此刻的状态，以及这一轮被 @ 的人
        let display = Dictionary(members.map { ($0.id, GroupChat.nameIn(chat, $0)) }, uniquingKeysWith: { a, _ in a })
        let called = GroupChat.pendingMentions(all).compactMap { display[$0] }
        var tail: [String] = []
        if !arranged.tail.isEmpty { tail.append(arranged.tail) }
        if !called.isEmpty { tail.append(Templates.render("skeleton.group-mention", ["names": called.joined(separator: "、")], settings: s)) }
        if let t = translateTail(chat, settings: s) { tail.append(t) }

        let (messages, seen) = history(all, chat: chat, char: lead, settings: s, tail: tail.joined(separator: "\n\n"),
                                       tailDepth: max(1, memoryDepth), lore: deep, group: display)
        return Built(system: arranged.system, messages: messages, recalled: recalledIds, seenImages: seen)
    }
}
