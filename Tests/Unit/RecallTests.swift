import XCTest
@testable import Eira

/// 记忆召回的关键词命中（网页版 4.574、4.575）：关键词里两个字以上的一段出现在话里也算；带虚字、日常词、很多条都有的那一段不算；命中的排在前面
final class RecallTests: XCTestCase {
    func testKeywordHit() {
        XCTAssertEqual(ChatPrompt.keywordHit(["祖玛珑香水"], "是哪个牌子的香水"), "香水")
        XCTAssertEqual(ChatPrompt.keywordHit(["香水"], "最近买了香水"), "香水", "整个出现直接算")
        XCTAssertEqual(ChatPrompt.keywordHit(["考研复试"], "下周复试"), "复试")
        XCTAssertEqual(ChatPrompt.keywordHit(["喜欢的歌"], "你喜欢吗"), "", "日常词不算")
        XCTAssertEqual(ChatPrompt.keywordHit(["我们的约定"], "我们去吧"), "", "带虚字的一段不算")
        XCTAssertEqual(ChatPrompt.keywordHit(["拿铁"], "拿着"), "", "两个字的关键词整个对不上就是没提到")
        XCTAssertEqual(ChatPrompt.keywordHit(["coffee shop"], "the coffee was cold"), "coffee")
        XCTAssertEqual(ChatPrompt.keywordHit(["祖玛珑香水"], "是哪个牌子的香水", common: { $0 == "香水" }), "", "很多条都有的那一段不算")
    }
}
