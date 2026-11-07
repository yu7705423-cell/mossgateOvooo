import Foundation
import JavaScriptCore

/// 试点（docs/jscore-pilot.md）：在 JavaScriptCore 里直接跑网页版自己的回复解析（reply.js 的 splitReply）。
///
/// 脚本是 `Resources/weblogic/shims.js` 与 `reply.bundle.js`，由 `node scripts/sync-weblogic.mjs <网页版仓库目录>`
/// 从网页版源码打出来，随 app 一起打包，**从不联网下载**（App Store 审核 2.5.2）。
///
/// 现在只是一条开发用的路：正式的解析仍是 `ReplyParser.split`，这里没有接进 `ChatEngine`，也没有设置项。
/// 测试（WebLogicTests）拿同一批样本对照两边的结果、量两边的耗时。
///
/// 线程：一个 JSContext，第一次用时在自己的串行队列上建好，之后所有调用都在那条队列上排队。
/// 出错（脚本缺失、加载抛异常、解析抛异常）记进诊断记录并返回 nil，不抛到调用方。
final class WebLogic: @unchecked Sendable {
    static let shared = WebLogic()

    private let queue = DispatchQueue(label: "cn.eiraphone.weblogic")
    // 以下几项只在 queue 上读写
    private var context: JSContext?
    private var parseFn: JSValue?
    private var loadTried = false
    private var lastErrorStorage: String?
    private var errorCount = 0
    private var loadSecondsStorage: Double = 0

    /// 最近一次出错的说明（加载或解析）。没出过错是 nil
    var lastError: String? { queue.sync { lastErrorStorage } }
    /// 建 JSContext 并执行两份脚本用了几秒（第一次调用时才有）
    var loadSeconds: Double { queue.sync { loadSecondsStorage } }

    struct Output {
        var result: ReplyParser.Result
        /// 网页版切出来、原生 PartType 里没有对应种类的那几条（网页版的 type 名），按出现顺序
        var unmapped: [String]
        /// 网页版原样的结果，一条一个字典
        var raw: [[String: Any]]
    }

    // MARK: - 入口

    /// 网页版 splitReply 的结果，换成原生 `ReplyParser.Result`。autoSplitAt 为 nil 时用网页版默认设置（40）
    static func parseReply(_ raw: String, autoSplitAt: Int? = nil) -> ReplyParser.Result? {
        shared.parse(raw, autoSplitAt: autoSplitAt)?.result
    }

    func parse(_ raw: String, autoSplitAt: Int? = nil) -> Output? {
        queue.sync {
            guard let fn = loadLocked() else { return nil }
            var opts: [String: Any] = [:]
            if let n = autoSplitAt { opts["settings"] = ["autoSplitAt": n] }
            let optsJSON = (try? JSONSerialization.data(withJSONObject: opts)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            guard let out = fn.call(withArguments: [raw, optsJSON]), out.isString, let text = out.toString() else {
                fail("parseReply 没有返回字符串")
                return nil
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                fail("parseReply 返回的不是 JSON")
                return nil
            }
            guard obj["ok"] as? Bool == true, let list = obj["parts"] as? [[String: Any]] else {
                fail("parseReply 出错：\(obj["error"] as? String ?? "未知")")
                return nil
            }
            let (parts, unmapped) = Self.map(list)
            let stamp = list.first?["stamp"] as? String
            return Output(result: ReplyParser.Result(parts: parts, think: obj["think"] as? String ?? "", stamp: stamp),
                          unmapped: unmapped, raw: list)
        }
    }

    /// 打包时记下的网页版提交号
    var webCommit: String? {
        queue.sync {
            guard loadLocked() != nil else { return nil }
            return context?.evaluateScript("weblogic.commit()")?.toString()
        }
    }

    // MARK: - 加载

    private static func scriptURL(_ name: String) -> URL? {
        // XcodeGen 把 Resources 下的子目录收成组，文件平铺在包的根上；两种位置都找一遍
        for bundle in [Bundle.main, Bundle(for: WebLogic.self)] {
            if let u = bundle.url(forResource: name, withExtension: "js", subdirectory: "weblogic")
                ?? bundle.url(forResource: name, withExtension: "js") { return u }
        }
        return nil
    }

    /// 在 queue 上调用
    private func loadLocked() -> JSValue? {
        if let fn = parseFn { return fn }
        if loadTried { return nil }
        loadTried = true
        let start = Date()
        // JSContext 的 init 导进 Swift 是 init!，先落成 Optional 再拆，两种导入方式都编得过
        let made: JSContext? = JSContext()
        guard let ctx = made else { fail("建不出 JSContext"); return nil }
        ctx.name = "weblogic"
        ctx.exceptionHandler = { [weak self] _, exc in
            // 在 queue 上（evaluateScript / call 都是同步的）
            self?.fail("脚本异常：\(exc?.toString() ?? "未知")")
        }
        for name in ["shims", "reply.bundle"] {
            guard let url = Self.scriptURL(name), let src = try? String(contentsOf: url, encoding: .utf8) else {
                fail("找不到 \(name).js")
                return nil
            }
            let before = errorCount
            ctx.evaluateScript(src, withSourceURL: url)
            if errorCount != before { return nil }
        }
        guard let fn = ctx.objectForKeyedSubscript("weblogic")?.objectForKeyedSubscript("parseReply"),
              !fn.isUndefined else {
            fail("脚本里没有 weblogic.parseReply")
            return nil
        }
        context = ctx
        parseFn = fn
        loadSecondsStorage = Date().timeIntervalSince(start)
        return fn
    }

    private func fail(_ message: String) {
        lastErrorStorage = message
        errorCount += 1
        Diagnostics.shared.record("weblogic-failed", ["error": message])
    }

    // MARK: - 网页版结果换成原生的 Part

    /// 字段对应照 ReplyParser 里每一种的注释。原生没有的种类不落成 Part，名字记进 unmapped（原生那边对这些是认出来吞掉）
    static func map(_ list: [[String: Any]]) -> ([ReplyParser.Part], [String]) {
        var parts: [ReplyParser.Part] = []
        var unmapped: [String] = []
        for d in list {
            let type = d["type"] as? String ?? ""
            func s(_ k: String) -> String? { d[k] as? String }
            func str(_ k: String) -> String { s(k) ?? "" }
            func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
            func bool(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }
            func nonEmpty(_ v: String?) -> String? { (v?.isEmpty ?? true) ? nil : v }

            var p: ReplyParser.Part
            switch type {
            case "text": p = .init(type: .text, text: str("text"))
            case "image": p = .init(type: .image, text: str("prompt"))
            case "clip": p = .init(type: .clip, text: str("prompt"))
            case "voice": p = .init(type: .voice, text: str("text"))
            case "sticker": p = .init(type: .sticker, text: str("name"))
            case "location": p = .init(type: .location, text: str("place")); p.address = nonEmpty(s("address"))
            case "narration": p = .init(type: .narration, text: str("text"))
            case "dice": p = .init(type: .dice, text: "")
            case "silence": p = .init(type: .silence, text: "")
            case "transfer": p = .init(type: .transfer, text: str("note")); p.amount = num("amount"); p.to = nonEmpty(s("to"))
            case "gift": p = .init(type: .gift, text: str("cover")); p.extra = s("inner")
            case "settle": p = .init(type: .settle, text: ""); p.flag = bool("take")
            case "unwrap": p = .init(type: .unwrap, text: ""); p.flag = bool("open")
            case "pat": p = .init(type: .pat, text: "")
            case "react": p = .init(type: .react, text: str("e")); p.extra = s("quote")
            case "remark": p = .init(type: .remark, text: str("name"))
            case "takeout": p = .init(type: .takeout, text: str("item")); p.amount = num("amount"); p.extra = s("kind")
            case "meal": p = .init(type: .meal, text: ""); p.flag = bool("take")
            case "agenda": p = .init(type: .agenda, text: str("title")); p.flag = s("state") == "done"
            case "listen": p = .init(type: .listen, text: "")
            case "pick": p = .init(type: .pick, text: str("name"))
            case "song": p = .init(type: .song, text: str("query"))
            case "newlist":
                p = .init(type: .newlist, text: str("name"))
                p.extra = (d["songs"] as? [String] ?? []).joined(separator: "；")
            case "dm": p = .init(type: .dm, text: str("text"))
            case "recall-post": p = .init(type: .recallPost, text: "")
            case "tie": p = .init(type: .tie, text: str("name")); p.extra = s("kind")
            case "pact": p = .init(type: .pact, text: str("title"))
            case "pactdone": p = .init(type: .pactDone, text: str("title"))
            case "letter": p = .init(type: .letter, text: str("text")); p.extra = s("title")
            case "keep": p = .init(type: .keep, text: str("note"))
            case "lockcode": p = .init(type: .lockcode, text: str("code")); p.extra = s("why")
            case "ring": p = .init(type: .ring, text: ""); p.flag = bool("video")
            case "draft": p = .init(type: .draft, text: str("body"))
            case "card": p = .init(type: .card, text: str("name")); p.extra = s("body")
            case "award": p = .init(type: .award, text: str("name")); p.extra = s("reason")
            case "mute": p = .init(type: .mute, text: str("name")); p.amount = num("minutes")
            case "unmute": p = .init(type: .unmute, text: str("name"))
            case "muteall": p = .init(type: .muteAll, text: ""); p.flag = bool("on")
            case "nick": p = .init(type: .nick, text: str("name")); p.extra = s("nick")
            case "wear": p = .init(type: .wear, text: str("name"))
            case "todo": p = .init(type: .todo, text: str("text"))
            case "redpacket":
                p = .init(type: .redpacket, text: str("note")); p.amount = num("total")
                p.count = num("count").map { Int($0.rounded()) }; p.extra = s("rtype"); p.to = nonEmpty(s("to"))
            case "rpclaim": p = .init(type: .rpclaim, text: str("from"))
            case "leave": p = .init(type: .leave, text: "")
            case "selfnick": p = .init(type: .selfnick, text: str("name"))
            case "shot": p = .init(type: .shot, text: str("raw"))
            case "sendshot": p = .init(type: .sendshot, text: str("query"))
            case "theater":
                p = .init(type: .theater, text: str("title")); p.extra = s("brief"); p.html = s("html")
            case "tool":
                p = .init(type: .tool, text: str("name"))
                p.extra = ReplyParser.argsText(d["args"] as? [String: Any] ?? [:])
                p.bad = nonEmpty(s("bad"))
            case "meet": p = .init(type: .meet, text: str("place"))
            case "part": p = .init(type: .part, text: "")
            case "playback": p = .init(type: .playback, text: str("act")); p.extra = s("to")
            case "request": p = .init(type: .request, text: str("note")); p.amount = num("amount"); p.extra = s("kind")
            case "vote": p = .init(type: .vote, text: ""); p.flag = bool("ok")
            case "funcard-give":
                p = .init(type: .funGive, text: str("name"))
                p.info = ["name": str("name"), "desc": str("desc"), "uses": WalletCards.numText(num("uses") ?? 0),
                          "days": WalletCards.numText(num("days") ?? 0), "until": WalletCards.numText(num("until") ?? 0), "confirm": bool("confirm") ? "1" : ""]
            case "funcard-use": p = .init(type: .funUse, text: str("name"))
            case "funcard-vote": p = .init(type: .funVote, text: ""); p.flag = bool("ok")
            case "pass-give":
                p = .init(type: .passGive, text: str("name"))
                p.info = ["kind": str("kind"), "name": str("name"), "place": str("place"), "note": str("note")]
            case "pass-act":
                p = .init(type: .passAct, text: str("name"))
                p.info = ["act": str("act"), "kind": str("kind"), "name": str("name")]
            case "ticket-give":
                p = .init(type: .ticketGive, text: str("title"))
                p.info = ["title": str("title"), "when": str("when"), "venue": str("venue"), "seat": str("seat")]
            case "ticket-check": p = .init(type: .ticketCheck, text: str("title"))
            case "member-open":
                p = .init(type: .memberOpen, text: str("shop"))
                p.info = ["shop": str("shop"), "note": str("note")]
            case "member-visit":
                p = .init(type: .memberVisit, text: str("shop"))
                p.info = ["shop": str("shop"), "points": WalletCards.numText(num("points") ?? 0), "note": str("note")]
            default:
                unmapped.append(type)
                continue
            }
            // 每一种都可能带的：引用（回应的 quote 是摘录，上面已经放进 extra）、撤回、译文、心声
            if type != "react" { p.quote = s("quote") }
            p.recall = bool("recall")
            if type == "text" || type == "voice" || type == "narration" { p.translation = s("translation") }
            if type == "text" { p.inner = s("inner"); p.innerTrans = s("innerTrans") }
            parts.append(p)
        }
        return (parts, unmapped)
    }

    // MARK: - 对照（开发用）

    /// 同一句交给原生 ReplyParser 与网页版，返回不一致的地方（空表示一致）。只比原生 Part 里有的字段
    static func compareWithNative(_ raw: String, autoSplitAt: Int = 40) -> [String] {
        let native = ReplyParser.split(raw, autoSplitAt: autoSplitAt)
        guard let web = shared.parse(raw, autoSplitAt: autoSplitAt) else {
            return ["网页版解析失败：\(shared.lastError ?? "未知")"]
        }
        var out: [String] = []
        let a = native.parts.map(normalized), b = web.result.parts.map(normalized)
        if a != b {
            out.append("条目不同\n  原生：\(a.map(describe))\n  网页：\(b.map(describe))")
        }
        if !web.unmapped.isEmpty {
            out.append("网页版另有原生没有的种类：\(web.unmapped.joined(separator: "、"))")
        }
        if native.think != web.result.think {
            out.append("思考段不同：原生 \(native.think.debugDescription)，网页 \(web.result.think.debugDescription)")
        }
        // 原生记的是整个标记（[时间：…]），网页版记的是里面的时间：只比有没有
        if (native.stamp == nil) != (web.result.stamp == nil) {
            out.append("时间戳有无不同：原生 \(native.stamp ?? "无")，网页 \(web.result.stamp ?? "无")")
        }
        return out
    }

    /// 歌单的几首：原生存的是竖线后面那一段原文，网页版是拆好的数组。比较前都拆开再用「；」接回去
    private static func normalized(_ p: ReplyParser.Part) -> ReplyParser.Part {
        var p = p
        if p.type == .newlist, let e = p.extra {
            p.extra = e.components(separatedBy: CharacterSet(charactersIn: "；;\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "；")
        }
        if p.extra?.isEmpty == true { p.extra = nil }
        return p
    }

    static func describe(_ p: ReplyParser.Part) -> String {
        var s = "\(p.type.rawValue)(\(p.text.debugDescription)"
        if let v = p.translation { s += " 译=\(v.debugDescription)" }
        if let v = p.inner { s += " 心声=\(v.debugDescription)" }
        if let v = p.innerTrans { s += " 心声译=\(v.debugDescription)" }
        if let v = p.quote { s += " 引=\(v.debugDescription)" }
        if p.recall { s += " 撤回" }
        if let v = p.address { s += " 址=\(v.debugDescription)" }
        if let v = p.amount { s += " 数=\(v)" }
        if let v = p.extra { s += " 附=\(v.debugDescription)" }
        if let v = p.to { s += " 给=\(v.debugDescription)" }
        if let v = p.count { s += " 个=\(v)" }
        if p.flag { s += " 真" }
        if let v = p.info { s += " 段=" + v.keys.sorted().map { "\($0):\(v[$0] ?? "")" }.joined(separator: ",") }
        return s + ")"
    }
}
