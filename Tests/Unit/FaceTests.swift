import XCTest
@testable import Eira

/// 见面模式：切过去落分隔线、之后的消息记 side、提示词换成面对面并只给当面说得通的能力、历史里分开标明。不调接口。
final class FaceTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    private func build() throws -> ChatPrompt.Built {
        try ChatPrompt.build(chat: XCTUnwrap(Repo.chat("chat_a")), char: XCTUnwrap(Repo.character("char_a")), settings: .load())
    }

    func testEnterAndLeave() throws {
        let line = try XCTUnwrap(Face.enter("chat_a", place: "便利店", at: "21:30", note: ""))
        XCTAssertEqual(line.kind, "side")
        XCTAssertEqual(line.content, "[线下 · 便利店 · 21:30]")
        XCTAssertTrue(Face.on(try Repo.chat("chat_a")))
        let m = try ChatEngine.send(text: "你来啦", chatId: "chat_a")
        XCTAssertEqual(m.row.string("side"), "face")

        let built = try build()
        XCTAssertTrue(built.system.contains("face to\nface"))
        XCTAssertTrue(built.system.contains("地点：便利店"))
        XCTAssertTrue(built.system.contains("[旁白]"))
        XCTAssertFalse(built.system.contains("[转账"))
        XCTAssertTrue(built.messages.map(\.content).joined().contains("[以下当面]"))

        // 已经在线下时再进：只改地点，分隔线跟着改，不再落新的一条
        XCTAssertNil(try Face.enter("chat_a", place: "公园", at: "21:30", note: ""))
        XCTAssertTrue(try Repo.messages(chatId: "chat_a").contains { $0.content == "[线下 · 公园 · 21:30]" })

        let back = try XCTUnwrap(Face.leave("chat_a"))
        XCTAssertEqual(back.content, "[回到线上]")
        let m2 = try ChatEngine.send(text: "到家了", chatId: "chat_a")
        XCTAssertEqual(m2.row.string("side"), "")
        let after = try build()
        XCTAssertTrue(after.messages.map(\.content).joined().contains("[以下在手机上]"))
        XCTAssertFalse(after.system.contains("face to\nface"))
    }
}
