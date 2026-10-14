import XCTest
@testable import Eira

/// 语音：角色的一句 [语音：…] 合成一次，失败不重试，切版本不重合成；用户的语音每条识别一次。
final class VoiceTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private let chatPresets: JSONValue = .object([
        "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                     "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
        "activeId": .string("svc_main")])

    private func configure(enabled: Bool = true, kind: String = "minimax", asr: [String: JSONValue]? = nil) throws {
        var services: [String: JSONValue] = [
            "chat": chatPresets,
            "voice": .object(["enabled": .bool(enabled), "activeId": .string("v1"), "presets": .array([.object([
                "id": .string("v1"), "name": .string("测试"), "kind": .string(kind), "baseUrl": .string("https://tts.test"),
                "apiKey": .string("k"), "model": .string("speech-02-hd")])])]),
        ]
        if let asr { services["asr"] = .object(asr) }
        try setSettings(["services": .object(services)])
        var c = try XCTUnwrap(Repo.character("char_a"))
        c.row["voiceIds"] = .object(["v1": .string("female-1")])
        try Database.shared.put(Collections.characters, c.row)
    }

    private func isTTS(_ r: URLRequest) -> Bool { r.url?.host == "tts.test" }

    private func settle() async throws {
        for _ in 0..<100 {
            if !(try Repo.messages(chatId: "chat_a").contains { MediaJobs.isRunning($0.id) }) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("语音一直停在合成中")
    }

    func testLegacyFlatVoiceReadsAsFirstPreset() {
        let s = AppSettings(raw: ["services": .object(["voice": .object(["enabled": .bool(true), "kind": .string("openai"),
                                                                          "apiKey": .string("k"), "model": .string("tts-1")])])])
        XCTAssertEqual(s.activeVoice?.id, VoicePreset.legacyId)
        XCTAssertEqual(s.activeVoice?.kind, "openai")
        XCTAssertTrue(s.voiceReady)
        // 老字段 voiceId 只归第一套
        let c = Character(row: Row.new(prefix: "char", ["voiceId": .string("old")]))
        XCTAssertEqual(VoiceGen.voiceId(c, presetId: VoicePreset.legacyId), "old")
        XCTAssertEqual(VoiceGen.voiceId(c, presetId: "other"), "")
        // 改一处不把平铺的那一份丢掉
        var w = s
        w.patchVoicePreset(VoicePreset.legacyId, ["name": .string("改名")])
        XCTAssertEqual(w.activeVoice?.apiKey, "k")
        XCTAssertEqual(w.activeVoice?.name, "改名")
    }

    func testHex() {
        XCTAssertEqual(VoiceGen.hex("49443303"), Data([0x49, 0x44, 0x33, 0x03]))
        XCTAssertNil(VoiceGen.hex("4"))
        XCTAssertNil(VoiceGen.hex("zz"))
    }

    /// 总开关关着或角色没有音色：能力不进提示词，语音落成 off，不调语音接口。
    func testOffWhenNoVoiceId() async throws {
        try configure(enabled: false)
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertFalse(try ChatPrompt.build(chat: chat, char: char, settings: .load()).system.contains("[语音："))
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("[语音：你好]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        try await settle()
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.row.string("media"), "off")
    }

    /// MiniMax：一句一次请求，十六进制音频存成文件；接口一直失败时也只一次。
    func testMinimaxOncePerLine() async throws {
        try configure()
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertTrue(try ChatPrompt.build(chat: chat, char: char, settings: .load()).system.contains("[语音："))
        MockNet.reset { r, _ in
            if r.url?.host == "tts.test" { return .init(status: 200, body: #"{"data":{"audio":"49443303"},"base_resp":{"status_code":0}}"#) }
            return .init(status: 200, body: MockNet.anthropicStream("[语音：你好]\n[语音：再见]"))
        }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        try await settle()
        let tts = MockNet.requests.filter(isTTS)
        XCTAssertEqual(tts.count, 2)
        XCTAssertEqual(tts.first?.url?.path, "/v1/t2a_v2")
        let body = try JSONValue.parse(XCTUnwrap(tts.first?.httpBodyStreamData()))
        XCTAssertEqual(body["voice_setting"]?["voice_id"]?.string, "female-1")
        XCTAssertEqual(body["text"]?.string, "你好")
        for m in try Repo.messages(chatId: "chat_a").filter({ $0.kind == "voice" && ["你好", "再见"].contains($0.row.string("voiceText")) }) {
            XCTAssertEqual(m.row.string("media"), "done")
            let url = try XCTUnwrap(MediaStore.url(.files, id: m.row.string("audioId")))
            XCTAssertEqual(try Data(contentsOf: url), Data([0x49, 0x44, 0x33, 0x03]))
        }

        // 一直失败：开了重试也只一次；错误包在 200 里的也认
        try setSettings(["retryMax": .number(3)])
        MockNet.reset { r, _ in
            if r.url?.host == "tts.test" { return .init(status: 200, body: #"{"base_resp":{"status_code":1004,"status_msg":"auth failed"}}"#) }
            return .init(status: 200, body: MockNet.anthropicStream("[语音：第三句]"))
        }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        try await settle()
        XCTAssertEqual(MockNet.requests.filter(isTTS).count, 1)
        let last = try XCTUnwrap(Repo.messages(chatId: "chat_a").last)
        XCTAssertEqual(last.row.string("media"), "error")
        XCTAssertTrue(last.row.string("mediaError").contains("auth failed"))
    }

    /// 切换版本：语音不重新合成。
    func testSwitchVersionDoesNotResynthesize() async throws {
        try configure(kind: "openai")
        MockNet.reset { r, n in
            if r.url?.host == "tts.test" { return .init(status: 200, body: "ID3") }
            return .init(status: 200, body: MockNet.anthropicStream("[语音：版本\(n)]"))
        }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        try await settle()
        try await ChatEngine.reply(chatId: "chat_a", regenerate: true) { _ in }
        try await settle()
        XCTAssertEqual(MockNet.requests.filter(isTTS).count, 2)
        XCTAssertEqual(MockNet.requests.filter(isTTS).first?.url?.path, "/v1/audio/speech")
        let before = MockNet.count
        try await ChatEngine.switchVersion(chatId: "chat_a", step: -1) { _ in }
        try await settle()
        XCTAssertEqual(MockNet.count, before)
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.row.string("media"), "off")
    }

    /// 改为输入：不调任何接口，角色收到的写法与录音识别后相同。
    func testTypedVoice() throws {
        let m = try Asr.sendTyped(" 晚上见 ", chatId: "chat_a", quote: nil)
        XCTAssertEqual(m.content, "[语音：晚上见]")
        XCTAssertEqual(m.row.string("asr"), "done")
        XCTAssertEqual(MockNet.count, 0)
    }

    /// 识别接口：只转文字走 /audio/transcriptions；一直失败时最多再试 min(1, retryMax) 次。
    func testTranscribe() async throws {
        try configure(asr: ["baseUrl": .string("https://asr.test"), "apiKey": .string("k"), "model": .string("whisper-1")])
        MockNet.reset { _, _ in .init(status: 200, body: #"{"text":" 你好 "}"#) }
        let h = try await Asr.transcribe(wav: Data(repeating: 1, count: 100))
        XCTAssertEqual(h.text, "你好")
        XCTAssertEqual(MockNet.requests.first?.url?.absoluteString, "https://asr.test/v1/audio/transcriptions")

        try setSettings(["retryMax": .number(3)])
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        do { _ = try await Asr.transcribe(wav: Data(repeating: 1, count: 100)); XCTFail("应当报错") }
        catch { XCTAssertTrue(error.localizedDescription.contains("down")) }
        XCTAssertEqual(MockNet.count, 2)
    }

    /// 连语气一起读：从 JSON 里取文字与语气。录音落库后识别结果写回那一条。
    func testToneAndRecording() async throws {
        try configure(asr: ["baseUrl": .string("https://asr.test/v1"), "apiKey": .string("k"), "model": .string("gpt-4o-audio"), "mode": .string("tone")])
        let reply = #"{"text":"在吗","tone":"平静","emotion":"疲惫","pace":"","notes":""}"#
        let wrapped = String(data: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": reply]]]]), encoding: .utf8)!
        MockNet.reset { _, _ in .init(status: 200, body: wrapped) }
        let done = expectation(description: "识别写回")
        let m = try Asr.sendRecording(Data(repeating: 1, count: 100), seconds: 3, chatId: "chat_a", quote: nil) { _ in done.fulfill() }
        XCTAssertEqual(m.row.string("asr"), "pending")
        await fulfillment(of: [done], timeout: 10)
        let row = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.id == m.id })
        XCTAssertEqual(row.content, "[语音：在吗]（听起来平静、疲惫）")
        XCTAssertEqual(MockNet.requests.first?.url?.path, "/v1/chat/completions")
        XCTAssertEqual(MockNet.count, 1)
    }
}
