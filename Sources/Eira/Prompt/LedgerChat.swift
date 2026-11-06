import Foundation

/// 角色在回复里写的情侣账户与卡包那几种标记（网页版 reply.js 的 request、vote、funcard-*、pass-*、ticket-*、member-*）。
/// 落成消息或一行说明，交回 ChatEngine 追加。都搭在本来就要发的那次回复上，不另调接口。
///
/// 能力关着（全局「能力开关」、新功能没开、这段对话没绑账本）时照网页版 gatePlan：写了也不执行。
/// 找不到那张卡、做不了的落一行说明，不凭空造一张（网页版第 22 条）。只在单聊里有。
enum LedgerChat {
    static let types: Set<ReplyParser.PartType> = [.request, .vote, .funGive, .funUse, .funVote, .passGive, .passAct,
                                                   .ticketGive, .ticketCheck, .memberOpen, .memberVisit]

    /// 这一项能力眼下开着吗（网页版 capLive：自己的条件、全局开关、新功能）
    static func live(_ id: String, chat: Chat, char: Character, settings s: AppSettings) -> Bool {
        let off = Set((s.raw["capsOff"]?.array ?? []).compactMap(\.string))
        guard !off.contains(id), NewFeat.capOn(id, s, char: char) else { return false }
        if id == "joint" { return Ledger.bookOfChat(chat.id) != nil }
        return !chat.row.bool("group") && chat.characterIds.count == 1
    }

    static func effect(_ p: ReplyParser.Part, chat: Chat, char: Character, turnId: String) throws -> Message? {
        guard !chat.isGroup else { return nil }
        let s = AppSettings.load()
        let base = Message.new(chatId: chat.id, role: .char, authorId: char.id, content: "", kind: "text", turnId: turnId)
        let info = p.info ?? [:]
        func num(_ k: String) -> Double { Ledger.parse(info[k] ?? "") }
        func say(_ e: Error) -> Message { WalletCards.notice(base, "[\(e.localizedDescription)]") }
        switch p.type {
        case .request:
            guard live("joint", chat: chat, char: char, settings: s) else { return nil }
            return try LedgerRequest.fromChar(base, kind: p.extra ?? LedgerRequest.spend, amount: p.amount ?? 0, note: p.text)
        case .vote:
            // 处理的是你提的那一条
            guard live("joint", chat: chat, char: char, settings: s), let target = try LedgerRequest.pendingFrom(chat.id, role: .user) else { return nil }
            return try LedgerRequest.settle(target.id, ok: p.flag, turnId: turnId)
        case .funGive:
            guard live("funcard", chat: chat, char: char, settings: s) else { return nil }
            return try? WalletCards.Fun.give(base, name: info["name"] ?? p.text, desc: info["desc"] ?? "", uses: num("uses"), days: num("days"),
                                             until: num("until"), confirm: info["confirm"] == "1")
        case .funUse:
            guard live("funcard", chat: chat, char: char, settings: s) else { return nil }
            guard let hit = WalletCards.Fun.findUsable(chat.id, holder: "char", name: p.text) else {
                return WalletCards.notice(base, "[没有可以使用的\(p.text)]")
            }
            return try WalletCards.Fun.use(hit.id, role: .char, authorId: char.id, turnId: turnId)
        case .funVote:
            guard live("funcard", chat: chat, char: char, settings: s), let target = WalletCards.Fun.pendingFrom(chat.id, role: .user) else { return nil }
            return try WalletCards.Fun.settle(target.id, ok: p.flag, turnId: turnId)
        case .passGive:
            guard live("pass", chat: chat, char: char, settings: s) else { return nil }
            return try WalletCards.Pass.give(base, kind: info["kind"] ?? "door", name: info["name"] ?? "", place: info["place"] ?? "", note: info["note"] ?? "")
        case .passAct:
            guard live("pass", chat: chat, char: char, settings: s) else { return nil }
            let act = info["act"] ?? "use", name = info["name"] ?? p.text
            do {
                guard let hit = WalletCards.Pass.find(chat.id, role: "char", name: name, holderSide: act == "use", kind: info["kind"] ?? "") else {
                    throw StoreError(message: act == "use" ? "手里没有「\(name)」这张卡" : "没有发出过「\(name)」这张卡")
                }
                switch act {
                case "revoke": return try WalletCards.Pass.revoke(hit.id, role: .char, authorId: char.id, turnId: turnId)
                case "grant": return try WalletCards.Pass.grant(hit.id, role: .char, authorId: char.id, turnId: turnId)
                default: return try WalletCards.Pass.use(hit.id, role: .char, authorId: char.id, turnId: turnId)
                }
            } catch { return say(error) }
        case .ticketGive, .ticketCheck:
            guard live("ticket", chat: chat, char: char, settings: s) else { return nil }
            do {
                if p.type == .ticketGive {
                    return try WalletCards.Ticket.give(base, title: info["title"] ?? p.text, when: info["when"] ?? "", venue: info["venue"] ?? "", seat: info["seat"] ?? "")
                }
                guard let t = WalletCards.Ticket.findUsable(chat.id, holder: "char", name: p.text) else {
                    throw StoreError(message: "手里没有「\(p.text)」这张能检的票")
                }
                return try WalletCards.Ticket.check(t.id, role: .char, authorId: char.id, turnId: turnId)
            } catch { return say(error) }
        case .memberOpen, .memberVisit:
            guard live("member", chat: chat, char: char, settings: s) else { return nil }
            do {
                if p.type == .memberOpen { return try WalletCards.Member.open(base, shop: info["shop"] ?? p.text, note: info["note"] ?? "") }
                let shop = info["shop"] ?? p.text
                guard let c = WalletCards.Member.find(chat.id, shop: shop) else { throw StoreError(message: "还没有「\(shop)」的会员卡") }
                return try WalletCards.Member.visit(c.id, role: .char, authorId: char.id, points: num("points"), note: info["note"] ?? "", turnId: turnId)
            } catch { return say(error) }
        default:
            return nil
        }
    }
}
