import XCTest
import SQLite3
@testable import Eira

/// 很大的数据量下各条常用路径要多久：查询消息记录、打开会话、往上翻、消息列表、未读数、拼一次回复的提示词、
/// 总结记忆的积压、导出。每一项打印一行 `STRESS 名字 毫秒`（CI 的 test.log 里能看到），并给一个宽松的上限：
/// 退回逐条解析（慢一个数量级以上）时会超，CI 机器忙一点不会超。
///
/// 规模按 CI 的模拟器取：A 一段会话 10 万条，B 200 段会话各 1000 条（共 20 万条）。
/// 真机上更大的库按打印出来的每条耗时（`STRESS *.per-row-us`）外推。
/// 数据经 `Database.replaceAll` 在一个事务里批量写，和导入备份走的是同一条路（同样写搜索索引）。
final class StressTests: StoreTestCase {
    static let bigChat = 100_000
    static let chatsB = 200
    static let perChatB = 1_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 单个测试默认只给 60 秒；这里的两个测试各自要造几十万条数据（A 还要整段拼一次提示词、等标识在后台过完）
        executionTimeAllowance = 180
    }

    // MARK: - 计时

    @discardableResult
    private func timed<T>(_ name: String, under limitMs: Double, rows: Int? = nil, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        let out = try body()
        let ms = Date().timeIntervalSince(start) * 1000
        print("STRESS \(name) \(Int(ms.rounded()))")
        if let rows, rows > 0 {
            print("STRESS \(name).per-row-us \(String(format: "%.2f", ms * 1000 / Double(rows)))")
        }
        XCTAssertLessThan(ms, limitMs, "\(name) 用了 \(Int(ms)) 毫秒，上限 \(Int(limitMs))")
        return out
    }

    // MARK: - 造数据

    /// 固定种子的伪随机，每次跑出同一份数据
    private struct Rng {
        var s: UInt64
        mutating func next() -> UInt64 {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return s >> 33
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    private static let cn = ["今天下班路上看到一只橘猫，蹲在便利店门口不肯走", "你吃饭了没有", "明天要早起去开会，有点紧张",
                             "我刚刚在想你说的那件事", "周末一起去看电影吗", "这家店的拉面很好吃，汤头很浓",
                             "外面下雨了，记得带伞", "我把那本书看完了，结局出乎意料", "晚安，早点睡",
                             "工作好多，忙到现在才有空回你", "楼下新开了一家面包店", "地铁上人太多了"]
    private static let en = ["Just got home, the traffic was terrible today.", "Did you finish the report you were talking about?",
                             "I think we should try that new place downtown this weekend.", "Honestly I have no idea what happened in the meeting.",
                             "Remember to drink some water.", "The sunset from the bridge looked unreal tonight."]
    private static let jp = ["今日はとても疲れました。", "また明日話しましょう。", "駅前の新しいカフェに行ってみたい。", "雨が降りそうですね。"]
    static let rare = "紫藤花开"
    static let none = "绝不会出现的暗号QZX"

    /// 造出来的一条消息里搜索要核对的几项（预期结果用）
    private struct Made {
        var id: String
        var chatId: String
        var created: Double
        var text: String
        var hidden: Bool
    }

    /// 一段会话里第 i 条消息的 JSON 原文。手拼字符串：比 JSONSerialization 快几倍，文本池里没有要转义的字符
    private func message(_ chatId: String, _ i: Int, at t: Int, rng: inout Rng, rareAt: Set<Int>) -> (json: Data, made: Made) {
        let id = "msg_\(chatId)_\(i)"
        let user = i % 4 == 0
        var parts: [String] = []
        let lang = rng.int(10)
        let pool = lang < 6 ? Self.cn : (lang < 9 ? Self.en : Self.jp)
        let n = rng.int(40) == 0 ? 12 : 1 + rng.int(3)  // 偶尔一大段
        for _ in 0..<n { parts.append(pool[rng.int(pool.count)]) }
        var content = parts.joined(separator: lang < 6 || lang == 9 ? "" : " ")
        var kind = "text"
        var extra = ""
        if i % 30 == 5 {
            kind = "image"
            content = "[图片：海边的落日]"
            extra += ",\"imageId\":\"img_\(i)\""
        }
        if rareAt.contains(i) { content += "，院子里\(Self.rare)了" }
        var translation = ""
        if lang >= 6 && lang < 9 && i % 5 == 0 {
            translation = "今天回家的路上很堵"
            extra += ",\"translation\":\"\(translation)\""
        }
        let error = i % 97 == 3
        let recalled = i % 500 == 11
        if recalled { extra += ",\"recalled\":{\"at\":1,\"by\":\"char\"}" }
        if !user { extra += ",\"turnId\":\"turn_\(chatId)_\(i / 4)\"" }
        let json = "{\"id\":\"\(id)\",\"chatId\":\"\(chatId)\",\"role\":\"\(user ? "user" : "char")\",\"authorId\":\"\(user ? "me" : "char_\(chatId)")\","
            + "\"kind\":\"\(kind)\",\"content\":\"\(content)\",\"status\":\"\(error ? "error" : "done")\",\"createdAt\":\(t),\"updatedAt\":\(t)\(extra)}"
        let text = translation.isEmpty ? content : "\(content)\n\(translation)"
        return (Data(json.utf8), Made(id: id, chatId: chatId, created: Double(t), text: text, hidden: error || recalled))
    }

    private func put(_ b: Database.Batch, _ collection: String, _ fields: [String: JSONValue]) throws {
        let row = Row(fields: fields)
        try b.put(collection, id: row.id, json: try row.encoded(), idx: Collections.indexValue(collection, fields), created: row.created)
    }

    /// chats 段会话，每段 perChat 条，时间铺在最近三年里。返回造出来的全部消息（按会话、按时间）
    private func generate(chats: Int, perChat: Int, rareIn: [Int: Set<Int>]) throws -> [Made] {
        var rng = Rng(s: 20261102)
        let now = Int(Date().millis)
        let span = 3 * 365 * 86_400_000
        let start = now - span
        var made: [Made] = []
        made.reserveCapacity(chats * perChat)
        try Database.shared.replaceAll { b in
            try put(b, Collections.personas, ["id": .string("me_1"), "name": .string("小于"), "createdAt": .number(1)])
            for c in 0..<chats {
                let chatId = "c\(c)"
                try put(b, Collections.characters, ["id": .string("char_\(chatId)"), "name": .string("角色\(c)"),
                                                    "persona": .string("PERSONA"), "createdAt": .number(Double(c + 1))])
                let step = max(1, span / perChat)
                var last = 0
                for i in 0..<perChat {
                    let t = start + i * step + rng.int(max(1, step / 2))
                    last = t
                    let m = message(chatId, i, at: t, rng: &rng, rareAt: rareIn[c] ?? [])
                    try b.put(Collections.messages, id: m.made.id, json: m.json, idx: chatId, created: m.made.created)
                    made.append(m.made)
                }
                try put(b, Collections.chats, ["id": .string(chatId), "characterIds": .array([.string("char_\(chatId)")]),
                                               "personaId": .string("me_1"), "lastMessageAt": .number(Double(last)),
                                               "unread": .number(Double(c % 7)), "createdAt": .number(Double(c + 1))])
            }
        }
        try setSettings(["activePersonaId": .string("me_1")])
        return made
    }

    /// 改之前的做法：整段读出来逐条核对（预期结果，也是「之前」的耗时）
    private func legacySearch(_ key: String, chatIds: [String]) throws -> [Message] {
        let k = key.trimmingCharacters(in: .whitespaces)
        var out: [Message] = []
        for id in chatIds {
            out += try Repo.messages(chatId: id).filter { m in
                !m.isError && !m.isRecalled && m.kind != "typing" && ChatSearch.searchable(m).range(of: k, options: .caseInsensitive) != nil
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    private func expected(_ made: [Made], _ key: String, chat: String? = nil) -> Int {
        made.filter { m in !m.hidden && (chat == nil || m.chatId == chat) && m.text.range(of: key, options: .caseInsensitive) != nil }.count
    }

    // MARK: - A：一段会话 10 万条

    func testOneHugeChat() throws {
        let n = Self.bigChat
        let made = try timed("A.insert", under: 60_000, rows: n) {
            try generate(chats: 1, perChat: n, rareIn: [0: [7, 20_007, 40_007, 60_007, 80_007]])
        }
        XCTAssertTrue(Database.shared.searchIndexReady)
        XCTAssertEqual(try Database.shared.count(Collections.messages, where: "c0"), n)

        // 查询消息记录（这一段会话）
        let common = try timed("A.search.common", under: 5_000) { try ChatSearch.run("今天", chatId: "c0") }
        XCTAssertEqual(common.count, expected(made, "今天"))
        XCTAssertGreaterThan(common.count, 1000)
        let folded = try timed("A.search.case-insensitive", under: 5_000) { try ChatSearch.run("TODAY", chatId: "c0") }
        XCTAssertEqual(folded.count, expected(made, "TODAY"))
        let rare = try timed("A.search.rare", under: 2_000) { try ChatSearch.run(Self.rare, chatId: "c0") }
        XCTAssertEqual(rare.count, 5)
        XCTAssertEqual(rare.map(\.id), rare.sorted { $0.createdAt > $1.createdAt }.map(\.id))
        let miss = try timed("A.search.none", under: 2_000) { try ChatSearch.run(Self.none, chatId: "c0") }
        XCTAssertTrue(miss.isEmpty)
        // 改之前的做法，结果必须一模一样
        let old = try timed("A.search.legacy-full-decode", under: 90_000, rows: n) { try legacySearch(Self.rare, chatIds: ["c0"]) }
        XCTAssertEqual(old.map(\.id), rare.map(\.id))

        // 打开会话：最近一页、还有几条更早的、最后一轮
        let page = 60
        try timed("A.open.latest-page", under: 1_000) {
            let list = try Repo.messages(chatId: "c0", limit: page + 1)
            XCTAssertEqual(list.count, page + 1)
            XCTAssertEqual(list.last?.id, made.last?.id)
            _ = try Database.shared.count(Collections.messages, where: "c0")
            _ = try ChatEngine.lastTurn(chatId: "c0")
        }
        // 第一次打开导进来的大会话时标识要从头统计一遍（之后只看新的）。打开会话不等它：前台只看一眼、交给后台，
        // 后台分批过完再写回。前台那一下记 A.open.badges-first，后台过完一共多久记 A.open.badges-first.background
        let badgesDone = expectation(description: "标识后台统计过完")
        let token = NotificationCenter.default.addObserver(forName: Badges.didFinish, object: nil, queue: nil) { note in
            if (note.object as? String) == "c0" { badgesDone.fulfill() }
        }
        // 后台那一遍分步计时（在后台线程上记）
        final class Tally: @unchecked Sendable {
            let lock = NSLock()
            var ms: [String: Double] = [:]
            func add(_ k: String, _ v: Double) { lock.withLock { ms[k, default: 0] += v } }
        }
        let tally = Tally()
        Badges.passTimer = { name, ms in tally.add(name, ms) }
        let bgStart = Date()
        try timed("A.open.badges-first", under: 1_000) { _ = try Badges.sync("c0") }
        XCTAssertTrue(Badges.passActive("c0"))
        XCTAssertNil(try Repo.chat("c0")?.row["stats"])
        wait(for: [badgesDone], timeout: 100)
        NotificationCenter.default.removeObserver(token)
        let bgMs = Date().timeIntervalSince(bgStart) * 1000
        Badges.passTimer = nil
        for (k, v) in tally.lock.withLock({ tally.ms }).sorted(by: { $0.key < $1.key }) {
            print("STRESS A.open.badges-first.background.\(k) \(Int(v.rounded()))")
        }
        print("STRESS A.open.badges-first.background \(Int(bgMs.rounded()))")
        print("STRESS A.open.badges-first.background.per-row-us \(String(format: "%.2f", bgMs * 1000 / Double(n)))")
        XCTAssertLessThan(bgMs, 60_000, "A.open.badges-first.background 用了 \(Int(bgMs)) 毫秒，上限 60000")
        // 失败的不算（造数据时每 97 条一条失败）
        let failed = (0..<n).filter { $0 % 97 == 3 }.count
        XCTAssertEqual(try Repo.chat("c0")?.row["stats"]?["n"]?.number, Double(n - failed))
        try timed("A.open.badges-again", under: 1_000) { _ = try Badges.sync("c0") }
        // 「查看更早的消息」点一次
        try timed("A.open.earlier-page", under: 1_000) {
            XCTAssertEqual(try Repo.messages(chatId: "c0", limit: page * 2 + 1).count, page * 2 + 1)
        }
        // 从搜索结果跳到正中间那一条：数一下要画多少条（从前要整段读出来找下标）
        let mid = made[n / 2]
        let need = try timed("A.jump.count", under: 1_000) { try Database.shared.countFrom(Collections.messages, where: "c0", id: mid.id) }
        XCTAssertEqual(need, n - n / 2)
        try timed("A.jump.load-half", under: 60_000, rows: n / 2) {
            let list = try Repo.messages(chatId: "c0", limit: (need ?? 0) + 1)
            XCTAssertTrue(list.contains { $0.id == mid.id })
        }

        // 消息列表与未读
        try timed("A.chat-list", under: 1_000) { _ = try chatList() }

        // 拼一次回复的提示词：只读历史窗口那一截（从末尾往前翻页），整段里才查得出来的几件事按字节粗筛。
        // 改之前整段读出来再拼的做法记 A.prompt.build-reference，两边拼出来的必须一字不差
        let chat = try XCTUnwrap(Repo.chat("c0"))
        let char = try XCTUnwrap(Repo.character("char_c0"))
        let at = Date()
        // 各步用了多久：打印 STRESS A.prompt.phase.<名字> <毫秒>（facts.candidates-count 是粗筛出来的条数，不是毫秒）
        var phases: [(String, Double)] = []
        ChatPrompt.phaseTimer = { name, ms in phases.append((name, ms)) }
        let built = try timed("A.prompt.build", under: 2_000) { try ChatPrompt.build(chat: chat, char: char, settings: .load(), now: at) }
        ChatPrompt.phaseTimer = nil
        var phaseTotal: [String: Double] = [:]
        var phaseOrder: [String] = []
        for (name, ms) in phases {
            if phaseTotal[name] == nil { phaseOrder.append(name) }
            phaseTotal[name, default: 0] += ms
        }
        for name in phaseOrder { print("STRESS A.prompt.phase.\(name) \(String(format: "%.1f", phaseTotal[name] ?? 0))") }
        XCTAssertFalse(built.messages.isEmpty)
        XCTAssertLessThan(built.messages.count, 200)
        let ref = try timed("A.prompt.build-reference", under: 90_000, rows: n) {
            try ChatPrompt.buildReference(chat: chat, char: char, settings: .load(), now: at)
        }
        XCTAssertEqual(built.system, ref.system)
        XCTAssertEqual(built.messages, ref.messages)
        XCTAssertEqual(built.recalled, ref.recalled)
        // 第二次（库的页缓存是热的）
        try timed("A.prompt.build.again", under: 1_000) { _ = try ChatPrompt.build(chat: chat, char: char, settings: .load(), now: at) }

        // 总结记忆的积压：水位线在末尾附近时只读水位线之后的
        var c = chat
        let markAt = n - 50
        c.row["memoryUpTo"] = .string(made[markAt].id)
        c.row["memoryUpToAt"] = .number(made[markAt].created)
        try Repo.save(c)
        let pending = try timed("A.memory.pending-after-mark", under: 1_000) { try MemorySummary.pending(chatId: "c0") }
        // 积压里是水位线之后、不是失败的那些（撤回的照样算，同从前）
        let errors = (markAt + 1..<n).filter { $0 % 97 == 3 }.count
        XCTAssertEqual(pending.count, n - markAt - 1 - errors)
        let firstAfter = try XCTUnwrap((markAt + 1..<n).first { $0 % 97 != 3 })
        XCTAssertEqual(pending.first?.id, made[firstAfter].id)
    }

    // MARK: - B：200 段会话各 1000 条

    func testManyChats() throws {
        let total = Self.chatsB * Self.perChatB
        let made = try timed("B.insert", under: 90_000, rows: total) {
            try generate(chats: Self.chatsB, perChat: Self.perChatB, rareIn: [3: [500], 77: [10], 150: [999]])
        }
        XCTAssertEqual(try Database.shared.count(Collections.messages), total)

        // 全部会话里搜（「搜索全部会话」与「在聊天记录中搜索」）
        let rare = try timed("B.search.all.rare", under: 3_000) { try ChatSearch.run(Self.rare, chatId: nil) }
        XCTAssertEqual(rare.count, 3)
        let none = try timed("B.search.all.none", under: 3_000) { try ChatSearch.run(Self.none, chatId: nil) }
        XCTAssertTrue(none.isEmpty)
        let common = try timed("B.search.all.common", under: 15_000) { try ChatSearch.run("今天", chatId: nil) }
        XCTAssertEqual(common.count, expected(made, "今天"))
        let found = try timed("B.search.all.with-titles", under: 3_000) { try ChatSearch.found(Self.rare, chatId: nil) }
        XCTAssertEqual(found.hits.count, 3)
        XCTAssertEqual(Set(found.hits.map(\.chatTitle)), ["角色3", "角色77", "角色150"])
        let one = try timed("B.search.one-chat.common", under: 1_000) { try ChatSearch.run("今天", chatId: "c42") }
        XCTAssertEqual(one.count, expected(made, "今天", chat: "c42"))
        let old = try timed("B.search.all.legacy-full-decode", under: 120_000, rows: total) {
            try legacySearch(Self.rare, chatIds: try Repo.chats().map(\.id))
        }
        XCTAssertEqual(old.map(\.id), rare.map(\.id))

        // 消息列表（每段会话取最后一条做预览）与未读角标
        let rows = try timed("B.chat-list", under: 5_000) { try chatList() }
        XCTAssertEqual(rows, Self.chatsB)
        let unread = timed("B.unread-total", under: 2_000) { Shell.chatUnread() }
        XCTAssertEqual(unread, (0..<Self.chatsB).reduce(0) { $0 + $1 % 7 })

        // 导出全部数据（只要数据，不带图片）
        let r = try timed("B.export.json", under: 90_000, rows: total) { try BackupExporter.run(.init(media: false)) }
        XCTAssertEqual(r.rows, try Database.shared.counts().values.reduce(0, +))
        print("STRESS B.export.bytes \(r.bytes)")
        let back = try timed("B.export.parse-check", under: 60_000) {
            try JSONSerialization.jsonObject(with: Data(contentsOf: r.file)) as? [String: Any]
        }
        XCTAssertEqual((back?["messages"] as? [Any])?.count, total)
        XCTAssertEqual((back?["chats"] as? [Any])?.count, Self.chatsB)
        XCTAssertEqual(back?["_format"] as? String, BackupImporter.format)
        try? FileManager.default.removeItem(at: r.file.deletingLastPathComponent())
    }

    /// 消息列表的读法（同 ChatListView.reload）：全部会话、全部角色、每段最后一条
    private func chatList() throws -> Int {
        let chats = try Repo.chats()
        let chars = Dictionary(try Repo.characters().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var n = 0
        for chat in chats {
            _ = chat.characterIds.first.flatMap { chars[$0] }?.displayName
            let last = try Repo.messages(chatId: chat.id, limit: 1).last
            _ = last.map(MsgPreview.text)
            n += 1
        }
        return n
    }
}

/// 搜索索引本身：老库升级后在后台补齐、补齐前后结果一样、旧版本写进去的消息会被发现并重建、
/// 删除与清空跟着走、几种大小写与组合字符的写法和逐条读的结果一致。
final class SearchIndexTests: StoreTestCase {
    private var dbURL: URL { root.appendingPathComponent("test.sqlite") }

    private func legacy(_ key: String, chatId: String) throws -> [String] {
        let k = key.trimmingCharacters(in: .whitespaces)
        return try Repo.messages(chatId: chatId).filter { m in
            !m.isError && !m.isRecalled && m.kind != "typing" && ChatSearch.searchable(m).range(of: k, options: .caseInsensitive) != nil
        }.sorted { $0.createdAt > $1.createdAt }.map(\.id)
    }

    private func chat(_ id: String = "chat_x") throws {
        try Database.shared.put(Collections.chats, Row(fields: ["id": .string(id), "characterIds": .array([]), "createdAt": .number(1)]))
    }

    /// 关掉库，直接改文件（模拟旧版本留下的库），再打开
    private func raw(_ sql: String) throws {
        Database.shared.close()
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &h), SQLITE_OK)
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(h, sql, nil, nil, &err)
        let msg = err.map { String(cString: $0) } ?? ""
        sqlite3_free(err)
        sqlite3_close(h)
        XCTAssertEqual(rc, SQLITE_OK, msg)
        Database.shared = try Database(url: dbURL)
    }

    func testOldDatabaseIsFilledInBackground() throws {
        try chat()
        var ids: [String] = []
        for i in 0..<4500 {
            ids.append(try Repo.append(Message.new(chatId: "chat_x", role: i % 2 == 0 ? .user : .char, authorId: "",
                                                   content: i % 1000 == 1 ? "第\(i)条 Hello World" : "第\(i)条")).id)
        }
        let before = try ChatSearch.run("hello", chatId: "chat_x").map(\.id)
        XCTAssertEqual(before.count, 5)
        // 升级之前的库：没有索引，也没有记号
        try raw("DROP TABLE msgtext; DROP TABLE native_meta;")
        // 补齐之前（或正在补）搜到的一样
        XCTAssertEqual(try ChatSearch.run("hello", chatId: "chat_x").map(\.id), before)
        Database.shared.maintainSearchIndex()
        XCTAssertTrue(Database.shared.searchIndexReady)
        XCTAssertEqual(try ChatSearch.run("hello", chatId: "chat_x").map(\.id), before)
        XCTAssertEqual(try ChatSearch.run("HELLO", chatId: "chat_x").map(\.id), try legacy("HELLO", chatId: "chat_x"))
        // 再开一次：记号已经写上，直接可用
        try raw("SELECT 1;")
        XCTAssertTrue(Database.shared.searchIndexReady)
        XCTAssertEqual(try ChatSearch.run("hello", chatId: "chat_x").map(\.id), before)
    }

    func testRowWrittenByOldVersionTriggersRebuild() throws {
        try chat()
        _ = try Repo.append(Message.new(chatId: "chat_x", role: .user, authorId: "", content: "新版写的"))
        XCTAssertTrue(Database.shared.searchIndexReady)
        // 旧版本写进来的一条：只在 records 里，索引里没有
        try raw("""
            INSERT INTO records (collection, id, idx, created, json) VALUES ('messages', 'msg_old', 'chat_x', 5,
            '{"id":"msg_old","chatId":"chat_x","role":"char","content":"旧版写的暗号","status":"done","createdAt":5}');
            """)
        Database.shared.maintainSearchIndex()
        XCTAssertTrue(Database.shared.searchIndexReady)
        XCTAssertEqual(try ChatSearch.run("暗号", chatId: "chat_x").map(\.id), ["msg_old"])
    }

    func testIndexFollowsWrites() throws {
        try chat()
        var m = try Repo.append(Message.new(chatId: "chat_x", role: .char, authorId: "", content: "原来的话"))
        XCTAssertEqual(try ChatSearch.run("原来", chatId: "chat_x").map(\.id), [m.id])
        // 改正文：旧词搜不到、新词搜得到
        m.row["content"] = .string("改过的话")
        try Repo.save(m)
        XCTAssertTrue(try ChatSearch.run("原来", chatId: "chat_x").isEmpty)
        XCTAssertEqual(try ChatSearch.run("改过", chatId: "chat_x").map(\.id), [m.id])
        // 加译文
        m.row["translation"] = .string("Changed words")
        try Repo.save(m)
        XCTAssertEqual(try ChatSearch.run("changed", chatId: "chat_x").map(\.id), [m.id])
        // 标成失败：搜不到；改回来又搜得到
        m.row["status"] = .string("error")
        try Repo.save(m)
        XCTAssertTrue(try ChatSearch.run("改过", chatId: "chat_x").isEmpty)
        m.row["status"] = .string("done")
        try Repo.save(m)
        XCTAssertEqual(try ChatSearch.run("改过", chatId: "chat_x").count, 1)
        // 删掉一条
        try Database.shared.delete(Collections.messages, id: m.id)
        XCTAssertTrue(try ChatSearch.run("改过", chatId: "chat_x").isEmpty)
        // 整段删掉
        _ = try Repo.append(Message.new(chatId: "chat_x", role: .user, authorId: "", content: "整段删"))
        try Database.shared.deleteAll(Collections.messages, where: "chat_x")
        XCTAssertTrue(try ChatSearch.run("整段删", chatId: "chat_x").isEmpty)
        // 清空全部之后还是齐的
        try Database.shared.wipe()
        XCTAssertTrue(Database.shared.searchIndexReady)
        Database.shared.maintainSearchIndex()
        XCTAssertTrue(Database.shared.searchIndexReady)
    }

    func testFoldingMatchesLegacy() throws {
        try chat()
        let texts = ["Café au lait", "Cafe\u{301} noir", "ＡＢＣ全角", "ΣΟΦΟΣ λόγος", "οδός σοφός", "Hello WORLD", "hello world",
                     "東京タワー", "とうきょう", "[图片：海边的落日]", "混合 Mixed 文字", "  前后有空格  "]
        for t in texts { _ = try Repo.append(Message.new(chatId: "chat_x", role: .user, authorId: "", content: t)) }
        let queries = ["café", "CAFÉ", "cafe\u{301}", "ａｂｃ", "ＡＢＣ", "σοφος", "ΣΟΦΌΣ", "σοφός", "WORLD", "o w", "タワー", "图片",
                       "[图片", "mixed 文", "前后", " hello "]
        for q in queries {
            XCTAssertEqual(try ChatSearch.run(q, chatId: "chat_x").map(\.id), try legacy(q, chatId: "chat_x"), q)
        }
    }

    func testJumpCountMatchesOldIndex() throws {
        try chat()
        var ids: [String] = []
        for i in 0..<30 { ids.append(try Repo.append(Message.new(chatId: "chat_x", role: .user, authorId: "", content: "\(i)")).id) }
        let all = try Repo.messages(chatId: "chat_x")
        for (i, m) in all.enumerated() {
            XCTAssertEqual(try Database.shared.countFrom(Collections.messages, where: "chat_x", id: m.id), all.count - i)
        }
        XCTAssertNil(try Database.shared.countFrom(Collections.messages, where: "chat_other", id: ids[0]))
        XCTAssertNil(try Database.shared.countFrom(Collections.messages, where: "chat_x", id: "msg_none"))
    }

    func testRawRowsChunksKeepOrder() throws {
        try chat()
        for i in 0..<25 { _ = try Repo.append(Message.new(chatId: "chat_x", role: .user, authorId: "", content: "\(i)")) }
        // 没有 createdAt 的两条排在最前面
        try Database.shared.put(Collections.messages, Row(fields: ["id": .string("msg_b"), "chatId": .string("chat_x")]))
        try Database.shared.put(Collections.messages, Row(fields: ["id": .string("msg_a"), "chatId": .string("chat_x")]))
        let whole = try Database.shared.rawRows(Collections.messages)
        var chunked: [Data] = []
        try Database.shared.rawRows(Collections.messages, chunk: 4) { chunked += $0 }
        XCTAssertEqual(chunked, whole)
        XCTAssertEqual(chunked.count, 27)
    }
}
