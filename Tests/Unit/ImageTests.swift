import UIKit
import XCTest
@testable import Eira

/// 存图、读图，以及识图交给聊天模型时图怎么进请求。
final class ImageTests: StoreTestCase {
    private func makeImage(_ w: CGFloat, _ h: CGFloat, alpha: Bool = false) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !alpha
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        }
        return alpha ? img.pngData()! : img.jpegData(compressionQuality: 0.9)!
    }

    func testSaveShrinksToPhotoMax() async throws {
        let id = try Images.save(makeImage(3000, 2000))
        XCTAssertTrue(id.hasPrefix("img_"))
        let url = try XCTUnwrap(MediaStore.url(.images, id: id))
        XCTAssertEqual(url.pathExtension, "jpg")
        let stored = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        XCTAssertEqual(max(stored.size.width * stored.scale, stored.size.height * stored.scale), Images.photoMax, accuracy: 1)
        // 按显示大小缩小着读
        let small = await Images.load(id, maxPixel: 200)
        XCTAssertNotNil(small)
        XCTAssertLessThanOrEqual(max(small!.size.width, small!.size.height) * small!.scale, 200.5)
    }

    func testSmallImageKeepsSizeAndTransparencyKeepsPNG() throws {
        let id = try Images.save(makeImage(300, 200, alpha: true))
        let url = try XCTUnwrap(MediaStore.url(.images, id: id))
        XCTAssertEqual(url.pathExtension, "png")
        let stored = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        XCTAssertEqual(stored.size.width * stored.scale, 300, accuracy: 1)
    }

    func testRejectsNonImage() {
        XCTAssertThrowsError(try Images.save(Data("不是图片".utf8)))
    }

    func testMissingImageLoadsNil() async {
        let none = await Images.load("img_none", maxPixel: 100)
        XCTAssertNil(none)
    }

    // MARK: - 识图

    private func prepareChatWithImage(vision: String) throws -> String {
        try importFixture("data.json")
        if vision == "chat" {
            try setSettings(["services": .object(["vision": .object(["mode": .string("chat")])])])
        }
        let imageId = try Images.save(makeImage(400, 300))
        _ = try ChatEngine.send(text: "看这个", chatId: "chat_a")
        _ = try ChatEngine.sendImage(imageId: imageId, chatId: "chat_a")
        return imageId
    }

    private func built() throws -> ChatPrompt.Built {
        try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load())
    }

    func testVisionOffSendsNoImage() throws {
        _ = try prepareChatWithImage(vision: "off")
        let b = try built()
        XCTAssertTrue(b.messages.allSatisfy { $0.images.isEmpty })
        XCTAssertTrue(b.seenImages.isEmpty)
        // 模型看到的是协议文字
        XCTAssertTrue(b.messages.contains { $0.content.contains("[图片]") })
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.row.string("vision"), "off")
    }

    func testVisionChatSendsCurrentTurnImageOnce() throws {
        _ = try prepareChatWithImage(vision: "chat")
        let b = try built()
        let withImage = b.messages.filter { !$0.images.isEmpty }
        XCTAssertEqual(withImage.count, 1)
        XCTAssertEqual(withImage.first?.images.first?.mediaType, "image/jpeg")
        XCTAssertEqual(b.seenImages.count, 1)

        // 看过之后不再带
        for id in b.seenImages {
            var row = try XCTUnwrap(Database.shared.get(Collections.messages, id: id))
            row["vision"] = .string("done")
            try Database.shared.put(Collections.messages, row)
        }
        XCTAssertTrue(try built().messages.allSatisfy { $0.images.isEmpty })
    }

    /// 上一轮的图（角色已经回过）不带。
    func testOlderTurnImageNotSent() throws {
        _ = try prepareChatWithImage(vision: "chat")
        try Repo.append(Message.new(chatId: "chat_a", role: .char, authorId: "char_a", content: "好看"))
        _ = try ChatEngine.send(text: "还有呢", chatId: "chat_a")
        XCTAssertTrue(try built().messages.allSatisfy { $0.images.isEmpty })
    }

    /// 带图的消息在两种接口格式里的写法。
    func testRequestBodiesCarryImages() throws {
        let msg = AIMessage(role: .user, content: "看", images: [AIImage(mediaType: "image/png", base64: "QUJD")])
        let req = Provider.Request(system: "S", messages: [msg], maxTokens: 0, stream: false, cache: false)

        let a = ChatPreset(json: ["id": .string("a"), "provider": .string("anthropic"), "apiKey": .string("k"), "model": .string("m")])
        let aBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Provider.urlRequest(a, req, idleSeconds: 0).httpBody!) as? [String: Any])
        let aBlocks = try XCTUnwrap(((aBody["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        XCTAssertEqual(aBlocks.first?["type"] as? String, "image")
        XCTAssertEqual((aBlocks.first?["source"] as? [String: Any])?["data"] as? String, "QUJD")
        XCTAssertEqual(aBlocks.last?["text"] as? String, "看")

        let o = ChatPreset(json: ["id": .string("o"), "provider": .string("openai"), "apiKey": .string("k"), "model": .string("m")])
        let oBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Provider.urlRequest(o, req, idleSeconds: 0).httpBody!) as? [String: Any])
        let oParts = try XCTUnwrap(((oBody["messages"] as? [[String: Any]])?.last?["content"]) as? [[String: Any]])
        XCTAssertEqual((oParts.last?["image_url"] as? [String: Any])?["url"] as? String, "data:image/png;base64,QUJD")
    }

    /// 带图的不和相邻的同角色消息并在一起。
    func testImageMessagesAreNotMerged() {
        let p = ChatPreset(json: ["id": .string("a"), "provider": .string("anthropic")])
        let shaped = Provider.shape(p, [
            AIMessage(role: .user, content: "一"),
            AIMessage(role: .user, content: "二", images: [AIImage(mediaType: "image/png", base64: "x")]),
        ])
        XCTAssertEqual(shaped.count, 2)
    }
}
