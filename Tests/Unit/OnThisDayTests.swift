import XCTest
@testable import Eira

/// 那年今天：只列往年的同一天、双方都开过口的那一天。
final class OnThisDayTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    private func put(_ role: Message.Role, _ text: String, _ at: Date) throws {
        var m = Message.new(chatId: "chat_a", role: role, authorId: role == .user ? "me" : "char_a", content: text)
        m.row["createdAt"] = .number(at.millis)
        try Repo.save(m)
    }

    func testYears() throws {
        let cal = Calendar.current
        let now = Date()
        let lastYear = cal.date(byAdding: .year, value: -1, to: now)!
        let twoYears = cal.date(byAdding: .year, value: -2, to: now)!
        try put(.user, "去年你在吗", lastYear)
        try put(.char, "在", lastYear.addingTimeInterval(60))
        // 前年只有我一个人说了话：不算
        try put(.user, "前年", twoYears)
        let ys = OnThisDay.ofChat("chat_a", at: now)
        XCTAssertEqual(ys.map(\.ago), [1])
        XCTAssertEqual(ys.first?.msgs.map(\.content), ["去年你在吗", "在"])
    }
}
