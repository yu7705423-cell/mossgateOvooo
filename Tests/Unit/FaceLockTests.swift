import XCTest
import UIKit
@testable import Eira

/// 锁脸：角色与「我」同一套规则；接口收参考图就直传（一次请求），传几张被拒记在消息上不自动再画；
/// 不收参考图时读成外貌描述，只读一次、读失败不再自动读；改写提示词默认关。
final class FaceLockTests: StoreTestCase {
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

    private func configure(ref: String, vision: String = "chat", extra: [String: JSONValue] = [:]) throws {
        let image: [String: JSONValue] = ["id": .string("img_a"), "name": .string("测试"), "kind": .string("openai"),
                                          "baseUrl": .string("https://img.test/v1"), "apiKey": .string("k"),
                                          "model": .string("gpt-image-1"), "ref": .string(ref)]
        var f: [String: JSONValue] = ["services": .object([
            "chat": .object(["presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
                             "activeId": .string("svc_main")]),
            "image": .object(["presets": .array([.object(image)]), "activeId": .string("img_a")]),
            "vision": .object(["mode": .string(vision)]),
        ])]
        for (k, v) in extra { f[k] = v }
        try setSettings(f)
    }

    private func photo() throws -> String {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try Images.save(XCTUnwrap(img.pngData()), maxPixel: 1280)
    }

    private func imageMessage(_ prompt: String) throws -> String {
        var m = Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "[图片：\(prompt)]", kind: "image")
        m.row["prompt"] = .string(prompt)
        m.row["media"] = .string("pending")
        m = try Repo.append(m)
        return m.id
    }

    private func reply(image: Int = 200) {
        MockNet.reset { r, _ in
            if r.url?.host == "img.test" {
                return image == 200 ? .init(status: 200, body: #"{"data":[{"b64_json":"\#(Self.png)"}]}"#)
                    : .init(status: image, body: #"{"error":{"message":"bad image field"}}"#)
            }
            return .init(status: 200, body: MockNet.anthropicStream("short black hair, round face"))
        }
    }

    func testApplies() throws {
        let c = try XCTUnwrap(Repo.character("char_a"))
        var row = c.row
        XCTAssertFalse(FaceLock.appliesChar(row, prompt: "自拍"), "没有照片不锁")
        row["faceImages"] = .array([.string("p1")])
        XCTAssertTrue(FaceLock.appliesChar(row, prompt: "对着镜子自拍"))
        XCTAssertTrue(FaceLock.appliesChar(row, prompt: "\(c.name)在窗边"))
        XCTAssertFalse(FaceLock.appliesChar(row, prompt: "一只猫"))
        row["faceLock"] = .string("always")
        XCTAssertTrue(FaceLock.appliesChar(row, prompt: "一只猫"))
        var me = try XCTUnwrap(Repo.personas().first { $0.id == "me_root" }).row
        me["faceImages"] = .array([.string("p2")])
        XCTAssertTrue(FaceLock.appliesMe(me, prompt: "我们的合照"))
        XCTAssertFalse(FaceLock.appliesMe(me, prompt: "自拍"), "角色的自拍不带我")
    }

    /// 接口收参考图：角色与我的照片一起直传，一次请求；传几张被拒记在消息上，不自动再画
    func testRefsDirect() async throws {
        try configure(ref: "edits")
        try FaceLock.setFaces(.char("char_a"), [try photo()])
        try FaceLock.setFaces(.me("me_root"), [try photo()])
        reply()
        let id = try imageMessage("林和我们的合照")
        _ = await ImageGen.fill(messageId: id)
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(MockNet.requests.first?.url?.path, "/v1/images/edits")
        XCTAssertEqual(try Database.shared.get(Collections.messages, id: id)?.string("media"), "done")

        reply(image: 400)
        let id2 = try imageMessage("林和我们的合照")
        _ = await ImageGen.fill(messageId: id2)
        XCTAssertEqual(MockNet.count, 1, "被拒不再画第二次")
        let row = try XCTUnwrap(Database.shared.get(Collections.messages, id: id2))
        XCTAssertEqual(row.string("media"), "error")
        XCTAssertEqual(row.string("refMulti"), "img_a")
    }

    /// 不收参考图：照片读成外貌描述一次，之后用缓存；读失败的那一组不再自动读
    func testDescribeOnceThenCache() async throws {
        try configure(ref: "")
        try FaceLock.setFaces(.char("char_a"), [try photo()])
        reply()
        _ = await ImageGen.fill(messageId: try imageMessage("自拍"))
        XCTAssertEqual(MockNet.count, 2, "读一次脸、画一张")
        let body = String(decoding: MockNet.requests.last(where: { $0.url?.host == "img.test" })?.httpBodyStreamData() ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("short black hair"))
        _ = await ImageGen.fill(messageId: try imageMessage("自拍"))
        XCTAssertEqual(MockNet.count, 3, "第二张只画，不再读")

        // 换一组照片、识图一直失败：读一次失败，之后不再自动读
        try FaceLock.setFaces(.char("char_a"), [try photo(), try photo()])
        MockNet.reset { r, _ in
            r.url?.host == "img.test" ? .init(status: 200, body: #"{"data":[{"b64_json":"\#(Self.png)"}]}"#)
                : .init(status: 500, body: #"{"error":{"message":"down"}}"#)
        }
        _ = await ImageGen.fill(messageId: try imageMessage("自拍"))
        let first = MockNet.requests.filter { $0.url?.host != "img.test" }.count
        XCTAssertEqual(first, 1)
        _ = await ImageGen.fill(messageId: try imageMessage("自拍"))
        XCTAssertEqual(MockNet.requests.filter { $0.url?.host != "img.test" }.count, 1, "读失败的那一组不再自动读")
    }

    /// 改写提示词默认关：一张图一次请求；开了多一次
    func testRewriteOffByDefault() async throws {
        try configure(ref: "")
        reply()
        _ = await ImageGen.fill(messageId: try imageMessage("一只猫"))
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertFalse(ExtraCalls.switchedOn(.load()).contains { $0.id == "writeImagePrompt" })
        try configure(ref: "", extra: ["writeImagePrompt": .bool(true)])
        reply()
        _ = await ImageGen.fill(messageId: try imageMessage("一只猫"))
        XCTAssertEqual(MockNet.count, 2)
    }
}
