import Foundation

/// 角色那一侧的 MCP（网页版 system/mcptools.js，ARCHITECTURE 4.179、4.180）：它能用哪些工具、写出来的名字对应哪台服务器的哪个工具、
/// 调之前要不要先问你、调完之后要不要接着回复。连接与协议在 AI/Mcp.swift，这里只管「角色」与「会话」。
///
/// 一次调用落成一条消息（kind 为 tool），状态走：ask 等你允许 / running 正在调 / done 拿到结果（toolResult）/
/// error 失败（toolError）/ denied 你拒绝了。结果以「[工具结果：名字]」跟在那条调用后面进历史，角色下一次回复时读得到。
/// 配置在 settings.services.mcp.servers（与网页版同一份，备份时与接口密钥同样处理）；哪个角色能用哪几台在角色卡上勾（char.mcpServers）。
enum McpTools {
    static let kind = "tool"
    static let stateText = ["ask": "等待允许", "running": "正在调用", "done": "已完成", "error": "失败", "denied": "已拒绝"]

    // MARK: - 服务器配置

    static func servers(_ s: AppSettings = .load()) -> [McpServer] {
        (s.services["mcp"]?["servers"]?.array ?? []).compactMap { $0.object.map(McpServer.init(json:)) }.filter { !$0.id.isEmpty }
    }

    static func server(_ id: String, _ s: AppSettings = .load()) -> McpServer? { servers(s).first { $0.id == id } }

    private static func write(_ change: (inout [[String: JSONValue]]) -> Void) throws {
        var s = try AppSettings.loadForWrite()
        var list = (s.services["mcp"]?["servers"]?.array ?? []).compactMap(\.object)
        change(&list)
        var mcp = s.services["mcp"]?.object ?? [:]
        mcp["servers"] = .array(list.map { .object($0) })
        var all = s.services
        all["mcp"] = .object(mcp)
        s.raw["services"] = .object(all)
        try s.save()
        Task { @MainActor in SettingsModel.shared.reload() }
    }

    /// 新加一台（网页版 newMcpServer 的默认值）。回新的 id
    @discardableResult
    static func add(name: String = "", url: String = "", headers: String = "") throws -> String {
        let id = Ids.make("mcp")
        let n = servers().count + 1
        try write { $0.append([
            "id": .string(id), "name": .string(name.isEmpty ? "服务器 \(n)" : name), "url": .string(url), "headers": .string(headers),
            "authName": .string(""), "authValue": .string(""), "timeout": .number(60), "approve": .string("ask"),
            "toolsOff": .array([]), "tools": .array([]), "error": .string(""), "checkedAt": .number(0),
        ]) }
        return id
    }

    static func update(_ id: String, _ patch: [String: JSONValue]) throws {
        try write { list in
            guard let i = list.firstIndex(where: { $0["id"]?.string == id }) else { return }
            for (k, v) in patch { list[i][k] = v }
        }
    }

    static func remove(_ id: String) throws {
        try write { $0.removeAll { $0["id"]?.string == id } }
        Task { await McpClient.shared.forget(id) }
    }

    /// 连上一台服务器、取回工具清单，存进配置（拼提示词是同步的，不能每轮现取）。服务器页的「连接」
    static func refresh(_ id: String) async throws -> McpClient.Probe {
        guard let server = server(id) else { throw StoreError(message: "这台服务器已删除") }
        do {
            let r = try await McpClient.shared.probe(server)
            try update(id, ["tools": .array(r.tools.map { .object($0.json) }), "info": r.info, "gen": .string(r.gen),
                            "version": .string(r.version), "checkedAt": .number(Date().millis), "error": .string("")])
            return r
        } catch {
            try? update(id, ["checkedAt": .number(Date().millis), "error": .string(error.localizedDescription)])
            throw error
        }
    }

    /// 在服务器页手动调一次：不经过角色、不落消息，用来看这台服务器、这个工具通不通
    static func tryTool(_ id: String, name: String, args: JSONValue) async throws -> (text: String, isError: Bool, ms: Int) {
        guard let server = server(id) else { throw StoreError(message: "这台服务器已删除") }
        let t0 = Date()
        let r = try await McpClient.shared.callTool(server, name: name, args: args)
        return (Mcp.resultText(r), r["isError"]?.bool == true, Int(Date().timeIntervalSince(t0) * 1000))
    }

    /// 按参数 schema 先填一个样子（网页版服务器页的「试用」）
    static func sampleArgs(_ schema: JSONValue) -> String {
        var o: [String: Any] = [:]
        for (k, v) in schema["properties"]?.object ?? [:] {
            switch v["type"]?.string ?? "" {
            case "number", "integer": o[k] = 0
            case "boolean": o[k] = false
            case "array": o[k] = [Any]()
            case "object": o[k] = [String: Any]()
            default: o[k] = ""
            }
        }
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: - 角色能用哪些

    /// 这个角色能用的服务器：角色卡上勾了的、而且还在的那几台
    static func serversFor(_ char: Character?, _ s: AppSettings = .load()) -> [McpServer] {
        let ids = char?.row.strings("mcpServers") ?? []
        return servers(s).filter { ids.contains($0.id) && !$0.url.isEmpty }
    }

    private static func prefixOf(_ s: McpServer) -> String {
        let t = s.name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"[\s.]+"#, with: "_", options: .regularExpression)
        return t.isEmpty ? "server" : t
    }

    struct Tool { var server: McpServer; var tool: McpTool; var call: String }

    /// 这个角色能用的工具，每个带着写给模型看的那个名字。两台服务器有同名工具时写成「服务器.工具」
    static func toolsFor(_ char: Character?, _ s: AppSettings = .load()) -> [Tool] {
        var list: [(McpServer, McpTool)] = []
        for sv in serversFor(char, s) { for t in sv.tools where !sv.toolsOff.contains(t.name) { list.append((sv, t)) } }
        var seen: [String: Int] = [:]
        for (_, t) in list { seen[t.name, default: 0] += 1 }
        return list.map { Tool(server: $0.0, tool: $0.1, call: (seen[$0.1.name] ?? 0) > 1 ? "\(prefixOf($0.0)).\($0.1.name)" : $0.1.name) }
    }

    /// 角色写的名字对应哪一个。带不带服务器前缀都认
    static func resolve(_ char: Character?, _ name: String, _ s: AppSettings = .load()) -> Tool? {
        let n = name.trimmingCharacters(in: .whitespaces)
        let all = toolsFor(char, s)
        return all.first { $0.call == n } ?? all.first { "\(prefixOf($0.server)).\($0.tool.name)" == n } ?? all.first { $0.tool.name == n }
    }

    static func needsAsk(_ server: McpServer, _ tool: McpTool) -> Bool {
        let a = server.approve
        return a == "ask" || (a == "read" && !tool.readOnly)
    }

    // MARK: - 落成一条

    /// 角色写的 [调用：…] 落成一条（不入库，由调用方 append）。名字对不上、参数不是 JSON 的照样落一条失败：
    /// 丢掉的话角色以为调成了，会接着编一个结果出来。autoRun 为假（切换版本时重新落一遍）：不用确认的也先停在 ask，不重调一次
    static func make(_ p: ReplyParser.Part, chat: Chat, char: Character, turnId: String, autoRun: Bool = true) -> Message {
        let hit = resolve(char, p.text)
        // 有意截断：报错里引一段
        let why = hit == nil ? "没有名为「\(p.text)」的工具" : p.bad.map { "参数不是一个合法的 JSON 对象：\($0.prefix(200))" } ?? ""
        let args = (p.extra.flatMap { try? JSONValue.parse(Data($0.utf8)) })?.object ?? [:]
        var m = Message.new(chatId: chat.id, role: .char, authorId: char.id,
                            content: "[调用：\(p.text) \(p.bad ?? p.extra ?? "{}")]", kind: kind, turnId: turnId)
        m.row["toolName"] = .string(hit?.tool.name ?? p.text)
        m.row["toolTitle"] = .string(hit.map { $0.tool.title.isEmpty ? $0.tool.name : $0.tool.title } ?? p.text)
        m.row["toolServerId"] = .string(hit?.server.id ?? "")
        m.row["toolArgs"] = .object(args)
        let state = !why.isEmpty ? "error" : (hit.map { needsAsk($0.server, $0.tool) } ?? true) || !autoRun ? "ask" : "running"
        m.row["toolState"] = .string(state)
        m.row["toolError"] = .string(why)
        return m
    }

    // MARK: - 调用

    /// 正在调的那几条（消息 id → 任务）。状态停在 running 却不在这里的，是应用重开时正在调的那一次：
    /// 工具可能有副作用（发邮件、写文件），不自动重调，卡片上给「重试」
    @MainActor static var running: [String: Task<Void, Never>] = [:]
    @MainActor static func isRunning(_ id: String) -> Bool { running[id] != nil }

    private static func message(_ id: String) -> Message? {
        guard let row = (try? Database.shared.get(Collections.messages, id: id)) ?? nil else { return nil }
        let m = Message(row: row)
        return m.kind == kind ? m : nil
    }

    private static func patch(_ id: String, _ f: [String: JSONValue]) {
        guard var m = message(id) else { return }
        for (k, v) in f { m.row[k] = v }
        m.row.touch()
        do { try Repo.save(m) } catch { Problems.report("工具调用的状态未能保存：\(error.localizedDescription)") }
        NotificationCenter.default.post(name: .eiraChatChanged, object: m.chatId)
    }

    /// 落下之后发出去，不挡着这一轮
    static func launch(_ id: String) {
        Task { @MainActor in await run(id) }
    }

    /// 把一条调用真的发出去
    @MainActor
    static func run(_ id: String) async {
        guard let m = message(id), running[id] == nil else { return }
        guard let server = server(m.row.string("toolServerId")) else {
            patch(id, ["toolState": .string("error"), "toolError": .string("这台服务器已删除")])
            followUp(m.chatId, turnId: m.turnId)
            return
        }
        patch(id, ["toolState": .string("running"), "toolError": .string("")])
        let task = Task<Void, Never> {
            do {
                let r = try await McpClient.shared.callTool(server, name: m.row.string("toolName"), args: m.row["toolArgs"] ?? .object([:]))
                let text = Mcp.resultText(r)
                if r["isError"]?.bool == true {
                    patch(id, ["toolState": .string("error"), "toolResult": .string(text), "toolError": .string(text.isEmpty ? "工具返回了错误" : text)])
                } else {
                    patch(id, ["toolState": .string("done"), "toolResult": .string(text), "toolError": .string(""), "toolAt": .number(Date().millis)])
                }
            } catch is CancellationError {
                patch(id, ["toolState": .string("error"), "toolError": .string("已取消")])
            } catch {
                patch(id, ["toolState": .string("error"), "toolError": .string(error.localizedDescription)])
            }
        }
        running[id] = task
        await task.value
        running[id] = nil
        followUp(m.chatId, turnId: m.turnId)
    }

    @MainActor static func approve(_ id: String) { launch(id) }

    @MainActor static func deny(_ id: String) {
        guard let m = message(id) else { return }
        patch(id, ["toolState": .string("denied")])
        followUp(m.chatId, turnId: m.turnId)
    }

    @MainActor static func cancel(_ id: String) { running[id]?.cancel() }

    // MARK: - 接着回复（默认关，登记在 ExtraCalls 的 mcpFollowUp）

    static func followOn(_ s: AppSettings) -> Bool { s.raw["mcpFollowUp"]?.bool == true }
    static func followMax(_ s: AppSettings) -> Int { max(0, Int(s.raw["mcpFollowMax"]?.number ?? 1)) }

    /// 这一轮的调用都有了结果（允许、拒绝、失败都算），就把这段对话记成「该回复了」，走 Pace 那一套到点回复。
    /// 从你上一条消息往后，角色调用过工具的轮数超过设定就停（0 表示不限）。回有没有排上
    @discardableResult
    static func followUp(_ chatId: String, turnId: String, settings s: AppSettings = .load()) -> Bool {
        guard followOn(s), let list = try? Repo.messages(chatId: chatId, limit: 200) else { return false }
        let turn = list.filter { $0.kind == kind && $0.turnId == turnId }
        if turn.contains(where: { ["ask", "running"].contains($0.row.string("toolState")) }) { return false }
        var turns = Set<String>()
        for m in list.reversed() {
            if m.role == .user { break }
            if m.kind == kind && !m.turnId.isEmpty { turns.insert(m.turnId) }
        }
        let max = followMax(s)
        if max > 0 && turns.count > max { return false }
        do {
            guard var c = try Repo.chat(chatId) else { return false }
            c.row["pacePending"] = .object(["dueAt": .number(Date().millis), "secs": .number(0)])
            try Repo.save(c)
        } catch {
            Problems.report("工具结果之后的接着回复未能排上：\(error.localizedDescription)")
            return false
        }
        return true
    }

    // MARK: - 进提示词的那几段

    /// 工具清单，一个工具一段：名字、说明、参数的 JSON Schema（去掉 $schema）
    static func toolList(_ char: Character?, _ s: AppSettings = .load()) -> String {
        toolsFor(char, s).map { x in
            var schema = x.tool.inputSchema.object ?? [:]
            schema["$schema"] = nil
            let js = (try? JSONSerialization.data(withJSONObject: JSONValue.object(schema).any, options: [.sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            let d = x.tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return "- \(x.call)\(d.isEmpty ? "" : ": \(d)")\n  input: \(js)"
        }.joined(separator: "\n")
    }

    /// 跟在调用后面、角色读到的那一段。状态说明是英文，结果本身是数据，原样给；按「用量与上限」里的字数截断，0 表示整段
    static func resultFor(_ m: Message, _ s: AppSettings) -> String {
        let head = "[工具结果：\(m.row.string("toolName"))]"
        switch m.row.string("toolState") {
        case "denied": return "\(head)\nThe user declined this call."
        case "ask": return "\(head)\nWaiting for the user to allow this call."
        case "running": return "\(head)\nThe call is still running."
        case "error":
            let e = m.row.string("toolError")
            return "\(head)\nThe call failed: \(e.isEmpty ? "unknown error" : e)"
        default:
            let text = m.row.string("toolResult")
            if text.isEmpty { return "\(head)\n(empty result)" }
            let n = max(0, Int(s.raw["mcpResultChars"]?.number ?? 4000))
            if n > 0 && text.count > n {
                // 有意截断：用户在「用量与上限」里填的字数
                return "\(head)\n\(text.prefix(n))\n(truncated: first \(n) of \(text.count) characters)"
            }
            return "\(head)\n\(text)"
        }
    }

    /// 所有会话里的工具调用，等待允许的排最前，其余新的在前（调用记录页）
    static func calls() -> [Message] {
        let chats = (try? Repo.chats()) ?? []
        var out: [Message] = []
        for c in chats {
            out += ((try? Database.shared.all(Collections.messages, where: c.id)) ?? []).map(Message.init(row:)).filter { $0.kind == kind }
        }
        return out.sorted {
            let a = $0.row.string("toolState") == "ask", b = $1.row.string("toolState") == "ask"
            return a != b ? a : $0.createdAt > $1.createdAt
        }
    }
}
