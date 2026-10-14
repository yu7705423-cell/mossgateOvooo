import Foundation

/// 互动：转账、礼物、拍一拍、回应、改备注。照网页版 transfer.js、gift.js、extras.js、reaction.js、remark.js。
/// 不另调接口；落成的消息与字段和网页版一字不差，两边的备份互相读得懂。
///
/// 余额：网页版在记账里把账本关联到对话时才核对余额。原生版还没有记账，不核对。
enum Interact {
    // MARK: - 货币（网页版 currency.js）

    struct Currency {
        let code: String
        let symbol: String
        let name: String
        let digits: Int
    }

    static let currencies = [
        Currency(code: "CNY", symbol: "¥", name: "人民币", digits: 2), Currency(code: "USD", symbol: "$", name: "美元", digits: 2),
        Currency(code: "EUR", symbol: "€", name: "欧元", digits: 2), Currency(code: "GBP", symbol: "£", name: "英镑", digits: 2),
        Currency(code: "JPY", symbol: "¥", name: "日元", digits: 0), Currency(code: "KRW", symbol: "₩", name: "韩元", digits: 0),
        Currency(code: "HKD", symbol: "HK$", name: "港币", digits: 2), Currency(code: "TWD", symbol: "NT$", name: "新台币", digits: 2),
        Currency(code: "SGD", symbol: "S$", name: "新加坡元", digits: 2), Currency(code: "RUB", symbol: "₽", name: "卢布", digits: 2),
        Currency(code: "none", symbol: "", name: "不显示符号", digits: 2),
    ]

    static func currency(_ code: String? = nil, settings s: AppSettings = .load()) -> Currency {
        let c = code ?? s.raw["currency"]?.string ?? "CNY"
        return currencies.first { $0.code == c } ?? currencies[0]
    }

    static func round(_ n: Double, _ code: String? = nil) -> Double {
        let p = pow(10, Double(currency(code).digits))
        let v = (n * p).rounded() / p
        return v.isFinite ? v : 0
    }

    static func format(_ n: Double, _ code: String? = nil) -> String {
        String(format: "%.\(currency(code).digits)f", round(n, code))
    }

    /// 带符号，只给界面用。上下文里一律是纯数字。
    static func display(_ n: Double, _ code: String?) -> String {
        let c = currency(code)
        return c.symbol.isEmpty ? format(n, c.code) : c.symbol + format(n, c.code)
    }

    /// 写进 prompt 的那一句：这段对话用的是什么钱。
    static func currencyLabel(_ s: AppSettings) -> String {
        let c = currency(settings: s)
        return c.code == "none" ? "" : "\(c.name)（\(c.symbol.isEmpty ? c.code : c.symbol)）"
    }

    // MARK: - 名字

    static func names(_ chatId: String) -> (me: String, char: String, charId: String) {
        let chat = try? Repo.chat(chatId)
        let s = AppSettings.load()
        let personas = (try? Repo.personas()) ?? []
        let me = personas.first { $0.id == chat?.personaId } ?? (try? Repo.activePersona(s)) ?? nil
        let charId = chat?.characterIds.first ?? ""
        let char = (try? Repo.character(charId)) ?? nil
        let meName = me.map { $0.row.string("name") } ?? ""
        return (meName.isEmpty ? "我" : meName, char?.row.string("name").isEmpty == false ? char!.row.string("name") : "角色", charId)
    }

    private static func touchChat(_ chatId: String) throws {
        if var c = try Repo.chat(chatId) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
    }

    private static func update(_ id: String, _ change: (inout Row) -> Void) throws {
        guard var row = try Database.shared.get(Collections.messages, id: id) else { return }
        change(&row)
        row.touch()
        try Database.shared.put(Collections.messages, row)
    }

    private static func pending(_ chatId: String, kind: String, field: String, role: Message.Role) throws -> Message? {
        try Repo.messages(chatId: chatId).last { $0.kind == kind && $0.role == role && $0.row.string(field) == "pending" }
    }

    // MARK: - 转账

    static func transferContent(_ amount: Double, _ note: String, _ state: String, _ code: String?) -> String {
        let head = "[转账：\(format(amount, code))\(note.isEmpty ? "" : " " + note)]"
        switch state {
        case "taken": return head + "（已被收下）"
        case "returned": return head + "（已被退回）"
        default: return head
        }
    }

    static func transferLabel(_ state: String) -> String {
        state == "taken" ? "已收款" : state == "returned" ? "已退回" : "待收款"
    }

    /// 发一笔。row 带上这一轮的公共字段（turnId、引用）。
    static func transfer(_ base: Message, amount: Double, note: String) throws -> Message {
        let code = currency().code
        let v = round(amount, code)
        guard v > 0 else { throw StoreError(message: "金额需大于 0") }
        let text = String(note.trimmingCharacters(in: .whitespaces).prefix(40))
        var m = base
        m.row["kind"] = .string("transfer")
        m.row["amount"] = .number(v)
        m.row["note"] = .string(text)
        m.row["transfer"] = .string("pending")
        m.row["currency"] = .string(code)
        m.row["content"] = .string(transferContent(v, text, "pending", code))
        return m
    }

    /// 收下或退回对方那一笔。改那条的状态，并落一行提示（返回，由调用方追加）。
    static func settleTransfer(_ msgId: String, take: Bool, turnId: String? = nil) throws -> Message? {
        guard let row = try Database.shared.get(Collections.messages, id: msgId) else { return nil }
        let m = Message(row: row)
        guard m.kind == "transfer", row.string("transfer") == "pending" else { return nil }
        let state = take ? "taken" : "returned"
        let amount = row.number("amount") ?? 0
        let code = row.string("currency").isEmpty ? nil : row.string("currency")
        try update(msgId) {
            $0["transfer"] = .string(state)
            $0["content"] = .string(transferContent(amount, row.string("note"), state, code))
        }
        let n = names(m.chatId)
        let byUser = m.role != .user
        let who = byUser ? n.me : n.char
        let from = byUser ? n.char : n.me
        var notice = Message.new(chatId: m.chatId, role: byUser ? .user : .char, authorId: byUser ? "me" : (n.charId.isEmpty ? m.authorId : n.charId),
                                 content: "[\(who)\(take ? "收下了" : "退回了")\(from)的转账 \(format(amount, code))]", kind: "notice", turnId: turnId)
        notice.row["settledId"] = .string(msgId)
        return notice
    }

    static func pendingTransfer(_ chatId: String, from role: Message.Role) throws -> Message? {
        try pending(chatId, kind: "transfer", field: "transfer", role: role)
    }

    // MARK: - 礼物

    /// 默认不让对方提前知道里面是什么（网页版 giftBlind，默认开）。
    static func giftBlind(_ s: AppSettings = .load()) -> Bool { s.raw["giftBlind"]?.bool != false }

    static func giftContent(cover: String, inner: String, state: String, hide: Bool) -> String {
        let same = inner.isEmpty || inner == cover
        switch state {
        case "opened": return same ? "[礼物：\(cover)]" : "[礼物：\(cover)，拆开是 \(inner)]"
        case "declined": return "[礼物：\(cover)（已拒收）]"
        default: return hide || same ? "[礼物：\(cover)（未拆封）]" : "[礼物：\(cover)（未拆封，里面是 \(inner)）]"
        }
    }

    static func giftLabel(_ state: String) -> String {
        state == "opened" ? "已拆开" : state == "declined" ? "已拒收" : "待拆开"
    }

    /// 「封面 | 里面」。没有竖线时两者相同。
    static func parseGift(_ body: String) -> (cover: String, inner: String)? {
        let t = body.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        guard let i = t.firstIndex(where: { $0 == "|" || $0 == "｜" }) else { return (String(t.prefix(40)), "") }
        return (String(t[..<i].trimmingCharacters(in: .whitespaces).prefix(40)),
                String(t[t.index(after: i)...].trimmingCharacters(in: .whitespaces).prefix(60)))
    }

    static func gift(_ base: Message, cover: String, inner: String) throws -> Message {
        let c = String(cover.trimmingCharacters(in: .whitespaces).prefix(40))
        guard !c.isEmpty else { throw StoreError(message: "请填写礼物名称") }
        let n = String(inner.trimmingCharacters(in: .whitespaces).prefix(60))
        var m = base
        m.row["kind"] = .string("gift")
        m.row["cover"] = .string(c)
        m.row["inner"] = .string(n)
        m.row["gift"] = .string("pending")
        m.row["content"] = .string(giftContent(cover: c, inner: n, state: "pending", hide: giftBlind()))
        return m
    }

    static func settleGift(_ msgId: String, open: Bool, turnId: String? = nil) throws -> Message? {
        guard let row = try Database.shared.get(Collections.messages, id: msgId) else { return nil }
        let m = Message(row: row)
        guard m.kind == "gift", row.string("gift") == "pending" else { return nil }
        let state = open ? "opened" : "declined"
        let cover = row.string("cover"), inner = row.string("inner")
        try update(msgId) {
            $0["gift"] = .string(state)
            $0["content"] = .string(giftContent(cover: cover, inner: inner, state: state, hide: false))
        }
        let n = names(m.chatId)
        let byUser = m.role != .user
        let giver = byUser ? n.char : n.me
        let what = open && !inner.isEmpty && inner != cover ? "拆开了\(giver)送的「\(cover)」，里面是\(inner)"
            : open ? "拆开了\(giver)送的「\(cover)」" : "拒收了\(giver)送的「\(cover)」"
        var notice = Message.new(chatId: m.chatId, role: byUser ? .user : .char, authorId: byUser ? "me" : (n.charId.isEmpty ? m.authorId : n.charId),
                                 content: "[\(byUser ? n.me : n.char)\(what)]", kind: "notice", turnId: turnId)
        notice.row["settledId"] = .string(msgId)
        notice.row["settledKind"] = .string("gift")
        return notice
    }

    static func pendingGift(_ chatId: String, from role: Message.Role) throws -> Message? {
        try pending(chatId, kind: "gift", field: "gift", role: role)
    }

    // MARK: - 外卖（网页版 takeout.js）：自己点（self）、请客（treat）、代付（ask）

    static func takeoutLabel(_ kind: String, _ state: String) -> String {
        if kind == "self" { return "" }
        if state == "taken" { return kind == "treat" ? "已收下" : "已付款" }
        if state == "declined" { return kind == "treat" ? "已谢绝" : "未代付" }
        return kind == "treat" ? "待收下" : "待代付"
    }

    static func takeoutContent(kind: String, item: String, amount: Double, state: String, code: String?) -> String {
        let money = format(amount, code)
        let head = kind == "treat" ? "[请客：\(item) \(money)]" : kind == "ask" ? "[代付：\(item) \(money)]" : "[外卖：\(item) \(money)]"
        if kind == "self" || state == "pending" { return head }
        if state == "taken" { return head + (kind == "treat" ? "（已被收下）" : "（对方付了）") }
        return head + (kind == "treat" ? "（被谢绝了）" : "（对方没付）")
    }

    /// 「东西 金额」：最后一个数是金额，没有就是 0。
    static func parseTakeout(_ body: String) -> (item: String, amount: Double)? {
        let t = body.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let re = try! NSRegularExpression(pattern: #"^(.*?)[\s　]*(?:[¥￥$]\s*)?(\d+(?:\.\d{1,2})?)\s*(?:元|块)?$"#)
        let ns = t as NSString
        guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return (String(t.prefix(40)), 0) }
        return (String(ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces).prefix(40)),
                Double(ns.substring(with: m.range(at: 2))) ?? 0)
    }

    static func takeout(_ base: Message, kind: String, item: String, amount: Double) throws -> Message {
        let it = String(item.trimmingCharacters(in: .whitespaces).prefix(40))
        guard !it.isEmpty else { throw StoreError(message: "请填写要点的东西") }
        guard ["self", "treat", "ask"].contains(kind) else { throw StoreError(message: "不认识这种点法") }
        let code = currency().code
        let v = round(amount, code)
        guard v >= 0 else { throw StoreError(message: "金额不能是负数") }
        var m = base
        m.row["kind"] = .string("takeout")
        m.row["takeoutKind"] = .string(kind)
        m.row["item"] = .string(it)
        m.row["amount"] = .number(v)
        m.row["currency"] = .string(code)
        m.row["takeout"] = .string(kind == "self" ? "taken" : "pending")
        m.row["content"] = .string(takeoutContent(kind: kind, item: it, amount: v, state: "pending", code: code))
        return m
    }

    static func settleTakeout(_ msgId: String, take: Bool, turnId: String? = nil) throws -> Message? {
        guard let row = try Database.shared.get(Collections.messages, id: msgId) else { return nil }
        let m = Message(row: row)
        guard m.kind == "takeout", row.string("takeout") == "pending" else { return nil }
        let state = take ? "taken" : "declined"
        let kind = row.string("takeoutKind"), item = row.string("item")
        let amount = row.number("amount") ?? 0
        let code = row.string("currency").isEmpty ? nil : row.string("currency")
        try update(msgId) {
            $0["takeout"] = .string(state)
            $0["content"] = .string(takeoutContent(kind: kind, item: item, amount: amount, state: state, code: code))
        }
        let n = names(m.chatId)
        let byUser = m.role != .user
        let who = byUser ? n.me : n.char
        let from = byUser ? n.char : n.me
        let what = "\(item) \(format(amount, code))"
        let line = kind == "treat" ? "\(who)\(take ? "收下了" : "谢绝了")\(from)点的\(what)" : "\(who)\(take ? "替" : "没有替")\(from)付了\(what)"
        var notice = Message.new(chatId: m.chatId, role: byUser ? .user : .char, authorId: byUser ? "me" : (n.charId.isEmpty ? m.authorId : n.charId),
                                 content: "[\(line)]", kind: "notice", turnId: turnId)
        notice.row["settledId"] = .string(msgId)
        notice.row["settledKind"] = .string("takeout")
        return notice
    }

    static func pendingTakeout(_ chatId: String, from role: Message.Role) throws -> Message? {
        try pending(chatId, kind: "takeout", field: "takeout", role: role)
    }

    // MARK: - 位置（网页版 place.js）

    static func location(_ base: Message, place: String, address: String) throws -> Message {
        let p = String(place.trimmingCharacters(in: .whitespaces).prefix(40))
        guard !p.isEmpty else { throw StoreError(message: "请填写地点名称") }
        let a = String(address.trimmingCharacters(in: .whitespaces).prefix(80))
        var m = base
        m.row["kind"] = .string("location")
        m.row["place"] = .string(p)
        m.row["address"] = .string(a)
        m.row["content"] = .string("[位置：\(p)\(a.isEmpty ? "" : " " + a)]")
        return m
    }

    /// 「已收款」「已拆开」那一行删掉，就当这次处理没发生过，那一笔回到待处理（网页版 dropMessage）。
    static func unsettle(_ notice: Message) throws {
        // 角色改锁屏密码的那一行：放回换之前那一份
        if notice.kind == "notice", let u = notice.row["lockUndo"]?.object, let charId = u["charId"]?.string {
            try Theirs.restoreLock(charId, u["prev"])
            return
        }
        guard notice.kind == "notice", case let id = notice.row.string("settledId"), !id.isEmpty,
              let row = try Database.shared.get(Collections.messages, id: id) else { return }
        if notice.row.string("settledKind") == "pact" {
            try Space.unsettlePact(notice)
        } else if notice.row.string("settledKind") == "gift" {
            guard row.string("kind") == "gift" else { return }
            try update(id) {
                $0["gift"] = .string("pending")
                $0["content"] = .string(giftContent(cover: row.string("cover"), inner: row.string("inner"), state: "pending", hide: giftBlind()))
            }
        } else if notice.row.string("settledKind") == "takeout" {
            guard row.string("kind") == "takeout" else { return }
            let code = row.string("currency").isEmpty ? nil : row.string("currency")
            try update(id) {
                $0["takeout"] = .string("pending")
                $0["content"] = .string(takeoutContent(kind: row.string("takeoutKind"), item: row.string("item"),
                                                       amount: row.number("amount") ?? 0, state: "pending", code: code))
            }
        } else if notice.row.string("settledKind").isEmpty {
            guard row.string("kind") == "transfer" else { return }
            let code = row.string("currency").isEmpty ? nil : row.string("currency")
            try update(id) {
                $0["transfer"] = .string("pending")
                $0["content"] = .string(transferContent(row.number("amount") ?? 0, row.string("note"), "pending", code))
            }
        }
    }

    /// 删一条消息。处理记录先撤回去，再删（网页版 reply.js 的 dropMessage）。
    static func drop(_ m: Message) throws {
        try unsettle(m)
        try Database.shared.delete(Collections.messages, id: m.id)
    }

    // MARK: - 拍一拍

    static let patSuffixes = ["的头", "的肩膀", "的脸", "的头发", "的尾巴", "的脑门"]

    static func pat(chatId: String, role: Message.Role, turnId: String? = nil) -> Message {
        let n = names(chatId)
        let char = try? Repo.character(n.charId)
        func trim(_ s: String) -> String { String(s.trimmingCharacters(in: .whitespaces).prefix(20)) }
        let charPat = trim(char?.row.string("patSuffix") ?? "")
        let myPat = trim(AppSettings.load().raw["patSuffix"]?.string ?? "")
        let text = role == .user
            ? "\(n.me)拍了拍\(n.char)\(charPat.isEmpty ? patSuffixes[0] : charPat)"
            : "\(n.char)拍了拍\(n.me)\(myPat.isEmpty ? patSuffixes[0] : myPat)"
        var m = Message.new(chatId: chatId, role: role, authorId: role == .user ? "me" : n.charId, content: "[\(text)]", kind: "notice", turnId: turnId)
        m.row["pat"] = .bool(true)
        return m
    }

    // MARK: - 改备注

    /// 角色改了对你的备注。名字没变或是空的，什么都不做。返回那一行提示。
    static func setTheirRemark(chatId: String, name: String, char: Character, turnId: String?) throws -> Message? {
        let n = String(name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").prefix(20))
        guard !n.isEmpty, var chat = try Repo.chat(chatId), chat.row.string("charRemark") != n else { return nil }
        chat.row["charRemark"] = .string(n)
        chat.row.touch()
        try Repo.save(chat)
        var m = Message.new(chatId: chatId, role: .char, authorId: char.id, content: "[\(char.name)将你的备注改为「\(n)」]", kind: "notice", turnId: turnId)
        m.row["remark"] = .string(n)
        return m
    }

    // MARK: - 回应

    /// 认 emoji：每个字都得是图形符号、区域指示符或组合用的那几个（网页版 isEmoji）。
    static func isEmoji(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.utf16.count <= 16 else { return false }
        var hasPicto = false
        for u in t.unicodeScalars {
            let v = u.value
            if (u.properties.isEmoji && v > 0x7F && v != 0xFE0F && v != 0x200D && v != 0x20E3 && !(0x1F3FB...0x1F3FF).contains(v)) || (0x1F1E6...0x1F1FF).contains(v) || v == 0x20E3 { hasPicto = true; continue }
            if (0x1F3FB...0x1F3FF).contains(v) || v == 0xFE0F || v == 0x200D || (0x30...0x39).contains(v) || v == 0x23 || v == 0x2A { continue }
            return false
        }
        return hasPicto
    }

    /// 贴上或取消。同一个人对同一条、同一个 emoji 第二次就是取消。
    @discardableResult
    static func toggleReaction(_ msgId: String, emoji: String, by: String, turnId: String? = nil) throws -> Bool {
        guard isEmoji(emoji), let row = try Database.shared.get(Collections.messages, id: msgId) else { return false }
        var list = row["reactions"]?.array ?? []
        if let i = list.firstIndex(where: { $0["e"]?.string == emoji && $0["by"]?.string == by }) {
            list.remove(at: i)
            try update(msgId) { $0["reactions"] = .array(list) }
            return false
        }
        var r: [String: JSONValue] = ["e": .string(emoji), "by": .string(by), "at": .number(Date().millis)]
        if let turnId, !turnId.isEmpty { r["turnId"] = .string(turnId) }
        list.append(.object(r))
        try update(msgId) { $0["reactions"] = .array(list) }
        return true
    }

    /// 重新生成：角色这一轮贴的回应一并撤掉。
    static func undoReactions(chatId: String, turnId: String) throws {
        guard !turnId.isEmpty else { return }
        for m in try Repo.messages(chatId: chatId) {
            let list = m.row["reactions"]?.array ?? []
            guard list.contains(where: { $0["turnId"]?.string == turnId }) else { continue }
            try update(m.id) { $0["reactions"] = .array(list.filter { $0["turnId"]?.string != turnId }) }
        }
    }

    /// 常用的六个（网页版 reaction.QUICK：红心、点赞、笑哭、惊讶、哭、合十），由码点生成，源码里不写 emoji 字面量。
    static let quick = ["\u{2764}\u{FE0F}", "\u{1F44D}", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F64F}"]

    private static func cp(_ codes: UInt32...) -> String {
        String(String.UnicodeScalarView(codes.compactMap { Unicode.Scalar($0) }))
    }
    private static func range(_ a: UInt32, _ b: UInt32) -> [String] { (a...b).map { cp($0) } }

    /// 「更多回应」里的网格：笑脸一片、手势几个、心与杂项几个（网页版 reaction.GRID）。不求全，输入框兜底
    static let grid: [String] = {
        var g = range(0x1F600, 0x1F64F)
        g += range(0x1F910, 0x1F917) + range(0x1F920, 0x1F925) + range(0x1F970, 0x1F976) + [cp(0x1F97A)]
        g += range(0x1F44A, 0x1F44F) + [cp(0x1F64C), cp(0x1F91D), cp(0x1F4AA), cp(0x270C, 0xFE0F), cp(0x1F44C), cp(0x1F44B)]
        g += [cp(0x2764, 0xFE0F)] + range(0x1F493, 0x1F49D) + [cp(0x1F494), cp(0x1F525), cp(0x2728), cp(0x1F389), cp(0x1F381)]
        g += [cp(0x1F338), cp(0x1F33F), cp(0x1F340), cp(0x1F31F), cp(0x1F319), cp(0x2600, 0xFE0F), cp(0x2614), cp(0x26A1)]
        g += [cp(0x1F4AF), cp(0x1F4A4), cp(0x1F4A2), cp(0x1F4A5), cp(0x1F4A6), cp(0x1F440), cp(0x1F480), cp(0x1F37B), cp(0x2615)]
        g += [cp(0x1F370), cp(0x1F35C), cp(0x1F436), cp(0x1F431), cp(0x1F430), cp(0x1F43B), cp(0x1F981), cp(0x1F427)]
        var seen = Set<String>()
        return g.filter { seen.insert($0).inserted }
    }()

    private static func strip(_ e: String) -> String { e.replacingOccurrences(of: "\u{FE0F}", with: "") }

    /// 我最近贴过的（settings.reactRecent，最多 8 个，新的在前）
    static func recentReactions(_ s: AppSettings) -> [String] {
        (s.raw["reactRecent"]?.array ?? []).compactMap(\.string).filter(isEmoji)
    }

    /// 长按菜单上那一排：最近用过的排前面，常用的补齐，共 6 个
    static func quickList(_ s: AppSettings) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for e in recentReactions(s) + quick where !seen.contains(strip(e)) {
            seen.insert(strip(e)); out.append(e)
        }
        return Array(out.prefix(6))
    }

    /// 记一次「最近用过」
    static func noteRecent(_ e: String, _ s: AppSettings) -> JSONValue {
        .array(([e] + recentReactions(s).filter { $0 != e }).prefix(8).map { .string($0) })
    }
}
