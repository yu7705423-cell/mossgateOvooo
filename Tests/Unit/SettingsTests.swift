import XCTest
import UIKit
@testable import Eira

/// 「设置」里新加的几样：接口来源、任务路由、单独的识图接口、清空数据、额外调用的登记。
final class SettingsTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["services": .object([
            "chat": .object([
                "presets": .array([
                    .object(["id": .string("svc_main"), "name": .string("主"), "provider": .string("anthropic"),
                             "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")]),
                    .object(["id": .string("svc_spare"), "name": .string("副"), "provider": .string("openai"),
                             "baseUrl": .string("https://spare.test/v1"), "apiKey": .string("k2"), "model": .string("m2")]),
                ]),
                "activeId": .string("svc_main"),
                "fallbackId": .string("svc_spare"),
            ]),
            "endpoints": .array([.object(["id": .string("ep_relay"), "name": .string("中转"),
                                          "baseUrl": .string("https://relay.test/v1"), "apiKey": .string("rk")])]),
        ])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func setService(_ name: String, _ fields: [String: JSONValue]) throws {
        var s = try AppSettings.loadForWrite()
        s.setService(name, fields)
        try s.save()
    }

    private func sendPhoto() throws -> Message {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).pngData { _ in }
        return try ChatEngine.sendImage(imageId: try Images.save(png), chatId: "chat_a")
    }

    // MARK: - 接口来源

    /// 服务记着 endpointId 时，地址与密钥从那一条上取，模型是自己的；指向聊天预设也行。
    func testEndpointSourceResolves() throws {
        try setService("memory", ["mode": .string("api"), "endpointId": .string("ep_relay"), "model": .string("cheap"),
                                  "baseUrl": .string("https://ignored.test"), "apiKey": .string("")])
        var p = try XCTUnwrap(AppSettings.load().memoryPreset)
        XCTAssertEqual(p.baseUrl, "https://relay.test/v1")
        XCTAssertEqual(p.apiKey, "rk")
        XCTAssertEqual(p.model, "cheap")

        try setService("memory", ["endpointId": .string("svc_spare")])
        p = try XCTUnwrap(AppSettings.load().memoryPreset)
        XCTAssertEqual(p.baseUrl, "https://spare.test/v1")
        XCTAssertEqual(p.apiKey, "k2")

        // 指向的那条删掉了：用服务自己填的，自己没填密钥就不可用
        try setService("memory", ["endpointId": .string("ep_gone")])
        XCTAssertNil(AppSettings.load().memoryPreset)
    }

    /// 改一项服务只动给出的字段，其余（包括网页版另存、原生版不认识的）原样留着。
    func testSetServiceKeepsOtherFields() throws {
        try setService("vision", ["mode": .string("chat"), "unknownWebField": .string("keep")])
        try setService("vision", ["mode": .string("off")])
        let v = try XCTUnwrap(AppSettings.load().raw["services"]?["vision"]?.object)
        XCTAssertEqual(v["unknownWebField"]?.string, "keep")
        XCTAssertEqual(v["mode"]?.string, "off")
        XCTAssertEqual(AppSettings.load().chatPresets.count, 2)
    }

    // MARK: - 任务路由

    /// 调用方不传任务组时，按任务名找组；选了某一套就走那一套。
    func testRouteGroupFromTaskName() async throws {
        XCTAssertEqual(RouteGroup.of(task: "chat.proactive"), "proactive")
        XCTAssertEqual(RouteGroup.of(task: "memory.extract"), "memory")
        XCTAssertNil(RouteGroup.of(task: "chat.reply"))
        try setSettings(["taskRoutes": .object(["memory": .string("main")])])
        MockNet.reset { req, _ in .init(status: 200, body: req.url?.host == "main.test"
            ? MockNet.anthropicStream("x") : MockNet.openaiStream("x")) }
        _ = try await AIService.shared.send(task: "memory.extract", system: "", messages: [.init(role: .user, content: "hi")])
        XCTAssertEqual(MockNet.requests.compactMap { $0.url?.host }, ["main.test"])
    }

    /// 选的那一套没填全：照默认走，不因此失败。
    func testRouteToUnusablePresetFallsBackToDefault() async throws {
        try setSettings(["taskRoutes": .object(["memory": .string("memory")])])
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.openaiStream("x")) }
        _ = try await AIService.shared.send(task: "memory.extract", system: "", messages: [.init(role: .user, content: "hi")])
        XCTAssertEqual(MockNet.requests.compactMap { $0.url?.host }, ["spare.test"])
    }

    // MARK: - 单独的识图接口

    /// 发一张图：识图接口一次，描述写回消息；之后请回复照样只打聊天接口一次。
    func testVisionApiDescribesOnce() async throws {
        try setService("vision", ["mode": .string("api"), "baseUrl": .string("https://vision.test/v1"),
                                  "apiKey": .string("vk"), "model": .string("eye")])
        let m = try sendPhoto()
        XCTAssertEqual(m.row.string("vision"), "pending")
        MockNet.reset { req, _ in .init(status: 200, body: req.url?.host == "main.test"
            ? MockNet.anthropicStream("好看") : MockNet.openaiStream("一只猫")) }
        let done = try await Vision.describe(messageId: m.id)
        XCTAssertEqual(MockNet.requests.compactMap { $0.url?.host }, ["vision.test"])
        XCTAssertEqual(done?.content, "[图片：一只猫]")
        XCTAssertEqual(done?.row.string("vision"), "done")
        let body = String(data: MockNet.requests[0].httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("image_url"))
        XCTAssertTrue(body.contains("\"model\":\"eye\""))

        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.requests.compactMap { $0.url?.host }, ["vision.test", "main.test"])
        // 描述已经写进文字，聊天请求里不再带图
        let chatBody = String(data: MockNet.requests[1].httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(chatBody.contains("\"type\":\"image\""))
        XCTAssertTrue(chatBody.contains("一只猫"))
    }

    /// 识图接口一直失败：默认只打一次，标成 error，不自动再读；再调一次也不再打。
    func testVisionApiFailingIsOneRequest() async throws {
        try setService("vision", ["mode": .string("api"), "baseUrl": .string("https://vision.test/v1"),
                                  "apiKey": .string("vk"), "model": .string("eye")])
        let m = try sendPhoto()
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"down"}}"#) }
        do { _ = try await Vision.describe(messageId: m.id); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        let row = try XCTUnwrap(Database.shared.get(Collections.messages, id: m.id))
        XCTAssertEqual(row.string("vision"), "error")
        XCTAssertFalse(row.string("visionError").isEmpty)
        _ = try await Vision.describe(messageId: m.id)
        XCTAssertEqual(MockNet.count, 1)
    }

    /// 选了单独的接口却没填全：图标成 off，不打任何请求。
    func testVisionApiUnfilledSendsNothing() async throws {
        try setService("vision", ["mode": .string("api")])
        let m = try sendPhoto()
        XCTAssertEqual(m.row.string("vision"), "off")
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.openaiStream("x")) }
        let r = try await Vision.describe(messageId: m.id)
        XCTAssertNil(r)
        XCTAssertEqual(MockNet.count, 0)
    }

    // MARK: - 清空

    /// 清空全部数据：记录、图片、我的人设没了；接口配置留着。
    func testWipeKeepsSettings() throws {
        _ = try sendPhoto()
        try Database.shared.setKV(KVKey.persona, .object(["name": .string("我")]))
        XCTAssertGreaterThan(try Database.shared.mediaBytes(), 0)
        try Wipe.all()
        XCTAssertTrue(try Database.shared.counts().values.allSatisfy { $0 == 0 })
        XCTAssertEqual(try Database.shared.mediaBytes(), 0)
        XCTAssertTrue(try Database.shared.allMedia().isEmpty)
        XCTAssertNil(try Database.shared.kv(KVKey.persona))
        XCTAssertEqual(AppSettings.load().mainPreset?.id, "svc_main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.media.path))
        // 清空之后照样能存新图
        _ = try Images.save(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in })
    }

    // MARK: - 额外调用

    /// 登记的每一项，在默认设置下都是关着的（网页版 check-calls 的同一条）。
    func testExtraCallsOffByDefault() {
        let fresh = AppSettings(raw: [:])
        XCTAssertTrue(ExtraCalls.active(fresh).isEmpty)
        XCTAssertEqual(ExtraCalls.attemptsPerCall(fresh), 1)
    }

    /// 重试与换接口相乘。
    func testAttemptsMultiply() throws {
        try setSettings(["retryMax": .number(2), "chatFallback": .bool(true), "failoverMax": .number(0)])
        let s = AppSettings.load()
        XCTAssertEqual(ExtraCalls.swapCount(s), 1)
        XCTAssertEqual(ExtraCalls.attemptsPerCall(s), 6)
        XCTAssertEqual(ExtraCalls.active(s).count, 2)
    }

    // MARK: - 主题

    /// 没存过 theme 的跟随系统；导入的备份里有 theme 就照它。跟随系统另存一个键，不往 theme 里写网页版不认得的值。
    func testThemeDefaults() {
        XCTAssertTrue(AppSettings(raw: [:]).themeFollowsSystem)
        XCTAssertFalse(AppSettings(raw: ["theme": .string("dark")]).themeFollowsSystem)
        XCTAssertEqual(AppSettings(raw: ["theme": .string("dark")]).theme, "dark")
        XCTAssertTrue(AppSettings(raw: ["theme": .string("dark"), "themeFollowSystem": .bool(true)]).themeFollowsSystem)
    }
}
