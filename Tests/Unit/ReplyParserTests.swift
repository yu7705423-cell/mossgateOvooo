import XCTest
@testable import Eira

/// 模型回复切成几条。规则照网页版 reply.js。
final class ReplyParserTests: XCTestCase {
    private func parts(_ raw: String) -> [ReplyParser.Part] { ReplyParser.split(raw).parts }
    private func types(_ raw: String) -> [ReplyParser.PartType] { parts(raw).map(\.type) }

    func testEveryLineIsAMessage() {
        XCTAssertEqual(parts("你好\n\n今天怎么样\n嗯").map(\.text), ["你好", "今天怎么样", "嗯"])
    }

    func testMarkSplitsMidLine() {
        let p = parts("好啊[图片：一只猫]真可爱")
        XCTAssertEqual(p.map(\.type), [.text, .image, .text])
        XCTAssertEqual(p[1].text, "一只猫")
    }

    func testFullWidthBracketsAndColons() {
        XCTAssertEqual(parts("【表情:开心】").first?.type, .sticker)
        XCTAssertEqual(parts("【表情:开心】").first?.text, "开心")
    }

    func testVoiceWithTranslation() {
        let p = parts("[语音：你好（译文：hello）]")
        XCTAssertEqual(p.first?.type, .voice)
        XCTAssertEqual(p.first?.text, "你好")
        XCTAssertEqual(p.first?.translation, "hello")
    }

    func testLocationNarrationDice() {
        let loc = parts("[位置：上海 外滩十八号]").first
        XCTAssertEqual(loc?.type, .location)
        XCTAssertEqual(loc?.text, "上海")
        XCTAssertEqual(loc?.address, "外滩十八号")
        XCTAssertEqual(types("[旁白：夜深了]"), [.narration])
        XCTAssertEqual(types("[骰子]"), [.dice])
    }

    func testTimestampIsStrippedAndKept() {
        let r = ReplyParser.split("[时间：2026-10-13 12:00]\n在呢")
        XCTAssertEqual(r.parts.map(\.text), ["在呢"])
        XCTAssertNotNil(r.stamp)
        // 方括号里不是时间的，不当时间戳
        XCTAssertEqual(parts("[发呆]").map(\.text), ["[发呆]"])
    }

    func testThink() {
        let r = ReplyParser.split("<think>先想想</think>嗯")
        XCTAssertEqual(r.think, "先想想")
        XCTAssertEqual(r.parts.map(\.text), ["嗯"])
        // 只有开头没有收尾：后面全是思考
        XCTAssertTrue(ReplyParser.split("<thinking>想到一半").parts.isEmpty)
        // 只有收尾：前面全是思考
        XCTAssertEqual(ReplyParser.split("前面是思考</think>正文").parts.map(\.text), ["正文"])
    }

    func testRecallMarksPreviousLine() {
        let p = parts("说错了\n[撤回]\n重说")
        XCTAssertEqual(p.map(\.text), ["说错了", "重说"])
        XCTAssertTrue(p[0].recall)
        XCTAssertFalse(p[1].recall)
    }

    func testSilence() {
        XCTAssertEqual(types("[不回复]"), [.silence])
        XCTAssertEqual(types("[已读不回]。"), [.silence])
    }

    func testQuoteAttachesToNextLine() {
        let p = parts("[引用：你好]\n回你一句")
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].quote, "你好")
        XCTAssertEqual(p[0].text, "回你一句")
    }

    func testInnerAttachesToPreviousText() {
        let p = parts("没事\n[心声：其实很在意]")
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].inner, "其实很在意")
    }

    func testTranslationLine() {
        let p = parts("Hello there\n[译文：你好]")
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].translation, "你好")
        let same = parts("Hello [译文：你好]")
        XCTAssertEqual(same.first?.text, "Hello")
        XCTAssertEqual(same.first?.translation, "你好")
    }

    /// 认得但原生版还没有对应功能的标记：吞掉，不留成文字。
    func testKnownButUnsupportedMarksAreConsumed() {
        XCTAssertEqual(parts("给你\n[点歌：晴天]").map(\.text), ["给你"])
        XCTAssertTrue(parts("[约定：周末去看海]").isEmpty)
    }

    func testEmptyBodyProducesNothing() {
        XCTAssertTrue(parts("[图片： ]").isEmpty)
        // 冒号后面一个字都没有：标记的正则本身不匹配，留成文字（网页版同样）
        XCTAssertEqual(parts("[图片：]").map(\.text), ["[图片：]"])
    }

    func testAutoSplitLongSingleText() {
        let long = "今天天气很好，阳光一直照到下午。我们出去走走吧，顺便去书店看看有没有新书。晚上一起吃饭好不好？"
        let p = parts(long)
        XCTAssertGreaterThan(p.count, 1)
        XCTAssertTrue(p.allSatisfy { $0.type == .text && !$0.text.hasSuffix("。") && !$0.text.hasSuffix("，") })
        // 两条以上的回复不再切
        XCTAssertEqual(parts(long + "\n嗯").count, 2)
    }
}
