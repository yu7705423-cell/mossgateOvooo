import Foundation
import UIKit
import UserNotifications

/// 手机号（网页版 system/phonenum.js，ARCHITECTURE 4.307、4.392）。社交与角色行为规范第三节。
///
/// · 角色与 NPC 各有一个号码（char.phoneNumber），程序生成，用户可以改。第一次用到时生成并存下，不批量改数据。
///   格式按角色卡的时区对应国家，没设时区的生成中国大陆 11 位。
/// · 小号与本体共用本体的号码（ownerOf 认到本体）。
/// · 你的号码挂在身份上（persona.phones），第一个自动生成，可以再加任意多个。
/// · 角色能借的号码只从它关系网里、已经有号码的 NPC 里筛（borrowable），不临时编号码、不临时造人（第 22 条）。
/// · 哪些角色存过你的哪个号码：persona.phoneSaved（{ 号码的数字: [角色 id] }），记的是本体。
enum PhoneNum {
    private static func rnd(_ n: Int) -> String { (0..<max(0, n)).map { _ in String(Int.random(in: 0...9)) }.joined() }
    private static func pick(_ xs: [String]) -> String { xs.randomElement() ?? "" }

    /// 时区对应的当地手机号样子（网页版 FORMATS，同一个顺序）。认不出的时区与没设时区的一样，生成中国大陆的
    private static let formats: [(zones: String, make: () -> String)] = [
        (#"^Asia/(Hong_Kong)$"#, { "\(pick(["5", "6", "9"]))\(rnd(3)) \(rnd(4))" }),
        (#"^Asia/(Macau)$"#, { "6\(rnd(3)) \(rnd(4))" }),
        (#"^Asia/(Taipei)$"#, { "09\(rnd(2))-\(rnd(3))-\(rnd(3))" }),
        (#"^Asia/(Tokyo)$"#, { "\(pick(["090", "080", "070"]))-\(rnd(4))-\(rnd(4))" }),
        (#"^Asia/(Seoul)$"#, { "010-\(rnd(4))-\(rnd(4))" }),
        (#"^Asia/(Singapore)$"#, { "\(pick(["8", "9"]))\(rnd(3)) \(rnd(4))" }),
        (#"^(America/(New_York|Chicago|Denver|Los_Angeles|Phoenix|Anchorage|Detroit|Toronto|Vancouver|Edmonton|Winnipeg|Halifax)|Pacific/Honolulu)$"#,
         { "(\(pick("23456789".map { String($0) }))\(rnd(2))) \(pick("23456789".map { String($0) }))\(rnd(2))-\(rnd(4))" }),
        (#"^Europe/(London)$"#, { "07\(rnd(3)) \(rnd(6))" }),
        (#"^Europe/(Paris)$"#, { "0\(pick(["6", "7"])) \(rnd(2)) \(rnd(2)) \(rnd(2)) \(rnd(2))" }),
        (#"^Europe/(Berlin)$"#, { "01\(pick(["5", "6", "7"]))\(rnd(1)) \(rnd(7))" }),
        (#"^Europe/(Moscow)$"#, { "+7 9\(rnd(2)) \(rnd(3))-\(rnd(2))-\(rnd(2))" }),
        (#"^Australia/"#, { "04\(rnd(2)) \(rnd(3)) \(rnd(3))" }),
    ]

    static func mainland() -> String { "1\(pick(["3", "5", "7", "8", "9"]))\(rnd(1)) \(rnd(4)) \(rnd(4))" }

    static func generate(_ zone: String = "") -> String {
        guard !zone.isEmpty, let f = formats.first(where: { zone.range(of: $0.zones, options: .regularExpression) != nil }) else { return mainland() }
        return f.make()
    }

    /// 只留数字，比较号码用。写法（空格、横线、括号）不同的同一个号码算同一个
    static func digits(_ n: String) -> String {
        var out = String.UnicodeScalarView()
        for u in n.unicodeScalars where u.value >= 48 && u.value <= 57 { out.append(u) }
        return String(out)
    }
    static func same(_ a: String, _ b: String) -> Bool { let x = digits(a); return !x.isEmpty && x == digits(b) }

    // MARK: - 角色与 NPC

    static func root(_ c: Character) -> Character {
        guard let p = c.parentId, !p.isEmpty, let r = (try? Repo.character(p)) ?? nil else { return c }
        return r
    }

    private static func save(_ c: Character, _ fields: [String: JSONValue]) throws {
        var row = c.row
        for (k, v) in fields { row[k] = v }
        row.touch()
        try Database.shared.put(Collections.characters, row)
    }

    /// 这个角色的号码。小号用本体的；没有就生成一个存下（写不进去时在屏幕上说，这一次照样用生成的那个）
    static func numberOf(_ charId: String) -> String {
        guard let c = (try? Repo.character(charId)) ?? nil else { return "" }
        let r = root(c)
        let own = r.row.string("phoneNumber")
        if !own.isEmpty { return own }
        let n = generate(r.row.string("timezone"))
        do { try save(r, ["phoneNumber": .string(n)]) } catch { Problems.report("保存角色号码失败：\(error.localizedDescription)") }
        return n
    }

    static func setNumber(_ charId: String, _ n: String) throws {
        guard let c = try Repo.character(charId) else { return }
        try save(root(c), ["phoneNumber": .string(String(n.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)))])   // 有意截断：号码一栏，与网页版同
    }

    /// 号码是谁的（本体或 NPC）。没有人用这个号码给 nil
    static func ownerOf(_ number: String) -> Character? {
        guard !digits(number).isEmpty else { return nil }
        return ((try? Repo.characters()) ?? []).first { ($0.parentId ?? "").isEmpty && !$0.row.string("phoneNumber").isEmpty && same($0.row.string("phoneNumber"), number) }
    }

    /// 角色能借的号码：关系网里、已经有号码的 NPC
    static func borrowable(_ char: Character) -> [Character] {
        let r = root(char)
        return (r.row["relations"]?.array ?? []).compactMap { $0["charId"]?.string }
            .compactMap { (try? Repo.character($0)) ?? nil }
            .filter { $0.isNpc && !$0.row.string("phoneNumber").isEmpty }
    }

    // MARK: - 你的号码

    static func currentPersonaId() -> String { ((try? Repo.activePersona()) ?? nil)?.id ?? "" }

    private static func persona(_ id: String) -> Persona? { ((try? Repo.personas()) ?? []).first { $0.id == id } }

    /// 这个身份的号码。一个都没有时生成第一个并存下
    static func mine(_ personaId: String = currentPersonaId()) -> [String] {
        guard let p = persona(personaId) else { return [] }
        let list = p.row.strings("phones")
        if !list.isEmpty { return list }
        let first = mainland()
        do { _ = try People.update(p, ["phones": .array([.string(first)])]) } catch { Problems.report("保存号码失败：\(error.localizedDescription)") }
        return [first]
    }

    @discardableResult
    static func addMine(_ n: String = "", _ personaId: String = currentPersonaId()) throws -> String {
        let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = t.isEmpty ? mainland() : t
        let list = mine(personaId)
        if list.contains(where: { same($0, v) }) { throw StoreError(message: "该号码已存在") }
        guard let p = persona(personaId) else { throw StoreError(message: "当前身份不存在") }
        _ = try People.update(p, ["phones": .array((list + [String(v.prefix(30))]).map { .string($0) })])   // 有意截断：号码一栏，与网页版同
        return v
    }

    static func removeMine(_ n: String, _ personaId: String = currentPersonaId()) throws {
        let list = mine(personaId).filter { !same($0, n) }
        if list.isEmpty { throw StoreError(message: "至少保留一个号码") }
        guard let p = persona(personaId) else { return }
        var saved = p.row["phoneSaved"]?.object ?? [:]
        saved[digits(n)] = nil
        _ = try People.update(p, ["phones": .array(list.map { .string($0) }), "phoneSaved": .object(saved)])
    }

    static func isMine(_ n: String, _ personaId: String = currentPersonaId()) -> Bool { mine(personaId).contains { same($0, n) } }

    // MARK: - 哪些角色存过你的哪个号码（4.392）

    private static func rootId(_ charId: String) -> String {
        guard let c = (try? Repo.character(charId)) ?? nil, let p = c.parentId, !p.isEmpty else { return charId }
        return p
    }

    /// 存过这个号码的角色 id（本体）
    static func savedBy(_ n: String, _ personaId: String = currentPersonaId()) -> [String] {
        persona(personaId)?.row["phoneSaved"]?[digits(n)]?.array?.compactMap(\.string) ?? []
    }

    static func isSavedBy(_ n: String, _ charId: String, _ personaId: String = currentPersonaId()) -> Bool {
        !charId.isEmpty && savedBy(n, personaId).contains(rootId(charId))
    }

    static func setSaved(_ n: String, _ charId: String, _ on: Bool, _ personaId: String = currentPersonaId()) throws {
        let key = digits(n)
        guard !key.isEmpty, !charId.isEmpty, let p = persona(personaId) else { return }
        let id = rootId(charId)
        var map = p.row["phoneSaved"]?.object ?? [:]
        var list = (map[key]?.array?.compactMap(\.string) ?? []).filter { $0 != id }
        if on { list.append(id) }
        map[key] = list.isEmpty ? nil : .array(list.map { .string($0) })
        _ = try People.update(p, ["phoneSaved": .object(map)])
    }
}

/// 短信（网页版 system/sms.js，ARCHITECTURE 4.307）。社交与角色行为规范第三到五节。
///
/// 一段短信由两端的号码确定：你的哪个号码（mine）对着哪个号码（theirs）。换一个号码发，就是互不相干的另一段。
/// 另一端由那个号码的主人（角色或 NPC）来回，或者借了 NPC 号码发来的角色（via 记着借的是谁）。
/// 短信不进聊天的会话列表：线程另存一域（smsThreads），消息仍在 messages 里，chatId 是线程 id。
///
/// **身份隔离**：一段短信默认不认为对面是你。提示词只写「一个尚未确认身份的号码」，不注入你的身份资料；
/// 角色认出来时写 [认出：名字]，界面上问一句要不要表明身份；你确认了（或自己点「表明身份」）这一段才按你的身份注入。
/// 角色存过这个号码（4.392）等同于表明过身份。只写状态，不写该怎么反应（第 22 条）。
///
/// **角色只知道和它有过短信往来的号码**。它主动发短信、借号发短信，都只能发给这些号码。
/// **拦截**是号码层面的，记在身份上（persona.smsBlocked）：被拦的号码发来的落进「已拦截」，不提醒；
/// 角色那边记一笔「这个号码发送失败」。
enum Sms {
    static let collection = "smsThreads"

    // MARK: - 线程

    static func get(_ id: String) -> Row? { (try? Database.shared.get(collection, id: id)) ?? nil }

    static func threadsOf(_ personaId: String = PhoneNum.currentPersonaId()) -> [Row] {
        ((try? Database.shared.all(collection)) ?? [])
            .filter { ($0.string("personaId").isEmpty ? personaId : $0.string("personaId")) == personaId }
            .sorted { ($0.number("lastMessageAt") ?? 0) > ($1.number("lastMessageAt") ?? 0) }
    }

    /// 另一端由谁来回
    static func answererOf(_ t: Row) -> Character? {
        let id = t.string("charId")
        return id.isEmpty ? nil : ((try? Repo.character(id)) ?? nil)
    }

    /// 找一段，没有就开一段。theirs 的主人（本体或 NPC）来回
    @discardableResult
    static func open(mine: String, theirs: String, personaId: String = PhoneNum.currentPersonaId(), charId: String = "", via: String = "") throws -> Row {
        if let hit = threadsOf(personaId).first(where: { PhoneNum.same($0.string("mine"), mine) && PhoneNum.same($0.string("theirs"), theirs) }) {
            return hit
        }
        let owner = charId.isEmpty ? (PhoneNum.ownerOf(theirs)?.id ?? "") : charId
        let row = Row.new(prefix: "sms", [
            "personaId": .string(personaId), "mine": .string(mine.trimmingCharacters(in: .whitespacesAndNewlines)),
            "theirs": .string(theirs.trimmingCharacters(in: .whitespacesAndNewlines)),
            "charId": .string(owner), "characterIds": .array(owner.isEmpty ? [] : [.string(owner)]), "via": .string(via),
            "confirmed": .bool(false), "guess": .string(""), "lastMessageAt": .number(Date().millis), "unread": .number(0),
        ])
        try Database.shared.put(collection, row)
        return row
    }

    @discardableResult
    static func update(_ id: String, _ patch: [String: JSONValue]) throws -> Row? {
        guard var row = try Database.shared.get(collection, id: id) else { return nil }
        for (k, v) in patch { row[k] = v }
        row.touch()
        try Database.shared.put(collection, row)
        return row
    }

    static func touch(_ id: String, _ patch: [String: JSONValue] = [:]) throws {
        var p = patch
        p["lastMessageAt"] = .number(Date().millis)
        try update(id, p)
    }

    static func markRead(_ id: String) throws { try update(id, ["unread": .number(0)]) }

    /// 引擎、记忆、解析那一套认「会话」，给它一个会话的样子（不存进 chats）。
    /// 翻译跟随这个角色与这个身份的私聊（网页版 4.364）：短信自己没有翻译设置，同一件事一个开关（第 5 条）
    static func asChat(_ t: Row) -> Chat {
        let charId = t.string("charId")
        let pid = t.string("personaId")
        var f: [String: JSONValue] = [
            "id": .string(t.id), "characterIds": .array(charId.isEmpty ? [] : [.string(charId)]), "personaId": .string(pid),
            "sms": .object(t.fields), "title": .string(""), "summary": .string(t.string("summary")),
            "createdAt": t["createdAt"] ?? .number(0), "lastMessageAt": t["lastMessageAt"] ?? .number(0),
        ]
        for k in ["memoryUpTo", "memoryUpToAt", "memoryTriedId", "memoryTriedAt"] { if let v = t[k] { f[k] = v } }
        if !charId.isEmpty, let own = ((try? Repo.chats()) ?? []).first(where: { !$0.isGroup && $0.characterIds == [charId] && $0.personaId == pid }) {
            for k in ["translateTo", "translateRules"] { if let v = own.row[k] { f[k] = v } }
        }
        return Chat(row: Row(fields: f))
    }

    /// 你发一条
    @discardableResult
    static func send(_ threadId: String, text: String) throws -> Message? {
        guard let t = get(threadId) else { return nil }
        let m = try Repo.append(Message.new(chatId: t.id, role: .user, authorId: "me", content: text))
        try touch(t.id)
        return m
    }

    /// 彩信：图照常存，识图按「设置 - 识图」那一档（ChatEngine.sendImage 同一套）
    @discardableResult
    static func sendImage(_ threadId: String, imageId: String) throws -> Message? {
        guard let t = get(threadId) else { return nil }
        let m = try ChatEngine.sendImage(imageId: imageId, chatId: t.id)
        try touch(t.id)
        return m
    }

    // MARK: - 拦截

    private static func persona(_ id: String) -> Persona? { ((try? Repo.personas()) ?? []).first { $0.id == id } }

    static func blockedOf(_ personaId: String = PhoneNum.currentPersonaId()) -> [String] { persona(personaId)?.row.strings("smsBlocked") ?? [] }
    static func isBlocked(_ n: String, _ personaId: String = PhoneNum.currentPersonaId()) -> Bool { blockedOf(personaId).contains { PhoneNum.same($0, n) } }

    static func setBlocked(_ n: String, _ on: Bool, _ personaId: String = PhoneNum.currentPersonaId()) throws {
        guard let p = persona(personaId) else { return }
        var list = blockedOf(personaId).filter { !PhoneNum.same($0, n) }
        if on { list.append(n.trimmingCharacters(in: .whitespacesAndNewlines)) }
        _ = try People.update(p, ["smsBlocked": .array(list.map { .string($0) })])
    }

    // MARK: - 身份

    /// 角色知不知道这段短信那头是你：表明过身份，或者它存过你的这个号码（4.392）。注入与「认出」那一段一律看这一处
    static func isKnown(_ t: Row) -> Bool {
        t.bool("confirmed") || PhoneNum.isSavedBy(t.string("mine"), t.string("charId"), t.string("personaId"))
    }

    /// [认出：名字]。只在短信里有用：记下猜的是谁，界面上问一句
    static func guess(_ threadId: String, name: String, turnId: String = "") throws {
        guard let t = get(threadId), !isKnown(t) else { return }
        try update(threadId, ["guess": .string(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))),   // 有意截断：提示条里一个名字，与网页版同
                              "guessAt": .number(Date().millis), "guessTurn": .string(turnId)])
    }

    static func confirm(_ threadId: String) throws {
        try update(threadId, ["confirmed": .bool(true), "confirmedAt": .number(Date().millis), "guess": .string("")])
    }

    static func dismissGuess(_ threadId: String) throws { try update(threadId, ["guess": .string("")]) }

    /// 重新生成那一轮：这一轮里发到短信里的那几条（按 fromChat 找）撤回；短信里这一轮「认出」那一句撤回
    static func undoTurn(chatId: String, turnId: String) throws {
        guard !turnId.isEmpty else { return }
        for t in try Database.shared.all(collection) {
            if t.id == chatId && t.string("guessTurn") == turnId { try update(t.id, ["guess": .string(""), "guessTurn": .string("")]) }
            for m in try Repo.messages(chatId: t.id, limit: 60) where m.turnId == turnId && m.row.string("fromChat") == chatId && t.id != chatId {
                try Database.shared.delete(Collections.messages, id: m.id)
            }
        }
    }

    // MARK: - 角色发短信

    struct Known: Equatable {
        var mine: String
        var theirs: String
        var via: String
        var confirmed: Bool
        var threadId: String
    }

    /// 这个角色知道的你的号码：和它（本体、它的小号，以及它借号发过的）有过短信往来的那些
    static func knownNumbers(_ char: Character, personaId: String) -> [Known] {
        let r = PhoneNum.root(char)
        return threadsOf(personaId).filter { t in
            t.string("charId") == r.id && !((try? Database.shared.last(Collections.messages, where: t.id, limit: 1)) ?? []).isEmpty
        }.map { Known(mine: $0.string("mine"), theirs: $0.string("theirs"), via: $0.string("via"), confirmed: isKnown($0), threadId: $0.id) }
    }

    /// [发短信：号码|内容] / [借号发短信：NPC 名字|号码|内容]。和那一轮是同一次请求。
    /// 号码只认它知道的你的号码；借号只认关系网里有号码的 NPC。检查不过就当没写过。
    /// 被拦截：消息落进这一段但标成已拦截（界面上只在「已拦截」里看得见），这一段记一笔失败
    @discardableResult
    static func charSend(char: Character, personaId pid: String, body: String, borrow: String = "", turnId: String = "", fromChat: String = "") throws -> Message? {
        let r = PhoneNum.root(char)
        let personaId = pid.isEmpty ? PhoneNum.currentPersonaId() : pid
        var parts = body.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "|" || $0 == "｜" }).map(String.init)
        let target = (parts.isEmpty ? "" : parts.removeFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = parts.joined(separator: "|").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let mine = knownNumbers(r, personaId: personaId).first(where: { PhoneNum.same($0.mine, target) })?.mine else { return nil }
        var from = PhoneNum.numberOf(r.id)
        var via = ""
        let who = borrow.trimmingCharacters(in: .whitespacesAndNewlines)
        if !who.isEmpty {
            guard let npc = PhoneNum.borrowable(r).first(where: { $0.row.string("name") == who }) else { return nil }
            from = npc.row.string("phoneNumber")
            via = npc.id
        }
        let t = try open(mine: mine, theirs: from, personaId: personaId, charId: r.id, via: via)
        let blocked = isBlocked(from, personaId)
        var m = Message.new(chatId: t.id, role: .char, authorId: r.id, content: text)
        if !turnId.isEmpty { m.row["turnId"] = .string(turnId); m.row["fromChat"] = .string(fromChat) }
        if blocked { m.row["intercepted"] = .bool(true) }
        m = try Repo.append(m)
        if blocked {
            let fails = Array((t["failures"]?.array ?? []).suffix(4)) + [.object(["at": .number(Date().millis)])]
            try update(t.id, ["failures": .array(fails)])
        } else {
            try touch(t.id, ["unread": .number((t.number("unread") ?? 0) + 1)])
            notify(title: t.bool("confirmed") ? r.row.string("name") : from, body: text, threadId: t.id)
        }
        return m
    }

    /// 回复里那三种标记落成状态（网页版 reply.js 的 sms）。都不是这一段的消息，什么都不落
    static func effect(_ p: ReplyParser.Part, chat: Chat, char: Character, turnId: String) throws {
        let s = AppSettings.load()
        let off = Set((s.raw["capsOff"]?.array ?? []).compactMap(\.string))
        // 关掉的能力写了也不执行（网页版 capLive：PART_CAP 里 sms 归 smssend）
        guard !off.contains("smssend") else { return }
        let kind = p.extra ?? ""
        let thread = get(chat.id)
        if kind == "认出" {
            if let thread { try guess(thread.id, name: p.text, turnId: turnId) }
            return
        }
        let personaId = chat.personaId.isEmpty ? (thread?.string("personaId") ?? "") : chat.personaId
        var body = p.text
        var borrow = ""
        if kind == "借号发短信" {
            guard let bar = body.firstIndex(where: { $0 == "|" || $0 == "｜" }) else { return }
            borrow = String(body[..<bar]).trimmingCharacters(in: .whitespacesAndNewlines)
            body = String(body[body.index(after: bar)...])
        }
        try charSend(char: char, personaId: personaId, body: body, borrow: borrow, turnId: turnId, fromChat: chat.id)
    }

    /// 这段短信里正常的那些（被拦截的不在这里）
    static func visible(_ threadId: String) -> [Message] {
        ((try? Repo.messages(chatId: threadId)) ?? []).filter { !$0.row.bool("intercepted") }
    }

    struct Caught: Identifiable {
        var thread: Row
        var msg: Message
        var id: String { msg.id }
    }

    static func intercepted(_ personaId: String = PhoneNum.currentPersonaId()) -> [Caught] {
        threadsOf(personaId).flatMap { t in
            ((try? Repo.messages(chatId: t.id)) ?? []).filter { $0.row.bool("intercepted") }.map { Caught(thread: t, msg: $0) }
        }.sorted { $0.msg.createdAt > $1.msg.createdAt }
    }

    /// 删掉一段：连同里面的消息
    static func remove(_ threadId: String) throws {
        try Database.shared.deleteAll(Collections.messages, where: threadId)
        try Database.shared.delete(collection, id: threadId)
    }

    // MARK: - 提示词里的事实（第 16 条只陈述）

    /// 这个角色和哪些号码有过短信往来、哪几次发送失败。在聊天、短信里都给
    static func factsFor(_ char: Character, personaId: String, userName: String) -> [String] {
        let known = knownNumbers(char, personaId: personaId)
        guard !known.isEmpty else { return [] }
        var lines = ["You have exchanged SMS with these numbers: " + known.map { k in
            "\(k.mine)\(k.confirmed ? " (\(userName))" : " (identity not confirmed)")\(k.via.isEmpty ? "" : " from a borrowed number \(k.theirs)")"
        }.joined(separator: "; ") + "."]
        let rootId = (char.parentId ?? "").isEmpty ? char.id : (char.parentId ?? char.id)
        for t in threadsOf(personaId) where t.string("charId") == rootId && !(t["failures"]?.array ?? []).isEmpty {
            lines.append("Your SMS from \(t.string("theirs")) to \(t.string("mine")) failed to deliver: that number has been blocked by the recipient.")
        }
        return lines
    }

    /// [短信] 区块（网页版 context/sms.js）：自己的号码、和哪些号码有过往来、哪次失败、能借的号码。什么时候发、借不借，一个字不写
    static func block(char: Character, chat: Chat, me: Persona?) -> String {
        let personaId = chat.personaId.isEmpty ? (me?.id ?? "") : chat.personaId
        let n = me?.row.string("name") ?? ""
        var lines = factsFor(char, personaId: personaId, userName: n.isEmpty ? "the user" : n)
        guard !lines.isEmpty else { return "" }
        lines.insert("Your own number: \(PhoneNum.numberOf(char.id)).", at: 0)
        let lend = PhoneNum.borrowable(char)
        // 名字后面带圈子（网页版 4.593，只是状态）：圈子按这个角色自己的关系那一条
        let rels = char.row["relations"]?.array ?? []
        func ring(_ c: Character) -> String {
            (rels.first { $0["charId"]?.string == c.id }?["circle"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !lend.isEmpty {
            lines.append("Numbers of people in your relationships: " + lend.map { c in
                let r = ring(c)
                return "\(c.row.string("name"))\(r.isEmpty ? "" : "（\(r)）") \(c.row.string("phoneNumber"))"
            }.joined(separator: "; ") + ".")
        }
        return "\n\n[短信]\n" + lines.joined(separator: "\n")
    }

    // MARK: - 提醒

    /// 来了一条短信（网页版 notify，appId sms）。开关关着时不弹；点开打开短信
    static func notify(title: String, body: String, threadId: String) {
        Task { @MainActor in NotificationCenter.default.post(name: .eiraChatChanged, object: threadId) }
        let s = AppSettings.load()
        guard Notifier.isOn(s) else { return }
        Task { @MainActor in
            let c = UNMutableNotificationContent()
            c.title = title.isEmpty ? "短信" : title
            let l = Notifier.line(body)
            c.body = Notifier.showsText(s) && !l.isEmpty ? l : "收到一条短信"
            c.sound = .default
            c.userInfo = ["app": "sms"]
            c.threadIdentifier = threadId
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}
