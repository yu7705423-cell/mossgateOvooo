import Foundation

/// 梦境（网页版 system/dream.js、ai/tasks/dream.js、ai/context/dream.js，ARCHITECTURE 4.442、4.444）。
///
/// 角色每晚一个梦：「原料」从它的记忆、进行中的事、心愿里本地抽（不花钱），「拼法」是程序抽的扭曲操作，写成具体指令；
/// 模型只负责把它们写成一个梦，一次只调一次接口。醒来记得多少由本地掷一次骰子（完整 / 碎片 / 只剩感觉），过了中午再淡一档。
///
/// 每晚自动那一次：开关挂在角色身上（char.dreamAuto，梦境 app 里该角色的页面），默认关，登记在 ExtraCalls。
/// 先 Daily.claim("dream") 占住当天、在角色身上记 dreamAutoAt，再发请求；失败当天写明原因，明天再自动试。
/// 「现在做一个梦」是手动的，不经过 claim。
///
/// 一行（dreams 域，前缀 dm，按 charId 索引）：charId、personaId、date、title、titleTrans、scenes [{ text, textTrans? }]、text、
/// recall、recallTrans、mood、materials [{ key, kind, id, text }]、plan { bizarre, scenes, returned }、source（auto / now）、memoryId、
/// fragments、recallLevel（full / fragment / trace）、kept。
enum Dream {
    static let collection = "dreams"

    static let kinds: [String: String] = ["recent": "最近的事", "open": "进行中的事", "wish": "心愿", "distant": "久远的记忆", "user": "用户"]

    struct Level: Identifiable, Equatable { var id: String; var label: String; var desc: String }

    static let bizarre: [(value: Int, label: String, desc: String)] = [
        (0, "0", "近乎白天的重放，没有扭曲"), (1, "1", "约一半的幕各有一处扭曲"),
        (2, "2", "每一幕一处扭曲"), (3, "3", "每一幕两处扭曲，允许物理失效"),
    ]

    static let recall: [Level] = [
        Level(id: "full", label: "完整", desc: "记得整个梦"),
        Level(id: "fragment", label: "碎片", desc: "只剩几个零散的画面，接不上"),
        Level(id: "trace", label: "只剩感觉", desc: "只记得情绪，想不起梦到什么"),
    ]
    static func recallLabel(_ id: String) -> String { recall.first { $0.id == id }?.label ?? "" }
    static let oddsDefault: [String: Int] = ["full": 20, "fragment": 60, "trace": 20]
    static let fadeHour = 12
    static let hourDefault = 6, actsDefault = 3, wordsDefault = 3000

    typealias RNG = () -> Double
    static let random: RNG = { Double.random(in: 0..<1) }

    // MARK: - 角色身上的几个旋钮

    private static func clampInt(_ v: JSONValue?, _ def: Int, _ lo: Int, _ hi: Int) -> Int {
        guard let n = v?.number ?? v?.string.flatMap({ Double($0) }), n.isFinite else { return def }
        return min(hi, max(lo, Int(n.rounded())))
    }

    static func isAuto(_ c: Character?) -> Bool { c?.row["dreamAuto"]?.bool == true }
    static func hourOf(_ c: Character?) -> Int { clampInt(c?.row["dreamHour"], hourDefault, 0, 23) }
    static func bizarreOf(_ c: Character?) -> Int { clampInt(c?.row["dreamBizarre"], 1, 0, 3) }
    /// 幕数与字数不设上限；0 按默认
    static func actsOf(_ c: Character?) -> Int { let n = clampInt(c?.row["dreamActs"], actsDefault, 0, 99); return n == 0 ? actsDefault : n }
    static func wordsOf(_ c: Character?) -> Int { let n = clampInt(c?.row["dreamWords"], wordsDefault, 0, 100_000); return n == 0 ? wordsDefault : n }
    /// 写进对话：开或关。老数据里的 'brief'、'full' 都算开着
    static func injectOn(_ c: Character?) -> Bool {
        guard let v = c?.row["dreamInject"] else { return false }
        if let s = v.string { return !s.isEmpty && s != "off" }
        if let b = v.bool { return b }
        return !v.isNull && v.number != 0
    }
    static func memoryOn(_ c: Character?) -> Bool { c?.row["dreamMemory"]?.bool == true }
    static func fadeOn(_ c: Character?) -> Bool { c?.row["dreamFade"]?.bool != false }

    /// 三档的概率（按比例算，加起来不必是 100）。都填 0 按默认
    static func oddsOf(_ c: Character?) -> [String: Int] {
        let o = c?.row["dreamOdds"]?.object ?? [:]
        var out: [String: Int] = [:]
        for id in ["full", "fragment", "trace"] {
            let n = o[id]?.number ?? o[id]?.string.flatMap { Double($0) } ?? Double(oddsDefault[id] ?? 0)
            out[id] = n.isFinite ? max(0, Int(n.rounded())) : 0
        }
        return out.values.reduce(0, +) > 0 ? out : oddsDefault
    }

    /// 醒来时掷一次
    static func roll(_ c: Character?, _ rng: RNG = random) -> String {
        let o = oddsOf(c)
        let total = Double(o.values.reduce(0, +))
        var x = rng() * total
        for r in recall {
            let w = Double(o[r.id] ?? 0)
            if x < w { return r.id }
            x -= w
        }
        return "trace"
    }

    static func shuffle<T>(_ list: [T], _ rng: RNG) -> [T] {
        var a = list
        guard a.count > 1 else { return a }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = min(i, Int((rng() * Double(i + 1)).rounded(.down)))
            a.swapAt(i, j)
        }
        return a
    }

    static func pickN<T>(_ list: [T], _ n: Int, _ rng: RNG) -> [T] { Array(shuffle(list, rng).prefix(max(0, n))) }

    /// 碎片档留哪几个画面：两到三个，按原来的先后。模型没给碎片时从各幕里各取一句
    static func keepFragments(_ fragments: [String], _ scenes: [String], _ rng: RNG = random) -> [String] {
        var pool = fragments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if pool.isEmpty {
            pool = scenes.map { firstSentence($0) }.filter { !$0.isEmpty }
        }
        let n = min(pool.count, 2 + (rng() < 0.5 ? 0 : 1))
        let idx = Array(shuffle(Array(pool.indices), rng).prefix(n)).sorted()
        return idx.map { pool[$0] }
    }

    private static func firstSentence(_ s: String) -> String {
        var out = ""
        for ch in s {
            out.append(ch)
            if "。！？!?.".contains(ch) { break }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lower(_ id: String) -> String { id == "full" ? "fragment" : "trace" }

    private static func parts(_ at: Date, _ c: Character?) -> (day: String, hour: Int) {
        let s = AppSettings.load()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Clock.zone(Clock.charZone(c, s))
        let d = cal.dateComponents([.year, .month, .day, .hour], from: at)
        return (String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0), d.hour ?? 0)
    }

    /// 此刻还记得多少。不是今天的梦、没掷过的老梦按完整算
    static func levelNow(_ row: Row, _ c: Character?, at: Date = Date()) -> String {
        let lv = row.string("recallLevel")
        let base = recall.contains(where: { $0.id == lv }) ? lv : "full"
        if !fadeOn(c) || base == "trace" { return base }
        let p = parts(at, c)
        return p.day != row.string("date") || p.hour >= fadeHour ? lower(base) : base
    }

    static func sceneTexts(_ row: Row) -> [String] { (row["scenes"]?.array ?? []).compactMap { $0["text"]?.string ?? $0.string }.filter { !$0.isEmpty } }

    /// 角色此刻记得的那一份。full 时 lines 是各幕全文，trace 时为空
    static func remembered(_ row: Row, _ c: Character?, at: Date = Date()) -> (level: String, lines: [String], mood: String) {
        let level = levelNow(row, c, at: at)
        let mood = row.string("mood")
        switch level {
        case "full": return (level, sceneTexts(row), mood)
        case "fragment":
            let kept = row.strings("kept")
            return (level, kept.isEmpty ? keepFragments(row.strings("fragments"), sceneTexts(row), { 0.5 }) : kept, mood)
        default: return (level, [], mood)
        }
    }

    /// 记成记忆时用的那一句：按醒来时记得的版本，忘掉的部分不进记忆
    static func memoryText(_ row: Row) -> String {
        let lv = row.string("recallLevel").isEmpty ? "full" : row.string("recallLevel")
        if lv == "full" {
            return [row.string("recall"), row.string("title"), row.string("text")].first { !$0.isEmpty } ?? ""
        }
        if lv == "fragment" { return "梦见了一些零散的片段：\(row.strings("kept").joined(separator: "；"))" }
        return "做了一个梦，醒来只记得\(row.string("mood").isEmpty ? "一种说不清的感觉" : "「\(row.string("mood"))」的感觉")"
    }

    /// 角色那边醒来的那一天（与日程一致：深夜算前一天）
    static func todayOf(_ c: Character?, _ at: Date = Date()) -> String { DayPlan.dateKey(c, at) }

    // MARK: - 读

    static func personaId() -> String { Diary.personaId() }

    private static func samePersona(_ r: Row, _ pid: String) -> Bool {
        let p = r.string("personaId")
        return (p.isEmpty ? pid : p) == pid
    }

    static func get(_ id: String) -> Row? { (try? Database.shared.get(collection, id: id)) ?? nil }

    /// 某个角色的梦（当前身份下），新的在前
    static func ofChar(_ charId: String, _ pid: String = personaId()) -> [Row] {
        ((try? Database.shared.all(collection, where: charId)) ?? []).filter { samePersona($0, pid) }.sorted {
            $0.string("date") != $1.string("date") ? $0.string("date") > $1.string("date") : ($0.created ?? 0) > ($1.created ?? 0)
        }
    }

    static func on(_ charId: String, _ date: String, _ pid: String = personaId()) -> Row? { ofChar(charId, pid).first { $0.string("date") == date } }
    static func last(_ charId: String, _ pid: String = personaId()) -> Row? { ofChar(charId, pid).first }

    /// 做过梦的角色（当前身份下），按最近一个梦排
    static func dreamers(_ pid: String = personaId()) -> [Character] {
        var seen: [String: Double] = [:]
        for d in (try? Database.shared.all(collection)) ?? [] where samePersona(d, pid) {
            let t = d.created ?? 0
            if (seen[d.string("charId")] ?? -1) < t { seen[d.string("charId")] = t }
        }
        return seen.sorted { $0.value > $1.value }.compactMap { (try? Repo.character($0.key)) ?? nil }
    }

    /// 梦境 app 第一屏的角色：和当前身份有私聊的，外加做过梦的
    static func choices(_ pid: String = personaId()) -> [Character] {
        var ids = dreamers(pid).map(\.id)
        for c in (try? Repo.characters()) ?? [] where (c.parentId ?? "").isEmpty && !c.isNpc && !ids.contains(c.id) {
            if Diary.chatWith(c.id, pid) != nil { ids.append(c.id) }
        }
        return ids.compactMap { (try? Repo.character($0)) ?? nil }
    }

    static func remove(_ id: String) throws { try Database.shared.delete(collection, id: id) }

    // MARK: - 原料（五路来源，本地抽）

    struct Material: Equatable {
        var key: String
        var kind: String
        var id: String
        var text: String
        var json: JSONValue { .object(["key": .string(key), "kind": .string(kind), "id": .string(id), "text": .string(text)]) }
    }

    private static let keys = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)

    static func draw(_ char: Character, _ pid: String = personaId(), rng: RNG = random, now: Date = Date()) -> [Material] {
        let nowMs = now.millis, dayMs = 86_400_000.0
        let mems = ((try? Knowledge.memories(charId: char.id, personaId: pid)) ?? []).filter { $0.fateHidden.isEmpty }
        // 梦记成的那条记忆不再当原料：否则第二晚梦见第一晚的梦
        let all = mems.filter { $0.supersededBy.isEmpty && $0.row.string("dreamId").isEmpty && $0.kind != .open
            && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let recent = all.filter { nowMs - $0.at <= 3 * dayMs }
        let distant = all.filter { nowMs - $0.at > 30 * dayMs }
        let openMems = mems.filter { $0.kind == .open && $0.status == "open" && $0.supersededBy.isEmpty }
            .sorted { $0.at < $1.at }.filter { ChatPrompt.isOpen($0, now: now) }
        // 临近到期的那一件一定在；再随机一件
        func due(_ m: Memory) -> Double { let d = ChatPrompt.dueTime(m); return d > 0 ? d : .infinity }
        let nearest = openMems.min { due($0) < due($1) }
        let openPick = nearest.map { n in [n] + pickN(openMems.filter { $0.id != n.id }, 1, rng) } ?? []
        let wishes = Wish.ownOf(char.id, pid).filter { !$0.isDone && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let d1 = pickN(distant.filter { $0.kind == .event }, 1, rng)
        let d2 = pickN(distant.filter { m in !d1.contains { $0.id == m.id } }, 1, rng)

        var rows: [(kind: String, id: String, text: String)] = []
        for m in pickN(recent, 3, rng) { rows.append(("recent", m.id, m.content)) }
        for m in openPick {
            let d = m.row.string("dueAt")
            rows.append(("open", m.id, m.content + (d.isEmpty ? "" : " (\(d))")))
        }
        for w in pickN(wishes, 1, rng) { rows.append(("wish", w.id, w.text)) }
        for m in d1 + d2 { rows.append(("distant", m.id, m.content)) }
        let userName = ((try? Repo.personas()) ?? []).first { $0.id == pid }?.row.string("name") ?? ""
        if !userName.isEmpty { rows.append(("user", "", userName)) }
        let kept = rows.map { ($0.kind, $0.id, $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.2.isEmpty }
        return kept.enumerated().map { i, r in Material(key: i < keys.count ? keys[i] : "#\(i + 1)", kind: r.0, id: r.1, text: r.2) }
    }

    // MARK: - 拼法（客观指令，不是判断）

    struct Twist { var id: String; var n: Int; var min = 0; var label: String; var text: ([String]) -> String }

    static let twists: [Twist] = [
        Twist(id: "merge", n: 2, label: "一人兼二人", text: { "A person from [\($0[0])] is also, at the same time, a person from [\($0[1])]. The dreamer does not find this strange." }),
        Twist(id: "place", n: 2, label: "地点与人错配", text: { "The scene takes place where [\($0[0])] happened, but the people present belong to [\($0[1])]." }),
        Twist(id: "displace", n: 2, label: "情绪错位", text: { "The feeling that belongs to [\($0[0])] attaches itself to the small matter of [\($0[1])]." }),
        Twist(id: "object", n: 1, label: "反复出现的物件", text: { "One object from [\($0[0])] keeps reappearing in this scene, changed each time." }),
        Twist(id: "time", n: 2, label: "时间折叠", text: { "[\($0[0])] and [\($0[1])] happen on the same day, side by side, as if no time lay between them." }),
        Twist(id: "speech", n: 2, label: "借别人的声音", text: { "Someone from [\($0[0])] speaks in the words or voice of someone from [\($0[1])]." }),
        Twist(id: "cut", n: 0, label: "无过渡跳切", text: { _ in "This scene ends without transition; the next one is already underway somewhere else." }),
        Twist(id: "physics", n: 0, min: 3, label: "物理失效", text: { _ in "Distance, size or the layout of a familiar place does not hold in this scene. The dreamer does not question it." }),
    ]
    static func twistLabel(_ id: String) -> String { twists.first { $0.id == id }?.label ?? id }

    static func twistsPerScene(_ b: Int, _ i: Int) -> Int {
        let b = min(3, max(0, b))
        if b == 0 { return 0 }
        if b == 1 { return i % 2 == 0 ? 1 : 0 }
        return b == 2 ? 1 : 2
    }

    /// 分幕的计划：每一幕分到哪几样原料（轮流分），各有几处什么扭曲。同一幕里不重复同一种扭曲
    static func plan(_ materials: [Material], acts: Int = actsDefault, bizarre b0: Int = 1, rng: RNG = random) -> JSONValue {
        let n = max(1, acts)
        let b = min(3, max(0, b0))
        let keys = materials.map(\.key)
        var scenes: [(n: Int, keys: [String], twists: [JSONValue])] = (0..<n).map { (n: $0 + 1, keys: [String](), twists: [JSONValue]()) }
        for (i, k) in shuffle(keys, rng).enumerated() { scenes[i % n].keys.append(k) }
        let ops = twists.filter { $0.min == 0 || b >= $0.min }.filter { $0.n <= keys.count }
        for i in scenes.indices {
            let want = twistsPerScene(b, i)
            var used = Set<String>()
            for _ in 0..<want {
                let pool = ops.filter { !used.contains($0.id) && !($0.id == "cut" && i == n - 1) }
                guard !pool.isEmpty else { break }
                let op = pool[min(pool.count - 1, Int((rng() * Double(pool.count)).rounded(.down)))]
                used.insert(op.id)
                let own = scenes[i].keys
                let others = keys.filter { !own.contains($0) }
                var picked = pickN(own, op.n, rng)
                if picked.count < op.n { picked += pickN(others, op.n - picked.count, rng) }
                if picked.count < op.n { continue }
                scenes[i].twists.append(.object(["op": .string(op.id), "keys": .array(picked.map { .string($0) }), "text": .string(op.text(picked))]))
            }
        }
        return .object(["bizarre": .number(Double(b)), "scenes": .array(scenes.map {
            .object(["n": .number(Double($0.n)), "keys": .array($0.keys.map { .string($0) }), "twists": .array($0.twists)])
        })])
    }

    /// 反复的梦：上一次梦里用过的某件进行中的事这一次还在，就把上一次的一幕交回去
    static func returning(_ charId: String, _ materials: [Material], _ pid: String = personaId(), rng: RNG = random) -> JSONValue {
        guard let prev = last(charId, pid), let mats = prev["materials"]?.array else { return .null }
        let scenes = sceneTexts(prev)
        guard !scenes.isEmpty else { return .null }
        let openNow = Set(materials.filter { $0.kind == "open" && !$0.id.isEmpty }.map(\.id))
        guard let again = mats.first(where: { $0["kind"]?.string == "open" && openNow.contains($0["id"]?.string ?? "") }) else { return .null }
        let scene = scenes[min(scenes.count - 1, Int((rng() * Double(scenes.count)).rounded(.down)))]
        return .object(["fromId": .string(prev.id), "about": .string(again["text"]?.string ?? ""), "text": .string(scene)])
    }

    // MARK: - 做一次（一次请求）

    private static let kindWord: [String: String] = ["recent": "recent", "open": "ongoing, not yet settled", "wish": "a wish", "distant": "long ago", "user": "the user"]

    private static func background(_ char: Character, _ pid: String, _ userName: String) -> String {
        let root = Repo.rootId(of: pid, in: (try? Repo.personas()) ?? [])
        let key = root.isEmpty ? "root" : root
        func block(_ id: String) -> String { (char.row["states"]?[key]?["blocks"]?[id]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var us = block("us")
        if us.isEmpty { us = (char.row["bonds"]?[key]?["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var out: [String] = []
        if !block("recent").isEmpty { out.append("Lately: \(block("recent"))") }
        if !us.isEmpty { out.append("Between \(char.name) and \(userName): \(us)") }
        if !block("self").isEmpty { out.append("About \(char.name): \(block("self"))") }
        return out.isEmpty ? "(nothing recorded)" : out.joined(separator: "\n")
    }

    static func promptOf(_ char: Character, materials: [Material], plan: JSONValue, returned: JSONValue, pid: String, settings s: AppSettings) -> String {
        let userName = ((try? Repo.personas()) ?? []).first { $0.id == pid }?.name ?? "the user"
        let matText = materials.isEmpty ? "(none)" : materials.map { "[\($0.key)] (\(kindWord[$0.kind] ?? $0.kind)) \($0.text)" }.joined(separator: "\n")
        let scenes = plan["scenes"]?.array ?? []
        let sceneText = scenes.map { sc -> String in
            let ks = (sc["keys"]?.array ?? []).compactMap(\.string)
            let head = "Scene \(Int(sc["n"]?.number ?? 0)): elements \(ks.isEmpty ? "(any)" : ks.map { "[\($0)]" }.joined(separator: ", "))"
            let lines = (sc["twists"]?.array ?? []).map { "  - \($0["text"]?.string ?? "")" }
            return ([head] + lines).joined(separator: "\n")
        }.joined(separator: "\n")
        let retText = returned.object == nil ? ""
            : "\n## A scene that returns\nThis scene from an earlier dream, about \"\(returned["about"]?.string ?? "")\", returns in some form:\n\"\(returned["text"]?.string ?? "")\"\n"
        return Templates.render("task.dream", [
            "charName": char.row.string("name"), "charPersona": char.persona.isEmpty ? "(no character card)" : char.persona,
            "date": todayOf(char), "background": background(char, pid, userName), "materials": matText, "scenes": sceneText,
            "returned": retText, "acts": String(scenes.count), "words": String(wordsOf(char)),
        ], settings: s)
    }

    /// 做一次。source：auto 每晚自动那一次 / now 用户点的。回来的是落下的那一行
    @discardableResult
    static func write(_ charId: String, source: String = "now", pid: String = personaId(), rng: RNG = random) async throws -> Row {
        guard let char = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        let s = AppSettings.load()
        let date = todayOf(char)
        let materials = draw(char, pid, rng: rng)
        let p = plan(materials, acts: actsOf(char), bizarre: bizarreOf(char), rng: rng)
        let returned = returning(charId, materials, pid, rng: rng)
        let tr = GenTrans.forChar(charId, personaId: pid)
        let system = promptOf(char, materials: materials, plan: p, returned: returned, pid: pid, settings: s)
            + GenTrans.fieldsPart(tr, ["title", "text", "recall"], settings: s)
        // 字数由用户定，回复上限按它算
        let maxTokens = max(4000, Int((Double(wordsOf(char)) * 2.5).rounded(.up)) + 600)
        let r = try await AIService.shared.send(task: "dream.write", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")], maxTokens: maxTokens)
        guard let j = JSONReply.parse(r.text), j.object != nil else { throw StoreError(message: JSONReply.failure(r.text)) }
        var scenes: [JSONValue] = []
        let rawScenes = j["scenes"]?.array ?? (j["text"]?.string.map { [JSONValue.object(["text": .string($0)])] } ?? [])
        for sc in rawScenes {
            let text = (sc["text"]?.string ?? sc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let t = GenTrans.pick(tr, sc, "text")
            scenes.append(t.isEmpty ? .object(["text": .string(text)]) : .object(["text": .string(text), "textTrans": .string(t)]))
        }
        guard !scenes.isEmpty else { throw StoreError(message: "模型交回的梦是空的") }
        let texts = scenes.compactMap { $0["text"]?.string }
        let fragments = (j["fragments"]?.array ?? []).compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // 醒来掷一次骰子：记得多少。碎片档留两三个画面。都是本地算，不多调接口
        let level = roll(char, rng)
        let kept = keepFragments(fragments, texts, rng)
        var planObj = p.object ?? [:]
        planObj["returned"] = returned
        func trim(_ k: String) -> String { (j[k]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var row = Row.new(prefix: "dm", [
            "charId": .string(charId), "personaId": .string(pid), "date": .string(date),
            "title": .string(trim("title")), "titleTrans": .string(GenTrans.pick(tr, j, "title")),
            "scenes": .array(scenes), "text": .string(texts.joined(separator: "\n\n")),
            "recall": .string(trim("recall")), "recallTrans": .string(GenTrans.pick(tr, j, "recall")),
            "mood": .string(trim("mood")), "materials": .array(materials.map(\.json)), "plan": .object(planObj),
            "source": .string(source), "memoryId": .string(""),
            "fragments": .array(fragments.map { .string($0) }), "recallLevel": .string(level), "kept": .array(kept.map { .string($0) }),
        ])
        try Database.shared.put(collection, row)
        if memoryOn(char) {
            // 记成一条 C 级事件记忆：按醒来时记得的版本。发生时间是醒来的这一刻
            let now = Date().millis
            let mem = Row.new(prefix: "mem", [
                "charId": .string(charId), "personaId": .string(pid), "source": .string("auto"), "kind": .string("event"),
                "category": .string("event"), "rank": .string("C"), "keywords": .array([]), "about": .string("char"),
                "weight": .number(0.5), "content": .string(memoryText(row)), "at": .number(now), "dreamId": .string(row.id),
            ])
            try Database.shared.put(Collections.memories, mem)
            row["memoryId"] = .string(mem.id)
            try Database.shared.put(collection, row)
        }
        return row
    }

    private static let inFlight = ClosetAI.InFlight()

    /// 角色那边是不是到了醒来的时刻
    static func due(_ c: Character, _ at: Date = Date()) -> Bool { parts(at, c).hour >= hourOf(c) }

    /// 开了、到了时刻、今天还没试过、今天还没有梦：做一次。不抛错，错误记在角色身上。返回这一次有没有发出请求
    @discardableResult
    static func ensureToday(_ charId: String, now: Date = Date()) async -> Bool {
        guard let char = (try? Repo.character(charId)) ?? nil, isAuto(char), !char.archived, due(char, now) else { return false }
        let date = todayOf(char, now)
        if char.row.string("dreamAutoAt") == date { return false }
        let pid = personaId()
        if on(charId, date, pid) != nil { return false }
        guard inFlight.begin(charId) else { return false }
        defer { inFlight.end(charId) }
        guard Daily.claim("dream", charId, date) else { return false }
        do { try Diary.patchChar(charId, ["dreamAutoAt": .string(date), "dreamAutoError": .string("")]) }
        catch {
            Problems.report("梦境未能记下今天的尝试：\(error.localizedDescription)")
            return false
        }
        do { _ = try await write(charId, source: "auto", pid: pid) }
        catch {
            do { try Diary.patchChar(charId, ["dreamAutoError": .string(error.localizedDescription)]) }
            catch { Problems.report("梦境失败的原因未能写入：\(error.localizedDescription)") }
        }
        return true
    }

    // MARK: - 进聊天（网页版 context/dream.js 与 reply.js 的 dreamshare）

    /// [昨夜的梦]：该角色此刻还记得的那部分。线下不给；开关在梦境 app 里该角色的页面（默认关）
    static func block(char: Character, chat: Chat, persona: Persona?, now: Date = Date()) -> String {
        guard injectOn(char) else { return "" }
        let pid = !chat.personaId.isEmpty ? chat.personaId : (persona?.id ?? personaId())
        guard let row = on(char.id, todayOf(char, now), pid) else { return "" }
        let r = remembered(row, char, at: now)
        let head = "Last night (\(row.string("date"))) you had a dream."
        let feel = r.mood.isEmpty ? "" : " The feeling it left: \(r.mood)."
        let body: String
        switch r.level {
        case "full": body = "You remember it clearly:\n\(r.lines.joined(separator: "\n\n"))"
        case "fragment": body = "You remember only these fragments; the rest is gone:\n\(r.lines.map { "- \($0)" }.joined(separator: "\n"))"
        default: body = "You remember nothing of what happened in it."
        }
        return "\n\n[昨夜的梦]\n\(head)\(r.level == "trace" ? feel : "")\n\(body)\(r.level != "trace" ? feel : "")"
    }

    /// 能力 dream 开不开：写进对话开着、一对一、今天确实有梦
    static func capOn(_ char: Character, chat: Chat) -> Bool {
        injectOn(char) && chat.characterIds.count <= 1 && on(char.id, todayOf(char), chat.personaId.isEmpty ? personaId() : chat.personaId) != nil
    }

    static let capLine = "Share last night's dream with them as a card: write a line on its own, [梦境：a few words of your own about it]. The card shows what you remember of the dream"

    /// [梦境：…]：落一张卡片，卡片上是它此刻记得的那部分。正文是它自己那一句。条件不满足就当没写过
    static func shareMessage(_ said: String, chat: Chat, char: Character, turnId: String) -> Message? {
        let off = Set((AppSettings.load().raw["capsOff"]?.array ?? []).compactMap(\.string))
        guard !chat.isGroup, chat.characterIds.count <= 1, injectOn(char), !off.contains("dream") else { return nil }
        let pid = chat.personaId.isEmpty ? personaId() : chat.personaId
        guard let row = on(char.id, todayOf(char), pid) else { return nil }
        let r = remembered(row, char)
        let t = said.trimmingCharacters(in: .whitespacesAndNewlines)
        var m = Message.new(chatId: chat.id, role: .char, authorId: char.id, content: "[梦境：\(t)]", kind: "dreamcard", turnId: turnId)
        m.row["dreamId"] = .string(row.id)
        m.row["dreamSnap"] = .object(["level": .string(r.level), "lines": .array(r.lines.map { .string($0) }), "mood": .string(r.mood), "said": .string(t)])
        return m
    }
}
