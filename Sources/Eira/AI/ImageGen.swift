import Foundation

/// 一套生图接口。和网页版 services.js 的 newImagePreset 同一形状，存在 settings.services.image.presets 里。
struct ImagePreset: Identifiable, Equatable, Sendable {
    /// openai：POST {base}/images/generations；nai：NovelAI，回来的是一个 zip；chat：对话接口，从回复里取图（网页版 image.js 的 KINDS）
    struct Choice: Identifiable, Sendable {
        let id: String
        let label: String
        var base = ""
    }

    static let kinds: [Choice] = [
        Choice(id: "openai", label: "OpenAI 兼容", base: "https://api.openai.com/v1"),
        Choice(id: "nai", label: "NovelAI", base: "https://image.novelai.net"),
        Choice(id: "chat", label: "对话接口", base: "https://api.openai.com/v1"),
    ]
    /// 空串整个字段不发（gpt-image-1 一类不认 response_format）
    static let formats: [Choice] = [Choice(id: "", label: "自动"), Choice(id: "b64_json", label: "base64"), Choice(id: "url", label: "链接")]
    /// 提示词的语言：跟随对话、角色写英文（不多调接口）、生图前翻译（每张含中文的图多一次，登记在 ExtraCalls）
    static let langs: [Choice] = [Choice(id: "", label: "跟随对话"), Choice(id: "en", label: "角色写英文"), Choice(id: "translate", label: "生图前翻译")]

    var json: [String: JSONValue]

    var id: String { json["id"]?.string ?? "" }
    var name: String { json["name"]?.string ?? "未命名" }
    var kind: String {
        let k = json["kind"]?.string ?? ""
        return Self.kinds.contains { $0.id == k } ? k : "openai"
    }
    var baseUrl: String { json["baseUrl"]?.string ?? "" }
    var apiKey: String { json["apiKey"]?.string ?? "" }
    var model: String { json["model"]?.string ?? "" }
    var size: String { json["size"]?.string ?? "1024x1024" }
    var respFormat: String { json["respFormat"]?.string ?? "" }
    var negative: String { json["negative"]?.string ?? "" }
    var negOn: Bool { json["negOn"]?.bool ?? false }
    var promptLang: String {
        let l = json["promptLang"]?.string ?? ""
        return Self.langs.contains { $0.id == l } ? l : ""
    }
    /// 等多久，秒。填 0 表示一直等（网页版 timeoutOf，默认 300）
    var timeout: Double {
        guard let n = json["timeout"]?.number, n >= 0 else { return 300 }
        return n.rounded()
    }
    var ready: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 去掉空白与末尾斜杠，没填用这一类的默认地址（网页版 url.js 的 baseOf）。
    var base: String {
        let b = baseUrl.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        return b.isEmpty ? (Self.kinds.first { $0.id == kind }?.base ?? "") : b
    }

    /// 地址末尾已经是 /v1 一类就直接接路径，否则补一个 /v1。
    func endpoint(_ path: String) -> String {
        base.range(of: #"/v\d+$"#, options: .regularExpression) != nil ? "\(base)/\(path)" : "\(base)/v1/\(path)"
    }

    static func new(name: String = "未命名", kind: String = "openai") -> [String: JSONValue] {
        ["id": .string(Ids.make("img")), "name": .string(name), "kind": .string(kind), "baseUrl": .string(""),
         "apiKey": .string(""), "model": .string(""), "size": .string("1024x1024"), "respFormat": .string(""),
         "timeout": .number(300)]
    }
}

extension AppSettings {
    var imagePresets: [ImagePreset] {
        (services["image"]?.object?["presets"]?.array ?? []).compactMap { $0.object.map(ImagePreset.init(json:)) }
    }

    /// 当前生效的那一套：activeId 指的那套，没有就第一套（网页版 activeImage）。
    var activeImage: ImagePreset? {
        let list = imagePresets
        let id = services["image"]?.object?["activeId"]?.string
        return list.first { $0.id == id } ?? list.first
    }

    /// 能不能生图：当前那一套填了密钥与模型（网页版 isImageReady）。
    var imageReady: Bool { activeImage?.ready ?? false }
}

/// 生图（网页版 ai/image.js 与 ai/imageprompt.js）。
///
/// 一个 `[图片：…]` 一次请求，是角色发图这件事本身的花法；失败不重试、不换接口，记在那条消息上，由用户点「重新生成」。
/// 「生图前翻译」那一档每张含中文的图在生成之前多一次文字请求，默认关，登记在 ExtraCalls。
/// 锁脸（参考图、读脸）、生图世界书、衣帽间原生版还没有，提示词里只拼画面描述、点名角色的外貌、角色与全局的固定提示词、画风预设。
enum ImageGen {
    // MARK: - 尺寸

    /// 认得出就规整成「宽x高」，认不出按 1024 见方（网页版 sizeText）。
    static func sizeText(_ v: String) -> String {
        let pattern = #"^\s*(\d{2,5})\s*[x×]\s*(\d{2,5})\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)),
              let w = Range(m.range(at: 1), in: v), let h = Range(m.range(at: 2), in: v) else { return "1024x1024" }
        return "\(v[w])x\(v[h])"
    }

    // MARK: - 提示词

    /// 一段提示词里写了单独成行的「Negative」就在那儿切开，后面那一段是负面（网页版 imageprompt.js 的 cut）。
    static func cut(_ text: String) -> (pos: String, neg: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let negHead = #"(^|\n)[ \t]*(negative([ \t]*prompt)?|负面(提示词)?|反向(提示词)?)[ \t]*[:：]?[ \t]*(\n|$)"#
        let posHead = #"(^|\n)[ \t]*(positive([ \t]*prompt)?|正面(提示词)?)[ \t]*[:：]?[ \t]*(\n|$)"#
        var pos = t
        var neg = ""
        if let r = t.range(of: negHead, options: [.regularExpression, .caseInsensitive]) {
            let tail = t[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                // 切到那一行本身的前面：开头那个换行不算
                var start = r.lowerBound
                if t[start] == "\n" { start = t.index(after: start) }
                pos = String(t[..<start])
                neg = tail
            }
        }
        if let r = pos.range(of: posHead, options: [.regularExpression, .caseInsensitive]) {
            pos.replaceSubrange(r, with: pos[r].hasPrefix("\n") ? "\n" : "")
        }
        return (pos.trimmingCharacters(in: .whitespacesAndNewlines), neg)
    }

    struct Part: Equatable {
        var from: String
        var text: String
        var negative: Bool
    }

    /// 画风预设（网页版 STYLES），默认全关，开着的存在 settings.imageStyles 里。
    struct Style: Identifiable, Sendable {
        let id: String
        let label: String
        let ask: String
        let tail: String
    }

    static let styles: [Style] = [
        Style(id: "daily", label: "日常拍照分享", ask: "style.daily.ask", tail: "style.daily.tail"),
    ]

    static func stylesOn(_ s: AppSettings) -> [Style] {
        let on = Set((s.raw["imageStyles"]?.array ?? []).compactMap(\.string))
        return styles.filter { on.contains($0.id) }
    }

    /// 加在写描述那一方身上的那几句（网页版 styleAsk）。
    static func styleAsk(_ s: AppSettings) -> String {
        stylesOn(s).map { Templates.get($0.ask, settings: s) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 最终提示词由哪几段拼成：画面描述、点了名的那几位的外貌、角色固定提示词、画风预设、全局提示词。
    /// 每一段里单独成行的 Negative 之后摘出来放进负面（网页版 parts）。
    static func parts(prompt: String, char: Character?, all: [Character], settings s: AppSettings) -> [Part] {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var raw: [(String, String)] = [("画面描述", text)]
        // 描述里点了名（两个字以上）的那几位，各自卡上写的外貌。当前角色先来
        var seen = Set<String>()
        for c in ([char].compactMap { $0 } + all) where !seen.contains(c.id) {
            let name = c.row.string("name").trimmingCharacters(in: .whitespaces)
            let look = c.row.string("appearance").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? c.row.string("faceDesc").trimmingCharacters(in: .whitespacesAndNewlines)
                : c.row.string("appearance").trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2, !look.isEmpty, text.contains(name) else { continue }
            seen.insert(c.id)
            raw.append(("「\(name)」的外貌", "\(name): \(look)"))
        }
        let own = char?.row.string("imagePrompt").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !own.isEmpty { raw.append(("这个角色的固定提示词", own)) }
        for st in stylesOn(s) {
            let t = Templates.get(st.tail, settings: s).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { raw.append(("生图预设「\(st.label)」", t)) }
        }
        let global = (s.raw["imagePrompt"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty { raw.append(("全局生图提示词", global)) }

        var out: [Part] = []
        for (from, t) in raw {
            let c = cut(t)
            if !c.pos.isEmpty { out.append(Part(from: from, text: c.pos, negative: false)) }
            if !c.neg.isEmpty { out.append(Part(from: "\(from) 里的负面部分", text: c.neg, negative: true)) }
        }
        return out
    }

    static func compose(_ parts: [Part]) -> String { parts.filter { !$0.negative }.map(\.text).joined(separator: "\n") }
    static func negativeOf(_ parts: [Part]) -> String { parts.filter(\.negative).map(\.text).joined(separator: "\n") }

    /// 接口自己那一栏的负面词，加上从正向里摘出来的那几段。
    static func negText(_ p: ImagePreset, _ extra: String) -> String {
        [p.negative.trimmingCharacters(in: .whitespacesAndNewlines), extra.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 「生图前翻译」那一档：含中日韩文字的提示词先经文字接口译成英文。译失败照原文画，不重试（网页版 toEnglish）。
    static func toEnglish(_ p: ImagePreset, _ text: String) async -> String {
        guard p.promptLang == "translate",
              text.range(of: #"[぀-ヿ㐀-鿿가-힯]"#, options: .regularExpression) != nil else { return text }
        do {
            let r = try await AIService.shared.send(task: "image.translate", system: Templates.get("task.image-translate", settings: .load()),
                                                    messages: [AIMessage(role: .user, content: text)], maxTokens: 1200)
            let out = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? text : out
        } catch {
            Diagnostics.shared.record("image-translate-failed", ["error": error.localizedDescription])
            return text
        }
    }

    // MARK: - 请求

    /// 画一张。返回图片的原始字节。每次真正发出去之前记一笔账。
    static func generate(prompt: String, negative: String = "", preset p: ImagePreset) async throws -> Data {
        guard p.ready else { throw StoreError(message: "还没有配置生图接口") }
        let raw = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw StoreError(message: "这一张没有提示词，没有可画的内容") }
        let text = await toEnglish(p, raw)
        try Task.checkCancellation()
        await Usage.shared.note(task: "image")
        let started = Date()
        do {
            let data: Data
            switch p.kind {
            case "nai": data = try await novelai(p, text)
            case "chat": data = try await chatImage(p, text)
            default: data = try await openai(p, text, negative: negative)
            }
            Diagnostics.shared.record("image", ["kind": p.kind, "model": p.model, "bytes": data.count,
                                                "ms": Int(Date().timeIntervalSince(started) * 1000)])
            return data
        } catch {
            Diagnostics.shared.record("image-failed", ["kind": p.kind, "model": p.model, "error": error.localizedDescription])
            throw error
        }
    }

    private static func post(_ url: String, _ p: ImagePreset, _ body: [String: JSONValue]) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw StoreError(message: "生图接口地址无效：\(url)") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(p.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "authorization")
        req.httpBody = try JSONValue.object(body).encoded()
        req.timeoutInterval = p.timeout > 0 ? p.timeout : 86400
        let started = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw StoreError(message: "生图接口没有返回有效的响应") }
            if !(200..<300).contains(http.statusCode) { throw asError(http.statusCode, data) }
            return (data, http)
        } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            let secs = Int(Date().timeIntervalSince(started))
            if e.code == .timedOut {
                throw StoreError(message: "生图接口等了 \(secs) 秒还没有回应。生图本来就慢，一张一两分钟很常见。可在该接口的「等待上限」里调大，或填 0 表示一直等。原始错误：\(e.localizedDescription)")
            }
            if secs >= 20 {
                throw StoreError(message: "生图接口的连接在请求发出 \(secs) 秒后中途断开（\(url)）。请求已经送达接口，接口可能已经生成图片并计费，但结果没有传回本机。原始错误：\(e.localizedDescription)")
            }
            throw StoreError(message: "连不上生图接口（\(url)）。请检查地址是否填写正确、网络是否可达。原始错误：\(e.localizedDescription)")
        }
    }

    private static func asError(_ status: Int, _ data: Data) -> StoreError {
        var detail = ""
        if let j = try? JSONValue.parse(data) {
            detail = j["error"]?["message"]?.string ?? j["error"]?.string ?? String((String(data: data, encoding: .utf8) ?? "").prefix(400))
        } else {
            detail = String((String(data: data, encoding: .utf8) ?? "").prefix(400))
        }
        let wants = #"上传.{0,6}图片|提供.{0,6}图片|参考或编辑|upload .{0,20}image|provide .{0,20}image|image[_ ]?url is required|reference image"#
        if detail.range(of: wants, options: [.regularExpression, .caseInsensitive]) != nil {
            return StoreError(message: "生图接口 \(status)：\(detail)\n这一家在要一张输入图，多半是把生图转给了一个只做图像编辑的模型。请换一个做文生图的模型。")
        }
        return StoreError(message: "生图接口 \(status)：\(detail.isEmpty ? "无详细信息" : detail)")
    }

    private static func openai(_ p: ImagePreset, _ text: String, negative: String) async throws -> Data {
        var body: [String: JSONValue] = ["model": .string(p.model), "prompt": .string(text), "n": .number(1), "size": .string(sizeText(p.size))]
        if !p.respFormat.isEmpty { body["response_format"] = .string(p.respFormat) }
        // 标准里没有这个字段，默认不发；有些中转站认它，由接口自己的开关定
        let neg = negText(p, negative)
        if p.negOn && !neg.isEmpty { body["negative_prompt"] = .string(neg) }
        let (data, _) = try await post(p.endpoint("images/generations"), p, body)
        guard let j = try? JSONValue.parse(data) else { throw StoreError(message: "生图接口返回的不是 JSON") }
        return try await pick(j)
    }

    private static func novelai(_ p: ImagePreset, _ text: String) async throws -> Data {
        let wh = sizeText(p.size).split(separator: "x").compactMap { Double($0) }
        let body: [String: JSONValue] = [
            "input": .string(text), "model": .string(p.model), "action": .string("generate"),
            "parameters": .object(["width": .number(wh.first ?? 1024), "height": .number(wh.last ?? 1024), "n_samples": .number(1),
                                   "qualityToggle": .bool(true), "ucPreset": .number(0), "negative_prompt": .string(p.negative)]),
        ]
        let (data, _) = try await post("\(p.base)/ai/generate-image", p, body)
        guard ZipReader.looksLikeZip(data), let zip = try? ZipReader(data: data),
              let e = zip.names.first(where: { $0.lowercased().hasSuffix(".png") }).flatMap({ zip.entry(named: $0) }),
              let png = zip.contents(of: e) else { throw StoreError(message: "接口回来的压缩包里没有图片") }
        return png
    }

    private static func chatImage(_ p: ImagePreset, _ text: String) async throws -> Data {
        let body: [String: JSONValue] = ["model": .string(p.model), "stream": .bool(false),
                                         "messages": .array([.object(["role": .string("user"), "content": .string(text)])])]
        let (data, _) = try await post(p.endpoint("chat/completions"), p, body)
        guard let j = try? JSONValue.parse(data) else { throw StoreError(message: "生图接口返回的不是 JSON") }
        let got = chatImageOf(j)
        guard !got.url.isEmpty else {
            let said = j["error"]?["message"]?.string ?? got.text
            throw StoreError(message: "回复里没有图片" + (said.isEmpty ? "，回复是空的" : "：\(said.prefix(160))")
                             + "。这个模型可能不在对话里出图，请换一个能出图的模型，或把类型改回 OpenAI 兼容。")
        }
        if got.url.lowercased().hasPrefix("data:") { return try base64(got.url) }
        return try await fetchImage(got.url)
    }

    /// 对话接口的回复里图在哪儿：message.images、content 里的图片段、正文里的 data URL 或图片链接（网页版 chatImageOf）。
    static func chatImageOf(_ j: JSONValue) -> (url: String, text: String) {
        let msg = j["choices"]?[0]?["message"] ?? .object([:])
        var urls: [String] = []
        for x in msg["images"]?.array ?? [] { urls.append(x["image_url"]?["url"]?.string ?? x["url"]?.string ?? "") }
        let parts = msg["content"]?.array ?? []
        for x in parts {
            if let s = x["image_url"]?.string { urls.append(s) } else if let s = x["image_url"]?["url"]?.string { urls.append(s) }
            let inl = x["inline_data"] ?? x["inlineData"]
            if let d = inl?["data"]?.string {
                urls.append("data:\(inl?["mime_type"]?.string ?? inl?["mimeType"]?.string ?? "image/png");base64,\(d)")
            }
            if let b = x["b64_json"]?.string { urls.append("data:image/png;base64,\(b)") }
        }
        let text = msg["content"]?.string ?? parts.compactMap { $0["text"]?.string }.joined(separator: "\n")
        if let r = text.range(of: #"data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\s]+"#, options: .regularExpression) {
            urls.append(String(text[r]))
        }
        let links = matches(#"https?://[^\s)"'<>\]]+"#, in: text)
        urls.append(links.first { $0.range(of: #"\.(png|jpe?g|webp|gif)(\?|$)"#, options: [.regularExpression, .caseInsensitive]) != nil } ?? links.first ?? "")
        return (urls.first { !$0.isEmpty } ?? "", text)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// 从回包里取图：b64_json、b64、image、整个就是字符串，或者一个链接（网页版 pickImage）。
    static func pick(_ j: JSONValue) async throws -> Data {
        let row = j["data"]?[0] ?? j["images"]?[0] ?? j[0]
        func str(_ v: JSONValue?) -> String {
            guard let s = v?.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
            return s
        }
        let b64 = [str(row?["b64_json"]), str(row?["b64"]), str(row?["image"]), str(row)].first { !$0.isEmpty } ?? ""
        if !b64.isEmpty { return try base64(b64) }
        let url = [str(row?["url"]), str(row?["image_url"]), str(j["url"])].first { !$0.isEmpty } ?? ""
        if !url.isEmpty { return try await fetchImage(url) }
        if let said = j["error"]?["message"]?.string ?? j["message"]?.string { throw StoreError(message: said) }
        let peek = String((String(data: (try? j.encoded()) ?? Data(), encoding: .utf8) ?? "").prefix(200))
        throw StoreError(message: "接口没有返回图片。回包是：\(peek)")
    }

    /// 接口只给了链接：再取一次。200 不等于取到了图，看一眼是不是图片。
    private static func fetchImage(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw StoreError(message: "接口返回的图片链接无效") }
        let got = try? await URLSession.shared.data(from: u)
        guard let got, let http = got.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StoreError(message: "接口只返回了图片链接，且取不回来。可在该生图接口的「返回格式」中改为 base64。")
        }
        let data = got.0
        let type = http.value(forHTTPHeaderField: "content-type") ?? ""
        if !type.lowercased().hasPrefix("image/") && !looksLikeImage(data) {
            let peek = String((String(data: data.prefix(400), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            throw StoreError(message: "那个图片链接回来的不是图片" + (peek.isEmpty ? "" : "：\(peek)"))
        }
        return data
    }

    private static func looksLikeImage(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(4))
        guard b.count >= 4 else { return false }
        return (b[0] == 0x89 && b[1] == 0x50) || (b[0] == 0xFF && b[1] == 0xD8) || (b[0] == 0x47 && b[1] == 0x49) || (b[0] == 0x52 && b[1] == 0x49)
    }

    /// base64 转字节。先摘掉 data URL 的前缀与折行的空白（网页版 b64ToBlob）。
    static func base64(_ raw: String) throws -> Data {
        var s = raw
        if s.lowercased().hasPrefix("data:"), let comma = s.firstIndex(of: ",") { s = String(s[s.index(after: comma)...]) }
        s = s.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        guard let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters), !d.isEmpty else {
            throw StoreError(message: "接口回来的图片数据不是有效的 base64")
        }
        return d
    }

    // MARK: - 消息上的那一张

    /// 角色写的一张 `[图片：…]`：画出来存好，写回那条消息。失败写 error 与原因，不重试。
    /// 已经不是 pending 的不画：同一条消息绝不画第二次，除非用户点了「重新生成」（那一步先把它改回 pending）。
    @discardableResult
    static func fill(messageId: String, queued: Bool = false) async -> Message? {
        guard let row = try? Database.shared.get(Collections.messages, id: messageId),
              row.string("kind") == "image", row.string("media") == "pending" else {
            if queued { MediaJobs.release(messageId) }
            return nil
        }
        let s = AppSettings.load()
        guard let preset = s.activeImage, preset.ready else {
            if queued { MediaJobs.release(messageId) }
            return try? update(messageId) { $0["media"] = .string("off"); $0["mediaError"] = .string("还没有配置生图接口") }
        }
        // 已经排上的（落库时就占住了）照常画；别处正在画的不再画第二张
        if !queued { guard MediaJobs.claim(messageId) else { return nil } }
        let out = await draw(row, preset: preset, settings: s)
        MediaJobs.release(messageId)
        return out
    }

    private static func draw(_ row: Row, preset: ImagePreset, settings s: AppSettings) async -> Message? {
        let messageId = row.id
        let char = try? Repo.character(row.string("authorId"))
        do {
            let all = (try? Repo.characters()) ?? []
            let ps = parts(prompt: row.string("prompt"), char: char, all: all, settings: s)
            guard !row.string("prompt").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StoreError(message: "这一张没有提示词，没有可画的内容")
            }
            let data = try await generate(prompt: compose(ps), negative: negativeOf(ps), preset: preset)
            // 存这一步失败不再画：图已经画回来了，重画一张也一样存不进去
            let id = try Images.save(data, maxPixel: 1024)
            return try update(messageId) {
                $0["imageId"] = .string(id)
                $0["media"] = .string("done")
                $0["mediaError"] = .string("")
            }
        } catch is CancellationError {
            return try? update(messageId) { $0["media"] = .string("off"); $0["mediaError"] = .string("") }
        } catch {
            return try? update(messageId) { $0["media"] = .string("error"); $0["mediaError"] = .string(error.localizedDescription) }
        }
    }

    /// 用户点了「重新生成」：改回 pending 再画一次。旧图不删：原生版不自己删图，留给「存储」里统一清理（网页版第 20 条）。
    static func regenerate(messageId: String) async throws -> Message? {
        guard var row = try Database.shared.get(Collections.messages, id: messageId), row.string("kind") == "image" else { return nil }
        row["imageId"] = .null
        row["media"] = .string("pending")
        row["mediaError"] = .string("")
        row.touch()
        try Database.shared.put(Collections.messages, row)
        return await fill(messageId: messageId)
    }

    /// 一轮里落下的几张，按顺序一张一张画，在后台跑，不挡着聊天。
    static func launch(_ created: [Message], onRow: @escaping ChatEngine.OnRow) {
        let ids = created.filter { $0.kind == "image" && $0.row.string("media") == "pending" }.map(\.id)
        guard !ids.isEmpty else { return }
        Task.detached {
            for id in ids { if let m = await ImageGen.fill(messageId: id, queued: true) { onRow(m) } }
        }
    }

    private static func update(_ id: String, _ change: (inout Row) -> Void) throws -> Message? {
        guard var row = try Database.shared.get(Collections.messages, id: id) else { return nil }
        change(&row)
        row.touch()
        try Database.shared.put(Collections.messages, row)
        return Message(row: row)
    }
}

/// 这一次打开应用以来正在画（或排着队等画）的那几条。消息停在 pending 而不在这里，是上一次没画完就退出了：
/// 界面上显示中断，给「重新生成」。同步加锁：落库那一刻就记上，界面不会先看到一个「中断」。
final class MediaJobs: @unchecked Sendable {
    static let shared = MediaJobs()
    private let lock = NSLock()
    private var running: Set<String> = []

    /// 占住这一条。已经有人在画就返回 false：同一条消息同一时间只画一张。
    static func claim(_ id: String) -> Bool {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return shared.running.insert(id).inserted
    }

    static func release(_ id: String) {
        shared.lock.lock(); defer { shared.lock.unlock() }
        shared.running.remove(id)
    }

    static func isRunning(_ id: String) -> Bool {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return shared.running.contains(id)
    }
}

extension AppSettings {
    private var imageService: [String: JSONValue] { services["image"]?.object ?? [:] }

    private mutating func setImageService(_ cfg: [String: JSONValue]) {
        var all = services
        all["image"] = .object(cfg)
        raw["services"] = .object(all)
    }

    /// 新建一套，还没有当前那一套时它就是当前的（网页版 newImagePreset）。
    @discardableResult
    mutating func addImagePreset(kind: String = "openai") -> String {
        var cfg = imageService
        let p = ImagePreset.new(kind: kind)
        cfg["presets"] = .array((cfg["presets"]?.array ?? []) + [.object(p)])
        if (cfg["activeId"]?.string ?? "").isEmpty { cfg["activeId"] = p["id"] }
        setImageService(cfg)
        return p["id"]?.string ?? ""
    }

    mutating func patchImagePreset(_ id: String, _ patch: [String: JSONValue]) {
        var cfg = imageService
        cfg["presets"] = .array((cfg["presets"]?.array ?? []).map { v in
            guard var o = v.object, o["id"]?.string == id else { return v }
            o.merge(patch) { _, new in new }
            return .object(o)
        })
        setImageService(cfg)
    }

    mutating func removeImagePreset(_ id: String) {
        var cfg = imageService
        let rest = (cfg["presets"]?.array ?? []).filter { $0["id"]?.string != id }
        cfg["presets"] = .array(rest)
        if cfg["activeId"]?.string == id { cfg["activeId"] = rest.first?["id"] ?? .null }
        setImageService(cfg)
    }

    mutating func setActiveImage(_ id: String) {
        var cfg = imageService
        cfg["activeId"] = .string(id)
        setImageService(cfg)
    }
}
