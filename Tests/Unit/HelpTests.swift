import XCTest
@testable import Eira

/// 说明书：Resources/help.json 打进了包里、读得出来，每一条都有标题和正文
final class HelpTests: XCTestCase {
    func testManualLoads() {
        XCTAssertGreaterThan(HelpView.all.count, 100)
        for e in HelpView.all {
            XCTAssertFalse(e.app.isEmpty)
            XCTAssertFalse(e.text.isEmpty)
        }
        XCTAssertTrue(HelpView.all.contains { $0.app == "聊天" && $0.title == "旁白" })
    }
}
