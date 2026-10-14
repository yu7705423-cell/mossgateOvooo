import SwiftUI

/// 美化（网页版 system/skin.js，ARCHITECTURE 4.111）。数据域 skins，与网页版同一格式；一段会话挂哪一份记在 chat.skinId。
///
/// 原生版不跑 CSS（规约第 2 节）：只读得懂的那几格，其余原样存着、写回时不丢。
///     tokens  消息间距、同一轮内间距、气泡圆角、气泡左右与上下内距、气泡字号
///     shape   头像形状（圆形、方形、圆角方形）
///     gen     生成器里的「头像」一组：显示头像、大小、圆角；「气泡」一组：改哪一边、底色、文字颜色、圆角、内距、字号
/// 自定义 CSS、头像框、贴图、小尾巴等不在原生版里画。网页版生成的 CSS 里生成器排在令牌之后，所以两处都写了的以生成器为准。
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
        var s = AppSettings.load()
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

    static func setToken(_ id: String, _ key: String, _ v: Double?) throws {
        try update(id) { r in
            var t = r["tokens"]?.object ?? [:]
            if let v { t[key] = .number(v.rounded()) } else { t.removeValue(forKey: key) }
            r["tokens"] = .object(t)
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
        var fill: Color? { Skins.color(bg) }
        var text: Color? { Skins.color(fg) }
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
        var show = "both"

        func bubble(_ mine: Bool) -> Bubble { mine ? self.mine : theirs }
        func showFace(_ mine: Bool) -> Bool { show == "both" || show == (mine ? "mine" : "theirs") }
        func radius(_ size: CGFloat) -> CGFloat {
            guard let avatarRound else { return size * 14 / 44 }
            return size * avatarRound
        }
    }

    static func look(_ r: Row?) -> Look {
        var l = Look()
        guard let r else { return l }
        func cg(_ v: Double?, _ lo: Double, _ hi: Double) -> CGFloat? { v.map { CGFloat(Swift.min(hi, Swift.max(lo, $0))) } }
        var base = Bubble()
        if let v = cg(token(r, "bubbleR"), 0, 200) { base.radius = v }
        if let v = cg(token(r, "bubblePX"), 0, 200) { base.padX = v }
        if let v = cg(token(r, "bubblePY"), 0, 200) { base.padY = v }
        if let v = cg(token(r, "bubbleFS"), 6, 60) { base.font = v }
        if let v = cg(token(r, "gap"), 0, 200) { l.gap = v }
        if let v = cg(token(r, "gapIn"), 0, 200) { l.gapIn = v }
        l.mine = base
        l.theirs = base
        // 生成器的「气泡」一组：只改选定的那一边
        let side = genValue(r, "bubble", "side")?.string ?? "all"
        func apply(_ b: inout Bubble) {
            if let v = cg(num(genValue(r, "bubble", "r")), 0, 200) { b.radius = v }
            if let v = cg(num(genValue(r, "bubble", "px")), 0, 200) { b.padX = v }
            if let v = cg(num(genValue(r, "bubble", "py")), 0, 200) { b.padY = v }
            if let v = cg(num(genValue(r, "bubble", "fs")), 6, 60) { b.font = v }
            if let v = genValue(r, "bubble", "bg")?.string, color(v) != nil { b.bg = v }
            if let v = genValue(r, "bubble", "fg")?.string, color(v) != nil { b.fg = v }
        }
        if side != "mine" { apply(&l.theirs) }
        if side != "theirs" { apply(&l.mine) }
        // 头像：形状在前，生成器的圆角在后（与网页版生成的 CSS 先后一致）
        switch r.string("shape") {
        case "round": l.avatarRound = 0.5
        case "square": l.avatarRound = 4 / Theme.avatarSize
        case "soft": l.avatarRound = 10 / Theme.avatarSize
        default: break
        }
        if let v = cg(num(genValue(r, "avatar", "size")), 16, 120) { l.avatarSize = v }
        if let v = num(genValue(r, "avatar", "round")), v > 0 { l.avatarRound = CGFloat(Swift.min(50, v)) / 100 }
        let show = genValue(r, "avatar", "show")?.string ?? "both"
        l.show = faceShow.contains { $0.id == show } ? show : "both"
        return l
    }

    /// 这份美化里原生版画不出来的那几样，导入、挂上时写明
    static func skipped(_ r: Row) -> [String] {
        var out: [String] = []
        if !r.string("css").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("自定义 CSS") }
        if !r.string("frame").isEmpty { out.append("头像框") }
        let known: [String: Set<String>] = ["avatar": ["show", "size", "round"], "bubble": ["side", "bg", "fg", "r", "px", "py", "fs"]]
        for (g, v) in r["gen"]?.object ?? [:] {
            let items = (v.object ?? [:]).filter { !$0.value.isNull && $0.value.string != "" && $0.value.bool != false }
            if items.keys.contains(where: { !(known[g]?.contains($0) ?? false) }) { out.append("生成器的其他样式"); break }
        }
        return out
    }
}

extension Notification.Name {
    /// 美化改了：object 为会话 id（挂上、取下）或 nil（某一份本身改了）
    static let eiraSkinChanged = Notification.Name("eiraSkinChanged")
}
