import XCTest
@testable import Eira

/// 生图：一个 [图片：…] 一次请求；失败不重试、不换接口；切换版本不重画；没配接口不调。
final class ImageGenTests: StoreTestCase {
    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func configure(image: [String: JSONValue]? = ["kind": .string("openai"), "baseUrl": .string("https://img.test/v1"),
                                                          "apiKey": .string("k"), "model": .string("gpt-image-1")]) throws {
        var services: [String: JSONValue] = ["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])]
        if var image {
            image["id"] = .string("img_a")
            image["name"] = .string("测试")
            services["image"] = .object(["presets": .array([.object(image)]), "activeId": .string("img_a")])
        }
        try setSettings(["services": .object(services)])
    }

    private func isImageHost(_ r: URLRequest) -> Bool { r.url?.host == "img.test" }

    /// 等后台那几张画完：不再有 pending。
    private func settle(_ chatId: String = "chat_a") async throws {
        for _ in 0..<100 {
            let pending = try Repo.messages(chatId: chatId).contains { MediaJobs.isRunning($0.id) }
            if !pending { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("图片一直停在生成中")
    }

    func testSizeAndCut() {
        XCTAssertEqual(ImageGen.sizeText(" 832 × 1216 "), "832x1216")
        XCTAssertEqual(ImageGen.sizeText("大一点"), "1024x1024")
        let c = ImageGen.cut("Positive\nsoft light, cat\nNegative prompt:\nselfie, studio")
        XCTAssertEqual(c.pos, "soft light, cat")
        XCTAssertEqual(c.neg, "selfie, studio")
        XCTAssertEqual(ImageGen.cut("just a cat").neg, "")
    }

    func testChatImageOf() throws {
        let a = try JSONValue.parse(Data(#"{"choices":[{"message":{"images":[{"image_url":{"url":"data:image/png;base64,AAA"}}]}}]}"#.utf8))
        XCTAssertEqual(ImageGen.chatImageOf(a).url, "data:image/png;base64,AAA")
        let b = try JSONValue.parse(Data(#"{"choices":[{"message":{"content":"![x](https://cdn.test/a.png)"}}]}"#.utf8))
        XCTAssertEqual(ImageGen.chatImageOf(b).url, "https://cdn.test/a.png")
        let c = try JSONValue.parse(Data(#"{"choices":[{"message":{"content":"抱歉"}}]}"#.utf8))
        XCTAssertEqual(ImageGen.chatImageOf(c).url, "")
    }

    /// 提示词：描述在前，点了名的角色外貌、角色固定提示词、全局提示词在后；全局里的 Negative 摘出去。
    func testCompose() throws {
        var c = try XCTUnwrap(Repo.character("char_a"))
        c.row["name"] = .string("林晚")
        c.row["appearance"] = .string("short black hair")
        c.row["imagePrompt"] = .string("film grain")
        let s = AppSettings(raw: ["imagePrompt": .string("best quality\nNegative:\nlowres")])
        let parts = ImageGen.parts(prompt: "林晚在窗边", char: c, all: [c], settings: s)
        let pos = ImageGen.compose(parts)
        XCTAssertTrue(pos.hasPrefix("林晚在窗边"))
        XCTAssertTrue(pos.contains("short black hair"))
        XCTAssertTrue(pos.contains("film grain"))
        XCTAssertTrue(pos.hasSuffix("best quality"))
        XCTAssertEqual(ImageGen.negativeOf(parts), "lowres")
    }

    /// 没配生图接口：能力不进提示词，图片落成 off，不调生图接口。
    func testNotConfigured() async throws {
        try configure(image: nil)
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertFalse(try ChatPrompt.build(chat: chat, char: char, settings: .load()).system.contains("[图片："))
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("给你看\n[图片：窗外的雨]")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        try await settle()
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.row.string("media"), "off")
    }

    /// 配好了：能力进提示词；两张图各一次请求，存好写回消息。
    func testGeneratesOncePerImage() async throws {
        try configure()
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let char = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertTrue(try ChatPrompt.build(chat: chat, char: char, settings: .load()).system.contains("[图片："))
        MockNet.reset { r, _ in
            if r.url?.host == "img.test" { return .init(status: 200, body: #"{"data":[{"b64_json":"\#(Self.png)"}]}"#) }
            return .init(status: 200, body: MockNet.anthropicStream("给你看\n[图片：窗外的雨]\n[图片：桌上的猫]"))
        }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        try await settle()
        let imgs = MockNet.requests.filter(isImageHost)
        XCTAssertEqual(imgs.count, 2)
        XCTAssertEqual(imgs.first?.url?.path, "/v1/images/generations")
        let body = try JSONValue.parse(XCTUnwrap(imgs.first?.httpBodyStreamData()))
        XCTAssertEqual(body["prompt"]?.string, "窗外的雨")
        XCTAssertNil(body["response_format"])
        XCTAssertNil(body["negative_prompt"])
        let rows = try Repo.messages(chatId: "chat_a").filter { $0.kind == "image" && ["窗外的雨", "桌上的猫"].contains($0.row.string("prompt")) }
        XCTAssertEqual(rows.count, 2)
        for m in rows {
            XCTAssertEqual(m.row.string("media"), "done")
            XCTAssertNotNil(MediaStore.url(.images, id: m.imageId))
        }
        let noted = await Usage.shared.today(task: "image")
        XCTAssertEqual(noted, 2)
    }

    /// 接口一直失败：一张图只打出去一次（开了重试也不重试），消息上写原因；切换版本不再画。
    func testFailureIsOneRequestAndSwitchDoesNotRedraw() async throws {
        try configure()
        try setSettings(["retryMax": .number(3), "chatFallback": .bool(true)])
        MockNet.reset { r, n in
            if r.url?.host == "img.test" { return .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
            return .init(status: 200, body: MockNet.anthropicStream("[图片：版本\(n)]"))
        }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        try await settle()
        XCTAssertEqual(MockNet.requests.filter(isImageHost).count, 1)
        let m = try XCTUnwrap(Repo.messages(chatId: "chat_a").last)
        XCTAssertEqual(m.row.string("media"), "error")
        XCTAssertTrue(m.row.string("mediaError").contains("boom"))

        // 重新生成整轮：新的一张画一次
        try await ChatEngine.reply(chatId: "chat_a", regenerate: true) { _ in }
        try await settle()
        XCTAssertEqual(MockNet.requests.filter(isImageHost).count, 2)
        // 切回上一个版本：不调任何接口
        let before = MockNet.count
        try await ChatEngine.switchVersion(chatId: "chat_a", step: -1) { _ in }
        try await settle()
        XCTAssertEqual(MockNet.count, before)
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.row.string("media"), "off")

        // 用户手动点重新生成：一次
        _ = try await ImageGen.regenerate(messageId: XCTUnwrap(Repo.messages(chatId: "chat_a").last?.id))
        XCTAssertEqual(MockNet.count, before + 1)
    }

    /// 生图前翻译：含中文的图先多一次文字请求；译失败照原文画，不因此多画一张。
    func testTranslateBeforeImage() async throws {
        try configure(image: ["kind": .string("openai"), "baseUrl": .string("https://img.test"), "apiKey": .string("k"),
                              "model": .string("m"), "promptLang": .string("translate")])
        XCTAssertTrue(ExtraCalls.switchedOn(.load()).contains { $0.id == "imageTranslate" })
        MockNet.reset { r, _ in
            if r.url?.host == "img.test" { return .init(status: 200, body: #"{"data":[{"b64_json":"\#(Self.png)"}]}"#) }
            return .init(status: 500, body: "{}")
        }
        let p = try XCTUnwrap(AppSettings.load().activeImage)
        _ = try await ImageGen.generate(prompt: "窗外的雨", preset: p)
        XCTAssertEqual(MockNet.count, 2)
        let img = try XCTUnwrap(MockNet.requests.first(where: isImageHost))
        XCTAssertEqual(img.url?.path, "/v1/images/generations")
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(img.httpBodyStreamData()))["prompt"]?.string, "窗外的雨")
    }

    /// NovelAI：zip 里取 png。
    func testNovelAIZip() async throws {
        try configure(image: ["kind": .string("nai"), "baseUrl": .string("https://img.test"), "apiKey": .string("k"), "model": .string("nai-diffusion-3")])
        // MockNet 的 body 是字符串：zip 不是合法 UTF-8 时传不过去，这里只核对请求形状与失败时的说法
        MockNet.reset { _, _ in .init(status: 200, body: "not a zip") }
        let p = try XCTUnwrap(AppSettings.load().activeImage)
        do {
            _ = try await ImageGen.generate(prompt: "a cat", preset: p)
            XCTFail("应当报错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("压缩包"))
        }
        let r = try XCTUnwrap(MockNet.requests.first)
        XCTAssertEqual(r.url?.absoluteString, "https://img.test/ai/generate-image")
        let body = try JSONValue.parse(XCTUnwrap(r.httpBodyStreamData()))
        XCTAssertEqual(body["action"]?.string, "generate")
        XCTAssertEqual(body["parameters"]?["width"]?.number, 1024)
    }
}
