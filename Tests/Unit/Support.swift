import XCTest
@testable import Eira

/// 每个测试一份新的库与媒体目录，放在临时目录里，不碰 app 自己的数据。
class StoreTestCase: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("eira-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppPaths.overrideRoot = root
        Database.shared = try Database(url: root.appendingPathComponent("test.sqlite"))
    }

    override func tearDownWithError() throws {
        Database.shared.close()
        try? FileManager.default.removeItem(at: root)
    }

    /// Tests/Fixtures 里的文件，由 scripts/make-fixtures.mjs 用网页版的代码生成。
    func fixture(_ name: String) -> URL {
        Bundle(for: StoreTestCase.self).resourceURL!
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    @discardableResult
    func importFixture(_ name: String, password: String = "") throws -> BackupImporter.Report {
        try BackupImporter.run(file: fixture(name), password: password) { _ in }
    }

    func setSettings(_ fields: [String: JSONValue]) throws {
        var s = AppSettings.load()
        for (k, v) in fields { s.raw[k] = v }
        try s.save()
    }
}

/// 把所有网络请求接住，数打出去几次，按 handler 给回应。
final class MockNet: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
        /// 额外的响应头（Set-Cookie、Location）
        var headers: [String: String] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: (URLRequest, Int) -> Reply = { _, _ in Reply(status: 500, body: "{}") }

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    static var count: Int { requests.count }

    static func reset(_ h: @escaping (URLRequest, Int) -> Reply) {
        lock.lock(); _requests = []; handler = h; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(request)
        let n = Self._requests.count
        let h = Self.handler
        Self.lock.unlock()
        let reply = h(request, n)
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["content-type": reply.status == 200 ? "text/event-stream" : "application/json"]
                                       .merging(reply.headers) { _, n in n })!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Anthropic 流式回复的几行 SSE。
    static func anthropicStream(_ text: String) -> String {
        let piece = String(data: try! JSONSerialization.data(withJSONObject: ["type": "content_block_delta",
            "delta": ["type": "text_delta", "text": text]]), encoding: .utf8)!
        return "event: content_block_delta\ndata: \(piece)\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    }

    static func openaiStream(_ text: String) -> String {
        let piece = String(data: try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": text]]]]), encoding: .utf8)!
        return "data: \(piece)\n\ndata: [DONE]\n\n"
    }
}

extension URLRequest {
    /// URLProtocol 收到的请求里，body 已经换成了流：读出来看发了什么。
    func httpBodyStreamData() -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}
