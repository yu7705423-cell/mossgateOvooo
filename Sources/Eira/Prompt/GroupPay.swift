import Foundation

/// 群红包（网页版 system/redpacket.js，ARCHITECTURE 4.736）。
///
/// 三种：luck 拼手气（总额随机分）、equal 普通（每份一样，除不尽的零头不发，记下的是实际发出的总额）、only 专属（一份，只有指定的人能领）。
/// **每份多少在发出那一刻就分好**（shares，二倍均值），不交给模型算。每人只领一次，发的人自己也能领；
/// 领完或过了 24 小时不能再领，过期没领的退给发的人。过期不靠定时器：显示、领取、群聊每一轮开始时按时刻判断。
///
/// 状态都在那条红包消息自己身上（rp），不另存流水，字段与网页版一字不差：
///   rp = { type, total, count, shares: [金额], claims: [{ who, amount, at }], to, note, currency }
/// 领一次落一行提示（kind notice，rpOf 指回红包）；那一行删掉（重新生成那一轮）时领的那一份退回去，剩下的人按先后重新对上金额。
enum RedPacket {
    static let luck = "luck", equal = "equal", only = "only"
    static let types = [luck, equal, only]
    static let ttl: Double = 24 * 3600 * 1000
    static let typeLabel: [String: String] = ["luck": "拼手气红包", "equal": "普通红包", "only": "专属红包"]
    static let stateLabel: [String: String] = ["open": "", "done": "已领完", "expired": "已过期"]
    static let defaultNote = "恭喜发财，大吉大利"

    struct Claim: Equatable, Sendable {
        var who: String
        var amount: Double
        var at: Double
    }

    struct Packet: Equatable, Sendable {
        var type: String
        var total: Double
        var shares: [Double]
        var claims: [Claim]
        var to: String
        var note: String
        var currency: String?

        init(type: String, total: Double, shares: [Double], claims: [Claim] = [], to: String = "", note: String, currency: String?) {
            self.type = type; self.total = total; self.shares = shares; self.claims = claims
            self.to = to; self.note = note; self.currency = currency
        }

        init?(_ v: JSONValue?) {
            guard let o = v?.object else { return nil }
            let t = o["type"]?.string ?? ""
            type = RedPacket.types.contains(t) ? t : RedPacket.luck
            total = o["total"]?.number ?? 0
            shares = (o["shares"]?.array ?? []).compactMap(\.number)
            claims = (o["claims"]?.array ?? []).compactMap { c in
                guard let who = c["who"]?.string else { return nil }
                return Claim(who: who, amount: c["amount"]?.number ?? 0, at: c["at"]?.number ?? 0)
            }
            to = o["to"]?.string ?? ""
            note = o["note"]?.string ?? ""
            currency = o["currency"]?.string
        }

        var json: JSONValue {
            var o: [String: JSONValue] = [
                "type": .string(type), "total": .number(total), "count": .number(Double(shares.count)),
                "shares": .array(shares.map { .number($0) }),
                "claims": .array(claims.map { .object(["who": .string($0.who), "amount": .number($0.amount), "at": .number($0.at)]) }),
                "to": .string(to), "note": .string(note),
            ]
            if let currency { o["currency"] = .string(currency) }
            return .object(o)
        }
    }

    static func packet(_ m: Message) -> Packet? { m.kind == "redpacket" ? Packet(m.row["rp"]) : nil }

    // MARK: - 分

    /// 分成几份，shares 的和就是 total。拼手气用二倍均值：每一份在 1 个最小单位到剩下的平均数的两倍之间随机，
    /// 保证后面的每一份至少还有 1 个单位。金额不够分（总额小于份数个最小单位）时抛错
    static func split(_ type: String, total: Double, count: Int, code: String?,
                      rng: () -> Double = { Double.random(in: 0..<1) }) throws -> (total: Double, shares: [Double]) {
        let digits = Interact.currency(code).digits
        let u = pow(10, -Double(digits))
        let n = type == only ? 1 : max(1, count)
        guard total.isFinite, total > 0, total / u < 1e15 else { throw StoreError(message: "金额需大于 0") }
        var units = Int((total / u).rounded())
        guard units > 0 else { throw StoreError(message: "金额需大于 0") }
        guard units >= n else { throw StoreError(message: "金额不够分成 \(n) 个") }
        var out: [Int] = []
        if type == equal {
            let each = units / n
            out = Array(repeating: each, count: n)
            units = each * n
        } else {
            var left = units
            for i in 0..<(n - 1) {
                let rest = n - i
                let mx = max(1, min(left - (rest - 1), Int((Double(left) / Double(rest) * 2).rounded(.down))))
                let v = max(1, min(mx, Int((rng() * Double(mx)).rounded(.down)) + 1))
                out.append(v)
                left -= v
            }
            out.append(left)
        }
        let shares = out.map { Interact.round(Double($0) * u, code) }
        return (Interact.round(Double(units) * u, code), shares)
    }

    // MARK: - 状态

    /// open / done（领完）/ expired（过了 24 小时还没领完）
    static func state(_ rp: Packet?, at: Double, now: Double = Date().millis) -> String {
        guard let rp else { return "done" }
        if rp.claims.count >= rp.shares.count { return "done" }
        return now - at > ttl ? "expired" : "open"
    }

    /// 过期退回的那一部分：没领出去的
    static func left(_ rp: Packet) -> Double {
        Interact.round(rp.shares.dropFirst(rp.claims.count).reduce(0, +), rp.currency)
    }

    /// 手气最佳：领完的拼手气红包里最多的那一份
    static func best(_ rp: Packet) -> String {
        guard rp.type == luck, rp.claims.count >= rp.shares.count, rp.shares.count >= 2 else { return "" }
        return rp.claims.sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.at < $1.at }.first?.who ?? ""
    }

    /// 上下文里的写法：模型读到的和它自己该写的是同一套格式，状态写在后面
    static func content(_ rp: Packet, at: Double, chat: Chat?, now: Double = Date().millis) -> String {
        let kind = rp.type == luck ? "红包" : rp.type == equal ? "普通红包" : "专属红包"
        let money = Interact.format(rp.total, rp.currency)
        let body = rp.type == only ? "\(chat.map { GroupPay.nameIn($0, rp.to) } ?? "")｜\(money)" : "\(money)｜\(rp.shares.count)"
        let head = "[\(kind)：\(body)\(rp.note.isEmpty ? "" : "｜" + rp.note)]"
        let got = "已领 \(rp.claims.count)/\(rp.shares.count)"
        switch state(rp, at: at, now: now) {
        case "done": return head + "（已领完）"
        case "expired": return head + "（已过期，\(got)）"
        default: return head + "（\(got)）"
        }
    }

    /// 气泡底下那一行：种类与状态
    static func foot(_ m: Message, chat: Chat?) -> String {
        guard let rp = packet(m) else { return "" }
        let st = state(rp, at: m.createdAt)
        let kind = rp.type == only ? "给\(chat.map { GroupPay.nameIn($0, rp.to) } ?? "")的专属红包" : (typeLabel[rp.type] ?? "")
        let s = st == "open" ? "已领 \(rp.claims.count)/\(rp.shares.count)" : (stateLabel[st] ?? "")
        return "\(kind) · \(s)"
    }

    private static func refresh(_ id: String, now: Double = Date().millis) throws {
        guard var row = try Database.shared.get(Collections.messages, id: id), let rp = Packet(row["rp"]) else { return }
        let chat = try Repo.chat(row.string("chatId"))
        row["content"] = .string(content(rp, at: row.created ?? 0, chat: chat, now: now))
        row.touch()
        try Database.shared.put(Collections.messages, row)
    }

    // MARK: - 发、领

    /// 发一个，返回还没落库的那一条（落库由调用方：一轮里的由 ChatEngine.write，我发的由 send）。
    /// to 是专属红包给谁（角色 id 或 me）。金额不够分、专属红包没有人时抛错
    static func make(chat: Chat, role: Message.Role, authorId: String, type: String, total: Double, count: Int,
                     note: String, to: String = "", turnId: String? = nil,
                     rng: () -> Double = { Double.random(in: 0..<1) }) throws -> Message {
        guard types.contains(type) else { throw StoreError(message: "红包类型不对") }
        if type == only && to.isEmpty { throw StoreError(message: "专属红包需要指定领取的人") }
        let code = Interact.currency().code
        let cut = try split(type, total: total, count: count, code: code, rng: rng)
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let rp = Packet(type: type, total: cut.total, shares: cut.shares, to: type == only ? to : "",
                        note: n.isEmpty ? defaultNote : n, currency: code)
        var m = Message.new(chatId: chat.id, role: role, authorId: authorId, content: "", kind: "redpacket", turnId: turnId)
        m.row["rp"] = rp.json
        m.row["content"] = .string(content(rp, at: m.createdAt, chat: chat))
        return m
    }

    /// 我发一个（加号面板「红包」）
    static func send(chatId: String, type: String, total: Double, count: Int, note: String, to: String) throws -> Message {
        guard let chat = try Repo.chat(chatId), chat.isGroup else { throw StoreError(message: "红包只能在群聊里发") }
        let m = try Repo.append(make(chat: chat, role: .user, authorId: GroupChat.me, type: type, total: total,
                                     count: count, note: note, to: to))
        try GroupPay.touch(chatId)
        return m
    }

    /// 这个人此刻能不能领这一个。能领回空串，否则回原因
    static func whyNot(_ m: Message, who: String, now: Double = Date().millis) -> String {
        guard let rp = packet(m) else { return "红包不存在" }
        let st = state(rp, at: m.createdAt, now: now)
        if st == "done" { return "红包已被领完" }
        if st == "expired" { return "红包已过期" }
        if rp.claims.contains(where: { $0.who == who }) { return "已经领过这个红包" }
        let chat = (try? Repo.chat(m.chatId)) ?? nil
        if rp.type == only && rp.to != who { return "这是给\(chat.map { GroupPay.nameIn($0, rp.to) } ?? "")的专属红包" }
        if who != GroupChat.me && !(chat?.characterIds.contains(who) ?? false) { return "不在这个群里" }
        return ""
    }

    /// 领。改红包那一条，返回还没落库的那一行提示；领不了回 nil
    static func claim(_ msgId: String, who: String, turnId: String? = nil, now: Double = Date().millis) throws -> Message? {
        guard let row = try Database.shared.get(Collections.messages, id: msgId) else { return nil }
        let m = Message(row: row)
        guard var rp = packet(m), whyNot(m, who: who, now: now).isEmpty else { return nil }
        let amount = rp.shares[rp.claims.count]
        rp.claims.append(Claim(who: who, amount: amount, at: now))
        var r = row
        r["rp"] = rp.json
        r.touch()
        try Database.shared.put(Collections.messages, r)
        try refresh(msgId, now: now)
        guard let chat = try Repo.chat(m.chatId) else { return nil }
        let from = m.role == .user ? GroupChat.me : m.authorId
        let last = rp.claims.count >= rp.shares.count
        let whose = from == who ? "自己" : GroupPay.nameIn(chat, from)
        var notice = Message.new(chatId: m.chatId, role: who == GroupChat.me ? .user : .char, authorId: who,
                                 content: "[\(GroupPay.nameIn(chat, who))领取了\(whose)的红包 \(Interact.format(amount, rp.currency))\(last ? "，红包已被领完" : "")]",
                                 kind: "notice", turnId: turnId)
        notice.row["rpOf"] = .string(msgId)
        return notice
    }

    /// 那一行提示删了：这次领取退回去，退回的那一份留给下一个领的人（按领取先后重新排一遍金额）
    @discardableResult
    static func unclaim(_ notice: Message) throws -> Bool {
        guard notice.kind == "notice", case let id = notice.row.string("rpOf"), !id.isEmpty,
              var row = try Database.shared.get(Collections.messages, id: id), var rp = Packet(row["rp"]) else { return false }
        let kept = rp.claims.filter { $0.who != notice.authorId }
        guard kept.count != rp.claims.count else { return false }
        let shares = rp.shares
        rp.claims = kept.enumerated().map { i, c in Claim(who: c.who, amount: i < shares.count ? shares[i] : c.amount, at: c.at) }
        row["rp"] = rp.json
        row.touch()
        try Database.shared.put(Collections.messages, row)
        try refresh(id)
        return true
    }

    /// 这个人在这段会话里能领的那几个，新的在前。fromId 给了就只看那个人发的
    static func claimable(_ chatId: String, who: String, fromId: String = "", now: Double = Date().millis) throws -> [Message] {
        try Repo.messages(chatId: chatId, limit: 400)
            .filter { $0.kind == "redpacket" && whyNot($0, who: who, now: now).isEmpty
                && (fromId.isEmpty || ($0.role == .user ? GroupChat.me : $0.authorId) == fromId) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 过期的那几个把状态写回去（上下文里那一行要说「已过期」）。群聊每一轮拼提示词之前调一次，不调接口
    static func sweep(_ chatId: String, now: Double = Date().millis) {
        for m in (try? Repo.messages(chatId: chatId, limit: 400)) ?? [] where m.kind == "redpacket" {
            guard let rp = packet(m), state(rp, at: m.createdAt, now: now) == "expired", !m.content.contains("已过期") else { continue }
            try? refresh(m.id, now: now)
        }
    }
}

/// 群里的转账、角色发红包领红包、退群与改网名这几件事落成状态（网页版 reply.js 的 renderPart 群那一半）。
enum GroupPay {
    static func touch(_ chatId: String) throws {
        if var c = try Repo.chat(chatId) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
    }

    private static func meOf(_ chat: Chat) -> Persona? {
        let personas = (try? Repo.personas()) ?? []
        return personas.first { $0.id == chat.personaId } ?? ((try? Repo.activePersona()) ?? nil)
    }

    /// 群里的名字：群昵称优先，你是 me（网页版 redpacket.nameOf / transfer.nameIn）
    static func nameIn(_ chat: Chat, _ id: String) -> String {
        guard !id.isEmpty else { return "" }
        let nick = GroupChat.nick(chat, id)
        if !nick.isEmpty { return nick }
        if id == GroupChat.me {
            let n = meOf(chat)?.row.string("name") ?? ""
            return n.isEmpty ? "我" : n
        }
        let n = ((try? Repo.character(id)) ?? nil)?.row.string("name") ?? ""
        return n.isEmpty ? "某人" : n
    }

    /// 「群红包与转账」这一项对这个角色开着吗：新功能开了、能力开关里没关（网页版 payCapOn）
    static func capOn(_ char: Character, _ s: AppSettings) -> Bool {
        NewFeat.isOn("grouppay", s, char: char) && !capsOff(s).contains("grouppay")
    }

    static func capsOff(_ s: AppSettings) -> Set<String> { Set((s.raw["capsOff"]?.array ?? []).compactMap(\.string)) }

    // MARK: - 转账

    /// 群里转一笔给某个人（to 是角色 id 或 me）。返回还没落库的那一条
    static func transfer(chat: Chat, role: Message.Role, authorId: String, to: String, amount: Double, note: String,
                         turnId: String? = nil) throws -> Message {
        guard !to.isEmpty else { throw StoreError(message: "请选择收款人") }
        guard to != authorId else { throw StoreError(message: "不能转账给自己") }
        var m = try Interact.transfer(Message.new(chatId: chat.id, role: role, authorId: authorId, content: "", turnId: turnId),
                                      amount: amount, note: note)
        let toName = nameIn(chat, to)
        m.row["to"] = .string(to)
        m.row["toName"] = .string(toName)
        m.row["content"] = .string(Interact.transferContent(m.row.number("amount") ?? 0, m.row.string("note"), "pending",
                                                            m.row.string("currency"), toName: toName))
        return m
    }

    /// 我在群里转一笔
    static func sendTransfer(chatId: String, to: String, amount: Double, note: String) throws -> Message {
        guard let chat = try Repo.chat(chatId), chat.isGroup else { throw StoreError(message: "这段会话不是群聊") }
        let m = try Repo.append(transfer(chat: chat, role: .user, authorId: GroupChat.me, to: to, amount: amount, note: note))
        try touch(chatId)
        return m
    }

    /// 群里转给某个人、还没处理的最近一笔
    static func pendingTo(_ chatId: String, who: String) throws -> Message? {
        try Repo.messages(chatId: chatId, limit: 400)
            .last { $0.kind == "transfer" && $0.row.string("to") == who && $0.row.string("transfer") == "pending" }
    }

    // MARK: - 角色回复里写的

    /// 一轮里的一段落成状态。需要落一行的返回那一行（还没落库）；什么都不落的返回 nil。不满足条件的什么都不落
    static func effect(_ p: ReplyParser.Part, chat: Chat, char: Character, turnId: String) throws -> Message? {
        let s = AppSettings.load()
        switch p.type {
        case .transfer:
            // 群里要写明转给谁；名字对不上就当转给你。新功能没开就不落
            guard chat.isGroup, capOn(char, s), let amount = p.amount else { return nil }
            let to = p.to.flatMap { GroupChat.whoByName(chat, $0) } ?? GroupChat.me
            guard to != char.id else { return nil }
            return try? transfer(chat: chat, role: .char, authorId: char.id, to: to, amount: amount, note: p.text, turnId: turnId)
        case .settle:
            // 只处理转给自己的那一笔
            guard chat.isGroup, let target = try pendingTo(chat.id, who: char.id) else { return nil }
            return try Interact.settleTransfer(target.id, take: p.flag, turnId: turnId)
        case .redpacket:
            guard chat.isGroup, capOn(char, s) else { return nil }
            let type = p.extra ?? RedPacket.luck
            var to = ""
            if type == RedPacket.only {
                guard let who = p.to.flatMap({ GroupChat.whoByName(chat, $0) }), who != char.id else { return nil }
                to = who
            }
            return try? RedPacket.make(chat: chat, role: .char, authorId: char.id, type: type, total: p.amount ?? 0,
                                       count: p.count ?? 1, note: p.text, to: to, turnId: turnId)
        case .rpclaim:
            guard chat.isGroup, capOn(char, s) else { return nil }
            let fromId = p.text.isEmpty ? "" : (GroupChat.whoByName(chat, p.text) ?? "")
            let list = try RedPacket.claimable(chat.id, who: char.id, fromId: fromId)
                + (fromId.isEmpty ? [] : RedPacket.claimable(chat.id, who: char.id))
            guard let first = list.first else { return nil }
            return try RedPacket.claim(first.id, who: char.id, turnId: turnId)
        case .leave:
            guard chat.isGroup, GroupMore.leaveCapOn(char, s) else { return nil }
            return try GroupMore.leave(chat, charId: char.id, turnId: turnId)
        case .selfnick:
            guard GroupMore.selfNickCapOn(char, s) else { return nil }
            return try GroupMore.setOwnNick(chat: chat, char: char, name: p.text, turnId: turnId)
        default:
            return nil
        }
    }

    /// 删掉那一行提示（重新生成那一轮）时把它做的事退回去。认得出是自己的就返回 true
    static func undo(_ notice: Message) throws -> Bool {
        guard notice.kind == "notice" else { return false }
        if !notice.row.string("rpOf").isEmpty { try RedPacket.unclaim(notice); return true }
        if let u = notice.row["nickUndo"]?.object, let charId = u["charId"]?.string {
            if var c = try Repo.character(charId) {
                c.row["nick"] = .string(u["prev"]?.string ?? "")
                c.row.touch()
                try Database.shared.put(Collections.characters, c.row)
            }
            return true
        }
        return false
    }
}
