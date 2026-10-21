import SwiftUI

/// 美化（网页版 system/skin.js，ARCHITECTURE 4.111）。数据域 skins，与网页版同一格式；一段会话挂哪一份记在 chat.skinId。
///
/// 原生版不跑 CSS（规约第 2 节）：只读得懂的那几格，其余原样存着、写回时不丢。
///     tokens  消息间距、同一轮内间距、气泡圆角、气泡左右与上下内距、气泡字号
///     shape   头像形状（圆形、方形、圆角方形）
///     gen     生成器里的「头像」一组：显示头像、大小、圆角；「气泡」一组：改哪一边、底色、文字颜色、圆角、内距、字号
/// 自定义 CSS：由 `CssSkin.compile` 读成原生样式（`compiled`，按原文缓存），读得懂的照着画，读不懂的记进还原情况。
/// 头像框、贴图、小尾巴等不在原生版里画。
///
/// 层叠照网页版 skin.js 的 compile：令牌（与头像形状）在前、手写 CSS 的变量在后、生成器最后（生成器那一段带 !important）。
/// 手写 CSS 之后又动过令牌或生成器的（`late`），令牌排到手写 CSS 之后。
enum Skins {
    static let collection = "skins"

    /// 与网页版 TOKENS 同一份（id、名字、默认值、范围）
    struct Token { let id: String; let label: String; let def: Double; let min: Double; let max: Double }
    static let tokens: [Token] = [
        Token(id: "gap", label: "消息间距", def: 16, min: 0, max: 48),
        Token(id: "gapIn", label: "同一轮内间距", def: 5, min: 0, max: 24),
        Token(id: "bubbleR", label: "气泡圆角", def: 14, min: 0, max: 30),
        Token(id: "bubblePX", label: "气泡左右内距", def: 12, min: 2, max: 32),
        Token(id: "bubblePY", label: "气泡上下内距", def: 8, min: 2, max: 28),
        Token(id: "bubbleFS", label: "气泡字号", def: 14, min: 11, max: 24),
    ]

    static let shapes: [(id: String, label: String)] = [("", "跟随默认"), ("round", "圆形"), ("square", "方形"), ("soft", "圆角方形")]
    static let faceShow: [(id: String, label: String)] = [("both", "双方"), ("theirs", "仅角色"), ("mine", "仅自己"), ("none", "都不显示")]
    static let sides: [(id: String, label: String)] = [("all", "双方"), ("theirs", "角色"), ("mine", "自己")]

    // MARK: - 读写

    static func all() -> [Row] {
        ((try? Database.shared.all(collection)) ?? []).sorted { ($0.number("updatedAt") ?? 0) > ($1.number("updatedAt") ?? 0) }
    }

    static func get(_ id: String) -> Row? {
        guard !id.isEmpty else { return nil }
        return try? Database.shared.get(collection, id: id)
    }

    /// 这段会话用哪一份：挂着的那一份；没挂就用设为全局的那一份。「外观」里的总开关关着时两层都不用
    static func of(_ chat: Chat?, settings s: AppSettings = .load()) -> Row? {
        if s.raw["skinOff"]?.bool == true { return nil }
        if let id = chat?.row.string("skinId"), let r = get(id) { return r }
        guard let r = get(s.raw["globalSkinId"]?.string ?? "") else { return nil }
        let scope = r["scope"]?.array?.compactMap(\.string) ?? (r["scope"]?.string.map { [$0] } ?? [])
        return scope.contains("shell") ? r : nil
    }

    static func usedBy(_ id: String) -> Int {
        ((try? Repo.chats()) ?? []).filter { $0.row.string("skinId") == id }.count
    }

    @discardableResult
    static func create(name: String) throws -> Row {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = Row.new(prefix: "sk", [
            "name": .string(n.isEmpty ? "未命名" : n), "tokens": .object([:]), "shape": .string(""), "css": .string(""),
            "scope": .array([.string("chat")]), "gen": .object([:]), "frame": .string(""), "frameWho": .string("both"),
            "frameScale": .number(160),
        ])
        try Database.shared.put(collection, r)
        return r
    }

    /// 改一份。改动对挂着它的每段会话都生效
    static func update(_ id: String, _ change: (inout Row) -> Void) throws {
        guard var r = get(id) else { throw StoreError(message: "这份美化已不存在") }
        change(&r)
        r.touch()
        try Database.shared.put(collection, r)
        NotificationCenter.default.post(name: .eiraSkinChanged, object: nil)
    }

    /// 删一份：挂着它的会话一并取下，设为全局的也一并取消
    static func remove(_ id: String) throws {
        for var c in try Repo.chats() where c.row.string("skinId") == id {
            c.row["skinId"] = .string("")
            c.row.touch()
            try Repo.save(c)
        }
        var s = try AppSettings.loadForWrite()
        if s.raw["globalSkinId"]?.string == id {
            s.raw["globalSkinId"] = .string("")
            try s.save()
        }
        try Database.shared.delete(collection, id: id)
        NotificationCenter.default.post(name: .eiraSkinChanged, object: nil)
    }

    /// 挂上或取下（传空串）
    static func attach(_ chatId: String, _ skinId: String) throws {
        guard var c = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
        c.row["skinId"] = .string(skinId)
        c.row.touch()
        try Repo.save(c)
        NotificationCenter.default.post(name: .eiraSkinChanged, object: chatId)
    }

    static func token(_ r: Row, _ id: String) -> Double? { num(r["tokens"]?.object?[id]) }

    /// 有手写 CSS 时又动了令牌、生成器或头像形状：记一笔 late，这几层排到 CSS 之后（网页版 skin.js 的 update，4.615）
    static func markLate(_ r: inout Row) {
        if !r.string("css").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { r["late"] = .bool(true) }
    }

    static func setToken(_ id: String, _ key: String, _ v: Double?) throws {
        try update(id) { r in
            var t = r["tokens"]?.object ?? [:]
            if let v { t[key] = .number(v.rounded()) } else { t.removeValue(forKey: key) }
            r["tokens"] = .object(t)
            markLate(&r)
        }
    }

    static func genValue(_ r: Row, _ group: String, _ item: String) -> JSONValue? {
        guard let v = r["gen"]?.object?[group]?.object?[item], !v.isNull else { return nil }
        if v.string == "" { return nil }
        return v
    }

    static func setGen(_ id: String, _ group: String, _ item: String, _ v: JSONValue?) throws {
        try update(id) { r in
            var g = r["gen"]?.object ?? [:]
            var grp = g[group]?.object ?? [:]
            if let v { grp[item] = v } else { grp.removeValue(forKey: item) }
            g[group] = .object(grp)
            r["gen"] = .object(g)
            markLate(&r)
        }
    }

    private static func num(_ v: JSONValue?) -> Double? {
        if let n = v?.number, n.isFinite { return n }
        if let s = v?.string, let n = Double(s.trimmingCharacters(in: .whitespaces)), n.isFinite { return n }
        return nil
    }

    /// #rgb、#rrggbb、#rrggbbaa。认不出的当没写
    static func color(_ s: String?) -> Color? {
        guard var h = s?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return nil }
        h.removeFirst()
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let n = UInt64(h, radix: 16) else { return nil }
        let (r, g, b, a): (UInt64, UInt64, UInt64, UInt64) = h.count == 6
            ? ((n >> 16) & 255, (n >> 8) & 255, n & 255, 255)
            : ((n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255)
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    // MARK: - 画出来用的那一份

    struct Bubble: Equatable {
        var radius: CGFloat = Theme.bubbleRadius
        var padX: CGFloat = Theme.bubblePadX
        var padY: CGFloat = Theme.bubblePadY
        var font: CGFloat = Theme.bubbleFont
        var bg: String = ""
        var fg: String = ""
        /// 生成器定下的那几项（r、px、py、fs）：网页版生成器写的带 !important，手写 CSS 盖不过
        var fixed: Set<String> = []
        var fill: Color? { Skins.color(bg) }
        var text: Color? { Skins.color(fg) }

        /// 手写 CSS 里气泡的样式，去掉生成器已经定下的那几项（生成器赢，同网页版的 !important）
        func overriding(_ st: CssStyle) -> CssStyle {
            var out = st
            if fill != nil { out.background = nil }
            if text != nil { out.color = nil }
            if fixed.contains("r") { out.radius = nil; out.radiusPercent = nil }
            if fixed.contains("px") || fixed.contains("py") { out.padding = nil }
            if fixed.contains("fs") { out.fontSize = nil }
            return out
        }
    }

    struct Look: Equatable {
        var mine = Bubble()
        var theirs = Bubble()
        /// 一轮与一轮之间、同一个人接着说的
        var gap: CGFloat = Theme.sp4
        var gapIn: CGFloat = 5
        var avatarSize: CGFloat = Theme.avatarSize
        /// 头像圆角：占边长的比例（0.5 为正圆）。nil 为默认
        var avatarRound: CGFloat?
        /// 头像圆角写的是像素（CSS 变量 --ph-avatar-r: 18px）。与 avatarRound 只有一个有值
        var avatarRadiusPx: CGFloat?
        var show = "both"
        /// 美化 CSS 的 --ph-navbar-h、--ph-composer-h、--ph-composer-pad。nil 为原生默认
        var navbarH: CGFloat?
        var composerH: CGFloat?
        var composerPad: CGFloat?

        func bubble(_ mine: Bool) -> Bubble { mine ? self.mine : theirs }
        func showFace(_ mine: Bool) -> Bool { show == "both" || show == (mine ? "mine" : "theirs") }
        func radius(_ size: CGFloat) -> CGFloat {
            if let avatarRadiusPx { return Swift.min(avatarRadiusPx, size / 2) }
            guard let avatarRound else { return size * 14 / 44 }
            return size * avatarRound
        }
    }

    /// 画出来用的那一份。css 是这一份的手写 CSS 读出来的结果（`compiled`），其中的 --ph-* 变量按网页版的先后叠进来
    static func look(_ r: Row?, css: CssCompiled? = nil) -> Look {
        var l = Look()
        guard let r else { return l }
        let vars = css?.vars ?? [:]
        let late = r["late"]?.bool == true
        if late { applyVars(&l, vars) }
        applyTokens(&l, r)
        if !late { applyVars(&l, vars) }
        applyGen(&l, r)
        return l
    }

    private static func cg(_ v: Double?, _ lo: Double, _ hi: Double) -> CGFloat? {
        v.map { CGFloat(Swift.min(hi, Swift.max(lo, $0))) }
    }

    /// 令牌与头像形状（网页版生成在 :root 上的那几个变量）
    private static func applyTokens(_ l: inout Look, _ r: Row) {
        for side in [true, false] {
            var b = l.bubble(side)
            if let v = cg(token(r, "bubbleR"), 0, 200) { b.radius = v }
            if let v = cg(token(r, "bubblePX"), 0, 200) { b.padX = v }
            if let v = cg(token(r, "bubblePY"), 0, 200) { b.padY = v }
            if let v = cg(token(r, "bubbleFS"), 6, 60) { b.font = v }
            if side { l.mine = b } else { l.theirs = b }
        }
        if let v = cg(token(r, "gap"), 0, 200) { l.gap = v }
        if let v = cg(token(r, "gapIn"), 0, 200) { l.gapIn = v }
        // 头像形状在令牌这一层：手写 CSS 的 --ph-avatar-r 盖得过它，生成器的圆角也盖得过它
        let shape: CGFloat?
        switch r.string("shape") {
        case "round": shape = 0.5
        case "square": shape = 4 / Theme.avatarSize
        case "soft": shape = 10 / Theme.avatarSize
        default: shape = nil
        }
        if let shape { l.avatarRound = shape; l.avatarRadiusPx = nil }
    }

    /// 生成器的「气泡」一组（只改选定的那一边）与「头像」一组。网页版生成器写的带 !important，排在最后
    private static func applyGen(_ l: inout Look, _ r: Row) {
        let side = genValue(r, "bubble", "side")?.string ?? "all"
        func apply(_ b: inout Bubble) {
            if let v = cg(num(genValue(r, "bubble", "r")), 0, 200) { b.radius = v; b.fixed.insert("r") }
            if let v = cg(num(genValue(r, "bubble", "px")), 0, 200) { b.padX = v; b.fixed.insert("px") }
            if let v = cg(num(genValue(r, "bubble", "py")), 0, 200) { b.padY = v; b.fixed.insert("py") }
            if let v = cg(num(genValue(r, "bubble", "fs")), 6, 60) { b.font = v; b.fixed.insert("fs") }
            if let v = genValue(r, "bubble", "bg")?.string, color(v) != nil { b.bg = v }
            if let v = genValue(r, "bubble", "fg")?.string, color(v) != nil { b.fg = v }
        }
        if side != "mine" { apply(&l.theirs) }
        if side != "theirs" { apply(&l.mine) }
        if let v = cg(num(genValue(r, "avatar", "size")), 16, 120) { l.avatarSize = v }
        if let v = num(genValue(r, "avatar", "round")), v > 0 {
            l.avatarRound = CGFloat(Swift.min(50, v)) / 100
            l.avatarRadiusPx = nil
        }
        let show = genValue(r, "avatar", "show")?.string ?? "both"
        l.show = faceShow.contains { $0.id == show } ? show : "both"
    }

    /// 美化 CSS 的公开变量（网页版 skin-contract.js 的 VARS）落到原生的几格上。变量名不带 `--`
    static func applyVars(_ l: inout Look, _ vars: [String: String]) {
        guard !vars.isEmpty else { return }
        func px(_ k: String, _ lo: Double, _ hi: Double) -> CGFloat? { cg(vars[k].flatMap(cssPx), lo, hi) }
        for side in [true, false] {
            var b = l.bubble(side)
            if let v = px("ph-bubble-r", 0, 200) { b.radius = v }
            if let v = px("ph-bubble-px", 0, 200) { b.padX = v }
            if let v = px("ph-bubble-py", 0, 200) { b.padY = v }
            if let v = px("ph-bubble-fs", 6, 60) { b.font = v }
            if side { l.mine = b } else { l.theirs = b }
        }
        if let v = px("ph-bubble-gap", 0, 200) { l.gap = v }
        if let v = px("ph-bubble-gap-in", 0, 200) { l.gapIn = v }
        if let v = px("ph-avatar-size", 16, 120) { l.avatarSize = v }
        if let raw = vars["ph-avatar-r"] {
            if let p = cssPercent(raw) {
                l.avatarRound = CGFloat(Swift.min(50, Swift.max(0, p))) / 100
                l.avatarRadiusPx = nil
            } else if let v = cg(cssPx(raw), 0, 200) {
                l.avatarRadiusPx = v
                l.avatarRound = nil
            }
        }
        if let v = px("ph-navbar-h", 24, 120) { l.navbarH = v }
        if let v = px("ph-composer-h", 24, 80) { l.composerH = v }
        if let v = px("ph-composer-pad", 0, 40) { l.composerPad = v }
    }

    /// 「14px」「14」「14.5px」读成数字；别的单位（em、%、vh）与 calc() 不认
    static func cssPx(_ s: String) -> Double? {
        var t = s.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasSuffix("px") { t.removeLast(2) }
        guard let n = Double(t.trimmingCharacters(in: .whitespaces)), n.isFinite else { return nil }
        return n
    }

    static func cssPercent(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix("%"), let n = Double(t.dropLast().trimmingCharacters(in: .whitespaces)), n.isFinite else { return nil }
        return n
    }

    // MARK: - 手写 CSS

    private static let cssLock = NSLock()
    nonisolated(unsafe) private static var cssCache: [String: CssCompiled] = [:]

    /// 这一份的手写 CSS 读成原生样式。按 CSS 原文缓存：同一段只读一次。没写 CSS 为 nil
    static func compiled(_ row: Row?) -> CssCompiled? {
        guard let row else { return nil }
        let css = row.string("css")
        guard !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return compiled(css: css)
    }

    static func compiled(css: String) -> CssCompiled {
        cssLock.lock()
        defer { cssLock.unlock() }
        if let hit = cssCache[css] { return hit }
        // 换了一段 CSS：自定义字体可能也换过，字体的查找结果一并重来
        CssFonts.reset()
        let out = CssSkin.compile(css)
        if cssCache.count >= 8 { cssCache.removeAll() }
        cssCache[css] = out
        return out
    }

    /// 这份美化里原生版画不出来的那几样，导入、挂上时写明
    static func skipped(_ r: Row) -> [String] {
        var out: [String] = []
        // 自定义 CSS 不在这里：读得懂的照着画，读不懂的逐条列在「查看还原情况」里
        if !r.string("frame").isEmpty { out.append("头像框") }
        let known: [String: Set<String>] = ["avatar": ["show", "size", "round"], "bubble": ["side", "bg", "fg", "r", "px", "py", "fs"]]
        for (g, v) in r["gen"]?.object ?? [:] {
            let items = (v.object ?? [:]).filter { !$0.value.isNull && $0.value.string != "" && $0.value.bool != false }
            if items.keys.contains(where: { !(known[g]?.contains($0) ?? false) }) { out.append("生成器的其他样式"); break }
        }
        return out
    }

    // MARK: - 美化包（网页版 skin.js 的 unpack / install，skinfile.js 的 parse；ARCHITECTURE 4.127、4.239）

    /// 读出来的一个美化包。只认识的字段才留下（同网页版 unpack）
    struct Pack: Equatable {
        var name = "未命名"
        var author = ""
        var scope: [String] = ["chat"]
        var gen: [String: JSONValue] = [:]
        var tokens: [String: JSONValue] = [:]
        var shape = ""
        var frame = ""
        var frameWho = "both"
        var frameScale: Double = 160
        var css = ""
        var late = false
    }

    static let packKind = "phone-skin"
    static let packVersion = 1
    private static let packBegin = "-----BEGIN EIRA SKIN-----"
    private static let packEnd = "-----END EIRA SKIN-----"

    /// 一段文字读成美化包：两行标记包着的 base64（txt、docx、复制来的那一段）、json 原文、
    /// 以及被聊天软件改过引号或前后多了字的 json
    static func parsePack(_ text: String) throws -> Pack {
        // 取最后一个开头标记：前面的说明文字、聊天记录里可能也提到它
        if let a = text.range(of: packBegin, options: .backwards) {
            guard let b = text.range(of: packEnd, range: a.upperBound..<text.endIndex) else {
                throw StoreError(message: "内容不完整：找到了开头的标记，没有找到结尾的 \(packEnd)")
            }
            let b64 = String(text[a.upperBound..<b.lowerBound].filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") })
            guard let data = Data(base64Encoded: b64), let json = String(data: data, encoding: .utf8) else {
                throw StoreError(message: "两行标记之间的内容被改动过，无法读取。请重新复制完整的一段")
            }
            return try unpack(json)
        }
        do { return try unpack(text) } catch {
            guard let from = text.firstIndex(of: "{"), let to = text.lastIndex(of: "}"), from < to else { throw error }
            var fixed = String(text[from...to])
            for q in ["\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{FF02}"] { fixed = fixed.replacingOccurrences(of: q, with: "\"") }
            if let p = try? unpack(fixed) { return p }
            throw error
        }
    }

    /// 读一个美化包的 JSON。认不出就说清楚认不出在哪儿（同网页版的四种说法）
    static func unpack(_ text: String) throws -> Pack {
        let raw: JSONValue
        do { raw = try JSONValue.parse(Data(text.utf8)) }
        catch { throw StoreError(message: "这不是一个美化包：内容不是有效的 JSON") }
        guard let o = raw.object else { throw StoreError(message: "这不是一个美化包：内容不是一个对象") }
        let kind = o["kind"]?.string ?? ""
        guard kind == packKind else {
            throw StoreError(message: "这不是一个美化包：标记写的是「\(String((kind.isEmpty ? "空" : kind).prefix(20)))」")
        }
        let ver = o["version"]?.number ?? o["version"]?.string.flatMap { Double($0) } ?? 0
        if ver > Double(packVersion) {
            throw StoreError(message: "这个美化包来自更新的版本（\(ver == ver.rounded() ? String(Int(ver)) : String(ver))），当前版本读不了")
        }
        var p = Pack()
        for t in tokens {
            guard let v = o["tokens"]?.object?[t.id], let n = num(v) else { continue }
            p.tokens[t.id] = .number(n.rounded())
        }
        let shape = o["shape"]?.string ?? ""
        p.shape = shapes.contains { $0.id == shape } ? shape : ""
        let frame = o["frame"]?.string ?? ""
        p.frame = imgOk(frame) ? frame : ""
        let who = o["frameWho"]?.string ?? ""
        p.frameWho = ["both", "char", "mine"].contains(who) ? who : "both"
        if let n = num(o["frameScale"]), n.rounded() > 0 { p.frameScale = Swift.max(100, Swift.min(300, n.rounded())) }
        let name = (o["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        p.name = name.isEmpty ? "未命名" : String(name.prefix(80))
        p.author = String((o["author"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        // 老包没有 scope：一律当「单段会话」
        let scope = (o["scope"]?.array ?? []).compactMap(\.string).filter { $0 == "chat" || $0 == "shell" }
        p.scope = scope.isEmpty ? ["chat"] : scope
        p.gen = o["gen"]?.object ?? [:]
        p.css = o["css"]?.string ?? ""
        p.late = o["late"]?.bool == true
        return p
    }

    /// 头像框只认 data:image 的 base64 与 https 图片（网页版 skin-gen.js 的 imgOk）
    static func imgOk(_ v: String) -> Bool {
        v.range(of: #"^data:image/[a-z+.-]+;base64,[A-Za-z0-9+/=]+$"#, options: .regularExpression) != nil
            || v.range(of: #"^https://[^\s"'()\\<>]{1,2000}$"#, options: .regularExpression) != nil
    }

    /// CSS 里引用了几处网络地址（网页版 assetsOf 的 remote）
    static func remoteRefs(_ css: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: #"url\(\s*(['"]?)([^'")]+)\1\s*\)"#, options: [.caseInsensitive]) else { return 0 }
        let ns = css as NSString
        return re.matches(in: css, range: NSRange(location: 0, length: ns.length)).filter { m in
            let u = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces).lowercased()
            return u.hasPrefix("http://") || u.hasPrefix("https://")
        }.count
    }

    /// 装进库里。重名不覆盖，加一个后缀「（2）」
    @discardableResult
    static func install(_ p: Pack) throws -> Row {
        let taken = Set(all().map { $0.string("name") })
        var name = p.name
        var i = 2
        while taken.contains(name) { name = "\(p.name)（\(i)）"; i += 1 }
        var fields: [String: JSONValue] = [
            "name": .string(name), "tokens": .object(p.tokens), "shape": .string(p.shape), "css": .string(p.css),
            "scope": .array(p.scope.map { .string($0) }), "gen": .object(p.gen), "frame": .string(p.frame),
            "frameWho": .string(p.frameWho), "frameScale": .number(p.frameScale),
        ]
        if p.late { fields["late"] = .bool(true) }
        let r = Row.new(prefix: "sk", fields)
        try Database.shared.put(collection, r)
        NotificationCenter.default.post(name: .eiraSkinChanged, object: nil)
        return r
    }
}

extension Notification.Name {
    /// 美化改了：object 为会话 id（挂上、取下）或 nil（某一份本身改了）
    static let eiraSkinChanged = Notification.Name("eiraSkinChanged")
}
