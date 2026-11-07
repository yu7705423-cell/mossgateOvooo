import Foundation

/// 「我们」：一部作品 + 一篇一篇的正文（网页版 system/work.js，ARCHITECTURE 4.117）。
///
/// **正文那一套整个复用线下的**：每一篇的正文就是 beats 里 sceneId 为这一篇 id 的那几行，分段、分版、续写、编辑全走 Scenes。
/// 这边只管「作品是什么」「篇怎么排」。两种体裁，差别只在三个字段上：
///
/// | | 长篇（saga） | 番外（extra） |
/// |---|---|---|
/// | 篇 | 一章一章，有编号 | 一则就是一篇 |
/// | 身份 | 可以整套换掉 | 就是原来那两个人 |
/// | 原来的记忆 | 自己选带不带 | 一直带 |
///
/// 作品不进记忆：番外是「如果当时」，长篇是另一条线。字段与网页版一致，两边导入导出互通（docs/web-fields.md）。
enum Works {
    static let works = "works"
    static let chapters = "chapters"
    static let SAGA = "saga", EXTRA = "extra"

    static let kinds: [(id: String, label: String, desc: String)] = [
        (SAGA, "长篇", "有主线，一章一章往下写。可以换一套身份重新开始"),
        (EXTRA, "番外", "一则小剧场。沿用现在的身份与记忆，不进记忆，不影响主线"),
    ]
    static func kindLabel(_ k: String) -> String { kinds.first { $0.id == k }?.label ?? kinds[1].label }

    // MARK: - 带上原来那段关系时，带哪几样（4.396）

    struct Carry {
        let id: String
        let key: String
        let label: String
        let def: Bool
        let desc: String
    }

    static let carry: [Carry] = [
        Carry(id: "chat", key: "carryChat", label: "携带近期聊天记录", def: false,
              desc: "带上手机上最近的几条消息。关闭后，正文不接手机上刚聊过的话题。"),
        Carry(id: "memory", key: "carryMemory", label: "携带记忆", def: true,
              desc: "带上关系底色、一直记着的与相关的记忆。关闭后，角色不记得聊天里发生过的事。"),
        Carry(id: "other", key: "carryOther", label: "携带其他每轮注入的内容", def: false,
              desc: "带上此刻的时间、日程、天气、身体状况等每轮注入的内容。关闭后，正文不受当下这些状态影响。"),
    ]

    /// 没设过的老作品按默认读
    static func carryOf(_ w: Row) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: carry.map { c in (c.id, w[c.key]?.bool ?? c.def) })
    }

    // MARK: - 作品

    static func get(_ id: String) -> Row? { (try? Database.shared.get(works, id: id)) ?? nil }

    private static func time(_ r: Row) -> Double { r.number("updatedAt") ?? r.created ?? 0 }

    static func all() -> [Row] { ((try? Database.shared.all(works)) ?? []).sorted { time($0) > time($1) } }
    static func ofChat(_ chatId: String) -> [Row] { ((try? Database.shared.all(works, where: chatId)) ?? []).sorted { time($0) > time($1) } }

    struct Draft {
        var chatId = ""
        var kind = EXTRA
        var title = ""
        var castIds: [String] = []
        var premise = ""
        var charAs: (name: String, persona: String)?
        var meAs: (name: String, persona: String)?
        var carry = false
        var solo = false
        var endNext = false
        var carryChat: Bool?
        var carryMemory: Bool?
        var carryOther: Bool?
        var opening = "char"
        var tones: [String] = []
        var toneText = ""
        var genres: [String] = []
        var length: (chapters: Int, perChapter: Int)?
        var inspiration = ""
        var secret = ""
        var outline: JSONValue?
        var lorebookIds: [String] = []
    }

    static func identity(_ v: (name: String, persona: String)?) -> JSONValue {
        .object(["name": .string((v?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
                 "persona": .string((v?.persona ?? "").trimmingCharacters(in: .whitespacesAndNewlines))])
    }

    static func lengthValue(_ v: (chapters: Int, perChapter: Int)?) -> JSONValue {
        guard let v else { return .null }
        return .object(["chapters": .number(Double(max(0, v.chapters))), "perChapter": .number(Double(max(0, v.perChapter)))])
    }

    /// 新建一部。长篇可以不挂会话（4.262），人物直接从联系里选；番外一定挂在会话上。
    /// carry 是「带不带原来的记忆」：番外一律带，长篇由用户定；solo 是「整篇由它写」（第 16 条：两种都写得出来，不替用户定）
    @discardableResult
    static func create(_ d: Draft) throws -> Row {
        let chat = d.chatId.isEmpty ? nil : try Repo.chat(d.chatId)
        let k = d.kind == SAGA ? SAGA : EXTRA
        if k == EXTRA && chat == nil { throw StoreError(message: "番外需要选择一段会话") }
        let cast = d.castIds.isEmpty ? (chat?.characterIds ?? []) : d.castIds.filter { ((try? Repo.character($0)) ?? nil) != nil }
        if cast.isEmpty { throw StoreError(message: "请先选择人物") }
        let tones = d.tones.filter { !$0.isEmpty }
        // 记住这一次挑的文风，下次新建时预填（只是默认值，开关仍在这一部自己身上）
        var s = try AppSettings.loadForWrite()
        s.raw["workToneLast"] = .array(tones.map { .string($0) })
        try s.save()
        var f: [String: JSONValue] = [
            "chatId": .string(chat?.id ?? ""), "kind": .string(k),
            "title": .string(d.title.trimmingCharacters(in: .whitespacesAndNewlines)),
            "castIds": .array(cast.map { .string($0) }),
            "premise": .string(d.premise.trimmingCharacters(in: .whitespacesAndNewlines)),
            "charAs": identity(d.charAs), "meAs": identity(d.meAs),
            // 番外不给这个开关：它就是这段关系的小剧场，不带原来的事就写不出来
            "carry": .bool(k == EXTRA ? true : (chat != nil && d.carry)),
            "solo": .bool(d.solo),
            "opening": .string(d.opening == "me" ? "me" : "char"),
            "tones": .array(tones.map { .string($0) }), "toneText": .string(d.toneText),
            "cover": .null, "state": .string("writing"),
            "genres": .array(d.genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { .string($0) }),
            "length": lengthValue(d.length),
            "inspiration": .string(d.inspiration.trimmingCharacters(in: .whitespacesAndNewlines)),
            "secret": .string(d.secret.trimmingCharacters(in: .whitespacesAndNewlines)),
            "outline": d.outline?.object != nil ? d.outline! : .null,
            "lorebookIds": .array(d.lorebookIds.filter { !$0.isEmpty }.map { .string($0) }),
        ]
        if let v = d.carryChat { f["carryChat"] = .bool(v) }
        if let v = d.carryMemory { f["carryMemory"] = .bool(v) }
        if let v = d.carryOther { f["carryOther"] = .bool(v) }
        // 结尾给出后续走向（反馈 10），默认关
        if d.endNext { f["endNext"] = .bool(true) }
        let row = Row.new(prefix: "wk", f)
        try Database.shared.put(works, row)
        return row
    }

    @discardableResult
    static func update(_ id: String, _ patch: [String: JSONValue]) throws -> Row? {
        guard var row = try Database.shared.get(works, id: id) else { return nil }
        for (k, v) in patch {
            // 番外那个开关不存在，别让改别的字段时顺手把它关掉
            if k == "carry" && row.string("kind") == EXTRA { continue }
            row[k] = v
        }
        row.touch()
        try Database.shared.put(works, row)
        return row
    }

    /// 删一部作品，连着它的篇与每一篇的正文。漏一层就是一堆没人认领的行
    static func remove(_ id: String) throws {
        for c in chaptersOf(id) { try removeChapter(c.id) }
        try Database.shared.delete(works, id: id)
    }

    static func castOf(_ w: Row) -> [Character] { w.strings("castIds").compactMap { (try? Repo.character($0)) ?? nil } }

    /// 这部作品里某一方叫什么、是谁。换过身份就按新的来，没换就是本来那个。头像仍然用本人的：换的是名字与人设，不是脸
    struct Who {
        var id = ""
        var baseName = ""
        var basePersona = ""
        var hasBase = false
        var name = ""
        var persona = ""
        var avatar = ""
        var renamed = false
    }

    static func charOf(_ w: Row) -> Who {
        let base = w.strings("castIds").first.flatMap { (try? Repo.character($0)) ?? nil }
        let asName = (w["charAs"]?["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let asPersona = (w["charAs"]?["persona"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bn = base?.row.string("name") ?? ""
        var out = Who()
        out.id = base?.id ?? ""
        out.hasBase = base != nil
        out.baseName = bn
        out.basePersona = base?.persona ?? ""
        out.name = !asName.isEmpty ? asName : (bn.isEmpty ? "对方" : bn)
        out.persona = !asPersona.isEmpty ? asPersona : out.basePersona
        out.avatar = base?.avatar ?? ""
        out.renamed = !asName.isEmpty
        return out
    }

    /// 这部作品里的「我」：挂着的会话用的那个身份，没有就是当前身份
    static func mePersona(_ w: Row) -> Persona? {
        let ps = (try? Repo.personas()) ?? []
        let pid = ((try? Repo.chat(w.string("chatId"))) ?? nil)?.personaId ?? ""
        return ps.first { $0.id == pid } ?? ((try? Repo.activePersona()) ?? nil)
    }

    static func meOf(_ w: Row) -> Who {
        let base = mePersona(w)
        let asName = (w["meAs"]?["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let asPersona = (w["meAs"]?["persona"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bn = base?.row.string("name") ?? ""
        var out = Who()
        out.id = base?.id ?? ""
        out.hasBase = base != nil
        out.baseName = bn
        out.basePersona = base?.description ?? ""
        out.name = !asName.isEmpty ? asName : (bn.isEmpty ? "我" : bn)
        out.persona = !asPersona.isEmpty ? asPersona : out.basePersona
        out.avatar = base?.avatar ?? ""
        out.renamed = !asName.isEmpty
        return out
    }

    // MARK: - 篇（长篇里叫「章」，番外里叫「则」）

    static func chaptersOf(_ workId: String) -> [Row] {
        let list = (try? Database.shared.all(chapters, where: workId)) ?? []
        return list.sorted { a, b in
            let x = a.number("no") ?? 0, y = b.number("no") ?? 0
            return x != y ? x < y : (a.created ?? 0) < (b.created ?? 0)
        }
    }

    static func getChapter(_ id: String) -> Row? { (try? Database.shared.get(chapters, id: id)) ?? nil }
    static func workOfChapter(_ id: String) -> Row? { getChapter(id).flatMap { get($0.string("workId")) } }

    private static func touchWork(_ id: String) { _ = try? update(id, [:]) }

    static func nextNo(_ workId: String) -> Int { Int(chaptersOf(workId).map { $0.number("no") ?? 0 }.max() ?? 0) + 1 }

    /// plan：章末选定的走向（4.264），写这一章时带进大纲那一块；planFrom 为 end 是上一篇末尾选的（反馈 10），另成一块进提示词
    @discardableResult
    static func addChapter(_ workId: String, title: String = "", place: String = "", at: String = "", note: String = "", plan: String = "",
                           opening: String = "", planFrom: String = "", fromChapterId: String = "") throws -> Row? {
        guard let w = get(workId) else { return nil }
        let open = opening.isEmpty ? w.string("opening") : opening
        var f: [String: JSONValue] = [
            "workId": .string(workId), "no": .number(Double(nextNo(workId))),
            "title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)),
            "place": .string(place.trimmingCharacters(in: .whitespacesAndNewlines)),
            "at": .string(at.trimmingCharacters(in: .whitespacesAndNewlines)),
            "note": .string(note.trimmingCharacters(in: .whitespacesAndNewlines)),
            "opening": .string(open == "me" ? "me" : "char"),
            "plan": .string(plan.trimmingCharacters(in: .whitespacesAndNewlines)),
            "summary": .string(""), "endedAt": .number(0), "stage": .null,
        ]
        if planFrom == "end" { f["planFrom"] = .string("end"); f["fromChapterId"] = .string(fromChapterId) }
        let row = Row.new(prefix: "cp", f)
        try Database.shared.put(chapters, row)
        touchWork(workId)
        return row
    }

    @discardableResult
    static func updateChapter(_ id: String, _ patch: [String: JSONValue]) throws -> Row? {
        guard var row = try Database.shared.get(chapters, id: id) else { return nil }
        for (k, v) in patch { row[k] = v }
        row.touch()
        try Database.shared.put(chapters, row)
        touchWork(row.string("workId"))
        return row
    }

    static func removeChapter(_ id: String) throws {
        guard let row = getChapter(id) else { return }
        try Database.shared.deleteAll(Scenes.beats, where: id)
        try Database.shared.delete(chapters, id: id)
        touchWork(row.string("workId"))
    }

    /// 往前挪一章或往后挪一章。编号跟着换，正文不动
    @discardableResult
    static func moveChapter(_ id: String, _ dir: Int) throws -> Bool {
        guard let row = getChapter(id) else { return false }
        let list = chaptersOf(row.string("workId"))
        guard let at = list.firstIndex(where: { $0.id == id }) else { return false }
        let to = at + (dir < 0 ? -1 : 1)
        guard to >= 0, to < list.count else { return false }
        let other = list[to]
        try updateChapter(row.id, ["no": other["no"] ?? .number(Double(to + 1))])
        try updateChapter(other.id, ["no": row["no"] ?? .number(Double(at + 1))])
        return true
    }

    // MARK: - 结尾的后续选项（反馈 10）

    private static let nextMark = try! NSRegularExpression(pattern: #"^[ \t]*[\[【]\s*后续\s*[:：]\s*([^\]】\n]*?)\s*[\]】][ \t]*$"#, options: [.anchorsMatchLines])

    /// 摘掉结尾的后续选项。按出现顺序取前三个当 A、B、C；没有标记原样返回
    static func takeNext(_ text: String) -> (text: String, items: [String]) {
        let ns = text as NSString
        let all = nextMark.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !all.isEmpty else { return (text, []) }
        var items: [String] = []
        for m in all {
            let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { items.append(t) }
        }
        var out = nextMark.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        out = out.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out, Array(items.prefix(3)))   // 有意截断：界面只有 A、B、C 三格
    }

    /// 流式时画在页面上的那部分：从第一个后续标记起不画
    static func cutNext(_ t: String) -> String {
        guard let r = t.range(of: #"[\[【]\s*后续\s*[:：]"#, options: .regularExpression) else { return t }
        return String(t[..<r.lowerBound])
    }

    /// 这一篇末尾此刻该不该给选项：开着、是本部最后一篇、选项来自最后一段的当前版本、还没选过
    static func nextOf(_ w: Row, _ ch: Row, lastBeat: Row?) -> [String]? {
        guard w.bool("endNext"), let e = ch["endNext"]?.object, let last = lastBeat else { return nil }
        let items = (e["items"]?.array ?? []).compactMap(\.string)
        guard !items.isEmpty, (e["picked"]?.string ?? "").isEmpty else { return nil }
        guard e["beatId"]?.string == last.id, Int(last.number("swipeIndex") ?? 0) == Int(e["ver"]?.number ?? 0) else { return nil }
        guard chaptersOf(w.id).last?.id == ch.id else { return nil }
        return items
    }

    // MARK: - 写到哪儿了

    /// 这一篇写到哪儿了。摘要有就用摘要，没有就截正文的末尾（不调接口）。chars 为 0 表示全文
    static func digestOf(_ chapterId: String, chars: Int = 400) -> String {
        guard let row = getChapter(chapterId) else { return "" }
        if !row.string("summary").isEmpty { return row.string("summary") }
        let list = Scenes.beatsOf(chapterId).filter { $0.string("role") != Scenes.DIRECTOR && !$0.string("text").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let t = (list.last?.string("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let n = max(0, chars)
        guard !t.isEmpty, n > 0 else { return t }
        return t.count <= n ? t : "…" + String(t.suffix(n))   // 有意截断：读的人设的「每章摘录多少字」，0 为全文
    }

    /// 这一篇现在几点。最后一段写了时刻就用它，没有就退回这一篇填的那个
    static func timeOf(_ chapterId: String) -> String {
        for b in Scenes.beatsOf(chapterId).reversed() where !b.string("at").isEmpty { return b.string("at") }
        return getChapter(chapterId)?.string("at") ?? ""
    }

    /// 一段的署名：名字按这部作品里的身份来
    static func signOf(_ beat: Row, chapter: Row, work w: Row) -> Scenes.Sign {
        let mine = beat.string("role") == Scenes.ME
        let who = mine ? meOf(w) : charOf(w)
        var out = Scenes.Sign()
        out.mine = mine
        out.place = beat.string("place").isEmpty ? chapter.string("place") : beat.string("place")
        out.time = beat.string("at")
        out.name = who.name
        out.face = who.avatar
        return out
    }

    /// 几篇、多少字。列表上要摆出来
    static func statsOf(_ workId: String) -> (chapters: Int, chars: Int) {
        let list = chaptersOf(workId)
        var chars = 0
        for c in list {
            for b in Scenes.beatsOf(c.id) where b.string("role") != Scenes.DIRECTOR { chars += b.string("text").count }
        }
        return (list.count, chars)
    }

    /// 一篇在列表上写几个字。长篇按章编号，番外按题目
    static func chapterTitle(_ w: Row, _ c: Row) -> String {
        let no = Int(c.number("no") ?? 0)
        let t = c.string("title")
        if w.string("kind") == SAGA { return "第 \(no) 章" + (t.isEmpty ? "" : "　\(t)") }
        return t.isEmpty ? "第 \(no) 则" : t
    }

    // MARK: - 外观（网页版 stage.forWork，4.1048）：全局、这一部、这一篇一层层盖上去

    static func stageOf(_ w: Row?, _ ch: Row?, _ s: AppSettings = .load()) -> [String: JSONValue] {
        var out = Stage.config(s)
        for (k, v) in w?["stage"]?.object ?? [:] { out[k] = v }
        for (k, v) in ch?["stage"]?.object ?? [:] { out[k] = v }
        return out
    }

    // MARK: - 让角色开场（4.834）

    /// 新建那一篇选了「让角色开场」就直接写第一段。每一篇只自动开场一次，**写之前**记在这一篇上（openedAt）：
    /// 进别的页再返回、这一页重新打开，不再写一遍；失败也算开过。更新之前建的、没有这个记号的，只认刚建好一分钟之内的
    static func claimOpening(_ chapterId: String, now: Date = Date()) -> Bool {
        guard let row = getChapter(chapterId), row.string("opening") != "me" else { return false }
        guard Scenes.beatsOf(chapterId).isEmpty else { return false }
        guard (row.number("openedAt") ?? 0) == 0, now.millis - (row.created ?? 0) <= 60_000 else { return false }
        do { try updateChapter(chapterId, ["openedAt": .number(now.millis)]) } catch {
            Problems.report("记下开场失败，这一次不自动开场：\(error.localizedDescription)")
            return false
        }
        return true
    }
}
