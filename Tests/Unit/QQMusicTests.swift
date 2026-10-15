import XCTest
@testable import Eira

/// QQ 音乐：散列与网页版 JS 写法逐位一致、歌单链接认编号、搜歌结果的字段（照 GitHub Actions 上探到的样子）、
/// 收进曲库不重复、播放地址拿不到时把原因说出来
final class QQMusicTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        QQMusic.session = QQMusic.makeSession(protocols: [MockNet.self])
        MockNet.reset { _, _ in .init(status: 500, body: "{}") }
        try importFixture("data.json")
    }

    override func tearDownWithError() throws {
        QQMusic.session = QQMusic.makeSession()
        try super.tearDownWithError()
    }

    func testHash33MatchesJS() {
        // 网页里那段 JS 算出来的值（node 跑的）
        XCTAssertEqual(QQMusic.hash33("abcDEF123xyz_-qrsigLONGVALUEexample0987654321"), 913_988_942)
        XCTAssertEqual(QQMusic.hash33("pskeyExampleVALUE*-_0123", seed: 5381), 12_917_910)
    }

    func testPlaylistId() {
        XCTAssertEqual(QQMusic.playlistId("7256912512"), "7256912512")
        XCTAssertEqual(QQMusic.playlistId("看看这个 https://y.qq.com/n/ryqq/playlist/7256912512 好听"), "7256912512")
        XCTAssertEqual(QQMusic.playlistId("https://i.y.qq.com/n2/m/share/details/taoge.html?hosteuin=x&id=8052190267&appversion=1"), "8052190267")
        XCTAssertNil(QQMusic.playlistId("随便一句话"))
    }

    func testUnescape() {
        XCTAssertEqual(QQMusic.unescape("[00&#58;01.00]你好&#32;呀"), "[00:01.00]你好 呀")
    }

    func testSearchAndLibrary() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: #"{"code":0,"data":{"song":{"list":[{"songmid":"0039MnYb0qxYhV","songid":97773,"songname":"晴天","singer":[{"name":"周杰伦"}],"albummid":"000MkMni19ClKG","interval":269}]}}}"#) }
        let r = try await QQMusic.search("晴天")
        XCTAssertEqual(r.first?.mid, "0039MnYb0qxYhV")
        XCTAssertEqual(r.first?.artist, "周杰伦")
        XCTAssertEqual(r.first?.seconds, 269)
        XCTAssertEqual(r.first?.cover, "https://y.gtimg.cn/music/photo_new/T002R300x300M000000MkMni19ClKG.jpg")
        let a = try MusicLibrary.fromQQ(try XCTUnwrap(r.first))
        let b = try MusicLibrary.fromQQ(try XCTUnwrap(r.first))
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.source, "qq")
        XCTAssertEqual(a.qqMid, "0039MnYb0qxYhV")
    }

    /// 播放地址拿不到（海外、未登录、会员歌）：一次请求，带上 QQ 音乐给的原因
    func testSongUrlEmptyExplains() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: #"{"code":0,"req_0":{"code":0,"data":{"sip":[],"midurlinfo":[{"purl":""}],"msg":"1.2.3.4;invalidq;"}}}"#) }
        do { _ = try await QQMusic.songUrl("0039MnYb0qxYhV"); XCTFail("应当失败") } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalidq"))
        }
        XCTAssertEqual(MockNet.count, 1)
        MockNet.reset { _, _ in .init(status: 200, body: #"{"code":0,"req_0":{"code":0,"data":{"sip":["http://ws.stream.qqmusic.qq.com/"],"midurlinfo":[{"purl":"C400x.m4a?vkey=1"}]}}}"#) }
        let u = try await QQMusic.songUrl("0039MnYb0qxYhV")
        XCTAssertEqual(u, "https://ws.stream.qqmusic.qq.com/C400x.m4a?vkey=1")
    }
}
