import XCTest
@testable import Eira

/// 音乐：网易云加密与网页版逐字节一致；歌词与「歌名 - 歌手」的拆法；[你在听的歌]；角色分享歌曲、整理歌单；
/// 角色在听什么按间隔读、读失败也不每条消息重读。
final class MusicTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
        Netease.session = Netease.makeSession(protocols: [MockNet.self])
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main")])])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        Netease.session = Netease.makeSession()
        try super.tearDownWithError()
    }

    /// 标准答案是网页版拿 NeteaseCloudMusicApi 自己的代码算的（tests/fixtures/ne-golden.json）。
    func testCryptoMatchesWebGolden() throws {
        let g = try JSONValue.parse(Data(contentsOf: fixture("ne-golden.json")))
        let w = try XCTUnwrap(g["weapi"]?.array)
        let objs: [NJ] = [
            .o([("s", .s("晴天")), ("type", .i(1)), ("limit", .i(30)), ("offset", .i(0)), ("e_r", .b(false)), ("csrf_token", .s(""))]),
            .o([("c", .s("[{\"id\":347230}]")), ("e_r", .b(false)), ("csrf_token", .s("abc"))]),
            .o([]),
        ]
        for (i, o) in objs.enumerated() {
            XCTAssertEqual(NeCrypto.weapiParams(o.json, key: w[i]["key"]?.string ?? ""), w[i]["params"]?.string)
        }
        let e = try XCTUnwrap(g["eapi"]?.array)
        let eo: [NJ] = [
            .o([("s", .s("晴天 周杰伦")), ("type", .i(1)), ("limit", .i(5)), ("offset", .i(0)), ("total", .b(true)), ("e_r", .b(false)),
                ("header", .o([("os", .s("iPhone OS")), ("appver", .s("9.0.90")), ("requestId", .s("1_0001"))]))]),
            .o([("id", .s("186016")), ("tv", .i(-1)), ("lv", .i(-1)), ("rv", .i(-1)), ("kv", .i(-1)), ("_nmclfl", .i(1)), ("e_r", .b(false))]),
            .o([("type", .i(3)), ("e_r", .b(false))]),
        ]
        for (i, o) in eo.enumerated() {
            XCTAssertEqual(NeCrypto.eapiParams(e[i]["url"]?.string ?? "", o), e[i]["params"]?.string)
        }
        for d in try XCTUnwrap(g["device"]?.array) {
            XCTAssertEqual(NeCrypto.encodeDeviceId(d["id"]?.string ?? ""), d["username"]?.string)
        }
        XCTAssertEqual(NJ.s("a\"b\n中").json, "\"a\\\"b\\n中\"")
    }

    func testLyricAndQuery() {
        let lines = MusicLibrary.parseLyric("[00:01.50]第一句\n[00:03.000]第二句\n[00:05]")
        XCTAssertEqual(lines.map(\.at), [1.5, 3, 5])
        let merged = MusicLibrary.merge(lines, MusicLibrary.parseLyric("[00:01.50]first"))
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.trans, "first")
        XCTAssertEqual(MusicLibrary.splitQuery("晴天 - 周杰伦").title, "晴天")
        XCTAssertEqual(MusicLibrary.splitQuery("晴天 - 周杰伦").artist, "周杰伦")
        XCTAssertEqual(MusicLibrary.splitQuery("周杰伦《晴天》").artist, "周杰伦")
        XCTAssertEqual(MusicLibrary.splitQuery("晴天（周杰伦）").title, "晴天")
    }

    func testBlockFreshness() throws {
        var c = try XCTUnwrap(Repo.character("char_a"))
        let now = Date().millis
        c.row["nowPlaying"] = .object(["kind": .string("recent"), "at": .number(now),
                                       "songs": .array([.object(["title": .string("晴天"), "artist": .string("周杰伦"), "at": .number(now)])])])
        XCTAssertTrue(Netease.block(c, now: now).contains("Most recent track: 晴天 — 周杰伦"))
        XCTAssertEqual(Netease.block(c, now: now + 3 * 3_600_000), "")
    }

    func testParserMarks() {
        let p = ReplyParser.split("[一起听]\n[点歌：晴天 - 周杰伦]\n[分享歌曲：七里香]\n[加入歌单：雨天 | 晴天；七里香]").parts
        XCTAssertEqual(p.map(\.type), [.listen, .pick, .song, .newlist])
        XCTAssertEqual(p.last?.text, "雨天")
        XCTAssertEqual(p.last?.extra, "晴天；七里香")
    }

    /// 曲库里有的歌：角色分享、加进歌单都不联网。
    func testCharSharesAndKeepsLocalSongs() async throws {
        let s = try MusicLibrary.addLocal(title: "晴天", artist: "周杰伦", data: Data(repeating: 0, count: 64), ext: "mp3")
        MockNet.reset { r, _ in
            if r.url?.host == "main.test" { return .init(status: 200, body: MockNet.anthropicStream("给你\n[分享歌曲：晴天 - 周杰伦]\n[加入歌单：雨天 | 晴天 - 周杰伦]")) }
            return .init(status: 500, body: "{}")
        }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        for _ in 0..<60 {
            let card = try Repo.messages(chatId: "chat_a").first { $0.kind == "song" }
            let notice = try Repo.messages(chatId: "chat_a").first { $0.kind == "notice" && $0.content.contains("加入了歌单") }
            if card?.row.string("songState") == "done" && notice != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let card = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.kind == "song" })
        XCTAssertEqual(card.row.string("songId"), s.id)
        let list = try XCTUnwrap(MusicLibrary.lists().first { $0.string("owner") == "char_a" })
        XCTAssertEqual(list.string("name"), "雨天")
        XCTAssertEqual(list.strings("trackIds"), [s.id])
        XCTAssertEqual(MockNet.requests.filter { $0.url?.host != "main.test" }.count, 0)
    }

    /// 角色登录了网易云：间隔内只读一次，读失败也不会下一条消息再读。
    func testPullIfDueThrottles() async throws {
        try Diary.patchChar("char_a", ["neteaseCookie": .string("MUSIC_U=x")])
        MockNet.reset { _, _ in .init(status: 500, body: #"{"code":500}"#) }
        await Netease.pullIfDue("char_a")
        let first = MockNet.count
        XCTAssertGreaterThan(first, 0)
        XCTAssertTrue(MockNet.requests.allSatisfy { $0.url?.host?.hasSuffix("music.163.com") == true })
        await Netease.pullIfDue("char_a")
        XCTAssertEqual(MockNet.count, first)
    }

    /// 搜索：直连网易云的 eapi 接口，解析出歌名与歌手。
    func testSearchParses() async throws {
        let body = #"{"code":200,"result":{"songs":[{"id":186016,"name":"晴天","ar":[{"name":"周杰伦"}],"al":{"name":"叶惠美","picUrl":"http://p1.music.126.net/a.jpg"},"dt":269000}]}}"#
        MockNet.reset { _, _ in .init(status: 200, body: body) }
        let r = try await Netease.search("晴天")
        XCTAssertEqual(r.first?.title, "晴天")
        XCTAssertEqual(r.first?.artist, "周杰伦")
        XCTAssertEqual(r.first?.cover, "https://p1.music.126.net/a.jpg")
        XCTAssertEqual(r.first?.seconds, 269)
        XCTAssertTrue(MockNet.requests.contains { $0.url?.absoluteString == "https://interface.music.163.com/eapi/cloudsearch/pc" })
    }
}
