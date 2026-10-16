import XCTest
@testable import Eira

/// 测试连接说清楚断在哪一步（网页版 4.551）：连上了被拒，还是没连上；本机与局域网地址各给提示
final class ConnTestTests: XCTestCase {
    func testLocalKind() {
        XCTAssertEqual(ConnTest.localKind("http://localhost:11434/v1"), "loopback")
        XCTAssertEqual(ConnTest.localKind("http://127.0.0.1:1234"), "loopback")
        XCTAssertEqual(ConnTest.localKind("http://192.168.1.5:11434/v1"), "lan")
        XCTAssertEqual(ConnTest.localKind("http://172.20.0.3"), "lan")
        XCTAssertEqual(ConnTest.localKind("http://172.40.0.3"), "")
        XCTAssertEqual(ConnTest.localKind("https://api.openai.com/v1"), "")
    }

    func testExplain() {
        XCTAssertTrue(ConnTest.explain(AIError(status: 401, message: "x"), base: "https://a.test").contains("对方拒绝"))
        XCTAssertTrue(ConnTest.explain(AIError(status: 404, message: "x"), base: "http://localhost:11434").contains("模型名"))
        var e = AIError(status: nil, message: "x")
        e.netCode = URLError.cannotConnectToHost.rawValue
        XCTAssertTrue(ConnTest.explain(e, base: "http://localhost:11434").contains("手机自己"))
        XCTAssertTrue(ConnTest.explain(e, base: "http://192.168.1.5:11434").contains("OLLAMA_HOST"))
        XCTAssertEqual(ConnTest.explain(AIError(status: nil, message: "x"), base: "https://a.test"), "")
    }
}
