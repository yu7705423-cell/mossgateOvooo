import Foundation

/// 自定义互动标识（网页版 system/badgedef.js，ARCHITECTURE 4.320）。
///
/// 自己定标识：名字、说明、隐藏与否（隐藏的只给一句提示），勾选对哪些角色生效。达成方式：
///   · 按条件：按聊天记录本地算，不调接口；
///   · 手动颁发：在「互动标识」里自己点；
///   · 模型判断：写一句条件，随记忆总结顺带判断，不多调接口；
/// 解锁记在会话自己的 unlocked 里，id 是 custom-<定义 id>，和内置的成就同一处：显示、等级、让角色知道都现成认得。
/// 定义按身份分（personaId），和网页版同一个数据域 badgeDefs，导入导出原样带着。
enum BadgeDefs {
    static let collection = "badgeDefs"

    struct Opt: Hashable { let id: String, label: String }
    static let hows = [Opt(id: "rule", label: "按条件"), Opt(id: "judge", label: "模型判断"), Opt(id: "manual", label: "手动颁发")]
    static let whos = [Opt(id: "both", label: "双方"), Opt(id: "me", label: "我"), Opt(id: "char", label: "角色")]
    static let kinds = [Opt(id: "image", label: "图片"), Opt(id: "sticker", label: "表情"), Opt(id: "voice", label: "语音"),
                        Opt(id: "transfer", label: "转账"), Opt(id: "gift", label: "礼物"), Opt(id: "letter", label: "信"),
                        Opt(id: "location", label: "位置"), Opt(id: "call", label: "通话")]

    struct Metric { let id: String, label: String, unit: String; var who = false, scan = false, word = false, kind = false }
    static let metrics: [Metric] = [
        Metric(id: "messages", label: "消息条数", unit: "条", who: true, scan: true),
        Metric(id: "streak", label: "最长连续互发", unit: "天"),
        Metric(id: "known", label: "相识天数", unit: "天"),
        Metric(id: "callHours", label: "通话时长", unit: "小时"),
        Metric(id: "listenHours", label: "一起听时长", unit: "小时"),
        Metric(id: "late", label: "零点到五点的消息", unit: "条"),
        Metric(id: "pacts", label: "完成的约定", unit: "个"),
        Metric(id: "keyword", label: "某个词出现的次数", unit: "次", who: true, scan: true, word: true),
        Metric(id: "kind", label: "某类消息的条数", unit: "条", who: true, scan: true, kind: true),
    ]
    static func metric(_ id: String) -> Metric { metrics.first { $0.id == id } ?? metrics[0] }

    struct Def: Identifiable, Equatable {
        var row: Row
        var id: String { row.id }
        var name: String { row.string("name") }
        var desc: String { row.string("desc") }
        var hint: String { row.string("hint") }
        var hidden: Bool { row.bool("hidden") }
        var how: String { ["rule", "judge", "manual"].contains(row.string("how")) ? row.string("how") : "rule" }
        var rule: [String: JSONValue] { row["rule"]?.object ?? [:] }
        var cond: String { row.string("cond") }
        var charIds: [String] { row.strings("charIds") }
        var personaId: String { row.string("personaId") }
        var unlockId: String { "custom-\(id)" }

        var metricId: String { rule["metric"]?.string ?? "messages" }
        var who: String { rule["who"]?.string ?? "both" }
        var word: String { rule["word"]?.string ?? "" }
        var kind: String { rule["kind"]?.string ?? "image" }
        var value: Int { max(1, Int((rule["value"]?.number ?? 1).rounded())) }
    }

    static func defIdOf(_ unlock: String) -> String { unlock.hasPrefix("custom-") ? String(unlock.dropFirst(7)) : "" }

    // MARK: - 定义

    static func all() -> [Def] {
        ((try? Database.shared.all(collection)) ?? []).map { Def(row: $0) }
            .sorted { ($0.row.number("createdAt") ?? 0) < ($1.row.number("createdAt") ?? 0) }
    }

    static func list(personaId: String) -> [Def] {
        all().filter { ($0.personaId.isEmpty ? personaId : $0.personaId) == personaId }
    }

    static func get(_ id: String) -> Def? {
        guard !id.isEmpty, let r = try? Database.shared.get(collection, id: id) else { return nil }
        return Def(row: r)
    }

    private static func trim(_ s: String, _ n: Int) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(n)) }

    /// 写之前整理一遍（网页版 clean）。图标与上传的图原生版还不编辑，原样留着
    static func clean(_ f: [String: JSONValue]) -> [String: JSONValue] {
        var o = f
        o["name"] = .string(trim(f["name"]?.string ?? "", 20))
        o["desc"] = .string(trim(f["desc"]?.string ?? "", 120))
        o["hint"] = .string(trim(f["hint"]?.string ?? "", 40))
        o["hidden"] = .bool(f["hidden"]?.bool == true)
        let how = f["how"]?.string ?? "rule"
        o["how"] = .string(hows.contains { $0.id == how } ? how : "rule")
        let r = f["rule"]?.object ?? [:]
        let who = r["who"]?.string ?? "both", kind = r["kind"]?.string ?? "image"
        o["rule"] = .object([
            "metric": .string(metric(r["metric"]?.string ?? "messages").id),
            "who": .string(whos.contains { $0.id == who } ? who : "both"),
            "word": .string(trim(r["word"]?.string ?? "", 20)),
            "kind": .string(kinds.contains { $0.id == kind } ? kind : "image"),
            "value": .number(Double(max(1, Int((r["value"]?.number ?? 1).rounded())))),
        ])
        o["cond"] = .string(trim(f["cond"]?.string ?? "", 200))
        var seen = Set<String>()
        o["charIds"] = .array((f["charIds"]?.array ?? []).compactMap(\.string).filter { !$0.isEmpty && seen.insert($0).inserted }.map { .string($0) })
        if o["icon"] == nil { o["icon"] = .string("star") }
        return o
    }

    static func check(_ o: [String: JSONValue]) throws {
        if (o["name"]?.string ?? "").isEmpty { throw StoreError(message: "请填写名称") }
        if o["how"]?.string == "judge" && (o["cond"]?.string ?? "").isEmpty { throw StoreError(message: "请写明达成的条件") }
        if o["how"]?.string == "rule", metric(o["rule"]?["metric"]?.string ?? "").word, (o["rule"]?["word"]?.string ?? "").isEmpty {
            throw StoreError(message: "请填写要数的词")
        }
    }

    @discardableResult
    static func save(id: String?, _ fields: [String: JSONValue], personaId: String) throws -> Def {
        if let id, var cur = try Database.shared.get(collection, id: id) {
            var merged = cur.fields
            for (k, v) in fields { merged[k] = v }
            let o = clean(merged)
            try check(o)
            for (k, v) in o { cur[k] = v }
            cur.touch()
            try Database.shared.put(collection, cur)
            return Def(row: cur)
        }
        var o = clean(fields)
        try check(o)
        o["personaId"] = .string(personaId)
        o["createdAt"] = .number(Date().millis)
        let row = Row.new(prefix: "bd", o)
        try Database.shared.put(collection, row)
        return Def(row: row)
    }

    /// 删定义。各段会话里已经得到的那一枚一起收回：定义没了，那一枚连名字都没有
    static func remove(_ id: String) throws {
        let key = "custom-\(id)"
        for var c in try Repo.chats() where c.row["unlocked"]?[key] != nil {
            var u = c.row["unlocked"]?.object ?? [:]
            u[key] = nil
            c.row["unlocked"] = .object(u)
            try Repo.save(c)
        }
        try Database.shared.delete(collection, id: id)
    }

    /// 这段会话上生效的那几个：一对一的会话，角色被勾上了
    static func defsFor(_ chat: Chat) -> [Def] {
        guard !chat.isGroup, chat.characterIds.count == 1, let charId = chat.characterIds.first else { return [] }
        let me = chat.personaId.isEmpty ? (((try? Repo.activePersona()) ?? nil)?.id ?? "") : chat.personaId
        return list(personaId: me).filter { $0.charIds.contains(charId) }
    }

    // MARK: - 条件的值（网页版 measure / reached）

    private static func scanHit(_ d: Def, _ m: Message) -> Int {
        if m.isError || (m.role != .user && m.role != .char) || m.kind == "notice" || m.kind == "typing" { return 0 }
        if d.who == "me" && m.role != .user { return 0 }
        if d.who == "char" && m.role != .char { return 0 }
        switch d.metricId {
        case "messages": return 1
        case "kind": return m.kind == d.kind ? 1 : 0
        case "keyword":
            guard !d.word.isEmpty else { return 0 }
            return m.content.components(separatedBy: d.word).count - 1
        default: return 0
        }
    }

    /// 条件类各是多少。要逐条数的存一份缓存在统计里（st.cx），只数新来的；定义改过（sig 变了）就整段重数
    static func measure(_ chat: Chat, _ st: inout [String: JSONValue], msgs: () -> [Message], now: Double) -> (values: [String: Int], changed: Bool) {
        let defs = defsFor(chat).filter { $0.how == "rule" }
        var cx = st["cx"]?.object ?? [:]
        guard !defs.isEmpty else {
            if !cx.isEmpty { st["cx"] = .object([:]); return ([:], true) }
            return ([:], false)
        }
        var changed = false
        var values: [String: Int] = [:]
        var list: [Message]?
        for d in defs {
            let m = metric(d.metricId)
            if m.scan {
                if list == nil { list = msgs() }
                let sig = "\(d.metricId)|\(d.who)|\(d.word)|\(d.kind)"
                var c = cx[d.id]?.object ?? [:]
                if c["sig"]?.string != sig { c = ["sig": .string(sig), "n": .number(0), "upTo": .number(-1)]; changed = true }
                let from = c["upTo"]?.number ?? -1
                var n = Int(c["n"]?.number ?? 0), upTo = from
                for msg in (list ?? []).reversed() {
                    if msg.createdAt <= from { break }
                    n += scanHit(d, msg)
                    upTo = max(upTo, msg.createdAt)
                }
                if Double(n) != c["n"]?.number || upTo != from { changed = true }
                cx[d.id] = .object(["sig": .string(sig), "n": .number(Double(n)), "upTo": .number(upTo)])
                values[d.id] = n
            } else {
                switch d.metricId {
                case "streak": values[d.id] = Int(st["best"]?.number ?? 0)
                case "known":
                    let first = st["first"]?.number ?? 0
                    values[d.id] = first > 0 ? Badges.dayNo(now) - Badges.dayNo(first) + 1 : 0
                case "callHours": values[d.id] = Int((st["callSec"]?.number ?? 0) / 3600)
                case "listenHours": values[d.id] = Int((st["listenSec"]?.number ?? 0) / 3600)
                case "late": values[d.id] = Int(st["late"]?.number ?? 0)
                case "pacts": values[d.id] = Int(st["pacts"]?.number ?? 0)
                default: break
                }
            }
        }
        let live = Set(defs.map(\.id))
        for k in cx.keys where !live.contains(k) { cx[k] = nil; changed = true }
        st["cx"] = .object(cx)
        return (values, changed)
    }

    /// 条件类里够数了的那几个
    static func reached(_ chat: Chat, _ st: inout [String: JSONValue], msgs: () -> [Message], now: Double) -> (hits: [String], changed: Bool) {
        let r = measure(chat, &st, msgs: msgs, now: now)
        let hits = defsFor(chat).filter { $0.how == "rule" && (r.values[$0.id] ?? 0) >= $0.value }.map(\.unlockId)
        return (hits, r.changed)
    }

    // MARK: - 模型判断（随记忆总结顺带判断，不多调接口；网页版 4.320）

    /// 设置里没关就搭（badgeJudgeInSummary，默认开）
    static func inSummary(_ s: AppSettings = .load()) -> Bool { s.raw["badgeJudgeInSummary"]?.bool != false }

    /// 这段会话上还没得到的「模型判断」那几个
    static func judgeFor(_ chat: Chat) -> [Def] {
        defsFor(chat).filter { $0.how == "judge" && chat.row["unlocked"]?[$0.unlockId] == nil }
    }

    static func judgeText(_ defs: [Def]) -> String {
        defs.map { "(id:\($0.id)) badge: \($0.name) | earned when: \($0.cond)" }.joined(separator: "\n")
    }

    /// 只认这一次交出去的那几个 id（模型编一个出来不算数）
    static func applyJudged(_ result: JSONValue?, sent: [Def], chatId: String) {
        let ids = Set(sent.map(\.id))
        for r in result?.array ?? [] {
            let id = r.string ?? r["id"]?.string ?? ""
            guard ids.contains(id) else { continue }
            do { try grant(chatId, "custom-\(id)") } catch { Diagnostics.shared.record("badge-judge-failed", ["error": error.localizedDescription]) }
        }
    }

    // MARK: - 看

    static func label(_ unlock: String) -> String {
        guard let d = get(defIdOf(unlock)) else { return "" }
        return d.desc.isEmpty ? d.name : "\(d.name)（\(d.desc)）"
    }

    /// 条件写成一句给人看的话
    static func ruleText(_ d: Def) -> String {
        if d.how == "manual" { return "手动颁发" }
        if d.how == "judge" { return d.cond.isEmpty ? "由模型判断" : "由模型判断：\(d.cond)" }
        let m = metric(d.metricId)
        let who = m.who ? (whos.first(where: { $0.id == d.who })?.label ?? "双方") : ""
        let what = d.metricId == "keyword" ? "说「\(d.word)」" : d.metricId == "kind" ? "发\(kinds.first(where: { $0.id == d.kind })?.label ?? "")" : m.label
        return "\(who)\(what)达到 \(d.value) \(m.unit)"
    }

    /// 直接给一枚（手动颁发）。已经有了就不动
    @discardableResult
    static func grant(_ chatId: String, _ unlock: String, at: Double = Date().millis) throws -> Bool {
        guard var chat = try Repo.chat(chatId), chat.row["unlocked"]?[unlock] == nil else { return false }
        var u = chat.row["unlocked"]?.object ?? [:]
        u[unlock] = .number(at)
        chat.row["unlocked"] = .object(u)
        try Repo.save(chat)
        return true
    }

    /// 收回一枚（手动颁发错了的时候）
    static func revoke(_ chatId: String, _ unlock: String) throws {
        guard var chat = try Repo.chat(chatId), chat.row["unlocked"]?[unlock] != nil else { return }
        var u = chat.row["unlocked"]?.object ?? [:]
        u[unlock] = nil
        chat.row["unlocked"] = .object(u)
        try Repo.save(chat)
    }
}
