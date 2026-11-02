import XCTest
@testable import Eira

/// 拼提示词只读末尾够用的那一截（不再整段读出来）：拼出来的必须和整段读出来再拼的一字不差。
/// 一段几千条、各种消息都有的会话：失败的、撤回的、只给你看的、自动回复、图、引用很早的一条、见面的分隔线与 side、
/// 线下正文（早的、晚的、和消息同一毫秒的）、很早以前还挂着的转账与约定、很早以前存下的状态栏值、正在输入。
/// 各种历史范围（N 条、N 轮、全部）、扫描窗口、重新生成、通话、群聊都比一遍。
final class HistoryWindowTests: StoreTestCase {
    private struct Rng {
        var s: UInt64
        mutating func int(_ n: Int) -> Int {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Int((s >> 33) % UInt64(n))
        }
    }

    private let now = Date()
    private var base: Double { now.millis - 70 * 86_400_000 }
    /// 第 i 条的时间：七分钟一条，每一百条隔一天
    private func at(_ i: Int) -> Double { base + Double(i) * 420_000 + Double(i / 100) * 86_400_000 }

    private static let texts = ["今天下雨了", "你吃饭了没有", "我刚刚在想你说的那件事", "猫在窗台上睡着了", "周末一起去看电影吗",
                                "Did you finish the report?", "晚安，早点睡", "我把那本书看完了", "密码改成我的生日了吗", "外面好冷"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
        for m in try Repo.messages(chatId: "chat_a") { try Database.shared.delete(Collections.messages, id: m.id) }
    }

    private func put(_ f: [String: JSONValue]) throws {
        try Database.shared.put(Collections.messages, Row(fields: f))
    }

    /// 一段 n 条的会话。authors：角色那一侧轮流由谁说（群聊里是几个成员）
    private func fill(_ chatId: String, n: Int, authors: [String], group: Bool = false) throws {
        var rng = Rng(s: 20261102)
        var userRun = 0
        for i in 0..<n {
            // 我连着说一到三条，角色连着回一到四条；最后三条是我说的（当前这一轮）
            let user: Bool
            if i >= n - 3 { user = true }
            else if userRun > 0 { user = true; userRun -= 1 }
            else { user = rng.int(3) == 0; if user { userRun = rng.int(3) } }
            let author = user ? "me" : authors[i % authors.count]
            var f: [String: JSONValue] = [
                "id": .string("\(chatId)_m\(i)"), "chatId": .string(chatId), "role": .string(user ? "user" : "char"),
                "authorId": .string(author), "kind": .string("text"), "content": .string(Self.texts[rng.int(Self.texts.count)] + "（\(i)）"),
                "status": .string("done"), "createdAt": .number(at(i)), "updatedAt": .number(at(i)),
            ]
            if !user { f["turnId"] = .string("\(chatId)_turn\(i / 6)") }
            if i % 53 == 7 { f["status"] = .string("error") }
            if i % 71 == 13 { f["recalled"] = .object(["at": .number(1), "seen": .bool(i % 2 == 0)]) }
            if i % 89 == 17 { f["kind"] = .string("notice"); f["local"] = .bool(true) }
            if i % 61 == 19 && !user { f["auto"] = .bool(true) }
            if i % 37 == 3 { f["kind"] = .string("image"); f["imageId"] = .string("img_\(i)"); f["content"] = .string("[图片：一只猫]") }
            if i % 97 == 5 { f["reactions"] = .array([.object(["e": .string("ok"), "by": .string("me")])]) }
            if i % 113 == 23 { f["kind"] = .string("song"); f["songLyric"] = .string("第一句\n第二句\n第三句") }
            if group && user && i % 7 == 0 { f["mentions"] = .array([.string(authors[0])]) }
            // 很早以前：还挂着的转账、没完成的约定、失败的外卖（不算挂着）、存下的状态栏值、一份带正文的文件
            switch i {
            case 10: f["kind"] = .string("transfer"); f["transfer"] = .string("pending"); f["status"] = .string("done")
            case 20: f["kind"] = .string("pact"); f["pact"] = .string(Space.pactOpen); f["status"] = .string("done")
            case 30: f["kind"] = .string("takeout"); f["takeout"] = .string("pending"); f["status"] = .string("error")
            case 50:
                f["sbar"] = .object(["items": .array([.object(["id": .string("mood"), "label": .string("心情"), "value": .string("开心")])])])
                f["status"] = .string("done"); f["recalled"] = nil
            case 100: f["kind"] = .string("file"); f["text"] = .string("很早的文件正文"); f["status"] = .string("done")
            default: break
            }
            // 末尾那一段：见面的分隔线与 side、引用（很早的、失败的、窗口里的、只有原文的）、挂着的礼物、带正文的文件
            if i == n - 32 { f["kind"] = .string("side"); f["side"] = .string(Face.FACE); f["face"] = .object(["place": .string("旧书店")]) }
            if i > n - 32 && i < n - 16 { f["side"] = .string(Face.FACE) }
            if i == n - 16 { f["kind"] = .string("side"); f["side"] = .string(Face.PHONE) }
            if i == n - 12 { f["kind"] = .string("file"); f["text"] = .string("最近的文件正文"); f["media"] = .string("done"); f["status"] = .string("done") }
            if i == n - 9 { f["kind"] = .string("gift"); f["gift"] = .string("pending"); f["status"] = .string("done") }
            if i == n - 8 { f["quoteId"] = .string("\(chatId)_m5"); f["quoteText"] = .string("备用的原文") }
            if i == n - 7 { f["quoteId"] = .string("\(chatId)_m7"); f["quoteText"] = .string("失败那条的原文") }
            if i == n - 6 { f["quoteId"] = .string("\(chatId)_m\(n - 10)") }
            if i == n - 5 { f["quoteText"] = .string("只有原文") }
            if i >= n - 3 { f["status"] = .string("done"); f["kind"] = .string("text"); f["recalled"] = nil; f["local"] = nil }
            try put(f)
        }
        // 正在输入那一条不进
        try put(["id": .string("\(chatId)_typing"), "chatId": .string(chatId), "role": .string("char"), "authorId": .string(authors[0]),
                 "kind": .string("typing"), "content": .string(""), "createdAt": .number(at(n) + 1)])
    }

    /// 线下一场的几段正文：很早的两段、末尾的两段、一段和消息同一毫秒
    private func beats(_ chatId: String, n: Int) throws {
        var d = Scenes.Draft()
        d.place = "旧书店"
        d.at = "2026-01-01 周三 14:30"
        d.castIds = ["char_a"]
        d.autoEnter = false
        let sc = try Scenes.create(chatId: chatId, d)
        for (k, t) in [at(500) + 1, at(501) + 1, at(n - 20), at(n - 14) + 1, at(n - 13) + 1].enumerated() {
            try Scenes.addBeat(sceneId: sc.id, role: k % 2 == 0 ? Scenes.ME : Scenes.CHAR, authorId: k % 2 == 0 ? "me" : "char_a",
                               text: "线下第\(k)段", now: Date(millis: t))
        }
    }

    private func settings(_ f: [String: JSONValue]) throws {
        var all: [String: JSONValue] = ["historyMode": .string("count"), "historyLimit": .number(20), "historyTurns": .number(10),
                                        "scanWindow": .number(6), "memoryDepth": .number(1)]
        for (k, v) in f { all[k] = v }
        try setSettings(all)
    }

    private static let configs: [(String, [String: JSONValue])] = [
        ("默认 20 条", [:]),
        ("7 条", ["historyLimit": .number(7)]),
        ("300 条", ["historyLimit": .number(300)]),
        ("3 轮", ["historyMode": .string("turn"), "historyTurns": .number(3)]),
        ("25 轮、扫描 40 条", ["historyMode": .string("turn"), "historyTurns": .number(25), "scanWindow": .number(40)]),
        ("全部", ["historyLimit": .number(0)]),
        ("全部轮", ["historyMode": .string("turn"), "historyTurns": .number(0)]),
        ("扫描全部", ["scanWindow": .number(0)]),
        ("记忆在设定区、60 条", ["memoryDepth": .number(0), "historyLimit": .number(60)]),
    ]

    private func same(_ a: ChatPrompt.Built, _ b: ChatPrompt.Built, _ label: String) {
        XCTAssertEqual(a.system, b.system, label)
        XCTAssertEqual(a.messages.count, b.messages.count, label)
        for (x, y) in zip(a.messages, b.messages) where x != y {
            XCTFail("\(label)：\(x.role) \(x.content.prefix(80)) 对 \(y.role) \(y.content.prefix(80))")
            break
        }
        XCTAssertEqual(a.recalled, b.recalled, label)
        XCTAssertEqual(a.seenImages, b.seenImages, label)
    }

    private func statusOn(_ chatId: String) throws {
        var cfg = StatusBar.config(try XCTUnwrap(Repo.chat(chatId)))
        cfg.on = true
        for i in cfg.items.indices where cfg.items[i].id == "mood" { cfg.items[i].on = true }
        try StatusBar.save(chatId, cfg)
    }

    func testOneToOneWindowMatchesFullLoad() throws {
        let n = 3000
        try fill("chat_a", n: n, authors: ["char_a"])
        try beats("chat_a", n: n)
        try statusOn("chat_a")
        let char = try XCTUnwrap(Repo.character("char_a"))
        for (label, cfg) in Self.configs {
            try settings(cfg)
            let s = AppSettings.load()
            let chat = try XCTUnwrap(Repo.chat("chat_a"))
            let ref = try ChatPrompt.buildReference(chat: chat, char: char, settings: s, now: now)
            same(try ChatPrompt.build(chat: chat, char: char, settings: s, now: now), ref, label)
            // 重新生成（去掉最后一轮角色说的）与通话
            let turn = "chat_a_turn\((n - 4) / 6)"
            same(try ChatPrompt.build(chat: chat, char: char, settings: s, now: now, excludeTurn: turn),
                 try ChatPrompt.buildReference(chat: chat, char: char, settings: s, now: now, excludeTurn: turn), label + "，重新生成")
            same(try ChatPrompt.build(chat: chat, char: char, settings: s, now: now, call: (rule: "CALL_RULE", script: "CALL_SCRIPT")),
                 try ChatPrompt.buildReference(chat: chat, char: char, settings: s, now: now, call: (rule: "CALL_RULE", script: "CALL_SCRIPT")),
                 label + "，通话")
        }
        // 这几样确实要看窗口之前的：很早存下的状态栏值、很早引用的那一条
        try settings([:])
        let b = try ChatPrompt.build(chat: try XCTUnwrap(Repo.chat("chat_a")), char: char, settings: .load(), now: now)
        let everything = b.system + b.messages.map(\.content).joined()
        XCTAssertTrue(everything.contains("心情：开心"))
        XCTAssertFalse(everything.contains("备用的原文"))
        XCTAssertTrue(everything.contains("失败那条的原文"))
        XCTAssertTrue(everything.contains("最近的文件正文"))
        XCTAssertFalse(everything.contains("很早的文件正文"))
    }

    func testOneToOneShortChats() throws {
        // 条数比窗口还少、一条角色说的都没有、只有一两条：读到头为止
        let char = try XCTUnwrap(Repo.character("char_a"))
        for n in [1, 2, 5, 9, 40] {
            for m in try Repo.messages(chatId: "chat_a") { try Database.shared.delete(Collections.messages, id: m.id) }
            try fill("chat_a", n: n, authors: ["char_a"])
            for (label, cfg) in Self.configs {
                try settings(cfg)
                let s = AppSettings.load()
                let chat = try XCTUnwrap(Repo.chat("chat_a"))
                same(try ChatPrompt.build(chat: chat, char: char, settings: s, now: now),
                     try ChatPrompt.buildReference(chat: chat, char: char, settings: s, now: now), "\(n) 条，\(label)")
            }
        }
    }

    func testGroupWindowMatchesFullLoad() throws {
        var z = try People.createCharacter(name: "小周")
        z.row["persona"] = .string("ZHOU_PERSONA")
        try Database.shared.put(Collections.characters, z.row)
        let g = try GroupChat.create(memberIds: ["char_a", z.id], title: "", personaId: "me_root")
        try fill(g.id, n: 2500, authors: ["char_a", z.id], group: true)
        let members = GroupChat.members(g)
        for (label, cfg) in Self.configs {
            try settings(cfg)
            let s = AppSettings.load()
            let chat = try XCTUnwrap(Repo.chat(g.id))
            same(try ChatPrompt.buildGroup(chat: chat, members: members, settings: s, now: now),
                 try ChatPrompt.buildGroupReference(chat: chat, members: members, settings: s, now: now), "群聊，\(label)")
        }
    }
}

/// 互动标识第一次从头统计放到后台分批做：分批、中途停下再接着做、整段重算，结果都和一次整段过的一模一样；
/// 打开会话时不等它。
final class BadgesPassTests: StoreTestCase {
    private let now = Date()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
        for m in try Repo.messages(chatId: "chat_a") { try Database.shared.delete(Collections.messages, id: m.id) }
    }

    /// 三四年、五千条：有互发的日子、断了又接上的、凌晨三点双方都在、早安晚安、同一分钟同一个表情、通话、一起听、
    /// 520 的转账、信、完成约定的提示、失败的、同一毫秒的几条
    private func fill(_ n: Int = 5000) throws {
        var s: UInt64 = 7
        func r(_ k: Int) -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) % UInt64(k)) }
        // 每条平均隔六小时左右，五千条三年多；从四年前起，最后一条也早于现在
        let start = now.millis - 1500 * 86_400_000
        var t = start
        for i in 0..<n {
            t += Double([60_000, 30_000, 3_600_000, 86_400_000, 0, 600_000, 2 * 86_400_000][r(7)] / (r(3) + 1))
            let user = r(2) == 0
            var f: [String: JSONValue] = [
                "id": .string("b\(i)"), "chatId": .string("chat_a"), "role": .string(user ? "user" : "char"),
                "authorId": .string(user ? "me" : "char_a"), "kind": .string("text"),
                "content": .string(["在吗", "早安", "晚安", "good morning", "好的", "下雨了"][r(6)]),
                "status": .string(r(40) == 0 ? "error" : "done"), "createdAt": .number(t),
            ]
            switch r(30) {
            case 0: f["kind"] = .string("sticker"); f["stickerId"] = .string("st_\(r(2))")
            case 1: f["kind"] = .string("call"); f["outcome"] = .string("done"); f["seconds"] = .number(Double(r(5000)))
            case 2: f["kind"] = .string("listen"); f["seconds"] = .number(Double(r(4000)))
            case 3: f["kind"] = .string("transfer"); f["amount"] = .number(r(3) == 0 ? 520 : 13)
            case 4: f["kind"] = .string("letter")
            case 5: f["kind"] = .string("notice"); f["settledKind"] = .string("pact")
            default: break
            }
            try Database.shared.put(Collections.messages, Row(fields: f))
        }
    }

    private func snapshot() throws -> [JSONValue?] {
        let c = try XCTUnwrap(Repo.chat("chat_a"))
        return [c.row["stats"], c.row["unlocked"], c.row["limited"]]
    }

    private func restore(_ v: [JSONValue?]) throws {
        var c = try XCTUnwrap(Repo.chat("chat_a"))
        c.row["stats"] = v[0]
        c.row["unlocked"] = v[1]
        c.row["limited"] = v[2]
        try Repo.save(c)
    }

    /// 改之前的做法：一次整段过（inlineMax 放到最大，sync 自己过）
    private func reference(full: Bool = false) throws -> [JSONValue?] {
        let keep = Badges.inlineMax
        Badges.inlineMax = Int.max
        defer { Badges.inlineMax = keep }
        try Badges.sync("chat_a", full: full, now: now)
        return try snapshot()
    }

    func testChunkedAndResumedEqualsFullPass() throws {
        try fill()
        let before = try snapshot()
        let ref = try reference()
        XCTAssertNotNil(ref[0])
        try restore(before)

        // 一批 333 条，过四批停下（像应用中途被关掉），进度存着，统计还没写
        XCTAssertFalse(try Badges.runPass("chat_a", now: now, chunk: 333, maxChunks: 4))
        XCTAssertTrue(Badges.passSaved("chat_a"))
        XCTAssertNil(try Repo.chat("chat_a")?.row["stats"])
        // 接着过完
        XCTAssertTrue(try Badges.runPass("chat_a", now: now, chunk: 333))
        XCTAssertFalse(Badges.passSaved("chat_a"))
        XCTAssertEqual(try snapshot(), ref)

        // 之后的增量照旧：再来几条，和一次整段过的同样往下走
        for k in 0..<5 {
            try Database.shared.put(Collections.messages, Row(fields: [
                "id": .string("late\(k)"), "chatId": .string("chat_a"), "role": .string(k % 2 == 0 ? "user" : "char"),
                "authorId": .string(k % 2 == 0 ? "me" : "char_a"), "kind": .string("text"), "content": .string("晚安"),
                "status": .string("done"), "createdAt": .number(now.millis - 1000 + Double(k)),
            ]))
        }
        try Badges.sync("chat_a", now: now)
        let incremental = try snapshot()
        try restore(before)
        XCTAssertEqual(try reference(), incremental)
    }

    func testFullRecountChunkedEqualsFullPass() throws {
        try fill()
        _ = try reference()
        // 手动颁发的一枚：重新统计也留着
        try BadgeDefs.grant("chat_a", "custom-handmade")
        let before = try snapshot()
        let ref = try reference(full: true)
        try restore(before)
        XCTAssertTrue(try Badges.runPass("chat_a", full: true, now: now, chunk: 500))
        XCTAssertEqual(try snapshot(), ref)
        XCTAssertNotNil(try Repo.chat("chat_a")?.row["unlocked"]?["custom-handmade"])
    }

    func testOpeningDoesNotWait() throws {
        try fill()
        let before = try snapshot()
        let ref = try reference()
        try restore(before)
        let keep = Badges.inlineMax
        Badges.inlineMax = 1000
        defer { Badges.inlineMax = keep }
        let done = expectation(description: "后台过完")
        let token = NotificationCenter.default.addObserver(forName: Badges.didFinish, object: nil, queue: nil) { n in
            if (n.object as? String) == "chat_a" { done.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        // 打开会话：不等，统计先空着
        XCTAssertEqual(try Badges.sync("chat_a", now: now), [])
        XCTAssertNil(try Repo.chat("chat_a")?.row["stats"])
        // 后台还在过时再打开一次：不另起一遍
        XCTAssertEqual(try Badges.sync("chat_a", now: now), [])
        wait(for: [done], timeout: 60)
        XCTAssertFalse(Badges.passActive("chat_a"))
        let got = try snapshot()
        // 档位解锁的时间是过完那一刻，其余一模一样
        XCTAssertEqual(got[0], ref[0])
        XCTAssertEqual(Set((got[1]?.object ?? [:]).keys), Set((ref[1]?.object ?? [:]).keys))
        XCTAssertEqual(got[2], ref[2])
    }
}
