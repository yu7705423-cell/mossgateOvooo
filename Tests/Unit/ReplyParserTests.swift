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
        // 拿语言名当标签（网页版 4.521）
        let lang = parts("おはよう [中文：早上好]")
        XCTAssertEqual(lang.first?.text, "おはよう")
        XCTAssertEqual(lang.first?.translation, "早上好")
    }

    /// 认得但原生版还没有对应功能的标记：吞掉，不留成文字。
    func testKnownButUnsupportedMarksAreConsumed() {
        XCTAssertEqual(parts("给你\n[心愿：一只猫]").map(\.text), ["给你"])
        XCTAssertTrue(parts("[梦境：一片海]").isEmpty)
        // 约定、信做了之后落成自己的那一种（情侣空间）
        XCTAssertEqual(parts("[约定：周末去看海]").map(\.type), [.pact])
        XCTAssertEqual(parts("[信：给你｜正文]").first?.extra, "给你")
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

    /// 标记名写成繁体也认；正文里的繁体不动
    func testTraditionalMarkNames() {
        let r = ReplyParser.split("[圖片：一隻貓]\n當然")
        XCTAssertEqual(r.parts.map(\.type), [.image, .text])
        XCTAssertEqual(r.parts[0].text, "一隻貓")
        XCTAssertEqual(r.parts[1].text, "當然")
    }

    /// 原生版还没有的那几件事：认出来就不落气泡
    func testUnsupportedActionLinesDropped() {
        let r = ReplyParser.split("好\n[批准]\n[暂停]\n[同行]\n嗯")
        XCTAssertEqual(r.parts.map(\.text), ["好", "嗯"])
        // 全员禁言如今是群管理的一件事：不占气泡，落成一个动作，由引擎按身份决定生不生效
        XCTAssertEqual(ReplyParser.split("好\n[全员禁言]\n嗯").parts.map(\.type), [.text, .muteAll, .text])
    }

    /// 打电话过来：整行一件事，不占气泡；视频的记在 flag 上（繁体也认）
    func testRingLine() {
        let r = ReplyParser.split("好\n[去电]\n[視頻去電]\n嗯")
        XCTAssertEqual(r.parts.map(\.type), [.text, .ring, .ring, .text])
        XCTAssertEqual(r.parts.map(\.flag), [false, false, true, false])
    }

    /// 角色手机的两个标记：存图（整行，可不带括号）、改密码（竖线后是这串数字是什么）
    func testKeepAndLockcode() {
        let r = ReplyParser.split("[存图：海边]\n[改密码：0520｜纪念日]\n嗯")
        XCTAssertEqual(r.parts.map(\.type), [.keep, .lockcode, .text])
        XCTAssertEqual(r.parts[0].text, "海边")
        XCTAssertEqual(r.parts[1].text, "0520")
        XCTAssertEqual(r.parts[1].extra, "纪念日")
    }

    func testDmAndRecallPost() {
        let r = ReplyParser.split("[私信：只告诉你]\n[撤回動態]")
        XCTAssertEqual(r.parts.map(\.type), [.dm, .recallPost])
        XCTAssertEqual(r.parts[0].text, "只告诉你")
    }

    func testAutoSplitCanBeOff() {
        let long = String(repeating: "今天天气很好。", count: 12)
        XCTAssertGreaterThan(ReplyParser.split(long).parts.count, 1)
        XCTAssertEqual(ReplyParser.split(long, autoSplitAt: 0).parts.count, 1)
    }
    /// 图片、语音标记写走样了也认（网页版 4.635）：换了说法、收口代替冒号、整行圆括号、行末没收口、繁体
    func testMediaMarkVariants() {
        func kinds(_ t: String) -> [ReplyParser.PartType] { ReplyParser.split(t).parts.map(\.type) }
        for t in ["[发送图片：夕阳]", "[图片]：夕阳", "【照片】夕阳", "（图片：夕阳）", "(照片：夕阳)", "[图片：夕阳", "[自拍：对镜]", "[配图：夕阳]", "[發送圖片：夕陽]"] {
            XCTAssertEqual(kinds(t), [.image], t)
        }
        for t in ["[语音消息：你好]", "[发语音：你好]", "[语音]你好", "[录音：你好]", "[语音条：你好]", "（语音：你好）"] {
            XCTAssertEqual(kinds(t), [.voice], t)
        }
        XCTAssertEqual(kinds("[截图：聊天]"), [.text])
        XCTAssertEqual(kinds("今天（图片：不算）很好"), [.text])
        XCTAssertEqual(kinds("[图片：夕阳] 好看吧"), [.image, .text])
        XCTAssertEqual(kinds("[图片]"), [.text])
        XCTAssertEqual(ReplyParser.split("[语音]今天好累").parts.first?.text, "今天好累")
    }
}
