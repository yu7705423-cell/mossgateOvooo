import Foundation

/// 衣帽间（网页版 system/closet.js，ARCHITECTURE 4.213、4.214、4.216、4.344）。
///
/// 一件东西一行，存在 closet 域，按 owner 建索引：'me' 是自己（另记 personaId，各个身份各有各的衣帽间），角色的就是角色 id。
/// 套装与单品存在同一个域里，side 记作 'outfit'。字段名与默认值照网页版 create / createOutfit，不认得的字段写回去时原样留着。
///
/// 全程不调接口：余量、保质期、今天穿的都是本地算的。识图、按描述生图、按设定生成一批是用户点了才调的，
/// 每日穿搭是每天一次的自动任务（默认关），都在 ClosetAI.swift。
enum Closet {
    static let me = "me"
    static let collection = "closet"
    static let outfit = "outfit"
    static let carry = "carry"
    private static let day = 86_400_000.0

    // MARK: - 日期（网页版 health.dateKey 与 closet.js 的 toMs，按本机时区）

    static func dateKey(_ ms: Double) -> String { Health.dateKey(Date(millis: ms)) }
    static func nowMs() -> Double { Clock.now(AppSettings.load()).millis }
    static func today() -> String { Health.dateKey() }

    static func toMs(_ key: String) -> Double {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard let y = p.first, y > 0 else { return 0 }
        let c = DateComponents(year: y, month: p.count > 1 ? p[1] : 1, day: p.count > 2 ? p[2] : 1)
        return Calendar.current.date(from: c)?.millis ?? 0
    }

    private static func addMonths(_ ms: Double, _ n: Double) -> Double {
        Calendar.current.date(byAdding: .month, value: Int(n.rounded()), to: Date(millis: ms))?.millis ?? ms
    }

    static func personaId() -> String { Diary.personaId() }

    // MARK: - 分类：内置的加上自己加的小类，减去隐藏的大类

    static func subsOf(_ groupId: String, _ s: AppSettings = .load()) -> [ClosetKinds.Sub] {
        guard let g = ClosetKinds.group(groupId) else { return [] }
        let extra = (s.raw["closetSubs"]?[groupId]?.array ?? []).compactMap(\.string)
        let have = Set(g.subs.map(\.label))
        var seen = Set<String>()
        return g.subs + extra.filter { !$0.isEmpty && !have.contains($0) && seen.insert($0).inserted }.map { ClosetKinds.Sub(label: $0, custom: true) }
    }

    static func subMeta(_ groupId: String, _ sub: String) -> ClosetKinds.Sub? { subsOf(groupId).first { $0.label == sub } }

    @discardableResult
    static func addSub(_ groupId: String, _ label: String) throws -> Bool {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, ClosetKinds.group(groupId) != nil, !subsOf(groupId).contains(where: { $0.label == l }) else { return false }
        var s = try AppSettings.loadForWrite()
        var all = s.raw["closetSubs"]?.object ?? [:]
        all[groupId] = .array((all[groupId]?.array ?? []) + [.string(l)])
        s.raw["closetSubs"] = .object(all)
        try s.save()
        return true
    }

    static func dropSub(_ groupId: String, _ label: String) throws {
        var s = try AppSettings.loadForWrite()
        var all = s.raw["closetSubs"]?.object ?? [:]
        all[groupId] = .array((all[groupId]?.array ?? []).filter { $0.string != label })
        s.raw["closetSubs"] = .object(all)
        try s.save()
    }

    static func hiddenGroups(_ s: AppSettings = .load()) -> Set<String> { Set((s.raw["closetHidden"]?.array ?? []).compactMap(\.string)) }

    static func setGroupHidden(_ groupId: String, _ hide: Bool) throws {
        var s = try AppSettings.loadForWrite()
        var set = hiddenGroups(s)
        if hide { set.insert(groupId) } else { set.remove(groupId) }
        s.raw["closetHidden"] = .array(ClosetKinds.groups.map(\.id).filter { set.contains($0) }.map { .string($0) })
        try s.save()
    }

    static func groupsOf(_ side: String) -> [ClosetKinds.Group] {
        let hidden = hiddenGroups()
        return ClosetKinds.groups.filter { $0.side == side && !hidden.contains($0.id) }
    }

    // MARK: - 谁的

    static func isOutfit(_ r: Row) -> Bool { r.string("side") == outfit }
    static func isCarry(_ r: Row) -> Bool { r.string("group") == carry }
    static func live(_ r: Row) -> Bool { !ClosetKinds.goneStates.contains(r.string("state")) }
    static func lentOut(_ r: Row) -> Bool { !(r["lent"]?["to"]?.string ?? "").isEmpty }

    /// 这个主人的全部。自己的按身份分开（没记身份的老数据算在每个身份上）
    static func itemsOf(_ owner: String, _ pid: String? = nil) -> [Row] {
        let rows = (try? Database.shared.all(collection, where: owner)) ?? []
        guard owner == me else { return rows }
        let p = pid ?? personaId()
        return rows.filter { $0.string("personaId").isEmpty || $0.string("personaId") == p }
    }

    static func get(_ id: String) -> Row? { (try? Database.shared.get(collection, id: id)) ?? nil }

    // MARK: - 增删改

    static func num(_ v: JSONValue?) -> Double {
        if let n = v?.number { return n }
        if let s = v?.string, let n = Double(s) { return n }
        return 0
    }

    static func strs(_ v: JSONValue?) -> JSONValue { .array((v?.array ?? []).compactMap(\.string).map { .string($0) }) }

    /// 新建一件（网页版 create）。fields 里没给的按网页版默认值补
    @discardableResult
    static func create(_ f: [String: JSONValue]) throws -> Row {
        let owner = f["owner"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? me
        let g = ClosetKinds.group(f["group"]?.string ?? "")
        let side = f["side"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? g?.side ?? "wear"
        let sub = f["sub"]?.string ?? ""
        let meta = g.flatMap { g in sub.isEmpty ? nil : subMeta(g.id, sub) }
        func s(_ k: String) -> JSONValue { .string(f[k]?.string ?? "") }
        let name = (f["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = f["personaId"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? personaId()
        // 一项一项写：几十项的字典字面量编译器推断不过来
        var fields: [String: JSONValue] = [:]
        fields["owner"] = .string(owner)
        fields["personaId"] = .string(owner == me ? pid : "")
        fields["side"] = .string(side)
        fields["group"] = .string(g?.id ?? "")
        fields["sub"] = .string(sub)
        fields["name"] = .string(name.isEmpty ? "未命名" : name)
        fields["desc"] = s("desc")
        let img = f["imageId"]?.string ?? ""
        fields["imageId"] = img.isEmpty ? .null : .string(img)
        fields["colors"] = strs(f["colors"])
        fields["seasons"] = strs(f["seasons"])
        fields["occasions"] = strs(f["occasions"])
        let source = f["source"]?.string ?? ""
        fields["source"] = .string(source.isEmpty ? "self" : source)
        fields["giver"] = s("giver")
        fields["with"] = s("with")
        fields["giftMsgId"] = s("giftMsgId")
        fields["giftChatId"] = s("giftChatId")
        fields["giftAt"] = .number(num(f["giftAt"]))
        fields["note"] = s("note")
        fields["state"] = s("state")
        fields["wornOn"] = .string("")
        fields["wornCount"] = .number(0)
        fields["lastWorn"] = .number(0)
        // 购买、穿着记录、清洗与保养（4.344）：只给自己看
        fields["channel"] = .string((f["channel"]?.string ?? "").trimmingCharacters(in: .whitespaces))
        fields["price"] = .number(num(f["price"]))
        fields["wornDates"] = .array([])
        fields["washWay"] = s("washWay")
        fields["washedAt"] = s("washedAt")
        fields["washRule"] = s("washRule")
        fields["washN"] = .number(num(f["washN"]))
        fields["careNote"] = .string((f["careNote"]?.string ?? "").trimmingCharacters(in: .whitespaces))
        fields["caredAt"] = s("caredAt")
        fields["careEvery"] = .number(num(f["careEvery"]))
        // 妆台
        fields["shade"] = s("shade")
        fields["capacity"] = .number(num(f["capacity"]))
        let capUnit = f["capUnit"]?.string ?? ""
        fields["capUnit"] = .string(capUnit.isEmpty ? "毫升" : capUnit)
        let metaDose: Double = meta?.dose ?? 0
        fields["dose"] = .number(f["dose"]?.number ?? metaDose)
        let doseUnit = f["doseUnit"]?.string ?? ""
        let metaUnit: String = meta?.unit ?? ""
        fields["doseUnit"] = .string(doseUnit.isEmpty ? metaUnit : doseUnit)
        fields["perDay"] = .number(num(f["perDay"]))
        fields["mlPer"] = .number(0)
        fields["level"] = .null
        fields["buyAt"] = s("buyAt")
        fields["openedAt"] = s("openedAt")
        fields["expireAt"] = s("expireAt")
        let metaPao: Double = meta?.pao ?? 0
        fields["pao"] = .number(f["pao"]?.number ?? metaPao)
        fields["shelf"] = .number(num(f["shelf"]))
        fields["alertAt"] = .number(0)
        fields["auto"] = .bool(f["auto"]?.bool == true)
        // 调用方带来的其余字段（例如 lent）原样放上
        for (k, v) in f where fields[k] == nil && !["id", "createdAt", "updatedAt"].contains(k) { fields[k] = v }
        let row = Row.new(prefix: "cl", fields)
        try Database.shared.put(collection, row)
        return row
    }

    /// 改一件。改了分类，妆台那几样默认值跟着换成新小类的（自己填过的不动）。动过一次就算收下的了（auto 清掉）
    @discardableResult
    static func update(_ id: String, _ patch: [String: JSONValue]) throws -> Row? {
        guard var r = get(id) else { return nil }
        var next = patch
        next["auto"] = .bool(false)
        let ng = patch["group"]?.string, ns = patch["sub"]?.string
        if (ng != nil && ng != r.string("group")) || (ns != nil && ns != r.string("sub")) {
            if let g = ClosetKinds.group(ng ?? r.string("group")) {
                next["side"] = .string(g.side)
                if let meta = subMeta(g.id, ns ?? r.string("sub")) {
                    if r.string("doseUnit").isEmpty && !meta.unit.isEmpty {
                        next["doseUnit"] = .string(meta.unit)
                        if num(r["dose"]) == 0 { next["dose"] = .number(meta.dose) }
                    }
                    if num(r["pao"]) == 0 && meta.pao > 0 { next["pao"] = .number(meta.pao) }
                }
            }
        }
        for (k, v) in next { r[k] = v }
        r.touch()
        try Database.shared.put(collection, r)
        return r
    }

    /// 只改几个字段，不碰 auto（内部记号：今天穿、借、提醒的时刻）
    @discardableResult
    static func patch(_ id: String, _ p: [String: JSONValue]) throws -> Row? {
        guard var r = get(id) else { return nil }
        for (k, v) in p { r[k] = v }
        r.touch()
        try Database.shared.put(collection, r)
        return r
    }

    /// 删一件。图片文件不删：同一张图可能还挂在别处（网页版第 20 条，宁可留着）
    static func remove(_ id: String) throws { try Database.shared.delete(collection, id: id) }

    /// 一次放进好几张图：每张一件，先不分类（落在「未整理」），分类交给识图或手动
    static func addPhotos(_ imageIds: [String], owner: String = me, side: String = "wear", group: String = "", sub: String = "") throws -> [Row] {
        try imageIds.map { try create(["owner": .string(owner), "side": .string(side), "group": .string(group), "sub": .string(sub),
                                       "imageId": .string($0), "name": .string("")]) }
    }

    // MARK: - 今天穿的、随身、借穿（4.216）

    private static func onToday(_ r: Row, _ d: String) -> Bool { r.string("side") == "wear" && r.string("wornOn") == d && live(r) }

    /// 今天穿着（戴着、带着）的。借出去的算在借的人身上。随身那一类也在里面，要分开用 isCarry
    static func wornToday(_ owner: String, _ pid: String? = nil) -> [Row] {
        let d = today()
        return itemsOf(owner, pid).filter { onToday($0, d) && !lentOut($0) } + borrowedBy(owner, pid).filter { onToday($0, d) }
    }

    /// 借到这个人手上的（别人的东西）。自己的按身份分开
    static func borrowedBy(_ owner: String, _ pid: String? = nil) -> [Row] {
        let p = pid ?? personaId()
        return ((try? Database.shared.all(collection)) ?? []).filter { r in
            lentOut(r) && r["lent"]?["to"]?.string == owner && r.string("owner") != owner && !isOutfit(r) && live(r)
                && (owner != me || (r["lent"]?["personaId"]?.string ?? "").isEmpty || r["lent"]?["personaId"]?.string == p)
        }
    }

    /// 借给谁。to 是 'me' 或角色 id
    @discardableResult
    static func lend(_ id: String, to: String) throws -> Row? {
        guard let r = get(id), !to.isEmpty, to != r.string("owner") else { return nil }
        return try patch(id, ["lent": .object(["to": .string(to), "at": .number(nowMs()), "personaId": .string(to == me ? personaId() : "")]),
                              "wornOn": .string("")])
    }

    /// 还回去。今天正穿着的一并取消
    @discardableResult
    static func giveBack(_ id: String) throws -> Row? {
        guard let r = get(id) else { return nil }
        return try patch(id, ["lent": .null, "wornOn": .string(r.string("wornOn") == today() ? "" : r.string("wornOn"))])
    }

    /// 我和这个角色之间借来借去、还没还的
    static func lentBetween(_ charId: String, _ pid: String? = nil) -> [Row] {
        let p = pid ?? personaId()
        return borrowedBy(me, p).filter { $0.string("owner") == charId }
            + borrowedBy(charId, p).filter { $0.string("owner") == me && ($0.string("personaId").isEmpty || $0.string("personaId") == p) }
    }

    /// 今天穿 / 不穿了。第一次勾上的那天穿过次数加一；当天又取消就减回去
    static func wear(_ id: String, _ on: Bool = true) throws {
        guard let r = get(id) else { return }
        let d = today()
        let dates = r.strings("wornDates").filter { $0 != d }
        let count = num(r["wornCount"])
        if on {
            if r.string("wornOn") == d { return }
            try patch(id, ["wornOn": .string(d), "wornCount": .number(count + 1), "lastWorn": .number(nowMs()),
                           "wornDates": .array((dates + [d]).map { .string($0) })])
        } else if r.string("wornOn") == d {
            try patch(id, ["wornOn": .string(""), "wornCount": .number(max(0, count - 1)), "wornDates": .array(dates.map { .string($0) })])
        }
    }

    // MARK: - 购买、次数、清洗与保养（4.344，只给自己看）

    static func wornDatesOf(_ r: Row) -> [String] { Array(Set(r.strings("wornDates"))).sorted(by: >) }
    static func undatedWears(_ r: Row) -> Int { max(0, Int(num(r["wornCount"])) - wornDatesOf(r).count) }

    static func setCount(_ id: String, _ n: Int) throws {
        guard let r = get(id) else { return }
        try patch(id, ["wornCount": .number(Double(max(wornDatesOf(r).count, n)))])
    }

    static func dropWornDate(_ id: String, _ d: String) throws {
        guard let r = get(id), r.strings("wornDates").contains(d) else { return }
        let dates = r.strings("wornDates").filter { $0 != d }
        let last = dates.sorted().last.map { toMs($0) } ?? 0
        var p: [String: JSONValue] = ["wornDates": .array(dates.map { .string($0) }),
                                      "wornCount": .number(Double(max(dates.count, Int(num(r["wornCount"])) - 1)))]
        if r.string("wornOn") == d { p["wornOn"] = .string("") }
        if num(r["lastWorn"]) > 0 && dateKey(num(r["lastWorn"])) == d { p["lastWorn"] = .number(last) }
        try patch(id, p)
    }

    /// 每穿一次合多少钱。价格与次数都有才算
    static func perWear(_ r: Row) -> Double {
        let p = num(r["price"]), n = num(r["wornCount"])
        return p > 0 && n > 0 ? p / n : 0
    }

    private static func daysSince(_ key: String, _ r: Row, _ now: Double) -> Int {
        let starts = [toMs(key), toMs(r.string("buyAt")), r.created ?? 0]
        let base = starts.first(where: { $0 > 0 }) ?? now
        return Int(((now - base) / day).rounded(.down))
    }

    static func wearsSinceWash(_ r: Row) -> Int {
        let w = r.string("washedAt")
        return wornDatesOf(r).filter { w.isEmpty || $0 > w }.count
    }

    static func washed(_ id: String, _ d: String = today()) throws { try patch(id, ["washedAt": .string(d)]) }
    static func cared(_ id: String, _ d: String = today()) throws { try patch(id, ["caredAt": .string(d)]) }

    struct Care: Equatable {
        var washWears: Int?
        var washDays: Int?
        var careDays: Int?
        var careNote = ""
        var wash: Bool { washWears != nil || washDays != nil }
    }

    /// 该洗、该保养了没有（网页版 careOf）
    static func careOf(_ r: Row, now: Double = nowMs()) -> Care? {
        guard live(r), !isOutfit(r) else { return nil }
        var c = Care()
        let n = Int(num(r["washN"]))
        if r.string("washRule") == "wears" && n > 0 {
            let w = wearsSinceWash(r)
            if w >= n { c.washWears = w }
        } else if r.string("washRule") == "days" && n > 0 {
            let d = daysSince(r.string("washedAt"), r, now)
            if d >= n { c.washDays = d }
        }
        let every = Int(num(r["careEvery"]))
        let note = r.string("careNote").trimmingCharacters(in: .whitespaces)
        if every > 0 && !note.isEmpty {
            let d = daysSince(r.string("caredAt"), r, now)
            if d >= every { c.careDays = d; c.careNote = note }
        }
        return c.wash || c.careDays != nil ? c : nil
    }

    static func careAlertsOf(_ owner: String, _ pid: String? = nil, now: Double = nowMs()) -> [(item: Row, care: Care)] {
        itemsOf(owner, pid).compactMap { r in careOf(r, now: now).map { (item: r, care: $0) } }
    }

    static func careText(_ c: Care?) -> String {
        guard let c else { return "" }
        var out: [String] = []
        if let w = c.washWears { out.append("该洗了：上次清洗后已穿 \(w) 次") } else if let d = c.washDays { out.append("该洗了：距上次清洗已 \(d) 天") }
        if let d = c.careDays { out.append("该保养了（\(c.careNote)）：距上次已 \(d) 天") }
        return out.joined(separator: "；")
    }

    struct Channel: Equatable { var name: String; var count: Int; var spent: Double }

    struct Stats {
        var total = 0, live = 0, priced = 0
        var spent = 0.0
        var channels: [Channel] = []
        var perCount = 0
        var cheap: [(item: Row, per: Double)] = []
        var dear: [(item: Row, per: Double)] = []
        var unworn: [Row] = []
        var most: [Row] = []
        var idleDays = 30
        var idle: [Row] = []
        var month = 0
    }

    /// 统计页（网页版 statsOf）。limit 是每个名单列几件，0 为全部（默认值，不是上限）
    static func statsOf(_ owner: String, _ pid: String?, side: String, limit: Int = 5, now: Double = nowMs()) -> Stats {
        let rows = itemsOf(owner, pid).filter { $0.string("side") == side && !isOutfit($0) }
        let lv = rows.filter { live($0) }
        func cut<T>(_ list: [T]) -> [T] { limit > 0 ? Array(list.prefix(limit)) : list }
        let priced = rows.filter { num($0["price"]) > 0 }
        var out = Stats()
        out.total = rows.count; out.live = lv.count; out.priced = priced.count
        out.spent = priced.reduce(0) { $0 + num($1["price"]) }
        var by: [String: Channel] = [:]
        var order: [String] = []
        for r in rows {
            let k = r.string("channel").trimmingCharacters(in: .whitespaces).isEmpty ? "未填" : r.string("channel").trimmingCharacters(in: .whitespaces)
            if by[k] == nil { order.append(k); by[k] = Channel(name: k, count: 0, spent: 0) }
            by[k]!.count += 1
            by[k]!.spent += num(r["price"])
        }
        out.channels = order.compactMap { by[$0] }.sorted { $0.spent != $1.spent ? $0.spent > $1.spent : $0.count > $1.count }
        guard side == "wear" else { return out }
        let worn = lv.filter { num($0["wornCount"]) > 0 }
        let per = priced.filter { live($0) && num($0["wornCount"]) > 0 }.map { (item: $0, per: perWear($0)) }
        let since = dateKey(now - 30 * day)
        let idleDays = idleCfg().days > 0 ? idleCfg().days : 30
        out.perCount = per.count
        out.cheap = cut(per.sorted { $0.per < $1.per })
        out.dear = cut(per.sorted { $0.per > $1.per })
        out.unworn = cut(priced.filter { live($0) && !(num($0["wornCount"]) > 0) }.sorted { num($0["price"]) > num($1["price"]) })
        out.most = cut(worn.sorted { num($0["wornCount"]) > num($1["wornCount"]) })
        out.idleDays = idleDays
        out.idle = cut(worn.filter { num($0["lastWorn"]) > 0 && now - num($0["lastWorn"]) >= Double(idleDays) * day }
            .sorted { num($0["lastWorn"]) < num($1["lastWorn"]) })
        out.month = lv.reduce(0) { $0 + wornDatesOf($1).filter { $0 > since }.count }
        return out
    }

    // MARK: - 余量与保质期（只对妆台）

    static func perUse(_ r: Row) -> Double {
        let dose = num(r["dose"])
        guard dose > 0 else { return 0 }
        let k = num(r["mlPer"]) > 0 ? num(r["mlPer"]) : (ClosetKinds.dose[r.string("doseUnit")] ?? 1)
        return dose * k
    }

    struct Remain: Equatable { var pct: Int; var daysLeft: Int }

    /// 还剩多少。容量、每次用量、每天几次三样都填了才算；从开封（没有就购入、再没有就放进来那天）起按天扣
    static func remaining(_ r: Row, now: Double = nowMs()) -> Remain? {
        let cap = num(r["capacity"])
        let use = perUse(r) * num(r["perDay"])
        guard r.string("side") == "beauty", cap > 0, use > 0 else { return nil }
        let starts = [toMs(r.string("openedAt")), toMs(r.string("buyAt")), r.created ?? 0]
        var basePct = 100.0
        var baseAt = starts.first(where: { $0 > 0 }) ?? now
        if let lv = r["level"]?.object, let at = lv["at"]?.number, at > 0 { basePct = lv["pct"]?.number ?? 0; baseAt = at }
        let days = max(0, (now - baseAt) / day)
        let left = max(0, cap * basePct / 100 - use * days)
        return Remain(pct: Int((left / cap * 100).rounded()), daysLeft: Int((left / use).rounded(.down)))
    }

    static func calibrate(_ id: String, _ pct: Double) throws {
        try patch(id, ["level": .object(["pct": .number(max(0, min(100, pct.rounded()))), "at": .number(nowMs())])])
    }

    struct Expiry: Equatable { var at: Double; var basis: String; var daysLeft: Int }

    /// 什么时候过期：自己填的保质日期 / 开封日期加开封后可用几个月 / 购入日期加未开封保质期
    static func expiry(_ r: Row, now: Double = nowMs()) -> Expiry? {
        guard r.string("side") == "beauty" else { return nil }
        var at = 0.0, basis = ""
        if !r.string("expireAt").isEmpty { at = toMs(r.string("expireAt")); basis = "set" }
        else if !r.string("openedAt").isEmpty && num(r["pao"]) > 0 { at = addMonths(toMs(r.string("openedAt")), num(r["pao"])); basis = "opened" }
        else if !r.string("buyAt").isEmpty && r.string("openedAt").isEmpty {
            at = addMonths(toMs(r.string("buyAt")), num(r["shelf"]) > 0 ? num(r["shelf"]) : ClosetKinds.shelfMonths); basis = "bought"
        }
        guard at > 0 else { return nil }
        return Expiry(at: at, basis: basis, daysLeft: Int(((at - now) / day).rounded(.down)))
    }

    struct AlertCfg { var lowPct: Double; var lowDays: Int; var expireDays: Int; var cooldown: Double }

    static func alertCfg(_ s: AppSettings = .load()) -> AlertCfg {
        AlertCfg(lowPct: s.raw["closetLowPct"]?.number ?? 15, lowDays: 14,
                 expireDays: Int(s.raw["closetExpireWarn"]?.number ?? 30), cooldown: s.raw["closetAlertCooldown"]?.number ?? 30)
    }

    struct Flags: Equatable { var low: Remain?; var exp: Expiry? }

    static func flagsOf(_ r: Row, now: Double = nowMs()) -> Flags? {
        guard r.string("side") == "beauty", live(r) else { return nil }
        let c = alertCfg()
        let rem = remaining(r, now: now), exp = expiry(r, now: now)
        let low = rem.map { Double($0.pct) <= c.lowPct || $0.daysLeft <= c.lowDays } ?? false
        let soon = exp.map { $0.daysLeft <= c.expireDays } ?? false
        return low || soon ? Flags(low: low ? rem : nil, exp: soon ? exp : nil) : nil
    }

    static func alertsOf(_ owner: String, _ pid: String? = nil, now: Double = nowMs()) -> [(item: Row, flags: Flags)] {
        itemsOf(owner, pid).compactMap { r in flagsOf(r, now: now).map { (item: r, flags: $0) } }
    }

    /// 这一轮要告诉角色的那几件（网页版 takeAlerts）：只在第一次递出去的那一天出现，之后过了冷却期才再递一次
    static func takeAlerts(_ pid: String?, now: Double = nowMs()) -> [(item: Row, flags: Flags)] {
        let c = alertCfg()
        let d = dateKey(now)
        var out: [(item: Row, flags: Flags)] = []
        for (item, f) in alertsOf(me, pid, now: now) {
            let at = num(item["alertAt"])
            let shownToday = at > 0 && dateKey(at) == d
            let cooled = at <= 0 || now - at >= c.cooldown * day
            if !shownToday && !cooled { continue }
            if !shownToday { _ = try? patch(item.id, ["alertAt": .number(now)]) }
            out.append((item: item, flags: f))
        }
        return out
    }

    // MARK: - 来源

    private static func nameOfWho(_ id: String, _ fallback: String) -> String {
        if id == me { return ((try? Repo.activePersona()) ?? nil)?.name ?? "我" }
        return ((try? Repo.character(id)) ?? nil)?.name ?? fallback
    }

    /// 「阿岚送的 · 2026-08-29」
    static func sourceText(_ r: Row) -> String {
        if r.string("source") == "gift" {
            let who = r.string("giver").isEmpty ? "收到的礼物" : "\(nameOfWho(r.string("giver"), "对方"))送的"
            return num(r["giftAt"]) > 0 ? "\(who) · \(dateKey(num(r["giftAt"])))" : who
        }
        if r.string("source") == "made" { return r.string("with").isEmpty ? "一起做的" : "和\(nameOfWho(r.string("with"), "对方"))一起做的" }
        return ""
    }

    // MARK: - 礼物联动

    /// 从一条礼物消息里读出要放进衣帽间的那几样：角色送给我的归我，我送给角色的归角色
    static func fromGift(_ m: Message) -> [String: JSONValue]? {
        guard m.kind == "gift" else { return nil }
        let fromChar = m.role == .char
        let to = ((try? Repo.chat(m.chatId)) ?? nil)?.characterIds.first ?? ""
        if !fromChar && to.isEmpty { return nil }
        let inner = m.row.string("inner"), cover = m.row.string("cover")
        return ["owner": .string(fromChar ? me : to), "name": .string(inner.isEmpty ? cover : inner),
                "source": .string("gift"), "giver": .string(fromChar ? m.authorId : me),
                "giftMsgId": .string(m.id), "giftChatId": .string(m.chatId), "giftAt": .number(m.createdAt > 0 ? m.createdAt : nowMs())]
    }

    static func giftItem(_ msgId: String) -> Row? {
        ((try? Database.shared.all(collection)) ?? []).first { $0.string("giftMsgId") == msgId }
    }

    private static let aliases: [(String, String, String)] = [
        ("耳环", "jewelry", "耳饰"), ("耳钉", "jewelry", "耳饰"), ("耳坠", "jewelry", "耳饰"),
        ("手镯", "jewelry", "手链 / 手镯"), ("手链", "jewelry", "手链 / 手镯"), ("吊坠", "jewelry", "项链"),
        ("发夹", "acc", "发饰"), ("发卡", "acc", "发饰"), ("发圈", "acc", "发饰"), ("墨镜", "acc", "眼镜"),
        ("毛衣", "top", "针织 / 毛衣"), ("针织", "top", "针织 / 毛衣"), ("T恤", "top", "T 恤"),
        ("吊带", "top", "背心 / 吊带"), ("背心", "top", "背心 / 吊带"), ("裙子", "onepiece", "连衣裙"),
        ("裤", "bottom", "长裤"), ("球鞋", "shoes", "运动鞋"), ("高跟", "shoes", "高跟鞋"), ("拖鞋", "shoes", "凉拖"),
        ("包包", "bag", "手提"), ("背包", "bag", "双肩"), ("钱包", "bag", "手拿"),
        ("唇膏", "lip", "口红"), ("唇釉", "lip", "唇釉"), ("面霜", "skin", "乳霜"), ("粉底液", "base", "粉底"),
        ("眼影盘", "eye", "眼影"), ("香氛", "scent", "香水"), ("化妆刷", "tool", "刷具"),
        ("外套", "outer", "夹克"), ("围巾", "acc", "围巾"), ("帽", "acc", "帽子"), ("手表", "acc", "手表"),
        ("雨伞", "carry", "伞"), ("拍立得", "carry", "相机"),
        ("鞋", "shoes", ""), ("包", "bag", ""), ("裙", "onepiece", "连衣裙"),
    ]
    private static let loose: Set<String> = ["造型", "平底", "套装", "手提", "高光", "修容", "洗护", "贴身"]

    /// 按名字猜分类（本地词表，不调接口）。认不出给 nil
    static func guessKind(_ name: String) -> (group: String, sub: String)? {
        guard !name.isEmpty else { return nil }
        let t = name.filter { !$0.isWhitespace }
        var subs: [(w: String, group: String, sub: String)] = []
        for g in ClosetKinds.groups {
            for s in subsOf(g.id) {
                for w in s.label.components(separatedBy: " / ") {
                    let k = w.filter { !$0.isWhitespace }
                    if k.count >= 2 && !loose.contains(k) { subs.append((k, g.id, s.label)) }
                }
            }
        }
        // 长的先认；同样长的照表里的先后（Swift 的 sort 不保证稳定，带上下标）
        let ordered = subs.enumerated().sorted { $0.element.w.count != $1.element.w.count ? $0.element.w.count > $1.element.w.count : $0.offset < $1.offset }
        if let hit = ordered.first(where: { t.contains($0.element.w) }) { return (hit.element.group, hit.element.sub) }
        if let al = aliases.first(where: { name.contains($0.0) }) { return (al.1, al.2) }
        return nil
    }

    /// 我送的礼物，角色拆开收下了：认得出是衣帽间里的东西就直接收进它的衣帽间。自动收的记 auto，整轮重新生成时撤掉
    @discardableResult
    static func keepGift(_ m: Message) throws -> Row? {
        guard m.kind == "gift", m.role == .user, giftItem(m.id) == nil, var f = fromGift(m) else { return nil }
        guard let k = guessKind(f["name"]?.string ?? "") ?? guessKind(m.row.string("cover")) else { return nil }
        f["group"] = .string(k.group); f["sub"] = .string(k.sub); f["auto"] = .bool(true)
        return try create(f)
    }

    static func dropAutoGift(_ msgId: String) throws {
        if let r = giftItem(msgId), r.bool("auto") { try remove(r.id) }
    }

    // MARK: - 给角色看的清单

    /// 按大类分行，每类最多 limit 件（0 为全部）。只写名字
    static func listLines(_ owner: String, _ pid: String?, side: String, limit: Int) -> [String] {
        let rows = itemsOf(owner, pid).filter { $0.string("side") == side && live($0) && !$0.string("group").isEmpty }
        var lines: [String] = []
        for g in ClosetKinds.groups where g.side == side {
            let mine = rows.filter { $0.string("group") == g.id }.sorted {
                (num($0["lastWorn"]) > 0 ? num($0["lastWorn"]) : $0.created ?? 0) > (num($1["lastWorn"]) > 0 ? num($1["lastWorn"]) : $1.created ?? 0)
            }
            guard !mine.isEmpty else { continue }
            let shown = limit > 0 ? Array(mine.prefix(limit)) : mine
            let more = mine.count - shown.count
            lines.append("\(g.label): \(shown.map { $0.string("name") }.joined(separator: ", "))\(more > 0 ? " (+\(more) more)" : "")")
        }
        return lines
    }

    // MARK: - 描述里只留东西本身（4.215）

    private static let person = try! NSRegularExpression(
        pattern: #"模特|人台|假人|穿着者|试穿者|脸|面容|五官|长相|发型|长发|短发|卷发|肤色|身材|表情|姿势|\b(models?|mannequins?|wearer|faces?|hair|skin|pose[sd]?|posing)\b"#,
        options: [.caseInsensitive])

    /// 提到人的那几句去掉（宁可多删一句，不能让别人的脸混进生图）
    static func garmentOnly(_ desc: String) -> String {
        var pieces: [String] = []
        var cur = ""
        let chars = Array(desc)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            let end = "。！？；!?;\n".contains(ch) || (ch == "." && i + 1 < chars.count && chars[i + 1].isWhitespace)
            if end { pieces.append(cur); cur = "" }
        }
        if !cur.isEmpty { pieces.append(cur) }
        let kept = pieces.filter { p in
            !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && person.firstMatch(in: p, range: NSRange(location: 0, length: (p as NSString).length)) == nil
        }
        return kept.joined().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 套装（4.214）

    static func outfitsOf(_ owner: String, _ pid: String? = nil) -> [Row] {
        itemsOf(owner, pid).filter { isOutfit($0) }.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
    }

    /// 一套里还在的那几件
    static func outfitItems(_ o: Row) -> [Row] { o.strings("items").compactMap { get($0) }.filter { !isOutfit($0) } }

    @discardableResult
    static func createOutfit(owner: String = me, name: String, items: [String], by: String = me, fromMsgId: String = "", fromChatId: String = "",
                             note: String = "", pid: String? = nil) throws -> Row {
        var seen = Set<String>()
        let ids = items.filter { !$0.isEmpty && seen.insert($0).inserted }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = Row.new(prefix: "cl", [
            "owner": .string(owner), "personaId": .string(owner == me ? (pid ?? personaId()) : ""), "side": .string(outfit),
            "name": .string(n.isEmpty ? "未命名的一套" : n), "items": .array(ids.map { .string($0) }),
            "occasions": .array([]), "seasons": .array([]), "note": .string(note),
            "by": .string(by), "fromMsgId": .string(fromMsgId), "fromChatId": .string(fromChatId),
            "wornOn": .string(""), "wornCount": .number(0), "lastWorn": .number(0),
        ])
        try Database.shared.put(collection, row)
        return row
    }

    static func outfitFromToday(_ owner: String, name: String, _ pid: String? = nil) throws -> Row? {
        let rows = wornToday(owner, pid)
        guard !rows.isEmpty else { return nil }
        return try createOutfit(owner: owner, name: name, items: rows.map(\.id), pid: pid)
    }

    /// 今天穿这一套：今天穿着的换成这几件（随身的不动），这一套穿过次数加一
    static func wearOutfit(_ id: String) throws {
        guard let o = get(id), isOutfit(o) else { return }
        let d = today()
        let owner = o.string("owner")
        let pid: String? = owner == me ? (o.string("personaId").isEmpty ? nil : o.string("personaId")) : nil
        let want = Set(outfitItems(o).filter { $0.string("side") == "wear" && live($0) }.map(\.id))
        for r in wornToday(owner, pid) where !want.contains(r.id) && !isCarry(r) { try wear(r.id, false) }
        for x in want { try wear(x, true) }
        if o.string("wornOn") != d {
            try patch(id, ["wornOn": .string(d), "wornCount": .number(num(o["wornCount"]) + 1), "lastWorn": .number(nowMs())])
        }
    }

    // MARK: - 会话里的搭配卡片

    /// 在聊穿搭吗（本地词表，不花钱）
    static let wearTopic = try! NSRegularExpression(pattern: "穿|搭配|衣服|裙|裤|鞋|包包|外套|打扮|出门|约会|首饰|项链|耳环|耳饰|戒指|手链|帽子|围巾|outfit|wear|dress",
                                                    options: [.caseInsensitive])
    static let beautyTopic = try! NSRegularExpression(pattern: "化妆|妆|口红|唇|粉底|眼影|腮红|香水|护肤|面膜|防晒|makeup|lipstick|perfume", options: [.caseInsensitive])

    static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// 我这边衣橱里有没有分好类的东西
    static func hasWardrobe(_ pid: String? = nil) -> Bool {
        itemsOf(me, pid).contains { $0.string("side") == "wear" && !$0.string("group").isEmpty && live($0) }
    }

    private static func clean(_ s: String) -> String { s.filter { !$0.isWhitespace }.lowercased() }

    /// 按名字认出那几件：先一模一样的，再互相包含的；同一件不认两次。认不出的 id 为空
    static func matchItems(_ owner: String, _ names: [String], _ pid: String? = nil) -> [(name: String, id: String)] {
        let pool = itemsOf(owner, pid).filter { !isOutfit($0) && live($0) }
        var used = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { (name: String) -> (name: String, id: String) in
            let k = clean(name)
            let free = pool.filter { !used.contains($0.id) }
            let hit = free.first { clean($0.string("name")) == k }
                ?? free.first { let c = clean($0.string("name")); return !c.isEmpty && (k.contains(c) || c.contains(k)) }
            if let hit { used.insert(hit.id) }
            return (name, hit?.id ?? "")
        }
    }

    /// 卡片正文。方括号标记是协议，历史里角色读到的就是这一行
    static func outfitText(_ name: String, _ names: [String]) -> String {
        "[搭配：\(name.isEmpty ? "" : "\(name) | ")\(names.joined(separator: "、"))]"
    }

    /// 「名字 | 甲、乙、丙」拆开。没写竖线就整段是单品
    static func parseOutfit(_ body: String) -> (name: String, names: [String])? {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let bar = t.firstIndex { $0 == "|" || $0 == "｜" }
        let name = bar.map { String(t[..<$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let rest = bar.map { String(t[t.index(after: $0)...]) } ?? t
        let names = rest.components(separatedBy: CharacterSet(charactersIn: "、,，;；/\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : (name, names)
    }

    /// 一张搭配卡片（未落库）。角色写的搭的是我衣帽间里的东西；我发的搭的是对方的。群里不接
    static func outfitMessage(chat: Chat, role: Message.Role, authorId: String, name: String, names: [String], turnId: String? = nil) -> Message? {
        guard !names.isEmpty else { return nil }
        let owner = role == .user ? (chat.characterIds.first ?? "") : me
        guard !owner.isEmpty else { return nil }
        let items = matchItems(owner, names, chat.personaId.isEmpty ? nil : chat.personaId)
        var m = Message.new(chatId: chat.id, role: role, authorId: authorId, content: outfitText(name, items.map { $0.name }), kind: "outfit", turnId: turnId)
        m.row["outfitName"] = .string(name)
        m.row["outfitOwner"] = .string(owner)
        m.row["outfitItems"] = .array(items.map { .object(["name": .string($0.name), "id": .string($0.id)]) })
        // 这段会话里有还没揭晓的穿搭盲盒：角色这一套也封着
        if role == .char, let box = openDresscode(chat.id) {
            m.row["sealed"] = .bool(true)
            m.row["dresscodeId"] = .string(box.id)
        }
        return m
    }

    private static func appendToChat(_ m: Message) throws -> Message {
        let out = try Repo.append(m)
        if var c = try Repo.chat(m.chatId) { c.row["lastMessageAt"] = .number(Date().millis); c.row.touch(); try Repo.save(c) }
        NotificationCenter.default.post(name: .eiraChatChanged, object: m.chatId)
        return out
    }

    /// 和这个角色的私聊（当前身份下）
    static func soloChat(_ charId: String) -> Chat? { Diary.chatWith(charId) }

    /// 在角色的衣帽间里替它挑好一套，发到和它的会话里
    @discardableResult
    static func sendOutfit(_ id: String) throws -> Message? {
        guard let o = get(id), isOutfit(o), o.string("owner") != me else { return nil }
        guard let chat = soloChat(o.string("owner")) else { throw StoreError(message: "还没有和该角色的会话") }
        let names = outfitItems(o).map { $0.string("name") }
        guard !names.isEmpty else { throw StoreError(message: "这一套里没有东西") }
        guard let m = outfitMessage(chat: chat, role: .user, authorId: me, name: o.string("name"), names: names) else { return nil }
        return try appendToChat(m)
    }

    static func outfitOfMsg(_ msgId: String) -> Row? {
        ((try? Database.shared.all(collection)) ?? []).first { isOutfit($0) && $0.string("fromMsgId") == msgId }
    }

    /// 卡片存成一套。存过就给存过的那一套；一件都没认出来就不存
    @discardableResult
    static func keepOutfit(_ m: Message) throws -> Row? {
        guard m.kind == "outfit" else { return nil }
        if let had = outfitOfMsg(m.id) { return had }
        let items = (m.row["outfitItems"]?.array ?? []).compactMap { $0["id"]?.string }.filter { !$0.isEmpty && get($0) != nil }
        guard !items.isEmpty else { return nil }
        let owner = m.row.string("outfitOwner").isEmpty ? me : m.row.string("outfitOwner")
        return try createOutfit(owner: owner, name: m.row.string("outfitName"), items: items,
                                by: m.role == .char ? m.authorId : me, fromMsgId: m.id, fromChatId: m.chatId)
    }

    // MARK: - 好久没穿（4.214）

    static func idleCfg(_ s: AppSettings = .load()) -> (days: Int, gap: Int) {
        (max(0, Int(s.raw["closetIdleDays"]?.number ?? 60)), max(0, Int(s.raw["closetIdleGap"]?.number ?? 7)))
    }

    static func idleOf(_ owner: String, _ pid: String?, now: Double = nowMs()) -> [Row] {
        let days = idleCfg().days
        guard days > 0 else { return [] }
        return itemsOf(owner, pid).filter { r in
            r.string("side") == "wear" && !r.string("group").isEmpty && !isCarry(r) && live(r) && num(r["wornCount"]) > 0
                && num(r["lastWorn"]) > 0 && now - num(r["lastWorn"]) >= Double(days) * day
        }.sorted { num($0["lastWorn"]) < num($1["lastWorn"]) }
    }

    /// 这一轮要告诉角色的那一件：一次一件，两次之间至少隔 gap 天，同一件一段闲置只递一次
    static func takeIdle(_ pid: String?, now: Double = nowMs()) -> Row? {
        let rows = idleOf(me, pid, now: now)
        guard !rows.isEmpty else { return nil }
        let d = dateKey(now)
        if let shown = rows.first(where: { num($0["idleAt"]) > 0 && dateKey(num($0["idleAt"])) == d }) { return shown }
        let gap = idleCfg().gap
        let last = itemsOf(me, pid).map { num($0["idleAt"]) }.max() ?? 0
        if last > 0 && now - last < Double(gap) * day { return nil }
        guard let next = rows.first(where: { !(num($0["idleAt"]) > num($0["lastWorn"])) }) else { return nil }
        return (try? patch(next.id, ["idleAt": .number(now)])) ?? next
    }

    // MARK: - 物品的回忆（4.216，只由用户记）

    @discardableResult
    static func addMemory(_ id: String, text: String, at: Double = 0, chatId: String = "", msgId: String = "") throws -> [String: JSONValue]? {
        guard let r = get(id) else { return nil }
        let t = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let m: [String: JSONValue] = ["id": .string(Ids.make("mm")), "at": .number(at > 0 ? at : nowMs()), "text": .string(t),
                                      "chatId": .string(chatId), "msgId": .string(msgId)]
        try patch(id, ["memories": .array((r["memories"]?.array ?? []) + [.object(m)])])
        return m
    }

    static func dropMemory(_ id: String, _ memId: String) throws {
        guard let r = get(id) else { return }
        try patch(id, ["memories": .array((r["memories"]?.array ?? []).filter { $0["id"]?.string != memId })])
    }

    /// 最近的 n 条（0 为全部），新的在前
    static func memoriesOf(_ r: Row, _ n: Int = 0) -> [[String: JSONValue]] {
        let all = (r["memories"]?.array ?? []).compactMap(\.object).sorted { ($0["at"]?.number ?? 0) > ($1["at"]?.number ?? 0) }
        return n > 0 ? Array(all.prefix(n)) : all
    }

    // MARK: - 在会话里用一件东西（4.216）

    static func actionsFor(_ r: Row) -> [String] {
        let g = r.string("group")
        if g == "scent" { return ["帮你喷上", "请你帮我喷上", "喷上"] }
        if ["lip", "eye", "cheek", "base"].contains(g) { return ["帮你涂上", "请你帮我涂上", "涂上"] }
        if g == "skin" || g == "hair" { return ["帮你抹上", "请你帮我抹上", "抹上"] }
        if g == "jewelry" { return ["帮你戴上", "请你帮我戴上", "戴上"] }
        if g == "acc" {
            return r.string("sub") == "领带" || r.string("sub") == "围巾" ? ["帮你系上", "请你帮我系上", "系上"] : ["帮你戴上", "请你帮我戴上", "戴上"]
        }
        if g == carry { return ["递给你", "拿出来给你看"] }
        if r.string("side") == "wear" { return ["帮你穿上", "请你帮我穿上", "换上", "借给你穿"] }
        return ["递给你", "拿出来给你看"]
    }

    /// 能发到哪几段会话：一对一的、当前身份的，这件东西的主人（是角色的话）排在最前
    static func useTargets(_ r: Row?) -> [Chat] {
        let pid = personaId()
        let list = ((try? Repo.chats()) ?? []).filter { $0.characterIds.count == 1 && !$0.row.bool("group") && ($0.personaId.isEmpty || $0.personaId == pid) }
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
        guard let r, r.string("owner") != me else { return list }
        let o = r.string("owner")
        return list.filter { $0.characterIds.first == o } + list.filter { $0.characterIds.first != o }
    }

    @discardableResult
    static func useInChat(_ id: String, chatId: String, action: String) throws -> Message {
        guard let r = get(id), let chat = try Repo.chat(chatId) else { throw StoreError(message: "这件东西或这段会话已经不在了") }
        let act = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !act.isEmpty else { throw StoreError(message: "请选择或填写一个动作") }
        let theirs = r.string("owner") != me && r.string("owner") == chat.characterIds.first
        let desc = garmentOnly(r.string("desc"))
        var m = Message.new(chatId: chatId, role: .user, authorId: me,
                            content: "[动作：\(act)「\(r.string("name"))」\(theirs ? "（你的）" : "")\(desc.isEmpty ? "" : "（\(desc)）")]", kind: "groom")
        m.row["itemId"] = .string(id)
        m.row["itemName"] = .string(r.string("name"))
        m.row["action"] = .string(act)
        return try appendToChat(m)
    }

    // MARK: - 分享卡片（4.344 第三步）

    static let shareFields: [ClosetKinds.Tag] = [
        .init(id: "photo", label: "照片"), .init(id: "desc", label: "描述"), .init(id: "price", label: "价格"), .init(id: "channel", label: "渠道"),
        .init(id: "buyAt", label: "购入日期"), .init(id: "worn", label: "穿过次数"), .init(id: "washed", label: "上次清洗"), .init(id: "care", label: "保养"),
    ]

    static func priceText(_ n: Double) -> String {
        if n == n.rounded() { return "\(Int(n)) 元" }
        var t = String(format: "%.2f", n)
        if t.hasSuffix("0") { t.removeLast() }
        return "\(t) 元"
    }

    /// 上装 · 衬衫
    static func categoryOf(_ r: Row) -> String {
        [ClosetKinds.group(r.string("group"))?.label ?? "", r.string("sub")].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 这一件每一项能分享的内容：card 是卡片上那一截，prompt 是角色读到的那一截。没填写的那一项没有
    static func shareParts(_ r: Row) -> [String: (card: String, prompt: String)] {
        var out: [String: (card: String, prompt: String)] = [:]
        if !r.string("imageId").isEmpty { out["photo"] = ("", "") }
        let desc = r.string("desc").trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { out["desc"] = (desc, "描述 \(desc)") }
        if num(r["price"]) > 0 { out["price"] = (priceText(num(r["price"])), "价格 \(priceText(num(r["price"])))") }
        if !r.string("channel").trimmingCharacters(in: .whitespaces).isEmpty { out["channel"] = (r.string("channel"), "购买渠道 \(r.string("channel"))") }
        if !r.string("buyAt").isEmpty { out["buyAt"] = ("\(r.string("buyAt")) 购入", "购入日期 \(r.string("buyAt"))") }
        if num(r["wornCount"]) > 0 {
            let t = "\(isCarry(r) ? "用过" : "穿过") \(Int(num(r["wornCount"]))) 次"
            out["worn"] = (t, t)
        }
        if !r.string("washedAt").isEmpty { out["washed"] = ("\(r.string("washedAt")) 洗过", "上次清洗 \(r.string("washedAt"))") }
        if !r.string("careNote").trimmingCharacters(in: .whitespaces).isEmpty {
            let t = "\(r.string("careNote"))\(r.string("caredAt").isEmpty ? "" : "，上次 \(r.string("caredAt"))")"
            out["care"] = ("保养：\(t)", "保养 \(t)")
        }
        return out
    }

    struct Share: Equatable { var photo: Bool; var meta: String; var content: String; var note: String }

    static func shareOf(_ r: Row, picks: [String], note: String = "", photoDesc: String = "", chat: Chat? = nil) -> Share {
        let parts = shareParts(r)
        let on = shareFields.map(\.id).filter { picks.contains($0) && parts[$0] != nil }
        let cat = categoryOf(r)
        let theirs = chat != nil && r.string("owner") != me && r.string("owner") == chat?.characterIds.first
        let meta = ([cat] + on.map { parts[$0]!.card }).filter { !$0.isEmpty }.joined(separator: " · ")
        let pd = photoDesc.replacingOccurrences(of: #"[\]】\n]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let line = (["衣帽间：\(r.string("name"))\(theirs ? "（你的）" : "")", cat] + on.map { parts[$0]!.prompt } + [pd.isEmpty ? "" : "照片 \(pd)"])
            .filter { !$0.isEmpty }.joined(separator: " | ")
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return Share(photo: on.contains("photo"), meta: meta, content: "[\(line)]\(n.isEmpty ? "" : "\n\(n)")", note: n)
    }

    /// 发出去：一条 closetshare 消息，不调接口，角色在下一次回复时读到
    @discardableResult
    static func shareToChat(_ id: String, chatId: String, picks: [String], note: String = "") throws -> Message {
        guard let r = get(id), let chat = try Repo.chat(chatId) else { throw StoreError(message: "这件东西或这段会话已经不在了") }
        let s = shareOf(r, picks: picks, note: note, chat: chat)
        var m = Message.new(chatId: chatId, role: .user, authorId: me, content: s.content, kind: "closetshare")
        m.row["itemId"] = .string(id)
        m.row["itemName"] = .string(r.string("name"))
        m.row["shareMeta"] = .string(s.meta)
        m.row["shareNote"] = .string(s.note)
        m.row["imageId"] = s.photo && !r.string("imageId").isEmpty ? .string(r.string("imageId")) : .null
        m.row["sharedPhoto"] = .bool(s.photo)
        m.row["lookedAt"] = .bool(false)
        return try appendToChat(m)
    }

    // MARK: - 穿搭盲盒（4.216）

    static func openDresscode(_ chatId: String) -> Message? {
        ((try? Repo.messages(chatId: chatId)) ?? []).filter { $0.kind == "dresscode" && !$0.row.bool("revealed") }
            .max { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    static func startDresscode(_ outfitId: String, theme: String) throws -> Message? {
        guard let o = get(outfitId), isOutfit(o), o.string("owner") != me else { return nil }
        let t = theme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw StoreError(message: "请填写主题") }
        guard let chat = useTargets(o).first(where: { $0.characterIds.first == o.string("owner") }) else { throw StoreError(message: "还没有和该角色的会话") }
        let items = outfitItems(o)
        guard !items.isEmpty else { throw StoreError(message: "这一套里没有东西") }
        var m = Message.new(chatId: chat.id, role: .user, authorId: me,
                            content: "[穿搭主题：\(t)]（我按这个主题为你挑好了一套，揭晓前不告诉你。也请你按这个主题为我挑一套。）", kind: "dresscode")
        m.row["theme"] = .string(t)
        m.row["outfitName"] = .string(o.string("name"))
        m.row["outfitOwner"] = .string(o.string("owner"))
        m.row["outfitItems"] = .array(items.map { .object(["name": .string($0.string("name")), "id": .string($0.id)]) })
        m.row["revealed"] = .bool(false)
        return try appendToChat(m)
    }

    @discardableResult
    static func revealDresscode(_ msgId: String) throws -> Message? {
        guard var m = try Database.shared.get(Collections.messages, id: msgId), m.string("kind") == "dresscode", !m.bool("revealed") else { return nil }
        m["revealed"] = .bool(true)
        m.touch()
        try Database.shared.put(Collections.messages, m)
        let chatId = m.string("chatId")
        let theirs = try Repo.messages(chatId: chatId).filter { $0.kind == "outfit" && $0.row.string("dresscodeId") == msgId }
        for var x in theirs { x.row["sealed"] = .bool(false); x.row.touch(); try Repo.save(x) }
        func names(_ v: JSONValue?) -> String { (v?.array ?? []).compactMap { $0["name"]?.string }.joined(separator: "、") }
        let mine = names(m["outfitItems"])
        let back = theirs.map { names($0.row["outfitItems"]) }.filter { !$0.isEmpty }.joined(separator: "；")
        let n = Message.new(chatId: chatId, role: .user, authorId: me,
                            content: "[穿搭揭晓：\(m.string("theme"))｜我为你挑的：\(mine)\(back.isEmpty ? "" : "｜你为我挑的：\(back)")]", kind: "notice")
        return try appendToChat(n)
    }

    // MARK: - 剧情里的衣帽间（网页版 closet-story.js，4.217）

    private static func find(_ rows: [Row], _ name: String) -> Row? {
        let k = clean(name)
        guard !k.isEmpty else { return nil }
        return rows.first { clean($0.string("name")) == k }
            ?? rows.first { let c = clean($0.string("name")); return !c.isEmpty && (k.contains(c) || c.contains(k)) }
    }

    private static func wearable(_ rows: [Row]) -> [Row] { rows.filter { $0.string("side") == "wear" && !isOutfit($0) && live($0) } }

    /// 改之前是什么样，撤回时照着改回去
    private static func snap(_ r: Row) -> JSONValue {
        .object(["id": .string(r.id), "lent": r["lent"] ?? .null, "wornOn": .string(r.string("wornOn")), "wornCount": .number(num(r["wornCount"])),
                 "lastWorn": .number(num(r["lastWorn"])), "wornDates": .array(r.strings("wornDates").map { .string($0) })])
    }

    struct Act: Equatable { var kind: String; var name: String; var itemId: String; var text: String; var undo: JSONValue }

    /// 换上、借走、借给你、归还。认不出是哪一件就当没写过（返回 nil）
    static func act(_ kind: String, _ body: String, charId: String, pid: String? = nil) throws -> Act? {
        guard let char = try Repo.character(charId) else { return nil }
        let name = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let who = char.name
        let p = pid ?? personaId()
        switch kind {
        case "换上":
            guard let r = find(wearable(itemsOf(charId).filter { !lentOut($0) } + borrowedBy(charId, p)), name) else { return nil }
            let u = snap(r)
            try wear(r.id, true)
            return Act(kind: kind, name: r.string("name"), itemId: r.id, text: "\(who)换上了\(r.string("owner") == charId ? "" : "借来的")\(r.string("name"))", undo: u)
        case "借走":
            guard let r = find(wearable(itemsOf(me, p).filter { !lentOut($0) }), name) else { return nil }
            let u = snap(r)
            try lend(r.id, to: charId)
            return Act(kind: kind, name: r.string("name"), itemId: r.id, text: "\(who)借走了你的\(r.string("name"))", undo: u)
        case "借给你":
            guard let r = find(wearable(itemsOf(charId).filter { !lentOut($0) }), name) else { return nil }
            let u = snap(r)
            try lend(r.id, to: me)
            return Act(kind: kind, name: r.string("name"), itemId: r.id, text: "\(who)把\(r.string("name"))借给了你", undo: u)
        case "归还":
            guard let r = find(lentBetween(charId, p), name) else { return nil }
            let u = snap(r)
            try giveBack(r.id)
            return Act(kind: kind, name: r.string("name"), itemId: r.id,
                       text: r.string("owner") == charId ? "你把\(r.string("name"))还给了\(who)" : "\(who)把\(r.string("name"))还给了你", undo: u)
        default:
            return nil
        }
    }

    static func capsOff(_ s: AppSettings = .load()) -> Set<String> { Set((s.raw["capsOff"]?.array ?? []).compactMap(\.string)) }

    /// 回复里的 [搭配：…] 与换上、借走、借给你、归还（未落库）。群里不接：搭给谁、借给谁说不清。认不出就当没写过
    static func effect(_ p: ReplyParser.Part, chat: Chat, char: Character, turnId: String) throws -> Message? {
        guard !chat.isGroup, chat.characterIds.count <= 1 else { return nil }
        let off = capsOff()
        if p.type == .outfit {
            guard !off.contains("outfit") else { return nil }
            let names = (p.extra ?? "").components(separatedBy: "、").filter { !$0.isEmpty }
            return outfitMessage(chat: chat, role: .char, authorId: char.id, name: p.text, names: names, turnId: turnId)
        }
        guard !off.contains("closetact"),
              let r = try act(p.extra ?? "", p.text, charId: char.id, pid: chat.personaId.isEmpty ? nil : chat.personaId) else { return nil }
        var m = Message.new(chatId: chat.id, role: .char, authorId: char.id, content: "[\(r.text)]", kind: "notice", turnId: turnId)
        m.row["closetUndo"] = r.undo
        return m
    }

    /// 撤回一件事：把那一件改回做之前的样子
    static func undo(_ u: JSONValue?) throws {
        guard let u, let id = u["id"]?.string, !id.isEmpty, get(id) != nil else { return }
        var p: [String: JSONValue] = ["lent": u["lent"] ?? .null, "wornOn": u["wornOn"] ?? .string(""),
                                      "wornCount": u["wornCount"] ?? .number(0), "lastWorn": u["lastWorn"] ?? .number(0)]
        if let d = u["wornDates"], d.array != nil { p["wornDates"] = d }
        try patch(id, p)
    }

    // MARK: - 进聊天提示词（网页版 context/closet.js）

    private static func tagsOf(_ r: Row) -> String {
        let whereText = [ClosetKinds.group(r.string("group"))?.label ?? "", r.string("sub")].filter { !$0.isEmpty }.joined(separator: " / ")
        let colors = r.strings("colors").map { ClosetKinds.label(ClosetKinds.colors, $0) }.filter { !$0.isEmpty }.joined(separator: "、")
        return [whereText, colors, r.string("shade")].filter { !$0.isEmpty }.joined(separator: "; ")
    }

    private static func charName(_ id: String) -> String? { ((try? Repo.character(id)) ?? nil)?.name }

    private static func originOf(_ r: Row, _ char: Character?, _ userName: String) -> String {
        if r.string("source") == "gift" && !r.string("giver").isEmpty {
            let g = r.string("giver")
            let from = g == char?.id ? "you" : g == me ? userName : (charName(g) ?? "someone")
            return "a gift from \(from)\(num(r["giftAt"]) > 0 ? ", \(dateKey(num(r["giftAt"])))" : "")"
        }
        if r.string("source") == "made" { return r.string("with") == char?.id ? "made together with you" : "made together with someone" }
        return ""
    }

    private static func loanOf(_ r: Row, _ wearer: String, _ char: Character?, _ userName: String) -> String {
        guard lentOut(r), r.string("owner") != wearer else { return "" }
        let o = r.string("owner")
        let whose = o == char?.id ? "you" : o == me ? userName : (charName(o) ?? "someone")
        return "borrowed from \(whose) on \(dateKey(r["lent"]?["at"]?.number ?? 0))"
    }

    private static func memLine(_ r: Row, _ n: Int) -> String {
        memoriesOf(r, n).map { "remembered \(dateKey($0["at"]?.number ?? 0)): 「\($0["text"]?.string ?? "")」" }.joined(separator: "; ")
    }

    private static func itemLine(_ r: Row, _ char: Character?, _ userName: String, wearer: String = "", mems: Int = -1) -> String {
        let tags = tagsOf(r)
        let origin = [originOf(r, char, userName), loanOf(r, wearer, char, userName), mems >= 0 ? memLine(r, mems) : ""]
            .filter { !$0.isEmpty }.joined(separator: "; ")
        let desc = garmentOnly(r.string("desc"))
        return "- \(r.string("name"))\(tags.isEmpty ? "" : " (\(tags))")\(desc.isEmpty ? "" : ": \(desc)")\(origin.isEmpty ? "" : "; \(origin)")"
    }

    private static func alertLine(_ r: Row, _ f: Flags) -> String {
        var bits: [String] = []
        if let l = f.low { bits.append("about \(l.pct)% left; at the recorded usage it runs out in about \(l.daysLeft) days") }
        if let e = f.exp {
            bits.append(e.daysLeft < 0 ? "past its use-by date (\(dateKey(e.at)))" : "use-by date \(dateKey(e.at)), in \(e.daysLeft) days")
        }
        let t = tagsOf(r)
        return "- \(r.string("name"))\(t.isEmpty ? "" : " (\(t))"): \(bits.joined(separator: "; "))"
    }

    /// [衣帽间] 那一段。只写事实；清单只在聊到穿搭、化妆时带；快用完、好久没穿的频率由代码管
    static func block(char: Character?, persona: Persona?, msgs: [Message], settings s: AppSettings, now: Double = nowMs()) -> String {
        let pid = persona?.id
        let user = persona?.name ?? "They"
        let limit = max(0, Int((s.raw["closetListMax"]?.number ?? 8).rounded()))
        let mems = max(0, Int((s.raw["closetMemMax"]?.number ?? 2).rounded()))
        let talk = msgs.filter { $0.role == .user }.suffix(3).map(\.content).joined(separator: "\n")
        var out: [String] = []
        func todayPart(_ who: String?, _ head: String, _ bag: String) {
            guard let who, !who.isEmpty else { return }
            let rows = wornToday(who, who == me ? pid : nil)
            let on = rows.filter { !isCarry($0) }, carried = rows.filter { isCarry($0) }
            if !on.isEmpty { out.append(head); out += on.map { itemLine($0, char, user, wearer: who, mems: mems) } }
            if !carried.isEmpty { out.append(bag); out += carried.map { itemLine($0, char, user, wearer: who, mems: mems) } }
        }
        todayPart(me, "## What \(user) is wearing today", "## In \(user)'s bag today")
        todayPart(char?.id, "## What you are wearing today", "## In your bag today")

        let loans = char.map { lentBetween($0.id, pid) } ?? []
        if !loans.isEmpty {
            out.append("## Lent between you and \(user), not yet returned")
            out += loans.map { r in
                "- \(r.string("name")): \(r.string("owner") == me ? "\(user)'s, with you" : "yours, with \(user)") since \(dateKey(r["lent"]?["at"]?.number ?? 0))"
            }
        }
        if matches(wearTopic, talk) {
            let a = listLines(me, pid, side: "wear", limit: limit)
            if !a.isEmpty { out.append("## \(user)'s wardrobe"); out += a }
            let b = char.map { listLines($0.id, nil, side: "wear", limit: limit) } ?? []
            if !b.isEmpty { out.append("## Your own wardrobe"); out += b }
        }
        if matches(beautyTopic, talk) {
            let a = listLines(me, pid, side: "beauty", limit: limit)
            if !a.isEmpty { out.append("## \(user)'s dressing table"); out += a }
        }
        let alerts = takeAlerts(pid, now: now)
        if !alerts.isEmpty { out.append("## On \(user)'s dressing table"); out += alerts.map { alertLine($0.item, $0.flags) } }
        if let idle = takeIdle(pid, now: now) {
            let days = Int(((num(idle["idleAt"]) - num(idle["lastWorn"])) / day).rounded(.down))
            let t = tagsOf(idle)
            out.append("## \(user) has not worn this for a while")
            out.append("- \(idle.string("name"))\(t.isEmpty ? "" : " (\(t))"): last worn \(dateKey(num(idle["lastWorn"]))), \(days) days ago")
        }
        guard !out.isEmpty else { return "" }
        return "\n\n[衣帽间]\n\(out.joined(separator: "\n"))\n"
            + "These come from their own records. Anything not listed here is unknown; do not invent items.\n"
    }
}
