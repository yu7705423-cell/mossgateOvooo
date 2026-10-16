import Foundation

/// 角色手机（网页版 system/theirs.js 与 system/ai/tasks/phone.js）。
///
/// 一个角色一台，phones 一行装下：锁屏（lock）、壁纸（wallpaper）、图标（icons）、备忘录（notes）、浏览记录（visits）、
/// 相册（albums、photos）、允许角色自己存图（keepOn）。会话另算 phoneChats，一条会话一行，消息内嵌在 lines 里。
/// 格式与网页版一字不差，导入导出两边读得回。
///
/// 密码**不落库也先有**：没存过就按角色卡当场推一个（localLock），不调接口。解开只记在内存里，重开应用重新锁上。
/// 生成一律用户点了才调，一项一次请求，失败不自动重试（第 15 条）。
enum Theirs {
    static let phones = "phones", chats = "phoneChats"

    // MARK: - 那一行

    static func get(_ charId: String) -> Row? { ((try? Database.shared.all(phones, where: charId)) ?? []).first }

    @discardableResult
    static func set(_ charId: String, _ fields: [String: JSONValue]) throws -> Row {
        var row = get(charId) ?? Row.new(prefix: "ph", ["charId": .string(charId), "lock": .null, "wallpaper": .null,
                                                        "icons": .object([:]), "notes": .array([]), "visits": .array([])])
        for (k, v) in fields { row[k] = v }
        row.touch()
        try Database.shared.put(phones, row)
        return row
    }

    private static func cap(_ s: String?, _ n: Int) -> String {
        String((s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(n))
    }

    private static func list(_ charId: String, _ key: String) -> [[String: JSONValue]] {
        (get(charId)?[key]?.array ?? []).compactMap(\.object)
    }

    private static func arr(_ rows: [[String: JSONValue]]) -> JSONValue { .array(rows.map { .object($0) }) }

    // MARK: - 锁屏

    struct Lock: Equatable {
        var code: String
        var why: String
        var hints: [String]
        var src: String
        var shown: Int
        var changedAt: Double = 0

        init(code: String, why: String, hints: [String], src: String, shown: Int = 0, changedAt: Double = 0) {
            self.code = code; self.why = why; self.hints = hints; self.src = src; self.shown = shown; self.changedAt = changedAt
        }

        init?(_ v: JSONValue?) {
            guard let o = v?.object, let code = o["code"]?.string, !code.isEmpty else { return nil }
            self.code = code
            why = o["why"]?.string ?? ""
            hints = o["hints"]?.array?.compactMap(\.string) ?? []
            src = o["src"]?.string ?? "ai"
            shown = Int(o["shown"]?.number ?? 0)
            changedAt = o["changedAt"]?.number ?? 0
        }

        var json: JSONValue {
            var o: [String: JSONValue] = ["code": .string(code), "why": .string(why), "hints": .array(hints.map { .string($0) }),
                                          "src": .string(src), "shown": .number(Double(shown))]
            if changedAt > 0 { o["changedAt"] = .number(changedAt) }
            return .object(o)
        }

        var left: Int { max(0, hints.count - shown) }
    }

    private static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    private static func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    /// 生日那一栏里的 MMDD。认 1999-03-14、3月14日、03/14、19990314
    static func mmdd(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        func ok(_ mo: Int, _ d: Int) -> String { (1...12).contains(mo) && (1...31).contains(d) ? pad2(mo) + pad2(d) : "" }
        if let g = groups(#"([0-9]{1,2})\s*月\s*([0-9]{1,2})"#, s) { return ok(Int(g[1]) ?? 0, Int(g[2]) ?? 0) }
        if let g = groups(#"(?:[0-9]{4}\s*[-/.年]\s*)?([0-9]{1,2})\s*[-/.]\s*([0-9]{1,2})"#, s) { return ok(Int(g[1]) ?? 0, Int(g[2]) ?? 0) }
        let only = s.filter { $0.isASCII && $0.isNumber }.map(String.init).joined()
        let d = Array(only)
        if d.count == 8 { return ok(Int(String(d[4...5])) ?? 0, Int(String(d[6...7])) ?? 0) }
        if d.count == 4 { return ok(Int(String(d[0...1])) ?? 0, Int(String(d[2...3])) ?? 0) }
        return ""
    }

    static func year(_ raw: String) -> String { groups(#"(19[0-9]{2}|20[0-9]{2})"#, raw)?[1] ?? "" }

    /// 设定正文里出现过的四位数，按出现顺序
    static func fours(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"(^|[^0-9])([0-9]{4})(?=[^0-9]|$)"#) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 2), in: text).map { String(text[$0]) } }
    }

    /// 和网页版同一个散列：(h * 31 + 字符) 按 32 位无符号取
    static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 0
        for c in s.utf16 { h = h &* 31 &+ UInt32(c) }
        return h
    }

    private static func picks(_ char: Character) -> [Lock] {
        var out: [Lock] = []
        func add(_ l: Lock) { if !l.code.isEmpty && !out.contains(where: { $0.code == l.code }) { out.append(l) } }
        let bd = mmdd(char.row.string("birthday"))
        add(Lock(code: bd, why: "该角色的生日", hints: ["这串数字是一个日期。", "那是这台手机的主人自己的日期。"]
                 + (bd.isEmpty ? [] : ["月份是 \(Int(bd.prefix(2)) ?? 0) 月。"]), src: "birthday"))
        let yr = year(char.row.string("birthday"))
        add(Lock(code: yr, why: "该角色出生的年份", hints: ["这串数字是一个年份。", "那是这台手机的主人出生的那一年。"]
                 + (yr.isEmpty ? [] : ["它在 \(yr.prefix(3))0 年代。"]), src: "birthyear"))
        let text = [char.persona, char.row.string("description"), char.signature].filter { !$0.isEmpty }.joined(separator: "\n")
        let f = fours(text)
        if let first = f.first {
            add(Lock(code: first, why: "该角色设定中出现的第一串四位数字",
                     hints: ["这串数字在该角色的设定里写着。", "它是设定正文中出现的第一串四位数字。", "第一位是 \(first.prefix(1))。"], src: "text"))
        }
        if f.count > 1, let last = f.last {
            add(Lock(code: last, why: "该角色设定中出现的最后一串四位数字",
                     hints: ["这串数字在该角色的设定里写着。", "它是设定正文中出现的最后一串四位数字。", "第一位是 \(last.prefix(1))。"], src: "text-last"))
        }
        return out
    }

    /// 不调接口，按角色卡当场推一个。依据随机挑，但对同一个角色永远挑中同一个（角色 id 当种子）
    static func localLock(_ char: Character) -> Lock {
        let p = picks(char)
        guard !p.isEmpty else {
            let n = Int(hash(char.id) % 10000)
            return Lock(code: String(format: "%04d", n),
                        why: "该角色的设定中没有可以作为依据的数字，这串是按角色标识推出的",
                        hints: ["该角色的设定中没有可以作为密码依据的信息。这串数字无从推测，可以直接查看。"], src: "random")
        }
        return p[Int(hash("\(char.id):lock") % UInt32(p.count))]
    }

    /// 现在用的那个密码：存过的优先，没存过当场推，不写库
    static func lock(_ charId: String) -> Lock? {
        if let l = Lock(get(charId)?["lock"]) { return l }
        return ((try? Repo.character(charId)) ?? nil).map(localLock)
    }

    static func setLock(_ charId: String, _ l: Lock?) throws {
        try set(charId, ["lock": l.map { var x = $0; x.shown = 0; return x.json } ?? .null])
    }

    static func tryCode(_ charId: String, _ input: String) -> Bool {
        guard let code = lock(charId)?.code, !code.isEmpty else { return false }
        return input.trimmingCharacters(in: .whitespaces) == code
    }

    /// 再要一条提示。问完返回 nil。问到第几条要记住，所以当场推的那个这一下存下来
    static func nextHint(_ charId: String) throws -> String? {
        guard var l = lock(charId) else { return nil }
        let shown = min(l.shown, l.hints.count)
        guard shown < l.hints.count else { return nil }
        l.shown = shown + 1
        try set(charId, ["lock": l.json])
        return l.hints[shown]
    }

    // 这一次打开应用期间解开过的。不落库：存起来就等于解过一次永远不用再解
    nonisolated(unsafe) private static var opened: Set<String> = []
    static func isOpen(_ charId: String) -> Bool { opened.contains(charId) }
    static func open(_ charId: String) { opened.insert(charId) }
    static func relock(_ charId: String) { opened.remove(charId) }

    // MARK: - 角色自己改密码（网页版 4.222）
    //
    // 角色在聊天里写 [改密码：数字｜这串数字是什么]。不要太频繁由代码管：离上一次改不满 lockGapDays 天（默认 30），
    // 这项能力整个不给，除非最近两句我说的话里聊到了密码。

    static let lockGapDefault = 30

    static func lockGap(_ char: Character) -> Int { max(0, Int((char.row.number("lockGapDays") ?? Double(lockGapDefault)).rounded())) }

    /// 最近两句我说的话里提到了密码（「你怎么没改成我的生日」这种不带「密码」两个字的也算）
    static func askedLock(_ msgs: [Message]) -> Bool {
        msgs.filter { $0.role == .user }.suffix(2).contains {
            $0.content.range(of: #"密码|锁屏|解锁|passcode|password|改.{0,6}(生日|纪念日)"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// 离上一次改够不够久（从没改过也算够）
    static func lockCooled(_ char: Character, now: Date = Date()) -> Bool {
        let at = get(char.id)?["lock"]?["changedAt"]?.number ?? 0
        return at <= 0 || now.millis - at >= Double(lockGap(char)) * 86_400_000
    }

    /// 换成新密码：4 到 6 位数字，和现在的一样就不换。返回换之前存着的那一份（没存过为 null），没换返回 nil
    static func changeLock(_ charId: String, code: String, why: String) throws -> JSONValue? {
        let digits = code.filter { $0.isASCII && $0.isNumber }
        guard (4...6).contains(digits.count), digits != lock(charId)?.code else { return nil }
        let prev = get(charId)?["lock"] ?? .null
        let at = Date().millis
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        try set(charId, ["lock": Lock(code: digits, why: String(why.trimmingCharacters(in: .whitespaces).prefix(80)),
                                      hints: ["这串密码是 \(f.string(from: Date(millis: at))) 新换的，一共 \(digits.count) 位。"],
                                      src: "char", changedAt: at).json])
        relock(charId)
        return prev
    }

    /// 撤回一次改密码：放回换之前那一份（没存过就回到按角色卡推的那一个）
    static func restoreLock(_ charId: String, _ prev: JSONValue?) throws {
        try set(charId, ["lock": prev ?? .null])
        relock(charId)
    }

    /// 你刚发过来的那张图：从最后往前，跳过这一轮角色自己刚落下的，取紧挨着的那段你发的里面最后一张
    static func justSent(_ chatId: String, turnId: String) -> String? {
        let list = (try? Repo.messages(chatId: chatId, limit: 40)) ?? []
        var hit: String?
        var inUser = false
        for m in list.reversed() {
            if m.role == .user {
                inUser = true
                if hit == nil && !m.imageId.isEmpty { hit = m.imageId }
                continue
            }
            if inUser || m.turnId != turnId { break }
        }
        return hit
    }

    // MARK: - 备忘录与浏览记录（追加不覆盖）

    struct Note: Equatable { var title: String; var text: String; var titleTrans: String; var textTrans: String }

    static func notes(_ charId: String) -> [Note] {
        list(charId, "notes").map { Note(title: $0["title"]?.string ?? "", text: $0["text"]?.string ?? "",
                                         titleTrans: $0["titleTrans"]?.string ?? "", textTrans: $0["textTrans"]?.string ?? "") }
    }

    @discardableResult
    static func addNotes(_ charId: String, _ rows: [JSONValue]) throws -> Int {
        let clean: [[String: JSONValue]] = rows.compactMap { r in
            var o: [String: JSONValue] = ["title": .string(cap(r["title"]?.string, 20)), "text": .string(cap(r["text"]?.string, 400))]
            if let t = r["titleTrans"]?.string, !t.isEmpty { o["titleTrans"] = .string(cap(t, 60)) }
            if let t = r["textTrans"]?.string, !t.isEmpty { o["textTrans"] = .string(cap(t, 1200)) }
            return (o["title"]?.string ?? "").isEmpty && (o["text"]?.string ?? "").isEmpty ? nil : o
        }
        guard !clean.isEmpty else { return 0 }
        try set(charId, ["notes": arr(list(charId, "notes") + clean)])
        return clean.count
    }

    static func removeNote(_ charId: String, at i: Int) throws {
        var all = list(charId, "notes")
        guard all.indices.contains(i) else { return }
        all.remove(at: i)
        try set(charId, ["notes": arr(all)])
    }

    struct Visit: Equatable { var query: String; var site: String; var queryTrans: String }

    static func visits(_ charId: String) -> [Visit] {
        list(charId, "visits").map { Visit(query: $0["query"]?.string ?? "", site: $0["site"]?.string ?? "",
                                           queryTrans: $0["queryTrans"]?.string ?? "") }
    }

    @discardableResult
    static func addVisits(_ charId: String, _ rows: [JSONValue]) throws -> Int {
        let clean: [[String: JSONValue]] = rows.compactMap { r in
            let q = cap(r["query"]?.string, 40)
            guard !q.isEmpty else { return nil }
            var o: [String: JSONValue] = ["query": .string(q), "site": .string(cap(r["site"]?.string, 30))]
            if let t = r["queryTrans"]?.string, !t.isEmpty { o["queryTrans"] = .string(cap(t, 120)) }
            return o
        }
        guard !clean.isEmpty else { return 0 }
        // 新的在前，和真的浏览记录一样
        try set(charId, ["visits": arr(clean + list(charId, "visits"))])
        return clean.count
    }

    static func removeVisit(_ charId: String, at i: Int) throws {
        var all = list(charId, "visits")
        guard all.indices.contains(i) else { return }
        all.remove(at: i)
        try set(charId, ["visits": arr(all)])
    }

    // MARK: - 外观

    struct Icon: Equatable { var name = ""; var icon = ""; var imageId = "" }

    static func icon(_ charId: String, _ appId: String) -> Icon {
        let o = get(charId)?["icons"]?[appId]?.object ?? [:]
        return Icon(name: o["name"]?.string ?? "", icon: o["icon"]?.string ?? "", imageId: o["imageId"]?.string ?? "")
    }

    static func setIcon(_ charId: String, _ appId: String, _ patch: [String: JSONValue]) throws {
        var all = get(charId)?["icons"]?.object ?? [:]
        var one = all[appId]?.object ?? [:]
        for (k, v) in patch { one[k] = v }
        all[appId] = .object(one)
        try set(charId, ["icons": .object(all)])
    }

    /// 回到默认。换下来的图不删：同一张图可能还有别处在用，删图要先核引用（网页版第 20 条）
    static func resetIcon(_ charId: String, _ appId: String) throws {
        var all = get(charId)?["icons"]?.object ?? [:]
        all[appId] = nil
        try set(charId, ["icons": .object(all)])
    }

    static func wallpaper(_ charId: String) -> String { get(charId)?.string("wallpaper") ?? "" }

    /// 壁纸：换过的优先，没换过用角色卡的封面
    static func wallShown(_ char: Character) -> String {
        let own = wallpaper(char.id)
        return own.isEmpty ? char.row.string("cover") : own
    }

    static func setWallpaper(_ charId: String, _ imageId: String?) throws {
        try set(charId, ["wallpaper": imageId.map { .string($0) } ?? .null])
    }

    // MARK: - 相册（描述为主，图片可有可无；本子密码是明文，不是加密）

    struct PhoneAlbum: Identifiable, Equatable { var id: String; var name: String; var code: String }

    struct Photo: Identifiable, Equatable {
        var id: String, albumId: String, note: String, noteTrans: String, imageId: String, from: String
        var cropped: Bool, at: Double
    }

    static func keepOn(_ charId: String) -> Bool { get(charId)?["keepOn"]?.bool == true }
    static func setKeepOn(_ charId: String, _ on: Bool) throws { try set(charId, ["keepOn": .bool(on)]) }

    static func albums(_ charId: String) -> [PhoneAlbum] {
        list(charId, "albums").map { PhoneAlbum(id: $0["id"]?.string ?? "", name: $0["name"]?.string ?? "", code: $0["code"]?.string ?? "") }
    }

    static func photos(_ charId: String) -> [Photo] {
        list(charId, "photos").map {
            Photo(id: $0["id"]?.string ?? "", albumId: $0["albumId"]?.string ?? "", note: $0["note"]?.string ?? "",
                  noteTrans: $0["noteTrans"]?.string ?? "", imageId: $0["imageId"]?.string ?? "", from: $0["from"]?.string ?? "",
                  cropped: $0["cropped"]?.bool == true, at: $0["at"]?.number ?? 0)
        }
    }

    static func inAlbum(_ charId: String, _ albumId: String) -> [Photo] { photos(charId).filter { $0.albumId == albumId } }

    private static func stamp() -> String { String(Int(Date().millis), radix: 36) }

    @discardableResult
    static func addAlbum(_ charId: String, name: String, code: String) throws -> PhoneAlbum {
        let n = cap(name, 20)
        guard !n.isEmpty else { throw StoreError(message: "请填写名称") }
        let a = PhoneAlbum(id: "pa_\(stamp())", name: n, code: cap(code, 20))
        try set(charId, ["albums": arr(list(charId, "albums") + [["id": .string(a.id), "name": .string(a.name), "code": .string(a.code)]])])
        return a
    }

    static func updateAlbum(_ charId: String, _ albumId: String, name: String, code: String) throws {
        let n = cap(name, 20)
        guard !n.isEmpty else { throw StoreError(message: "请填写名称") }
        try set(charId, ["albums": arr(list(charId, "albums").map { a in
            guard a["id"]?.string == albumId else { return a }
            var x = a
            x["name"] = .string(n)
            x["code"] = .string(cap(code, 20))
            return x
        })])
    }

    /// 删本子不删照片：里面的退回未归类
    static func removeAlbum(_ charId: String, _ albumId: String) throws {
        try set(charId, [
            "albums": arr(list(charId, "albums").filter { $0["id"]?.string != albumId }),
            "photos": arr(list(charId, "photos").map { p in
                guard p["albumId"]?.string == albumId else { return p }
                var x = p
                x["albumId"] = .string("")
                return x
            }),
        ])
    }

    @discardableResult
    static func addPhotos(_ charId: String, _ rows: [JSONValue], albumId: String = "") throws -> Int {
        let now = Date().millis
        let base = stamp()
        let clean: [[String: JSONValue]] = rows.enumerated().compactMap { i, r in
            let note = cap(r["note"]?.string, 200)
            let img = r["imageId"]?.string ?? ""
            guard !note.isEmpty || !img.isEmpty else { return nil }
            var o: [String: JSONValue] = [
                "id": .string("pp_\(base)_\(i)"), "albumId": .string(cap(r["albumId"]?.string ?? albumId, 40)),
                "note": .string(note), "imageId": img.isEmpty ? .null : .string(img),
                "from": .string(r["from"]?.string == "you" ? "you" : ""), "cropped": .bool(r["cropped"]?.bool == true),
                "at": .number(r["at"]?.number ?? now),
            ]
            if let t = r["noteTrans"]?.string, !t.isEmpty { o["noteTrans"] = .string(cap(t, 600)) }
            return o
        }
        guard !clean.isEmpty else { return 0 }
        try set(charId, ["photos": arr(clean + list(charId, "photos"))])   // 新的在前
        return clean.count
    }

    static func updatePhoto(_ charId: String, _ photoId: String, _ patch: [String: JSONValue]) throws {
        try set(charId, ["photos": arr(list(charId, "photos").map { p in
            guard p["id"]?.string == photoId else { return p }
            var x = p
            for (k, v) in patch { x[k] = v }
            return x
        })])
    }

    static func removePhoto(_ charId: String, _ photoId: String) throws {
        try set(charId, ["photos": arr(list(charId, "photos").filter { $0["id"]?.string != photoId })])
    }

    nonisolated(unsafe) private static var openedAlbums: Set<String> = []

    static func albumOpen(_ charId: String, _ albumId: String) -> Bool {
        guard let a = albums(charId).first(where: { $0.id == albumId }) else { return true }
        return a.code.isEmpty || openedAlbums.contains("\(charId)/\(albumId)")
    }

    static func openAlbum(_ charId: String, _ albumId: String, code: String) -> Bool {
        guard let a = albums(charId).first(where: { $0.id == albumId }) else { return false }
        if !a.code.isEmpty && code.trimmingCharacters(in: .whitespaces) != a.code { return false }
        openedAlbums.insert("\(charId)/\(albumId)")
        return true
    }

    // MARK: - 会话

    struct Line: Equatable { var from: String; var text: String; var textTrans: String; var rejected: String; var proxy: String }

    struct PhoneChat: Identifiable, Equatable {
        var row: Row
        var id: String { row.id }
        var charId: String { row.string("charId") }
        var npcId: String { row.string("npcId") }
        var name: String { row.string("name") }
        var preview: String { row.string("preview") }
        var lastAt: Double { row.number("lastAt") ?? 0 }
        var filled: Bool { row.bool("filled") }
        var lines: [Line] {
            (row["lines"]?.array ?? []).compactMap(\.object).map {
                Line(from: $0["from"]?.string == "char" ? "char" : "other", text: $0["text"]?.string ?? "",
                     textTrans: $0["textTrans"]?.string ?? "", rejected: $0["rejected"]?.string ?? "", proxy: $0["proxy"]?.string ?? "")
            }
        }
    }

    static func chatsOf(_ charId: String) -> [PhoneChat] {
        ((try? Database.shared.all(chats, where: charId)) ?? []).map(PhoneChat.init(row:)).sorted { $0.lastAt > $1.lastAt }
    }

    static func chat(_ id: String) -> PhoneChat? {
        ((try? Database.shared.get(chats, id: id)) ?? nil).map(PhoneChat.init(row:))
    }

    static func chatNames(_ charId: String) -> [String] { chatsOf(charId).map(\.name) }

    @discardableResult
    static func addChat(_ charId: String, npcId: String = "", name: String, preview: String = "", previewTrans: String = "",
                        lastAt: Double = Date().millis, filled: Bool = false) throws -> PhoneChat? {
        let n = cap(name, 40)
        guard !n.isEmpty else { return nil }
        var f: [String: JSONValue] = ["charId": .string(charId), "npcId": .string(npcId), "name": .string(n),
                                      "preview": .string(cap(preview, 80)), "lines": .array([]), "lastAt": .number(lastAt),
                                      "filled": .bool(filled)]
        if !previewTrans.isEmpty { f["previewTrans"] = .string(cap(previewTrans, 240)) }
        let row = Row.new(prefix: "pc", f)
        try Database.shared.put(chats, row)
        return PhoneChat(row: row)
    }

    /// 空手起一条：登着它的手机给一个还没聊过的人发消息
    static func startChat(_ charId: String, npcId: String, name: String) throws -> PhoneChat {
        let n = cap(name, 40)
        guard !n.isEmpty else { throw StoreError(message: "请填写对方的名称") }
        guard !chatNames(charId).contains(n) else { throw StoreError(message: "这台手机上已经有这个人了") }
        guard let c = try addChat(charId, npcId: npcId, name: n, filled: true) else { throw StoreError(message: "未能建立会话") }
        return c
    }

    private static func patchChat(_ id: String, _ f: [String: JSONValue]) throws {
        guard var row = try Database.shared.get(chats, id: id) else { throw StoreError(message: "这条会话已经不在了") }
        for (k, v) in f { row[k] = v }
        row.touch()
        try Database.shared.put(chats, row)
    }

    /// 整段换成生成出来的那一段
    static func fillChat(_ id: String, _ lines: [JSONValue]) throws {
        let clean: [JSONValue] = lines.compactMap { l in
            let t = cap(l["text"]?.string, 300)
            guard !t.isEmpty else { return nil }
            var o: [String: JSONValue] = ["from": .string(l["from"]?.string == "char" ? "char" : "other"), "text": .string(t)]
            if let tr = l["textTrans"]?.string, !tr.isEmpty { o["textTrans"] = .string(cap(tr, 900)) }
            return .object(o)
        }
        try patchChat(id, ["lines": .array(clean), "filled": .bool(true)])
    }

    /// 往后接一句。列表上的最后一句与排序跟着更新
    static func addLine(_ id: String, _ line: [String: JSONValue]) throws {
        guard let c = chat(id) else { throw StoreError(message: "这条会话已经不在了") }
        let t = cap(line["text"]?.string, 300)
        guard !t.isEmpty else { return }
        var o = line
        o["text"] = .string(t)
        o["at"] = .number(Date().millis)
        try patchChat(id, ["lines": .array((c.row["lines"]?.array ?? []) + [.object(o)]), "preview": .string(cap(t, 80)),
                           "lastAt": .number(Date().millis), "filled": .bool(true)])
    }

    static let proxyAware = "aware", proxyUnaware = "unaware"

    static func proxyMode(_ charId: String) -> String {
        ((try? Repo.character(charId)) ?? nil)?.row.bool("proxyAware") == true ? proxyAware : proxyUnaware
    }

    /// 代发（网页版 proxy.sendOther，4.308）：以角色的身份发给对方。对方把角色拉黑或删了就标出来，不要回话。
    /// 返回被拒收的原因，空串为送达
    static func sendOther(_ id: String, _ text: String, mode: String) throws -> String {
        guard let c = chat(id) else { throw StoreError(message: "这条会话已经不在了") }
        if var ch = try Repo.character(c.charId), ch.row.bool("proxyAware") != (mode == proxyAware) {
            ch.row["proxyAware"] = .bool(mode == proxyAware)
            ch.row.touch()
            try Database.shared.put(Collections.characters, ch.row)
        }
        var rejected = ""
        if !c.npcId.isEmpty {
            let pid = ((try? Repo.activePersona()) ?? nil)?.id ?? ""
            let s = Ties.state(c.npcId, c.charId, pid)
            rejected = s.blocked ? "blocked" : s.removed ? "removed" : ""
        }
        var line: [String: JSONValue] = ["from": .string("char"), "text": .string(text),
                                         "proxy": .string(mode == proxyAware ? proxyAware : proxyUnaware)]
        if !rejected.isEmpty { line["rejected"] = .string(rejected) }
        try addLine(id, line)
        return rejected
    }

    // MARK: - 代发进提示词（网页版 proxy.js 的 factsForSender、factsForRecipient，context/proxy.js）
    //
    // 只取有代发参与的那几句：代发的那句，和对方紧接着回的（re）。生成出来的那几段不算，那是这台手机的背景。
    // 被代发的那一方也记得：对它来说那都是那个角色发的。只陈述事实（第 16 条）

    private static func clip(_ s: String) -> String { String(s.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200)) }

    private static func proxied(_ c: PhoneChat) -> [[String: JSONValue]] {
        var out: [[String: JSONValue]] = []
        var open = false
        for l in (c.row["lines"]?.array ?? []).compactMap(\.object) {
            if !(l["proxy"]?.string ?? "").isEmpty { out.append(l); open = (l["rejected"]?.string ?? "").isEmpty; continue }
            if open && l["from"]?.string == "other" && l["re"]?.bool == true { out.append(l); continue }
            open = false
        }
        return out
    }

    /// 带进提示词的条数（settings.proxyLines，默认 10，0 为全带）
    private static func cap(_ s: AppSettings) -> Int { max(0, Int(s.num("proxyLines", 10))) }

    /// 按时刻排，同一时刻保持原来的先后（sort 不保证稳定）
    private static func byTime(_ list: [(PhoneChat, [String: JSONValue])]) -> [(PhoneChat, [String: JSONValue])] {
        list.enumerated().sorted {
            let a = $0.element.1["at"]?.number ?? 0, b = $1.element.1["at"]?.number ?? 0
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
    }

    private static func tail<T>(_ list: [T], _ n: Int) -> [T] { n > 0 ? Array(list.suffix(n)) : list }

    static func factsForSender(_ char: Character, personaId: String, userName: String, settings s: AppSettings) -> [String] {
        var out: [String] = []
        let n = cap(s)
        let mine = ((try? Repo.chats()) ?? []).filter { !$0.isGroup && $0.characterIds == [char.id] && ($0.personaId.isEmpty || $0.personaId == personaId) }
            .flatMap { ((try? Repo.messages(chatId: $0.id)) ?? []).filter { $0.row.string("proxy") == proxyAware } }
        for m in tail(mine, n) { out.append("\(userName) logged into your account and sent this to \(userName) as you: 「\(clip(m.content))」") }
        let lines = byTime(chatsOf(char.id).flatMap { c in proxied(c).map { (c, $0) } })
        for (c, l) in tail(lines, n) {
            let text = clip(l["text"]?.string ?? "")
            if l["from"]?.string == "other" { out.append("\(c.name) replied: 「\(text)」"); continue }
            let head = l["proxy"]?.string == proxyAware ? "\(userName) logged into your account and sent to \(c.name) as you" : "You sent to \(c.name)"
            let rej = l["rejected"]?.string ?? ""
            out.append("\(head): 「\(text)」" + (rej.isEmpty ? "" : " (not delivered: \(c.name) has \(rej == "blocked" ? "blocked" : "removed") you)"))
        }
        return out
    }

    static func factsForRecipient(_ char: Character, settings s: AppSettings) -> [String] {
        let rows = ((try? Database.shared.all(chats)) ?? []).map(PhoneChat.init(row:)).filter { $0.npcId == char.id }
        let lines = byTime(rows.flatMap { c in proxied(c).filter { ($0["rejected"]?.string ?? "").isEmpty }.map { (c, $0) } })
        return tail(lines, cap(s)).map { c, l in
            let sender = ((try? Repo.character(c.charId)) ?? nil)?.name ?? "someone"
            let text = clip(l["text"]?.string ?? "")
            return l["from"]?.string == "other" ? "You replied to \(sender): 「\(text)」" : "\(sender) messaged you: 「\(text)」"
        }
    }

    /// [手机上的对话] 区块
    static func proxyBlock(char: Character, personaId: String, userName: String, settings s: AppSettings) -> String {
        let lines = factsForSender(char, personaId: personaId, userName: userName.isEmpty ? "the user" : userName, settings: s)
            + factsForRecipient(char, settings: s)
        return lines.isEmpty ? "" : "[手机上的对话]\n" + lines.joined(separator: "\n")
    }

    static func removeChat(_ id: String) throws { try Database.shared.delete(chats, id: id) }

    // MARK: - 生成（一项一次请求，只在用户点了时调；只发角色设定，不发对话历史）

    private static func personaOf(_ c: Character) -> String {
        let s = [c.persona, c.signature, c.row.string("description")].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return s.isEmpty ? "（角色卡里还没有写人设）" : s
    }

    private static func runJSON(_ task: String, _ system: String, maxTokens: Int) async throws -> JSONValue {
        let r = try await AIService.shared.send(task: task, system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: maxTokens)
        guard let j = JSONReply.parse(r.text), j.object != nil else { throw StoreError(message: JSONReply.failure(r.text)) }
        return j
    }

    private static func character(_ charId: String) throws -> Character {
        guard let c = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        return c
    }

    /// 让模型定一个开机密码，连同三条线索。位数不对不收：一个开不了的锁比没有锁糟
    @discardableResult
    static func makeLock(_ charId: String, digits: Int) async throws -> Int {
        let c = try character(charId)
        let n = digits == 6 ? 6 : 4
        let j = try await runJSON("phone.lock", Templates.render("task.phone-lock", [
            "charName": c.name, "charPersona": personaOf(c), "digits": "\(n)",
        ], settings: .load()), maxTokens: 500)
        let code = (j["code"]?.string ?? j["code"]?.number.map { String(Int($0)) } ?? "").filter { $0.isASCII && $0.isNumber }
        guard code.count == n else { throw StoreError(message: "模型给的不是 \(n) 位数字，请重试") }
        let hints = (j["hints"]?.array ?? []).compactMap(\.string)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(3)
        guard !hints.isEmpty else { throw StoreError(message: "模型没有给出提示，请重试") }
        try setLock(charId, Lock(code: code, why: (j["why"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                 hints: Array(hints), src: "ai"))
        return n
    }

    // 只是爱称的名字：那是在叫你，不是另一个联系人（网页版 4.371）
    private static let pet = #"^(?:我的|我家)?(?:老婆|老公|媳妇|宝贝|宝宝|宝|亲爱的|亲亲|乖乖|小可爱|心肝|honey|baby|babe|darling|dear|sweetheart|wifey|hubby)(?:大人|儿|们)?$|老婆|老公|媳妇|宝贝|亲爱的"#

    /// 这个角色认识的人（关系网），名字对得上已有角色
    static func known(_ charId: String) -> [(id: String, name: String, label: String)] {
        let rel = (((try? Repo.character(charId)) ?? nil)?.row["relations"]?.array ?? []).compactMap(\.object)
        return rel.compactMap { r -> (id: String, name: String, label: String)? in
            guard let id = r["charId"]?.string, let c = (try? Repo.character(id)) ?? nil else { return nil }
            return (id: c.id, name: c.name, label: r["label"]?.string ?? "")
        }
    }

    /// 你用过的名字：生成的会话不能再有一条和你的。
    /// 同网页版 tasks/phone.js 的 userNamesOf：身份名（去首尾空白）在前，角色给你改的备注（remark.js theirsOf）在后，去重（4.371）
    static func userNames(_ charId: String) -> [String] {
        var out: [String] = []
        for p in (try? Repo.personas()) ?? [] {
            let n = p.row.string("name").trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty && !out.contains(n) { out.append(n) }
        }
        for c in (try? Repo.chats()) ?? [] where c.characterIds.contains(charId) {
            let r = remarkClean(c.row.string("charRemark"))
            if !r.isEmpty && !out.contains(r) { out.append(r) }
        }
        return out
    }

    /// 填进提示词的「用户叫什么」：同网页版 `me.join('、') || '对方'`
    static func userNamesText(_ charId: String) -> String {
        let me = userNames(charId)
        return me.isEmpty ? "对方" : me.joined(separator: "、")
    }

    /// 网页版 remark.js 的 clean：空白折成一个空格、去首尾、最多 20 字
    static func remarkClean(_ s: String) -> String {
        let one = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(one.prefix(20))
    }

    static func isUser(_ name: String, me: [String], known: [String]) -> Bool {
        if me.contains(name) { return true }
        if name.range(of: #"^(\{\{\s*user\s*\}\}|user|你|我)$"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return name.range(of: pet, options: [.regularExpression, .caseInsensitive]) != nil && !known.contains(name)
    }

    @discardableResult
    static func makeChats(_ charId: String, count: Int) async throws -> Int {
        let c = try character(charId)
        let n = max(1, count)
        let kn = known(charId)
        let me = userNames(charId)
        let j = try await runJSON("phone.chats", Templates.render("task.phone-chats", [
            "charName": c.name, "charPersona": personaOf(c), "count": "\(n)",
            "known": kn.isEmpty ? "（还没有建立关系的人）" : kn.map { "- \($0.name)\($0.label.isEmpty ? "" : "（\($0.label)）")" }.joined(separator: "\n"),
            "existing": (chatNames(charId) + me).isEmpty ? "（还没有）" : (chatNames(charId) + me).map { "- \($0)" }.joined(separator: "\n"),
            "userNames": me.isEmpty ? "对方" : me.joined(separator: "、"),
        ], settings: .load()), maxTokens: 300 + n * 60)
        var have = Set(chatNames(charId))
        var added = 0
        var at = Date().millis
        for r in j["chats"]?.array ?? [] {
            let name = (r["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !have.contains(name), !isUser(name, me: me, known: kn.map(\.name)) else { continue }
            have.insert(name)
            try addChat(charId, npcId: kn.first(where: { $0.name == name })?.id ?? "", name: name,
                        preview: r["preview"]?.string ?? "", lastAt: at)
            at -= 60000
            added += 1
        }
        guard added > 0 else { throw StoreError(message: "这一次没有生成出内容，可以再试一次") }
        return added
    }

    /// 点进某一条才生成那一段
    @discardableResult
    static func makeChat(_ id: String, count: Int = 12) async throws -> Int {
        guard let row = chat(id) else { throw StoreError(message: "这条会话已经不在了") }
        let c = try character(row.charId)
        let npc = row.npcId.isEmpty ? nil : (try? Repo.character(row.npcId)) ?? nil
        let n = max(2, count)
        let j = try await runJSON("phone.chat", Templates.render("task.phone-chat", [
            "charName": c.name, "charPersona": personaOf(c), "other": row.name,
            "otherPersona": npc.map(personaOf) ?? "（没有更多设定，按上面的关系与最后一句推断）",
            "preview": row.preview.isEmpty ? "（没有记下最后一句）" : row.preview, "count": "\(n)",
            "userNames": userNamesText(row.charId),
        ], settings: .load()), maxTokens: 300 + n * 60)
        let lines = j["lines"]?.array ?? []
        guard !lines.isEmpty else { throw StoreError(message: "这一次没有生成出内容，可以再试一次") }
        try fillChat(id, lines)
        return lines.count
    }

    /// 代发之后对方回话。一次发送一次请求，不重试
    @discardableResult
    static func reply(_ id: String) async throws -> Int {
        guard let row = chat(id) else { throw StoreError(message: "这条会话已经不在了") }
        let c = try character(row.charId)
        let npc = row.npcId.isEmpty ? nil : (try? Repo.character(row.npcId)) ?? nil
        let history = row.lines.suffix(30).map { "\($0.from == "char" ? c.name : row.name): \($0.text)" }.joined(separator: "\n")
        let j = try await runJSON("phone.reply", Templates.render("task.phone-reply", [
            "charName": c.name, "charPersona": personaOf(c), "other": row.name,
            "otherPersona": npc.map(personaOf) ?? "（没有更多设定，按上面的对话推断）",
            "history": history.isEmpty ? "（还没有说过话）" : history,
            "userNames": userNamesText(row.charId),
        ], settings: .load()), maxTokens: 400)
        let texts = (j["lines"]?.array ?? []).compactMap { $0["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { throw StoreError(message: "这一次没有回话，可以再试一次") }
        for t in texts { try addLine(id, ["from": .string("other"), "text": .string(t), "re": .bool(true)]) }
        return texts.count
    }

    @discardableResult
    static func makeAlbum(_ charId: String, count: Int) async throws -> Int {
        let c = try character(charId)
        let n = max(1, count)
        let have = photos(charId).prefix(40).map { "- \($0.note)" }
        let j = try await runJSON("phone.album", Templates.render("task.phone-album", [
            "charName": c.name, "charPersona": personaOf(c), "count": "\(n)",
            "existing": have.isEmpty ? "（还没有）" : have.joined(separator: "\n"),
        ], settings: .load()), maxTokens: 300 + n * 40)
        let rows = (j["photos"]?.array ?? []).map { JSONValue.object(["note": .string($0["note"]?.string ?? "")]) }
        let added = try addPhotos(charId, rows)
        guard added > 0 else { throw StoreError(message: "这一次没有生成出内容，可以再试一次") }
        return added
    }

    @discardableResult
    static func makeNotes(_ charId: String, count: Int) async throws -> Int {
        let c = try character(charId)
        let n = max(1, count)
        let have = notes(charId).map { "- \($0.title)" }
        let j = try await runJSON("phone.notes", Templates.render("task.phone-notes", [
            "charName": c.name, "charPersona": personaOf(c), "count": "\(n)",
            "existing": have.isEmpty ? "（还没有）" : have.joined(separator: "\n"),
        ], settings: .load()), maxTokens: 400 + n * 120)
        let added = try addNotes(charId, j["notes"]?.array ?? [])
        guard added > 0 else { throw StoreError(message: "这一次没有生成出内容，可以再试一次") }
        return added
    }

    @discardableResult
    static func makeVisits(_ charId: String, count: Int) async throws -> Int {
        let c = try character(charId)
        let n = max(1, count)
        let have = visits(charId).map { "- \($0.query)" }
        let j = try await runJSON("phone.visits", Templates.render("task.phone-visits", [
            "charName": c.name, "charPersona": personaOf(c), "count": "\(n)",
            "existing": have.isEmpty ? "（还没有）" : have.joined(separator: "\n"),
        ], settings: .load()), maxTokens: 300 + n * 40)
        let added = try addVisits(charId, j["visits"]?.array ?? [])
        guard added > 0 else { throw StoreError(message: "这一次没有生成出内容，可以再试一次") }
        return added
    }

    /// 生成页上的几项（网页版 MAKERS）。lock 那一项不在「全部生成」里
    struct Maker: Identifiable { let id: String; let label: String; let icon: String; let def: Int; let solo: Bool }

    static let makers: [Maker] = [
        .init(id: "chats", label: "聊天", icon: "message", def: 6, solo: false),
        .init(id: "album", label: "相册", icon: "photo", def: 8, solo: false),
        .init(id: "notes", label: "备忘录", icon: "note.text", def: 6, solo: false),
        .init(id: "visits", label: "浏览记录", icon: "magnifyingglass", def: 10, solo: false),
        .init(id: "lock", label: "锁屏密码", icon: "lock", def: 4, solo: true),
    ]

    static func run(_ makerId: String, _ charId: String, _ n: Int) async throws -> String {
        switch makerId {
        case "chats": let k = try await makeChats(charId, count: n); return "新增 \(k) 条会话"
        case "album": let k = try await makeAlbum(charId, count: n); return "新增 \(k) 张"
        case "notes": let k = try await makeNotes(charId, count: n); return "新增 \(k) 条"
        case "visits": let k = try await makeVisits(charId, count: n); return "新增 \(k) 条"
        case "lock": let k = try await makeLock(charId, digits: n); return "已重新设定 \(k) 位密码，现在需要重新推测"
        default: return ""
        }
    }

    static func state(_ makerId: String, _ charId: String) -> String {
        switch makerId {
        case "chats": return "已有 \(chatsOf(charId).count) 条会话"
        case "album": return "已有 \(photos(charId).count) 张"
        case "notes": return "已有 \(notes(charId).count) 条"
        case "visits": return "已有 \(visits(charId).count) 条"
        case "lock": return lock(charId)?.src == "ai" ? "当前密码由模型依据该角色的设定生成" : "当前密码依据角色卡中的信息推出，未调用接口"
        default: return ""
        }
    }
}
