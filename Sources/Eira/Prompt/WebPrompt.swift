import Foundation
import JavaScriptCore

/// 试点（docs/jscore-prompt.md）：一对一聊天的请求由网页版自己的代码拼（engine.js 的 buildChatSystem 与 buildHistory、
/// context/*、capabilities.js、layout.js……），在 JavaScriptCore 里跑。原生 `ChatPrompt` 照旧在，是默认的那一条路。
///
/// 脚本是 `Resources/weblogic/shims.js`、`prompt-host.js` 与 `prompt.bundle.js`。最后那一份由
/// `node scripts/sync-weblogic.mjs <网页版仓库目录> prompt` 从网页版源码打出来，随 app 一起打包，**从不联网下载**
/// （App Store 审核 2.5.2），不进本仓库（网页版仓库私密）。没有它时这里一律返回 nil，走原生。
///
/// 存储：网页版的 IndexedDB 那一层换成内存表。每拼一次，先从原生库把各数据域的原文（一行一条的 JSON，本来就是网页版的格式）
/// 原样交进去，网页版的 db/index.js、collection.js 照它自己的写法读。拼装途中网页版想写的（标头像已看过之类）
/// **一律不落盘**，记在 `Output.writes` 里。
///
/// 开关：`isOn`，存在原生自己的 native_meta 里（不进备份、不写进网页版的设置），默认关。
/// 只有 `ChatEngine` 的一对一回复会换用它（`replacing`）；通话、主动发消息、群聊、线下照旧走原生。
///
/// 线程：一个 JSContext，第一次用时在自己的串行队列上建好，之后所有调用都在那条队列上排队。
/// 出错（脚本缺失、加载抛异常、拼装抛异常）记进诊断记录并返回 nil，不抛到调用方。
final class WebPrompt: @unchecked Sendable {
    static let shared = WebPrompt()

    // MARK: - 开关

    static let metaKey = "webPrompt"

    /// 「按网页版拼装提示词」开着没有。默认关
    static var isOn: Bool { (try? Database.shared.nativeMeta(metaKey)) == "on" }

    static func setOn(_ on: Bool) throws {
        try Database.shared.setNativeMeta(metaKey, on ? "on" : nil)
    }

    /// 这一版 app 里有没有网页版的拼装脚本（编译时没取到网页版代码就没有）
    static var available: Bool { scriptURL("prompt.bundle") != nil }

    // MARK: - 灌表的规则

    /// 这段会话的消息最多交进去几条（最近的）。网页版自己是整段都在内存里；整段十万条每拼一次都交一遍太慢，
    /// 这里取最近的这么多。历史窗口、引用、待处理的转账都在这一截里；更早的只有「整段里才查得出来」的几件事会看不到
    static let chatRows = 5000
    /// 同一个角色的别的会话（私聊与群聊互通、小号那几块读它们最近的几句）各交最近几条
    static let otherChatRows = 300

    // MARK: - 结果

    struct Timing: Sendable {
        /// 从原生库读出各表的原文（秒）
        var read: Double = 0
        /// 交进 JSContext（JSON.parse 那一步，秒）
        var feed: Double = 0
        /// 网页版内存镜像换表（秒，JS 里量的）
        var refill: Double = 0
        /// 拼装本身（秒，JS 里量的）
        var build: Double = 0
        /// 从读库到拿到结果（秒）
        var total: Double = 0
        /// 交进去的原文一共多少字节、多少行
        var bytes = 0
        var rows = 0
    }

    struct Output: Sendable {
        var system: String
        var messages: [AIMessage]
        /// 这一轮召回的记忆 id（网页版 recall 的结果）
        var recalled: [String]
        /// 网页版里构建失败的区块 id（各块单独 try/catch，失败的不进提示词）
        var failed: [String]
        /// 拼装途中网页版想写、这里没有落盘的：「put chats chat_a」
        var writes: [String]
        /// 调到的存根（不在包里的模块）。正常应为空
        var stubHits: [String]
        /// 网页版的 console 输出
        var logs: [String]
        /// 拼装途中读过的数据域
        var touched: [String]
        var timing: Timing
        /// 打包时网页版的提交号
        var commit: String
    }

    // MARK: - 状态（只在 queue 上读写）

    private let queue = DispatchQueue(label: "cn.eiraphone.webprompt")
    private var context: JSContext?
    private var api: JSValue?
    private var loadTried = false
    private var lastErrorStorage: String?
    private var errorCount = 0
    private var loadSecondsStorage: Double = 0

    /// 最近一次出错的说明。没出过错是 nil
    var lastError: String? { queue.sync { lastErrorStorage } }
    /// 建 JSContext 并执行三份脚本用了几秒（第一次拼装时才有）
    var loadSeconds: Double { queue.sync { loadSecondsStorage } }

    // MARK: - 接进 ChatEngine

    /// 开关开着、脚本在、这一轮不用把原图交给模型时，换成网页版拼的那一份；否则原样返回 nil（调用方照旧用原生的）。
    /// 原图那一档由原生挂在 AIMessage.images 上（网页版的 imagesFor 读的是浏览器里的图），这一轮有图就不换
    static func replacing(_ native: ChatPrompt.Built, chat: Chat, char: Character, excludeTurn: String?) -> ChatPrompt.Built? {
        guard isOn, available else { return nil }
        guard native.seenImages.isEmpty else {
            Diagnostics.shared.record("webprompt-skipped", ["why": "images"])
            return nil
        }
        guard let out = shared.build(chat: chat, char: char, excludeTurn: excludeTurn) else { return nil }
        Diagnostics.shared.record("webprompt-used", [
            "ms": Int((out.timing.total * 1000).rounded()), "bytes": out.timing.bytes,
            "failed": out.failed.joined(separator: ","), "writes": out.writes.count, "stubs": out.stubHits.count,
        ])
        return ChatPrompt.Built(system: out.system, messages: out.messages, recalled: out.recalled, seenImages: [])
    }

    // MARK: - 拼装

    /// now：钉住拼装时的「此刻」（对照测试用）；nil 用真实时间
    func build(chat: Chat, char: Character, excludeTurn: String? = nil, now: Date? = nil) -> Output? {
        let start = Date()
        let feed: Feed
        do { feed = try Self.read(chat: chat, char: char) } catch {
            queue.sync { fail("读本地库失败：\(error.localizedDescription)") }
            return nil
        }
        let readSeconds = Date().timeIntervalSince(start)
        return queue.sync { () -> Output? in
            guard let api = loadLocked() else { return nil }
            let t0 = Date()
            let before = errorCount
            let nowArg: Any = now.map { NSNumber(value: $0.timeIntervalSince1970 * 1000) as Any } ?? NSNull()
            api.invokeMethod("reset", withArguments: [nowArg])
            for (name, json) in feed.tables { api.invokeMethod("table", withArguments: [name, json]) }
            for (key, json) in feed.kv { api.invokeMethod("kv", withArguments: [key, json]) }
            if errorCount != before { return nil }
            let feedSeconds = Date().timeIntervalSince(t0)

            var req: [String: Any] = ["chatId": chat.id, "charId": char.id]
            if let excludeTurn { req["excludeTurn"] = excludeTurn }
            guard let reqData = try? JSONSerialization.data(withJSONObject: req) else { fail("请求拼不成 JSON"); return nil }
            api.invokeMethod("buildChat", withArguments: [String(decoding: reqData, as: UTF8.self)])
            // JSContext 在每次从宿主调进去的那一下返回之前把微任务（Promise）跑完；万一没跑完，再进出一次
            var text = Self.string(api.invokeMethod("output", withArguments: []))
            if text == nil {
                context?.evaluateScript("void 0")
                text = Self.string(api.invokeMethod("output", withArguments: []))
            }
            if errorCount != before { return nil }
            guard let text else { fail("拼装没有结束（多半在等一个定时器或网络）"); return nil }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                fail("拼装返回的不是 JSON"); return nil
            }
            guard obj["ok"] as? Bool == true else {
                fail("拼装出错：\(obj["error"] as? String ?? "未知")"); return nil
            }
            var messages: [AIMessage] = []
            for m in obj["messages"] as? [[String: Any]] ?? [] {
                guard let role = AIMessage.Role(rawValue: m["role"] as? String ?? "") else {
                    fail("认不出的消息身份：\(m["role"] as? String ?? "")"); return nil
                }
                messages.append(AIMessage(role: role, content: m["content"] as? String ?? ""))
            }
            let ms = obj["ms"] as? [String: Any] ?? [:]
            let timing = Timing(read: readSeconds, feed: feedSeconds,
                                refill: ((ms["refill"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                                build: ((ms["build"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                                total: Date().timeIntervalSince(start), bytes: feed.bytes, rows: feed.rows)
            let writes = (obj["writes"] as? [[String: Any]] ?? []).map {
                "\($0["op"] as? String ?? "") \($0["store"] as? String ?? "") \($0["id"] as? String ?? "")"
            }
            return Output(system: obj["system"] as? String ?? "", messages: messages,
                          recalled: obj["recalled"] as? [String] ?? [], failed: obj["failed"] as? [String] ?? [],
                          writes: writes, stubHits: obj["stubHits"] as? [String] ?? [], logs: obj["logs"] as? [String] ?? [],
                          touched: obj["touched"] as? [String] ?? [], timing: timing, commit: obj["commit"] as? String ?? "")
        }
    }

    /// 打包时记下的网页版提交号
    var webCommit: String? {
        queue.sync {
            guard loadLocked() != nil else { return nil }
            return context?.evaluateScript("__wl.commit")?.toString()
        }
    }

    // MARK: - 从原生库读

    struct Feed {
        /// 数据域 -> JSON 数组原文
        var tables: [(String, String)] = []
        /// kv 键 -> JSON 原文
        var kv: [(String, String)] = []
        var bytes = 0
        var rows = 0
    }

    /// 各数据域的全部行原样交进去（消息除外，见 chatRows）；kv 交 settings、persona、layout
    static func read(chat: Chat, char: Character) throws -> Feed {
        let db = Database.shared
        var feed = Feed()
        func add(_ name: String, _ rows: [Data]) {
            var d = Data("[".utf8)
            for (i, r) in rows.enumerated() {
                if i > 0 { d.append(0x2C) }
                d.append(r)
            }
            d.append(0x5D)
            feed.bytes += d.count
            feed.rows += rows.count
            feed.tables.append((name, String(decoding: d, as: UTF8.self)))
        }
        var chatRows: [Data] = []
        for name in try db.collections() where name != Collections.messages {
            let rows = try db.rawRows(name)
            if name == Collections.chats { chatRows = rows }
            add(name, rows)
        }
        // 消息：这段会话最近 chatRows 条，同一个角色的别的会话各最近 otherChatRows 条
        var msgs = try db.rawLast(Collections.messages, where: chat.id, limit: chatRows)
        for raw in chatRows {
            guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  let id = o["id"] as? String, id != chat.id,
                  (o["characterIds"] as? [String] ?? []).contains(char.id) else { continue }
            msgs += try db.rawLast(Collections.messages, where: id, limit: otherChatRows)
        }
        add(Collections.messages, msgs)
        for key in [KVKey.settings, KVKey.persona, KVKey.layout] {
            guard let v = try db.kv(key) else { continue }
            let data = try v.encoded()
            feed.bytes += data.count
            feed.kv.append((key, String(decoding: data, as: UTF8.self)))
        }
        return feed
    }

    // MARK: - 加载

    private static func scriptURL(_ name: String) -> URL? {
        // XcodeGen 把 Resources 下的子目录收成组，文件平铺在包的根上；两种位置都找一遍
        for bundle in [Bundle.main, Bundle(for: WebPrompt.self)] {
            if let u = bundle.url(forResource: name, withExtension: "js", subdirectory: "weblogic")
                ?? bundle.url(forResource: name, withExtension: "js") { return u }
        }
        return nil
    }

    private static func string(_ v: JSValue?) -> String? {
        guard let v, v.isString else { return nil }
        return v.toString()
    }

    /// 在 queue 上调用
    private func loadLocked() -> JSValue? {
        if let ready = api { return ready }
        if loadTried { return nil }
        loadTried = true
        let start = Date()
        // JSContext 的 init 导进 Swift 是 init!，先落成 Optional 再拆，两种导入方式都编得过
        let made: JSContext? = JSContext()
        guard let ctx = made else { fail("建不出 JSContext"); return nil }
        ctx.name = "webprompt"
        ctx.exceptionHandler = { [weak self] _, exc in
            // 在 queue 上（evaluateScript / invokeMethod 都是同步的）
            self?.fail("脚本异常：\(exc?.toString() ?? "未知")")
        }
        for name in ["shims", "prompt-host", "prompt.bundle"] {
            guard let url = Self.scriptURL(name), let src = try? String(contentsOf: url, encoding: .utf8) else {
                fail("找不到 \(name).js")
                return nil
            }
            let before = errorCount
            ctx.evaluateScript(src, withSourceURL: url)
            if errorCount != before { return nil }
        }
        guard let api = ctx.objectForKeyedSubscript("weblogic")?.objectForKeyedSubscript("prompt"), !api.isUndefined else {
            fail("脚本里没有 weblogic.prompt")
            return nil
        }
        context = ctx
        self.api = api
        loadSecondsStorage = Date().timeIntervalSince(start)
        return api
    }

    private func fail(_ message: String) {
        lastErrorStorage = message
        errorCount += 1
        Diagnostics.shared.record("webprompt-failed", ["error": message])
    }

    // MARK: - 对照（开发用）

    /// 两份提示词按段对照：设定区按「空行 + [抬头]」切段，聊天记录逐条比。返回不一致的地方（空表示一致）
    static func compare(native: ChatPrompt.Built, web: Output) -> [String] {
        var out: [String] = []
        let a = sections(native.system), b = sections(web.system)
        let onlyNative = a.filter { x in !b.contains(x) }, onlyWeb = b.filter { x in !a.contains(x) }
        for s in onlyNative { out.append("设定区只有原生有：\(head(s))\n\(s)") }
        for s in onlyWeb { out.append("设定区只有网页版有：\(head(s))\n\(s)") }
        if onlyNative.isEmpty && onlyWeb.isEmpty && a != b {
            out.append("设定区各段相同、先后不同\n  原生：\(a.map(head))\n  网页：\(b.map(head))")
        }
        if native.messages.count != web.messages.count {
            out.append("聊天记录条数不同：原生 \(native.messages.count)，网页 \(web.messages.count)")
        }
        for (i, (x, y)) in zip(native.messages, web.messages).enumerated() where x.role != y.role || x.content != y.content {
            out.append("第 \(i + 1) 条不同\n  原生（\(x.role.rawValue)）：\(x.content.debugDescription)\n  网页（\(y.role.rawValue)）：\(y.content.debugDescription)")
        }
        if Set(native.recalled) != Set(web.recalled) {
            out.append("召回不同：原生 \(native.recalled)，网页 \(web.recalled)")
        }
        return out
    }

    /// 设定区按段切开：每段以单独一行的 `[抬头]` 开始（开场那一段没有抬头）
    static func sections(_ text: String) -> [String] {
        var out: [String] = []
        var cur: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("["), line.hasSuffix("]"), !line.contains("："), let prev = cur.last, prev.isEmpty {
                let s = cur.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(s) }
                cur = []
            }
            cur.append(line)
        }
        let s = cur.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }
        return out
    }

    private static func head(_ s: String) -> String {
        String(s.split(separator: "\n", maxSplits: 1).first ?? "")
    }
}
