import XCTest
@testable import Eira

/// 生图提示词预设（网页版 imgprompts.js，4.522）：全局与角色各一份，字段名与网页版相同，只换那一栏文字。
final class ImgPromptsTests: StoreTestCase {
    private func globalState() -> ImgPrompts.State {
        let raw = AppSettings.load().raw
        return ImgPrompts.state { raw[$0] }
    }

    private func applyGlobal(_ p: [String: JSONValue]?) throws {
        guard let p else { return XCTFail("没有要写的") }
        var s = try AppSettings.loadForWrite()
        for (k, v) in p { s.raw[k] = v }
        try s.save()
    }

    func testGlobalFlow() throws {
        try setSettings(["imagePrompt": .string("film grain")])
        var st = globalState()
        XCTAssertTrue(st.rows.isEmpty)
        XCTAssertNil(st.current)
        XCTAssertFalse(st.dirty)

        // 存为预设：成为当前那份，名字空着按序号起
        let a = ImgPrompts.saveAs(st, name: "  ")
        XCTAssertEqual(a.row.name, "预设 1")
        try applyGlobal(a.patch)
        st = globalState()
        XCTAssertEqual(st.rows.count, 1)
        XCTAssertEqual(st.current?.id, a.row.id)
        XCTAssertEqual(AppSettings.load().raw["imagePromptPresetId"]?.string, a.row.id)
        XCTAssertEqual(AppSettings.load().raw["imagePromptPresets"]?[0]?["text"]?.string, "film grain")

        // 改了那一栏：标出未存回；存回后不再标
        try setSettings(["imagePrompt": .string("watercolor")])
        st = globalState()
        XCTAssertTrue(st.dirty)
        XCTAssertFalse(st.known)
        try applyGlobal(ImgPrompts.overwrite(st))
        st = globalState()
        XCTAssertFalse(st.dirty)
        XCTAssertEqual(st.rows.first?.text, "watercolor")

        // 另存一份，再切回第一份：那一栏换成它的文字
        try setSettings(["imagePrompt": .string("ink")])
        st = globalState()
        let b = ImgPrompts.saveAs(st, name: "水墨")
        try applyGlobal(b.patch)
        st = globalState()
        XCTAssertFalse(ImgPrompts.needsConfirm(st, to: st.rows[0]), "已存进预设的文字切换时不必确认")
        try applyGlobal(ImgPrompts.apply(st, id: a.row.id))
        st = globalState()
        XCTAssertEqual(st.text, "watercolor")
        XCTAssertEqual(st.current?.id, a.row.id)

        // 重命名；删除当前那份不动那一栏
        try applyGlobal(ImgPrompts.rename(st, id: b.row.id, name: " 水墨二 "))
        st = globalState()
        XCTAssertEqual(st.rows.first(where: { $0.id == b.row.id })?.name, "水墨二")
        XCTAssertNil(ImgPrompts.rename(st, id: b.row.id, name: "  "))
        try applyGlobal(ImgPrompts.remove(st, id: a.row.id))
        st = globalState()
        XCTAssertEqual(st.rows.map(\.id), [b.row.id])
        XCTAssertNil(st.current)
        XCTAssertEqual(st.text, "watercolor")
    }

    /// 那一栏里有没存进任何一份的文字，切换前要确认
    func testNeedsConfirm() {
        let row = ImgPrompts.Preset(id: "p1", name: "一", text: "aaa")
        let st = ImgPrompts.State(rows: [row], current: nil, text: "unsaved")
        XCTAssertTrue(ImgPrompts.needsConfirm(st, to: row))
        XCTAssertFalse(ImgPrompts.needsConfirm(ImgPrompts.State(rows: [row], current: nil, text: "  "), to: row))
        XCTAssertFalse(ImgPrompts.needsConfirm(ImgPrompts.State(rows: [row], current: nil, text: "aaa"), to: row))
    }

    /// 网页版写的清单读得进来：没有 id 的丢掉，名字空着记作「未命名」
    func testCleanWebRows() {
        let v: JSONValue = .array([
            .object(["id": .string("ipp_1"), "name": .string(""), "text": .string("t")]),
            .object(["name": .string("没有 id")]),
            .string("坏数据"),
        ])
        XCTAssertEqual(ImgPrompts.clean(v), [ImgPrompts.Preset(id: "ipp_1", name: "未命名", text: "t")])
    }

    /// 角色那一份写在角色卡上，其他字段原样留着
    func testCharacterScope() throws {
        let c = try People.createCharacter()
        _ = try People.update(c, ["imagePrompt": .string("red scarf")])
        var cur = try XCTUnwrap(Repo.character(c.id))
        let made = ImgPrompts.saveAs(ImgPrompts.state { cur.row[$0] }, name: "围巾")
        _ = try People.update(cur, made.patch)
        cur = try XCTUnwrap(Repo.character(c.id))
        XCTAssertEqual(cur.row["imagePromptPresets"]?[0]?["name"]?.string, "围巾")
        XCTAssertEqual(cur.row["imagePromptPresetId"]?.string, made.row.id)
        XCTAssertEqual(cur.row.string("imagePrompt"), "red scarf")
        XCTAssertEqual(cur.row["canSendVoice"]?.bool, true)
        // 设置里那一份不受影响
        XCTAssertNil(AppSettings.load().raw["imagePromptPresets"])
    }
}
