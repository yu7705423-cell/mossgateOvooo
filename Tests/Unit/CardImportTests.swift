import XCTest
@testable import Eira

/// 从资料读角色卡：读文件、解析模型回的 JSON、调几次接口。
final class CardImportTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc"), "provider": .string("openai"),
                                         "baseUrl": .string("https://spare.test/v1"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc")])])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func reply(_ text: String) -> MockNet.Reply { .init(status: 200, body: MockNet.openaiStream(text)) }

    func testParseCard() async throws {
        MockNet.reset { [self] _, _ in reply("```json\n{\"name\":\"林\",\"persona\":\"PERSONA\",\"age\":24,\"signature\":\"签名\",}\n```") }
        let d = try await CardImport.parse(raw: "一段资料")
        XCTAssertEqual(d.name, "林")
        XCTAssertEqual(d.persona, "PERSONA")
        XCTAssertEqual(d.age, "24")
        XCTAssertEqual(MockNet.count, 1)
        // 资料进了请求（截在前 12000 字）
        let body = String(data: MockNet.requests[0].httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("一段资料"))

        let c = try CardImport.save(d)
        XCTAssertEqual(try Repo.character(c.id)?.persona, "PERSONA")
    }

    /// 接口一直失败：默认只打一次（读取任务本身值得重试一次，但用户的自动重试默认是 0）。
    func testFailingAPIOneRequestByDefault() async throws {
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { _ = try await CardImport.parse(raw: "资料"); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
    }

    /// 用户开了自动重试：这个任务最多重试一次，不跟着用户的上限走到三次。
    func testRetryCappedByTask() async throws {
        try setSettings(["retryMax": .number(3)])
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        do { _ = try await CardImport.parse(raw: "资料"); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 2)
    }

    func testNotJSONSaysWhy() async throws {
        MockNet.reset { [self] _, _ in reply("抱歉，我无法读取") }
        do { _ = try await CardImport.parse(raw: "资料"); XCTFail("应当失败") }
        catch { XCTAssertTrue(error.localizedDescription.contains("不是合法 JSON")) }
        XCTAssertEqual(MockNet.count, 1)
    }

    func testEmptyFileMakesNoRequest() async throws {
        MockNet.reset { [self] _, _ in reply("{}") }
        do { _ = try await CardImport.parse(raw: "  \n "); XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 0)
    }

    /// 核心设定另调一次；失败返回空串，不抛。
    func testMakeCore() async throws {
        MockNet.reset { [self] _, _ in reply("核心一\n核心二") }
        let core = await CardImport.makeCore(persona: "很长的人设")
        XCTAssertEqual(core, "核心一\n核心二")
        XCTAssertEqual(MockNet.count, 1)

        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        let none = await CardImport.makeCore(persona: "人设")
        XCTAssertEqual(none, "")
        XCTAssertEqual(MockNet.count, 1)
    }

    func testLenientJSON() {
        XCTAssertEqual(JSONReply.parse("<think>{想}</think>{\"a\":1}")?["a"]?.number, 1)
        XCTAssertEqual(JSONReply.parse("前面的话 {\"a\":\"x\"} 后面的话")?["a"]?.string, "x")
        XCTAssertEqual(JSONReply.parse("{\"a\":\"第一行\n第二行\"}")?["a"]?.string, "第一行\n第二行")
        XCTAssertEqual(JSONReply.parse("{\"a\":[1,2,],}")?["a"]?.array?.count, 2)
        XCTAssertNil(JSONReply.parse("没有 JSON"))
        XCTAssertTrue(JSONReply.failure("{\"a\":\"写到一半").contains("截断"))
    }

    func testDocxText() throws {
        let xml = """
        <?xml version="1.0"?><w:document xmlns:w="x"><w:body>\
        <w:p><w:pPr><w:b/></w:pPr><w:r><w:t>第一段</w:t></w:r></w:p>\
        <w:p w:rsidR="1"><w:r><w:t xml:space="preserve">第二段 </w:t></w:r><w:r><w:t>&lt;续&gt;</w:t></w:r><w:r><w:br/><w:t>换行</w:t></w:r></w:p>\
        </w:body></w:document>
        """
        let url = root.appendingPathComponent("card.docx")
        let zip = try ZipWriter(url: url)
        try zip.add(name: "word/document.xml", data: Data(xml.utf8))
        try zip.finish()
        XCTAssertEqual(try DocText.read(url), "第一段\n第二段 <续>\n换行")
    }

    func testPlainTextGB18030() throws {
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = try XCTUnwrap("中文资料".data(using: String.Encoding(rawValue: gb)))
        XCTAssertEqual(DocText.plain(data), "中文资料")
        XCTAssertEqual(DocText.plain(Data("a\r\nb".utf8)), "a\nb")
    }
}
