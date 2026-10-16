import XCTest
@testable import Eira

/// 设定集与联系里和网页版对齐的几处（第二批 32 至 39）：世界书改用途与批量调整、内置提示词的名称、能力分组、封存的日期。
final class CanonTests: StoreTestCase {
    private func entry(_ id: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "comment": .string(id), "keys": .array([.string("k")]), "content": .string("c"),
                                      "enabled": .bool(true), "constant": .bool(false), "priority": .number(100), "part": .string("before"),
                                      "depth": .number(0), "caseSensitive": .bool(false), "probability": .number(100)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    /// 改用途：四个标记全写，不残留旧的 true；改成论坛用时不再全局生效（网页版 purposePatch）
    func testPurposePatch() throws {
        let b = try Knowledge.createBook(name: "书")
        XCTAssertEqual(b.purpose, "chat")
        var now = try Knowledge.updateBook(b.id, LoreText.purposePatch("image"))
        XCTAssertEqual(now.purpose, "image")
        now = try Knowledge.updateBook(b.id, LoreText.purposePatch("memory"))
        XCTAssertEqual(now.purpose, "memory")
        XCTAssertEqual(now.row.bool("forImage"), false)
        _ = try Knowledge.updateBook(b.id, ["global": .bool(true)])
        now = try Knowledge.updateBook(b.id, LoreText.purposePatch("forum"))
        XCTAssertEqual(now.purpose, "forum")
        XCTAssertFalse(now.global)
        now = try Knowledge.updateBook(b.id, LoreText.purposePatch("chat"))
        XCTAssertEqual(now.purpose, "chat")
        // 原生版没有论坛：论坛只在这本书本来就是论坛用时列出
        XCTAssertFalse(LoreText.purposeChoices(current: "chat").contains("forum"))
        XCTAssertTrue(LoreText.purposeChoices(current: "forum").contains("forum"))
        XCTAssertEqual(LoreText.purposeTag("voice"), " \u{00B7} 只用于语音")
        XCTAssertEqual(LoreText.purposeTag("chat"), "")
    }

    /// 批量调整（网页版 lorebulk）：改选中几条的常驻、所属部分、深度；没碰的各项原样；没选的那条与卡片不变
    func testBulkChangesOnlyPickedFields() throws {
        let entries = [entry("a", ["priority": .number(7)]), entry("b"), entry("c"),
                       entry("d", ["type": .string("card"), "constant": .bool(false)])]
        let change = LoreBulk.change(tri: ["enabled": "", "constant": "on", "caseSensitive": ""], part: "after", depth: 3,
                                     priority: nil, probability: nil, bare: false)
        XCTAssertEqual(change.count, 3)
        let out = LoreBulk.apply(entries, ids: ["a", "b", "d"], change: change)
        XCTAssertEqual(out[0]["constant"]?.bool, true)
        XCTAssertEqual(out[0]["part"]?.string, "after")
        XCTAssertEqual(out[0]["depth"]?.number, 3)
        XCTAssertEqual(out[0]["priority"]?.number, 7)
        XCTAssertEqual(out[0]["enabled"]?.bool, true)
        XCTAssertEqual(out[1]["constant"]?.bool, true)
        XCTAssertEqual(out[2], entries[2])
        XCTAssertEqual(out[3], entries[3])

        // 不进对话的书没有所属部分与注入深度；一项没选时什么都不改
        let bare = LoreBulk.change(tri: ["enabled": "off"], part: "after", depth: 2, priority: 50, probability: nil, bare: true)
        XCTAssertEqual(Set(bare.keys), ["enabled", "priority"])
        XCTAssertEqual(bare["enabled"]?.bool, false)
        XCTAssertTrue(LoreBulk.change(tri: ["enabled": "", "constant": ""], part: "", depth: nil, priority: nil, probability: nil, bare: false).isEmpty)

        // 写回库里：条目以外的书照旧
        let b = try Knowledge.createBook(name: "书")
        _ = try Knowledge.updateBook(b.id, ["entries": .array(entries)])
        let next = LoreBulk.apply(entries, ids: ["c"], change: ["enabled": .bool(false)])
        let saved = try Knowledge.updateBook(b.id, ["entries": .array(next)])
        XCTAssertEqual(saved.entries.first(where: { $0.id == "c" })?.enabled, false)
        XCTAssertEqual(saved.entries.first(where: { $0.id == "a" })?.enabled, true)
        XCTAssertEqual(saved.name, "书")
    }

    /// 「以前修改过的内置提示词」显示名称（网页版 labelOf）：没有名称的显示 id
    func testTemplateLabels() {
        XCTAssertEqual(TemplateLabels.of("skeleton.opening"), "骨架 · 身份开场")
        XCTAssertEqual(TemplateLabels.of("task.memory-extract"), "任务 · 提取记忆")
        XCTAssertEqual(TemplateLabels.of("no.such"), "no.such")
        for id in TemplateLabels.labels.keys { XCTAssertNotNil(Templates.defaults[id], id) }
    }

    /// 能力分组（网页版 CapsPage.js）：打电话在「一起」，群昵称与群管理在「群聊」；说明里称「角色能力」
    func testCapsGroups() {
        let group = Dictionary(uniqueKeysWithValues: CapsView.caps.map { ($0.id, $0.group) })
        XCTAssertEqual(group["ring"], "一起")
        XCTAssertEqual(group["listen"], "一起")
        XCTAssertEqual(group["groupnick"], "群聊")
        XCTAssertEqual(group["groupadmin"], "群聊")
        for c in CapsView.caps {
            XCTAssertTrue(CapsView.groups.contains(c.group), c.id)
            XCTAssertFalse(c.info.contains("角色卡"), c.id)
        }
    }

    /// 已封存页的日期写法同网页版 toLocaleDateString('zh-CN')
    func testArchivedDay() {
        let d = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        XCTAssertEqual(ArchivedCharsView.day(d.millis), "2026/3/7")
    }
}
