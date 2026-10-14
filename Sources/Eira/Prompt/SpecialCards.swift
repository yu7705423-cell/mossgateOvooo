import Foundation

/// 原生版还没有对应 app 的那几十种消息（约定、信、申请、出行、衣帽间、商城、纸条、论坛、梦境……）在聊天里画成一张卡：
/// 一个图标、一行标题、一两行要点、底下一行状态。字段照网页版各 *Bits.js 与 msgpreview.js 读，只读不改。
/// 从前它们走 default，把方括号协议原文居中显示成一行灰字（对照报告第一条）。
///
/// 这些消息来自导入的网页版记录：原生版的回复解析认得这些标记，但还没有对应功能，不会自己落出这几种消息。
enum SpecialCards {
    /// 画成卡片的那几种
    static let kinds: Set<String> = ["pact", "letter", "request", "trip", "xhs", "watch", "read", "excerpt", "tool", "award", "acquire",
        "outfit", "closetshare", "dresscode", "groom", "slip", "mallitem", "mallshot", "dreamcard", "quiz", "quizask", "game",
        "forumpost", "boxslip", "boxreveal", "boxdraw", "moshare", "file", "card", "listen"]

    struct Face: Equatable {
        var icon: String
        var title: String
        var detail = ""
        var foot = ""
        /// 点开看全文（信、文件、HTML 卡片之类）
        var body = ""
    }

    /// 线上与线下的分界线（网页版 FaceBits 的 SideLine）
    static func sideLabel(_ m: Message) -> String? {
        guard m.kind == "side" else { return nil }
        guard m.row.string("side") == "face" else { return "回到线上" }
        let info = m.row["face"]?.object ?? [:]
        let t = [info["place"]?.string ?? "", info["at"]?.string ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " · ")
        return t.isEmpty ? "线下" : "线下 · \(t)"
    }

    private static func md(_ ms: Double) -> String {
        let d = Date(millis: ms)
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0) 月 \(c.day ?? 0) 日"
    }

    private static func money(_ m: Message) -> String {
        guard let n = m.row.number("amount") else { return "" }
        return Interact.display(n, m.row["currency"]?.string)
    }

    /// 方括号协议原文去掉外层括号与标签，留下要点
    static func stripped(_ content: String) -> String {
        var t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("["), let close = t.firstIndex(of: "]"), close == t.index(before: t.endIndex) {
            t = String(t.dropFirst().dropLast())
            if let colon = t.firstIndex(where: { $0 == "：" || $0 == ":" }) { t = String(t[t.index(after: colon)...]) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func face(_ m: Message, now: Date = Date()) -> Face? {
        let r = m.row
        let snap = { (key: String) -> [String: JSONValue] in r[key]?.object ?? [:] }
        let s = { (o: [String: JSONValue], k: String) -> String in o[k]?.string ?? "" }
        switch m.kind {
        case "pact":
            let done = r.string("pact") == "done"
            return Face(icon: done ? "checkmark.seal" : "bookmark", title: r.string("title").isEmpty ? stripped(m.content) : r.string("title"),
                        foot: done ? "约定已完成" : "约定")
        case "letter":
            let openAt = r.number("openAt") ?? 0
            let sealed = openAt > now.millis
            let closed = sealed && m.role != .user
            var body = closed ? "这封信封着，要到 \(md(openAt))才能拆开。" : r.string("body")
            if !closed, !r.string("bodyTrans").isEmpty {
                body += "\n\n" + [r.string("titleTrans"), r.string("bodyTrans")].filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            return Face(icon: "envelope", title: r.string("title").isEmpty ? "一封信" : r.string("title"),
                        foot: sealed ? "\(md(openAt))可拆" : "点击展开", body: body)
        case "request":
            let k = r.string("requestKind")
            let v = money(m)
            let title = k == "joint" ? "开设情侣账户" : k == "card" ? "亲属卡　额度 \(v)" : k == "deposit" ? "存入情侣账户　\(v)" : "动用情侣账户　\(v)"
            let st = r.string("request")
            let foot = k == "deposit" ? "已存入" : st == "approved" ? "已通过" : st == "rejected" ? "已驳回" : "待处理"
            return Face(icon: k == "card" ? "creditcard" : k == "deposit" ? "wallet.pass" : "person.2", title: title,
                        detail: (k == "spend" || k == "deposit") ? r.string("note") : "", foot: foot)
        case "trip":
            let t = r["trip"]?.object ?? [:]
            let where_ = r.string("where").isEmpty ? s(t, "where") : r.string("where")
            return Face(icon: "airplane", title: where_.isEmpty ? "出行" : where_, detail: r.string("when"), foot: "出行")
        case "xhs":
            let x = snap("xhs")
            let site = r.string("xhsSite")
            let name = site == "x" ? "X" : site == "weibo" ? "微博" : "小红书"
            let title = s(x, "title").isEmpty ? (s(x, "author").isEmpty ? name : s(x, "author")) : s(x, "title")
            return Face(icon: "link", title: title, detail: s(x, "desc"),
                        foot: r.string("xhsState") == "error" ? "\(name) · 无法读取" : name, body: r.string("xhsUrl"))
        case "watch", "read":
            let lines = m.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let first = (lines.first ?? "").replacingOccurrences(of: #"^\[|\]$"#, with: "", options: .regularExpression)
            return Face(icon: m.kind == "watch" ? "film" : "book", title: first, detail: lines.count > 1 ? lines[1] : "")
        case "excerpt":
            return Face(icon: "text.quote", title: "摘自《\(r.string("bookTitle").isEmpty ? "一本书" : r.string("bookTitle"))》"
                        + (r.string("bookAuthor").isEmpty ? "" : " · \(r.string("bookAuthor"))"),
                        detail: r.string("quote"), foot: r.string("note"))
        case "tool":
            let state = r.string("toolState")
            return Face(icon: "wrench.and.screwdriver", title: r.string("toolTitle").isEmpty ? r.string("toolName") : r.string("toolTitle"),
                        detail: r.string("toolError").isEmpty ? "" : "失败：\(r.string("toolError"))",
                        foot: state == "pending" ? "等待允许" : "工具调用", body: r["toolResult"]?.string ?? "")
        case "award":
            return Face(icon: "rosette", title: r.string("awardName").isEmpty ? "互动标识" : r.string("awardName"),
                        detail: r.string("awardReason"), foot: "颁发了互动标识")
        case "acquire":
            let a = snap("acquire")
            return Face(icon: "shippingbox", title: s(a, "name").isEmpty ? stripped(m.content) : s(a, "name"),
                        detail: a["price"].map { $0.string ?? ($0.number.map { String(format: "%.0f", $0) } ?? "") } ?? "", foot: "入手")
        case "outfit":
            if r.bool("sealed") && !r.bool("revealed") { return Face(icon: "gift", title: "穿搭盲盒", foot: "揭晓前只显示主题") }
            let items = (r["outfitItems"]?.array ?? []).compactMap { $0["name"]?.string ?? $0.string }
            return Face(icon: "tshirt", title: r.string("outfitName").isEmpty ? "搭配" : r.string("outfitName"),
                        detail: items.joined(separator: "、"), foot: "搭配")
        case "closetshare":
            return Face(icon: "tshirt", title: r.string("itemName").isEmpty ? "衣帽间" : r.string("itemName"),
                        detail: r.string("shareNote"), foot: "衣帽间")
        case "dresscode":
            return Face(icon: "gift", title: "穿搭盲盒", detail: r.string("theme"), foot: "穿搭盲盒")
        case "groom", "slip":
            let opened = r.bool("slipOpened")
            return Face(icon: "bag", title: opened ? "包里的东西" : "包里多了一样东西", detail: opened ? r.string("slipWhat") : "", foot: "")
        case "mallitem", "mallshot":
            let x = snap("mallSnap")
            return Face(icon: "cart", title: m.kind == "mallshot" ? "闲置截图" : (s(x, "title").isEmpty ? "商品" : s(x, "title")),
                        detail: x["price"].map { $0.string ?? ($0.number.map { "¥\(String(format: "%.2f", $0))" } ?? "") } ?? "", foot: "商城")
        case "dreamcard":
            let x = snap("dreamSnap")
            return Face(icon: "moon.stars", title: s(x, "title").isEmpty ? "梦境" : s(x, "title"), detail: s(x, "text"), foot: "梦境",
                        body: s(x, "text"))
        case "quiz", "quizask":
            let x = snap("quizSnap")
            return Face(icon: "checklist", title: s(x, "title").isEmpty ? "测试" : s(x, "title"),
                        foot: m.kind == "quiz" ? "测试结果" : "邀请作答")
        case "game":
            let x = snap("gameSnap")
            return Face(icon: "gamecontroller", title: s(x, "name").isEmpty ? "桌游" : s(x, "name"), foot: "桌游")
        case "forumpost":
            let x = snap("forumSnap")
            return Face(icon: "text.bubble", title: s(x, "title").isEmpty ? "论坛帖子" : s(x, "title"), detail: s(x, "body"),
                        foot: "论坛", body: s(x, "body"))
        case "boxslip", "boxreveal", "boxdraw":
            let x = snap("slipSnap")
            let title = m.kind == "boxreveal" ? "同时揭晓" : m.kind == "boxdraw" ? "纸条抽签" : "纸条"
            return Face(icon: "doc.plaintext", title: title, detail: s(x, "text"), foot: s(x, "mood"))
        case "moshare":
            let x = snap("share")
            return Face(icon: "photo.on.rectangle", title: s(x, "who").isEmpty ? "动态" : "\(s(x, "who")) 的动态", detail: s(x, "text"), foot: "朋友圈")
        case "file":
            let size = r.number("size").map { $0 >= 1_048_576 ? String(format: "%.1f MB", $0 / 1_048_576) : String(format: "%.0f KB", max(1, $0 / 1024)) } ?? ""
            return Face(icon: "doc", title: r.string("name").isEmpty ? "文件" : r.string("name"),
                        detail: [r.string("ext").uppercased(), size].filter { !$0.isEmpty }.joined(separator: " · "),
                        foot: "文件", body: r.string("text"))
        case "card":
            let c = snap("card")
            let vals = (c["values"]?.object ?? [:]).compactMap { k, v in v.string.map { "\(k)：\($0)" } }.sorted()
            return Face(icon: "rectangle.on.rectangle", title: s(c, "name").isEmpty ? "卡片" : s(c, "name"),
                        detail: vals.prefix(3).joined(separator: "\n"), foot: "卡片", body: vals.joined(separator: "\n"))
        case "listen":
            let secs = Int(r.number("seconds") ?? 0)
            return Face(icon: "headphones", title: "一起听", detail: secs > 0 ? (secs >= 60 ? "\(secs / 60) 分钟" : "\(secs) 秒") : "", foot: "一起听")
        default:
            return nil
        }
    }
}

/// 一条消息在会话列表里露出来的那一行（网页版 msgpreview.js，4.523）：不露方括号协议原文
enum MsgPreview {
    static func text(_ m: Message) -> String {
        if m.isRecalled { return "撤回了一条消息" }
        if m.isError { return "回复失败" }
        let r = m.row
        func with(_ tag: String, _ v: String) -> String { v.isEmpty ? "[\(tag)]" : "[\(tag)] \(v)" }
        switch m.kind {
        case Forward.kind: return "[聊天记录]"
        case "sticker": return "[表情]"
        case "image": return "[图片]"
        case "voice": return "[语音]"
        case "clip": return "[视频]"
        case "silence": return r.bool("reacted") ? "已读，仅回应" : "已读，未回复"
        case "transfer": return with("转账", r.number("amount").map { Interact.display($0, r["currency"]?.string) } ?? "")
        case "location": return with("位置", r.string("place"))
        case "gift": return with("礼物", r.string("cover"))
        case "takeout": return with("外卖", r.string("item"))
        case "dice": return with("骰子", r.number("value").map { String(Int($0)) } ?? "")
        case "narration": return with("旁白", r.string("narration").isEmpty ? SpecialCards.stripped(m.content) : r.string("narration"))
        case "notice": return m.content.replacingOccurrences(of: #"^\[|\]$"#, with: "", options: .regularExpression)
        case "side": return SpecialCards.sideLabel(m) ?? ""
        default:
            if let f = SpecialCards.face(m) { return with(f.foot.isEmpty ? "消息" : f.foot, f.title) }
            // 一条回复里可能有多段，用空行分隔：列表里显示最后一段
            let parts = m.content.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return parts.last ?? m.content
        }
    }
}
