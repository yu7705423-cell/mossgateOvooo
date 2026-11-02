import XCTest
@testable import Eira

/// 试点（docs/jscore-pilot.md）：网页版的 splitReply 在 JavaScriptCore 里跑，和原生 ReplyParser 对照。
///
/// 样本是 Tests/Fixtures/weblogic-cases.json（ReplyParserTests 里的每一条输入，外加几条互动标记），
/// scripts/check-weblogic.mjs 在 Node 里跑的是同一份。
///
/// 两边不一致的地方逐条列出来。试点阶段它们记成「预期内的失败」（XCTExpectFailure），日志里看得到、不挡出包；
/// 环境变量 WEBLOGIC_STRICT=1 时当成真失败。脚本加载不了、解析抛错一律是真失败。
final class WebLogicTests: XCTestCase {
    private struct Case: Decodable {
        var raw: String
        var settings: [String: Int]?
    }

    private func cases() throws -> [Case] {
        struct File: Decodable { var cases: [Case] }
        let url = Bundle(for: Self.self).resourceURL!
            .appendingPathComponent("Fixtures").appendingPathComponent("weblogic-cases.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }

    /// 网页版仓库是私密的，打包结果不进本仓库，由编译流程用 WEB_REPO_TOKEN 现取现打。
    /// 没取到（没配钥匙的复刻、本地没跑过 sync-weblogic）时整组跳过，不算失败
    override func setUpWithError() throws {
        let found = [Bundle.main, Bundle(for: WebLogicTests.self), Bundle(for: WebLogic.self)].contains {
            $0.url(forResource: "reply.bundle", withExtension: "js", subdirectory: "weblogic") != nil
                || $0.url(forResource: "reply.bundle", withExtension: "js") != nil
        }
        try XCTSkipUnless(found, "没有网页版的打包结果（编译时没有取到网页版代码），跳过")
    }

    private var strict: Bool { ProcessInfo.processInfo.environment["WEBLOGIC_STRICT"] == "1" }

    func testBundleLoadsAndParses() throws {
        let out = WebLogic.shared.parse("你好\n[图片：一只猫]")
        XCTAssertNotNil(out, WebLogic.shared.lastError ?? "")
        XCTAssertEqual(out?.result.parts.map(\.type), [.text, .image])
        XCTAssertEqual(out?.result.parts.last?.text, "一只猫")
        XCTAssertEqual(WebLogic.shared.webCommit?.count, 40, "包头里记着网页版的提交号")
        print("[weblogic] 网页版提交 \(WebLogic.shared.webCommit ?? "无")，加载 \(String(format: "%.3f", WebLogic.shared.loadSeconds)) 秒")
    }

    /// 每条样本两边都跑一遍，结果逐条对照
    func testSameResultAsNative() throws {
        var mismatches: [String] = []
        var expectedOnly: [String] = []
        for c in try cases() {
            let split = c.settings?["autoSplitAt"] ?? 40
            let web = WebLogic.shared.parse(c.raw, autoSplitAt: split)
            XCTAssertNotNil(web, "网页版解析失败：\(c.raw.debugDescription) \(WebLogic.shared.lastError ?? "")")
            let diffs = WebLogic.compareWithNative(c.raw, autoSplitAt: split)
            // 「网页版另有原生没有的种类」是原生的既定做法（认出来吞掉，见 ReplyParser 头注），只记下来
            let real = diffs.filter { !$0.hasPrefix("网页版另有") }
            expectedOnly += diffs.filter { $0.hasPrefix("网页版另有") }.map { "\(c.raw.debugDescription)：\($0)" }
            if !real.isEmpty { mismatches.append("\(c.raw.debugDescription)\n" + real.joined(separator: "\n")) }
        }
        print("[weblogic] 样本 \(try cases().count) 条，不一致 \(mismatches.count) 条，原生没有对应种类的 \(expectedOnly.count) 条")
        for line in expectedOnly { print("[weblogic] \(line)") }
        for m in mismatches {
            print("[weblogic] 不一致：\(m)")
            if strict {
                XCTFail("原生与网页版不一致：\(m)")
            } else {
                XCTExpectFailure("试点阶段：原生与网页版的已知差异") {
                    XCTFail("原生与网页版不一致：\(m)")
                }
            }
        }
    }

    /// 字段对应本身：网页版每种结果换成原生 Part 的样子
    func testMapping() {
        let (parts, unmapped) = WebLogic.map([
            ["type": "transfer", "amount": 52, "note": "奶茶"],
            ["type": "react", "e": "x", "quote": "好的"],
            ["type": "newlist", "name": "夜晚", "songs": ["晴天", "七里香"]],
            ["type": "agenda", "state": "done", "title": "买菜"],
            ["type": "text", "text": "嗯", "quote": "你好", "recall": true, "inner": "其实", "translation": "hm"],
            ["type": "vote", "ok": true],
        ])
        XCTAssertEqual(parts.map(\.type), [.transfer, .react, .newlist, .agenda, .text])
        XCTAssertEqual(parts[0].amount, 52)
        XCTAssertEqual(parts[0].text, "奶茶")
        XCTAssertEqual(parts[1].extra, "好的")
        XCTAssertNil(parts[1].quote, "回应的摘录放在 extra，不当成引用")
        XCTAssertEqual(parts[2].extra, "晴天；七里香")
        XCTAssertTrue(parts[3].flag)
        XCTAssertEqual(parts[4].quote, "你好")
        XCTAssertTrue(parts[4].recall)
        XCTAssertEqual(parts[4].inner, "其实")
        XCTAssertEqual(parts[4].translation, "hm")
        XCTAssertEqual(unmapped, ["vote"])
    }

    /// 两千行的回复各解析两百次，日志里打出两边的耗时（docs/jscore-pilot.md）。
    /// 模拟器里的 JavaScriptCore 可能开着 JIT，真机上 app 里的 JSContext 没有 JIT，会慢得多：这里的数只是下限。
    /// CI 给每个测试 60 秒（build.yml），所以两边各一个测试，各自跑到 45 秒就停下，按跑完的次数算平均
    private static var nativePerRun: Double?

    private static let big: String = (0..<2000).map { i in
        i % 10 == 3 ? "[图片：第\(i)张]" : i % 10 == 7 ? "[语音：第\(i)句（译文：line \(i)）]" : "这是第\(i)行，随便说点什么。"
    }.joined(separator: "\n")

    private func timed(_ label: String, _ run: () -> Int) -> Double {
        let start = Date()
        var runs = 0, count = 0
        while runs < 200 && Date().timeIntervalSince(start) < 45 {
            count += run()
            runs += 1
        }
        let total = Date().timeIntervalSince(start)
        let per = total / Double(max(runs, 1))
        print(String(format: "[weblogic] %@：2000 行 x %ld 次，共 %.2f 秒，每次 %.1f 毫秒，切出 %ld 条", label, runs, total, per * 1000, count))
        return per
    }

    func testSpeed1Native() {
        Self.nativePerRun = timed("原生 ReplyParser") { ReplyParser.split(Self.big).parts.count }
    }

    func testSpeed2JavaScriptCore() {
        XCTAssertNotNil(WebLogic.shared.parse("预热"), WebLogic.shared.lastError ?? "")
        let per = timed("JavaScriptCore") { WebLogic.shared.parse(Self.big)?.result.parts.count ?? 0 }
        if let n = Self.nativePerRun, n > 0 {
            print(String(format: "[weblogic] JavaScriptCore 比原生慢 %.1f 倍", per / n))
        }
        XCTAssertLessThan(per, 10, "一次解析超过 10 秒")
    }
}
