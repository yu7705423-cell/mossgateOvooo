import Foundation

/// 卡包里那几种卡（网页版 system/funcard.js、pass.js、ticket.js、member.js、idcard.js，ARCHITECTURE 4.611、4.643、4.644）。
///
/// **卡就是消息**：送一张卡是对话里一条消息，之后的每一次使用、收回、检票、消费又是一条。剩几次、收没收回、过没过期，
/// 全部从这些消息现算，不另存一份。重新生成那一轮、删掉那条消息，那件事就当没发生（网页版第 22 条：状态是真的）。
/// 正文是给模型读的固定格式，方括号标记是协议，和网页版一字不差。
///
/// 这里的函数只**造**消息（返回一条 Message），由调用方追加：回复里的由 ChatEngine 落，卡包里点的由 `post` 落。
enum WalletCards {
    static let day: Double = 86_400_000

    /// 网页版 clean：空白折成一个空格、去掉两头（不截字数）
    static func clean(_ t: String) -> String {
        t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// 数字写成网页版拼进字符串的样子：整数不带小数点
    static func numText(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
    }

    static func bare(_ t: String) -> String { t.replacingOccurrences(of: #"[《》「」"]"#, with: "", options: .regularExpression) }

    static func authorOf(_ chat: Chat?, _ role: Message.Role, _ authorId: String) -> String {
        if !authorId.isEmpty { return authorId }
        return role == .user ? "me" : (chat?.characterIds.first ?? "")
    }

    static func fmtDay(_ ms: Double) -> String { Ledger.ymd(ms) }

    static func endOfDay(_ ms: Double) -> Double {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date(millis: ms))
        return (cal.date(byAdding: .day, value: 1, to: start)?.millis ?? ms) - 1
    }

    /// 这段对话里的消息，按时间升序。needle 是粗筛的字样（Database.containing），逐条再按 kind 核对
    static func messages(_ chatId: String, _ needles: [String], kinds: Set<String>) -> [Message] {
        let rows = (try? Database.shared.containing(Collections.messages, where: chatId, any: needles.map { [$0] })) ?? []
        return rows.map(Message.init(row:)).filter { kinds.contains($0.kind) }
    }

    /// 单聊（群里没有卡），连同那个角色
    static func singleChats() -> [(chat: Chat, char: Character)] {
        ((try? Repo.chats()) ?? []).compactMap { c in
            guard !c.row.bool("group"), c.characterIds.count == 1, let ch = (try? Repo.character(c.characterIds[0])) ?? nil else { return nil }
            return (c, ch)
        }
    }

    /// 你在卡包里点的：追加进对话、碰一下会话的时间
    @discardableResult
    static func post(_ m: Message) throws -> Message {
        let out = try Repo.append(m)
        try LedgerRequest.touch(m.chatId)
        Ledger.changed()
        return out
    }

    static func notice(_ base: Message, _ text: String) -> Message {
        var m = base
        m.row["kind"] = .string("notice")
        m.row["content"] = .string(text)
        m.row["status"] = .string("done")
        return m
    }

    // MARK: - 娱乐卡（funcard.js）

    enum Fun {
        static let pending = "pending", done = "done", declined = "declined"

        struct Template { let name: String; let desc: String; let color: String; let uses: Int }
        static let templates = [
            Template(name: "和好卡", desc: "吵架之后出示这张卡，对方要先停下来，和你好好说话。", color: "rose", uses: 1),
            Template(name: "亲亲卡", desc: "出示即可兑换一个亲亲。", color: "pink", uses: 3),
            Template(name: "抱抱卡", desc: "出示即可兑换一个拥抱，不限时长。", color: "peach", uses: 3),
            Template(name: "免生气卡", desc: "这一次做错的小事，对方不生气。", color: "sky", uses: 1),
            Template(name: "许愿卡", desc: "说出一个愿望，对方尽力去实现。", color: "lilac", uses: 1),
            Template(name: "陪伴卡", desc: "对方放下手头的事，陪你一会儿。", color: "mint", uses: 2),
        ]
        static let colors: [(id: String, label: String)] = [("rose", "玫瑰"), ("pink", "樱粉"), ("peach", "杏色"), ("sand", "沙色"),
                                                            ("mint", "薄荷"), ("sky", "天蓝"), ("lilac", "丁香"), ("ink", "墨色")]

        static func giveText(name: String, desc: String, uses: Int, expiresAt: Double, confirm: Bool) -> String {
            var parts = [name, desc, uses > 0 ? "\(uses) 次" : "不限次数", expiresAt > 0 ? "\(fmtDay(expiresAt)) 前有效" : "长期有效"]
            if confirm { parts.append("使用需对方同意") }
            return "[送卡：\(parts.joined(separator: "｜"))]"
        }

        static func useText(_ name: String, _ state: String) -> String {
            "[用卡：\(name)]" + (state == pending ? "（待对方同意）" : state == declined ? "（对方未同意）" : "")
        }

        /// 送一张。base.role 是送出的一方；days 是从今天起有效几天（0 长期），until 是直接给的到期时刻（优先）；uses 0 不限次数
        static func give(_ base: Message, name: String, desc: String = "", uses: Double = 1, days: Double = 0, until: Double = 0,
                         color: String = "rose", imageId: String? = nil, confirm: Bool = false, now: Date = Date()) throws -> Message {
            let n = clean(name)
            guard !n.isEmpty else { throw StoreError(message: "请填写卡的名字") }
            let u = max(0, Int((uses.isFinite ? uses : 0).rounded()))
            let t = now.millis
            let exp = until > t ? until : days > 0 ? t + days.rounded() * day : 0
            let expiresAt = exp > 0 ? endOfDay(exp) : 0
            let col = colors.contains { $0.id == color } ? color : "rose"
            let d = clean(desc)
            var m = base
            m.row["kind"] = .string("funcard")
            m.row["status"] = .string("done")
            m.row["card"] = .object(["name": .string(n), "desc": .string(d), "uses": .number(Double(u)), "expiresAt": .number(expiresAt),
                                     "color": .string(col), "confirm": .bool(confirm)])
            m.row["cardImageId"] = imageId.map { .string($0) } ?? .null
            m.row["content"] = .string(giveText(name: n, desc: d, uses: u, expiresAt: expiresAt, confirm: confirm))
            return m
        }

        struct State: Identifiable {
            let msg: Message
            var id: String { msg.id }
            var chatId: String { msg.chatId }
            let name: String, desc: String, color: String, imageId: String
            let uses: Int
            let expiresAt: Double
            let confirm: Bool
            /// 送出的一方（user / char），持有的是另一方
            let from: String, holder: String
            let givenAt: Double
            let used: Int
            /// 不限次数时是 nil
            let left: Int?
            let pending: Message?
            let expired: Bool
            let history: [Message]
            var usable: Bool { !expired && (left ?? 1) > 0 && pending == nil }
            var status: String { expired ? "expired" : (left ?? 1) <= 0 ? "spent" : pending != nil ? "pending" : "active" }
            var charId = "", charName = ""
        }

        static func state(_ m: Message, all: [Message], now: Date = Date()) -> State? {
            guard m.kind == "funcard" else { return nil }
            let c = m.row["card"]?.object ?? [:]
            let uses = Int(Ledger.num(c["uses"]))
            let hist = all.filter { $0.kind == "funcard-use" && $0.row.string("cardMsgId") == m.id }
            let used = hist.filter { $0.row.string("useState") == done }.count
            let exp = Ledger.num(c["expiresAt"])
            return State(msg: m, name: c["name"]?.string ?? "", desc: c["desc"]?.string ?? "", color: c["color"]?.string ?? "rose",
                         imageId: m.row.string("cardImageId"), uses: uses, expiresAt: exp, confirm: Ledger.truthy(c["confirm"]),
                         from: m.role.rawValue, holder: m.role == .user ? "char" : "user", givenAt: m.createdAt, used: used,
                         left: uses > 0 ? max(0, uses - used) : nil, pending: hist.first { $0.row.string("useState") == pending },
                         expired: exp > 0 && now.millis > exp, history: hist)
        }

        static func state(_ id: String) -> State? {
            guard let row = (try? Database.shared.get(Collections.messages, id: id)) ?? nil else { return nil }
            let m = Message(row: row)
            return state(m, all: messages(m.chatId, ["funcard"], kinds: ["funcard", "funcard-use"]))
        }

        /// 一段对话里的全部卡，新送的在前
        static func cardsOf(_ chatId: String, now: Date = Date()) -> [State] {
            let all = messages(chatId, ["funcard"], kinds: ["funcard", "funcard-use"])
            return Ledger.stableSorted(all.filter { $0.kind == "funcard" }) { $0.createdAt > $1.createdAt }.compactMap { state($0, all: all, now: now) }
        }

        /// 所有单聊里的卡，卡包首页用。每张带上对方是谁
        static func allCards() -> [State] {
            var out: [State] = []
            for (c, ch) in singleChats() {
                for var s in cardsOf(c.id) { s.charId = ch.id; s.charName = ch.row.string("name").isEmpty ? "角色" : ch.row.string("name"); out.append(s) }
            }
            return Ledger.stableSorted(out) { $0.givenAt > $1.givenAt }
        }

        /// 持有的一方按名字找一张还能用的
        static func findUsable(_ chatId: String, holder: String, name: String) -> State? {
            let q = bare(clean(name))
            let list = cardsOf(chatId).filter { $0.holder == holder && $0.usable }
            return list.first { $0.name == q } ?? list.first { $0.name.contains(q) || q.contains($0.name) }
        }

        /// 用一次。role 必须是持有的一方。要确认的先挂着，不用确认的当场算一次
        static func use(_ cardId: String, role: Message.Role, authorId: String = "", turnId: String? = nil) throws -> Message {
            guard let s = state(cardId) else { throw StoreError(message: "这张卡已经不在了") }
            guard s.holder == role.rawValue else { throw StoreError(message: "这张卡不在你手里") }
            if s.expired { throw StoreError(message: "这张卡已经过期") }
            if (s.left ?? 1) <= 0 { throw StoreError(message: "这张卡的次数已经用完") }
            if s.pending != nil { throw StoreError(message: "上一次使用还在等对方同意") }
            let chat = (try? Repo.chat(s.chatId)) ?? nil
            let st = s.confirm ? pending : done
            var m = Message.new(chatId: s.chatId, role: role, authorId: authorOf(chat, role, authorId), content: useText(s.name, st),
                                kind: "funcard-use", turnId: turnId)
            m.row["cardMsgId"] = .string(s.id)
            m.row["cardName"] = .string(s.name)
            m.row["useState"] = .string(st)
            return m
        }

        static func pendingFrom(_ chatId: String, role: Message.Role) -> Message? {
            messages(chatId, ["funcard-use"], kinds: ["funcard-use"]).last { $0.role == role && $0.row.string("useState") == pending }
        }

        /// 同意或不同意那一次使用。返回那一行提示（由调用方追加）
        static func settle(_ useId: String, ok: Bool, turnId: String? = nil) throws -> Message? {
            guard var row = try Database.shared.get(Collections.messages, id: useId) else { return nil }
            let m = Message(row: row)
            guard m.kind == "funcard-use", row.string("useState") == pending else { return nil }
            let st = ok ? done : declined
            row["useState"] = .string(st)
            row["content"] = .string(useText(row.string("cardName"), st))
            row.touch()
            try Database.shared.put(Collections.messages, row)
            let n = Interact.names(m.chatId)
            let byUser = m.role != .user
            var notice = Message.new(chatId: m.chatId, role: byUser ? .user : .char, authorId: byUser ? "me" : n.charId,
                                     content: "[\(byUser ? n.me : n.char)\(ok ? "同意了" : "没有同意")\(byUser ? n.char : n.me)使用\(row.string("cardName"))]",
                                     kind: "notice", turnId: turnId)
            notice.row["settledId"] = .string(useId)
            notice.row["settledKind"] = .string("funcard")
            return notice
        }

        /// 提示行被删就当没表过态
        static func unsettle(_ notice: Message) throws {
            let id = notice.row.string("settledId")
            guard notice.kind == "notice", notice.row.string("settledKind") == "funcard", !id.isEmpty,
                  var row = try Database.shared.get(Collections.messages, id: id), row.string("kind") == "funcard-use" else { return }
            row["useState"] = .string(pending)
            row["content"] = .string(useText(row.string("cardName"), pending))
            row.touch()
            try Database.shared.put(Collections.messages, row)
        }

        /// 给模型的事实：两边各持有什么卡、还剩几次、到哪天、有没有等着表态的
        static func facts(_ chatId: String) -> (mine: [String], theirs: [String], waiting: String) {
            let live = cardsOf(chatId).filter { $0.status != "expired" && $0.status != "spent" }
            func line(_ s: State) -> String {
                "\(s.name)（\(s.uses > 0 ? "剩 \(s.left ?? 0) 次" : "不限次数")\(s.expiresAt > 0 ? "，\(fmtDay(s.expiresAt)) 前有效" : "")\(s.confirm ? "，使用需对方同意" : "")）"
            }
            return (live.filter { $0.holder == "char" }.map(line), live.filter { $0.holder == "user" }.map(line),
                    pendingFrom(chatId, role: .user)?.row.string("cardName") ?? "")
        }

        /// [送卡：和好卡｜吵架后先和好｜3 次｜30 天] 拆开（网页版 reply.js 的 parseFunGive）
        static func parse(_ body: String) -> (name: String, desc: String, uses: Double, days: Double, until: Double, confirm: Bool)? {
            let seg = body.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "|" || $0 == "｜" }).map { $0.trimmingCharacters(in: .whitespaces) }
            let name = bare(seg.first ?? "")
            guard !name.isEmpty else { return nil }
            func firstNum(_ t: String) -> Double {
                guard let r = t.range(of: #"\d+"#, options: .regularExpression) else { return 0 }
                return Double(t[r]) ?? 0
            }
            let usesT = seg.count > 2 ? seg[2] : ""
            let uses = usesT.range(of: "不限|无限|unlimited", options: [.regularExpression, .caseInsensitive]) != nil ? 0 : (firstNum(usesT) == 0 ? 1 : firstNum(usesT))
            let termT = seg.count > 3 ? seg[3] : ""
            var until = 0.0
            if let m = ReplyParser.match(ReplyParser.regex(#"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})"#, []), termT),
               let y = Int(m[1]), let mo = Int(m[2]), let d = Int(m[3]) {
                until = Calendar.current.date(from: DateComponents(year: y, month: mo, day: d))?.millis ?? 0
            }
            let days = until != 0 || termT.range(of: "长期|不限|永久", options: .regularExpression) != nil ? 0 : firstNum(termT)
            let confirm = seg.dropFirst(4).contains { $0.range(of: "确认|同意", options: .regularExpression) != nil }
            return (name, seg.count > 1 ? seg[1] : "", uses, days, until, confirm)
        }
    }

    // MARK: - 门禁卡、钥匙、房卡（pass.js）

    enum Pass {
        struct Kind { let id: String; let label: String; let give: String; let use: String; let eyebrow: String }
        static let kinds = [
            Kind(id: "door", label: "门禁卡", give: "给门禁卡", use: "刷门禁卡", eyebrow: "ACCESS"),
            Kind(id: "key", label: "钥匙", give: "给钥匙", use: "用钥匙", eyebrow: "KEY"),
            Kind(id: "room", label: "房卡", give: "给房卡", use: "刷房卡", eyebrow: "ROOM"),
        ]
        static func kindOf(_ id: String) -> Kind { kinds.first { $0.id == id } ?? kinds[0] }
        static func kindByMark(_ word: String) -> Kind? { kinds.first { $0.give == word || $0.use == word } }
        static let revokeMarks = ["收回门禁卡": "door", "收回钥匙": "key", "收回房卡": "room"]
        static let grantMarks = ["恢复门禁卡": "door", "恢复钥匙": "key", "恢复房卡": "room"]

        static func giveText(kind: String, name: String, place: String, note: String) -> String {
            "[\(kindOf(kind).give)：\([name, place, note].filter { !$0.isEmpty }.joined(separator: "｜"))]"
        }

        /// 送出一张。base.role 是发卡人。房卡挂在这段会话眼下那一次出行上（4.644）：出行结束就算退房
        static func give(_ base: Message, kind: String = "door", name: String = "", place: String = "", note: String = "") throws -> Message {
            guard (try Repo.chat(base.chatId)) != nil else { throw StoreError(message: "这段对话已经不在了") }
            let k = kindOf(kind)
            let n = clean(name)
            var p: [String: JSONValue] = ["kind": .string(k.id), "name": .string(n.isEmpty ? k.label : n), "place": .string(clean(place)), "note": .string(clean(note))]
            if k.id == "room", let t = Trips.current(base.chatId), t.string("kind") == "trip",
               ["soon", "going"].contains(Trips.phase(t)) {
                p["tripId"] = .string(t.id)
                p["tripTitle"] = .string(clean(t.string("title")))
            }
            var m = base
            m.row["kind"] = .string("pass")
            m.row["status"] = .string("done")
            m.row["pass"] = .object(p)
            m.row["content"] = .string(giveText(kind: k.id, name: p["name"]?.string ?? "", place: p["place"]?.string ?? "", note: p["note"]?.string ?? ""))
            return m
        }

        struct State: Identifiable {
            let msg: Message
            var id: String { msg.id }
            var chatId: String { msg.chatId }
            let kind: String, name: String, place: String, note: String, tripId: String, tripTitle: String
            var kindLabel: String { Pass.kindOf(kind).label }
            let from: String, holder: String
            let givenAt: Double
            let revoked: Bool
            let revokedAt: Double
            let uses: Int
            let lastUse: Double
            let checkedOut: Bool
            let history: [Message]
            var charId = "", charName = ""
        }

        static func state(_ m: Message, all: [Message]) -> State? {
            guard m.kind == "pass" else { return nil }
            let p = m.row["pass"]?.object ?? [:]
            let acts = all.filter { $0.kind == "pass-act" && $0.row.string("passMsgId") == m.id }
            let gate = acts.last { ["revoke", "grant"].contains($0.row.string("act")) }
            let revoked = gate?.row.string("act") == "revoke"
            let uses = acts.filter { $0.row.string("act") == "use" }
            let tripId = p["tripId"]?.string ?? ""
            var out = false
            if !tripId.isEmpty {
                let tr = Trips.get(tripId)
                out = tr == nil || Trips.phase(tr!) == "done" || tr!.string("state") == "dropped"
            }
            return State(msg: m, kind: p["kind"]?.string ?? "door", name: p["name"]?.string ?? "", place: p["place"]?.string ?? "",
                         note: p["note"]?.string ?? "", tripId: tripId, tripTitle: p["tripTitle"]?.string ?? "",
                         from: m.role.rawValue, holder: m.role == .user ? "char" : "user", givenAt: m.createdAt,
                         revoked: revoked, revokedAt: revoked ? (gate?.createdAt ?? 0) : 0, uses: uses.count, lastUse: uses.last?.createdAt ?? 0,
                         checkedOut: out, history: acts)
        }

        static func state(_ id: String) -> State? {
            guard let row = (try? Database.shared.get(Collections.messages, id: id)) ?? nil else { return nil }
            let m = Message(row: row)
            return state(m, all: messages(m.chatId, ["pass"], kinds: ["pass", "pass-act"]))
        }

        static func passesOf(_ chatId: String) -> [State] {
            let all = messages(chatId, ["pass"], kinds: ["pass", "pass-act"])
            return Ledger.stableSorted(all.filter { $0.kind == "pass" }) { $0.createdAt > $1.createdAt }.compactMap { state($0, all: all) }
        }

        static func allPasses() -> [State] {
            var out: [State] = []
            for (c, ch) in singleChats() {
                for var s in passesOf(c.id) { s.charId = ch.id; s.charName = ch.row.string("name").isEmpty ? "角色" : ch.row.string("name"); out.append(s) }
            }
            return Ledger.stableSorted(out) { $0.givenAt > $1.givenAt }
        }

        /// 按名字找一张。holderSide 为真是持有的一方找自己手里的，假是发卡人找自己发出去的
        static func find(_ chatId: String, role: String, name: String, holderSide: Bool = true, kind: String = "") -> State? {
            let q = bare(clean(name))
            let list = passesOf(chatId).filter { (holderSide ? $0.holder == role : $0.from == role) && (kind.isEmpty || $0.kind == kind) }
            if q.isEmpty { return list.first }
            return list.first { $0.name == q } ?? list.first {
                $0.name.contains(q) || q.contains($0.name) || (!$0.place.isEmpty && ($0.place.contains(q) || q.contains($0.place)))
            }
        }

        private static func act(_ s: State, _ a: String, role: Message.Role, authorId: String, turnId: String?) -> Message {
            let chat = (try? Repo.chat(s.chatId)) ?? nil
            let n = Interact.names(s.chatId)
            let who = role == .user ? n.me : n.char
            let whereText = s.place.isEmpty ? "" : "（\(s.place)）"
            let text = a == "use" ? "[\(kindOf(s.kind).use)：\(s.name)]"
                : "[\(who)\(a == "revoke" ? "收回了" : "恢复了")\(role == .user ? n.char : n.me)的\(s.name)\(whereText)的权限]"
            var m = Message.new(chatId: s.chatId, role: role, authorId: authorOf(chat, role, authorId), content: text, kind: "pass-act", turnId: turnId)
            m.row["passMsgId"] = .string(s.id)
            m.row["passName"] = .string(s.name)
            m.row["act"] = .string(a)
            return m
        }

        /// 持有的一方刷一次。收回了、退房了就刷不了
        static func use(_ id: String, role: Message.Role, authorId: String = "", turnId: String? = nil) throws -> Message {
            guard let s = state(id) else { throw StoreError(message: "这张卡已经不在了") }
            guard s.holder == role.rawValue else { throw StoreError(message: "这张卡不在你手里") }
            if s.revoked { throw StoreError(message: "这张\(s.kindLabel)的权限已被收回") }
            if s.checkedOut { throw StoreError(message: "「\(s.tripTitle.isEmpty ? "那次出行" : s.tripTitle)」已经结束，房卡已退") }
            return act(s, "use", role: role, authorId: authorId, turnId: turnId)
        }

        static func revoke(_ id: String, role: Message.Role, authorId: String = "", turnId: String? = nil) throws -> Message {
            guard let s = state(id) else { throw StoreError(message: "这张卡已经不在了") }
            guard s.from == role.rawValue else { throw StoreError(message: "只有发卡的一方能收回") }
            if s.revoked { throw StoreError(message: "权限已经收回了") }
            return act(s, "revoke", role: role, authorId: authorId, turnId: turnId)
        }

        static func grant(_ id: String, role: Message.Role, authorId: String = "", turnId: String? = nil) throws -> Message {
            guard let s = state(id) else { throw StoreError(message: "这张卡已经不在了") }
            guard s.from == role.rawValue else { throw StoreError(message: "只有发卡的一方能恢复") }
            if !s.revoked { throw StoreError(message: "权限没有被收回") }
            return act(s, "grant", role: role, authorId: authorId, turnId: turnId)
        }

        /// 给模型的事实：两边各持有什么卡、哪张的权限被收回了。只写状态（第 22 条）
        static func facts(_ chatId: String) -> (mine: [String], given: [String]) {
            let all = passesOf(chatId)
            func line(_ s: State) -> String {
                "\(s.kindLabel)「\(s.name)」\(s.place.isEmpty ? "" : " (\(s.place))")\(s.revoked ? " - access revoked" : "")\(s.checkedOut ? " - checked out" : "")"
            }
            return (all.filter { $0.holder == "char" }.map(line), all.filter { $0.from == "char" }.map(line))
        }
    }

    /// 出行（网页版 trip.js）里房卡要用的那一点：取一行、算阶段、这段会话眼下那一次
    enum Trips {
        static func get(_ id: String) -> Row? { (try? Database.shared.get("trips", id: id)) ?? nil }

        static func today() -> String { Ledger.ymd(Clock.now(.load()).millis) }

        private static func isDate(_ v: String) -> Bool { v.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }

        /// talking / soon / going / done / dropped（网页版 phaseOf）
        static func phase(_ row: Row) -> String {
            let st = row.string("state")
            if st == "dropped" { return "dropped" }
            if st != "booked" { return "talking" }
            let now = today()
            let from = isDate(row.string("from")) ? row.string("from") : ""
            let to = isDate(row.string("to")) ? row.string("to") : from
            if from.isEmpty || now < from { return "soon" }
            if now > to { return "done" }
            return "going"
        }

        static func current(_ chatId: String) -> Row? {
            let rank = ["going": 0, "soon": 1, "talking": 2]
            let list = Ledger.stableSorted((try? Database.shared.all("trips", where: chatId)) ?? []) { Ledger.num($0["createdAt"]) > Ledger.num($1["createdAt"]) }
            let live = list.filter { rank[phase($0)] != nil }
            return Ledger.stableSorted(live) { a, b in
                let d = (rank[phase(a)] ?? 9) - (rank[phase(b)] ?? 9)
                if d != 0 { return d < 0 }
                let fa = a.string("from").isEmpty ? "9999" : a.string("from"), fb = b.string("from").isEmpty ? "9999" : b.string("from")
                return fa < fb
            }.first
        }
    }

    // MARK: - 票券（ticket.js）

    enum Ticket {
        struct Kind { let id: String; let label: String; let eyebrow: String }
        static let kinds = [Kind(id: "movie", label: "电影票", eyebrow: "CINEMA"), Kind(id: "show", label: "演出票", eyebrow: "LIVE"),
                            Kind(id: "match", label: "比赛票", eyebrow: "MATCH"), Kind(id: "other", label: "入场券", eyebrow: "ADMIT ONE")]
        static func kindOf(_ id: String) -> Kind { kinds.first { $0.id == id } ?? kinds[0] }
        static func kindByWord(_ t: String) -> Kind? { kinds.first { t.contains(String($0.label.prefix(2))) } }

        /// 开场时间：认「2026-10-20 19:30」「10月20日 19:30」「10-20」这几种，认不出就是 0
        static func parseWhen(_ text: String, now: Date = Clock.now(.load())) -> Double {
            let cal = Calendar.current
            let y0 = cal.component(.year, from: now)
            var y = y0, mo = 0, d = 0
            var hit = ""
            if let m = ReplyParser.match(ReplyParser.regex(#"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})日?"#, []), text) {
                y = Int(m[1]) ?? y0; mo = Int(m[2]) ?? 0; d = Int(m[3]) ?? 0; hit = m[0]
            } else if let m = ReplyParser.match(ReplyParser.regex(#"(\d{1,2})[-/.月](\d{1,2})日?"#, []), text) {
                mo = Int(m[1]) ?? 0; d = Int(m[2]) ?? 0; hit = m[0]
            }
            guard mo != 0, d != 0 else { return 0 }
            // 日期摘掉之后再找几点几分
            let rest: String = {
                guard let r = text.range(of: hit) else { return text }
                return text.replacingCharacters(in: r, with: " ")
            }()
            var h = 0, mi = 0
            let hm = ReplyParser.match(ReplyParser.regex(#"(\d{1,2})[:：](\d{2})"#, []), rest)
                ?? ReplyParser.match(ReplyParser.regex(#"(\d{1,2})\s*点(?:\s*(\d{1,2})\s*分?)?"#, []), rest)
            if let hm, let hh = Int(hm[1]), hh < 24 {
                h = hh + (rest.range(of: "下午|晚上", options: .regularExpression) != nil && hh < 12 ? 12 : 0)
                if hm.count > 2, let m2 = Int(hm[2]) { mi = m2 }
            }
            // 和 JS 的 new Date(y, m, d) 一样，日子溢出时顺到下个月（Calendar 默认宽松）
            func at(_ year: Int) -> Double { cal.date(from: DateComponents(year: year, month: mo, day: d, hour: h, minute: mi))?.millis ?? 0 }
            var v = at(y)
            // 只写了月日、又已经过去很久的，算明年
            if text.range(of: #"\d{4}"#, options: .regularExpression) == nil && v < now.millis - 30 * day { v = at(y + 1) }
            return v
        }

        static func whenText(_ at: Double) -> String {
            guard at != 0 else { return "" }
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date(millis: at))
            let hm = (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0 ? String(format: " %02d:%02d", c.hour ?? 0, c.minute ?? 0) : ""
            return Ledger.ymd(at) + hm
        }

        static func giveText(title: String, at: Double, venue: String, seat: String) -> String {
            "[送票：\([title, whenText(at), venue, seat].filter { !$0.isEmpty }.joined(separator: "｜"))]"
        }

        static func give(_ base: Message, kind: String = "", title: String, at: Double = 0, when: String = "", venue: String = "",
                         seat: String = "", note: String = "") throws -> Message {
            guard (try Repo.chat(base.chatId)) != nil else { throw StoreError(message: "这段对话已经不在了") }
            // 片名的书名号照原样留着，找票时两边都摘掉再比
            let name = clean(title).replacingOccurrences(of: "\"", with: "")
            guard !name.isEmpty else { throw StoreError(message: "请填写场次的名字") }
            let k = kindOf(kind.isEmpty ? (kindByWord(name)?.id ?? "movie") : kind)
            let when0 = at != 0 ? at : parseWhen(when)
            let t: [String: JSONValue] = ["kind": .string(k.id), "title": .string(name), "at": .number(when0), "venue": .string(clean(venue)),
                                          "seat": .string(clean(seat)), "note": .string(clean(note))]
            var m = base
            m.row["kind"] = .string("ticket")
            m.row["status"] = .string("done")
            m.row["ticket"] = .object(t)
            m.row["content"] = .string(giveText(title: name, at: when0, venue: clean(venue), seat: clean(seat)))
            return m
        }

        struct State: Identifiable {
            let msg: Message
            var id: String { msg.id }
            var chatId: String { msg.chatId }
            let kind: String, title: String, venue: String, seat: String, note: String
            let at: Double
            var kindLabel: String { Ticket.kindOf(kind).label }
            let from: String, holder: String
            let givenAt: Double
            let checked: Bool
            let checkedAt: Double
            let expired: Bool
            let daysLeft: Int?
            var status: String { checked ? "checked" : expired ? "expired" : "active" }
            var charId = "", charName = ""
        }

        static func state(_ m: Message, all: [Message], now: Date = Clock.now(.load())) -> State? {
            guard m.kind == "ticket" else { return nil }
            let t = m.row["ticket"]?.object ?? [:]
            let check = all.first { $0.kind == "ticket-act" && $0.row.string("ticketMsgId") == m.id && $0.row.string("act") == "check" }
            let at = Ledger.num(t["at"])
            let end = at != 0 ? endOfDay(at) : 0
            let cal = Calendar.current
            var left: Int?
            if at != 0 {
                let a = cal.startOfDay(for: Date(millis: at)).millis, b = cal.startOfDay(for: now).millis
                left = Int(((a - b) / day).rounded(.up))
            }
            return State(msg: m, kind: t["kind"]?.string ?? "movie", title: t["title"]?.string ?? "", venue: t["venue"]?.string ?? "",
                         seat: t["seat"]?.string ?? "", note: t["note"]?.string ?? "", at: at, from: m.role.rawValue,
                         holder: m.role == .user ? "char" : "user", givenAt: m.createdAt, checked: check != nil, checkedAt: check?.createdAt ?? 0,
                         expired: check == nil && end != 0 && now.millis > end, daysLeft: left)
        }

        static func state(_ id: String) -> State? {
            guard let row = (try? Database.shared.get(Collections.messages, id: id)) ?? nil else { return nil }
            let m = Message(row: row)
            return state(m, all: messages(m.chatId, ["ticket"], kinds: ["ticket", "ticket-act"]))
        }

        static func ticketsOf(_ chatId: String) -> [State] {
            let all = messages(chatId, ["ticket"], kinds: ["ticket", "ticket-act"])
            return Ledger.stableSorted(all.filter { $0.kind == "ticket" }) { $0.createdAt > $1.createdAt }.compactMap { state($0, all: all) }
        }

        static func allTickets() -> [State] {
            var out: [State] = []
            for (c, ch) in singleChats() {
                for var s in ticketsOf(c.id) { s.charId = ch.id; s.charName = ch.row.string("name").isEmpty ? "角色" : ch.row.string("name"); out.append(s) }
            }
            return Ledger.stableSorted(out) { a, b in
                let ra = a.status == "active" ? 0 : 1, rb = b.status == "active" ? 0 : 1
                if ra != rb { return ra < rb }
                return (a.at != 0 ? a.at : 9e15) < (b.at != 0 ? b.at : 9e15)
            }
        }

        static func findUsable(_ chatId: String, holder: String, name: String) -> State? {
            let q = bare(clean(name)).trimmingCharacters(in: .whitespaces)
            let list = ticketsOf(chatId).filter { $0.holder == holder && $0.status == "active" }
            if q.isEmpty { return list.first }
            func b(_ s: State) -> String { bare(s.title).trimmingCharacters(in: .whitespaces) }
            return list.first { b($0) == q } ?? list.first { b($0).contains(q) || q.contains(b($0)) }
        }

        /// 检票。只有持有的一方，过期、检过的不行
        static func check(_ id: String, role: Message.Role, authorId: String = "", turnId: String? = nil) throws -> Message {
            guard let s = state(id) else { throw StoreError(message: "这张票已经不在了") }
            guard s.holder == role.rawValue else { throw StoreError(message: "这张票不在你手里") }
            if s.checked { throw StoreError(message: "这张票已经检过了") }
            if s.expired { throw StoreError(message: "这张票已经过期") }
            let chat = (try? Repo.chat(s.chatId)) ?? nil
            var m = Message.new(chatId: s.chatId, role: role, authorId: authorOf(chat, role, authorId), content: "[检票：\(s.title)]",
                                kind: "ticket-act", turnId: turnId)
            m.row["ticketMsgId"] = .string(s.id)
            m.row["ticketTitle"] = .string(s.title)
            m.row["act"] = .string("check")
            return m
        }

        static func facts(_ chatId: String) -> (mine: [String], theirs: [String]) {
            let live = ticketsOf(chatId).filter { $0.status == "active" }
            func line(_ s: State) -> String {
                "\(s.kindLabel)「\(s.title)」\(s.at != 0 ? " at \(whenText(s.at))" : "")\(s.venue.isEmpty ? "" : ", \(s.venue)")\(s.seat.isEmpty ? "" : ", seat \(s.seat)")"
            }
            return (live.filter { $0.holder == "char" }.map(line), live.filter { $0.holder == "user" }.map(line))
        }
    }

    // MARK: - 会员卡（member.js）：两个人共用，去一次攒一点积分

    enum Member {
        struct State: Identifiable {
            let msg: Message
            var id: String { msg.id }
            var chatId: String { msg.chatId }
            let shop: String, note: String, by: String
            let openedAt: Double
            let visits: Int
            let points: Int
            let lastAt: Double
            let history: [Message]
            var charId = "", charName = ""
        }

        static func state(_ m: Message, all: [Message]) -> State? {
            guard m.kind == "member" else { return nil }
            let o = m.row["member"]?.object ?? [:]
            let v = all.filter { $0.kind == "member-act" && $0.row.string("memberMsgId") == m.id }
            return State(msg: m, shop: o["shop"]?.string ?? "", note: o["note"]?.string ?? "", by: m.role.rawValue, openedAt: m.createdAt,
                         visits: v.count, points: Int(v.reduce(0) { $0 + Ledger.num($1.row["points"]) }), lastAt: v.last?.createdAt ?? 0, history: v)
        }

        static func state(_ id: String) -> State? {
            guard let row = (try? Database.shared.get(Collections.messages, id: id)) ?? nil else { return nil }
            let m = Message(row: row)
            return state(m, all: messages(m.chatId, ["member"], kinds: ["member", "member-act"]))
        }

        static func cardsOf(_ chatId: String) -> [State] {
            let all = messages(chatId, ["member"], kinds: ["member", "member-act"])
            return Ledger.stableSorted(all.filter { $0.kind == "member" }) { $0.createdAt > $1.createdAt }.compactMap { state($0, all: all) }
        }

        static func allCards() -> [State] {
            var out: [State] = []
            for (c, ch) in singleChats() {
                for var s in cardsOf(c.id) { s.charId = ch.id; s.charName = ch.row.string("name").isEmpty ? "角色" : ch.row.string("name"); out.append(s) }
            }
            return Ledger.stableSorted(out) { ($0.lastAt != 0 ? $0.lastAt : $0.openedAt) > ($1.lastAt != 0 ? $1.lastAt : $1.openedAt) }
        }

        static func find(_ chatId: String, shop: String) -> State? {
            let q = bare(clean(shop))
            let list = cardsOf(chatId)
            if q.isEmpty { return list.first }
            return list.first { $0.shop == q } ?? list.first { $0.shop.contains(q) || q.contains($0.shop) }
        }

        static func open(_ base: Message, shop: String, note: String = "") throws -> Message {
            guard (try Repo.chat(base.chatId)) != nil else { throw StoreError(message: "这段对话已经不在了") }
            let name = bare(clean(shop))
            guard !name.isEmpty else { throw StoreError(message: "请填写店名") }
            if cardsOf(base.chatId).contains(where: { $0.shop == name }) { throw StoreError(message: "已经有「\(name)」的会员卡") }
            let n = clean(note)
            var m = base
            m.row["kind"] = .string("member")
            m.row["status"] = .string("done")
            m.row["member"] = .object(["shop": .string(name), "note": .string(n)])
            m.row["content"] = .string("[开会员卡：\([name, n].filter { !$0.isEmpty }.joined(separator: "｜"))]")
            return m
        }

        /// 去了一次。points 是这一次攒的分
        static func visit(_ id: String, role: Message.Role, authorId: String = "", points: Double = 0, note: String = "", turnId: String? = nil) throws -> Message {
            guard let s = state(id) else { throw StoreError(message: "这张会员卡已经不在了") }
            let chat = (try? Repo.chat(s.chatId)) ?? nil
            let n = max(0, Int((points.isFinite ? points : 0).rounded()))
            let t = clean(note)
            var m = Message.new(chatId: s.chatId, role: role, authorId: authorOf(chat, role, authorId),
                                content: "[会员卡消费：\([s.shop, n > 0 ? "\(n) 分" : "", t].filter { !$0.isEmpty }.joined(separator: "｜"))]",
                                kind: "member-act", turnId: turnId)
            m.row["memberMsgId"] = .string(s.id)
            m.row["memberShop"] = .string(s.shop)
            m.row["points"] = .number(Double(n))
            m.row["note"] = .string(t)
            return m
        }

        static func facts(_ chatId: String) -> [String] { cardsOf(chatId).map { "「\($0.shop)」 \($0.visits) visits, \($0.points) points" } }
    }

    // MARK: - 证件（idcard.js）：工牌、学生证。存在人身上（characters.idCard、personas.idCard），不进提示词

    enum IdCard {
        struct Kind { let id: String; let label: String; let eyebrow: String; let orgLabel: String; let titleLabel: String }
        static let kinds = [
            Kind(id: "work", label: "工牌", eyebrow: "STAFF", orgLabel: "单位", titleLabel: "职位"),
            Kind(id: "student", label: "学生证", eyebrow: "STUDENT", orgLabel: "学校", titleLabel: "专业与年级"),
            Kind(id: "other", label: "证件", eyebrow: "ID", orgLabel: "发证单位", titleLabel: "身份"),
        ]
        static func kindOf(_ id: String) -> Kind { kinds.first { $0.id == id } ?? kinds[0] }

        struct Card: Equatable {
            var kind = "work", org = "", title = "", no = "", dept = ""
            var json: JSONValue { .object(["kind": .string(kind), "org": .string(org), "title": .string(title), "no": .string(no), "dept": .string(dept)]) }
        }

        static func clean(_ raw: JSONValue?) -> Card? {
            guard let o = raw?.object else { return nil }
            func s(_ k: String) -> String {
                let v = o[k]
                let t = v?.string ?? v?.number.map { $0 == $0.rounded() ? String(Int64($0)) : String($0) } ?? ""
                return WalletCards.clean(t)
            }
            let c = Card(kind: kindOf(o["kind"]?.string ?? "").id, org: s("org"), title: s("title"), no: s("no"), dept: s("dept"))
            return c.org.isEmpty && c.title.isEmpty && c.no.isEmpty && c.dept.isEmpty ? nil : c
        }

        static func of(_ id: String, me: Bool = false) -> Card? {
            let row = (try? Database.shared.get(me ? Collections.personas : Collections.characters, id: id)) ?? nil
            return clean(row?["idCard"])
        }

        /// 存一张（nil 是删掉）。只改 idCard 这一项
        static func set(_ id: String, _ card: Card?, me: Bool = false) throws {
            let coll = me ? Collections.personas : Collections.characters
            guard var row = try Database.shared.get(coll, id: id) else { throw StoreError(message: "找不到这个人") }
            row["idCard"] = card.flatMap { clean($0.json) }?.json ?? .null
            row.touch()
            try Database.shared.put(coll, row)
            Ledger.changed()
        }
    }
}
