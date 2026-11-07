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
        // 角色打电话过来（flag 为真是视频通话）
        case ring
        // 草稿箱：写了又没发出去的话（不落进聊天）
        case draft
        // HTML 卡片：text 是卡片名，extra 是「字段：值」那一段
        case card
        // 颁发互动标识：text 是标识名，extra 是理由
        case award
        // 群管理：禁言（text 名字，amount 分钟，0 为一直）、解除禁言（text 名字）、全员禁言（flag 开关）、改群昵称（text 名字，空为自己；extra 新昵称）
        case mute, unmute, muteAll, nick
        // 换头像：text 是头像库里那一张的名字
        case wear
        // 待办：角色提出的一件事（text），不占气泡，落成待确认
        case todo
        // 群红包（网页版 4.736）：text 是祝福语，amount 是总额，count 是个数，extra 是种类（luck / equal / only），to 是专属红包给谁
        // 领红包：text 是发的人（空为最近能领的那一个）；退群（4.733）；改网名（4.947）：text 是新网名
        case redpacket, rpclaim, leave, selfnick
        // 截下聊天记录（网页版 4.904）：text 是冒号后面那一段原样（从「原话」开始|说明|私密）；发一张截过的：text 是说明
        case shot, sendshot
        // 小剧场（网页版 4.769）：text 是主题，extra 是梗概，html 是整页（空着是封面，点开时单独生成）
        case theater
        // 调用 MCP 工具（网页版 4.179）：text 是工具名，extra 是参数（JSON 对象的文字），bad 是写坏了的参数原文
        case tool
        // 角色自行进出线下（网页版 4.721）：见面（text 是地点，可空）与回到线上
        case meet, part
        // 情侣账户与亲属卡（网页版 request.js）：申请（extra 是种类 joint / spend / card / deposit，amount 金额，text 用途）、批准与驳回（flag）
        case request, vote
        // 卡包（网页版 4.611、4.643、4.644）：娱乐卡的送、用、同意；门禁卡的给、刷、收回与恢复；票券的送与检；会员卡的开与消费。字段在 info 里
        case funGive, funUse, funVote, passGive, passAct, ticketGive, ticketCheck, memberOpen, memberVisit
        // 心愿（网页版 4.304）：text 是冒号后面那一段原样（「内容|达成条件」），flag 为真是公开的心愿、假是私下心愿；心愿达成：text 是一小段原话
        case wish, wishDone
        // 分享梦境（4.444）：text 是角色自己那一句
        case dreamShare
        // 衣帽间（4.214、4.217）：搭配（text 是这一套的名字，可空；extra 是几件单品用「、」接起来）；
        // 换上、借走、借给你、归还（text 是那一件的名字，extra 是哪一种）
        case outfit, closetAct
        // 短信（网页版 4.307）：认出、发短信、借号发短信。extra 是哪一种，text 是冒号后面那一段原样
        case sms
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
        /// 群里转账、专属红包写明的那个人（名字，网页版 part.to）
        var to: String?
        /// 红包的个数
        var count: Int?
        /// 小剧场的整页
        var html: String?
        /// 调用工具时写坏了的参数原文（不是合法的 JSON 对象）
        var bad: String?
        /// 卡包那几种标记拆出来的几段（名字、地点、次数……），数字写成网页版拼进字符串的样子
        var info: [String: String]?
    }

    struct Result: Sendable {
        var parts: [Part]
        var think: String
        var stamp: String?
    }

    // MARK: - 正则（网页版原文）

    static let markPattern = #"[\[【]\s*(图片|照片|image|pic|视频|video|语音|voice|audio|表情|sticker|emoji|转账|transfer|普通红包|专属红包|领红包|抢红包|红包|位置|定位|location|礼物|gift|点歌|建歌单|加入歌单|分享歌曲|分享音乐|调用|tool|约定完成|约定|pact|信|letter|事项完成|事项取消|心声|换头像|改网名|改备注|备注|外卖|请客|代付|申请|亲属卡|存入情侣账户|存入共同账户|旅行|攻略|待办|todo|授予|award|搭配|outfit|换上|借走|借给你|归还|旁白|narration|改密码|送卡|用卡|送票|检票|开会员卡|会员卡消费|给门禁卡|给钥匙|给房卡|刷门禁卡|用钥匙|刷房卡|收回门禁卡|收回钥匙|收回房卡|恢复门禁卡|恢复钥匙|恢复房卡|卡片|card|小剧场互动|小剧场|theater|文件|file|填写|fill|私信|解除禁言|禁言|改群昵称|心愿达成|私下心愿|心愿|梦境|出题|草稿|开小号|承认小号|解除拉黑|拉黑|删除好友|添加好友|通过好友申请|认出|借号发短信|发短信|入手|点赞|评论|转发帖子|转发|分享商品|想要|出价|下单|挂出|已发货|识破|闲置截图|写纸条|不抽纸条|抽纸条|打开纸条|放回纸条|不回答|完成纸条|转交纸条|给你看纸条|回应纸条|记下回答|封存答案|私人纸条盒)\s*[:：]\s*([^\]】]+)[\]】]"#

    private static let mark = regex(markPattern, [.caseInsensitive])
    private static let voiceTrans = regex(#"\s*[\[【(（]?\s*(?:译文|翻译|译|translation)\s*[:：]"#, [.caseInsensitive])
    private static let sameLineTrans = regex(#"^(.*?\S)\s*[\[【]\s*(?:译文|翻译|译|translation)\s*[:：]\s*([^\]】]*?)\s*[\]】]\s*$"#, [.caseInsensitive])
    private static let sameLineParen = regex(#"^(.*?\S)\s*[(（]\s*(?:译文|翻译|译|translation)\s*[:：]\s*([^)）]*?)\s*[)）]\s*$"#, [.caseInsensitive])
    /// 「原文 [英文：…]」这种拿语言名当标签的写法（网页版 4.521）
    private static let sameLineLang = regex(#"^(.*?\S)\s*[\[【]\s*(?:中文|汉语|简体中文|英文|英语|english|chinese|日文|日语|japanese|韩文|韩语|korean)\s*[:：]\s*([^\]】]*?)\s*[\]】]\s*$"#, [.caseInsensitive])
    private static let transHead = regex(#"^(?:\d+\s*[.、)）]\s*)?([\[【(（]?)\s*(?:译文|翻译|译|translation)\s*([:：]?)\s*([\s\S]*)$"#, [.caseInsensitive])
    private static let innerLine = regex(#"^[\[【(（]?\s*(?:心声|内心|inner)\s*[:：]\s*(.+?)[\]】)）]?\s*$"#, [.caseInsensitive])
    private static let quoteOpen = regex(#"^(?:\d+\s*[.、)）]\s*)?([\[【(（])\s*(?:引用|回复|quote|reply(?:ing)?(?:\s+to)?|in\s+reply\s+to)\s*[:：]\s*(.+?)\s*[\]】)）]\s*(.*)$"#, [.caseInsensitive])

    private static func lineMark(_ words: String) -> NSRegularExpression {
        regex(#"^(?:\d+\s*[.、)）]\s*)?[\[【(（]\s*(?:"# + words + #")\s*(?:[:：][^\]】)）]*)?\s*[\]】)）]\s*[。．.!！~～]?$"#, [.caseInsensitive])
    }
    // 「撤回了一条消息」是历史里对方撤回时的写法，模型会照着写成自己的撤回，一并认下（网页版 4.647）
    private static let recallLine = lineMark("撤回了一条消息|撤回上一条|撤回消息|撤回这一?条|撤回了|已撤回|撤回")
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
        lineMark("不覆盖"),
        lineMark("覆盖"),
    ]
    static let muteAllLine = lineMark("全员禁言|开启全员禁言")
    static let jointLine = lineMark("开设情侣账户|开情侣账户|开通情侣账户|开通共同账户|开共同账户")
    static let okayLine = lineMark("批准|同意|通过")
    static let denyLine = lineMark("驳回|拒绝|不同意")
    static let funOkLine = lineMark("同意用卡|允许用卡")
    static let funNoLine = lineMark("不同意用卡|拒绝用卡")
    // 自行退群（网页版 4.733）：整行就是它
    static let leaveLine = lineMark("退群|退出群聊")
    // 角色自行进出线下（网页版 4.721 的 MEET_LINE、PART_LINE）。整行只能是这一个标记
    static let meetLine = regex(#"^[\[【(（]\s*见面\s*(?:[:：]\s*([^\]】)）]*?))?\s*[\]】)）]$"#, [])
    static let partLine = regex(#"^[\[【(（]\s*回到线上\s*[\]】)）]$"#, [])
    // 领红包（4.736）：不写发的人就是能领的最近那一个
    static let rpClaimLine = lineMark("领红包|抢红包|拆红包")
    static let unmuteAllLine = lineMark("解除全员禁言|关闭全员禁言")
    private static let keepLine = regex(#"^[\[【(（]?\s*(?:存图|存照片)\s*[:：]\s*(.+?)[\]】)）]?\s*$"#, [.caseInsensitive])
    // 截下聊天记录、发一张截过的（网页版 reply.js 的 SHOT_LINE、SEND_SHOT_LINE）。单独一行才认，和存图一样
    static let shotLine = regex(#"^[\[【]\s*(?:截图|截屏|screenshot)\s*(?:[:：]\s*(.*?))?\s*[\]】]\s*$"#, [.caseInsensitive])
    static let sendShotLine = regex(#"^[\[【]\s*(?:发截图|发送截图|send screenshot)\s*(?:[:：]\s*(.*?))?\s*[\]】]\s*$"#, [.caseInsensitive])
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
    static let muteSpan = regex(#"^([\s\S]*?)\s*(\d+)\s*(分钟|分|小时|个小时|时|天|日)\s*$"#, [])
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
    /// 回复切分的正式入口：先用网页版的 reply.js（WebLogic：编译时从网页版仓库取来打包进 app，与网页版同一份代码）；
    /// 包里没有、加载失败或解析抛错时，退回下面原生的这一份，聊天不受影响（docs/jscore-pilot.md）
    static func splitPreferWeb(_ raw: String, autoSplitAt: Int = 40) -> Result {
        let t0 = Date()
        if let r = WebLogic.parseReply(raw, autoSplitAt: autoSplitAt) {
            // 真机上 app 里的 JavaScriptCore 没有加速，慢的那几次记下来，好知道真机上的实际耗时
            let ms = Date().timeIntervalSince(t0) * 1000
            if ms > 30 { Diagnostics.shared.record("weblogic-slow", ["ms": Int(ms), "chars": raw.count]) }
            return r
        }
        return split(raw, autoSplitAt: autoSplitAt)
    }

    static func split(_ raw: String, autoSplitAt: Int = 40) -> Result {
        let (body, think) = stripThink(raw)
        let (stamped, stamp) = stripStamps(MarkFold.splitTrailRecall(MarkFold.foldMedia(MarkFold.fold(body.trimmingCharacters(in: .whitespacesAndNewlines)))))
        let (staged, theaters) = liftTheater(stamped)
        let (called, calls) = liftCalls(staged)
        let (text, cards) = liftCards(called)
        var state = State()
        state.cards = cards
        state.theaters = theaters
        state.calls = calls

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

    // MARK: - 小剧场（网页版 liftTheater，ARCHITECTURE 4.769）

    // 角色写的是一整段页面：[小剧场：主题]、HTML（可以包在 ```html 里）、[/小剧场]。只写一行 [小剧场：主题｜梗概]、
    // 后面不跟页面的，是一张封面。和卡片一样先整段摘出来，原位换成 [小剧场：#序号]。
    // 漏写收尾的：紧跟着的是页面（以 < 或 ``` 开头）就收到这一轮末尾，否则当封面
    private static let theaterHead = regex(#"[\[【]\s*(?:小剧场|theater)\s*[:：]\s*([^\]】\n#][^\]】\n]*?)\s*[\]】]"#, [.caseInsensitive])
    private static let theaterEnd = regex(#"[\[【]\s*/\s*(?:小剧场|theater)\s*[\]】]"#, [.caseInsensitive])
    private static let pageStart = regex(#"^\s*(?:<|```)"#, [])

    static func unfence(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^```[a-zA-Z]*[ \t]*\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n?```\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func liftTheater(_ text: String) -> (String, [(title: String, brief: String, html: String)]) {
        let ns = text as NSString
        var list: [(title: String, brief: String, html: String)] = []
        var out = ""
        var last = 0
        var from = 0
        while from < ns.length, let m = theaterHead.firstMatch(in: text, range: NSRange(location: from, length: ns.length - from)) {
            let head = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let bar = head.firstIndex { $0 == "|" || $0 == "｜" }
            let title = (bar.map { String(head[..<$0]) } ?? head).trimmingCharacters(in: .whitespaces)
            let brief = bar.map { String(head[head.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
            let start = m.range.location + m.range.length
            let restRange = NSRange(location: start, length: ns.length - start)
            var body = ""
            var stop = start
            if let e = theaterEnd.firstMatch(in: text, range: restRange) {
                body = ns.substring(with: NSRange(location: start, length: e.range.location - start))
                stop = e.range.location + e.range.length
            } else {
                let rest = ns.substring(with: restRange)
                if matches(pageStart, rest) {
                    body = rest
                    stop = ns.length
                }
            }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + "\n[小剧场：#\(list.count)]\n"
            list.append((title, brief, unfence(body)))
            last = stop
            from = max(stop, m.range.location + 1)
        }
        return (out + ns.substring(from: last), list)
    }

    // MARK: - 调用工具（网页版 liftCalls，ARCHITECTURE 4.179）

    // [调用：名字 {JSON 参数}]。参数里常有方括号与换行，标记那条正则在第一个 ] 就收口了。
    // 所以先单独扫一遍：按花括号配对（认得字符串里的括号与转义）把整段取出来，原位换成 [调用：#序号]
    private static let callHead = regex(#"[\[【]\s*(?:调用|tool)\s*[:：]\s*"#, [.caseInsensitive])

    /// 从 at 那个 { 开始，找到与它配对的 } 的位置（UTF-16 下标）。没配上返回 nil
    static func braceEnd(_ u: [UInt16], _ at: Int) -> Int? {
        var depth = 0, str = false, esc = false
        var i = at
        while i < u.count {
            let c = u[i]
            if str {
                if esc { esc = false } else if c == 0x5C { esc = true } else if c == 0x22 { str = false }
            } else if c == 0x22 { str = true }
            else if c == 0x7B { depth += 1 }
            else if c == 0x7D { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    /// 参数对象写成文字：键排好序，两边读出来的一样
    static func argsText(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    static func liftCalls(_ text: String) -> (String, [(name: String, args: String, bad: String)]) {
        let ns = text as NSString
        let u = Array(text.utf16)
        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x3000 || c == 0xA0 }
        var calls: [(name: String, args: String, bad: String)] = []
        var out = ""
        var last = 0
        var from = 0
        while from < ns.length, let m = callHead.firstMatch(in: text, range: NSRange(location: from, length: ns.length - from)) {
            from = m.range.location + m.range.length
            let i = from
            var j = i
            while j < u.count, !isSpace(u[j]), u[j] != 0x7B, u[j] != 0x5D, u[j] != 0x3011 { j += 1 }
            let name = ns.substring(with: NSRange(location: i, length: j - i)).trimmingCharacters(in: .whitespaces)
            var k = j
            while k < u.count, isSpace(u[k]) { k += 1 }
            var args = "{}", bad = ""
            if k < u.count, u[k] == 0x7B {
                guard let end = braceEnd(u, k) else { continue }
                let raw = ns.substring(with: NSRange(location: k, length: end - k + 1))
                if let v = try? JSONSerialization.jsonObject(with: Data(raw.utf8)), v is [String: Any] { args = argsText(v) } else { bad = raw }
                k = end + 1
                while k < u.count, isSpace(u[k]) { k += 1 }
            }
            guard !name.isEmpty, k < u.count, u[k] == 0x5D || u[k] == 0x3011 else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + "[调用：#\(calls.count)]"
            calls.append((name, args, bad))
            last = k + 1
            from = last
        }
        return (out + ns.substring(from: last), calls)
    }

    // MARK: - 逐段

    private struct State {
        var parts: [Part] = []
        var cards: [(name: String, body: String)] = []
        var theaters: [(title: String, brief: String, html: String)] = []
        var calls: [(name: String, args: String, bad: String)] = []
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
            case "禁言":
                // 「名字 10分钟」：最后一截是时长（分钟、小时、天），没写或写「永久」就是一直禁到解除
                var name = body, minutes = 0.0
                if let m = ReplyParser.match(ReplyParser.muteSpan, body), let n = Double(m[2]) {
                    minutes = n * (m[3].contains("天") || m[3].contains("日") ? 1440 : m[3].contains("时") ? 60 : 1)
                    name = m[1]
                } else {
                    name = body.replacingOccurrences(of: #"\s*永久\s*$"#, with: "", options: .regularExpression)
                }
                name = name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { var p = Part(type: .mute, text: name); p.amount = minutes; push(p) }
            case "解除禁言":
                push(Part(type: .unmute, text: body))
            case "改群昵称":
                // 「新昵称」是改自己的；「名字｜新昵称」是改别人的
                let bar = body.firstIndex { $0 == "|" || $0 == "｜" }
                var p = Part(type: .nick, text: bar.map { String(body[..<$0]).trimmingCharacters(in: .whitespaces) } ?? "")
                p.extra = (bar.map { String(body[body.index(after: $0)...]) } ?? body).trimmingCharacters(in: .whitespaces)
                push(p)
            case "转账", "transfer":
                // 群里写明转给谁（网页版 4.736）：「名字｜金额 备注」。竖线前面本身就是金额、后面读不出金额的，
                // 是私聊里原来的「金额｜留言」（4.753），照旧整段当金额与留言读
                var bar = body.firstIndex { $0 == "|" || $0 == "｜" }
                if let b = bar, ReplyParser.matches(ReplyParser.amountRe, String(body[..<b])),
                   !ReplyParser.matches(ReplyParser.amountRe, String(body[body.index(after: b)...])) { bar = nil }
                var toName = bar.map { String(body[..<$0]).trimmingCharacters(in: .whitespaces) } ?? ""
                if toName.hasPrefix("@") { toName.removeFirst() }
                let rest = bar.map { String(body[body.index(after: $0)...]) } ?? body
                // 金额读不出来就整条丢掉。凭空造一笔金额不明的转账比少发一条更糟
                if let m = ReplyParser.match(ReplyParser.amountRe, rest), let a = Double(m[1]) {
                    var p = Part(type: .transfer, text: m[2].trimmingCharacters(in: .whitespaces))
                    p.amount = a
                    if !toName.isEmpty { p.to = toName }
                    push(p)
                }
            case "红包", "普通红包", "专属红包":
                // 群红包（4.736）：[红包：总额｜个数｜祝福语]、[普通红包：…]、[专属红包：名字｜金额｜祝福语]
                let rtype = kind == "普通红包" ? "equal" : kind == "专属红包" ? "only" : "luck"
                let xs = body.split(maxSplits: Int.max, omittingEmptySubsequences: false, whereSeparator: { $0 == "|" || $0 == "｜" }).map { $0.trimmingCharacters(in: .whitespaces) }
                func num(_ i: Int) -> Double {
                    guard i < xs.count else { return 0 }
                    let t = xs[i].filter { !"¥￥$元块个".contains($0) && !$0.isWhitespace }
                    return Double(t) ?? 0
                }
                let note = xs.count > 2 ? xs[2...].joined(separator: " ") : ""
                if rtype == "only" {
                    var who = xs.first ?? ""
                    if who.hasPrefix("@") { who.removeFirst() }
                    if !who.isEmpty && num(1) > 0 {
                        var p = Part(type: .redpacket, text: note)
                        p.amount = num(1); p.count = 1; p.extra = rtype; p.to = who
                        push(p)
                    }
                } else if num(0) > 0 {
                    var p = Part(type: .redpacket, text: note)
                    let n = num(1)
                    p.amount = num(0); p.count = max(1, n.isFinite && n > 0 ? Int(n.rounded()) : 1); p.extra = rtype
                    push(p)
                }
            case "领红包", "抢红包":
                var from = body
                if from.hasPrefix("@") { from.removeFirst() }
                push(Part(type: .rpclaim, text: from.trimmingCharacters(in: .whitespaces)))
            case "改网名":
                push(Part(type: .selfnick, text: body))
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
            case "申请", "亲属卡", "存入情侣账户", "存入共同账户":
                // 和外卖同一种拆法，最后一个数是金额；读不出金额的整条丢掉（网页版 ASK_KINDS、CARD_KINDS、DEPOSIT_KINDS）
                if let o = Interact.parseTakeout(body), o.amount > 0 {
                    var p = Part(type: .request, text: kind == "亲属卡" ? "" : o.item)
                    p.amount = o.amount
                    p.extra = kind == "申请" ? LedgerRequest.spend : kind == "亲属卡" ? LedgerRequest.card : LedgerRequest.deposit
                    push(p)
                }
            case "送卡":
                if let o = WalletCards.Fun.parse(body) {
                    var p = Part(type: .funGive, text: o.name)
                    p.info = ["name": o.name, "desc": o.desc, "uses": WalletCards.numText(o.uses), "days": WalletCards.numText(o.days),
                              "until": WalletCards.numText(o.until), "confirm": o.confirm ? "1" : ""]
                    push(p)
                }
            case "用卡":
                let name = body.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { push(Part(type: .funUse, text: name)) }
            case "送票":
                let seg = ReplyParser.bars(body)
                if !seg[0].isEmpty {
                    var p = Part(type: .ticketGive, text: seg[0])
                    p.info = ["title": seg[0], "when": seg[1], "venue": seg[2], "seat": seg[3]]
                    push(p)
                }
            case "检票":
                push(Part(type: .ticketCheck, text: body.trimmingCharacters(in: .whitespaces)))
            case "开会员卡":
                let seg = ReplyParser.bars(body)
                if !seg[0].isEmpty {
                    var p = Part(type: .memberOpen, text: seg[0])
                    p.info = ["shop": seg[0], "note": seg[1]]
                    push(p)
                }
            case "会员卡消费":
                let seg = ReplyParser.bars(body)
                if !seg[0].isEmpty {
                    let pts = seg[1].range(of: #"\d+"#, options: .regularExpression).flatMap { Double(seg[1][$0]) } ?? 0
                    var p = Part(type: .memberVisit, text: seg[0])
                    p.info = ["shop": seg[0], "points": WalletCards.numText(pts.rounded()), "note": seg[2]]
                    push(p)
                }
            case "给门禁卡", "给钥匙", "给房卡":
                let seg = ReplyParser.bars(body)
                var p = Part(type: .passGive, text: seg[0])
                p.info = ["kind": WalletCards.Pass.kindByMark(kind)?.id ?? "door", "name": seg[0], "place": seg[1], "note": seg[2]]
                push(p)
            case "刷门禁卡", "用钥匙", "刷房卡":
                let name = body.trimmingCharacters(in: .whitespaces)
                var p = Part(type: .passAct, text: name)
                p.info = ["act": "use", "kind": WalletCards.Pass.kindByMark(kind)?.id ?? "", "name": name]
                push(p)
            case "收回门禁卡", "收回钥匙", "收回房卡", "恢复门禁卡", "恢复钥匙", "恢复房卡":
                let name = body.trimmingCharacters(in: .whitespaces)
                let revoke = WalletCards.Pass.revokeMarks[kind] != nil
                var p = Part(type: .passAct, text: name)
                p.info = ["act": revoke ? "revoke" : "grant", "kind": WalletCards.Pass.revokeMarks[kind] ?? WalletCards.Pass.grantMarks[kind] ?? "", "name": name]
                push(p)
            case "备注", "改备注":
                push(Part(type: .remark, text: body))
            case "换头像":
                push(Part(type: .wear, text: body.trimmingCharacters(in: .whitespaces)))
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
            case "认出", "发短信", "借号发短信":
                // 网页版 SMS_KINDS：原样交给短信那一套，竖线在那边拆
                var p = Part(type: .sms, text: body)
                p.extra = kind
                push(p)
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
            case "授予", "award":
                // 竖线前是标识的名字，后面是理由。没写竖线就整段是名字
                let bar = body.firstIndex { $0 == "|" || $0 == "｜" }
                let name = (bar.map { String(body[..<$0]) } ?? body).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    var p = Part(type: .award, text: name)
                    p.extra = (bar.map { String(body[body.index(after: $0)...]) } ?? "").trimmingCharacters(in: .whitespaces)
                    push(p)
                }
            case "卡片", "card":
                if body.hasPrefix("#"), let i = Int(body.dropFirst()), cards.indices.contains(i) {
                    var p = Part(type: .card, text: cards[i].name)
                    p.extra = cards[i].body
                    push(p)
                }
            case "小剧场", "theater":
                if body.hasPrefix("#"), let i = Int(body.dropFirst()), theaters.indices.contains(i) {
                    var p = Part(type: .theater, text: theaters[i].title)
                    p.extra = theaters[i].brief
                    p.html = theaters[i].html
                    push(p)
                }
            case "小剧场互动":
                break   // 你在小剧场里点的那几下，历史里一行一条；角色照着写回来的不落成气泡
            case "调用", "tool":
                if body.hasPrefix("#"), let i = Int(body.dropFirst()), calls.indices.contains(i) {
                    var p = Part(type: .tool, text: calls[i].name)
                    p.extra = calls[i].args
                    if !calls[i].bad.isEmpty { p.bad = calls[i].bad }
                    push(p)
                }
            case "草稿":
                let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { push(Part(type: .draft, text: t)) }
            case "待办", "todo":
                // 网页版 reply.js 的 TODO_KINDS：原样交给待办，空的由 propose 丢掉
                push(Part(type: .todo, text: body))
            case "事项完成", "事项取消":
                var p = Part(type: .agenda, text: body.trimmingCharacters(in: .whitespaces))
                p.flag = kind == "事项完成"
                push(p)
            case "心愿", "私下心愿":
                var p = Part(type: .wish, text: body)
                p.flag = kind == "心愿"
                push(p)
            case "心愿达成":
                push(Part(type: .wishDone, text: body))
            case "梦境":
                push(Part(type: .dreamShare, text: body))
            case "换上", "借走", "借给你", "归还":
                var p = Part(type: .closetAct, text: body)
                p.extra = kind
                push(p)
            case "搭配", "outfit":
                // 竖线前是这一套的名字，后面是几件单品。一件都没有就整条丢掉（网页版 closet.parseOutfit）
                if let o = Closet.parseOutfit(body) {
                    var p = Part(type: .outfit, text: o.name)
                    p.extra = o.names.joined(separator: "、")
                    push(p)
                }
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
            if (p.type == .text && !bare || p.type == .voice || p.type == .narration) && p.translation == nil {
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
            for re in [ReplyParser.sameLineTrans, ReplyParser.sameLineParen, ReplyParser.sameLineLang] {
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
            // 见面、回到线上（网页版 4.721）。见面落一张卡片，回到线上落一条分隔线，都不是一条气泡
            if let m = ReplyParser.match(ReplyParser.meetLine, t) {
                push(Part(type: .meet, text: m.count > 1 ? m[1].trimmingCharacters(in: .whitespaces) : ""))
                return
            }
            if ReplyParser.matches(ReplyParser.partLine, t) { push(Part(type: .part, text: "")); return }
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
            if let m = ReplyParser.match(ReplyParser.sendShotLine, t) {
                push(Part(type: .sendshot, text: m[1].trimmingCharacters(in: .whitespaces)))
                return
            }
            if let m = ReplyParser.match(ReplyParser.shotLine, t) {
                push(Part(type: .shot, text: m[1].trimmingCharacters(in: .whitespaces)))
                return
            }
            // 它要打电话过来。不占气泡：电话是一件事，不是一条消息
            if let m = ReplyParser.match(ReplyParser.ringLine, t) {
                var p = Part(type: .ring, text: "")
                p.flag = !m[1].isEmpty
                push(p)
                return
            }
            if ReplyParser.matches(ReplyParser.unmuteAllLine, t) { var p = Part(type: .muteAll, text: ""); p.flag = false; push(p); return }
            if ReplyParser.matches(ReplyParser.muteAllLine, t) { var p = Part(type: .muteAll, text: ""); p.flag = true; push(p); return }
            if ReplyParser.matches(ReplyParser.leaveLine, t) { push(Part(type: .leave, text: "")); return }
            if ReplyParser.matches(ReplyParser.rpClaimLine, t) { push(Part(type: .rpclaim, text: "")); return }
            // 情侣账户：开设、批准、驳回各一行；娱乐卡的同意与不同意在批准、驳回之前认（网页版 reply.js 的顺序）
            if ReplyParser.matches(ReplyParser.jointLine, t) { var p = Part(type: .request, text: ""); p.extra = LedgerRequest.joint; push(p); return }
            if ReplyParser.matches(ReplyParser.funNoLine, t) { push(Part(type: .funVote, text: "")); return }
            if ReplyParser.matches(ReplyParser.funOkLine, t) { var p = Part(type: .funVote, text: ""); p.flag = true; push(p); return }
            if ReplyParser.matches(ReplyParser.okayLine, t) { var p = Part(type: .vote, text: ""); p.flag = true; push(p); return }
            if ReplyParser.matches(ReplyParser.denyLine, t) { push(Part(type: .vote, text: "")); return }
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

    /// 按竖线切成几段、去掉两头空白；不够的补空串（网页版 body.split(/[｜|]/)，取 seg[i] || ''）
    static func bars(_ body: String, at least: Int = 4) -> [String] {
        var seg = body.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "|" || $0 == "｜" }).map { $0.trimmingCharacters(in: .whitespaces) }
        while seg.count < least { seg.append("") }
        return seg
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
