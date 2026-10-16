import Foundation
import Combine
import ImageIO
import UIKit

/// 自定义组件的占位符（原生版独有）：HTML 里写 `{{角色名}}`、`{{最近几句:3}}` 这样的占位符，
/// 装进盒子之前由本应用读本机的数据填进去。不联网、不调接口，只读不写。
///
/// - 只算 HTML 里真的写了的那几项；认不出的名字原样留着；
/// - 填进 HTML 的文字一律先转义（& < > " ' 与反斜杠、反引号），数据里有什么都变不成标记或脚本；
/// - 同一份数据另经桥交给脚本：`widget.data`，只有 HTML 里写了的那几项，`最近几句` 是一个数组；
/// - 写了占位符的组件默认关掉外部图片与字体（CSP 的 images: false）：否则组件可以把填进去的内容拼进图片地址发出去。
///   这一格的 config.allowRemote 为 true 时照旧放开，编辑页上写明后果。
/// - 交进去的只有下面列的这几项：不交人设正文、设置、密钥，也不交别的任何东西（CLAUDE.md 第 6 条、网页版第 21 条）。
extension CustomWidget {
    /// 认得的名字。顺序即写法说明里列的顺序
    static let placeholderNames: [String] = [
        "角色名", "签名", "角色头像", "我的名字", "我的头像",
        "最近一句", "最近几句", "上次聊天", "未读",
        "在一起天数", "认识天数", "纪念日", "纪念日名", "纪念日天数",
        "最近记忆", "角色日记", "角色朋友圈", "正在听", "角色时间", "角色天气",
    ]
    private static let placeholderSet = Set(placeholderNames)

    /// 随时间变化的几项：用到时每分钟重算一次（值没变不重装页面）
    /// 上次聊天的写法：刚刚、5 分钟前、3 小时前、2 天前，再早写月日
    static func agoZH(_ t: Double, now: Date = Date()) -> String {
        guard t > 0 else { return "" }
        let m = Int(floor((now.timeIntervalSince1970 * 1000 - t) / 60000))
        if m < 1 { return "刚刚" }
        if m < 60 { return "\(m) 分钟前" }
        if m < 1440 { return "\(m / 60) 小时前" }
        if m < 7 * 1440 { return "\(m / 1440) 天前" }
        let p = MoreWidgets.Day.parts(Date(millis: t))
        return "\(p.m + 1)月\(p.d)日"
    }

    /// 用到随时间变化的项时，每分钟重算一次（一个共用的计时器，不随每次重画重建）
    static let minute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    static let clockNames: Set<String> = ["上次聊天", "角色时间", "在一起天数", "认识天数", "纪念日", "纪念日天数", "角色天气"]

    /// 一个占位符：名字与冒号后面的参数（没写为空串）
    struct Token: Hashable, Sendable {
        let name: String
        let arg: String
        /// 填值、widget.data 用的键：`名字` 或 `名字:参数`
        var key: String { arg.isEmpty ? name : "\(name):\(arg)" }
    }

    /// 最近几句里的一句
    struct Line: Equatable, Sendable {
        var who: String
        var me: Bool
        var text: String
        var time: Double
    }

    /// 算好的值：按占位符的键给文字；最近几句另给一份结构化的
    struct Filled: Equatable, Sendable {
        var text: [String: String] = [:]
        var lines: [Line] = []

        /// 值变了页面才重装
        var hash: Int {
            var h = Hasher()
            for k in text.keys.sorted() {
                h.combine(k)
                h.combine(text[k] ?? "")
            }
            for l in lines {
                h.combine(l.who)
                h.combine(l.me)
                h.combine(l.text)
                h.combine(l.time)
            }
            return h.finalize()
        }
    }

    private static let tokenRegex = try? NSRegularExpression(pattern: #"\{\{([^{}]*)\}\}"#)

    /// `{{` 与 `}}` 之间的那一段读成占位符；名字认不出是 nil。冒号全角半角都认
    static func token(_ inner: String) -> Token? {
        let norm = inner.replacingOccurrences(of: "：", with: ":")
        let parts = norm.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let name = String(first).trimmingCharacters(in: .whitespaces)
        guard placeholderSet.contains(name) else { return nil }
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return Token(name: name, arg: arg)
    }

    /// HTML 里写了的占位符，去重，按出现的顺序
    static func tokens(_ html: String) -> [Token] {
        guard let re = tokenRegex, html.contains("{{") else { return [] }
        let ns = html as NSString
        var seen = Set<Token>()
        var out: [Token] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard let t = token(ns.substring(with: m.range(at: 1))), !seen.contains(t) else { continue }
            seen.insert(t)
            out.append(t)
        }
        return out
    }

    /// 按文件缓存（文件存一次换一个 id，缓存不会过期）
    nonisolated(unsafe) static var tokenCache: [String: [Token]] = [:]

    static func tokens(fileId: String, html: String) -> [Token] {
        if let hit = tokenCache[fileId] { return hit }
        let t = tokens(html)
        tokenCache[fileId] = t
        return t
    }

    /// 填进 HTML 之前的转义。反斜杠与反引号也换掉：值落在脚本的字符串里时同样截不断
    static func escapeHTML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            case "\\": out += "&#92;"
            case "`": out += "&#96;"
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// 把认得的占位符换成转义过的值（没有值的换成空串），认不出的原样留着。只换一遍，值里的 {{…}} 不再展开
    static func fill(_ html: String, _ values: [String: String]) -> String {
        guard let re = tokenRegex, html.contains("{{") else { return html }
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard let t = token(ns.substring(with: m.range(at: 1))) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += escapeHTML(values[t.key] ?? "")
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// `:N` 读成正整数，读不出按默认。不设上限（CLAUDE.md 第 13 条）
    static func count(_ arg: String, default d: Int) -> Int {
        guard let n = Int(arg) else { return d }
        return max(1, n)
    }

    /// 最近几句的文字：每行「名字：内容」，最后 n 句
    static func recentText(_ lines: [Line], _ n: Int) -> String {
        lines.suffix(max(0, n)).map { "\($0.who)：\($0.text)" }.joined(separator: "\n")
    }

    /// 交给脚本的 widget.data：HTML 里写了的每个键一项文字；写了最近几句（任何一种写法）时，`最近几句` 是数组
    static func dataValue(_ tokens: [Token], _ f: Filled) -> JSONValue {
        var o: [String: JSONValue] = [:]
        for t in tokens { o[t.key] = .string(f.text[t.key] ?? "") }
        if tokens.contains(where: { $0.name == "最近几句" }) {
            o["最近几句"] = .array(f.lines.map { l -> JSONValue in
                JSONValue.object(["who": .string(l.who), "me": .bool(l.me), "text": .string(l.text), "time": .number(l.time)])
            })
        }
        return .object(o)
    }

    /// 写了占位符时是否仍放开外部图片与字体（这一格的 config.allowRemote，默认关）
    static func allowRemote(_ config: [String: JSONValue]) -> Bool { config["allowRemote"]?.bool == true }

    // MARK: - 头像

    nonisolated(unsafe) static var avatarCache: [String: String] = [:]

    /// 头像缩到最长边 256 像素，写成 data: 地址。有透明的用 PNG，其余 JPEG。读不到为空串
    static func avatarURI(_ id: String) -> String {
        guard !id.isEmpty else { return "" }
        if let hit = avatarCache[id] { return hit }
        guard let url = MediaStore.url(.images, id: id), let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "" }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Images.iconMax,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return "" }
        let image = UIImage(cgImage: cg)
        let alpha: Bool
        switch cg.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: alpha = true
        default: alpha = false
        }
        var out = ""
        if alpha, let png = image.pngData() {
            out = "data:image/png;base64," + png.base64EncodedString()
        } else if let jpg = image.jpegData(compressionQuality: 0.85) {
            out = "data:image/jpeg;base64," + jpg.base64EncodedString()
        }
        if !out.isEmpty { avatarCache[id] = out }
        return out
    }

    // MARK: - 取数

    /// 算出 tokens 里每一项的值。charId 为空跟随最近聊过的角色（同其他小组件，MoreWidgets.Source.charOf）。
    /// 只读本机：消息、会话、纪念日、记忆、日记、朋友圈、播放器、缓存的天气。不发任何请求，不写任何东西
    @MainActor
    static func resolve(_ tokens: [Token], charId: String, now: Date = Date()) -> Filled {
        var f = Filled()
        guard !tokens.isEmpty else { return f }
        let names = Set(tokens.map(\.name))
        func wants(_ list: [String]) -> Bool { list.contains { names.contains($0) } }

        let active = MoreWidgets.Source.me()
        let ch = MoreWidgets.Source.charOf(charId, me: active?.id ?? "")
        let chat = ch.flatMap { MoreWidgets.Source.chatWith($0.id, me: active?.id ?? "") }
        // 这段会话用的身份；没写或找不到用当前身份（同 ChatEngine）
        var me = active
        if let pid = chat?.personaId, !pid.isEmpty, pid != active?.id {
            me = ((try? Repo.personas()) ?? []).first(where: { $0.id == pid }) ?? active
        }
        let meLabel = me.map { MoreWidgets.meName($0) } ?? "我"
        let chName = ch?.displayName ?? ""

        var all: [Message] = []
        if let chat, wants(["最近一句", "最近几句", "上次聊天", "认识天数"]) {
            all = (try? Repo.messages(chatId: chat.id)) ?? []
        }
        let talk = wants(["最近一句", "最近几句"]) ? MoreWidgets.Calc.talkLines(all, all.count, now: now) : []
        if names.contains("最近几句") {
            let most = tokens.filter { $0.name == "最近几句" }.map { count($0.arg, default: 5) }.max() ?? 5
            f.lines = talk.suffix(most).map { m in
                Line(who: m.role == .user ? meLabel : chName, me: m.role == .user, text: m.content, time: m.createdAt)
            }
        }

        let next: (item: Row, left: Int)? = wants(["纪念日", "纪念日名", "纪念日天数"])
            ? chat.flatMap { c in Space.upcoming(c.id, now: now).first(where: { $0.left >= 0 }) }
            : nil

        for t in tokens {
            let v: String
            switch t.name {
            case "角色名": v = chName
            case "签名": v = ch?.signature ?? ""
            case "角色头像": v = avatarURI(ch?.avatar ?? "")
            case "我的名字": v = MoreWidgets.meName(me)
            case "我的头像": v = avatarURI(me?.avatar ?? "")
            case "最近一句": v = talk.last(where: { $0.role == .char })?.content ?? ""
            case "最近几句": v = recentText(f.lines, count(t.arg, default: 5))
            case "上次聊天": v = agoZH(all.last?.createdAt ?? 0, now: now)
            case "未读": v = String(chat?.unread ?? 0)
            case "在一起天数":
                // 情侣空间里设了起始日按它，否则按这段对话建立的那天（同对望、恋爱日历两个组件）
                if let chat {
                    let love = chat.row.number("loveStartAt") ?? 0
                    let start: Double? = love > 0 ? love : MoreWidgets.Calc.start(since: "", chatCreated: chat.row.created)
                    v = String(MoreWidgets.Calc.daysFrom(start, now: now))
                } else {
                    v = "0"
                }
            case "认识天数":
                if let first = all.first, first.createdAt > 0 {
                    v = String(MoreWidgets.Calc.daysFrom(first.createdAt, now: now))
                } else {
                    v = "0"
                }
            case "纪念日":
                if let next {
                    let title = next.item.string("title")
                    v = next.left == 0 ? "\(title) 今天" : "\(title) 还有 \(next.left) 天"
                } else {
                    v = ""
                }
            case "纪念日名": v = next?.item.string("title") ?? ""
            case "纪念日天数": v = next.map { String($0.left) } ?? ""
            case "最近记忆":
                let list = ch.map { c in (try? Knowledge.memories(charId: c.id, personaId: me?.id ?? "")) ?? [] } ?? []
                v = list.first(where: { m in
                    m.supersededBy.isEmpty && m.fateHidden.isEmpty && !m.content.isEmpty
                        && (m.scopeChat.isEmpty || m.scopeChat == chat?.id)
                })?.content ?? ""
            case "角色日记":
                let d = ch.flatMap { c in ((try? Diary.ofChar(c.id)) ?? []).first }
                if let d, !d.locked {
                    v = String(d.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(count(t.arg, default: 120)))
                } else {
                    v = ""
                }
            case "角色朋友圈": v = ch.flatMap { MoreWidgets.latestMoment($0.id)?.text } ?? ""
            case "正在听":
                let player = MusicPlayer.shared
                let l = MoreWidgets.RecordW.pick(liveChat: player.listenChat, current: player.current, seconds: player.seconds,
                                                 resume: MoreWidgets.RecordW.lastResume())
                v = l?.song?.title ?? ""
            case "角色时间":
                if let ch {
                    let s = AppSettings.load()
                    v = Clock.clockOnly(Clock.now(s, real: now), zone: Clock.charZone(ch, s))
                } else {
                    v = ""
                }
            case "角色天气":
                // 只读排日程时存下的那一份，不去查
                if let ch, let r = try? DayPlan.today(ch), let w = Weather.Forecast(r["weather"]) {
                    v = "\(w.textDay) \(Weather.fmt(w.tempMin))°/\(Weather.fmt(w.tempMax))°"
                } else {
                    v = ""
                }
            default: v = ""
            }
            f.text[t.key] = v
        }
        return f
    }
}
