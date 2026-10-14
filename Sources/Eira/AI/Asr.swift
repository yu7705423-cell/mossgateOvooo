import AVFoundation
import Foundation
import Speech

extension AppSettings {
    /// 语音识别接口（services.asr）。地址与密钥可以指向已有的一套（endpointId）。
    var asrConfig: [String: JSONValue] { service("asr") }
    var asrReady: Bool {
        let a = asrConfig
        return !(a["apiKey"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && !(a["model"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
    /// text：只转文字（/audio/transcriptions）；tone：连语气一起读（chat/completions，音频作为 input_audio）
    var asrMode: String { asrConfig["mode"]?.string == "tone" ? "tone" : "text" }
}

/// 把用户发的语音读成文字（网页版 ai/asr.js）。录音本来就是 16k 单声道 wav，两档都直接用。
///
/// 每条语音一次请求，是用户发语音这件事本身的花法。重试取 1 与用户的 retryMax 里较小的那个（默认 0），和网页版一样。
enum Asr {
    struct Heard: Sendable {
        var text: String
        var tone: String
    }

    static func transcribe(wav: Data) async throws -> Heard {
        let s = AppSettings.load()
        guard s.asrReady else { throw StoreError(message: "尚未配置语音识别接口") }
        let a = s.asrConfig
        var base = (a["baseUrl"]?.string ?? "").replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        if base.isEmpty { base = "https://api.openai.com/v1" }
        if base.range(of: #"/v\d+$"#, options: .regularExpression) == nil { base += "/v1" }
        let key = (a["apiKey"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (a["model"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tries = min(1, s.retryMax)
        var last: Error = StoreError(message: "语音识别失败")
        for attempt in 0...tries {
            try Task.checkCancellation()
            await Usage.shared.note(task: "asr")
            do {
                return s.asrMode == "tone"
                    ? try await withTone(base: base, key: key, model: model, wav: wav, settings: s)
                    : try await textOnly(base: base, key: key, model: model, wav: wav)
            } catch let e as AsrError {
                last = e
                guard e.retryable, attempt < tries else { break }
                try await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        throw last
    }

    struct AsrError: LocalizedError {
        var status: Int?
        var message: String
        var errorDescription: String? { message }
        var retryable: Bool { status == nil || status == 429 || (status ?? 0) >= 500 }
    }

    private static func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw AsrError(status: nil, message: "连不上语音识别接口：\(e.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let j = try? JSONValue.parse(data)
            let detail = j?["error"]?["message"]?.string ?? String((String(data: data, encoding: .utf8) ?? "").prefix(200))
            throw AsrError(status: status, message: "语音识别接口 \(status): \(detail)")
        }
        return data
    }

    private static func textOnly(base: String, key: String, model: String, wav: Data) async throws -> Heard {
        guard let url = URL(string: "\(base)/audio/transcriptions") else { throw AsrError(status: 0, message: "语音识别接口地址无效") }
        let boundary = "eira-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))
        // 不传 language，让它自己判断。中英混说时写死反而会错
        field("model", model)
        body.append(Data("--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        req.httpBody = body
        req.timeoutInterval = 120
        let data = try await send(req)
        let text = ((try? JSONValue.parse(data))?["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AsrError(status: 0, message: "没有识别出内容") }
        return Heard(text: text, tone: "")
    }

    private static func withTone(base: String, key: String, model: String, wav: Data, settings s: AppSettings) async throws -> Heard {
        guard let url = URL(string: "\(base)/chat/completions") else { throw AsrError(status: 0, message: "语音识别接口地址无效") }
        let body: JSONValue = .object([
            "model": .string(model), "max_tokens": .number(600),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(Templates.get("task.asr-tone", settings: s))]),
                .object(["role": .string("user"), "content": .array([
                    .object(["type": .string("text"), "text": .string("这是一段语音，按要求输出 JSON。")]),
                    .object(["type": .string("input_audio"), "input_audio": .object(["data": .string(wav.base64EncodedString()), "format": .string("wav")])]),
                ])]),
            ]),
        ])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        req.httpBody = try body.encoded()
        req.timeoutInterval = 120
        let data = try await send(req)
        let raw = (try? JSONValue.parse(data))?["choices"]?[0]?["message"]?["content"]?.string ?? ""
        guard let parsed = JSONReply.parse(raw), parsed.object != nil else {
            // 没按格式来，至少把它说的话当转写用上
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw AsrError(status: 0, message: "语音识别接口没有返回内容") }
            return Heard(text: t, tone: "")
        }
        var bits: [String] = []
        for k in ["tone", "emotion", "pace", "notes"] {
            let v = (parsed[k]?.string ?? "").trimmingCharacters(in: .whitespaces)
            if !v.isEmpty && !bits.contains(v) { bits.append(v) }
        }
        return Heard(text: (parsed["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), tone: bits.joined(separator: "、"))
    }

    // MARK: - 本机识别

    /// 没配识别接口时用系统自带的识别读那段录音。不经网络接口，不计费。
    static func local(_ url: URL) async -> String {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized, let r = SFSpeechRecognizer(), r.isAvailable else { return "" }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        return await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            var done = false
            r.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    c.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    done = true
                    c.resume(returning: "")
                }
            }
        }
    }

    // MARK: - 用户发的语音

    /// 录好的一段：存成文件，落一条语音消息。配了识别接口就交给接口读，没配用本机识别。
    /// 返回落下的那一条；识别完成后经 onUpdate 交回更新过的那一条。
    static func sendRecording(_ wav: Data, seconds: Int, chatId: String, quote: Message?,
                              onUpdate: @escaping @Sendable (Message) -> Void) throws -> Message {
        let audioId = try Files.save(wav, ext: "wav", type: "audio/wav")
        let useApi = AppSettings.load().asrReady
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: "[语音]", kind: "voice")
        m.row["audioId"] = .string(audioId)
        m.row["seconds"] = .number(Double(max(1, seconds)))
        m.row["status"] = .string("done")
        m.row["media"] = .string("done")
        m.row["asr"] = .string("pending")
        if let quote { for (k, v) in MessageActions.quoteFields(of: quote) { m.row[k] = v } }
        m = try Repo.append(m)
        try touchChat(chatId)
        let id = m.id
        Task.detached {
            var change: (inout Row) -> Void
            if useApi {
                do {
                    let h = try await Asr.transcribe(wav: wav)
                    change = {
                        $0["voiceText"] = .string(h.text)
                        $0["tone"] = .string(h.tone)
                        $0["asr"] = .string("done")
                        $0["content"] = .string("[语音：\(h.text)]" + (h.tone.isEmpty ? "" : "（听起来\(h.tone)）"))
                    }
                } catch {
                    let msg = error.localizedDescription
                    change = { $0["asr"] = .string("error"); $0["mediaError"] = .string(msg) }
                }
            } else {
                let text = await Asr.local(MediaStore.url(.files, id: audioId) ?? URL(fileURLWithPath: "/dev/null"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    change = { $0["asr"] = .string("error"); $0["mediaError"] = .string("本机识别没有听出内容") }
                } else {
                    change = { $0["voiceText"] = .string(text); $0["asr"] = .string("done"); $0["content"] = .string("[语音：\(text)]") }
                }
            }
            do {
                guard var row = try Database.shared.get(Collections.messages, id: id) else { return }
                change(&row)
                row.touch()
                try Database.shared.put(Collections.messages, row)
                onUpdate(Message(row: row))
            } catch {
                Problems.report("语音识别结果未能保存：\(error.localizedDescription)")
            }
        }
        return m
    }

    /// 不录音，打一段字发成语音。角色收到的与真录一段相同。
    static func sendTyped(_ text: String, chatId: String, quote: Message?) throws -> Message {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: "[语音：\(t)]", kind: "voice")
        m.row["audioId"] = .null
        m.row["seconds"] = .number(Double(max(1, Int((Double(t.count) / 4).rounded()))))
        m.row["voiceText"] = .string(t)
        m.row["asr"] = .string("done")
        m.row["status"] = .string("done")
        m.row["media"] = .string("done")
        if let quote { for (k, v) in MessageActions.quoteFields(of: quote) { m.row[k] = v } }
        m = try Repo.append(m)
        try touchChat(chatId)
        return m
    }

    private static func touchChat(_ chatId: String) throws {
        if var c = try Repo.chat(chatId) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
    }
}

/// 录音：16k 单声道 wav，识别接口与本机识别都直接收。
@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var seconds = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL?

    func start() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw StoreError(message: "没有麦克风权限。可在系统「设置 - 隐私与安全性 - 麦克风」中开启。") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let r = try AVAudioRecorder(url: u, settings: settings)
        guard r.record() else { throw StoreError(message: "录音未能开始") }
        recorder = r
        url = u
        seconds = 0
        recording = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.seconds += 1 }
        }
    }

    /// 停下，交回录好的那一段与秒数。
    func stop() -> (Data, Int)? {
        timer?.invalidate()
        timer = nil
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        recording = false
        defer { if let url { try? FileManager.default.removeItem(at: url) }; url = nil }
        guard let url, let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        return (data, max(1, Int(duration.rounded())))
    }

    func cancel() { _ = stop() }
}

/// 播放语音。同一时间只放一条。
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()
    @Published private(set) var playing: String?
    @Published var problem: String?
    private var player: AVAudioPlayer?

    func toggle(_ messageId: String, audioId: String) {
        if playing == messageId { stop(); return }
        stop()
        guard let url = MediaStore.url(.files, id: audioId) else { problem = "这段语音的文件已不存在"; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            player = p
            playing = messageId
        } catch {
            problem = "无法播放：\(error.localizedDescription)"
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = nil; self.player = nil }
    }

    /// 这段语音有多长（秒）。读不出来按 0。
    static func duration(_ audioId: String) -> Int {
        guard let url = MediaStore.url(.files, id: audioId), let p = try? AVAudioPlayer(contentsOf: url) else { return 0 }
        return max(1, Int(p.duration.rounded()))
    }
}
