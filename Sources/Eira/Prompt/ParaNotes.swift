import Foundation

/// 段评（网页版 system/paracomment.js 与 ai/tasks/para-comment.js）。书里每一段旁边一个小气泡，影片里每一句台词旁边一个。
///
/// 评论挂在作品上，不挂在会话上。锚点是「哪部作品 + 哪个位置」：书是这一段在全书正文里的字符起点，影片是这一句台词的开始秒数。
/// 两种坐标不通用，所以 subject 带着类型：`book:xxx` / `video:xxx`。早先只有书的那批记录只写了 bookId，读的时候补上。
/// 生成都是按一下调一次：一个角色评一次、多人共读默认一次写全部（crowdSeparate 开了一人一次）、随机评论一次一批。
enum ParaNotes {
    static let collection = "readnotes"
    static let charKind = "char", readerKind = "reader", meKind = "me"

    enum Kind: String, Sendable { case book, video }

    struct Note: Identifiable, Equatable, Sendable {
        var row: Row
        var id: String { row.id }
        var subject: String { ParaNotes.rowSubject(row) }
        var at: Int { Int(row.number("at") ?? -1) }
        var kind: String { row.string("kind") }
        var authorId: String { row.string("authorId") }
        var authorName: String { row.string("authorName") }
        var text: String { row.string("text") }
        var textTrans: String { row.string("textTrans") }
        var createdAt: Double { row.created ?? 0 }
    }

    static func subject(_ kind: Kind, _ id: String) -> String { "\(kind.rawValue):\(id)" }

    static func rowSubject(_ r: Row) -> String {
        let s = r.string("subject")
        if !s.isEmpty { return s }
        let b = r.string("bookId")
        return b.isEmpty ? "" : "book:\(b)"
    }

    static func parse(_ subject: String) -> (kind: Kind, id: String) {
        guard let i = subject.firstIndex(of: ":") else { return (.book, subject) }
        return (Kind(rawValue: String(subject[..<i])) ?? .book, String(subject[subject.index(after: i)...]))
    }

    static func all() -> [Note] { ((try? Database.shared.all(collection)) ?? []).map(Note.init(row:)) }

    /// 这个位置上的评论，早的在前
    static func list(_ subject: String, at: Int) -> [Note] {
        all().filter { $0.subject == subject && $0.at == at && !$0.text.isEmpty }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 这一段区间里每个位置各有几条（气泡上的数字）
    static func counts(_ subject: String, from: Int, span: Int) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for n in all() where n.subject == subject && !n.text.isEmpty && n.at >= from && n.at < from + span { out[n.at, default: 0] += 1 }
        return out
    }

    static func count(_ subject: String) -> Int { all().filter { $0.subject == subject && !$0.text.isEmpty }.count }

    struct Draft: Equatable {
        var authorId: String
        var authorName: String
        var kind: String
        var text: String
        var textTrans: String = ""
    }

    @discardableResult
    static func add(_ subject: String, at: Int, _ d: Draft) throws -> Note {
        let body = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw StoreError(message: "评论是空的") }
        let p = parse(subject)
        var f: [String: JSONValue] = [
            "subject": .string(subject), "at": .number(Double(max(0, at))), "kind": .string(d.kind),
            "authorId": .string(d.authorId), "text": .string(body),
        ]
        // 书那一路仍然写 bookId：删书时按它清，早先的记录也按它认
        f[p.kind == .book ? "bookId" : "videoId"] = .string(p.id)
        var name = d.authorName
        if name.isEmpty, !d.authorId.isEmpty { name = ((try? Repo.character(d.authorId)) ?? nil)?.name ?? "" }
        f["authorName"] = .string(name)
        let tr = d.textTrans.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tr.isEmpty { f["textTrans"] = .string(tr) }
        let row = Row.new(prefix: "rn", f)
        try Database.shared.put(collection, row)
        return Note(row: row)
    }

    static func keep(_ subject: String, at: Int, _ rows: [Draft]) throws {
        for r in rows { try add(subject, at: at, r) }
    }

    static func remove(_ id: String) throws { try Database.shared.delete(collection, id: id) }

    static func clear(_ subject: String, at: Int) throws {
        for n in list(subject, at: at) { try Database.shared.delete(collection, id: n.id) }
    }

    /// 作品没了，它身上的段评一起清掉
    static func dropSubject(_ subject: String) throws {
        for n in all() where n.subject == subject { try Database.shared.delete(collection, id: n.id) }
    }

    // MARK: - 共读名单（存在作品上）

    private static func workCollection(_ subject: String) -> (String, String) {
        let p = parse(subject)
        return (p.kind == .video ? VideoLib.collection : Books.collection, p.id)
    }

    static func crew(_ subject: String) -> [Character] {
        let (c, id) = workCollection(subject)
        let ids = ((try? Database.shared.get(c, id: id)) ?? nil)?.strings("crew") ?? []
        return ids.compactMap { ((try? Repo.character($0)) ?? nil) }
    }

    static func setCrew(_ subject: String, _ ids: [String]) throws {
        let (c, id) = workCollection(subject)
        guard var row = try Database.shared.get(c, id: id) else { return }
        var seen = Set<String>()
        row["crew"] = .array(ids.filter { seen.insert($0).inserted }.map { .string($0) })
        row.touch()
        try Database.shared.put(c, row)
    }

    /// 能进名单的：正经角色，不含 NPC 与小号
    static func candidates() -> [Character] {
        ((try? Repo.characters()) ?? []).filter { !$0.isNpc && ($0.parentId ?? "").isEmpty }
    }

    // MARK: - 生成

    static func persona(_ c: Character) -> String {
        let t = [c.persona, c.signature].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return t.isEmpty ? "（角色卡里还没有写人设）" : t
    }

    /// 要评的那一处：书是那一整段正文；影片是那一句台词连同前面几句
    static func passage(_ subject: String, at: Int) throws -> (title: String, body: String) {
        let p = parse(subject)
        if p.kind == .video {
            guard let v = VideoLib.get(p.id) else { throw StoreError(message: "这部影片已经不在了") }
            let body = Subtitle.recentLines(VideoLib.lines(v), Double(at), 5).map(\.text).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { throw StoreError(message: "这一处没有台词") }
            return (v.title, body)
        }
        guard let b = Books.get(p.id) else { throw StoreError(message: "这本书已经不在了") }
        let body = Books.paragraphAt(Books.text(p.id), at)
        guard !body.isEmpty else { throw StoreError(message: "这一段没有内容") }
        return (b.title, body)
    }

    /// 一个角色评这一段。一次调用。译文跟随这个角色私聊的翻译，同一次调用（网页版 4.365）
    static func one(_ subject: String, at: Int, charId: String) async throws -> [Draft] {
        guard let char = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        let (title, body) = try passage(subject, at: at)
        let s = AppSettings.load()
        let tr = GenTrans.forChar(charId)
        let system = Templates.render("task.para-one", [
            "charName": char.name, "title": title, "charPersona": persona(char), "passage": body,
        ], settings: s) + textPart(tr, s)
        let r = try await AIService.shared.send(task: "para.one", system: system,
                                                messages: [AIMessage(role: .user, content: "Write it now.")], maxTokens: 300)
        let (text, trans) = splitText(tr, ReplyParser.stripThink(r.text).0)
        guard !text.isEmpty else { throw StoreError(message: "模型没有写出内容") }
        return [Draft(authorId: charId, authorName: char.name, kind: charKind, text: text, textTrans: trans)]
    }

    static func separate(_ s: AppSettings = .load()) -> Bool { s.raw["crowdSeparate"]?.bool == true }

    /// 一次调用几次请求：一人一次是名单人数，合写是 1 次
    static func callsForCrew(_ n: Int, _ s: AppSettings = .load()) -> Int { separate(s) ? max(1, n) : 1 }

    static func crewComments(_ subject: String, at: Int, charIds: [String]) async throws -> [Draft] {
        let list = charIds.compactMap { ((try? Repo.character($0)) ?? nil) }
        guard !list.isEmpty else { throw StoreError(message: "共读名单是空的") }
        if separate() {
            var out: [Draft] = []
            for c in list { out += try await one(subject, at: at, charId: c.id) }
            return out
        }
        let (title, body) = try passage(subject, at: at)
        let s = AppSettings.load()
        // 几个人合写一次时，按第一个开着翻译的成员那段私聊的设置译
        let tr = list.lazy.compactMap { GenTrans.forChar($0.id) }.first
        let system = Templates.render("task.para-crew", [
            "title": title, "passage": body,
            "crew": list.map { "- \($0.name)：\(persona($0))" }.joined(separator: "\n"),
        ], settings: s) + GenTrans.fieldsPart(tr, ["text"], settings: s)
        let r = try await AIService.shared.send(task: "para.crew", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: 300 + list.count * 200)
        guard let j = JSONReply.parse(r.text) else { throw StoreError(message: JSONReply.failure(r.text)) }
        var byName: [String: Character] = [:]
        for c in list { byName[c.name.trimmingCharacters(in: .whitespaces)] = c }
        return (j["comments"]?.array ?? []).compactMap { x in
            let name = (x["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (x["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let c = byName[name] else { return nil }
            return Draft(authorId: c.id, authorName: name, kind: charKind, text: text, textTrans: GenTrans.pick(tr, x, "text"))
        }
    }

    static func crowdCount(_ s: AppSettings = .load()) -> Int {
        let v = s.raw["crowdCount"]?.number ?? 6
        return v.isFinite && v > 0 ? Int(v.rounded()) : 6
    }

    /// 随机评论：临时编一批读者，不入联系人，只留名字和这一条。一次调用一批
    static func readers(_ subject: String, at: Int, count: Int? = nil) async throws -> [Draft] {
        let n = max(1, count ?? crowdCount())
        let (title, body) = try passage(subject, at: at)
        let system = Templates.render("task.para-readers", ["title": title, "passage": body, "count": "\(n)"], settings: .load())
        let r = try await AIService.shared.send(task: "para.readers", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: 250 + n * 130)
        guard let j = JSONReply.parse(r.text) else { throw StoreError(message: JSONReply.failure(r.text)) }
        var seen = Set<String>()
        return (j["comments"]?.array ?? []).compactMap { x in
            let name = (x["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (x["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !name.isEmpty, seen.insert(name).inserted else { return nil }
            return Draft(authorId: "", authorName: name, kind: readerKind, text: text)
        }
    }

    // MARK: - 纯文字任务的译文（网页版 translate.textPart / splitText）

    static func textPart(_ t: GenTrans.Target?, _ s: AppSettings) -> String {
        guard let t else { return "" }
        return "\n\n" + Templates.render("task.text-trans", ["lang": t.lang, "extra": t.extra.isEmpty ? "" : "\nAdditional requirements: \(t.extra)"], settings: s)
    }

    private static let tail = Subtitle.rx(#"\n?\s*[\[【]\s*(?:译文|翻译)\s*[:：]\s*([\s\S]*?)\s*[\]】]\s*$"#)

    static func splitText(_ t: GenTrans.Target?, _ raw: String) -> (text: String, trans: String) {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = body as NSString
        guard let m = tail.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else { return (body, "") }
        let text = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        let tr = ns.substring(with: m.range(at: 1))
        guard let t, !TranslateOne.alreadyIn(text, t.lang) else { return (text, "") }
        return (text, GenTrans.usable(tr, text))
    }
}

/// 让一个角色先往前读（网页版 system/readahead.js 与 ai/tasks/readahead.js）。
///
/// 你选「从这里起注入 N 字」，把那一段交给它读一遍；它自己挑哪几段值得开口，留下段评。一次注入一次调用，字数不设上限。
/// 一本书同时只有一个先读的角色。自动续读两道闸：先在弹窗里选「一直继续」（默认每次都问），且续读次数有上限；
/// 登记在 ExtraCalls 的 readAheadAuto。自动续读失败一次就停下，改回每次先问。
enum ReadAhead {
    static let defaultChars = 6000
    static let defaultRuns = 3

    /// 一次注入多少字。0 表示一直读到书末
    static func chars(_ s: AppSettings = .load()) -> Int {
        let v = s.raw["injectChars"]?.number ?? Double(defaultChars)
        return v.isFinite && v >= 0 ? Int(v.rounded()) : defaultChars
    }

    /// 最多自动续几次。0 表示不自动续
    static func maxRuns(_ s: AppSettings = .load()) -> Int {
        let v = s.raw["injectMaxRuns"]?.number ?? Double(defaultRuns)
        return v.isFinite && v >= 0 ? Int(v.rounded()) : defaultRuns
    }

    struct State: Equatable {
        var charId: String
        var char: Character
        var at: Int
        var runs: Int
        var always: Bool
    }

    static func state(_ bookId: String) -> State? {
        guard let r = Books.get(bookId)?.row["readAhead"], let cid = r["charId"]?.string, !cid.isEmpty,
              let char = (try? Repo.character(cid)) ?? nil else { return nil }
        return State(charId: cid, char: char, at: max(0, Int(r["at"]?.number ?? 0)), runs: max(0, Int(r["runs"]?.number ?? 0)),
                     always: r["always"]?.bool == true)
    }

    private static func write(_ bookId: String, _ patch: [String: JSONValue]?) throws {
        guard var row = try Database.shared.get(Books.collection, id: bookId) else { return }
        if let patch {
            var cur = row["readAhead"]?.object ?? [:]
            for (k, v) in patch { cur[k] = v }
            row["readAhead"] = .object(cur)
        } else {
            row["readAhead"] = .null
        }
        row.touch()
        try Database.shared.put(Books.collection, row)
    }

    /// 换一个角色先读，或者头一次开始。读到哪儿从当前位置算起
    static func begin(_ bookId: String, charId: String, from: Int) throws {
        try write(bookId, ["charId": .string(charId), "at": .number(Double(max(0, from))), "runs": .number(0), "always": .bool(false)])
    }

    /// 又读完一段。手动那次不计进自动次数
    static func advance(_ bookId: String, to: Int, auto: Bool) throws {
        let runs = Int(Books.get(bookId)?.row["readAhead"]?["runs"]?.number ?? 0)
        try write(bookId, ["at": .number(Double(max(0, to))), "runs": .number(Double(auto ? runs + 1 : 0))])
    }

    static func setAlways(_ bookId: String, _ v: Bool) throws { try write(bookId, ["always": .bool(v)]) }
    static func stop(_ bookId: String) throws { try write(bookId, nil) }

    /// 你有没有追上它。追上了才该弹那个窗
    static func caughtUp(_ bookId: String, youAt: Int, span: Int) -> Bool {
        guard let s = state(bookId) else { return false }
        return youAt + span >= s.at
    }

    /// 还能不能自动续。选了「一直继续」也仍然受次数上限约束
    static func canAuto(_ bookId: String, _ st: AppSettings = .load()) -> Bool {
        guard let s = state(bookId), s.always else { return false }
        let cap = maxRuns(st)
        return cap > 0 && s.runs < cap
    }

    static func hitCap(_ bookId: String, _ st: AppSettings = .load()) -> Bool {
        guard let s = state(bookId) else { return false }
        return s.always && s.runs >= maxRuns(st)
    }

    struct Result: Equatable {
        var added: Int
        var read: Int
        var to: Int
        var done: Bool
    }

    /// 先读的那个角色接着往下读一段（你追上它之后：问过之后点的，或选了「一直继续」自动读的）。
    /// 自动续读失败一次就停下，改回每次先问：不停的话来回翻页时又会自动再读一次，失败一次扣一次（网页版 ReadAheadWatch）
    @discardableResult
    static func step(_ bookId: String, auto: Bool) async throws -> Result {
        guard let s = state(bookId) else { throw StoreError(message: "没有正在先读的角色") }
        do {
            let r = try await run(bookId: bookId, charId: s.charId, from: s.at)
            try advance(bookId, to: r.to, auto: auto)
            return r
        } catch {
            if auto { try? setAlways(bookId, false) }
            throw error
        }
    }

    /// 读一段，挑出的段落落成段评（作者是这个角色）。一次调用
    static func run(bookId: String, charId: String, from: Int, want: Int? = nil) async throws -> Result {
        guard let row = Books.get(bookId) else { throw StoreError(message: "这本书已经不在了") }
        guard let char = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        let text = Books.text(bookId)
        let start = max(0, min(text.length, from))
        guard start < text.length else { throw StoreError(message: "后面没有内容了") }
        let w = want ?? chars()
        let to = w > 0 ? min(text.length, start + w) : text.length
        let list = Books.paragraphs(text, from: start, span: to - start)
        guard !list.isEmpty else { throw StoreError(message: "这一段没有正文") }
        let s = AppSettings.load()
        let tr = GenTrans.forChar(charId)
        let system = Templates.render("task.read-ahead", [
            "charName": char.name, "title": row.title, "charPersona": ParaNotes.persona(char),
            "paragraphs": list.enumerated().map { "[\($0.offset + 1)] \($0.element.text)" }.joined(separator: "\n\n"),
        ], settings: s) + GenTrans.fieldsPart(tr, ["text"], settings: s)
        let r = try await AIService.shared.send(task: "read.ahead", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: 400 + min(list.count, 60) * 90)
        guard let j = JSONReply.parse(r.text) else { throw StoreError(message: JSONReply.failure(r.text)) }
        var seen = Set<Int>()
        var added = 0
        let subject = ParaNotes.subject(.book, bookId)
        for n in j["notes"]?.array ?? [] {
            let i = Int((n["para"]?.number ?? Double(n["para"]?.string ?? "") ?? 0).rounded())
            let t = (n["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, i >= 1, i <= list.count, seen.insert(i).inserted else { continue }
            try ParaNotes.add(subject, at: list[i - 1].at,
                              .init(authorId: charId, authorName: char.name, kind: ParaNotes.charKind, text: t, textTrans: GenTrans.pick(tr, n, "text")))
            added += 1
        }
        return Result(added: added, read: to - start, to: to, done: to >= text.length)
    }
}
