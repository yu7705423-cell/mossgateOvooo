import Foundation

/// 把模型的一次回复切成若干条消息。照网页版 `src/system/ai/reply.js` 的 splitReply 与 pushText，正则一字不改（是协议）。
///
/// 原生版第一版只落成这几种：文字、图片、视频、语音、表情、位置、旁白、骰子、不回复，以及挂在文字上的心声、译文、引用、撤回。
/// 网页版认得、原生版还没有对应功能的标记（转账、礼物、歌单、约定……）照网页版对「认得但用不了」的处理：
/// 认出来、吞掉，不落成消息，也不留成文字。提示词里不告诉模型这些能力，正常不会出现。
/// 不在标记表里的方括号（`[发呆]`）原样当文字。
enum ReplyParser {
    enum PartType: String, Sendable {
        case text, image, clip, voice, sticker, location, narration, dice, silence
        // 互动（网页版 reply.js）：转账、礼物各自发出与处理；拍一拍、回应、改备注
        case transfer, gift, settle, unwrap, pat, react, remark, takeout, meal
        // 日常：角色勾掉今天的一条事项（flag 为真是完成，假是取消）
        case agenda
        // 音乐：一起听（整行 [一起听]）、点歌、分享歌曲、建歌单 / 加入歌单（extra 是用 ；隔开的几首）
        case listen, pick, song, newlist
        // 群里单独发给你的一句（落进私聊）；撤回自己最近一条动态
        case dm, recallPost
        // 好友与拉黑：角色改自己这一方对某人的状态（extra 是 block / unblock / remove / add / accept，text 是名字）
        case tie
        // 情侣空间：约定、约定完成（text 是那件事）、信（extra 是信封上的标题）
        case pact, pactDone, letter
        // 角色手机：存图（text 是角色给这张写的一句）、改密码（text 是数字，extra 是这串数字是什么）
        case keep, lockcode
        // 角色打电话过来（flag 为真是视频，原生版先按语音接）
        case ring
        // 草稿箱：写了又没发出去的话（不落进聊天）
        case draft
        // HTML 卡片：text 是卡片名，extra 是「字段：值」那一段
        case card
    }

    struct Part: Equatable, Sendable {
        var type: PartType
        var text: String
        var translation: String?
        var inner: String?
        var innerTrans: String?
        var quote: String?
        var recall = false
        /// 位置的地址
        var address: String?
        /// 转账的金额
        var amount: Double?
        /// 礼物里面装的；回应的摘录
        var extra: String?
        /// 收款 / 拆开为 true，退回 / 拒收为 false
        var flag = false
    }

    struct Result: Sendable {
        var parts: [Part]
        var think: String
        var stamp: String?
    }

    // MARK: - 正则（网页版原文）

    static let markPattern = #"[\[【]\s*(图片|照片|image|pic|视频|video|语音|voice|audio|表情|sticker|emoji|转账|transfer|位置|定位|location|礼物|gift|点歌|建歌单|加入歌单|分享歌曲|分享音乐|调用|tool|约定完成|约定|pact|信|letter|事项完成|事项取消|心声|换头像|改备注|备注|外卖|请客|代付|申请|亲属卡|存入情侣账户|存入共同账户|旅行|攻略|待办|todo|授予|award|搭配|outfit|换上|借走|借给你|归还|旁白|narration|改密码|卡片|card|文件|file|填写|fill|私信|解除禁言|禁言|改群昵称|心愿达成|私下心愿|心愿|梦境|出题|草稿|开小号|承认小号|解除拉黑|拉黑|删除好友|添加好友|通过好友申请|认出|借号发短信|发短信|入手|点赞|评论|转发帖子|转发|分享商品|想要|出价|下单|挂出|已发货|识破|闲置截图|写纸条|不抽纸条|抽纸条|打开纸条|放回纸条|不回答|完成纸条|转交纸条|给你看纸条|回应纸条|记下回答|封存答案|私人纸条盒)\s*[:：]\s*([^\]】]+)[\]】]"#

    private static let mark = regex(markPattern, [.caseInsensitive])
    private static let voiceTrans = regex(#"\s*[\[【(（]?\s*(?:译文|翻译|译|translation)\s*[:：]"#, [.caseInsensitive])
    private static let sameLineTrans = regex(#"^(.*?\S)\s*[\[【]\s*(?:译文|翻译|译|translation)\s*[:：]\s*([^\]】]*?)\s*[\]】]\s*$"#, [.caseInsensitive])
    private static let sameLineParen = regex(#"^(.*?\S)\s*[(（]\s*(?:译文|翻译|译|translation)\s*[:：]\s*([^)）]*?)\s*[)）]\s*$"#, [.caseInsensitive])
    private static let transHead = regex(#"^(?:\d+\s*[.、)）]\s*)?([\[【(（]?)\s*(?:译文|翻译|译|translation)\s*([:：]?)\s*([\s\S]*)$"#, [.caseInsensitive])
    private static let innerLine = regex(#"^[\[【(（]?\s*(?:心声|内心|inner)\s*[:：]\s*(.+?)[\]】)）]?\s*$"#, [.caseInsensitive])
    private static let quoteOpen = regex(#"^(?:\d+\s*[.、)）]\s*)?([\[【(（])\s*(?:引用|回复|quote|reply(?:ing)?(?:\s+to)?|in\s+reply\s+to)\s*[:：]\s*(.+?)\s*[\]】)）]\s*(.*)$"#, [.caseInsensitive])

    private static func lineMark(_ words: String) -> NSRegularExpression {
        regex(#"^(?:\d+\s*[.、)）]\s*)?[\[【(（]\s*(?:"# + words + #")\s*(?:[:：][^\]】)）]*)?\s*[\]】)）]\s*[。．.!！~～]?$"#, [.caseInsensitive])
    }
    private static let recallLine = lineMark("撤回|撤回消息|撤回上一条")
    // 「撤回动态」要先认：两个都以「撤回」开头
    private static let recallPostLine = lineMark("撤回动态|删除动态")
    // 原生版还没有的那几件事（来电、一起看、出行、情侣账户、群管理、千丝万缕）：标记认出来就不落气泡，
    // 从前原样变成一条文字（网页版 reply.js 里各自是一件事，不占气泡）
    // 「来电」是用户那边收到的结果。两个词都认，免得模型偶尔写回旧的那个
    static let ringLine = lineMark("(视频)?(?:去电|来电|打电话|拨打|通话|call)")
    private static let unsupportedLines: [NSRegularExpression] = [
        regex(#"^[\[【(（]\s*(?:暂停|暂停一下)\s*[\]】)）]$"#, []),
        regex(#"^[\[【(（]\s*(?:继续|继续播放|接着看)\s*[\]】)）]$"#, []),
        regex(#"^[\[【(（]\s*(?:倒回|回到|快进)\s*[:：]\s*([\d:：.]+)\s*[\]】)）]$"#, []),
        regex(#"^[\[【(（]\s*(?:同行|一起去|去)\s*[\]】)）]$"#, []),
        regex(#"^[\[【(（]\s*(?:不去|去不了|算了)\s*[\]】)）]$"#, []),
        lineMark("开设情侣账户|开情侣账户|开通情侣账户|开通共同账户|开共同账户"),
        lineMark("批准|同意|通过"),
        lineMark("驳回|拒绝|不同意"),
        lineMark("全员禁言|开启全员禁言"),
        lineMark("解除全员禁言|关闭全员禁言"),
        lineMark("不覆盖"),
        lineMark("覆盖"),
    ]
    private static let keepLine = regex(#"^[\[【(（]?\s*(?:存图|存照片)\s*[:：]\s*(.+?)[\]】)）]?\s*$"#, [.caseInsensitive])
    private static let silenceLine = lineMark("不回复|已读不回|不回")
    private static let diceLine = lineMark("骰子|掷骰子|扔骰子|dice")
    private static let patLine = lineMark("拍一拍|拍拍|戳一戳")
    // 收下或退回对方那一笔、拆开或拒收礼物。必须带方括号，整行只能是它
    private static let listenLine = regex(#"^[\[【(（]\s*(一起听|一起听歌|听歌)\s*[\]】)）]$"#, [])
    private static let settleLine = regex(#"^[\[【(（]\s*(收款|收下|接收|退回|退还)\s*[\]】)）]$"#, [])
    private static let openLine = regex(#"^[\[【(（]\s*(拆开|拆|打开|拆礼物)\s*[\]】)）]$"#, [])
    // 处理对方点的那一单。和收款、拆礼物各用一套词，不能用「收下」（那个归转账）
    private static let takeLine = regex(#"^[\[【(（]\s*(?:要了|吃了|签收)\s*[\]】)）]$"#, [])
    private static let nopeLine = regex(#"^[\[【(（]\s*(?:不要|不用了|不吃)\s*[\]】)）]$"#, [])
    private static let refuseLine = regex(#"^[\[【(（]\s*(拒收|不收|退掉)\s*[\]】)）]$"#, [])
    private static let reactLine = regex(#"^[\[【]\s*(?:回应|反应|react(?:ion)?)\s*[:：]\s*([^\]】]+?)\s*[\]】]\s*[。．.!！~～]?$"#, [.caseInsensitive])
    /// 转账：金额在前，后面是留言
    private static let amountRe = regex(#"^\s*(?:[¥￥$]\s*)?(\d+(?:\.\d{1,2})?)\s*(?:元|块)?\s*(.*)$"#, [])

    // 时间戳（网页版 stripStamps）
    private static let stampLabelled = regex(#"[\[【(（]\s*(?:时间|時間|time)\s*[:：][^\n\]】)）]{0,40}[\]】)）]"#, [.caseInsensitive])
    private static let stampBare = regex(#"[\[【]\s*([^\n\]】]{1,40}?)\s*[\]】]"#, [])
    private static let timeish = regex(#"^[\d\s:：\-/.年月日时分秒時曜周一二三四五六天上下午前後aApPmM]+$"#, [])

    // <think> 段（网页版 think.js）
    private static let thinkPair = regex(#"<\s*(thinking|think|thought)\s*>([\s\S]*?)<\s*/\s*\1\s*>"#, [.caseInsensitive])
    private static let thinkClose = regex(#"<\s*/\s*(?:thinking|think|thought)\s*>"#, [.caseInsensitive])
    private static let thinkOpen = regex(#"<\s*(?:thinking|think|thought)\s*>([\s\S]*)$"#, [.caseInsensitive])

    // MARK: - 入口

    /// autoSplitAt：整轮只有一条很长的纯文字时按句子再切的字数（网页版 settings.autoSplitAt，默认 40，0 为不切）
    static func split(_ raw: String, autoSplitAt: Int = 40) -> Result {
        let (body, think) = stripThink(raw)
        let (stamped, stamp) = stripStamps(MarkFold.foldMedia(MarkFold.fold(body.trimmingCharacters(in: .whitespacesAndNewlines))))
        let (text, cards) = liftCards(stamped)
        var state = State()
        state.cards = cards

        let ns = text as NSString
        var last = 0
        for m in mark.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            state.pushText(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            let kind = ns.substring(with: m.range(at: 1)).lowercased()
            let body = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            last = m.range.location + m.range.length
            if !body.isEmpty { state.handleMark(kind, body) }
        }
        state.pushText(ns.substring(from: last))
        // 引用、心声、译文后面再没有正文的，网页版同样丢掉

        var parts = state.parts
        // 整轮只有一条不带引用的文字，且长于 autoSplitAt：按句子再切（网页版 autoSplit）
        if autoSplitAt > 0, parts.count == 1, parts[0].type == .text, parts[0].quote == nil {
            let pieces = autoSplit(parts[0].text, limit: autoSplitAt)
            if pieces.count > 1 {
                var first = parts[0]
                first.text = pieces[0]
                parts = [first] + pieces.dropFirst().map { Part(type: .text, text: $0) }
            }
        }
        return Result(parts: parts, think: think, stamp: stamp)
    }

    // MARK: - HTML 卡片（网页版 liftCards，ARCHITECTURE 4.250）

    // 角色写的是一整段：[卡片：名字]、几行「字段：值」、[/卡片]。逐行分条会把它拆成好几个气泡，
    // 所以先整段摘出来，原位换成 [卡片：#序号]。漏写收尾的：往下只收像字段的几行，碰到别的就停
    private static let cardHead = regex(#"[\[【]\s*(?:卡片|card)\s*[:：]\s*([^\]】\n#][^\]】\n]*?)\s*[\]】]"#, [.caseInsensitive])
    private static let cardEnd = regex(#"[\[【]\s*/\s*(?:卡片|card)\s*[\]】]"#, [.caseInsensitive])
    private static let fieldLine = regex(#"^[^：:\n\[【]{1,24}[：:]"#, [])

    static func liftCards(_ text: String) -> (String, [(name: String, body: String)]) {
        let ns = text as NSString
        var cards: [(name: String, body: String)] = []
        var out = ""
        var last = 0
        var from = 0
        while from < ns.length, let m = cardHead.firstMatch(in: text, range: NSRange(location: from, length: ns.length - from)) {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let start = m.range.location + m.range.length
            let restRange = NSRange(location: start, length: ns.length - start)
            var body: String
            var stop: Int
            if let e = cardEnd.firstMatch(in: text, range: restRange) {
                body = ns.substring(with: NSRange(location: start, length: e.range.location - start))
                stop = e.range.location + e.range.length
            } else {
                let lines = ns.substring(with: restRange).components(separatedBy: "\n")
                var kept: [String] = []
                var used = (lines[0] as NSString).length + 1
                if !lines[0].trimmingCharacters(in: .whitespaces).isEmpty { kept.append(lines[0]) }
                for l in lines.dropFirst() {
                    let t = l.trimmingCharacters(in: .whitespaces)
                    guard fieldLine.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil else { break }
                    kept.append(l)
                    used += (l as NSString).length + 1
                }
                body = kept.joined(separator: "\n")
                stop = min(ns.length, start + used)
            }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + "\n[卡片：#\(cards.count)]\n"
            while body.hasPrefix("\n") { body.removeFirst() }
            while body.hasSuffix("\n") { body.removeLast() }
            cards.append((name, body))
            last = stop
            from = max(stop, m.range.location + 1)
        }
        return (out + ns.substring(from: last), cards)
    }

    // MARK: - 逐段

    private struct State {
        var parts: [Part] = []
        var cards: [(name: String, body: String)] = []
        var pendingQuote: String?
        var pendingInner: (String, String?)?
        var pendingTrans: String?
        var transNext = false

        mutating func push(_ p: Part) {
            var p = p
            if let q = pendingQuote { p.quote = q; pendingQuote = nil }
            if p.type == .text || p.type == .voice, let t = pendingTrans, p.translation == nil {
                p.translation = t; pendingTrans = nil
            }
            if p.type == .text, let pi = pendingInner {
                p.inner = pi.0; p.innerTrans = pi.1; pendingInner = nil
            }
            parts.append(p)
        }

        mutating func handleMark(_ kind: String, _ body: String) {
            switch kind {
            case "图片", "照片", "image", "pic":
                push(Part(type: .image, text: body))
            case "视频", "video":
                push(Part(type: .clip, text: body))
            case "语音", "voice", "audio":
                let (t, tr) = ReplyParser.splitVoiceText(body)
                push(Part(type: .voice, text: t, translation: tr))
            case "表情", "sticker", "emoji":
                push(Part(type: .sticker, text: body))
            case "位置", "定位", "location":
                let pieces = body.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).map(String.init)
                push(Part(type: .location, text: pieces.first ?? body, address: pieces.count > 1 ? pieces[1] : nil))
            case "旁白", "narration":
                let (t, tr) = ReplyParser.splitVoiceText(body)
                push(Part(type: .narration, text: t, translation: tr))
            case "心声":
                let (t, tr) = ReplyParser.splitVoiceText(body)
                attachInner(t, tr)
            case "私信":
                push(Part(type: .dm, text: body))
            case "转账", "transfer":
                // 金额读不出来就整条丢掉。凭空造一笔金额不明的转账比少发一条更糟
                if let m = ReplyParser.match(ReplyParser.amountRe, body), let a = Double(m[1]) {
                    var p = Part(type: .transfer, text: m[2].trimmingCharacters(in: .whitespaces))
                    p.amount = a
                    push(p)
                }
            case "礼物", "gift":
                if let g = Interact.parseGift(body) {
                    var p = Part(type: .gift, text: g.cover)
                    p.extra = g.inner
                    push(p)
                }
            case "外卖", "请客", "代付":
                // 吃什么读不出来就整条丢掉
                if let o = Interact.parseTakeout(body), !o.item.isEmpty {
                    var p = Part(type: .takeout, text: o.item)
                    p.amount = o.amount
                    p.extra = kind == "请客" ? "treat" : kind == "代付" ? "ask" : "self"
                    push(p)
                }
            case "备注", "改备注":
                push(Part(type: .remark, text: body))
            case "点歌":
                push(Part(type: .pick, text: body.trimmingCharacters(in: .whitespaces)))
            case "分享歌曲", "分享音乐":
                push(Part(type: .song, text: body.trimmingCharacters(in: .whitespaces)))
            case "建歌单", "加入歌单":
                let bar = body.firstIndex { $0 == "|" || $0 == "｜" }
                let name = (bar.map { String(body[..<$0]) } ?? body).trimmingCharacters(in: .whitespaces)
                let songs = (bar.map { String(body[body.index(after: $0)...]) } ?? "").trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && (kind == "建歌单" || !songs.trimmingCharacters(in: .whitespaces).isEmpty) {
                    var p = Part(type: .newlist, text: name)
                    p.extra = songs
                    push(p)
                }
            case "拉黑", "解除拉黑", "删除好友", "添加好友", "通过好友申请":
                var p = Part(type: .tie, text: body.trimmingCharacters(in: .whitespaces))
                p.extra = Ties.kinds[kind] ?? ""
                push(p)
            case "约定", "pact":
                let t = body.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { push(Part(type: .pact, text: t)) }
            case "约定完成":
                push(Part(type: .pactDone, text: body.trimmingCharacters(in: .whitespaces)))
            case "信", "letter":
                // 竖线前是信封上写的标题，后面是正文；不写竖线整段都是正文
                let bar = body.firstIndex { $0 == "|" || $0 == "｜" }
                let title = (bar.map { String(body[..<$0]) } ?? "").trimmingCharacters(in: .whitespaces)
                let text = (bar.map { String(body[body.index(after: $0)...]) } ?? body).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    var p = Part(type: .letter, text: text)
                    p.extra = title
                    push(p)
                }
            case "改密码":
                let bar = body.firstIndex { $0 == "|" || $0 == "｜" }
                var p = Part(type: .lockcode, text: (bar.map { String(body[..<$0]) } ?? body).trimmingCharacters(in: .whitespaces))
                p.extra = (bar.map { String(body[body.index(after: $0)...]) } ?? "").trimmingCharacters(in: .whitespaces)
                push(p)
            case "卡片", "card":
                if body.hasPrefix("#"), let i = Int(body.dropFirst()), cards.indices.contains(i) {
                    var p = Part(type: .card, text: cards[i].name)
                    p.extra = cards[i].body
                    push(p)
                }
            case "草稿":
                let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { push(Part(type: .draft, text: t)) }
            case "事项完成", "事项取消":
                var p = Part(type: .agenda, text: body.trimmingCharacters(in: .whitespaces))
                p.flag = kind == "事项完成"
                push(p)
            default:
                break   // 认得但原生版还没有对应功能：吞掉
            }
        }

        mutating func attachInner(_ inner: String, _ trans: String?) {
            if let i = parts.lastIndex(where: { $0.type == .text }) {
                parts[i].inner = String(inner.prefix(300))
                parts[i].innerTrans = trans.map { String($0.prefix(600)) }
            } else {
                pendingInner = (String(inner.prefix(300)), trans)
            }
        }

        /// 译文只挂到紧挨着的上一条：文字（不是单独一个方括号标记）或语音，且还没有译文。
        mutating func attachTrans(_ t: String) {
            guard let i = parts.indices.last else { pendingTrans = t; return }
            let p = parts[i]
            let bare = p.text.range(of: #"^[\[【][^\]】]*[\]】]$"#, options: .regularExpression) != nil
            if (p.type == .text && !bare || p.type == .voice) && p.translation == nil {
                parts[i].translation = t
            }
        }

        mutating func pushText(_ chunk: String) {
            for seg in chunk.components(separatedBy: .newlines) {
                let t = seg.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                pushLine(t)
            }
        }

        mutating func pushLine(_ t: String) {
            if transNext { transNext = false; attachTrans(t); return }

            // 同一行带译文
            for re in [ReplyParser.sameLineTrans, ReplyParser.sameLineParen] {
                if let m = ReplyParser.match(re, t), m[1].range(of: #"^\d+\s*[.、)）]?$"#, options: .regularExpression) == nil {
                    var p = Part(type: .text, text: m[1].trimmingCharacters(in: .whitespaces))
                    p.translation = m[2]
                    push(p)
                    return
                }
            }

            // 引用：> 原文，或 [引用：原文] 后面接正文
            if t.hasPrefix("> ") {
                pendingQuote = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                return
            }
            if let m = ReplyParser.match(ReplyParser.quoteOpen, t) {
                pendingQuote = m[2]
                let rest = m[3].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { pushLine(rest) }
                return
            }

            if ReplyParser.matches(ReplyParser.listenLine, t) { push(Part(type: .listen, text: "")); return }
            if let m = ReplyParser.match(ReplyParser.settleLine, t) {
                var p = Part(type: .settle, text: "")
                p.flag = !m[1].contains("退")
                push(p)
                return
            }
            if ReplyParser.matches(ReplyParser.openLine, t) { var p = Part(type: .unwrap, text: ""); p.flag = true; push(p); return }
            if ReplyParser.matches(ReplyParser.refuseLine, t) { push(Part(type: .unwrap, text: "")); return }
            if ReplyParser.matches(ReplyParser.takeLine, t) { var p = Part(type: .meal, text: ""); p.flag = true; push(p); return }
            if ReplyParser.matches(ReplyParser.nopeLine, t) { push(Part(type: .meal, text: "")); return }
            if ReplyParser.matches(ReplyParser.recallPostLine, t) { push(Part(type: .recallPost, text: "")); return }
            if let m = ReplyParser.match(ReplyParser.keepLine, t) {
                push(Part(type: .keep, text: m[1].trimmingCharacters(in: .whitespaces)))
                return
            }
            // 它要打电话过来。不占气泡：电话是一件事，不是一条消息
            if let m = ReplyParser.match(ReplyParser.ringLine, t) {
                var p = Part(type: .ring, text: "")
                p.flag = !m[1].isEmpty
                push(p)
                return
            }
            if ReplyParser.unsupportedLines.contains(where: { ReplyParser.matches($0, t) }) { return }
            if ReplyParser.matches(ReplyParser.silenceLine, t) {
                push(Part(type: .silence, text: ""))
                return
            }
            if let r = ReplyParser.reactOf(t) {
                var p = Part(type: .react, text: r.0)
                p.extra = r.1
                push(p)
                return
            }
            if ReplyParser.matches(ReplyParser.recallLine, t) {
                if !parts.isEmpty { parts[parts.count - 1].recall = true }
                return
            }
            if ReplyParser.matches(ReplyParser.patLine, t) {
                push(Part(type: .pat, text: ""))
                return
            }
            if ReplyParser.matches(ReplyParser.diceLine, t) {
                push(Part(type: .dice, text: ""))
                return
            }
            if let m = ReplyParser.match(ReplyParser.innerLine, t) {
                let (inner, tr) = ReplyParser.splitVoiceText(m[1])
                attachInner(inner, tr)
                return
            }
            // 单独一行的译文：要有括号或冒号；只有「[译文]」就让下一行当译文
            if let m = ReplyParser.match(ReplyParser.transHead, t), !m[1].isEmpty || !m[2].isEmpty {
                var body = m[3].trimmingCharacters(in: .whitespaces)
                if !m[1].isEmpty, let close = body.last, "]】)）".contains(close) { body.removeLast() }
                body = body.trimmingCharacters(in: .whitespaces)
                if body.isEmpty { transNext = true } else { attachTrans(body) }
                return
            }
            push(Part(type: .text, text: t))
        }
    }

    // MARK: - 小工具

    /// [回应：emoji：摘录]。emoji 与摘录之间是冒号；没写冒号按第一个空白分（网页版 reactOf）。
    static func reactOf(_ line: String) -> (String, String?)? {
        guard let m = match(reactLine, line) else { return nil }
        let inner = m[1].trimmingCharacters(in: .whitespaces)
        let cut = inner.firstIndex { $0 == ":" || $0 == "：" } ?? inner.firstIndex { $0.isWhitespace }
        let e = (cut.map { String(inner[..<$0]) } ?? inner).trimmingCharacters(in: .whitespaces)
        let q = cut.map { String(inner[inner.index(after: $0)...]).trimmingCharacters(in: .whitespaces) }
        guard Interact.isEmoji(e) else { return nil }
        return (e, q.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// 语音、旁白、心声里的「原文（译文：…）」拆成两半。
    static func splitVoiceText(_ s: String) -> (String, String?) {
        let ns = s as NSString
        guard let m = voiceTrans.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            return (s.trimmingCharacters(in: .whitespaces), nil)
        }
        let text = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
        var tr = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespaces)
        while let c = tr.last, "]】)）".contains(c) { tr.removeLast() }
        tr = tr.trimmingCharacters(in: .whitespaces)
        return (text, tr.isEmpty ? nil : tr)
    }

    static func stripThink(_ raw: String) -> (String, String) {
        var thinks: [String] = []
        var text = raw
        let ns = text as NSString
        for m in thinkPair.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            thinks.append(ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        text = thinkPair.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        // 只剩收尾标签：最后一个收尾标签之前全是思考
        let ns2 = text as NSString
        if let lastClose = thinkClose.matches(in: text, range: NSRange(location: 0, length: ns2.length)).last {
            thinks.append(ns2.substring(to: lastClose.range.location).trimmingCharacters(in: .whitespacesAndNewlines))
            text = ns2.substring(from: lastClose.range.location + lastClose.range.length)
        }
        // 只有开头标签没有收尾：从那里到结尾都丢掉
        let ns3 = text as NSString
        if let open = thinkOpen.firstMatch(in: text, range: NSRange(location: 0, length: ns3.length)) {
            thinks.append(ns3.substring(with: open.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines))
            text = ns3.substring(to: open.range.location)
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), thinks.filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    /// 去掉回复里模型自己写的时间戳，第一个留下来记在第一条上。
    static func stripStamps(_ text: String) -> (String, String?) {
        var first: String?
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            var l = line
            for re in [stampLabelled, stampBare] {
                let ns = l as NSString
                var out = ""
                var last = 0
                for m in re.matches(in: l, range: NSRange(location: 0, length: ns.length)) {
                    let whole = ns.substring(with: m.range)
                    let inner = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound
                        ? ns.substring(with: m.range(at: 1)) : whole
                    let isStamp = re === stampLabelled ? stampBody(String(whole.dropFirst().dropLast()).replacingOccurrences(of: #"^\s*(?:时间|時間|time)\s*[:：]"#, with: "", options: [.regularExpression, .caseInsensitive]))
                        : stampBody(inner)
                    out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                    if isStamp { if first == nil { first = whole } } else { out += whole }
                    last = m.range.location + m.range.length
                }
                out += ns.substring(from: last)
                l = out
            }
            if !l.trimmingCharacters(in: .whitespaces).isEmpty || line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(l)
            }
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), first)
    }

    private static func stampBody(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 40, t.contains(where: \.isNumber), matches(timeish, t) else { return false }
        return t.contains(":") || t.contains("：") || t.range(of: #"\d{4}[-/.]\d"#, options: .regularExpression) != nil
    }

    /// 长段按句末标点切，过长的句子再按逗号顿号分组，不硬切字数（网页版 autoSplit）。
    static func autoSplit(_ text: String, limit: Int) -> [String] {
        guard text.count > limit, !text.contains("["), !text.contains("【") else { return [text] }
        func cut(_ s: String, after marks: String) -> [String] {
            var out: [String] = []
            var cur = ""
            for ch in s {
                cur.append(ch)
                if marks.contains(ch) { out.append(cur); cur = "" }
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        }
        var pieces: [String] = []
        for sentence in cut(text, after: "。！？!?…") {
            if sentence.count <= limit { pieces.append(sentence); continue }
            var group = ""
            for clause in cut(sentence, after: "，,、；;") {
                if !group.isEmpty && group.count + clause.count > limit { pieces.append(group); group = "" }
                group += clause
            }
            if !group.isEmpty { pieces.append(group) }
        }
        return pieces.map { p in
            var t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            while let c = t.last, "。，,、；;".contains(c) { t.removeLast() }
            return t
        }.filter { !$0.isEmpty }
    }

    static func regex(_ p: String, _ o: NSRegularExpression.Options) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// 整个匹配与各组；没匹配上的组是空串。
    static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}
