import Foundation

/// 衣帽间里要调接口的几样（网页版 ai/tasks/closet.js，ARCHITECTURE 4.213、4.214、4.237）。
///
/// 识图、按描述生图、按角色设定生成一批：**都是用户点了才调**，按钮旁写着要调几次。
/// 每日穿搭是每天一次的自动任务：开关挂在角色身上（char.closetDaily，衣帽间里那个角色的页面），默认关，登记在 ExtraCalls。
/// 一天只试一次，失败也算试过：先 Daily.claim 占住当天、在角色身上记 closetDailyAt，再发请求；今天已经穿着东西的不碰。
enum ClosetAI {
    // MARK: - 分类表摆给模型看（名字是数据，原样给）

    static func groupLines(_ side: String = "") -> String {
        ClosetKinds.groups.filter { side.isEmpty || $0.side == side }
            .map { g in "\(g.id): \(g.label) — \(Closet.subsOf(g.id).map(\.label).joined(separator: " / "))" }.joined(separator: "\n")
    }

    static func idList(_ list: [ClosetKinds.Tag]) -> String { list.map { "\($0.id) (\($0.label))" }.joined(separator: ", ") }

    private static func pick(_ v: JSONValue?, _ list: [ClosetKinds.Tag]) -> JSONValue {
        let ids = (v?.array ?? []).compactMap { $0.string ?? $0.number.map { String(Int($0)) } }.filter { id in list.contains { $0.id == id } }
        return .array(ids.map { .string($0) })
    }

    private static func str(_ v: JSONValue?) -> String { (v?.string ?? v?.number.map { String($0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - 识图（用户点了才调，一件一次）

    static func visionReady(_ s: AppSettings = .load()) -> Bool { s.visionActive }

    /// 看一件东西的照片，填上分类、颜色、季节、场合、名字与描述。**只填空着的**：用户自己写过的不动
    @discardableResult
    static func recognize(_ id: String) async throws -> Row? {
        guard let row = Closet.get(id) else { throw StoreError(message: "这件东西已经不在了") }
        guard !row.string("imageId").isEmpty else { throw StoreError(message: "这件东西还没有图片") }
        let s = AppSettings.load()
        guard s.visionActive else { throw StoreError(message: "尚未配置识图接口，可在「设置 - 识图」中填写") }
        guard let url = MediaStore.url(.images, id: row.string("imageId")), let data = try? Data(contentsOf: url) else {
            throw StoreError(message: "图片已不存在")
        }
        let prompt = Templates.render("task.closet-vision", [
            "groups": groupLines(), "colors": idList(ClosetKinds.colors), "seasons": idList(ClosetKinds.seasons),
            "occasions": idList(ClosetKinds.occasions),
        ], settings: s)
        let image = AIImage(mediaType: Images.mediaType(ext: url.pathExtension), base64: data.base64EncodedString())
        let r = try await AIService.shared.send(task: "closet.vision", preset: s.visionMode == "api" ? s.visionPreset : nil,
                                                system: prompt, messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.", images: [image])],
                                                maxTokens: 500, retries: 1)
        guard let j = JSONReply.parse(r.text), j.object != nil else { throw StoreError(message: "识图接口返回的内容读不出来") }
        let cur = Closet.get(id) ?? row
        var patch: [String: JSONValue] = [:]
        if cur.string("group").isEmpty, let g = ClosetKinds.group(str(j["group"])) {
            patch["group"] = .string(g.id)
            patch["side"] = .string(g.side)
            if let sub = Closet.subsOf(g.id).first(where: { $0.label == str(j["sub"]) }) { patch["sub"] = .string(sub.label) }
        }
        let name = str(j["name"])
        if !name.isEmpty && (cur.string("name").isEmpty || cur.string("name") == "未命名") { patch["name"] = .string(name) }
        // 照片常是模特穿着的：提到人的句子不存（4.215）
        let desc = Closet.garmentOnly(str(j["desc"]))
        if !desc.isEmpty && cur.string("desc").isEmpty { patch["desc"] = .string(desc) }
        if cur.strings("colors").isEmpty { patch["colors"] = pick(j["colors"], ClosetKinds.colors) }
        if cur.strings("seasons").isEmpty { patch["seasons"] = pick(j["seasons"], ClosetKinds.seasons) }
        if cur.strings("occasions").isEmpty { patch["occasions"] = pick(j["occasions"], ClosetKinds.occasions) }
        let shade = str(j["shade"])
        if !shade.isEmpty && cur.string("shade").isEmpty { patch["shade"] = .string(shade) }
        return try Closet.update(id, patch)
    }

    /// 一件一件识。一件失败不拦后面的
    static func recognizeMany(_ ids: [String], onEach: @escaping @Sendable (Int, Int, Int) -> Void = { _, _, _ in }) async -> (done: Int, failed: [String]) {
        var done = 0
        var failed: [String] = []
        for id in ids {
            do { try await recognize(id); done += 1 } catch { failed.append(error.localizedDescription) }
            onEach(done, failed.count, ids.count)
        }
        return (done, failed)
    }

    // MARK: - 按描述画一张（用户点了才调，一次）

    static func imageReady(_ s: AppSettings = .load()) -> Bool { s.imageReady }

    @discardableResult
    static func draw(_ id: String) async throws -> Row? {
        guard let row = Closet.get(id) else { throw StoreError(message: "这件东西已经不在了") }
        let s = AppSettings.load()
        guard s.imageReady, let preset = s.activeImage else { throw StoreError(message: "尚未配置生图接口，可在「设置 - 生图」中填写") }
        var what = row.string("desc").trimmingCharacters(in: .whitespacesAndNewlines)
        if what.isEmpty { what = [row.string("name"), row.string("sub"), row.string("shade")].filter { !$0.isEmpty }.joined(separator: ", ") }
        guard !what.isEmpty else { throw StoreError(message: "先写一句描述再生成") }
        let prompt = Templates.render("task.closet-image", ["desc": what], settings: s)
        let data = try await ImageGen.generate(prompt: prompt, preset: preset)
        let img = try Images.save(data)
        return try Closet.patch(id, ["imageId": .string(img)])
    }

    // MARK: - 按角色设定生成一批（一次调用，结果先列出来看一眼再决定存不存）

    /// 生成该角色衣帽间里的一批东西，只有文字。count 由用户填，不设上限。已经有的同名的不再给
    static func wardrobe(_ charId: String, count: Int = 20, side: String = "wear") async throws -> [[String: JSONValue]] {
        guard let char = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        let n = max(1, count)
        let have = Closet.itemsOf(charId).filter { !Closet.isOutfit($0) && $0.string("side") == side }
        let persona = [char.persona, char.row.string("appearance"), char.signature].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let s = AppSettings.load()
        let system = Templates.render("task.closet-wardrobe", [
            "charName": char.row.string("name").isEmpty ? "该角色" : char.name,
            "charPersona": persona.isEmpty ? "（角色卡里还没有写人设）" : persona,
            "count": String(n),
            "sideName": side == "beauty" ? "dressing table (skincare, makeup, fragrance, tools)" : "clothing and accessories",
            "existing": have.isEmpty ? "（还是空的）" : have.map { "- \($0.string("name"))" }.joined(separator: "\n"),
            "groups": groupLines(side), "colors": idList(ClosetKinds.colors), "seasons": idList(ClosetKinds.seasons),
            "occasions": idList(ClosetKinds.occasions),
        ], settings: s)
        let r = try await AIService.shared.send(task: "closet.wardrobe", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: 300 + n * 110)
        guard let j = JSONReply.parse(r.text), j.object != nil else { throw StoreError(message: JSONReply.failure(r.text)) }
        func norm(_ t: String) -> String { t.filter { !$0.isWhitespace }.lowercased() }
        var seen = Set(have.map { norm($0.string("name")) })
        var out: [[String: JSONValue]] = []
        for x in j["items"]?.array ?? [] {
            guard let g = ClosetKinds.group(str(x["group"])), g.side == side else { continue }
            let name = str(x["name"])
            guard !name.isEmpty, !seen.contains(norm(name)) else { continue }
            seen.insert(norm(name))
            let sub = Closet.subsOf(g.id).first { $0.label == str(x["sub"]) }
            out.append([
                "group": .string(g.id), "side": .string(g.side), "sub": .string(sub?.label ?? ""), "name": .string(name),
                "desc": .string(Closet.garmentOnly(str(x["desc"]))), "shade": .string(side == "beauty" ? str(x["shade"]) : ""),
                "colors": pick(x["colors"], ClosetKinds.colors),
                "seasons": side == "wear" ? pick(x["seasons"], ClosetKinds.seasons) : .array([]),
                "occasions": side == "wear" ? pick(x["occasions"], ClosetKinds.occasions) : .array([]),
            ])
        }
        return out
    }

    /// 勾选的那几件放进该角色的衣帽间
    @discardableResult
    static func keepWardrobe(_ charId: String, _ rows: [[String: JSONValue]]) throws -> [Row] {
        try rows.map { var f = $0; f["owner"] = .string(charId); return try Closet.create(f) }
    }

    // MARK: - 每天自动：今天穿什么、带什么（4.237）

    static func isDaily(_ char: Character?) -> Bool { char?.row["closetDaily"]?.bool == true }

    private static let inFlight = InFlight()

    final class InFlight: @unchecked Sendable {
        private let lock = NSLock()
        private var ids = Set<String>()
        func begin(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.insert(id).inserted }
        func end(_ id: String) { lock.lock(); ids.remove(id); lock.unlock() }
    }

    private static func line(_ r: Row) -> String {
        let cat = [ClosetKinds.group(r.string("group"))?.label ?? "", r.string("sub")].filter { !$0.isEmpty }.joined(separator: " / ")
        let seasons = r.strings("seasons").map { x in ClosetKinds.seasons.first { $0.id == x }?.label ?? x }
        let occ = r.strings("occasions").map { x in ClosetKinds.occasions.first { $0.id == x }?.label ?? x }
        return "\(r.id) | \(cat) | \(r.string("name"))"
            + (seasons.isEmpty ? "" : " | \(seasons.joined(separator: "、"))")
            + (occ.isEmpty ? "" : " | \(occ.joined(separator: "、"))")
    }

    /// 当天气温落在哪几个季节。宁宽勿窄：只用来把明显不合季节的衣物拿掉
    static func seasonsFor(_ w: Weather.Forecast?) -> Set<String>? {
        guard let w, w.tempMin.isFinite, w.tempMax.isFinite else { return nil }
        let mid = (w.tempMin + w.tempMax) / 2
        var out = Set<String>()
        if w.tempMax >= 26 || mid >= 22 { out.insert("summer") }
        if mid >= 8 && mid <= 25 { out.insert("spring"); out.insert("autumn") }
        if w.tempMin <= 10 || mid <= 12 { out.insert("winter") }
        return out
    }

    /// 角色那边的日期（按角色时区，不往前挪一天：和日程、天气同一个「今天」）
    static func charDate(_ char: Character, _ s: AppSettings) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Clock.zone(Clock.charZone(char, s))
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Clock.now(s))
    }

    /// 挑一次，勾上。回来的是勾上了几件。只从这个角色衣帽间里已有的东西里挑
    @discardableResult
    static func pickToday(_ charId: String) async throws -> Int {
        guard let char = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        let owned = Closet.itemsOf(charId).filter { Closet.live($0) && !Closet.isOutfit($0) && $0.string("side") == "wear" && !Closet.lentOut($0) }
        guard !owned.isEmpty else { throw StoreError(message: "该角色的衣帽间里还没有衣物或随身物品") }
        let s = AppSettings.load()
        let date = charDate(char, s)
        // 今天的日程已经查过天气就用那一份，不再查一次
        var w = ((try? DayPlan.day(charId, date: date)) ?? nil).flatMap { Weather.Forecast($0["weather"]) }
        if w == nil { w = await Weather.forChar(char, date: date) }
        // 严格按天气：标了季节、又不合今天气温的衣物不交给模型，模型选回来也不认。随身物品不看季节。全被拿掉时照原样全给
        let fit = seasonsFor(w)
        let suits = { (r: Row) -> Bool in
            Closet.isCarry(r) || fit == nil || r.strings("seasons").isEmpty || r.strings("seasons").contains(where: { fit!.contains($0) })
        }
        let kept = owned.filter(suits)
        let keepAll = kept.contains(where: { !Closet.isCarry($0) }) || !owned.contains(where: { !Closet.isCarry($0) })
        let all = keepAll ? kept : owned
        let clothes = all.filter { !Closet.isCarry($0) }, carry = all.filter { Closet.isCarry($0) }
        let wd: String = {
            let p = date.split(separator: "-").compactMap { Int($0) }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            guard p.count == 3, let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)) else { return "" }
            return String(Array("日一二三四五六")[cal.component(.weekday, from: d) - 1])
        }()
        let persona = [char.persona, char.row.string("appearance")].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let system = Templates.render("task.closet-daily", [
            "charName": char.row.string("name").isEmpty ? "该角色" : char.name,
            "charPersona": persona.isEmpty ? "（角色卡里还没有写人设）" : persona,
            "date": date, "weekday": wd,
            "weather": w.map { Templates.render("task.closet-daily-weather", ["forecast": Weather.promptLine($0)], settings: s) } ?? "",
            "clothes": clothes.isEmpty ? "（没有）" : clothes.map { line($0) }.joined(separator: "\n"),
            "carry": carry.isEmpty ? "（没有）" : carry.map { line($0) }.joined(separator: "\n"),
        ], settings: s)
        let r = try await AIService.shared.send(task: "closet.daily", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")], maxTokens: 400)
        guard let j = JSONReply.parse(r.text), j.object != nil else { throw StoreError(message: JSONReply.failure(r.text)) }
        let ids = Set(all.map(\.id))
        let chosen = ((j["wear"]?.array ?? []) + (j["carry"]?.array ?? [])).compactMap { $0.string ?? $0.number.map { String(Int($0)) } }
            .filter { ids.contains($0) }
        guard !chosen.isEmpty else { throw StoreError(message: "模型没有从衣帽间里选出任何一件") }
        for id in chosen { try Closet.wear(id, true) }
        return chosen.count
    }

    /// 开了、今天还没试过、今天还什么都没穿：挑一次。不抛错，错误记在角色身上。返回这一次有没有发出请求
    @discardableResult
    static func ensureDaily(_ charId: String) async -> Bool {
        guard let char = (try? Repo.character(charId)) ?? nil, isDaily(char), !char.archived else { return false }
        let d = Closet.today()
        if char.row.string("closetDailyAt") == d { return false }
        if !Closet.wornToday(charId).isEmpty { return false }
        // 今天已经自动试过（别的地方试的、开关关了又开）：不再试，等明天
        guard inFlight.begin(charId) else { return false }
        defer { inFlight.end(charId) }
        guard Daily.claim("closet", charId, d) else { return false }
        do { try Diary.patchChar(charId, ["closetDailyAt": .string(d), "closetDailyError": .string("")]) }
        catch {
            Problems.report("每日穿搭未能记下今天的尝试：\(error.localizedDescription)")
            return false
        }
        do { _ = try await pickToday(charId) }
        catch {
            do { try Diary.patchChar(charId, ["closetDailyError": .string(error.localizedDescription)]) }
            catch { Problems.report("每日穿搭失败的原因未能写入：\(error.localizedDescription)") }
        }
        return true
    }

    // MARK: - 生图时带上今天穿的（网页版 imageprompt.js 的 wearOf，衣帽间设置里开，默认关）

    private static let pair = try! NSRegularExpression(pattern: "合照|合影|我们|两个人|俩人|一起|together|couple|both of us", options: [.caseInsensitive])
    private static let selfish = try! NSRegularExpression(pattern: "自拍|自照|正脸|我的脸|我的样子|镜子|镜头|selfie|头像|证件照", options: [.caseInsensitive])

    /// 画面里有谁，就把谁今天穿的接在后面。只传文字，衣物的照片永远不当参考图（4.215）
    static func wearParts(_ text: String, char: Character?, me: Persona?, settings s: AppSettings) -> [(String, String)] {
        guard s.raw["closetInImage"]?.bool == true else { return [] }
        let both = Closet.matches(pair, text)
        func line(_ name: String, _ rows: [Row]) -> String {
            rows.isEmpty ? "" : "\(name) is wearing: " + rows.map { r in
                [r.string("name"), Closet.garmentOnly(r.string("desc"))].filter { !$0.isEmpty }.joined(separator: ", ")
            }.joined(separator: "; ")
        }
        var out: [(String, String)] = []
        let cn = char?.row.string("name").trimmingCharacters(in: .whitespaces) ?? ""
        if let char, both || Closet.matches(selfish, text) || (cn.count >= 2 && text.contains(cn)) {
            let l = line(cn.isEmpty ? "The character" : cn, Closet.wornToday(char.id).filter { !Closet.isCarry($0) })
            if !l.isEmpty { out.append(("「\(cn)」今天穿的（衣帽间）", l)) }
        }
        let who = me ?? ((try? Repo.activePersona()) ?? nil)
        let mn = who?.row.string("name").trimmingCharacters(in: .whitespaces) ?? ""
        if both || (mn.count >= 2 && text.contains(mn)) {
            let l = line(mn.isEmpty ? "The other person" : mn, Closet.wornToday(Closet.me, who?.id).filter { !Closet.isCarry($0) })
            if !l.isEmpty { out.append(("我今天穿的（衣帽间）", l)) }
        }
        if !out.isEmpty {
            out.append(("衣帽间：只取衣物", "The clothing lines above describe garments only."
                + " Faces, hair and bodies follow the appearance of each named person, never a model the garments were photographed on."))
        }
        return out
    }
}
