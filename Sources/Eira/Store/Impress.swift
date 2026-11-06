import Foundation

/// 角色眼中的你（网页版 system/impress.js，ARCHITECTURE 4.346、4.347）。
///
/// - 每条印象都有依据，依据只能是你自己发的消息（整理时按编号引用、本机核对）。角色自己的回复不算。
/// - 强度只数日子：有依据的不同日子有几天。
/// - 相反表现也记，附原话。
/// - 按「角色 × 账号」分开。
///
/// 数据域 impressions（按 charId 查），kind 分四种：imp 一条印象、note 零散的依据、draft 整理结果、mark 整理到哪儿了；
/// 另有 kind groups（charId 为空串）：「几位都注意到的」对照结果，按账号一份。
/// 删掉的印象不真删，state 记成 dropped：下次整理时交给模型当「用户说过不准」。
enum Impress {
    static let collection = "impressions"
    private static var db: Database { .shared }

    // MARK: - 设置

    /// 有依据的日子到几天算「多次观察后形成」「已经非常确定」（settings.impressSeen / impressSure）
    static func thresholds(_ s: AppSettings = .load()) -> (seen: Int, sure: Int) {
        let seen = max(2, Int((s.raw["impressSeen"]?.number ?? 2).rounded()))
        let sure = max(seen + 1, Int((s.raw["impressSure"]?.number ?? 5).rounded()))
        return (seen, sure)
    }

    /// 整理时最多读最近多少条消息。默认值不是上限，0 为全部（网页版第 13 条）
    static func linesCap(_ s: AppSettings = .load()) -> Int {
        max(0, Int((s.raw["impressLines"]?.number ?? 400).rounded()))
    }

    // MARK: - 读

    static func pid(_ personaId: String) -> String {
        personaId.isEmpty ? ((try? Repo.activePersona())?.id ?? "") : personaId
    }

    static func rows(_ charId: String, _ personaId: String, kind: String) -> [Row] {
        let p = pid(personaId)
        return ((try? db.all(collection, where: charId)) ?? [])
            .filter { $0.string("kind") == kind && $0.string("personaId") == p }
            .sorted { ($0.created ?? 0) < ($1.created ?? 0) }
    }

    /// 一条依据：{ msgId, chatId, at, day, quote }
    static func evidence(_ v: JSONValue?) -> [[String: JSONValue]] { (v?.array ?? []).compactMap(\.object) }

    /// 有依据的不同日子
    static func days(_ r: Row) -> [String] { days(evidence(r["evidence"])) }
    static func days(_ ev: [[String: JSONValue]]) -> [String] {
        Array(Set(ev.compactMap { $0["day"]?.string }.filter { !$0.isEmpty })).sorted()
    }

    struct Level: Equatable { let id: String; let label: String; let short: String; var days: Int }
    static let levels: [Level] = [
        .init(id: "sure", label: "已经非常确定", short: "非常确定", days: 0),
        .init(id: "seen", label: "多次观察后形成", short: "多次观察", days: 0),
        .init(id: "first", label: "初步印象", short: "初步", days: 0),
    ]

    static func level(days n: Int, _ s: AppSettings = .load()) -> Level {
        let t = thresholds(s)
        let id = n >= t.sure ? "sure" : n >= t.seen ? "seen" : "first"
        var l = levels.first { $0.id == id }!
        l.days = n
        return l
    }
    static func level(_ r: Row) -> Level { level(days: days(r).count) }

    private static func lastAt(_ r: Row) -> Double {
        (evidence(r["evidence"]) + evidence(r["against"])).reduce(0) { max($0, $1["at"]?.number ?? 0) }
    }

    /// 收下的印象。强的在前，同一档里最近印证过的在前
    static func list(_ charId: String, _ personaId: String) -> [Row] {
        let rank = ["sure": 0, "seen": 1, "first": 2]
        let s = AppSettings.load()
        return rows(charId, personaId, kind: "imp").filter { $0.string("state") != "dropped" }.sorted { a, b in
            let ra = rank[level(days: days(a).count, s).id] ?? 2, rb = rank[level(days: days(b).count, s).id] ?? 2
            return ra != rb ? ra < rb : lastAt(a) > lastAt(b)
        }
    }

    static func dropped(_ charId: String, _ personaId: String) -> [Row] {
        rows(charId, personaId, kind: "imp").filter { $0.string("state") == "dropped" }
    }
    static func notes(_ charId: String, _ personaId: String) -> [Row] {
        rows(charId, personaId, kind: "note").filter { ($0.number("usedAt") ?? 0) == 0 }
    }
    static func draft(_ charId: String, _ personaId: String) -> Row? { rows(charId, personaId, kind: "draft").first }
    static func mark(_ charId: String, _ personaId: String) -> Row? { rows(charId, personaId, kind: "mark").first }
    static func newCount(_ charId: String, _ personaId: String) -> Int {
        list(charId, personaId).filter { ($0.number("seenAt") ?? 0) == 0 }.count
    }
    static func get(_ id: String) -> Row? { (try? db.get(collection, id: id)) ?? nil }

    static func markSeen(_ charId: String, _ personaId: String) throws {
        let now = Date().millis
        for var r in list(charId, personaId) where (r.number("seenAt") ?? 0) == 0 {
            r["seenAt"] = .number(now)
            r.touch()
            try db.put(collection, r)
        }
    }

    // MARK: - 消息

    /// 这个角色与这个账号之间的一对一会话（群里的话不是只对它说的）
    static func chats(_ charId: String, _ personaId: String) -> [Chat] {
        let p = pid(personaId)
        return ((try? Repo.chats()) ?? []).filter {
            !$0.row.bool("group") && $0.characterIds == [charId] && pid($0.personaId) == p
        }
    }

    private static func said(_ m: Message) -> Bool {
        !m.isError && m.kind != "side" && m.kind != "notice" && !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 上次整理之后的消息（双方的都要），按时间排；超过 linesCap 取最后那一截
    static func linesSince(_ charId: String, _ personaId: String, _ s: AppSettings = .load()) -> [Message] {
        let upTo = mark(charId, personaId)?.number("upTo") ?? 0
        let all = chats(charId, personaId).flatMap { (try? Repo.messages(chatId: $0.id)) ?? [] }
            .filter { said($0) && $0.createdAt > upTo }
            .sorted { $0.createdAt < $1.createdAt }
        let cap = linesCap(s)
        return cap > 0 && all.count > cap ? Array(all.suffix(cap)) : all
    }

    static func sinceCount(_ charId: String, _ personaId: String) -> Int {
        let upTo = mark(charId, personaId)?.number("upTo") ?? 0
        return chats(charId, personaId).reduce(0) { n, c in
            n + ((try? Repo.messages(chatId: c.id)) ?? []).filter { said($0) && $0.createdAt > upTo }.count
        }
    }

    /// 一条消息落成一条依据
    static func evidenceOf(_ m: Message, quote: String = "") -> [String: JSONValue] {
        let text = (quote.isEmpty ? m.content : quote).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let at = m.createdAt
        return [
            "msgId": .string(m.id), "chatId": .string(m.chatId), "at": .number(at),
            "day": .string(Health.dateKey(Date(millis: at > 0 ? at : Date().millis))),
            // 有意截断：只是显示一行摘要，原文完整保存在消息里
            "quote": .string(text.count > 120 ? String(text.prefix(120)) + "…" : text),
        ]
    }

    // MARK: - 写：整理结果

    struct Fresh: Equatable { var text: String; var voice: String; var evidence: [[String: JSONValue]] }
    struct Pick: Equatable { var id: String; var evidence: [[String: JSONValue]] }

    private static func evJSON(_ ev: [[String: JSONValue]]) -> JSONValue { .array(ev.map { .object($0) }) }

    /// 存一份整理结果。同一个角色 × 账号只留一份（新的顶掉旧的）
    @discardableResult
    static func saveDraft(_ charId: String, _ personaId: String, fresh: [Fresh], support: [Pick], against: [Pick],
                          noteIds: [String], upTo: Double) throws -> Row {
        let p = pid(personaId)
        if let old = draft(charId, p) { try db.delete(collection, id: old.id) }
        let row = Row.new(prefix: "imp", [
            "kind": .string("draft"), "charId": .string(charId), "personaId": .string(p),
            "fresh": .array(fresh.map { .object(["text": .string($0.text), "voice": .string($0.voice), "evidence": evJSON($0.evidence)]) }),
            "support": .array(support.map { .object(["id": .string($0.id), "evidence": evJSON($0.evidence)]) }),
            "against": .array(against.map { .object(["id": .string($0.id), "evidence": evJSON($0.evidence)]) }),
            "noteIds": .array(noteIds.map { .string($0) }), "upTo": .number(upTo),
        ])
        try db.put(collection, row)
        return row
    }

    private static func mergeEv(_ list: [[String: JSONValue]], _ add: [[String: JSONValue]]) -> [[String: JSONValue]] {
        var seen = Set(list.compactMap { $0["msgId"]?.string })
        var out = list
        for e in add {
            guard let id = e["msgId"]?.string, !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(e)
        }
        return out
    }

    private static func create(_ fields: [String: JSONValue]) throws -> Row {
        let row = Row.new(prefix: "imp", fields)
        try db.put(collection, row)
        return row
    }

    private static func update(_ id: String, _ patch: [String: JSONValue]) throws {
        guard var r = get(id) else { return }
        for (k, v) in patch { r[k] = v }
        r.touch()
        try db.put(collection, r)
    }

    /// 收下勾选的那几项。没勾的新印象不丢依据：落回零散依据，下次整理还能再用。
    /// 这次交出去的零散依据算用掉了；水位线挪到这次读到的最后一条
    @discardableResult
    static func accept(_ draftId: String, fresh pf: Set<Int> = [], support ps: Set<Int> = [], against pa: Set<Int> = []) throws -> [String] {
        guard let d = get(draftId), d.string("kind") == "draft" else { throw StoreError(message: "这份整理结果已不在了") }
        let now = Date().millis
        let cid = d.string("charId"), p = d.string("personaId")
        var made: [String] = []
        for (i, f) in (d["fresh"]?.array ?? []).enumerated() {
            let text = f["text"]?.string ?? ""
            let ev = evidence(f["evidence"])
            if pf.contains(i) {
                made.append(try create(["kind": .string("imp"), "charId": .string(cid), "personaId": .string(p), "text": .string(text),
                                        "voice": .string(f["voice"]?.string ?? ""), "evidence": evJSON(mergeEv([], ev)),
                                        "against": .array([]), "state": .string("kept")]).id)
                continue
            }
            for e in ev {
                _ = try create(["kind": .string("note"), "charId": .string(cid), "personaId": .string(p), "text": .string(text), "evidence": evJSON([e])])
            }
        }
        for (key, picked) in [("support", ps), ("against", pa)] {
            for (i, x) in (d[key]?.array ?? []).enumerated() where picked.contains(i) {
                guard let id = x["id"]?.string, let imp = get(id) else { continue }
                let field = key == "support" ? "evidence" : "against"
                try update(imp.id, [field: evJSON(mergeEv(evidence(imp[field]), evidence(x["evidence"]))), "seenAt": .null])
            }
        }
        for id in (d["noteIds"]?.array ?? []).compactMap(\.string) where get(id) != nil { try update(id, ["usedAt": .number(now)]) }
        let upTo = d.number("upTo") ?? 0
        if let m = mark(cid, p) {
            try update(m.id, ["upTo": .number(max(m.number("upTo") ?? 0, upTo)), "at": .number(now)])
        } else {
            _ = try create(["kind": .string("mark"), "charId": .string(cid), "personaId": .string(p), "upTo": .number(upTo), "at": .number(now)])
        }
        try db.delete(collection, id: d.id)
        return made
    }

    /// 一项都不要：等于全都不勾
    static func discard(_ draftId: String) throws { try accept(draftId) }

    /// 不准确。不真删，记成 dropped
    static func drop(_ id: String) throws {
        guard let r = get(id), r.string("kind") == "imp" else { return }
        try update(id, ["state": .string("dropped"), "droppedAt": .number(Date().millis)])
    }

    /// 合并进某个账号的人设：key 为分区 id，或 "char"（放进「与 charId 相关」的专属印象）。印象本身不删，标「已合并」
    static func merge(_ ids: [String], personaId: String, key: String, text: String, charId: String = "") throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw StoreError(message: "内容是空的") }
        if key == "char" {
            guard !charId.isEmpty else { throw StoreError(message: "没有选择角色") }
            try SelfProfile.addNote(personaId, charId: charId, kind: "imp", text: t)
        } else {
            guard SelfProfile.sections.contains(where: { $0.id == key }) else { throw StoreError(message: "没有这个分区") }
            try SelfProfile.append(personaId, key, t)
        }
        let now = Date().millis
        for id in ids where get(id) != nil {
            try update(id, ["mergedAt": .number(now), "mergedTo": .object(["personaId": .string(personaId), "key": .string(key), "charId": .string(charId)])])
        }
    }

    // MARK: - 注入

    /// 收下的印象（网页版 context/impress.js）。只有这个角色自己的、这个账号的
    static func block(charId: String, personaId: String, userName: String) -> String {
        let lines = list(charId, personaId).map { $0.string("text") }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        return "\n\n[你对对方的印象]\nImpressions of \(userName) you have formed, each based on things \(userName) said:\n"
            + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    // MARK: - 几位都注意到的（4.347）

    static func allKept(_ personaId: String) -> [Row] {
        let p = pid(personaId)
        return ((try? db.all(collection)) ?? []).filter { $0.string("kind") == "imp" && $0.string("state") != "dropped" && $0.string("personaId") == p }
    }

    static func groupsRow(_ personaId: String) -> Row? {
        let p = pid(personaId)
        return ((try? db.all(collection, where: "")) ?? []).first { $0.string("kind") == "groups" && $0.string("personaId") == p }
    }

    static func saveGroups(_ personaId: String, _ groups: [(ids: [String], text: String)], basis: [String]) throws {
        let p = pid(personaId)
        if let old = groupsRow(p) { try db.delete(collection, id: old.id) }
        _ = try create(["kind": .string("groups"), "charId": .string(""), "personaId": .string(p),
                        "groups": .array(groups.map { .object(["ids": .array($0.ids.map { .string($0) }), "text": .string($0.text)]) }),
                        "basis": .array(basis.map { .string($0) }), "at": .number(Date().millis)])
    }

    struct Shared: Identifiable {
        var text: String
        var items: [Row]
        var charIds: [String]
        var days: Int
        var id: String { items.map(\.id).joined(separator: ",") }
    }

    /// 几位角色都注意到的那几组：只留还在的印象，至少两位角色
    static func consensus(_ personaId: String) -> [Shared] {
        guard let row = groupsRow(personaId) else { return [] }
        let live = Dictionary(allKept(personaId).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return (row["groups"]?.array ?? []).map { g -> Shared in
            let items = (g["ids"]?.array ?? []).compactMap(\.string).compactMap { live[$0] }
            var cids: [String] = []
            for r in items where !cids.contains(r.string("charId")) { cids.append(r.string("charId")) }
            let ds = Set(items.flatMap { days($0) })
            let text = g["text"]?.string ?? ""
            return Shared(text: text.isEmpty ? (items.first?.string("text") ?? "") : text, items: items, charIds: cids, days: ds.count)
        }.filter { $0.charIds.count >= 2 }
            .sorted { $0.charIds.count != $1.charIds.count ? $0.charIds.count > $1.charIds.count : $0.days > $1.days }
    }

    static func uncompared(_ personaId: String) -> Int {
        let basis = Set((groupsRow(personaId)?["basis"]?.array ?? []).compactMap(\.string))
        return allKept(personaId).filter { !basis.contains($0.id) }.count
    }

    struct Summary { var chars: Int; var total: Int; var fresh: Int; var shared: [Shared] }

    static func summary(_ personaId: String) -> Summary {
        let all = allKept(personaId)
        return Summary(chars: Set(all.map { $0.string("charId") }).count, total: all.count,
                       fresh: all.filter { ($0.number("seenAt") ?? 0) == 0 }.count, shared: consensus(personaId))
    }
}
