import XCTest
@testable import Eira

/// 一起看与一起读（网页版 subtitle.js、video.js、watch.js、book.js、read.js、paracomment.js、readahead.js、shelf.js、bili.js）
final class TogetherTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
        Watch.set { $0 = .init() }
        ReadTogether.set { $0 = .init() }
    }

    override func tearDownWithError() throws {
        Watch.set { $0 = .init() }
        ReadTogether.set { $0 = .init() }
        try super.tearDownWithError()
    }

    // MARK: - 字幕

    static let srt = """
    1
    00:00:01,000 --> 00:00:03,500
    <i>第一句</i>

    2
    00:00:05,000 --> 00:00:07,000
    第二句
    换行

    3
    00:01:02,250 --> 00:01:04,000
    {\\an8}第三句
    """

    func testParseSrt() {
        let ls = Subtitle.parse(Self.srt)
        XCTAssertEqual(ls.map(\.text), ["第一句", "第二句 换行", "第三句"])
        XCTAssertEqual(ls[0].at, 1)
        XCTAssertEqual(ls[0].end, 3.5)
        XCTAssertEqual(ls[2].at, 62.25)
    }

    func testParseVttAndAss() {
        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.000\n你好\n\n00:03.000 --> 00:04.000 align:start\n再见"
        XCTAssertEqual(Subtitle.parse(vtt).map(\.text), ["你好", "再见"])
        let ass = """
        [Script Info]
        Title: x

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,后一句，带逗号
        Dialogue: 0,0:00:01.50,0:00:02.00,Default,,0,0,0,,{\\b1}前一句\\N第二行
        """
        let ls = Subtitle.parse(ass)
        XCTAssertEqual(ls.map(\.text), ["前一句 第二行", "后一句，带逗号"])
        XCTAssertEqual(ls[0].at, 1.5)
        XCTAssertTrue(Subtitle.parse("   ").isEmpty)
        XCTAssertTrue(Subtitle.parse("不是字幕").isEmpty)
    }

    func testCueRecentDensityStamp() {
        let ls = Subtitle.parse(Self.srt)
        XCTAssertEqual(Subtitle.cueAt(ls, 2)?.text, "第一句")
        XCTAssertNil(Subtitle.cueAt(ls, 4))
        XCTAssertEqual(Subtitle.recentLines(ls, 6, 8).map(\.text), ["第一句", "第二句 换行"])
        XCTAssertEqual(Subtitle.recentLines(ls, 70, 1).map(\.text), ["第三句"])
        // 三句隔得开：安静
        XCTAssertTrue(Subtitle.density(ls, 30).quiet)
        let busy = (0..<10).map { Subtitle.Line(at: Double($0 * 2), end: Double($0 * 2 + 1), text: "x") }
        let d = Subtitle.density(busy, 10)
        XCTAssertTrue(d.talky)
        XCTAssertFalse(d.quiet)
        XCTAssertEqual(Subtitle.stamp(75), "1:15")
        XCTAssertEqual(Subtitle.stamp(3725), "1:02:05")
        XCTAssertEqual(Subtitle.toSeconds("12:30"), 750)
        XCTAssertEqual(Subtitle.toSeconds("1:00:01"), 3601)
        XCTAssertEqual(Subtitle.toSeconds("83"), 83)
        XCTAssertNil(Subtitle.toSeconds("abc"))
        XCTAssertEqual(Subtitle.markSeconds("12：30"), 750)
        let back = Subtitle.parse(Subtitle.toSrt(ls))
        XCTAssertEqual(back, ls)
    }

    // MARK: - 片库

    private func video(_ sub: String = TogetherTests.srt) throws -> VideoLib.Video {
        try VideoLib.add(title: "片子", url: "https://v.test/a.mp4", subtitle: sub, seconds: 600)
    }

    func testVideoAddUpdateOffset() throws {
        XCTAssertThrowsError(try VideoLib.add(title: " ", url: "https://x"))
        XCTAssertThrowsError(try VideoLib.add(title: "无源"))
        let v = try video()
        XCTAssertEqual(v.row.string("id").hasPrefix("vid"), true)
        XCTAssertEqual(VideoLib.lines(v).count, 3)
        let shifted = try VideoLib.update(v.id, .init(offset: -1.26))
        XCTAssertEqual(VideoLib.offset(shifted), -1.3)
        XCTAssertEqual(VideoLib.lines(shifted)[0].at, 0, accuracy: 0.001, "跑到零之前的夹在 0 上")
        XCTAssertEqual(try VideoLib.update(v.id, .init(offset: 500)).row.number("offset"), 60)
        // 提纲：换了字幕就作废
        try VideoLib.update(v.id, .init(outline: [.init(from: 0, to: 60, text: "开头"), .init(from: 60, to: 120, text: "后来")]))
        XCTAssertEqual(VideoLib.outlineSoFar(VideoLib.get(v.id), 30).map(\.text), ["开头"])
        XCTAssertEqual(VideoLib.outlineSoFar(VideoLib.get(v.id), 59).map(\.text), ["开头", "后来"], "正在演的这一段也给")
        try VideoLib.update(v.id, .init(subtitle: "1\n00:00:01,000 --> 00:00:02,000\n新的\n"))
        XCTAssertTrue(VideoLib.get(v.id)!.outline.isEmpty)
        // 填了地址就不再是 B 站那一部
        let b = try VideoLib.add(title: "B", bili: .init(bvid: "BV1xx411c7mD", cid: 123, part: ""))
        XCTAssertEqual(b.url, "")
        XCTAssertNotNil(b.bili)
        let moved = try VideoLib.update(b.id, .init(url: "https://v.test/b.mp4"))
        XCTAssertNil(moved.bili)
        XCTAssertNil(VideoLib.biliOf(.object(["bvid": .string("BV123"), "cid": .number(1)])))
    }

    func testOutlineParseAndDigest() {
        let j = try! JSONValue.parse(Data(#"{"segments":[{"from":"8:30","to":"15:00","text":"后"},{"from":"0:00","to":"8:30","text":"前"},{"from":"x","text":"坏"},{"from":"1:00","text":" "}]}"#.utf8))
        let segs = VideoLib.parseOutline(j)
        XCTAssertEqual(segs.map(\.text), ["前", "后"])
        XCTAssertEqual(segs[1].from, 510)
        let lines = (0..<40).map { Subtitle.Line(at: Double($0 * 5), end: Double($0 * 5 + 2), text: "第\($0)句") }
        let dg = VideoLib.digest(lines).components(separatedBy: "\n")
        XCTAssertEqual(dg.count, 14, "每 15 秒只留一句")
        XCTAssertEqual(dg.first, "[0:00] 第0句")
    }

    // MARK: - 一起看

    func testWatchBlockOnlyInThatChat() throws {
        let v = try video()
        try VideoLib.update(v.id, .init(outline: [.init(from: 0, to: 60, text: "开头发生的事"), .init(from: 300, to: 400, text: "结局")]))
        try Watch.begin(chatId: "chat_a", videoId: v.id)
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").last?.content, "[开始一起看《片子》]")
        Watch.tick(at: 6, duration: 600, playing: true)
        let text = Watch.block(chatId: "chat_a")
        XCTAssertTrue(text.hasPrefix("\n\n[你们正在看]\nYou are watching 《片子》 together with the other party."))
        XCTAssertTrue(text.contains("Current position 0:06, of a total running time of 10:00."))
        XCTAssertTrue(text.contains("different places"))
        XCTAssertTrue(text.contains("[到目前为止的剧情]\n0:00\u{3000}开头发生的事"))
        XCTAssertFalse(text.contains("结局"), "后面的一段不给")
        XCTAssertTrue(text.contains("[刚刚的台词]\n第一句\n第二句 换行"))
        XCTAssertTrue(text.contains("first time"))
        XCTAssertEqual(Watch.block(chatId: "other"), "", "别的会话里不写")
        // 在一起看、暂停、看过
        try Watch.setCfg("chat_a", how: "face")
        var row = try XCTUnwrap(Database.shared.get(Collections.characters, id: "char_a"))
        row["watchedBefore"] = .bool(true)
        try Database.shared.put(Collections.characters, row)
        Watch.tick(at: 6, duration: 600, playing: false)
        let t2 = Watch.block(chatId: "chat_a")
        XCTAssertTrue(t2.contains("same place, watching the same screen"))
        XCTAssertTrue(t2.contains("Playback is paused at this moment."))
        XCTAssertTrue(t2.contains("You have seen this film before"))
    }

    func testWatchPromptHasBlockAndCapOnlyWhileWatching() throws {
        let s = AppSettings.load()
        let chat = try XCTUnwrap(Repo.chat("chat_a")), char = try XCTUnwrap(Repo.character("char_a"))
        func all() throws -> String {
            let b = try ChatPrompt.build(chat: chat, char: char, settings: s)
            return b.system + b.messages.map(\.content).joined(separator: "\n")
        }
        XCTAssertFalse(try all().contains("[你们正在看]"))
        XCTAssertFalse(try all().contains("[一起看]"))
        let v = try video()
        try Watch.start(chatId: "chat_a", videoId: v.id)
        let on = try all()
        XCTAssertTrue(on.contains("[你们正在看]"))
        XCTAssertTrue(on.contains("[一起看]\nYou are watching a film"))
    }

    func testWatchDueDefaultsOffAndRespectsGap() throws {
        let v = try video("")
        try Watch.start(chatId: "chat_a", videoId: v.id)
        Watch.tick(at: 200, duration: 600, playing: true)
        XCTAssertFalse(Watch.due(), "原生版没填间隔按 0：不自己开口")
        try setSettings(["watchGap": .number(90)])
        XCTAssertTrue(Watch.due())
        Watch.markTried()
        XCTAssertFalse(Watch.due(), "试过之后要再等一个间隔")
        Watch.tick(at: 291, duration: 600, playing: true)
        XCTAssertTrue(Watch.due())
        Watch.tick(at: 291, duration: 600, playing: false)
        XCTAssertFalse(Watch.due(), "暂停时不开口")
    }

    func testWatchAwaySweepAndStopRecord() throws {
        let v = try video()
        try Watch.start(chatId: "chat_a", videoId: v.id)
        for i in 1...65 { Watch.tick(at: Double(i), duration: 600, playing: true) }
        Watch.away()
        XCTAssertFalse(Watch.sweep(now: Date().millis + 60_000))
        XCTAssertTrue(Watch.block(chatId: "chat_a").contains("stepped away"))
        XCTAssertTrue(Watch.sweep(now: Date().millis + 16 * 60_000), "离开十五分钟之后收场")
        XCTAssertFalse(Watch.playing())
        let last = try XCTUnwrap(Repo.messages(chatId: "chat_a").last)
        XCTAssertEqual(last.kind, "watch")
        XCTAssertEqual(last.content, "[一起看了 1 分钟]\n片子\u{3000}看到 1:05")
        XCTAssertEqual(last.row.number("seconds"), 65)
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        XCTAssertEqual(Watch.totals(chat).count, 1)
        XCTAssertEqual(Watch.totals(chat).seconds, 65)
    }

    func testPlaybackMarksReachPlayerOnlyInThatChat() throws {
        let v = try video()
        try Watch.start(chatId: "chat_a", videoId: v.id)
        final class Box: @unchecked Sendable { var items: [Double?] = [] }
        let box = Box()
        let obs = NotificationCenter.default.addObserver(forName: .eiraWatchControl, object: nil, queue: nil) { n in
            box.items.append(n.userInfo?["to"] as? Double)
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        Watch.playback(.pause, to: "", chatId: "other")
        XCTAssertTrue(box.items.isEmpty)
        Watch.playback(.seek, to: "1:02:03", chatId: "chat_a")
        Watch.playback(.seek, to: "没写时刻", chatId: "chat_a")
        XCTAssertEqual(box.items, [3723])
    }

    // MARK: - 书

    func testTxtChaptersAndGbk() throws {
        let text = "序\n第一章 开始\n正文一\n第二章 后来\n正文二"
        let ch = Books.chapters(of: text)
        XCTAssertEqual(ch.map(\.title), ["开头", "第一章 开始", "第二章 后来"])
        XCTAssertEqual(ch[1].start, 2)
        XCTAssertEqual(ch.last?.end, (text as NSString).length)
        XCTAssertEqual(Books.chapters(of: "没有章节").map(\.title), ["全文"])
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let data = try XCTUnwrap("中文书".data(using: gb))
        XCTAssertEqual(Books.decode(data), "中文书")
        XCTAssertThrowsError(try Books.parse(Data(" \n".utf8), name: "空", epub: false))
    }

    func testEpub() throws {
        let url = root.appendingPathComponent("b.epub")
        let z = try ZipWriter(url: url)
        try z.add(name: "mimetype", data: Data("application/epub+zip".utf8))
        try z.add(name: "META-INF/container.xml", data: Data(#"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#.utf8))
        try z.add(name: "OEBPS/content.opf", data: Data("""
        <package><metadata><dc:title>书 &amp; 名</dc:title><dc:creator>作者</dc:creator></metadata>
        <manifest><item id="c1" href="text/one.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="text/two.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c2"/><itemref idref="c1"/></spine></package>
        """.utf8))
        try z.add(name: "OEBPS/text/one.xhtml", data: Data("<html><body><h1>第一节</h1><p>甲</p><p>乙</p></body></html>".utf8))
        try z.add(name: "OEBPS/text/two.xhtml", data: Data("<html><body><h2>序</h2><p>丙&nbsp;丁</p><script>x()</script></body></html>".utf8))
        try z.finish()
        let p = try Books.parseEpub(Data(contentsOf: url))
        XCTAssertEqual(p.title, "书 & 名")
        XCTAssertEqual(p.author, "作者")
        XCTAssertEqual(p.chapters.map(\.title), ["序", "第一节"], "按 spine 的顺序")
        XCTAssertEqual(p.text, "序\n丙 丁\n\n第一节\n甲\n乙")
        XCTAssertEqual(p.chapters[1].start, ("序\n丙 丁" as NSString).length + 2)
    }

    func testBookStoreProgressParagraphs() throws {
        let body = "第一章 起\n\u{3000}\u{3000}段落一\n\n段落二𠀀\n" + String(repeating: "长", count: 5000)
        let b = try Books.add(try Books.parse(Data(body.utf8), name: "书", epub: false), title: "书", author: "")
        XCTAssertEqual(b.chars, (body as NSString).length)
        let text = Books.text(b.id)
        let paras = Books.paragraphs(text, from: 0, span: 30)
        XCTAssertEqual(paras.map(\.text).prefix(3), ["第一章 起", "段落一", "段落二𠀀"])
        XCTAssertEqual(paras[1].at, ("第一章 起\n\u{3000}\u{3000}" as NSString).length, "起点跳过段首空白")
        XCTAssertEqual(Books.paragraphAt(text, paras[2].at), "段落二𠀀")
        Books.setAt(b.id, 2400)
        XCTAssertEqual(Books.get(b.id)?.at, 2400)
        XCTAssertEqual(Books.percent(Books.get(b.id)), min(100, Int((Double(4800) / Double(b.chars) * 100).rounded())))
        Books.setAt(b.id, 10_000_000)
        XCTAssertEqual(Books.get(b.id)?.at, b.chars, "夹在全书字数之内")
        XCTAssertEqual(Books.chapterAt(Books.get(b.id))?.chapter.title, "第一章 起")
    }

    // MARK: - 一起读

    func testReadTogetherBlockDueStop() throws {
        let b = try Books.add(try Books.parse(Data(("第一章\n" + String(repeating: "字", count: 6000)).utf8), name: "书", epub: false), title: "书", author: "某人")
        try ReadTogether.start(chatId: "chat_a", bookId: b.id)
        ReadTogether.markStart()
        let t = Watch.block(chatId: "chat_a")
        XCTAssertTrue(t.hasPrefix("\n\n[你们正在读]\nYou are reading 《书》 together with the other party.\nWritten by 某人."))
        XCTAssertTrue(t.contains("They are on 第一章,"))
        XCTAssertTrue(t.contains("\n[这一页]\n第一章\n"))
        XCTAssertEqual(Watch.block(chatId: "other"), "")
        try setSettings(["readChars": .number(0)])
        XCTAssertTrue(Watch.block(chatId: "chat_a").contains("The text on the page is not being shown to you."))
        // 翻页开口：没填按 0
        ReadTogether.setAt(2400)
        XCTAssertFalse(ReadTogether.due())
        try setSettings(["readGap": .number(1)])
        XCTAssertTrue(ReadTogether.due())
        ReadTogether.markTried()
        XCTAssertFalse(ReadTogether.due(), "试过之后要再翻够页数")
        ReadTogether.away()
        ReadTogether.setAt(4800)
        XCTAssertFalse(ReadTogether.due(), "离开了阅读页不开口")
        ReadTogether.back()
        ReadTogether.stop()
        let last = try XCTUnwrap(Repo.messages(chatId: "chat_a").last)
        XCTAssertEqual(last.kind, "read")
        XCTAssertTrue(last.content.hasPrefix("[一起读了 2 页]\n《书》\u{3000}读到 "))
        XCTAssertEqual(Books.get(b.id)?.at, 4800, "书的进度保留")
    }

    func testWatchAndReadAreExclusive() throws {
        let v = try video()
        let b = try Books.add(try Books.parse(Data("正文".utf8), name: "书", epub: false), title: "书", author: "")
        try Watch.start(chatId: "chat_a", videoId: v.id)
        try ReadTogether.start(chatId: "chat_a", bookId: b.id)
        XCTAssertFalse(Watch.playing())
        try Watch.start(chatId: "chat_a", videoId: v.id)
        XCTAssertFalse(ReadTogether.reading())
    }

    // MARK: - 段评、先读、书架、书摘

    func testParaNotes() throws {
        let b = try Books.add(try Books.parse(Data("一\n二".utf8), name: "书", epub: false), title: "书", author: "")
        let subject = ParaNotes.subject(.book, b.id)
        try ParaNotes.add(subject, at: 2, .init(authorId: "char_a", authorName: "", kind: ParaNotes.charKind, text: "评"))
        // 早先只写了 bookId 的那批记录照样认
        try Database.shared.put(ParaNotes.collection, Row.new(prefix: "rn", ["bookId": .string(b.id), "at": .number(2), "text": .string("旧的"),
                                                                       "createdAt": .number(Date().millis + 1000)]))
        XCTAssertEqual(ParaNotes.list(subject, at: 2).map(\.text), ["评", "旧的"])
        XCTAssertEqual(ParaNotes.list(subject, at: 2).first?.authorName, "林", "名字按角色补上")
        XCTAssertEqual(ParaNotes.counts(subject, from: 0, span: 10), [2: 2])
        XCTAssertThrowsError(try ParaNotes.add(subject, at: 0, .init(authorId: "", authorName: "我", kind: ParaNotes.meKind, text: " ")))
        try ParaNotes.setCrew(subject, ["char_a", "char_a", "nobody"])
        XCTAssertEqual(ParaNotes.crew(subject).map(\.id), ["char_a"])
        XCTAssertEqual(try ParaNotes.passage(subject, at: 2).body, "二")
        try Books.remove(b.id)
        XCTAssertEqual(ParaNotes.count(subject), 0, "删书时段评一起清掉")
        XCTAssertEqual(ParaNotes.parse("video:vid_1").kind, .video)
        XCTAssertEqual(ParaNotes.parse("vid_1").kind, .book)
    }

    func testReadAheadState() throws {
        let b = try Books.add(try Books.parse(Data(String(repeating: "字\n", count: 100).utf8), name: "书", epub: false), title: "书", author: "")
        XCTAssertNil(ReadAhead.state(b.id))
        try ReadAhead.begin(b.id, charId: "char_a", from: 10)
        XCTAssertEqual(ReadAhead.state(b.id)?.at, 10)
        XCTAssertFalse(ReadAhead.canAuto(b.id), "默认每次都问")
        XCTAssertTrue(ReadAhead.caughtUp(b.id, youAt: 0, span: 2400))
        try ReadAhead.setAlways(b.id, true)
        XCTAssertTrue(ReadAhead.canAuto(b.id))
        for _ in 0..<3 { try ReadAhead.advance(b.id, to: 20, auto: true) }
        XCTAssertFalse(ReadAhead.canAuto(b.id), "到了次数上限")
        XCTAssertTrue(ReadAhead.hitCap(b.id))
        try ReadAhead.advance(b.id, to: 30, auto: false)
        XCTAssertEqual(ReadAhead.state(b.id)?.runs, 0, "手动那次重新计数")
        try ReadAhead.stop(b.id)
        XCTAssertNil(ReadAhead.state(b.id))
    }

    func testShelfLinksBooks() throws {
        let it = try Shelf.add("char_a", title: "《百年孤独》", author: "马尔克斯")
        XCTAssertThrowsError(try Shelf.add("char_a", title: "百年 孤独"), "书名归一之后同一本")
        XCTAssertNil(it.book)
        let b = try Books.add(try Books.parse(Data("正文".utf8), name: "百年孤独", epub: false), title: "百年孤独", author: "")
        XCTAssertEqual(Shelf.list("char_a").first?.bookId, b.id, "导入同名的书自动接上")
        try Books.remove(b.id)
        XCTAssertEqual(Shelf.list("char_a").first?.bookId, "", "书删了退回占位")
        XCTAssertEqual(Shelf.withShelf().map { $0.count }, [1])
        // 角色卡上别的字段原样留着
        XCTAssertEqual(try Repo.character("char_a")?.row["webOnlyField"]?["keep"]?.bool, true)
    }

    func testExcerptMessage() throws {
        let b = try Books.add(try Books.parse(Data("正文".utf8), name: "书", epub: false), title: "书", author: "某人")
        let m = try Excerpt.send(chatId: "chat_a", bookId: b.id, quote: " 一段 ", note: "想到你")
        XCTAssertEqual(m.kind, "excerpt")
        XCTAssertEqual(m.content, "[书摘：《书》]\n「一段」\n想到你")
        XCTAssertEqual(m.row.string("bookAuthor"), "某人")
        XCTAssertThrowsError(try Excerpt.send(chatId: "chat_a", bookId: b.id, quote: " "))
    }

    // MARK: - B 站

    func testBiliSigning() {
        let mixin = BiliApi.mixinOf(img: "7cd084941338484aae1ad9425b84077c", sub: "4932caff0ff746eab6f01bf08b70ac45")
        XCTAssertEqual(mixin, "ea1db124af3c7062474693fa704f4ff8")
        // 与网页版 signQuery 同一组输入算出来的（node 跑的网页版写法）
        XCTAssertEqual(BiliApi.signQuery(["foo": "114", "bar": "514", "zab": "1919810"], mixin: mixin, now: 1_702_204_169_000),
                       "bar=514&foo=114&wts=1702204169&zab=1919810&w_rid=8f6f2b5b3d485fe1886cec6a0be8c5d4")
        XCTAssertEqual(BiliApi.signQuery(["keyword": "猫 (测试)!", "search_type": "video", "page": "1"], mixin: mixin, now: 1_702_204_169_000),
                       "keyword=%E7%8C%AB%20%E6%B5%8B%E8%AF%95&page=1&search_type=video&wts=1702204169&w_rid=3a480f68ea49b51a032c3abaa6283e6e")
        XCTAssertEqual(BiliApi.keyOf("https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png"), "7cd084941338484aae1ad9425b84077c")
    }

    func testBiliHelpers() throws {
        XCTAssertEqual(BiliApi.rankUrls(["http://upos-hz-mirrorakam.akamaized.net/a.mp4?x=1", "https://cn-gd.bilivideo.com/b.mp4", ""]),
                       ["https://cn-gd.bilivideo.com/b.mp4", "https://upos-sz-mirrorcos.bilivideo.com/a.mp4?x=1",
                        "https://upos-hz-mirrorakam.akamaized.net/a.mp4?x=1"])
        let j = try JSONValue.parse(Data(#"{"body":[{"from":1.5,"to":3,"content":"你好 "},{"from":61,"to":62.25,"content":"再见"}]}"#.utf8))
        XCTAssertEqual(BiliApi.toSrt(j), "1\n00:00:01,500 --> 00:00:03,000\n你好\n\n2\n00:01:01,000 --> 00:01:02,250\n再见\n")
        let tracks = [BiliApi.Track(lang: "ai-zh", label: "AI", url: "a", ai: true), BiliApi.Track(lang: "en", label: "en", url: "b", ai: false),
                      BiliApi.Track(lang: "zh-CN", label: "中文", url: "c", ai: false)]
        XCTAssertEqual(BiliApi.pickTrack(tracks)?.url, "c")
        XCTAssertEqual(BiliApi.pickTrack(Array(tracks.prefix(2)))?.url, "a")
        XCTAssertNil(BiliApi.pickTrack([]))
        XCTAssertEqual(BiliApi.splitCookies("SESSDATA=a; Path=/; Expires=Wed, 01 Jan 2027 00:00:00 GMT, bili_jct=b; Path=/"),
                       ["SESSDATA=a; Path=/; Expires=Wed, 01 Jan 2027 00:00:00 GMT", "bili_jct=b; Path=/"])
        XCTAssertEqual(BiliApi.cookieFrom(["SESSDATA=a; Path=/"], url: "https://x.test/?DedeUserID=9&SESSDATA=zz&bili_jct=j"),
                       "SESSDATA=a; DedeUserID=9; bili_jct=j")
        XCTAssertEqual(BiliApi.bvidIn("看这个 https://www.bilibili.com/video/BV1xx411c7mD?p=2"), "BV1xx411c7mD")
        XCTAssertNil(BiliApi.bvidIn("没有"))
        XCTAssertEqual(BiliApi.secOf(.string("1:02:03")), 3723)
        XCTAssertEqual(BiliApi.plain("<em class=\"keyword\">猫</em> &amp; 狗"), "猫 & 狗")
    }

    func testBiliCookieStaysOnDevice() throws {
        try BiliApi.patch(["cookie": .string("SESSDATA=a"), "buvid3": .string("b3")])
        XCTAssertTrue(BiliApi.loggedIn())
        XCTAssertEqual(BiliApi.cookieOf(), "SESSDATA=a; buvid3=b3")
        try BiliApi.logout()
        XCTAssertFalse(BiliApi.loggedIn())
        XCTAssertEqual(BiliApi.cookieOf(), "buvid3=b3", "设备号留着")
    }
}
