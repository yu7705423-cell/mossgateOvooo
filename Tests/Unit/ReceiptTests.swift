import XCTest
@testable import Eira

/// 时刻与已读回执（网页版 receipt.js）；气泡按空行拆开。
final class ReceiptTests: StoreTestCase {
    private func msg(_ role: Message.Role, at: Double, kind: String = "text", author: String? = nil) -> Message {
        var m = Message.new(chatId: "c", role: role, authorId: author ?? (role == .user ? "me" : "char_a"), content: "x", kind: kind)
        m.row["createdAt"] = .number(at)
        return m
    }

    func testSeparatorAndContinuation() {
        let t0 = Date().millis - 3_600_000
        let a = msg(.user, at: t0)
        let b = msg(.user, at: t0 + 60_000)
        let c = msg(.user, at: t0 + 10 * 60_000)
        XCTAssertTrue(Receipt.needSep(prev: nil, cur: a))
        XCTAssertFalse(Receipt.needSep(prev: a, cur: b))
        XCTAssertTrue(Receipt.needSep(prev: b, cur: c))
        XCTAssertTrue(Receipt.cont(prev: a, cur: b))
        XCTAssertFalse(Receipt.cont(prev: b, cur: c))
        XCTAssertFalse(Receipt.cont(prev: a, cur: msg(.char, at: t0 + 30_000)))
    }

    func testSepText() {
        let now = Date()
        let cal = Calendar.current
        let today = cal.date(bySettingHour: 8, minute: 5, second: 0, of: now)!
        XCTAssertEqual(Receipt.sepOf(today.millis, now: now), "08:05")
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        XCTAssertEqual(Receipt.sepOf(yesterday.millis, now: now), "昨天 08:05")
        let old = cal.date(from: DateComponents(year: 2020, month: 3, day: 2, hour: 8, minute: 5))!
        XCTAssertEqual(Receipt.sepOf(old.millis, now: now), "2020年3月2日 08:05")
        XCTAssertEqual(Receipt.stampOf(today.millis, now: now), "08:05")
    }

    func testReadReceipts() throws {
        try importFixture("data.json")
        let before = try Repo.messages(chatId: "chat_a")
        let upTo = Receipt.readUpTo(before)
        let old = try XCTUnwrap(before.first { $0.role == .user })
        XCTAssertEqual(Receipt.textOf(old, upTo: upTo, on: true), "已读")
        XCTAssertEqual(Receipt.textOf(old, upTo: upTo, on: false), "")
        let sent = try Repo.append(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "新的一句"))
        XCTAssertEqual(Receipt.textOf(sent, upTo: upTo, on: true), "未读")
        XCTAssertEqual(try Receipt.markRead(chatId: "chat_a"), 1)
        XCTAssertEqual(try Receipt.markRead(chatId: "chat_a"), 0)
        let read = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.id == sent.id })
        XCTAssertEqual(Receipt.textOf(read, upTo: upTo, on: true), "已读")
    }

    func testParagraphBubbles() {
        XCTAssertEqual(MessageRow.paragraphs("第一段\n\n  \n第二段\n还是第二段"), ["第一段", "第二段\n还是第二段"])
        XCTAssertEqual(MessageRow.paragraphs("一句"), ["一句"])
    }
}
