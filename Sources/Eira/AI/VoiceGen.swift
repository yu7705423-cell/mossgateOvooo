import Foundation

/// 一套语音合成接口。和网页版 services.js 的语音预设同一形状，存在 settings.services.voice.presets 里；
/// 总开关 enabled 不跟预设走。
struct VoicePreset: Identifiable, Equatable, Sendable {
    struct Choice: Identifiable, Sendable {
        let id: String
        let label: String
        var base = ""
        var mm = ""
        var iso = ""
    }

    /// 三家（网页版 voice.js 的 KINDS）
    static let kinds: [Choice] = [
        Choice(id: "minimax", label: "MiniMax", base: "https://api.minimaxi.com"),
        Choice(id: "openai", label: "OpenAI 兼容", base: "https://api.openai.com/v1"),
        Choice(id: "eleven", label: "ElevenLabs", base: "https://api.elevenlabs.io"),
    ]

    /// 语种（网页版 LANGS）。mm 是 MiniMax 认的名字，iso 是 ElevenLabs 认的码
    static let langs: [Choice] = [
        Choice(id: "", label: "自动"), Choice(id: "zh", label: "中文", mm: "Chinese", iso: "zh"),
        Choice(id: "yue", label: "粤语", mm: "Chinese,Yue", iso: "zh"), Choice(id: "en", label: "英语", mm: "English", iso: "en"),
        Choice(id: "ja", label: "日语", mm: "Japanese", iso: "ja"), Choice(id: "ko", label: "韩语", mm: "Korean", iso: "ko"),
        Choice(id: "es", label: "西班牙语", mm: "Spanish", iso: "es"), Choice(id: "fr", label: "法语", mm: "French", iso: "fr"),
        Choice(id: "de", label: "德语", mm: "German", iso: "de"), Choice(id: "it", label: "意大利语", mm: "Italian", iso: "it"),
        Choice(id: "pt", label: "葡萄牙语", mm: "Portuguese", iso: "pt"), Choice(id: "ru", label: "俄语", mm: "Russian", iso: "ru"),
        Choice(id: "ar", label: "阿拉伯语", mm: "Arabic", iso: "ar"), Choice(id: "id", label: "印尼语", mm: "Indonesian", iso: "id"),
        Choice(id: "th", label: "泰语", mm: "Thai", iso: "th"), Choice(id: "vi", label: "越南语", mm: "Vietnamese", iso: "vi"),
    ]

    static func lang(_ v: String) -> Choice? { langs.first { $0.id == v || $0.label == v } }

    /// 老数据平铺的那一份收成的第一套，角色从前填的 voiceId 归它
    static let legacyId = "voice-1"

    var json: [String: JSONValue]

    var id: String { json["id"]?.string ?? "" }
    var name: String {
        let n = json["name"]?.string ?? ""
        return n.isEmpty ? "未命名" : n
    }
    var kind: String {
        let k = json["kind"]?.string ?? ""
        return Self.kinds.contains { $0.id == k } ? k : "minimax"
    }
    var baseUrl: String { json["baseUrl"]?.string ?? "" }
    var groupId: String { json["groupId"]?.string ?? "" }
    var apiKey: String { (json["apiKey"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var model: String { (json["model"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var lang: String { json["lang"]?.string ?? "" }
    var prompt: String { json["prompt"]?.string ?? "" }

    /// 配全了没有：密钥必填；ElevenLabs 的模型可以留空（网页版 isVoiceReady，不把可选项算成必填）
    var ready: Bool { !apiKey.isEmpty && (kind == "eleven" || !model.isEmpty) }

    var base: String {
        let b = baseUrl.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        return b.isEmpty ? (Self.kinds.first { $0.id == kind }?.base ?? "") : b
    }

    static let empty: [String: JSONValue] = ["kind": .string("minimax"), "baseUrl": .string(""), "groupId": .string(""),
                                             "apiKey": .string(""), "model": .string(""), "lang": .string(""), "prompt": .string("")]
}

extension AppSettings {
    private var voiceService: [String: JSONValue] { services["voice"]?.object ?? [:] }

    /// 总开关
    var voiceEnabled: Bool { voiceService["enabled"]?.bool ?? false }

    /// 几套语音接口。老数据（平铺的一份）读的时候收成第一套 voice-1，不往库里写（网页版 normVoice）。
    var voicePresets: [VoicePreset] {
        let v = voiceService
        if let list = v["presets"]?.array, !list.isEmpty {
            return list.compactMap { $0.object }.map { p in
                var out = VoicePreset.empty
                out["name"] = .string("")
                out.merge(p) { _, new in new }
                return VoicePreset(json: out)
            }
        }
        var p = VoicePreset.empty
        p["id"] = .string(VoicePreset.legacyId)
        p["name"] = .string("语音 1")
        for k in ["kind", "baseUrl", "groupId", "apiKey", "model", "lang", "prompt"] {
            if let s = v[k]?.string, !s.isEmpty { p[k] = .string(s) }
        }
        return [VoicePreset(json: p)]
    }

    var activeVoice: VoicePreset? {
        let list = voicePresets
        let id = voiceService["activeId"]?.string
        return list.first { $0.id == id } ?? list.first
    }

    /// 总开关开着、当前那一套配全了
    var voiceReady: Bool { voiceEnabled && (activeVoice?.ready ?? false) }

    // MARK: - 改

    private mutating func setVoiceService(_ cfg: [String: JSONValue]) {
        var all = services
        all["voice"] = .object(cfg)
        raw["services"] = .object(all)
    }

    /// 写之前先把老数据收成预设形状，不然改一处就把平铺的那一份丢了。
    private mutating func normalizedVoice() -> [String: JSONValue] {
        var cfg = voiceService
        if (cfg["presets"]?.array ?? []).isEmpty {
            cfg["presets"] = .array(voicePresets.map { .object($0.json) })
            if cfg["activeId"] == nil || cfg["activeId"]?.isNull == true { cfg["activeId"] = .string(VoicePreset.legacyId) }
        }
        return cfg
    }

    mutating func setVoiceEnabled(_ on: Bool) {
        var cfg = normalizedVoice()
        cfg["enabled"] = .bool(on)
        setVoiceService(cfg)
    }

    @discardableResult
    mutating func addVoicePreset() -> String {
        var cfg = normalizedVoice()
        let list = cfg["presets"]?.array ?? []
        var p = VoicePreset.empty
        let id = Ids.make("voice")
        p["id"] = .string(id)
        p["name"] = .string("语音 \(list.count + 1)")
        cfg["presets"] = .array(list + [.object(p)])
        if (cfg["activeId"]?.string ?? "").isEmpty { cfg["activeId"] = .string(id) }
        setVoiceService(cfg)
        return id
    }

    mutating func patchVoicePreset(_ id: String, _ patch: [String: JSONValue]) {
        var cfg = normalizedVoice()
        cfg["presets"] = .array((cfg["presets"]?.array ?? []).map { v in
            guard var o = v.object, o["id"]?.string == id else { return v }
            o.merge(patch) { _, new in new }
            return .object(o)
        })
        setVoiceService(cfg)
    }

    mutating func removeVoicePreset(_ id: String) {
        var cfg = normalizedVoice()
        let rest = (cfg["presets"]?.array ?? []).filter { $0["id"]?.string != id }
        cfg["presets"] = .array(rest)
        if cfg["activeId"]?.string == id { cfg["activeId"] = rest.first?["id"] ?? .null }
        setVoiceService(cfg)
    }

    mutating func setActiveVoice(_ id: String) {
        var cfg = normalizedVoice()
        cfg["activeId"] = .string(id)
        setVoiceService(cfg)
    }
}

/// 语音合成（网页版 ai/voice.js）。
///
/// 角色写的一句 `[语音：…]` 合成一次，是角色发语音这件事本身的花法；失败不重试，记在那条消息上，由用户点「重新合成」。
/// 台本（按情绪切段、一段一次）原生版还没有：带标记的一句原样念。
enum VoiceGen {
    /// 这个角色在某套语音接口上的音色 ID。按预设各填一个（char.voiceIds[预设 id]）；第一套沿用老字段 voiceId（网页版 idOf）。
    static func voiceId(_ char: Character?, presetId: String) -> String {
        guard let char else { return "" }
        let own = (char.row["voiceIds"]?[presetId]?.string ?? "").trimmingCharacters(in: .whitespaces)
        if !own.isEmpty { return own }
        return presetId == VoicePreset.legacyId ? char.row.string("voiceId").trimmingCharacters(in: .whitespaces) : ""
    }

    /// 写音色 ID 的那几个字段。第一套同时写回老字段，网页版旧版本读得到。
    static func voiceIdPatch(_ char: Character, presetId: String, id: String) -> [String: JSONValue] {
        var ids = char.row["voiceIds"]?.object ?? [:]
        ids[presetId] = .string(id)
        var out: [String: JSONValue] = ["voiceIds": .object(ids)]
        if presetId == VoicePreset.legacyId { out["voiceId"] = .string(id) }
        return out
    }

    /// 角色卡上填了风格与语种就用角色卡的，没填用这套接口自己的（网页版 styleFor）。
    static func style(_ char: Character?, _ p: VoicePreset) -> (prompt: String, lang: String) {
        let cp = char?.row.string("voicePrompt").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cl = char?.row.string("voiceLang").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (cp.isEmpty ? p.prompt.trimmingCharacters(in: .whitespacesAndNewlines) : cp,
                cl.isEmpty ? p.lang.trimmingCharacters(in: .whitespacesAndNewlines) : cl)
    }

    /// 这个角色能不能发语音：语音开着、当前那套配全、这个角色在那一套上有音色、角色卡没关掉。
    static func canSpeak(_ char: Character, _ s: AppSettings) -> Bool {
        guard s.voiceReady, let p = s.activeVoice else { return false }
        return !voiceId(char, presetId: p.id).isEmpty && char.row["canSendVoice"]?.bool != false
    }

    // MARK: - 请求

    /// 合成一句，返回 mp3 字节。真正发出去之前记一笔账。
    /// 带台本标记的（VoiceScript）按情绪切段，一段一次请求，音频按顺序接上；没有标记就是从前那一次请求
    static func speak(text: String, voiceId: String, speed: Double = 1, prompt: String = "", lang: String = "",
                      preset p: VoicePreset) async throws -> Data {
        guard !p.apiKey.isEmpty else { throw StoreError(message: "还没有配置语音接口") }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !VoiceScript.plain(t).isEmpty else { throw StoreError(message: "没有可以朗读的文字") }
        let style = (prompt: prompt.isEmpty ? p.prompt : prompt, lang: lang.isEmpty ? p.lang : lang)
        guard VoiceScript.hasTags(t) else { return try await one(p, t, voiceId, speed, style.prompt, style.lang) }
        var out = Data()
        for seg in VoiceScript.plan(p.kind, t, baseMood: style.prompt, model: p.model) {
            let segText = VoiceScript.text(p.kind, seg, model: p.model)
            if segText.isEmpty { continue }
            // MiniMax 的情绪只认固定几个词，拿这一段的情绪词本身去认；别家收自由文本，这一段的情绪与角色卡那一份一起给
            let segPrompt = p.kind == "minimax" ? (seg.mood.isEmpty ? style.prompt : seg.mood)
                : [seg.mood != style.prompt ? seg.mood : "", style.prompt].filter { !$0.isEmpty }.joined(separator: "；")
            out.append(try await one(p, segText, voiceId, speed, segPrompt, style.lang))
        }
        if out.isEmpty { throw StoreError(message: "台本里没有可念的内容") }
        return out
    }

    private static func one(_ p: VoicePreset, _ t: String, _ voiceId: String, _ speed: Double, _ prompt: String, _ lang: String) async throws -> Data {
        try Task.checkCancellation()
        await Usage.shared.note(task: "tts")
        let started = Date()
        do {
            let data: Data
            switch p.kind {
            case "openai": data = try await openai(p, t, voiceId, speed, prompt, lang)
            case "eleven": data = try await eleven(p, t, voiceId, speed, lang)
            default: data = try await minimax(p, t, voiceId, speed, prompt, lang)
            }
            Diagnostics.shared.record("tts", ["kind": p.kind, "model": p.model, "bytes": data.count,
                                              "ms": Int(Date().timeIntervalSince(started) * 1000)])
            return data
        } catch {
            Diagnostics.shared.record("tts-failed", ["kind": p.kind, "model": p.model, "error": error.localizedDescription])
            throw error
        }
    }

    private static func post(_ url: String, headers: [String: String], body: [String: JSONValue]) async throws -> Data {
        guard let u = URL(string: url) else { throw StoreError(message: "语音接口地址无效：\(url)") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONValue.object(body).encoded()
        req.timeoutInterval = 120
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw StoreError(message: "连不上语音接口（\(url)）。请检查地址是否填写正确、网络是否可达。原始错误：\(e.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var detail = String((String(data: data, encoding: .utf8) ?? "").prefix(200))
            if let j = try? JSONValue.parse(data) {
                detail = j["base_resp"]?["status_msg"]?.string ?? j["error"]?["message"]?.string
                    ?? j["detail"]?[0]?["msg"]?.string ?? j["detail"]?.string ?? detail
            }
            throw StoreError(message: "语音接口 \(status)：\(detail)")
        }
        return data
    }

    /// MiniMax：POST {base}/v1/t2a_v2。填了 GroupId 就带上。回来的是十六进制串，错误包在 200 里。
    private static func minimax(_ p: VoicePreset, _ text: String, _ voiceId: String, _ speed: Double,
                                _ prompt: String, _ lang: String) async throws -> Data {
        let q = p.groupId.trimmingCharacters(in: .whitespaces).isEmpty ? ""
            : "?GroupId=\(p.groupId.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        let boost = VoicePreset.lang(lang)?.mm ?? lang.trimmingCharacters(in: .whitespaces)
        var setting: [String: JSONValue] = ["voice_id": .string(voiceId), "speed": .number(speed), "vol": .number(1), "pitch": .number(0)]
        if let mood = mmEmotion(prompt) { setting["emotion"] = .string(mood) }
        var body: [String: JSONValue] = ["model": .string(p.model), "text": .string(text), "stream": .bool(false),
                                         "voice_setting": .object(setting),
                                         "audio_setting": .object(["format": .string("mp3"), "sample_rate": .number(32000)])]
        if !boost.isEmpty { body["language_boost"] = .string(boost) }
        let data = try await post("\(p.base)/v1/t2a_v2\(q)", headers: ["authorization": "Bearer \(p.apiKey)"], body: body)
        guard let j = try? JSONValue.parse(data) else { throw StoreError(message: "语音接口返回的不是 JSON") }
        if let code = j["base_resp"]?["status_code"]?.number, code != 0 {
            throw StoreError(message: "语音接口：\(j["base_resp"]?["status_msg"]?.string ?? String(Int(code)))")
        }
        guard let hex = j["data"]?["audio"]?.string, !hex.isEmpty, let out = Self.hex(hex) else {
            throw StoreError(message: "接口没有返回音频数据")
        }
        return out
    }

    /// MiniMax 的情绪只收几个固定的词（网页版 voicescript.js 的 mmEmotion）。认不得的不送。
    static func mmEmotion(_ prompt: String) -> String? {
        let map: [(String, [String])] = [
            ("happy", ["happy", "高兴", "开心", "愉快", "欢快"]), ("sad", ["sad", "难过", "伤心", "悲伤", "低落"]),
            ("angry", ["angry", "生气", "愤怒", "恼火"]), ("fearful", ["fearful", "害怕", "恐惧", "紧张"]),
            ("disgusted", ["disgusted", "厌恶", "嫌弃"]), ("surprised", ["surprised", "惊讶", "吃惊"]),
            ("calm", ["calm", "平静", "冷静", "淡定"]),
        ]
        let t = prompt.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return map.first { $0.1.contains { t.contains($0) } }?.0
    }

    /// OpenAI 兼容：POST {base}/audio/speech，回来的就是音频字节。风格与语种拼成一句 instructions。
    private static func openai(_ p: VoicePreset, _ text: String, _ voiceId: String, _ speed: Double,
                               _ prompt: String, _ lang: String) async throws -> Data {
        let url = p.base.range(of: #"/v\d+$"#, options: .regularExpression) != nil ? "\(p.base)/audio/speech" : "\(p.base)/v1/audio/speech"
        let known = VoicePreset.lang(lang)
        let name = known.map { $0.id.isEmpty ? "" : $0.label } ?? lang.trimmingCharacters(in: .whitespaces)
        let say = [prompt, name.isEmpty ? "" : "用\(name)朗读。"].filter { !$0.isEmpty }.joined(separator: " ")
        var body: [String: JSONValue] = ["model": .string(p.model), "input": .string(text), "voice": .string(voiceId.isEmpty ? "alloy" : voiceId),
                                         "speed": .number(speed), "response_format": .string("mp3")]
        if !say.isEmpty { body["instructions"] = .string(say) }
        return try await post(url, headers: ["authorization": "Bearer \(p.apiKey)"], body: body)
    }

    /// ElevenLabs：POST {base}/v1/text-to-speech/{voiceId}，鉴权走 xi-api-key。
    private static func eleven(_ p: VoicePreset, _ text: String, _ voiceId: String, _ speed: Double, _ lang: String) async throws -> Data {
        guard !voiceId.isEmpty else { throw StoreError(message: "这一家要求填写音色 id") }
        var body: [String: JSONValue] = ["text": .string(text),
                                         "voice_settings": .object(["stability": .number(0.5), "similarity_boost": .number(0.75), "speed": .number(speed)])]
        if !p.model.isEmpty { body["model_id"] = .string(p.model) }
        if let iso = VoicePreset.lang(lang)?.iso, !iso.isEmpty { body["language_code"] = .string(iso) }
        let id = voiceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voiceId
        return try await post("\(p.base)/v1/text-to-speech/\(id)", headers: ["xi-api-key": p.apiKey], body: body)
    }

    static func hex(_ s: String) -> Data? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        func v(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        while i < chars.count {
            guard let a = v(chars[i]), let b = v(chars[i + 1]) else { return nil }
            out.append(a << 4 | b)
            i += 2
        }
        return out
    }

    // MARK: - 消息上的那一条

    /// 角色写的一句 `[语音：…]`：合成、存好、写回那条消息。失败写 error 与原因，不重试。
    @discardableResult
    static func fill(messageId: String, queued: Bool = false) async -> Message? {
        guard let row = try? Database.shared.get(Collections.messages, id: messageId),
              row.string("kind") == "voice", row.string("media") == "pending" else {
            if queued { MediaJobs.release(messageId) }
            return nil
        }
        let s = AppSettings.load()
        let char = try? Repo.character(row.string("authorId"))
        guard s.voiceReady, let preset = s.activeVoice else {
            if queued { MediaJobs.release(messageId) }
            return try? update(messageId) { $0["media"] = .string("off"); $0["mediaError"] = .string("还没有配置语音接口") }
        }
        let vid = voiceId(char, presetId: preset.id)
        guard !vid.isEmpty else {
            if queued { MediaJobs.release(messageId) }
            return try? update(messageId) { $0["media"] = .string("off"); $0["mediaError"] = .string("这个角色在当前语音接口上还没有配音色") }
        }
        if !queued { guard MediaJobs.claim(messageId) else { return nil } }
        defer { MediaJobs.release(messageId) }
        do {
            let st = style(char, preset)
            let speed = char?.row.number("voiceSpeed") ?? 1
            // 先写成台本：原话不动，插上哪里停顿、哪里换情绪（依据是用户的语音世界书）。默认关，开了才多这一次
            let text = row.string("voiceText")
            let said = await PromptWrite.scriptFor(text, chatId: row.string("chatId"), char: (char ?? nil))
            if said != text { _ = try? update(messageId) { $0["voiceScript"] = .string(said) } }
            let data = try await speak(text: said, voiceId: vid, speed: speed > 0 ? speed : 1,
                                       prompt: st.prompt, lang: st.lang, preset: preset)
            let id = try Files.save(data, ext: "mp3", type: "audio/mpeg")
            return try update(messageId) {
                $0["audioId"] = .string(id)
                $0["media"] = .string("done")
                $0["mediaError"] = .string("")
            }
        } catch is CancellationError {
            return try? update(messageId) { $0["media"] = .string("off"); $0["mediaError"] = .string("") }
        } catch {
            return try? update(messageId) { $0["media"] = .string("error"); $0["mediaError"] = .string(error.localizedDescription) }
        }
    }

    /// 用户点了「重新合成」：改回 pending 再合成一次。
    static func regenerate(messageId: String) async throws -> Message? {
        guard var row = try Database.shared.get(Collections.messages, id: messageId), row.string("kind") == "voice" else { return nil }
        row["audioId"] = .null
        row["media"] = .string("pending")
        row["mediaError"] = .string("")
        row.touch()
        try Database.shared.put(Collections.messages, row)
        return await fill(messageId: messageId)
    }

    private static func update(_ id: String, _ change: (inout Row) -> Void) throws -> Message? {
        guard var row = try Database.shared.get(Collections.messages, id: id) else { return nil }
        change(&row)
        row.touch()
        try Database.shared.put(Collections.messages, row)
        return Message(row: row)
    }
}

/// 任意二进制附件（语音）。图片走 Images，那边会压缩，音频不能压（网页版 db/files.js）。
enum Files {
    /// 交给系统「存储到文件 / 发送」用的一份：拷到临时目录、起个看得懂的名字。原件不动
    static func exportURL(_ id: String, name: String) -> URL? {
        guard let src = MediaStore.url(.files, id: id) else { return nil }
        let safe = name.replacingOccurrences(of: #"[/\\:*?"<>|\s]+"#, with: "_", options: .regularExpression)
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "语音" : safe).\(src.pathExtension)")
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.copyItem(at: src, to: dst); return dst } catch { return nil }
    }

    static func save(_ data: Data, ext: String, type: String) throws -> String {
        let id = Ids.make("f")
        let dir = AppPaths.media.appendingPathComponent(MediaKind.files.rawValue, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("\(id).\(ext)"), options: .atomic)
        } catch {
            throw StoreError(message: "文件写入失败：\(error.localizedDescription)")
        }
        try Database.shared.registerMedia(kind: MediaKind.files.rawValue, id: id, ext: ext, bytes: data.count)
        return id
    }
}
