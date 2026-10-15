import Foundation

// MARK: - 线下（网页版 engine.js 的 buildSceneSystem、buildSceneEnsembleSystem、buildSceneHistory）
//
// 线上是一条条短气泡，线下是大段散文，所以另走一条：另一套骨架、另一份预算、另一套历史。
// 共用的只有底下那些注入区块（角色卡、世界书、记忆、人设、时刻）。几个数和线上分开，一律 0 表示不限（第 13 条）。

extension ChatPrompt {
    static func sceneBudget(_ s: AppSettings) -> Int { max(0, Int(s.num("sceneBudget", 120_000))) }
    static func sceneMax(_ s: AppSettings) -> Int { max(0, Int(s.num("sceneMaxTokens", 0))) }

    /// 世界书与 B 级记忆按最近几段正文扫：该被这一场勾起来的是这一场的字
    static func sceneScan(_ list: [Row], _ s: AppSettings) -> String {
        let body = list.filter { $0.string("role") != Scenes.DIRECTOR }
        let n = Int(s.num("sceneScan", 4))
        return (n > 0 ? Array(body.suffix(n)) : body).map { $0.string("text") }.joined(separator: "\n")
    }

    /// 这一场里换了身份就按换过的来（4.283）
    static func sceneChar(_ scene: Row, _ c: Character) -> Character {
        guard let a = Scenes.castAs(scene, c.id) else { return c }
        var out = c
        if !a.name.isEmpty { out.row["name"] = .string(a.name) }
        if !a.persona.isEmpty { out.row["persona"] = .string(a.persona) }
        return out
    }

    /// 填了这一场的身份时，账号上的分区一并换掉（4.347），不和这一场的身份混在一起
    static func sceneMe(_ scene: Row, _ me: Persona?) -> Persona? {
        guard var me, let a = scene["meAs"]?.object else { return me }
        let n = a["name"]?.string ?? "", p = a["persona"]?.string ?? ""
        if n.isEmpty && p.isEmpty { return me }
        if !n.isEmpty { me.row["name"] = .string(n) }
        if !p.isEmpty {
            me.row["description"] = .string(p)
            me.row["sections"] = .object([:])
            me.row["charNotes"] = .array([])
        }
        return me
    }

    private static func sceneIdentity(_ char0: Character?, _ char: Character?, _ me0: Persona?, _ me: Persona?, settings s: AppSettings) -> String {
        var lines: [String] = []
        if let char, let char0, char.name != char0.name { lines.append("\(char0.name) 在这一场里是「\(char.name)」") }
        if let char, let char0, char.persona != char0.persona { lines.append("\(char.name)：\(char.persona)") }
        if let me, let me0, me.name != me0.name { lines.append("\(me0.name) 在这一场里是「\(me.name)」") }
        if let me, let me0, me.description != me0.description { lines.append("\(me.name)：\(me.description)") }
        guard !lines.isEmpty else { return "" }
        return Templates.render("skeleton.work-identity", ["lines": lines.joined(separator: "\n"),
                                                          "carry": Templates.get("skeleton.work-identity-carry", settings: s)], settings: s)
    }

    /// 这一轮该听哪几条场外指示：常驻的一直在，其余只管下一段
    static func directorLines(_ list: [Row]) -> [String] {
        var fresh: [Row] = []
        for b in list.reversed() {
            guard b.string("role") == Scenes.DIRECTOR else { break }
            if !b.bool("hold") { fresh.insert(b, at: 0) }
        }
        let held = list.filter { $0.string("role") == Scenes.DIRECTOR && $0.bool("hold") }
        return (held + fresh).map { $0.string("text").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// 这一场的几件事实。是数据，不是指令
    private static func sceneSetup(_ scene: Row, others: [Character], settings s: AppSettings) -> String {
        var lines: [String] = []
        if !scene.string("place").isEmpty { lines.append("地点：\(scene.string("place"))") }
        let now = Scenes.timeOf(scene.id)
        if !now.isEmpty { lines.append("时刻：\(now)") }
        if !others.isEmpty { lines.append("在场：\(others.map(\.name).joined(separator: "、"))") }
        let gone = Scenes.leftOf(scene)
        if !gone.isEmpty { lines.append("已离开：\(gone.map(\.name).joined(separator: "、"))") }
        let may = Scenes.enterable(scene).filter { c in !gone.contains { $0.id == c.id } }
        if !may.isEmpty { lines.append("可进场：\(may.map(\.name).joined(separator: "、"))") }
        if !scene.string("note").isEmpty { lines.append("情境：\(scene.string("note"))") }
        guard !lines.isEmpty else { return "" }
        return Templates.render("skeleton.scene-setup", ["lines": lines.joined(separator: "\n")], settings: s)
    }

    /// 离场与进场的写法：不止一个人在场、或者有人可以进来时才给。只说标记怎么写，不说什么时候该用（第 16 条）
    private static func sceneExits(_ scene: Row, settings s: AppSettings) -> String {
        guard Scenes.presentOf(scene).count > 1 || !Scenes.enterable(scene).isEmpty else { return "" }
        return "\n\n" + Templates.get("skeleton.scene-exits", settings: s)
    }

    private static func sceneBooks(_ scene: Row) -> (off: [String], on: [String]) {
        (scene.strings("offBookIds"), scene.strings("bookIds"))
    }

    private static func meOf(_ chat: Chat, _ s: AppSettings) throws -> (Persona?, [Persona]) {
        let personas = try Repo.personas()
        return (try personas.first(where: { $0.id == chat.personaId }) ?? Repo.activePersona(s), personas)
    }

    /// 写一段。more 是续写；list 是这一场到此为止的正文（重写时已经去掉那一段及之后的）
    static func buildScene(scene: Row, chat: Chat, char char0: Character, list: [Row], more: Bool = false,
                           settings s: AppSettings, now: Date = Date()) throws -> Built {
        let (me0, personas) = try meOf(chat, s)
        let char = sceneChar(scene, char0)
        let me = sceneMe(scene, me0)
        let others = Scenes.presentOf(scene).filter { $0.id != char.id }
        let names = ["charName": char.name.isEmpty ? "对方" : char.name, "userName": (me?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "对方"]
        let rootId = Repo.rootId(of: me0?.id ?? "", in: personas)
        let budget = sceneBudget(s)
        let scan = sceneScan(list, s)
        var lore = activateLore(char: char0, scanText: scan, budget: budget > 0 ? Int((Double(budget) * 0.4).rounded()) : 0, books: sceneBooks(scene))
        // 线下的历史里没有插深度的地方：按深度插的那几条并进角色后
        lore.after += lore.deep.map(\.1)
        let online = try Repo.messages(chatId: chat.id).filter { !$0.isError }
        let memories = try visibleMemories(char: char0, chat: chat, rootId: rootId, personas: personas)
        let memoryOn = s.raw["memoryEnabled"]?.bool ?? true
        let recent = memoryOn ? recentMemories(memories, limit: Int(s.num("memoryRecent", 10))) : []
        let recalled = memoryOn ? recall(memories, scanText: scan, skip: Set(recent.map(\.id)),
                                         topK: Int(s.num("memoryTopK", 6)), now: now, openDays: staleDays(s)) : []
        let blocks = dataBlocks(chat: chat, char: char, me: me, msgs: online, lore: lore, memories: memories, recent: recent,
                                recalled: recalled, rootId: rootId, settings: s, now: now)

        var P = Layout.groupPieces(blocks, order: Layout.injectOrder(s))
        P["opening"] = Templates.render("skeleton.scene-opening", names, settings: s)
        let gender = genderPiece(char: char, me: me, names: names, settings: s)
        P["gender"] = gender
        P["ident"] = sceneIdentity(char0, char, me0, me, settings: s)
        // 摘要互通，原文不互通：两边的上下文预算各算各的
        if !chat.summary.isEmpty { P["summary"] = "[更早之前发生过什么]\n\(chat.summary)" }
        if !scene.string("summary").isEmpty { P["sceneSummary"] = "[这一场之前发生过什么]\n\(scene.string("summary"))" }
        if !others.isEmpty {
            P["groupNote"] = Templates.render("skeleton.group", ["members": others.map(\.name).joined(separator: "、")], settings: s)
        }
        P["sceneRules"] = Templates.render("skeleton.scene-rules", names, settings: s) + sceneExits(scene, settings: s)
        P["setup"] = sceneSetup(scene, others: others, settings: s)
        // 时刻仍走线上那套协议：模型写 [时间：…]，本地摘下来记在这一段上
        P["time"] = Templates.get("skeleton.time", settings: s)
        let words = max(0, Int(s.num("sceneWords", 0)))
        if words > 0 { P["length"] = Templates.render("skeleton.scene-length", ["words": "\(words)"], settings: s) }
        let style = Templates.fill(Tone.forScene(scene, s), names)
        if !style.isEmpty { P["style"] = Templates.render("skeleton.scene-style", ["text": style], settings: s) }
        let core = char.core.trimmingCharacters(in: .whitespacesAndNewlines)
        if !core.isEmpty { P["core"] = Templates.render("skeleton.core", ["core": core], settings: s) }
        P["ban"] = banPiece(s)
        P["genderTail"] = gender
        let arranged = Layout.arrange("scene", pieces: P, settings: s, names: names)

        let md = Int(s.num("memoryDepth", 1))
        let messages = sceneHistory(scene, chat: chat, char: char0, me: me, list: list, settings: s, volatile: arranged.tail,
                                    recall: md > 0 && !recalled.isEmpty ? recallText(recalled, now: now) : "", more: more, ensemble: false)
        return Built(system: arranged.system, messages: messages, recalled: recalled.map(\.id))
    }

    /// 一次调用写整轮：所有在场角色的卡、记忆、关系都在同一份里，模型按「【名字】」写各人的段落（4.439）
    static func buildSceneEnsemble(scene: Row, chat: Chat, cast cast0: [Character], list: [Row], more: Bool = false,
                                   settings s: AppSettings, now: Date = Date()) throws -> Built {
        guard let lead0 = cast0.first else { throw StoreError(message: "这一场里没有在场的角色") }
        let (me0, personas) = try meOf(chat, s)
        let me = sceneMe(scene, me0)
        let cast = cast0.map { sceneChar(scene, $0) }
        let userName = (me?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "对方"
        let names = ["charName": cast.map(\.name).joined(separator: "、"), "userName": userName]
        let rootId = Repo.rootId(of: me0?.id ?? "", in: personas)
        let budget = sceneBudget(s)
        let scan = sceneScan(list, s)

        // 世界书取各人的并集
        var before: [String] = [], after: [String] = []
        for c in cast0 {
            let l = activateLore(char: c, scanText: scan, budget: budget > 0 ? Int((Double(budget) * 0.4).rounded()) : 0, books: sceneBooks(scene))
            for x in l.before where !before.contains(x) { before.append(x) }
            for x in l.after + l.deep.map(\.1) where !after.contains(x) { after.append(x) }
        }
        var recalledIds: [String] = []
        var members: [String] = []
        for c in cast {
            let one = try memberBlock(c, chat: chat, rootId: rootId, personas: personas, scanText: scan, settings: s, now: now, name: c.name)
            members.append(one.text)
            recalledIds += one.recalled
        }
        let online = try Repo.messages(chatId: chat.id).filter { !$0.isError }
        let blocks: [String: String] = [
            "lorebook": loreBlock(before), "loreAfter": loreBlock(after),
            "user": userBlock(me: me, char: lead0),
            "time": timeBlock(char: lead0, msgs: online, settings: s, now: now),
            "dates": Holidays.block(char: lead0, chat: chat, me: me, settings: s, now: now),
        ].filter { NewFeat.blockOn($0.key, s) }

        var P = Layout.groupPieces(blocks, order: Layout.injectOrder(s))
        P["opening"] = Templates.render("skeleton.scene-ensemble-opening", ["names": names["charName"] ?? "", "userName": userName], settings: s)
        P["members"] = members.joined(separator: "\n\n")
        if !chat.summary.isEmpty { P["summary"] = "[更早之前发生过什么]\n\(chat.summary)" }
        if !scene.string("summary").isEmpty { P["sceneSummary"] = "[这一场之前发生过什么]\n\(scene.string("summary"))" }
        P["sceneRules"] = Templates.render("skeleton.scene-ensemble-rules", names, settings: s) + sceneExits(scene, settings: s)
        P["setup"] = sceneSetup(scene, others: cast, settings: s)
        P["time"] = Templates.get("skeleton.time", settings: s)
        let words = max(0, Int(s.num("sceneWords", 0)))
        if words > 0 { P["length"] = Templates.render("skeleton.scene-length", ["words": "\(words)"], settings: s) }
        let style = Templates.fill(Tone.forScene(scene, s), names)
        if !style.isEmpty { P["style"] = Templates.render("skeleton.scene-style", ["text": style], settings: s) }
        P["ban"] = banPiece(s)
        var gl = cast.compactMap { c -> String? in
            let g = c.row.string("gender").trimmingCharacters(in: .whitespaces)
            return g.isEmpty ? nil : "\(c.name)：\(g)"
        }
        let ug = (me?.row.string("gender") ?? "").trimmingCharacters(in: .whitespaces)
        if !ug.isEmpty { gl.append("\(userName)：\(ug)") }
        if !gl.isEmpty { P["genderTail"] = Templates.render("skeleton.gender", ["lines": gl.joined(separator: "\n")], settings: s) }
        let arranged = Layout.arrange("scene", pieces: P, settings: s, names: names)

        let messages = sceneHistory(scene, chat: chat, char: nil, me: me, list: list, settings: s, volatile: arranged.tail,
                                    recall: "", more: more, ensemble: true)
        return Built(system: arranged.system, messages: messages, recalled: recalledIds)
    }

    /// 线下的历史：我写的是 user；这个角色写的是 assistant；群戏里别人写的是 user，前面带名字。
    /// 一次调用写整轮时各人的段落都是它写的，按它要写出来的样子给：【名字】一行，正文跟在下面
    static func sceneHistory(_ scene: Row, chat: Chat, char: Character?, me: Persona?, list: [Row], settings s: AppSettings,
                             volatile: String, recall: String, more: Bool, ensemble: Bool) -> [AIMessage] {
        // 正文附带译文（4.366）：这一场开了，并且这段会话开着翻译，才出现
        let lang = chat.row.string("translateTo").trimmingCharacters(in: .whitespaces)
        let prose = scene.bool("withTrans") && !lang.isEmpty
            ? Templates.render("skeleton.prose-trans", ["lang": lang, "extra": ""], settings: s) : ""
        let isGroup = scene.strings("castIds").count > 1
        let body = list.filter { $0.string("role") != Scenes.DIRECTOR }
        let n = max(0, Int(s.num("sceneWindow", 0)))
        let scope = n > 0 ? Array(body.suffix(n)) : body
        // 预算按 token 从后往前收
        let budget = sceneBudget(s)
        var kept: [Row] = []
        var used = 0
        for b in scope.reversed() {
            let cost = TokenEstimate.of(b.string("text"))
            if budget > 0 && used + cost > budget && !kept.isEmpty { break }
            used += cost
            kept.insert(b, at: 0)
        }
        // 钉住的那几段不受窗口与预算约束
        let inKept = Set(kept.map(\.id))
        let all = body.filter { $0.bool("pinned") && !inKept.contains($0.id) } + kept

        let charIds = scene.strings("castIds")
        var out: [AIMessage] = all.map { b in
            // 正则替换里「两边都改」「只改发给角色的」那几条（存着的原文不动）
            let text = RegexRules.forPrompt(b.string("text"), .init(who: b.string("role") == Scenes.ME ? "user" : "char",
                                                                     whereIs: "offline", charIds: charIds), settings: s)
            if b.string("role") == Scenes.ME { return AIMessage(role: .user, content: text) }
            let who = (try? Repo.character(b.string("authorId"))) ?? nil
            if ensemble {
                let name = who.map { Scenes.nameIn(scene, $0) } ?? "某人"
                return AIMessage(role: .assistant, content: "【\(name)】\n\(text)")
            }
            if isGroup && b.string("authorId") != char?.id {
                return AIMessage(role: .user, content: "\(who?.name ?? "某人")：\(text)")
            }
            return AIMessage(role: .assistant, content: text)
        }

        let userName = (me?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "对方"
        let dir = directorLines(list)
        let tail = [
            volatile.trimmingCharacters(in: .whitespacesAndNewlines),
            recall,
            dir.isEmpty ? "" : Templates.render("skeleton.scene-director", ["lines": dir.joined(separator: "\n"), "userName": userName], settings: s),
            more ? Templates.get("skeleton.scene-more", settings: s) : "",
            // 贴着输出再说一遍。设定区那一段离这里隔着整场戏
            Templates.render("skeleton.scene-tail", ["userName": userName], settings: s),
            prose,
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        out.append(AIMessage(role: .user, content: tail))

        // 相邻同一侧的并成一条
        var merged: [AIMessage] = []
        for m in out {
            if let last = merged.last, last.role == m.role { merged[merged.count - 1].content += "\n\n" + m.content }
            else { merged.append(m) }
        }
        return merged
    }
}
