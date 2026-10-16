import Foundation

/// 发给模型的一条消息。system 出现在历史中段时（按深度插进来的世界书、召回的记忆），
/// 发出去之前按网页版 midsystem.js 改写，见 `Provider.shape`。
struct AIMessage: Equatable, Sendable {
    enum Role: String, Sendable { case system, user, assistant }
    var role: Role
    var content: String
    /// 随这条一起发给模型的图（「识图交给聊天模型」时，当前这一轮用户发的图）。
    var images: [AIImage] = []
}

struct AIImage: Equatable, Sendable {
    var mediaType: String
    var base64: String
}

struct AIError: LocalizedError {
    var status: Int?
    var message: String
    /// 已经收到了一部分正文。这种失败不重试、不换接口：再来一次是另付一次钱，而用户已经看到了一半。
    var partial: String = ""
    var cancelled = false
    /// 没连上时系统给的错误码（URLError.Code），测试连接据此说明断在哪一步
    var netCode: Int?
    /// 这一次试过、都失败了的那几套，各自是不是余额不足（网页版 err.failedPresets）。会话里那条失败据此给「去充值」
    var failedPresets: [FailedPreset] = []
    var errorDescription: String? { message }

    struct FailedPreset: Equatable, Sendable {
        var id: String
        var balance: Bool
    }

    /// 余额不足。各家写法不一：402，或者报错正文里带这几种说法（网页版 isBalanceError）
    var isBalance: Bool {
        if status == 402 { return true }
        return message.range(of: "insufficient|quota|balance|credit|billing|payment|余额|额度|欠费|充值",
                             options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 值得原样再试一次的：限流、服务端出错、连接断了且一个字都没收到。
    var retryable: Bool {
        if cancelled || !partial.isEmpty { return false }
        guard let status else { return true }
        return status == 429 || status >= 500
    }
}

/// 两种接口格式：Anthropic 与 OpenAI 兼容。请求与解析照网页版 `ai/providers/anthropic.js`、`openai.js`。
enum Provider {
    struct Request {
        var system: String
        var messages: [AIMessage]
        var maxTokens: Int
        var stream: Bool
        var cache: Bool
    }

    static func urlRequest(_ p: ChatPreset, _ r: Request, idleSeconds: Double) throws -> URLRequest {
        let url: URL?
        var headers = ["content-type": "application/json"]
        var body: [String: Any] = ["model": p.model]
        let msgs = shape(p, r.messages)

        switch p.provider {
        case .anthropic:
            let base = trimSlash(p.baseUrl.isEmpty ? "https://api.anthropic.com" : p.baseUrl)
            url = URL(string: base + "/v1/messages")
            headers["x-api-key"] = p.apiKey
            headers["anthropic-version"] = "2023-06-01"
            body["max_tokens"] = r.maxTokens > 0 ? r.maxTokens : 32000
            body["messages"] = msgs.map { m -> [String: Any] in
                guard !m.images.isEmpty else { return ["role": m.role.rawValue, "content": m.content] }
                var blocks: [[String: Any]] = m.images.map {
                    ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.base64]] as [String: Any]
                }
                if !m.content.isEmpty { blocks.append(["type": "text", "text": m.content]) }
                return ["role": m.role.rawValue, "content": blocks]
            }
            if !r.system.isEmpty {
                body["system"] = r.cache
                    ? [["type": "text", "text": r.system, "cache_control": ["type": "ephemeral"]]]
                    : r.system
            }
            if !p.effort.isEmpty { body["output_config"] = ["effort": p.effort] }
        case .openai:
            let base = trimSlash(p.baseUrl.isEmpty ? "https://api.openai.com/v1" : p.baseUrl)
            let hasVersion = base.range(of: #"/v\d+$"#, options: .regularExpression) != nil
            url = URL(string: base + (hasVersion ? "/chat/completions" : "/v1/chat/completions"))
            headers["authorization"] = "Bearer \(p.apiKey)"
            var list: [[String: Any]] = []
            if !r.system.isEmpty { list.append(["role": "system", "content": r.system]) }
            list += msgs.map { m -> [String: Any] in
                guard !m.images.isEmpty else { return ["role": m.role.rawValue, "content": m.content] }
                var parts: [[String: Any]] = []
                if !m.content.isEmpty { parts.append(["type": "text", "text": m.content]) }
                parts += m.images.map { ["type": "image_url", "image_url": ["url": "data:\($0.mediaType);base64,\($0.base64)"]] as [String: Any] }
                return ["role": m.role.rawValue, "content": parts]
            }
            body["messages"] = list
            if r.maxTokens > 0 { body["max_tokens"] = r.maxTokens }
            if let t = p.temperature { body["temperature"] = t }
        }
        if r.stream { body["stream"] = true }

        guard let url else { throw AIError(status: nil, message: "接口地址无效：\(p.baseUrl)") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // URLRequest 的超时就是「两段数据之间最多等多久」，正好是网页版 streamIdleSec 的意思
        req.timeoutInterval = idleSeconds > 0 ? (r.stream ? idleSeconds : idleSeconds * 4) : 86400
        return req
    }

    /// 历史中段的 system 改成用 `<context>` 包起来的 user，再把相邻同角色的并成一条。
    /// Anthropic 一律这样；OpenAI 除非这套接口设了 midSystem = 'system'。
    static func shape(_ p: ChatPreset, _ messages: [AIMessage]) -> [AIMessage] {
        if p.provider == .openai && p.midSystem == "system" { return messages }
        var out: [AIMessage] = []
        for m in messages {
            // 网页版是 { ...m, role: 'user' }：带着的图一并留下
            let m = m.role == .system ? AIMessage(role: .user, content: "<context>\n\(m.content)\n</context>", images: m.images) : m
            // 带图的不并：并进去图就挂到别的话上了（网页版同样）
            if let last = out.last, last.role == m.role, last.images.isEmpty, m.images.isEmpty {
                out[out.count - 1].content = last.content + "\n\n" + m.content
            } else {
                out.append(m)
            }
        }
        return out
    }

    /// 发一次请求。流式时每收到一段调一次 onDelta（参数是到目前为止的全文）。
    static func send(_ p: ChatPreset, _ r: Request, idleSeconds: Double,
                     onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        let req = try urlRequest(p, r, idleSeconds: idleSeconds)
        var text = ""
        do {
            if r.stream {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
                    var raw = Data()
                    for try await b in bytes { raw.append(b); if raw.count > 64_000 { break } }
                    throw httpError(p, code, raw)
                }
                lines: for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let ev = try? JSONValue.parse(Data(payload.utf8)) else { continue }
                    switch try streamEvent(p, ev) {
                    case .text(let piece):
                        text += piece
                        onDelta(text)
                    case .stop: break lines
                    case .none: continue
                    }
                }
            } else {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
                    throw httpError(p, code, data)
                }
                text = try completeText(p, try JSONValue.parse(data))
                onDelta(text)
            }
        } catch var e as AIError {
            e.partial = text
            throw e
        } catch is CancellationError {
            throw AIError(status: nil, message: "已取消", partial: text, cancelled: true)
        } catch let e as URLError where e.code == .cancelled {
            throw AIError(status: nil, message: "已取消", partial: text, cancelled: true)
        } catch let e as URLError {
            var out = AIError(status: nil, message: "连接失败：\(e.localizedDescription)", partial: text)
            out.netCode = e.code.rawValue
            throw out
        } catch {
            throw AIError(status: nil, message: "连接失败：\(error.localizedDescription)", partial: text)
        }
        // 回复那一路要留着思考段（网页版 4.580：存在这一轮第一条的 think 上，长按「查看思考」）。
        // 由回复解析（ReplyParser.stripThink）摘掉；其余任务照旧在这里剥掉
        return keepThink ? text.trimmingCharacters(in: .whitespacesAndNewlines) : stripThink(text)
    }

    /// 为真时 send 回来的正文保留 <thinking> 段。只在对话回复那一处设（ChatEngine），经 AIService 一路传下来
    @TaskLocal static var keepThink: Bool = false

    private enum Event { case text(String), stop, none }

    private static func streamEvent(_ p: ChatPreset, _ ev: JSONValue) throws -> Event {
        if let err = ev["error"], !err.isNull {
            throw AIError(status: nil, message: err["message"]?.string ?? err.string ?? "接口返回错误")
        }
        switch p.provider {
        case .anthropic:
            switch ev["type"]?.string {
            case "content_block_delta":
                if ev["delta"]?["type"]?.string == "text_delta", let t = ev["delta"]?["text"]?.string { return .text(t) }
                return .none
            case "message_delta":
                if ev["delta"]?["stop_reason"]?.string == "refusal" {
                    throw AIError(status: nil, message: "模型拒绝了这次请求")
                }
                return .none
            case "message_stop": return .stop
            default: return .none
            }
        case .openai:
            guard let choice = ev["choices"]?.array?.first else { return .none }
            if let t = choice["delta"]?["content"]?.string, !t.isEmpty { return .text(t) }
            if let reason = choice["finish_reason"], !reason.isNull { return .stop }
            return .none
        }
    }

    private static func completeText(_ p: ChatPreset, _ body: JSONValue) throws -> String {
        switch p.provider {
        case .anthropic:
            if body["stop_reason"]?.string == "refusal" { throw AIError(status: nil, message: "模型拒绝了这次请求") }
            return (body["content"]?.array ?? [])
                .filter { $0["type"]?.string == "text" }
                .compactMap { $0["text"]?.string }
                .joined()
        case .openai:
            return body["choices"]?.array?.first?["message"]?["content"]?.string ?? ""
        }
    }

    private static func httpError(_ p: ChatPreset, _ code: Int, _ raw: Data) -> AIError {
        let body = try? JSONValue.parse(raw)
        let detail = body?["error"]?["message"]?.string ?? body?["error"]?.string ?? body?["message"]?.string
            ?? String(decoding: raw.prefix(300), as: UTF8.self)
        let head = p.provider == .anthropic ? "Anthropic \(code)" : "接口 \(code)"
        return AIError(status: code, message: detail.isEmpty ? head : "\(head)：\(detail)")
    }

    /// 去掉 <think>、<thinking>、<thought> 段（网页版 think.js）。
    static func stripThink(_ s: String) -> String {
        var out = s
        for tag in ["think", "thinking", "thought"] {
            out = out.replacingOccurrences(of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimSlash(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespaces)
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}
