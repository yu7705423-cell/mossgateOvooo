import XCTest
@testable import Eira

/// 主屏整理（网页版 screens/home/layout.js）：挪、挤开、对调、底栏、文件夹、移除与放回；不认得的字段原样留着。
final class HomeLayoutTests: StoreTestCase {
    private func cell(_ id: String, _ ref: String, _ x: Int, _ y: Int, w: Int = 1, h: Int = 1, kind: String = "app") -> JSONValue {
        .object(["id": .string(id), "kind": .string(kind), "ref": .string(ref), "x": .number(Double(x)), "y": .number(Double(y)),
                 "w": .number(Double(w)), "h": .number(Double(h))])
    }

    private func seed() throws {
        try Database.shared.setKV(KVKey.layout, .object([
            "pages": .array([
                .object(["id": .string("p1"), "cells": .array([
                    cell("a", "chat", 0, 0), cell("b", "diary", 1, 0), cell("w", "note", 0, 1, w: 2, h: 1, kind: "widget"),
                ]), "webOnly": .bool(true)]),
                .object(["id": .string("p2"), "cells": .array([cell("c", "music", 0, 0)])]),
            ]),
            "dock": .array([.string("settings"), .null, .null, .null]),
            "keepMe": .string("x"),
        ]))
    }

    private func at(_ h: HomeLayout, _ id: String) -> (Int, Int, Int)? {
        h.locate(id).map { ($0.page, HomeLayout.x($0.cell), HomeLayout.y($0.cell)) }
    }

    /// 没存过从默认版式开始；存回去的保留不认得的字段
    func testDefaultAndUnknownFields() throws {
        XCTAssertFalse(try HomeLayout.begin(settings: [:]).pages.isEmpty, "没存过时按默认版式")
        try seed()
        var h = try HomeLayout.begin(settings: [:])
        try h.move("a", toPage: 0, x: 3, y: 0)
        try h.save()
        let back = try XCTUnwrap(Database.shared.kv(KVKey.layout)?.object)
        XCTAssertEqual(back["keepMe"]?.string, "x")
        XCTAssertEqual(back["pages"]?.array?.first?["webOnly"]?.bool, true)
    }

    /// 同样大小的对调；跨页对调各搬到对方那一页；挡路的就近让开
    func testMoveSwapAndDisplace() throws {
        try seed()
        var h = try HomeLayout.begin(settings: [:])
        try h.move("a", toPage: 0, x: 1, y: 0)
        XCTAssertEqual(at(h, "a")?.1, 1)
        XCTAssertEqual(at(h, "b")?.1, 0)
        try h.move("a", toPage: 1, x: 0, y: 0)
        XCTAssertEqual(at(h, "a")?.0, 1)
        XCTAssertEqual(at(h, "c")?.0, 0)
        // 1x1 落在 2x1 小组件上：小组件让开，不重叠
        try h.move("c", toPage: 0, x: 0, y: 1)
        let w = try XCTUnwrap(h.locate("w"))
        XCTAssertFalse(HomeLayout.y(w.cell) == 1 && HomeLayout.x(w.cell) == 0, "被挤走")
        XCTAssertEqual(at(h, "c")?.1, 0)
        XCTAssertEqual(at(h, "c")?.2, 1)
    }

    /// 底栏与网格互换；底栏放不下小组件
    func testDock() throws {
        try seed()
        var h = try HomeLayout.begin(settings: [:])
        try h.move(.cell("b"), to: .dock(1))
        XCTAssertEqual(h.dock[1], "diary")
        XCTAssertNil(h.locate("b"))
        try h.move(.dock(0), to: .cell("a"))
        XCTAssertEqual(h.dock[0], "chat")
        XCTAssertEqual(h.locate("a").map { HomeLayout.ref($0.cell) }, "settings")
        XCTAssertThrowsError(try h.move(.cell("w"), to: .dock(2)))
        try h.move(.dock(1), to: .slot(page: 1, x: 2, y: 2))
        XCTAssertNil(h.dock[1])
    }

    /// 移除的记下来，自愈不摆回来；放回之后有位置
    func testRemoveAndRestore() throws {
        try seed()
        var h = try HomeLayout.begin(settings: [:])
        h.remove("b")
        h.heal()
        XCTAssertTrue(h.removedApps.contains("diary"))
        XCTAssertFalse(h.pages.flatMap { h.cells($0) }.contains { HomeLayout.ref($0) == "diary" })
        h.restore("diary")
        XCTAssertFalse(h.removedApps.contains("diary"))
        XCTAssertTrue(h.pages.flatMap { h.cells($0) }.contains { HomeLayout.ref($0) == "diary" })
    }

    /// 文件夹：建的时候把应用从原处摘下；取出来回到主屏；装空了就去掉
    func testFolder() throws {
        try seed()
        var h = try HomeLayout.begin(settings: [:])
        try h.newFolder(page: 0, x: 3, y: 0, apps: ["chat", "music"], name: "常用")
        XCTAssertNil(h.locate("a"))
        XCTAssertNil(h.locate("c"))
        let f = try XCTUnwrap(h.folders.first)
        XCTAssertEqual(HomeLayout.apps(f), ["chat", "music"])
        try h.takeOut(HomeLayout.id(f), app: "music")
        XCTAssertTrue(h.pages.flatMap { h.cells($0) }.contains { HomeLayout.kind($0) == "app" && HomeLayout.ref($0) == "music" })
        try h.setFolder(HomeLayout.id(f), name: "常用", apps: [])
        XCTAssertTrue(h.folders.isEmpty)
    }

    /// 放东西：挡路的挪走；空页才能删，第一页不删
    func testPlaceAndPages() throws {
        try seed()
        var h = try HomeLayout.begin(settings: [:])
        try h.place(page: 0, x: 0, y: 0, ["kind": .string("widget"), "ref": .string("photo"), "w": .number(2), "h": .number(2)])
        XCTAssertNotNil(h.locate("a"), "被挤走的还在")
        XCTAssertNotNil(h.locate("b"))
        let n = h.addPage()
        XCTAssertTrue(h.removePage(n))
        XCTAssertFalse(h.removePage(0))
        XCTAssertFalse(h.removePage(1), "有东西的页不删")
    }
}
