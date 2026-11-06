import Foundation

/// MCP 客户端（Model Context Protocol，网页版 system/mcp.js，ARCHITECTURE 4.179、4.973、4.regex-1）。让角色调用外部的工具服务器。
///
/// 只走 HTTP（stdio 那一种要起本地进程，网页版同样不做）。原生版不受跨域限制，网页版的「经转发地址连接」在这里不需要。
/// 服务器分三代，按从新到旧的顺序试：
///   2026-07-28   无状态。没有握手、没有会话 id，每个请求在 _meta 里自己带着协议版本，头里带 Mcp-Method / Mcp-Name。先发 server/discover 探
///   ≤2025-11-25  Streamable HTTP。先 initialize 握手，服务器回一个 Mcp-Session-Id，之后每个请求都带着它；404 视为会话过期，重新握手再发一次
///   2024-11-05   旧版 HTTP+SSE。先 GET 开一条事件流，流里告诉你往哪儿 POST，回复从那条流里回来
/// 探测失败（包括网络错误）一律往下退一档；只有 401 / 403 这种明确的拒绝不退。
/// 回复可以是 JSON 也可以是 SSE，SSE 里夹着的服务器通知跳过，只认 id 对得上的那条。
///
/// 这里不是模型接口：调工具不经 AIService、不记模型调用的账。调完之后要不要让角色接着说（多一次模型调用）由 McpTools.followUp 管，默认关。
enum Mcp {
    static let modern = "2026-07-28"
    static let legacy = "2025-11-25"
    static var client: [String: Any] {
        ["name": "mini-phone", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "native"]
    }

    struct Failure: Error, LocalizedError {
        var message: String
        var status = 0
        var code: Int?
        var expired = false
        /// 这一档不行、可以退一档再试
        var fallback = false
        var errorDescription: String? { message }
    }

    // MARK: - 请求头宽松读（4.973）

    private static func unq(_ v: String) -> String {
        var t = v.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(",") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        if let f = t.first, "\"'`".contains(f) { t.removeFirst() }
        if let l = t.last, "\"'`".contains(l) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func headersOfJson(_ o: Any) -> [String: Any]? {
        guard let o = o as? [String: Any] else { return nil }
        if let servers = o["mcpServers"] as? [String: Any] {
            guard let first = servers.values.first else { return [:] }
            return headersOfJson(first) ?? [:]
        }
        if let h = o["headers"] as? [String: Any] { return h }
        if o.keys.contains(where: { ["url", "serverUrl", "type", "command", "args"].contains($0) }) { return [:] }
        return o
    }

    private static let headerLine = try! NSRegularExpression(pattern: #"^["'`]?([A-Za-z0-9][A-Za-z0-9_.-]*)["'`]?\s*[:=]\s*(.+)$"#)

    /// 请求头文本读成字典。「名称: 值」一行一个，也认 JSON、带引号的行、「名称=值」
    static func parseHeaders(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return out }
        if raw.hasPrefix("{"), let v = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) {
            for (k, val) in headersOfJson(v) ?? [:] {
                let s: String
                if let x = val as? String { s = x } else if val is NSNull { continue } else { s = "\(val)" }
                let key = k.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty && !s.isEmpty { out[key] = s.trimmingCharacters(in: .whitespaces) }
            }
            return out
        }
        for line in raw.components(separatedBy: "\n") {
            var l = line.trimmingCharacters(in: .whitespaces)
            while let f = l.first, "{}".contains(f) { l.removeFirst() }
            while let e = l.last, "{}".contains(e) { l.removeLast() }
            l = l.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, let m = ReplyParser.match(headerLine, l) else { continue }
            let v = unq(m[2])
            if !v.isEmpty { out[m[1]] = v }
        }
        return out
    }

    private static let tokenName = try! NSRegularExpression(pattern: #"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$"#)
    private static func validName(_ n: String) -> Bool { !n.isEmpty && ReplyParser.matches(tokenName, n) }

    /// 令牌那一栏：名称空着按 Authorization；Authorization 的值没写方案（Bearer、Basic……）时补上 Bearer
    static func authHeader(name: String, value: String) -> [String: String] {
        var v = unq(value)
        if v.isEmpty { return [:] }
        let n = name.trimmingCharacters(in: .whitespaces)
        // 整行贴进来的（Authorization: Bearer x），按那一行读
        let line = parseHeaders(v)
        if line.count == 1, let k = line.keys.first,
           k.range(of: #"^(authorization|x-api-key|api-key|x-auth-token|token)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return [(validName(n) ? n : k): line[k] ?? ""]
        }
        let k = validName(n) ? n : "Authorization"
        if k.lowercased() == "authorization", v.range(of: #"^[A-Za-z][\w-]*\s+\S"#, options: .regularExpression) == nil { v = "Bearer \(v)" }
        return [k: v]
    }

    /// 这台服务器实际要带的请求头：其余请求头在前，令牌那一栏在后（同名时以令牌那一栏为准）
    static func headersOf(_ s: McpServer) -> [String: String] {
        var out = parseHeaders(s.headers)
        for (k, v) in authHeader(name: s.authName, value: s.authValue) {
            for old in out.keys where old.lowercased() == k.lowercased() { out[old] = nil }
            out[k] = v
        }
        return out
    }

    /// 别处复制来的整段 JSON 配置：读出名称、地址与请求头。不是配置时回 nil
    static func parseConfig(_ text: String) -> (name: String, url: String, headers: String)? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("{"), var o = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return nil }
        var name = ""
        if let servers = o["mcpServers"] as? [String: Any], let k = servers.keys.sorted().first {
            name = k
            o = servers[k] as? [String: Any] ?? [:]
        }
        let url = ((o["url"] ?? o["serverUrl"] ?? o["baseUrl"]) as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard url.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let h = o["headers"] as? [String: Any] ?? [:]
        let lines = h.keys.sorted().map { (k: String) -> String in
            let v = h[k].map { (x: Any) -> String in "\(x)" } ?? ""
            return "\(k): \(v)"
        }
        return (name, url, lines.joined(separator: "\n"))
    }

    // MARK: - 结果读成文字

    /// 角色读的、气泡上显示的都是它。图片、音频这类角色读不了，写明有这么一个东西；结构化结果没有文字时整个转成 JSON
    static func resultText(_ r: JSONValue?) -> String {
        let parts: [String] = (r?["content"]?.array ?? []).compactMap { (c: JSONValue) -> String? in
            switch c["type"]?.string ?? "" {
            case "text": return c["text"]?.string ?? ""
            case "image": return "[图片结果：\(c["mimeType"]?.string ?? "image")]"
            case "audio": return "[音频结果：\(c["mimeType"]?.string ?? "audio")]"
            case "resource":
                if let t = c["resource"]?["text"]?.string, !t.isEmpty { return t }
                return "[资源：\(c["resource"]?["uri"]?.string ?? "")]"
            case "resource_link":
                return "[链接：\(c["name"]?.string ?? "") \(c["uri"]?.string ?? "")]".trimmingCharacters(in: .whitespaces)
            default: return ""
            }
        }.filter { !$0.isEmpty }
        if parts.isEmpty, let sc = r?["structuredContent"], !sc.isNull,
           let d = try? JSONSerialization.data(withJSONObject: sc.any, options: [.sortedKeys, .fragmentsAllowed]) {
            return String(decoding: d, as: UTF8.self)
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - 网络

    /// 测试里换成接住全部请求的那一份
    nonisolated(unsafe) static var session: URLSession = .shared

    static func httpError(_ status: Int, _ text: String = "") -> Failure {
        let why = status == 401 || status == 403 ? "没有权限，请检查令牌或请求头里的密钥"
            : status == 404 ? "地址不存在" : status == 405 ? "这个地址不接受这种请求" : "HTTP \(status)"
        // 有意截断：报错里引一段服务器的回复
        return Failure(message: why + (text.isEmpty ? "" : "：\(text.prefix(160))"), status: status,
                       fallback: [400, 404, 405, 406, 415].contains(status))
    }

    static func netError(_ e: Error) -> Failure {
        Failure(message: "连不上服务器（\(e.localizedDescription)）", fallback: true)
    }
}

/// 一台 MCP 服务器的配置（settings.services.mcp.servers 的一条，字段同网页版 services.newMcpServer）
struct McpServer: Identifiable, Equatable, Sendable {
    var json: [String: JSONValue]
    var id: String { json["id"]?.string ?? "" }
    var name: String { json["name"]?.string ?? "" }
    var url: String { (json["url"]?.string ?? "").trimmingCharacters(in: .whitespaces) }
    var headers: String { json["headers"]?.string ?? "" }
    var authName: String { json["authName"]?.string ?? "" }
    var authValue: String { json["authValue"]?.string ?? "" }
    var timeout: Double { max(1, json["timeout"]?.number ?? 60) }
    /// ask 每次确认 / read 只读免确认 / auto 直接调
    var approve: String { json["approve"]?.string ?? "ask" }
    var toolsOff: [String] { (json["toolsOff"]?.array ?? []).compactMap(\.string) }
    var tools: [McpTool] { (json["tools"]?.array ?? []).compactMap { $0.object.map(McpTool.init(json:)) }.filter { !$0.name.isEmpty } }
    var error: String { json["error"]?.string ?? "" }
    var checkedAt: Double { json["checkedAt"]?.number ?? 0 }
    var label: String { name.isEmpty ? "未命名服务器" : name }

    /// 连接缓存作废的条件：地址、请求头、令牌、名称，任何一样变了上次的连接都不作数
    var connKey: String { [url, headers, authName, authValue].joined(separator: "\u{1}") }
}

struct McpTool: Equatable, Sendable {
    var json: [String: JSONValue]
    init(json: [String: JSONValue]) { self.json = json }
    var name: String { json["name"]?.string ?? "" }
    var title: String { json["title"]?.string ?? "" }
    var description: String { json["description"]?.string ?? "" }
    var inputSchema: JSONValue { json["inputSchema"] ?? .object(["type": .string("object")]) }
    var readOnly: Bool { json["readOnly"]?.bool == true }

    /// tools/list 回来的一项，存成网页版 listTools 的样子
    static func fromList(_ t: JSONValue) -> McpTool {
        let title = t["title"]?.string ?? t["annotations"]?["title"]?.string ?? ""
        return McpTool(json: ["name": .string(t["name"]?.string ?? ""), "title": .string(title),
                              "description": .string(t["description"]?.string ?? ""),
                              "inputSchema": t["inputSchema"] ?? .object(["type": .string("object")]),
                              "readOnly": .bool(t["annotations"]?["readOnlyHint"]?.bool == true)])
    }
}

/// 连接按服务器 id 缓存在内存里。握手的结果（哪一代、会话 id、协商出来的版本）应用重开就没了，下次用到时重新探一遍。
/// 正在连的那一次大家共用（4.regex-1）：角色一轮写了几个调用，同一台服务器只握一次手
actor McpClient {
    static let shared = McpClient()

    enum Gen: String, Sendable { case modern, http, sse }

    final class Conn: @unchecked Sendable {
        var gen: Gen
        var session = ""
        var version = ""
        var info: JSONValue = .null
        var postUrl: URL?
        var key = ""
        var stream: Task<Void, Never>?
        var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
        let lock = NSLock()
        init(_ gen: Gen) { self.gen = gen }

        /// 流里先到、还没人等的那几条（POST 的回复有时比 POST 本身先从流里回来）
        var early: [String: JSONValue] = [:]

        func wait(_ id: String) async throws -> JSONValue {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if let v = early.removeValue(forKey: id) { lock.unlock(); c.resume(returning: v); return }
                pending[id] = c
                lock.unlock()
            }
        }
        func deliver(_ id: String, _ v: JSONValue) {
            lock.lock()
            let c = pending.removeValue(forKey: id)
            if c == nil { early[id] = v }
            lock.unlock()
            c?.resume(returning: v)
        }
        func failAll(_ e: Error) {
            lock.lock(); let all = pending; pending = [:]; lock.unlock()
            for c in all.values { c.resume(throwing: e) }
        }
        func drop(_ id: String) -> CheckedContinuation<JSONValue, Error>? {
            lock.lock(); defer { lock.unlock() }; return pending.removeValue(forKey: id)
        }
    }

    private var conns: [String: Conn] = [:]
    private var connecting: [String: (key: String, task: Task<Conn, Error>)] = [:]
    private var seq = 0

    private func nextId() -> String {
        seq += 1
        return "c\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36))\(String(seq, radix: 36))"
    }

    func forget(_ id: String) {
        if let c = conns[id] { c.stream?.cancel(); c.failAll(Mcp.Failure(message: "连接已断开")) }
        conns[id] = nil
    }

    // MARK: 发一个请求

    private func baseHeaders(_ s: McpServer) -> [String: String] {
        var h = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"]
        for (k, v) in Mcp.headersOf(s) { h[k] = v }
        return h
    }

    private func post(_ s: McpServer, _ conn: Conn, _ method: String, _ params: [String: Any]?, notify: Bool = false) async throws -> JSONValue {
        let id = notify ? nil : nextId()
        var headers = baseHeaders(s)
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { body["id"] = id }
        if let params { body["params"] = params }
        switch conn.gen {
        case .modern:
            headers["MCP-Protocol-Version"] = Mcp.modern
            headers["Mcp-Method"] = method
            if let n = params?["name"] as? String { headers["Mcp-Name"] = n }
            var p = params ?? [:]
            var meta = p["_meta"] as? [String: Any] ?? [:]
            meta["io.modelcontextprotocol/protocolVersion"] = Mcp.modern
            meta["io.modelcontextprotocol/clientInfo"] = Mcp.client
            meta["io.modelcontextprotocol/clientCapabilities"] = [String: Any]()
            p["_meta"] = meta
            body["params"] = p
        case .http:
            if !conn.session.isEmpty { headers["Mcp-Session-Id"] = conn.session }
            // 2025-06-18 起要求带协议版本头；更早的服务器不认这个头
            if !conn.version.isEmpty && conn.version >= "2025-06-18" { headers["MCP-Protocol-Version"] = conn.version }
        case .sse:
            break
        }
        guard let url = conn.gen == .sse ? conn.postUrl : URL(string: s.url) else { throw Mcp.Failure(message: "服务器地址无效") }
        var req = URLRequest(url: url, timeoutInterval: s.timeout)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let request = req

        return try await Self.timed(s.timeout) { [self] in
            let bytes: URLSession.AsyncBytes
            let res: URLResponse
            do { (bytes, res) = try await Mcp.session.bytes(for: request) }
            catch is CancellationError { throw Mcp.Failure(message: "请求已取消") }
            catch { throw Mcp.netError(error) }
            let http = res as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if conn.gen == .http, let sid = http?.value(forHTTPHeaderField: "mcp-session-id"), !sid.isEmpty { conn.session = sid }
            guard (200..<300).contains(status) else {
                if status == 404 && conn.gen == .http && !conn.session.isEmpty {
                    throw Mcp.Failure(message: "会话已过期", status: 404, expired: true)
                }
                throw Mcp.httpError(status, await Self.text(bytes))
            }
            guard let id else { return .null }
            let msg: JSONValue
            if conn.gen == .sse {
                // 旧版 SSE：回复不在这个 POST 里，在那条事件流里
                msg = try await self.waitSse(conn, id)
            } else {
                msg = try await Self.readReply(bytes, http, id)
            }
            if let e = msg["error"], !e.isNull {
                let code = e["code"]?.number.map { Int($0) }
                throw Mcp.Failure(message: e["message"]?.string ?? "错误 \(code.map(String.init) ?? "")", code: code, fallback: code == -32601)
            }
            return msg["result"] ?? .null
        }
    }

    private nonisolated func waitSse(_ conn: Conn, _ id: String) async throws -> JSONValue {
        try await withTaskCancellationHandler {
            try await conn.wait(id)
        } onCancel: {
            conn.drop(id)?.resume(throwing: Mcp.Failure(message: "请求已取消"))
        }
    }

    /// 超过时限就停（网页版 withTimeout）
    static func timed<T: Sendable>(_ secs: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await body() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, secs) * 1_000_000_000))
                throw Mcp.Failure(message: "超过 \(Int(secs)) 秒没有回复")
            }
            defer { g.cancelAll() }
            guard let first = try await g.next() else { throw Mcp.Failure(message: "请求已取消") }
            return first
        }
    }

    static func text(_ bytes: URLSession.AsyncBytes) async -> String {
        var d = Data()
        do { for try await b in bytes { d.append(b); if d.count > 4096 { break } } } catch {}
        return String(decoding: d, as: UTF8.self)
    }

    /// 一段 SSE 文本流，逐条交出 (event, data)
    static func events(_ bytes: URLSession.AsyncBytes, _ each: (String, String) async throws -> Bool) async throws {
        var buf = Data()
        let sep = Data("\n\n".utf8)
        for try await b in bytes {
            if b == 0x0D { continue }   // \r\n、\r 一律当 \n（\r 单独出现的极少，这里按丢掉处理）
            buf.append(b)
            while let r = buf.range(of: sep) {
                let block = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
                buf.removeSubrange(buf.startIndex..<r.upperBound)
                var event = "message"
                var data: [String] = []
                for l in block.components(separatedBy: "\n") {
                    if l.hasPrefix("event:") { event = l.dropFirst(6).trimmingCharacters(in: .whitespaces) }
                    else if l.hasPrefix("data:") {
                        var v = String(l.dropFirst(5))
                        if v.hasPrefix(" ") { v.removeFirst() }
                        data.append(v)
                    }
                }
                if !data.isEmpty, try await each(event, data.joined(separator: "\n")) { return }
            }
        }
    }

    private static func parse(_ s: String) -> JSONValue? { try? JSONValue.parse(Data(s.utf8)) }

    /// 回复里那条对得上 id 的。流里可能先来几条服务器自己的通知，跳过
    static func readReply(_ bytes: URLSession.AsyncBytes, _ res: HTTPURLResponse?, _ id: String) async throws -> JSONValue {
        let type = res?.value(forHTTPHeaderField: "content-type") ?? ""
        func hit(_ v: JSONValue?, needResult: Bool) -> JSONValue? {
            let list = v?.array ?? (v.map { [$0] } ?? [])
            return list.first { $0["id"]?.string == id && (!needResult || $0["result"] != nil || $0["error"] != nil) }
        }
        if type.contains("text/event-stream") {
            var found: JSONValue?
            try await events(bytes) { _, data in
                if let h = hit(parse(data), needResult: true) { found = h; return true }
                return false
            }
            guard let found else { throw Mcp.Failure(message: "服务器没有回复这个请求就关闭了连接") }
            return found
        }
        var d = Data()
        for try await b in bytes { d.append(b) }
        let text = String(decoding: d, as: UTF8.self)
        guard let h = hit(parse(text), needResult: false) else {
            // 有意截断：报错里引一段服务器的回复
            throw Mcp.Failure(message: "服务器的回复不是 JSON-RPC：\(text.prefix(120))")
        }
        return h
    }

    // MARK: 旧版 SSE：开一条事件流，等它告诉我们往哪儿 POST

    private func openSse(_ s: McpServer) async throws -> Conn {
        guard let base = URL(string: s.url) else { throw Mcp.Failure(message: "服务器地址无效") }
        var req = URLRequest(url: base, timeoutInterval: max(s.timeout, 600))
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in Mcp.headersOf(s) { req.setValue(v, forHTTPHeaderField: k) }
        let bytes: URLSession.AsyncBytes, res: URLResponse
        do { (bytes, res) = try await Mcp.session.bytes(for: req) } catch { throw Mcp.netError(error) }
        let http = res as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Mcp.httpError(status) }
        guard (http?.value(forHTTPHeaderField: "content-type") ?? "").contains("text/event-stream") else {
            throw Mcp.Failure(message: "这个地址既不是 Streamable HTTP，也不是旧版 SSE 的事件流")
        }
        let conn = Conn(.sse)
        let sid = s.id
        let endpoint = AsyncThrowingStream<URL, Error> { cont in
            conn.stream = Task.detached {
                do {
                    try await Self.events(bytes) { event, data in
                        if event == "endpoint" {
                            if let u = URL(string: data, relativeTo: base)?.absoluteURL { cont.yield(u) }
                            return false
                        }
                        if let msg = Self.parse(data), let id = msg["id"]?.string { conn.deliver(id, msg) }
                        return false
                    }
                } catch {}
                cont.finish(throwing: Mcp.Failure(message: "事件流已关闭"))
                conn.failAll(Mcp.Failure(message: "事件流已关闭"))
                // 流断了：下一次请求会发现连接没了，重新连
                await McpClient.shared.dropIfSame(sid, conn)
            }
        }
        let url = try await Self.timed(15) {
            for try await u in endpoint { return u }
            throw Mcp.Failure(message: "事件流里一直没有给出消息地址")
        }
        conn.postUrl = url
        return conn
    }

    func dropIfSame(_ id: String, _ conn: Conn) {
        if conns[id] === conn { conns[id] = nil }
    }

    private func handshake(_ s: McpServer, _ conn: Conn) async throws -> Conn {
        let r = try await post(s, conn, "initialize", ["protocolVersion": Mcp.legacy, "capabilities": [String: Any](), "clientInfo": Mcp.client])
        conn.version = r["protocolVersion"]?.string ?? Mcp.legacy
        conn.info = r["serverInfo"] ?? .null
        _ = try? await post(s, conn, "notifications/initialized", nil, notify: true)
        return conn
    }

    private func open(_ s: McpServer) async throws -> Conn {
        forget(s.id)
        // 一、新一代
        let modern = Conn(.modern)
        do {
            let r = try await post(s, modern, "server/discover", [:])
            let versions = (r["supportedVersions"]?.array ?? []).compactMap(\.string)
            if versions.contains(Mcp.modern) {
                modern.version = Mcp.modern
                modern.info = r["_meta"]?["io.modelcontextprotocol/serverInfo"] ?? r["serverInfo"] ?? .null
                return modern
            }
        } catch let e as Mcp.Failure {
            if !(e.fallback || e.code != nil) { throw e }
        }
        // 二、Streamable HTTP 握手
        do {
            return try await handshake(s, Conn(.http))
        } catch let e as Mcp.Failure {
            if !e.fallback { throw e }
        }
        // 三、旧版 SSE
        return try await handshake(s, try await openSse(s))
    }

    /// 连上一个服务器。已经连着就直接用；正在连的那一次大家共用
    func connect(_ s: McpServer) async throws -> Conn {
        guard !s.url.isEmpty else { throw Mcp.Failure(message: "没有填写服务器地址") }
        if let had = conns[s.id], had.key == s.connKey { return had }
        if let wip = connecting[s.id], wip.key == s.connKey { return try await wip.task.value }
        let task = Task { try await self.open(s) }
        connecting[s.id] = (s.connKey, task)
        defer { if connecting[s.id]?.key == s.connKey { connecting[s.id] = nil } }
        let conn = try await task.value
        conn.key = s.connKey
        conns[s.id] = conn
        return conn
    }

    /// 带一次「会话过期就重连」的请求。只丢掉过期的那一个：同一轮的另一个调用可能已经重连好了
    func request(_ s: McpServer, _ method: String, _ params: [String: Any]?) async throws -> JSONValue {
        var conn = try await connect(s)
        do {
            return try await post(s, conn, method, params)
        } catch let e as Mcp.Failure where e.expired {
            if conns[s.id] === conn { forget(s.id) }
            conn = try await connect(s)
            return try await post(s, conn, method, params)
        }
    }

    /// 这台服务器上所有的工具。有分页就一页页取完
    func listTools(_ s: McpServer) async throws -> [McpTool] {
        var out: [McpTool] = []
        var cursor: String?
        repeat {
            let p: [String: Any] = cursor.map { ["cursor": $0] } ?? [:]
            let r = try await request(s, "tools/list", p)
            out += (r["tools"]?.array ?? []).map(McpTool.fromList)
            cursor = r["nextCursor"]?.string
        } while cursor?.isEmpty == false
        return out.filter { !$0.name.isEmpty }
    }

    struct Probe: Sendable { var gen: String; var version: String; var info: JSONValue; var tools: [McpTool] }

    /// 连上并列出工具。服务器页的「连接」用
    func probe(_ s: McpServer) async throws -> Probe {
        forget(s.id)
        let conn = try await connect(s)
        let tools = try await listTools(s)
        return Probe(gen: conn.gen.rawValue, version: conn.version, info: conn.info, tools: tools)
    }

    /// 调一个工具。返回 MCP 的原始结果
    func callTool(_ s: McpServer, name: String, args: JSONValue) async throws -> JSONValue {
        try await request(s, "tools/call", ["name": name, "arguments": args.object.map { JSONValue.object($0).any } ?? [String: Any]()])
    }
}
