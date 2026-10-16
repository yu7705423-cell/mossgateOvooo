import XCTest
@testable import Eira

/// 记忆首页（网页版 MemoryHome，4.649）：主角在上；NPC 与小号按归属的主角分开、只列有记忆的；没绑定角色的单独一行
final class MemoryHomeTests: StoreTestCase {
    private func char(_ id: String, _ extra: [String: JSONValue] = [:]) -> Character {
        var f: [String: JSONValue] = ["id": .string(id), "name": .string(id)]
        for (k, v) in extra { f[k] = v }
        return Character(row: Row(fields: f))
    }

    private func mem(_ id: String, char: String?, rank: String = "B", extra: [String: JSONValue] = [:]) -> Memory {
        var f: [String: JSONValue] = ["id": .string(id), "content": .string(id), "rank": .string(rank)]
        if let char { f["charId"] = .string(char) }
        for (k, v) in extra { f[k] = v }
        return Memory(row: Row(fields: f))
    }

    func testPlanSeparatesMainsFromNpcsAndAlts() {
        let chars = [
            char("a"), char("b"),
            char("alt", ["parentId": .string("b")]),
            char("npc1", ["isNpc": .bool(true), "relations": .array([.object(["charId": .string("zzz")]), .object(["charId": .string("a")])])]),
            char("npc2", ["isNpc": .bool(true)]),
            char("npc3", ["isNpc": .bool(true), "relations": .array([.object(["charId": .string("a")])])]),
        ]
        let mems = [
            mem("m1", char: "b", rank: "S"), mem("m2", char: "b", rank: "A"),
            mem("m3", char: "alt"), mem("m4", char: "npc1", rank: "C"), mem("m5", char: "npc2"),
            mem("m6", char: nil), mem("m7", char: "", rank: "A", extra: ["supersededBy": .string("m2")]),
        ]
        let p = MemoryHome.plan(chars: chars, memories: mems)
        // 主角按条数排，没有记忆的也列出
        XCTAssertEqual(p.mains.map(\.id), ["b", "a"])
        XCTAssertEqual(p.extras, 4)
        // 只列有记忆的；npc3 没有记忆
        XCTAssertEqual(p.extraRows, 3)
        XCTAssertEqual(p.groups.map(\.owner), ["b", "a", ""])
        XCTAssertEqual(p.groups.map(\.name), ["b", "a", "未关联主角"])
        XCTAssertEqual(p.groups[0].rows.map(\.id), ["alt"])
        XCTAssertEqual(p.groups[1].rows.map(\.id), ["npc1"])
        XCTAssertEqual(p.groups[2].rows.map(\.id), ["npc2"])
        // 没有 charId 字段的与 charId 为空串的都算没绑定角色
        XCTAssertEqual(Set(p.loose.map(\.id)), ["m6", "m7"])
        XCTAssertEqual(p.stats, [1, 2, 3, 1])
        // A、B 级里让位了的不算
        XCTAssertEqual(p.injected, 4)
    }

    func testSubtitle() {
        let list = [mem("x1", char: "a", rank: "S"), mem("x2", char: "a", rank: "B", extra: ["twin": .string("t")]),
                    mem("x3", char: "a", rank: "B", extra: ["scopeChat": .string("chat_g")])]
        XCTAssertEqual(MemoryHome.rankLine(list), "S 1\u{3000}B 2")
        XCTAssertEqual(MemoryHome.subtitle(list), "3 条 \u{00B7} S 1\u{3000}B 2 \u{00B7} 其中 2 条来自群聊")
        XCTAssertEqual(MemoryHome.subtitle([]), "0 条")
    }

    /// 没绑定角色的：库里没有 charId 字段的也读得到；指定角色后归那个角色；多选删除
    func testLooseAssignAndRemove() throws {
        try Database.shared.put(Collections.memories, mem("l1", char: nil).row)
        try Database.shared.put(Collections.memories, mem("l2", char: "").row)
        try Database.shared.put(Collections.memories, mem("k1", char: "a").row)
        XCTAssertEqual(Set(try LooseMemory.list().map(\.id)), ["l1", "l2"])
        try LooseMemory.assign(["l1"], to: "a")
        XCTAssertEqual(Set(try Repo.memories(charId: "a").map(\.id)), ["k1", "l1"])
        XCTAssertEqual(try LooseMemory.list().map(\.id), ["l2"])
        try LooseMemory.remove(["l2"])
        XCTAssertTrue(try LooseMemory.list().isEmpty)
        XCTAssertNotNil(try Database.shared.get(Collections.memories, id: "k1"))
    }

    /// 尚未总结的条数是各段对话积压的总和
    func testPendingTotal() throws {
        XCTAssertEqual(MemoryHome.pendingTotal(), 0)
        try Database.shared.put(Collections.chats, Row(fields: ["id": .string("chat_p"), "characterIds": .array([.string("a")])]))
        _ = try Repo.append(Message.new(chatId: "chat_p", role: .user, authorId: "me", content: "你好"))
        _ = try Repo.append(Message.new(chatId: "chat_p", role: .char, authorId: "a", content: "嗯", turnId: "t1"))
        XCTAssertEqual(MemoryHome.pendingTotal(), try MemorySummary.pending(chatId: "chat_p").count)
        XCTAssertEqual(MemoryHome.pendingTotal(), 2)
    }
}
