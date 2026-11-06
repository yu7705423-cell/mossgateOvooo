import XCTest
@testable import Eira

// 小剧场（网页版 4.769）、MCP 工具（4.179、4.973、4.regex-1）、角色自行进出线下（4.721、4.723）、线下的篇幅（4.690）。

final class TheaterParseTests: XCTestCase {
    /// 整段页面摘成一条，不被拆成气泡；封面一行；漏写收尾、紧跟着页面的收到末尾。与网页版 liftTheater 一致
    func testLift() {
        let a = ReplyParser.split("好呀\n[小剧场：咖啡馆点单]\n```html\n<div>菜单</div>\n<button onclick=\"eira.say('点了拿铁')\">拿铁</button>\n```\n[/小剧场]\n看看").parts
        XCTAssertEqual(a.map(\.type), [.text, .theater, .text])
        XCTAssertEqual(a[1].text, "咖啡馆点单")
        XCTAssertEqual(a[1].html, "<div>菜单</div>\n<button onclick=\"eira.say('点了拿铁')\">拿铁</button>")
        let b = ReplyParser.split("[小剧场：保险柜｜你得猜密码]\n就这样").parts
        XCTAssertEqual(b.map(\.type), [.theater, .text])
        XCTAssertEqual(b[0].extra, "你得猜密码")
        XCTAssertEqual(b[0].html, "")
        let c = ReplyParser.split("[小剧场：没收尾]\n<div>a</div>\n<p>b</p>").parts
        XCTAssertEqual(c.map(\.type), [.theater])
        XCTAssertEqual(c[0].html, "<div>a</div>\n<p>b</p>")
        // 角色照着写回来的互动记录不落成气泡
        XCTAssertEqual(ReplyParser.split("[小剧场互动：点了拿铁]\n好").parts.map(\.text), ["好"])
    }

    func testWebMap() {
        let (p, un) = WebLogic.map([["type": "theater", "title": "咖啡馆", "brief": "", "html": "<div>x</div>"],
                                    ["type": "tool", "name": "search", "args": ["q": "a]b", "n": 1], "bad": ""],
                                    ["type": "meet", "place": "咖啡馆"], ["type": "part"]])
        XCTAssertTrue(un.isEmpty)
        XCTAssertEqual(p.map(\.type), [.theater, .tool, .meet, .part])
        XCTAssertEqual(p[0].html, "<div>x</div>")
        XCTAssertEqual(p[1].extra, #"{"n":1,"q":"a]b"}"#)
        XCTAssertNil(p[1].bad)
        XCTAssertEqual(p[2].text, "咖啡馆")
        // 原生的那一份切出来一样
        let n = ReplyParser.split("查一下\n[调用：search {\"q\": \"a]b\", \"n\": 1}]\n[见面：咖啡馆]\n[回到线上]").parts
        XCTAssertEqual(n.map(\.type), [.text, .tool, .meet, .part])
        XCTAssertEqual(n[1].extra, p[1].extra)
    }

    /// 参数里的方括号与换行不截断；参数写坏的记下原文；只写名字的参数为空对象
    func testLiftCalls() {
        let ok = ReplyParser.split("[调用：notes.add {\"text\": \"[1]\\n二\", \"tags\": [\"a\"]}]").parts
        XCTAssertEqual(ok.map(\.type), [.tool])
        XCTAssertEqual(ok[0].text, "notes.add")
        XCTAssertEqual(ok[0].extra, #"{"tags":["a"],"text":"[1]\n二"}"#)
        let bad = ReplyParser.split("[调用：bad {oops}]").parts
        XCTAssertEqual(bad.first?.bad, "{oops}")
        XCTAssertEqual(bad.first?.extra, "{}")
        XCTAssertEqual(ReplyParser.split("[调用：ping]").parts.first?.extra, "{}")
        XCTAssertEqual(ReplyParser.split("[见面]").parts.first?.text, "")
    }

    func testPromptOfAndText() {
        let html = "<style>p{color:red}</style><div><h1>菜单</h1><p>拿铁&nbsp;28</p></div><script>x()</script>"
        XCTAssertEqual(Theater.textOf(html), "菜单\n拿铁 28")
        var t: [String: JSONValue] = ["title": .string("点单"), "html": .string(html), "inject": .string("text"),
                                      "acts": .array([.string("点了拿铁")])]
        XCTAssertEqual(Theater.promptOf(t), "[小剧场：点单]\n菜单\n拿铁 28\n[/小剧场]\n[小剧场互动：点了拿铁]")
        t["inject"] = .string("none")
        XCTAssertEqual(Theater.promptOf(t), "[小剧场：点单]\n[小剧场互动：点了拿铁]")
        t["inject"] = .string("code")
        XCTAssertTrue(Theater.promptOf(t).contains("<script>x()</script>"))
        // 还没生成的封面：主题与梗概
        XCTAssertEqual(Theater.promptOf(["title": .string("保险柜"), "brief": .string("猜密码")]), "[小剧场：保险柜｜猜密码]")
        // 背景音乐那一行一律摘掉
        let bg = Theater.takeBgm("[背景音乐：晴天 - 周杰伦]\n<div>a</div>")
        XCTAssertEqual(bg.text, "<div>a</div>")
        XCTAssertEqual(bg.q, "晴天 - 周杰伦")
        XCTAssertEqual(Theater.pageOf("```html\n<div>b</div>\n```"), "<div>b</div>")
        XCTAssertEqual(Theater.pageOf("[小剧场：x]\n<p>c</p>\n[/小剧场]"), "<p>c</p>")
    }

    /// 盒子：CSP 在最前面，桥只经 eiraTheater 往外报一句；只认主页面
    func testBox() {
        let doc = Theater.docOf("<p>x</p>")
        XCTAssertTrue(doc.hasPrefix("<!DOCTYPE html><meta http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(doc.contains("connect-src 'none'"))
        XCTAssertTrue(doc.contains("messageHandlers.eiraTheater"))
        XCTAssertEqual(Theater.sayOf(["eiraTheater": 1, "say": "点了"], mainFrame: true), "点了")
        XCTAssertNil(Theater.sayOf(["eiraTheater": 1, "say": "点了"], mainFrame: false))
        XCTAssertNil(Theater.sayOf(["say": "点了"], mainFrame: true))
    }
}

final class TheaterFlowTests: MockedChatCase {
    private func feature(_ ids: [String]) throws {
        try setSettings(["featureOpt": .object(Dictionary(uniqueKeysWithValues: ids.map { ($0, JSONValue.string("on")) }))])
    }

    /// 新功能没开：不进提示词，角色碰巧写了也不落成小剧场；开了才落，content 是上下文里的写法
    func testOffThenOn() async throws {
        main = { _ in .init(status: 200, body: MockNet.anthropicStream("看这个\n[小剧场：点单]\n<div>拿铁</div>\n[/小剧场]")) }
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertFalse(try ChatPrompt.build(chat: chat, char: char, settings: .load()).system.contains("[小剧场：title]"))
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertFalse(try Repo.messages(chatId: "chat_a").contains { $0.kind == Theater.kind })
        XCTAssertEqual(MockNet.count, 1)

        try feature(["theater"])
        XCTAssertTrue(try ChatPrompt.build(chat: chat, char: char, settings: .load()).system.contains("[小剧场：title]"))
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let m = try XCTUnwrap(Repo.messages(chatId: "chat_a").last { $0.kind == Theater.kind })
        XCTAssertEqual(m.content, "[小剧场：点单]\n拿铁\n[/小剧场]")
        XCTAssertEqual(MockNet.count, 2)

        // 页面里点了两下（同一句连着报只记一次），历史里一行一条
        XCTAssertTrue(try Theater.act(m.id, "点了拿铁"))
        XCTAssertFalse(try Theater.act(m.id, "点了拿铁"))
        try Theater.setInject(m.id, "none")
        XCTAssertEqual(Theater.message(m.id)?.content, "[小剧场：点单]\n[小剧场互动：点了拿铁]")
        try Theater.clearActs(m.id)
        XCTAssertEqual(Theater.message(m.id)?.content, "[小剧场：点单]")
    }

    /// 打开时生成：角色只写封面；点「开幕」才调一次（副用），失败也只一次；成功后页面落在这一条上
    func testGenerateOnlyWhenOpened() async throws {
        try feature(["theater"])
        try Theater.setCfg("chat_a", ["mode": .string(Theater.separate), "words": .number(300)])
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let sys = try ChatPrompt.build(chat: chat, char: XCTUnwrap(Repo.character("char_a")), settings: .load()).system
        XCTAssertTrue(sys.contains("[小剧场：title｜one-sentence summary]"))
        main = { _ in .init(status: 200, body: MockNet.anthropicStream("[小剧场：保险柜｜猜密码]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let m = try XCTUnwrap(Repo.messages(chatId: "chat_a").last { $0.kind == Theater.kind })
        XCTAssertEqual(MockNet.count, 1, "封面不调接口")
        XCTAssertEqual(m.row["theater"]?["gen"]?.string, Theater.free)

        spare = { _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        do { try await Theater.generate(m.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 2)
        XCTAssertEqual(hosts().last, "spare.test")
        let used = await Usage.shared.today(task: Theater.task)
        XCTAssertEqual(used, 1)
        XCTAssertTrue(body(1).contains("about 300 characters"), "字数只进生成那一次")

        spare = { _ in .init(status: 200, body: MockNet.openaiStream("```html\n<div>密码锁</div>\n```")) }
        try await Theater.generate(m.id)
        XCTAssertEqual(MockNet.count, 3)
        XCTAssertEqual(Theater.message(m.id)?.row["theater"]?["html"]?.string, "<div>密码锁</div>")
    }
}

final class MeetTests: MockedChatCase {
    private func reply(_ text: String) async throws {
        main = { _ in .init(status: 200, body: MockNet.anthropicStream(text)) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
    }

    /// 没开：见面那一行摘掉、不落卡片；开了：落一张卡片，挂着的时候不再落第二张；就在这里 → 面对面；[回到线上] → 回到线上
    func testProposeAndPart() async throws {
        try await reply("好\n[见面：咖啡馆]")
        XCTAssertFalse(try Repo.messages(chatId: "chat_a").contains { $0.kind == Meet.kind })

        try setSettings(["featureOpt": .object(["meet": .string("on")])])
        let sys = try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load()).system
        XCTAssertTrue(sys.contains("[见面：place]"))
        try await reply("好\n[见面：咖啡馆]")
        let card = try XCTUnwrap(Repo.messages(chatId: "chat_a").last { $0.kind == Meet.kind })
        XCTAssertEqual(card.content, "[见面：咖啡馆]")
        try await reply("[见面：公园]")
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").filter { $0.kind == Meet.kind }.count, 1)

        try Meet.decide(card.id, "here")
        XCTAssertTrue(Face.on(try Repo.chat("chat_a")))
        XCTAssertEqual(Face.info(try Repo.chat("chat_a"))["place"]?.string, "咖啡馆")
        let sys2 = try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load()).system
        XCTAssertTrue(sys2.contains("[回到线上]"))
        try await reply("那我先走了\n[回到线上]")
        XCTAssertFalse(Face.on(try Repo.chat("chat_a")))
        XCTAssertEqual(MockNet.count, 4)
    }

    /// 不去：卡片记为未答应，聊天里落一行；单独页面：新建一场线下长文
    func testDeclineAndPage() throws {
        let m = try XCTUnwrap(Meet.propose("chat_a", charId: "char_a", place: "", turnId: "t1"))
        try Repo.append(m)
        XCTAssertFalse(Meet.canPropose("chat_a"))
        try Meet.decide(m.id, "no")
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.content, "[未答应见面]")
        XCTAssertTrue(Meet.canPropose("chat_a"))
        let m2 = try XCTUnwrap(Meet.propose("chat_a", charId: "char_a", place: "海边", turnId: "t2"))
        try Repo.append(m2)
        let sid = try Meet.decide(m2.id, "page")
        XCTAssertEqual(Scenes.get(sid)?.string("place"), "海边")
        XCTAssertEqual(try Meet.decide(m2.id, "here"), "", "选过的不再动")
    }

    /// 线下长文里单独一行 [回到线上]：开着时收场，关着时只摘掉；都不多调接口
    func testSceneEnd() async throws {
        var d = Scenes.Draft()
        d.castIds = ["char_a"]
        let sc = try Scenes.create(chatId: "chat_a", d)
        main = { _ in .init(status: 200, body: MockNet.anthropicStream("他转身走了。\n[回到线上]")) }
        _ = try await SceneRun.writeRound(sceneId: sc.id)
        XCTAssertEqual(Scenes.told(sc.id).last?.string("text"), "他转身走了。")
        XCTAssertEqual(Scenes.get(sc.id)?.number("endedAt") ?? 0, 0)

        try setSettings(["featureOpt": .object(["meet": .string("on")])])
        let built = try ChatPrompt.buildScene(scene: XCTUnwrap(Scenes.get(sc.id)), chat: XCTUnwrap(Repo.chat("chat_a")),
                                              char: XCTUnwrap(Repo.character("char_a")), list: Scenes.beatsOf(sc.id), settings: .load())
        XCTAssertTrue(built.system.contains("To end this scene"))
        let r = try await SceneRun.writeRound(sceneId: sc.id)
        XCTAssertGreaterThan(Scenes.get(sc.id)?.number("endedAt") ?? 0, 0)
        XCTAssertTrue(r.notes.contains { $0.contains("结束了这一场") })
        XCTAssertEqual(MockNet.count, 2)
    }

    /// 删除线下分隔线（4.721）：只是不再显示，那一行照样读成「以下当面」
    func testHideSideLine() throws {
        let line = try XCTUnwrap(Face.enter("chat_a", place: "便利店", at: "", note: ""))
        XCTAssertEqual(MessageActions.slimMenu(line, canRegen: true), ["hideLine"])
        try MessageActions.hideLine(line.id)
        XCTAssertTrue(try XCTUnwrap(Database.shared.get(Collections.messages, id: line.id)).bool("lineHidden"))
        let built = try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertTrue(built.messages.contains { $0.content.contains("便利店") })
    }

    /// 线下的一起听（4.835）：单独一行的 [一起听]、[点歌：…] 从正文里摘掉；没在一起听时不给写法
    func testSceneListenLines() throws {
        let r = SceneRun.takeMusic("他按下播放。\n[点歌：晴天 - 周杰伦]\n[一起听]\n窗外下着雨。")
        XCTAssertEqual(r.text, "他按下播放。\n窗外下着雨。")
        XCTAssertEqual(r.acts.map(\.type), [.pick, .listen])
        XCTAssertEqual(r.acts.first?.text, "晴天 - 周杰伦")
        XCTAssertNil(ChatPrompt.sceneListen(try XCTUnwrap(Repo.character("char_a")), try XCTUnwrap(Repo.chat("chat_a")), .load()))
        MusicListen.setActive("chat_a")
        defer { MusicListen.setActive(nil) }
        XCTAssertNotNil(ChatPrompt.sceneListen(try XCTUnwrap(Repo.character("char_a")), try XCTUnwrap(Repo.chat("chat_a")), .load()))
    }

    /// 篇幅：这一场自己填了的优先，没填用全局那一项，都没填不写
    func testSceneWords() throws {
        var d = Scenes.Draft()
        d.castIds = ["char_a"]
        let sc = try Scenes.create(chatId: "chat_a", d)
        XCTAssertEqual(ChatPrompt.wordsOf(try XCTUnwrap(Scenes.get(sc.id)), .load()), 0)
        try setSettings(["sceneWords": .number(800)])
        XCTAssertEqual(ChatPrompt.wordsOf(try XCTUnwrap(Scenes.get(sc.id)), .load()), 800)
        try Scenes.update(sc.id, ["words": .number(2500)])
        XCTAssertEqual(ChatPrompt.wordsOf(try XCTUnwrap(Scenes.get(sc.id)), .load()), 2500)
        // 篇幅排在聊天记录下面（4.692），在末尾那一条里
        let built = try ChatPrompt.buildScene(scene: XCTUnwrap(Scenes.get(sc.id)), chat: XCTUnwrap(Repo.chat("chat_a")),
                                              char: XCTUnwrap(Repo.character("char_a")), list: [], settings: .load())
        XCTAssertFalse(built.system.contains("2500"))
        XCTAssertTrue(built.messages.contains { $0.content.contains("about 2500 characters") })
    }
}

final class McpParseTests: XCTestCase {
    /// 请求头宽松读（网页版 4.973）：一行一个、JSON、带引号与逗号的行、名称=值
    func testHeaders() {
        XCTAssertEqual(Mcp.parseHeaders("X-Api-Key: abc\nX-Other: 1"), ["X-Api-Key": "abc", "X-Other": "1"])
        XCTAssertEqual(Mcp.parseHeaders(#"{"mcpServers": {"s": {"url": "https://a", "headers": {"Authorization": "Bearer t"}}}}"#), ["Authorization": "Bearer t"])
        XCTAssertEqual(Mcp.parseHeaders(#""Authorization": "Bearer x","#), ["Authorization": "Bearer x"])
        XCTAssertEqual(Mcp.parseHeaders("Authorization=Bearer y"), ["Authorization": "Bearer y"])
        XCTAssertEqual(Mcp.authHeader(name: "", value: "tok"), ["Authorization": "Bearer tok"])
        XCTAssertEqual(Mcp.authHeader(name: "", value: "Basic abc"), ["Authorization": "Basic abc"])
        XCTAssertEqual(Mcp.authHeader(name: "X-Api-Key", value: "k"), ["X-Api-Key": "k"])
        XCTAssertEqual(Mcp.authHeader(name: "", value: "Authorization: Bearer z"), ["Authorization": "Bearer z"])
        XCTAssertEqual(Mcp.authHeader(name: "坏 名字", value: "t"), ["Authorization": "Bearer t"])
        let s = McpServer(json: ["headers": .string("authorization: old\nX-A: 1"), "authValue": .string("new")])
        XCTAssertEqual(Mcp.headersOf(s), ["X-A": "1", "Authorization": "Bearer new"])
        let c = Mcp.parseConfig(#"{"mcpServers": {"notes": {"url": "https://n.test/mcp", "headers": {"X-Key": "1"}}}}"#)
        XCTAssertEqual(c?.name, "notes")
        XCTAssertEqual(c?.url, "https://n.test/mcp")
        XCTAssertEqual(c?.headers, "X-Key: 1")
        XCTAssertNil(Mcp.parseConfig("https://n.test"))
    }

    func testResultText() throws {
        let r = try JSONValue.parse(Data(#"{"content":[{"type":"text","text":"晴"},{"type":"image","mimeType":"image/png"},{"type":"resource_link","name":"doc","uri":"https://d"}]}"#.utf8))
        XCTAssertEqual(Mcp.resultText(r), "晴\n[图片结果：image/png]\n[链接：doc https://d]")
        let s = try JSONValue.parse(Data(#"{"content":[],"structuredContent":{"t":1}}"#.utf8))
        XCTAssertEqual(Mcp.resultText(s), #"{"t":1}"#)
    }
}

final class McpFlowTests: MockedChatCase {
    private var serverId = ""
    private var calls: [String] = []

    /// 假的 Streamable HTTP 服务器：不认新一代的探测（400），握手给会话 id，工具列表、调用的回复走 SSE（前面夹一条通知）
    private func mcp(_ req: URLRequest) -> MockNet.Reply {
        let body = (try? JSONSerialization.jsonObject(with: req.httpBodyStreamData() ?? Data())) as? [String: Any] ?? [:]
        let method = body["method"] as? String ?? ""
        let id = body["id"] as? String ?? ""
        calls.append(method)
        func json(_ result: String, _ extra: [String: String] = [:]) -> MockNet.Reply {
            .init(status: 200, body: #"{"jsonrpc":"2.0","id":"\#(id)","result":\#(result)}"#,
                  headers: ["content-type": "application/json"].merging(extra) { _, n in n })
        }
        switch method {
        case "server/discover": return .init(status: 400, body: "{}")
        case "initialize": return json(#"{"protocolVersion":"2025-06-18","serverInfo":{"name":"notes"}}"#, ["Mcp-Session-Id": "s1"])
        case "notifications/initialized": return .init(status: 202, body: "")
        case "tools/list":
            return json(#"{"tools":[{"name":"echo","description":"Echo back","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}},"annotations":{"readOnlyHint":true}}]}"#)
        case "tools/call":
            let args = (body["params"] as? [String: Any])?["arguments"] as? [String: Any] ?? [:]
            let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n"
                + "data: {\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"echo:\(args["text"] as? String ?? "")\"}]}}\n\n"
            return .init(status: 200, body: sse)
        default: return .init(status: 404, body: "{}")
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        MockNet.reset { [unowned self] req, n in
            if req.url?.host == "mcp.test" { return self.mcp(req) }
            return req.url?.host == "spare.test" ? self.spare(n) : self.main(n)
        }
        serverId = try McpTools.add(name: "笔记", url: "https://mcp.test/mcp")
        try McpTools.update(serverId, ["approve": .string("auto")])
        var c = try XCTUnwrap(Repo.character("char_a"))
        c.row["mcpServers"] = .array([.string(serverId)])
        try Database.shared.put(Collections.characters, c.row)
    }

    private func modelCalls() -> Int { MockNet.requests.filter { $0.url?.host != "mcp.test" }.count }

    private func waitState(_ id: String, not states: Set<String> = ["running", "ask"]) async throws -> Message {
        for _ in 0..<100 {
            if let row = try Database.shared.get(Collections.messages, id: id), !states.contains(row.string("toolState")) { return Message(row: row) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return Message(row: try XCTUnwrap(Database.shared.get(Collections.messages, id: id)))
    }

    /// 连接：新一代探测被拒就退到握手，之后带着会话 id 与协议版本；工具清单存进配置；连接本身不调模型接口
    func testConnectAndPrompt() async throws {
        let r = try await McpTools.refresh(serverId)
        XCTAssertEqual(r.gen, "http")
        XCTAssertEqual(r.tools.map(\.name), ["echo"])
        XCTAssertEqual(calls, ["server/discover", "initialize", "notifications/initialized", "tools/list"])
        let list = MockNet.requests.filter { $0.url?.host == "mcp.test" }
        XCTAssertEqual(list.last?.value(forHTTPHeaderField: "Mcp-Session-Id"), "s1")
        XCTAssertEqual(list.last?.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
        XCTAssertEqual(modelCalls(), 0)
        let sys = try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load()).system
        XCTAssertTrue(sys.contains("- echo: Echo back\n  input: {\"properties\":{\"text\":{\"type\":\"string\"}},\"type\":\"object\"}"))
    }

    /// 角色写一次调用：直接调用的那台当场发出去，结果落在这一条上，下一轮跟在后面进历史。
    /// 接着回复默认关：工具结果回来之后一次模型调用都不多打（第 15 条）
    func testCallFlowNoFollowUpByDefault() async throws {
        _ = try await McpTools.refresh(serverId)
        main = { _ in .init(status: 200, body: MockNet.anthropicStream("我查一下\n[调用：echo {\"text\": \"hi\"}]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let m = try XCTUnwrap(Repo.messages(chatId: "chat_a").last { $0.kind == McpTools.kind })
        let done = try await waitState(m.id)
        XCTAssertEqual(done.row.string("toolState"), "done")
        XCTAssertEqual(done.row.string("toolResult"), "echo:hi")
        XCTAssertEqual(modelCalls(), 1)
        XCTAssertNil(Pace.pending(try XCTUnwrap(Repo.chat("chat_a"))))
        let built = try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertTrue(built.messages.contains { $0.content.contains("[工具结果：echo]\necho:hi") })
    }

    /// 每次确认：停在等待允许，一个请求都不发；拒绝之后记为拒绝。名字对不上的落一条失败
    func testAskDenyAndUnknown() async throws {
        _ = try await McpTools.refresh(serverId)
        try McpTools.update(serverId, ["approve": .string("ask")])
        let before = MockNet.count
        main = { _ in .init(status: 200, body: MockNet.anthropicStream("[调用：echo {\"text\": \"x\"}]\n[调用：nope]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let tools = try Repo.messages(chatId: "chat_a").filter { $0.kind == McpTools.kind }
        XCTAssertEqual(tools.map { $0.row.string("toolState") }, ["ask", "error"])
        XCTAssertTrue(tools[1].row.string("toolError").contains("nope"))
        XCTAssertEqual(MockNet.count, before + 1, "等待允许的不发")
        await MainActor.run { McpTools.deny(tools[0].id) }
        XCTAssertEqual(try Database.shared.get(Collections.messages, id: tools[0].id)?.string("toolState"), "denied")
        XCTAssertEqual(McpTools.resultFor(Message(row: try XCTUnwrap(Database.shared.get(Collections.messages, id: tools[0].id))), .load()),
                       "[工具结果：echo]\nThe user declined this call.")
    }

    /// 开了接着回复：这一轮的调用都有了结果才排一次，从你上一条消息往后超过设定的轮数就不排
    func testFollowUpWhenOn() async throws {
        _ = try await McpTools.refresh(serverId)
        try setSettings(["mcpFollowUp": .bool(true), "mcpFollowMax": .number(1)])
        XCTAssertTrue(ExtraCalls.active(.load()).contains { $0.id == "mcpFollowUp" })
        main = { _ in .init(status: 200, body: MockNet.anthropicStream("[调用：echo {\"text\": \"a\"}]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        let m = try XCTUnwrap(Repo.messages(chatId: "chat_a").last { $0.kind == McpTools.kind })
        _ = try await waitState(m.id)
        for _ in 0..<40 where Pace.pending(try XCTUnwrap(Repo.chat("chat_a"))) == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNotNil(Pace.pending(try XCTUnwrap(Repo.chat("chat_a"))))
        // 第二轮调用之后已经超过一轮：不再排
        try Pace.clear("chat_a")
        var second = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "[调用：echo {}]", kind: McpTools.kind, turnId: "turn_two")
        second.row["toolState"] = .string("done")
        try Repo.append(second)
        XCTAssertFalse(McpTools.followUp("chat_a", turnId: "turn_two"))
    }
}
