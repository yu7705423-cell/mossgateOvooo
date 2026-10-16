import Foundation

/// 标记名写成繁体（或日文汉字）也认（网页版 system/markfold.js，ARCHITECTURE 4.254）。
///
/// 方括号（以及整行的圆括号）开头、冒号或收口之前那一小段逐字换成简体，**换完正好是一个认得的标记名才替换**，
/// 否则原样留着。括号里的正文一个字不动。字表与标记名由网页版那份逐字搬来。
enum MarkFold {
    /// 繁体（含日文写法）到简体，逐字对齐的两行（字典字面量太长时编译器推断不过来，所以写成两行再拼）
    private static let from = "圖視頻語轉賬帳禮點單樂調約項聲換頭備註賣請親屬辦給歸還碼譯應復擲動態刪開戶駁絕電話撥聽暫繼續進簽時間內攜圍願達號認過發讚贊評論貨掛識價閒閑夢題門鑰檢會員費迴囘條經"
    private static let to = "图视频语转账账礼点单乐调约项声换头备注卖请亲属办给归还码译应复掷动态删开户驳绝电话拨听暂继续进签时间内携围愿达号认过发赞赞评论货挂识价闲闲梦题门钥检会员费回回条经"
    static let t2s: [Swift.Character: Swift.Character] = Dictionary(uniqueKeysWithValues: zip(from, to))

    static let heads: Set<String> = [
        "图片",
        "照片",
        "视频",
        "语音",
        "表情",
        "转账",
        "位置",
        "定位",
        "礼物",
        "点歌",
        "建歌单",
        "加入歌单",
        "分享歌曲",
        "分享音乐",
        "调用",
        "约定完成",
        "约定",
        "信",
        "事项完成",
        "事项取消",
        "心声",
        "内心",
        "换头像",
        "改备注",
        "备注",
        "外卖",
        "请客",
        "代付",
        "申请",
        "亲属卡",
        "旅行",
        "攻略",
        "待办",
        "授予",
        "搭配",
        "换上",
        "借走",
        "借给你",
        "归还",
        "塞进包里",
        "旁白",
        "改密码",
        "卡片",
        "/卡片",
        "时间",
        "心愿",
        "私下心愿",
        "心愿达成",
        "草稿",
        "开小号",
        "承认小号",
        "拉黑",
        "解除拉黑",
        "删除好友",
        "添加好友",
        "通过好友申请",
        "认出",
        "发短信",
        "借号发短信",
        "点赞",
        "评论",
        "转发帖子",
        "转发",
        "分享商品",
        "想要",
        "出价",
        "下单",
        "挂出",
        "已发货",
        "识破",
        "闲置截图",
        "梦境",
        "出题",
        "引用",
        "回复",
        "译文",
        "翻译",
        "译",
        "存图",
        "存照片",
        "收款",
        "收下",
        "接收",
        "退回",
        "退还",
        "同行",
        "一起去",
        "不去",
        "去不了",
        "要了",
        "吃了",
        "签收",
        "不要",
        "不用了",
        "拆开",
        "打开",
        "拆礼物",
        "拒收",
        "不收",
        "退掉",
        "一起听",
        "一起听歌",
        "听歌",
        "暂停",
        "暂停一下",
        "继续",
        "继续播放",
        "接着看",
        "倒回",
        "回到",
        "快进",
        "拍一拍",
        "拍拍",
        "戳一戳",
        "撤回动态",
        "删除动态",
        "撤回",
        "撤回消息",
        "撤回上一条",
        "撤回了一条消息",
        "撤回了",
        "已撤回",
        "撤回这条",
        "撤回这一条",
        "开通共同账户",
        "开共同账户",
        "批准",
        "同意",
        "通过",
        "驳回",
        "拒绝",
        "不同意",
        "骰子",
        "掷骰子",
        "扔骰子",
        "去电",
        "来电",
        "打电话",
        "拨打",
        "通话",
        "视频去电",
        "视频来电",
        "视频通话"
    ]

    private static let head = try! NSRegularExpression(pattern: #"([\[【])(\s*)([^\]】:：\n]{1,8}?)(\s*)(?=[:：\]】])"#)
    private static let line = try! NSRegularExpression(pattern: #"^([(（])(\s*)([^)）:：\n]{1,8}?)(\s*)(?=[:：)）]\s*$)"#, options: [.anchorsMatchLines])

    static func fold(_ text: String) -> String {
        apply(line, to: apply(head, to: text))
    }

    private static func apply(_ re: NSRegularExpression, to text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let whole = ns.substring(with: m.range)
            let h = ns.substring(with: m.range(at: 3))
            let folded = String(h.map { t2s[$0] ?? $0 })
            if h.unicodeScalars.contains(where: { $0.value > 0x7f }), folded != h, heads.contains(folded) {
                out += ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2)) + folded + ns.substring(with: m.range(at: 4))
            } else {
                out += whole
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: - 图片、语音、视频标记的走样（网页版 markfold.foldMedia，ARCHITECTURE 4.635）
    //
    // 反馈：角色说发了图片、语音，其实没有发，连「正在生成」都没有。解析只认 [图片：…] [语音：…] 这一种写法，
    // 模型常写成别的样子，整行就当成正文落成一个气泡：
    //   [发送图片：…] [语音消息：…] [录音：…]      标记名换了个说法
    //   [图片]：… 【照片】… [语音]…                名字和内容之间是收口不是冒号
    //   （图片：…） (语音：…)                      整行用圆括号
    //   [图片：…                                   行末没收口
    // 这几种换成规范写法再交给解析。只动这几类，别的标记不碰；截图（闲置截图）不算图片。

    private static let media: [String: String] = [
        "图片": "图片", "照片": "照片", "视频": "视频", "语音": "语音",
        "发送图片": "图片", "发图片": "图片", "发图": "图片", "图": "图片", "配图": "图片", "自拍": "图片", "图片描述": "图片",
        "照片描述": "照片", "相片": "照片", "发照片": "照片", "发送照片": "照片",
        "发送视频": "视频", "发视频": "视频", "视频描述": "视频",
        "语音消息": "语音", "发语音": "语音", "发送语音": "语音", "语音条": "语音", "录音": "语音",
    ]

    static func canon(_ head: String) -> String {
        let h = String(head.filter { !$0.isWhitespace }.map { t2s[$0] ?? $0 })
        return media[h] ?? ""
    }

    private static let alias = try! NSRegularExpression(pattern: #"([\[【])\s*([^\]】:：\n]{1,6}?)\s*([:：])"#)
    private static let shut = try! NSRegularExpression(pattern: #"^[\[【]\s*([^\]】:：\n]{1,6}?)\s*[\]】]\s*[:：]?\s*(\S[\s\S]*)$"#)
    private static let roundLine = try! NSRegularExpression(pattern: #"^[(（]\s*([^)）:：\n]{1,6}?)\s*[:：]\s*([\s\S]+?)\s*[)）]$"#)
    private static let openLine = try! NSRegularExpression(pattern: #"^[\[【]\s*([^\]】:：\n]{1,6}?)\s*[:：]\s*([^\]】]+?)\s*$"#)

    private static func groups(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    /// 图片、语音、视频标记的几种走样换成规范写法
    static func foldMedia(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let ns = line as NSString
            var s = ""
            var last = 0
            for m in alias.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                s += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let head = ns.substring(with: m.range(at: 2))
                let c = canon(head)
                s += !c.isEmpty && c != head ? ns.substring(with: m.range(at: 1)) + c + ns.substring(with: m.range(at: 3)) : ns.substring(with: m.range)
                last = m.range.location + m.range.length
            }
            s += ns.substring(from: last)
            let t = s.trimmingCharacters(in: .whitespaces)
            if let g = groups(shut, t), !canon(g[1]).isEmpty { return "[\(canon(g[1]))：\(g[2].trimmingCharacters(in: .whitespaces))]" }
            if let g = groups(roundLine, t), !canon(g[1]).isEmpty { return "[\(canon(g[1]))：\(g[2])]" }
            if let g = groups(openLine, t), !canon(g[1]).isEmpty { return "[\(canon(g[1]))：\(g[2])]" }
            return s
        }.joined(separator: "\n")
    }

    // MARK: - 撤回写在那一条的行末（网页版 markfold.splitTrailRecall，ARCHITECTURE 4.647）
    //
    // 规定是 [撤回] 单独一行、紧跟在要撤回的那一条后面。模型常常接在那一行的末尾：「其实我有点想你[撤回]」，
    // 整行成了一条正文，标记露在气泡里，那一条也没撤回。这里把行末的撤回标记拆到下一行，交给解析照常处理。
    // 只拆行末那一个；夹在一行中间的不动。撤回动态不跟着哪一条，不拆。

    private static let trailRecall = try! NSRegularExpression(
        pattern: #"^(.*\S)\s*([\[【]\s*(?:撤回(?:消息|上一条|了一条消息|这一?条|了)?|已撤回)\s*[\]】])\s*[。．.!！~～]?\s*$"#,
        options: [.anchorsMatchLines])

    /// 行末的撤回标记拆成单独一行
    static func splitTrailRecall(_ text: String) -> String {
        let ns = text as NSString
        return trailRecall.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "$1\n$2")
    }
}
