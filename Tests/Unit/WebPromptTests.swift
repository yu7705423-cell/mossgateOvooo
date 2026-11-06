import XCTest
@testable import Eira

/// 试点（docs/jscore-prompt.md）：一对一聊天的提示词由网页版自己的代码在 JavaScriptCore 里拼，和原生 ChatPrompt 对照。
///
/// 数据：Tests/Fixtures 里的 data.json（scripts/make-fixtures.mjs 用网页版的代码打的）、webprompt-rich.json
/// （网页版备份的格式，手写的数据：几十条消息、引用、转账、表情、译文、撤回、群聊、几类记忆、世界书）与 webprompt-avatar.json
/// （我换了头像：网页版说一次「对方的头像」并写回 chats.seenAvatar；核心设定、不认得的字段）。
///
/// 两边不一致的地方逐段列出来，日志里是 `[weblogic]` 开头的几行。试点阶段记成「预期内的失败」（XCTExpectFailure），
/// 不挡出包；WEBLOGIC_STRICT=1 时是真失败。脚本加载不了、拼装出错、区块构建失败、调到存根一律是真失败。
final class WebPromptTests: StoreTestCase {
    /// 网页版仓库是私密的，打包结果不进本仓库，由编译流程用 WEB_REPO_TOKEN 现取现打。没取到时整组跳过
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(WebPrompt.available, "没有网页版的拼装脚本（编译时没有取到网页版代码），跳过")
    }

    private var strict: Bool { ProcessInfo.processInfo.environment["WEBLOGIC_STRICT"] == "1" }

    /// 备份里的时间：data.json 的 t0，rich 的最后一条消息之后五分钟
    private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func both(_ fixture: String, chat chatId: String, now: Date, excludeTurn: String? = nil,
                      import: Bool = true) throws -> (ChatPrompt.Built, WebPrompt.Output) {
        if `import` { try importFixture(fixture) }
        let chat = try XCTUnwrap(Repo.chat(chatId))
        let char = try XCTUnwrap(Repo.character(chat.characterIds.first ?? ""))
        let native = try ChatPrompt.build(chat: chat, char: char, settings: .load(), now: now, excludeTurn: excludeTurn)
        let web = try XCTUnwrap(WebPrompt.shared.build(chat: chat, char: char, excludeTurn: excludeTurn, now: now),
                                "网页版拼装失败：\(WebPrompt.shared.lastError ?? "未知")")
        return (native, web)
    }

    private func healthy(_ web: WebPrompt.Output, _ label: String) {
        XCTAssertEqual(web.failed, [], "\(label)：网页版有区块构建失败")
        XCTAssertEqual(web.stubHits, [], "\(label)：拼装路径上调到了存根")
        XCTAssertTrue(web.writes.allSatisfy { $0.hasPrefix("put chats ") }, "\(label)：拼装途中想写别的数据域：\(web.writes)")
        XCTAssertEqual(web.commit.count, 40, "包头里记着网页版的提交号")
        for line in web.logs { print("[weblogic] \(label) 网页版日志：\(line)") }
    }

    func testFlagDefaultsOff() throws {
        XCTAssertFalse(WebPrompt.isOn)
        try WebPrompt.setOn(true)
        XCTAssertTrue(WebPrompt.isOn)
        try WebPrompt.setOn(false)
        XCTAssertFalse(WebPrompt.isOn)
    }

    func testBuildsFromWebBackup() throws {
        let (_, web) = try both("data.json", chat: "chat_a", now: Self.t0.addingTimeInterval(100))
        healthy(web, "data.json")
        XCTAssertTrue(web.system.contains("[你是谁]\nPERSONA_TEXT"))
        XCTAssertTrue(web.system.contains("[对方是谁]\nName: 小于\nUSER_DESC"))
        XCTAssertTrue(web.system.contains("[一直记着]\n- PINNED_MEMORY"))
        XCTAssertTrue(web.system.contains("LORE_CAT"))
        XCTAssertTrue(web.system.contains("LORE_ALWAYS"))
        XCTAssertFalse(web.system.contains("LORE_OFF"))
        XCTAssertFalse(web.system.contains("LORE_MISS"))
        XCTAssertTrue(web.system.contains("2 to 4"))
        XCTAssertTrue(web.messages.contains { $0.role == .assistant && $0.content.contains("在呢") && $0.content.contains("[图片：一只猫]") })
        XCTAssertEqual(web.messages.last?.role, .user)
        XCTAssertFalse(web.messages.contains { $0.content.contains("PERSONA_TEXT") })
        print("[weblogic] 提示词：data.json 灌表 \(web.timing.rows) 行 \(web.timing.bytes) 字节；读过的数据域 \(web.touched.joined(separator: "、"))；想写的 \(web.writes)")
    }

    /// 两份备份各拼一次，两边逐段对照
    func testSameAsNative() throws {
        let cases: [(String, String, Date)] = [
            ("data.json", "chat_a", Self.t0.addingTimeInterval(100)),
            ("webprompt-rich.json", "chat_r", Self.t0.addingTimeInterval(45 * 60)),
            ("webprompt-avatar.json", "chat_v", Self.t0.addingTimeInterval(20 * 60)),
        ]
        var total = 0
        for (fixture, chatId, now) in cases {
            try Database.shared.wipe()
            let (native, web) = try both(fixture, chat: chatId, now: now)
            healthy(web, fixture)
            let diffs = WebPrompt.compare(native: native, web: web)
            total += diffs.count
            print("[weblogic] 提示词对照 \(fixture)：设定区 原生 \(native.system.count) 字 / 网页 \(web.system.count) 字，"
                  + "段数 \(WebPrompt.sections(native.system).count) / \(WebPrompt.sections(web.system).count)，"
                  + "聊天记录 \(native.messages.count) / \(web.messages.count) 条，不一致 \(diffs.count) 处")
            for d in diffs {
                print("[weblogic] \(fixture) 不一致：\(d)")
                if strict {
                    XCTFail("\(fixture)：原生与网页版不一致：\(d)")
                } else {
                    XCTExpectFailure("试点阶段：原生与网页版拼出来的提示词的已知差异") {
                        XCTFail("\(fixture)：原生与网页版不一致：\(d)")
                    }
                }
            }
        }
        print("[weblogic] 提示词对照：共 \(total) 处不一致")
    }

    /// 重新生成：去掉的那一轮两边都不在
    func testExcludeTurn() throws {
        let (native, web) = try both("webprompt-rich.json", chat: "chat_r", now: Self.t0.addingTimeInterval(45 * 60), excludeTurn: "turn_r9")
        healthy(web, "excludeTurn")
        XCTAssertFalse(web.messages.contains { $0.content.contains("See you tomorrow") })
        XCTAssertFalse(native.messages.contains { $0.content.contains("See you tomorrow") })
        XCTAssertTrue(web.messages.contains { $0.content.contains("那就这么定了") })
    }

    /// 灌表之后改了一条：下一次读到的是新的（网页版的排序缓存按版本号认，条数相同、内容不同也要认得出）
    func testSeesChangesBetweenBuilds() throws {
        let now = Self.t0.addingTimeInterval(100)
        let (_, first) = try both("data.json", chat: "chat_a", now: now)
        XCTAssertTrue(first.messages.contains { $0.content.hasSuffix("你好") })
        var m = try XCTUnwrap(Repo.messages(chatId: "chat_a").first { $0.id == "msg_1" })
        m.row["content"] = .string("改过的一句")
        try Repo.save(m)
        let (_, second) = try both("data.json", chat: "chat_a", now: now, import: false)
        XCTAssertTrue(second.messages.contains { $0.content.hasSuffix("改过的一句") })
        XCTAssertFalse(second.messages.contains { $0.content.hasSuffix("你好") })
    }

    /// 常驻表：改了几行之后增量灌的结果，与整表重灌的逐字相同（改一条、加一条、删一条、整段删掉别的会话、加记忆、改设置、改会话）
    func testIncrementalSameAsFull() throws {
        let now = Self.t0.addingTimeInterval(45 * 60)
        let (_, first) = try both("webprompt-rich.json", chat: "chat_r", now: now)
        XCTAssertTrue(first.timing.full, "导入之后第一次整表灌")
        healthy(first, "incremental-1")
        let chat = try XCTUnwrap(Repo.chat("chat_r"))
        let char = try XCTUnwrap(Repo.character("char_r"))

        let steady = try XCTUnwrap(WebPrompt.shared.build(chat: chat, char: char, now: now))
        XCTAssertFalse(steady.timing.full)
        // 上一轮网页版写了 chats.seenAvatar（这里没写回）：那一行照原生库重灌，别的一行都不交
        XCTAssertLessThanOrEqual(steady.timing.rows, 1, "没有改动时只重灌上一轮写过的那一行")
        XCTAssertEqual(steady.system, first.system)
        XCTAssertEqual(steady.messages, first.messages)

        var m = try XCTUnwrap(Repo.messages(chatId: "chat_r").first { $0.id == "msg_r37" })
        m.row["content"] = .string("改过的一句")
        try Repo.save(m)
        let at = Self.t0.millis + 40 * 60_000
        try Database.shared.put(Collections.messages, Row(fields: [
            "id": .string("msg_new"), "chatId": .string("chat_r"), "role": .string("user"), "authorId": .string("me"),
            "kind": .string("text"), "status": .string("done"), "content": .string("新来的一句，说到拉面"),
            "createdAt": .number(at), "updatedAt": .number(at),
        ]))
        try Database.shared.delete(Collections.messages, id: "msg_r3")
        try Database.shared.deleteAll(Collections.messages, where: "chat_g")
        try Database.shared.put(Collections.memories, Row(fields: [
            "id": .string("mem_added"), "charId": .string("char_r"), "personaId": .string("me_root"),
            "content": .string("新记下：用户想去海边"), "keywords": .array([.string("拉面")]), "rank": .string("S"),
            "category": .string("fact"), "createdAt": .number(at), "updatedAt": .number(at),
        ]))
        try setSettings(["msgMin": .number(2), "msgMax": .number(5)])
        var c = chat
        c.row["summary"] = .string("RICH_SUMMARY_CHANGED")
        try Repo.save(c)

        let chat2 = try XCTUnwrap(Repo.chat("chat_r"))
        let inc = try XCTUnwrap(WebPrompt.shared.build(chat: chat2, char: char, now: now), WebPrompt.shared.lastError ?? "")
        XCTAssertFalse(inc.timing.full, "只交了变了的行")
        healthy(inc, "incremental-2")
        WebPrompt.shared.invalidate()
        let full = try XCTUnwrap(WebPrompt.shared.build(chat: chat2, char: char, now: now), WebPrompt.shared.lastError ?? "")
        XCTAssertTrue(full.timing.full)
        XCTAssertEqual(inc.system, full.system, "增量与整表的设定区不同")
        XCTAssertEqual(inc.messages, full.messages, "增量与整表的聊天记录不同")
        XCTAssertEqual(inc.recalled, full.recalled)
        let text = inc.system + inc.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(text.contains("改过的一句"))
        XCTAssertTrue(text.contains("新来的一句"))
        XCTAssertTrue(inc.system.contains("2 to 5"), "设置改了之后读到新的")
        XCTAssertFalse(text.contains("三人行"), "整段删掉的群聊不再出现")
        print("[weblogic] 增量灌表：\(inc.timing.rows) 行 \(inc.timing.bytes) 字节；整表 \(full.timing.rows) 行 \(full.timing.bytes) 字节")
    }

    /// 导入一份新备份（整批换掉）：常驻表整表重灌，上一份的数据一行不留
    func testImportRefeedsEverything() throws {
        let (_, a) = try both("webprompt-rich.json", chat: "chat_r", now: Self.t0.addingTimeInterval(45 * 60))
        XCTAssertTrue(a.system.contains("RICH_PERSONA"))
        _ = try both("webprompt-avatar.json", chat: "chat_v", now: Self.t0.addingTimeInterval(20 * 60))
        let (_, b) = try both("webprompt-avatar.json", chat: "chat_v", now: Self.t0.addingTimeInterval(20 * 60))
        XCTAssertTrue(b.timing.full, "导入之后整表重灌")
        let text = b.system + b.messages.map(\.content).joined(separator: "\n")
        XCTAssertFalse(text.contains("RICH_"), "上一份备份的数据还在表里")
    }

    /// 写回：网页版拼装途中写的 chats.seenAvatar 写进原生库，只盖改了的字段；下一轮不再说「对方换了头像」
    func testWritesGoBack() throws {
        let now = Self.t0.addingTimeInterval(20 * 60)
        let (_, first) = try both("webprompt-avatar.json", chat: "chat_v", now: now)
        healthy(first, "writes")
        let said = { (o: WebPrompt.Output) in (o.system + o.messages.map(\.content).joined(separator: "\n")).contains("[对方的头像]") }
        XCTAssertTrue(said(first), "我换了头像的那一轮说一次")
        let w = try XCTUnwrap(first.changes.first { $0.store == Collections.chats && $0.id == "chat_v" })
        XCTAssertEqual(w.op, "patch")
        XCTAssertEqual(w.set["seenAvatar"], .string("img_new"))
        XCTAssertEqual(Set(w.set.keys), ["seenAvatar", "updatedAt"], "只交改了的字段")
        XCTAssertEqual(first.changes.count, 1, "拼装途中只写这一处：\(first.writes)")

        // 拼完到写回之间原生自己改了这一行：原生改的那几个字段留着
        var c = try XCTUnwrap(Repo.chat("chat_v"))
        c.row["title"] = .string("原生刚改的")
        try Repo.save(c)
        XCTAssertEqual(WebPrompt.apply(first.changes), [])
        let row = try XCTUnwrap(Database.shared.get(Collections.chats, id: "chat_v"))
        XCTAssertEqual(row["seenAvatar"], .string("img_new"))
        XCTAssertEqual(row["title"], .string("原生刚改的"))
        XCTAssertEqual(row["unknownChatField"], .string("keep-me"), "不认得的字段写回时不丢")
        XCTAssertEqual(row["updatedAt"], .number(now.millis), "updatedAt 同网页版的 update 一样碰一下")

        let chat = try XCTUnwrap(Repo.chat("chat_v"))
        let char = try XCTUnwrap(Repo.character("char_v"))
        let second = try XCTUnwrap(WebPrompt.shared.build(chat: chat, char: char, now: now))
        XCTAssertFalse(second.timing.full)
        XCTAssertFalse(said(second), "写回之后下一轮不再说")
        XCTAssertEqual(second.changes, [], "第二轮不再写")
    }

    /// 没写回（测量、对照只拼不写）：常驻表里网页版改过的那一行照原生库换回来，下一轮照旧说
    func testUnappliedWritesRevert() throws {
        let now = Self.t0.addingTimeInterval(20 * 60)
        let (_, first) = try both("webprompt-avatar.json", chat: "chat_v", now: now)
        XCTAssertFalse(first.changes.isEmpty)
        let (_, second) = try both("webprompt-avatar.json", chat: "chat_v", now: now, import: false)
        XCTAssertFalse(second.timing.full)
        XCTAssertTrue((second.system + second.messages.map(\.content).joined()).contains("[对方的头像]"))
        XCTAssertEqual(try Database.shared.get(Collections.chats, id: "chat_v")?["seenAvatar"], .string("img_old"), "只拼不写")
    }

    /// 写回失败：一条一条报出来（调用方摆到屏幕上），不抛
    func testApplyFailureReported() throws {
        try importFixture("webprompt-avatar.json")
        let writes = [
            WebPrompt.Write(op: "patch", store: Collections.chats, id: "chat_v", set: ["seenAvatar": .string("x")]),
            WebPrompt.Write(op: "mem", store: Collections.chats, id: "chat_v"),
        ]
        Database.shared.close()
        let problems = WebPrompt.apply(writes)
        XCTAssertEqual(problems.count, 1, "patch 写不进去报一条；mem 本来就不写")
        XCTAssertTrue(problems[0].contains("chat_v"))
    }

    /// kv 的写：只盖交来的那几项，原来的照旧
    func testApplyKV() throws {
        try importFixture("webprompt-avatar.json")
        XCTAssertEqual(WebPrompt.apply([WebPrompt.Write(op: "kv", store: "kv", id: KVKey.settings,
                                                        set: ["thanksSeen": .string("1.0")], unset: ["msgMin"])]), [])
        let s = try XCTUnwrap(Database.shared.kv(KVKey.settings)?.object)
        XCTAssertEqual(s["thanksSeen"], .string("1.0"))
        XCTAssertNil(s["msgMin"])
        XCTAssertEqual(s["msgMax"], .number(2))
        XCTAssertNotNil(s["webOnlySetting"], "不认得的设置项留着")
    }

    /// 耗时与内存：rich 那段会话再加 2000 条消息、300 条记忆。一个新的 WebPrompt（量冷启动与内存），
    /// 常驻之后每拼一次（不变、每次多一条消息）与每次整表重灌各 20 次。预算是每次 50 毫秒（模拟器）；
    /// 真机上 JSContext 没有 JIT，要从 TestFlight 包里量（docs/jscore-prompt.md）
    func testSpeed() throws {
        executionTimeAllowance = 120
        try importFixture("webprompt-rich.json")
        let base = Self.t0.millis
        for i in 0..<2000 {
            let at = base - Double(2000 - i) * 60_000
            try Database.shared.put(Collections.messages, Row(fields: [
                "id": .string("msg_bulk\(i)"), "chatId": .string("chat_r"), "role": .string(i % 3 == 0 ? "user" : "char"),
                "authorId": .string(i % 3 == 0 ? "me" : "char_r"), "kind": .string("text"), "status": .string("done"),
                "content": .string("第\(i)条：今天下班路上看到一只橘猫，蹲在便利店门口不肯走"),
                "turnId": .string("turn_bulk\(i / 3)"), "createdAt": .number(at), "updatedAt": .number(at),
            ]))
        }
        for i in 0..<300 {
            let at = base - Double(i) * 3_600_000
            try Database.shared.put(Collections.memories, Row(fields: [
                "id": .string("mem_bulk\(i)"), "charId": .string("char_r"), "personaId": .string("me_root"),
                "content": .string("第\(i)条记忆：用户提到过一家店"), "keywords": .array([.string("店\(i)")]),
                "rank": .string(["S", "A", "B", "C"][i % 4]), "category": .string("fact"),
                "createdAt": .number(at), "updatedAt": .number(at),
            ]))
        }
        let chat = try XCTUnwrap(Repo.chat("chat_r"))
        let char = try XCTUnwrap(Repo.character("char_r"))
        let now = Self.t0.addingTimeInterval(45 * 60)
        let s = AppSettings.load()

        let n = 20
        var start = Date()
        for _ in 0..<n { _ = try ChatPrompt.build(chat: chat, char: char, settings: s, now: now) }
        let nativePer = Date().timeIntervalSince(start) / Double(n)

        let wp = WebPrompt()
        let mem0 = Self.footprint()
        start = Date()
        let cold = try XCTUnwrap(wp.build(chat: chat, char: char, now: now), wp.lastError ?? "")
        let coldSeconds = Date().timeIntervalSince(start)
        healthy(cold, "speed")
        XCTAssertTrue(cold.timing.full)
        wp.collectGarbage()
        let mem1 = Self.footprint()

        func run(_ label: String, _ before: (Int) throws -> Void) throws -> (per: Double, t: WebPrompt.Timing) {
            var sum = WebPrompt.Timing()
            let t0 = Date()
            for i in 0..<n {
                try before(i)
                let t = try XCTUnwrap(wp.build(chat: chat, char: char, now: now), wp.lastError ?? "").timing
                sum.read += t.read; sum.feed += t.feed; sum.refill += t.refill; sum.build += t.build
                sum.rows += t.rows; sum.bytes += t.bytes
                if label != "full" { XCTAssertFalse(t.full, label) }
            }
            return (Date().timeIntervalSince(t0) / Double(n), sum)
        }
        // 不变：只有上一轮写过的那一行（chats.seenAvatar，这里不写回）照原生库重灌
        let steady = try run("steady") { _ in }
        // 每一轮多一条消息（发一条、回一轮的常态）
        let grow = try run("grow") { i in
            let at = now.millis - 60_000 + Double(i)
            try Database.shared.put(Collections.messages, Row(fields: [
                "id": .string("msg_more\(i)"), "chatId": .string("chat_r"), "role": .string("user"), "authorId": .string("me"),
                "kind": .string("text"), "status": .string("done"), "content": .string("又一句\(i)"),
                "createdAt": .number(at), "updatedAt": .number(at),
            ]))
        }
        // 从前的做法：每一次整表重灌
        let full = try run("full") { _ in wp.invalidate() }
        wp.collectGarbage()
        let mem2 = Self.footprint()

        func ms(_ v: Double) -> String { String(format: "%.1f", v * 1000) }
        func mb(_ v: Int) -> String { String(format: "%.1f", Double(v) / 1_048_576) }
        let k = Double(n)
        func line(_ name: String, _ r: (per: Double, t: WebPrompt.Timing)) -> String {
            "\(name) \(ms(r.per)) ms/次（读库 \(ms(r.t.read / k))、灌表 \(ms(r.t.feed / k))、等 kv \(ms(r.t.refill / k))、拼装 \(ms(r.t.build / k))；"
                + "每次交 \(r.t.rows / n) 行 \(r.t.bytes / n / 1024) KB）"
        }
        print("[weblogic] 提示词耗时：原生 \(ms(nativePer)) ms/次；网页版常驻 " + line("不变", steady) + "；" + line("每次多一条", grow)
              + "；" + line("每次整表重灌", full) + "；第一次 \(ms(coldSeconds)) ms（含建 JSContext 与执行脚本 \(ms(wp.loadSeconds)) ms，"
              + "灌表 \(cold.timing.rows) 行 \(cold.timing.bytes / 1024) KB）；预算 50 ms：\(grow.per <= 0.05 ? "未超出" : "超出")")
        print("[weblogic] 提示词内存（phys_footprint）：建 JSContext 并整表灌之后多 \(mb(mem1 - mem0)) MB，再拼 \(3 * n) 次之后共多 \(mb(mem2 - mem0)) MB")
        XCTAssertLessThan(grow.per, 2, "一次拼装超过 2 秒")
        XCTAssertLessThanOrEqual(steady.t.rows / n, 1, "不变时每次最多重灌一行")
        XCTAssertLessThanOrEqual(grow.t.rows / n, 2, "每次多一条消息时只交那一条（与上一轮写过的那一行）")
    }

    /// 这个进程此刻占的内存（与 Xcode 内存表同一个数）
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

/// 变更记录（常驻表据此只交变了的行）。不要网页版的脚本，照常跑
final class ChangeLogTests: StoreTestCase {
    func testRecordsEveryWrite() throws {
        let db = Database.shared
        // 第一次问之后才开始留记录
        let c0 = db.changes.since(nil).cursor
        try db.put(Collections.chats, Row(fields: ["id": .string("c1")]))
        try db.delete(Collections.chats, id: "c1")
        try db.deleteAll(Collections.messages, where: "c1")
        try db.setKV(KVKey.settings, .object([:]))
        let (c1, list) = db.changes.since(c0)
        let want: [ChangeLog.Change] = [.row("chats", "c1"), .row("chats", "c1"), .group("messages", "c1"), .kv("settings")]
        XCTAssertEqual(list, want)
        XCTAssertEqual(db.changes.since(c1).changes?.count, 0, "之后没有新的")
    }

    func testNothingKeptUntilAsked() throws {
        let log = ChangeLog()
        let c0 = log.cursor
        log.note(.row("x", "1"))
        XCTAssertNil(log.since(c0).changes, "没人问过时不留记录，要整表")
        let c1 = log.cursor
        log.note(.row("x", "2"))
        XCTAssertEqual(log.since(c1).changes, [ChangeLog.Change.row("x", "2")])
    }

    func testFullRefeedWhenUnknown() throws {
        let db = Database.shared
        XCTAssertNil(db.changes.since(nil).changes, "第一次：整表")
        let c0 = db.changes.cursor
        try db.wipe()
        XCTAssertNil(db.changes.since(c0).changes, "清空全部数据之后：整表")
        let c1 = db.changes.cursor
        try importFixture("data.json")
        XCTAssertNil(db.changes.since(c1).changes, "导入之后：整表")
        let other = ChangeLog()
        XCTAssertNil(other.since(db.changes.cursor).changes, "换了一个库：整表")
    }

    func testOverflowMeansFull() {
        let log = ChangeLog()
        let c0 = log.since(nil).cursor
        for i in 0...ChangeLog.cap { log.note(.row("x", "\(i)")) }
        XCTAssertNil(log.since(c0).changes, "中间丢了几笔：整表")
        let c1 = log.cursor
        log.note(.kv("settings"))
        XCTAssertEqual(log.since(c1).changes, [ChangeLog.Change.kv("settings")])
    }
}

/// 开关开着时回复走网页版拼的那一份：发一条消息仍然只打一次接口（网页版第 15 条，CostTests 的同一条规矩）
final class WebPromptCostTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(WebPrompt.available, "没有网页版的拼装脚本（编译时没有取到网页版代码），跳过")
        URLProtocol.registerClass(MockNet.self)
        try importFixture("data.json")
        try setSettings(["services": .object(["chat": .object([
            "presets": .array([.object(["id": .string("svc_main"), "name": .string("主"), "provider": .string("anthropic"),
                                         "baseUrl": .string("https://main.test"), "apiKey": .string("k"), "model": .string("m")])]),
            "activeId": .string("svc_main"),
        ])])])
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        try super.tearDownWithError()
    }

    private func used() -> Int { Diagnostics.shared.entries().filter { $0["k"] as? String == "webprompt-used" }.count }

    func testFailingNetworkStillOneRequest() async throws {
        try WebPrompt.setOn(true)
        MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
        do { try await ChatEngine.reply(chatId: "chat_a") { _ in }; XCTFail("应当失败") } catch {}
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(used(), 1, "这一轮用的是网页版拼的提示词")
        let body = String(data: MockNet.requests.first?.httpBodyStreamData() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("PERSONA_TEXT"))
    }

    /// 开着时：网页版拼装途中的写（我的头像已看过）写回原生库，这一轮仍只打一次接口
    func testReplyAppliesWrites() async throws {
        try WebPrompt.setOn(true)
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("在的")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(used(), 1)
        XCTAssertEqual(try Database.shared.get(Collections.chats, id: "chat_a")?["seenAvatar"], .string("-"), "我没有头像，记成 -")
    }

    func testOffByDefault() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: MockNet.anthropicStream("在的")) }
        try await ChatEngine.reply(chatId: "chat_a") { _ in }
        XCTAssertEqual(MockNet.count, 1)
        XCTAssertEqual(used(), 0, "默认关着，用的是原生拼的")
    }
}
