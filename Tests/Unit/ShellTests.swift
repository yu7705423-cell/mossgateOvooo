import XCTest
@testable import Eira

/// 主屏：图标、app 列表、默认版式从网页版抄来；图标的 SVG 全部画得出来；
/// 导入的版式、壁纸、改过的图标与名字按网页版的读法读；没有存过版式时按默认画、不写回。
final class ShellTests: StoreTestCase {
    func testShellDataFromWeb() {
        XCTAssertEqual(Shell.apps.count, 32)
        XCTAssertEqual(Shell.app("chat")?.name, "聊天")
        XCTAssertEqual(Shell.app("chat")?.icon, "message")
        for a in Shell.apps { XCTAssertNotNil(Shell.icons[a.icon], "\(a.id) 的图标 \(a.icon) 不在图标表里") }
        let l = Shell.parse(Shell.defaultLayout)
        XCTAssertEqual(l.pages.count, 5)
        XCTAssertEqual(l.dock, ["chat", "todo", "album", "settings"])
        XCTAssertTrue(l.pages[0].cells.contains { $0.kind == "app" && $0.ref == "preset" })
    }

    func testEveryIconDraws() {
        let box = CGRect(x: -1, y: -1, width: 26, height: 26)
        for (name, svg) in Shell.icons {
            let parts = SvgShapes.parse(svg)
            XCTAssertFalse(parts.isEmpty, "\(name) 一笔都没有")
            for p in parts {
                let b = p.path.boundingBoxOfPath
                XCTAssertFalse(b.isNull, name)
                XCTAssertTrue(box.contains(b), "\(name) 画出了 24 格：\(b)")
            }
        }
    }

    func testCompactPathSyntax() {
        // 弧的两个标志位紧挨着下一个数（「012 2」= 0、1、2、2），以及「.5.5」这种连写
        let a = PathData.parse("M3 7a2 2 0 012-2h4").boundingBoxOfPath
        XCTAssertEqual(a.minX, 3, accuracy: 0.01)
        XCTAssertEqual(a.maxX, 9, accuracy: 0.01)
        XCTAssertEqual(a.minY, 5, accuracy: 0.01)
        XCTAssertEqual(a.maxY, 7, accuracy: 0.01)
        let b = PathData.parse("M1 1l.5.5-1.5 1.5").currentPoint
        XCTAssertEqual(b.x, 0, accuracy: 0.001)
        XCTAssertEqual(b.y, 3, accuracy: 0.001)
        let c = PathData.parse("M2 2h3v4H1V2z").boundingBoxOfPath
        XCTAssertEqual(c, CGRect(x: 1, y: 2, width: 4, height: 4))
    }

    func testRotatedRectAndFilledDot() {
        let parts = SvgShapes.parse(#"<rect x="3.5" y="5" width="11" height="15" rx="2" transform="rotate(-10 9 12.5)"/><circle cx="12" cy="12" r="1" fill="currentColor" stroke="none"/>"#)
        XCTAssertEqual(parts.count, 2)
        XCTAssertNotEqual(parts[0].path.boundingBoxOfPath.minX, 3.5, accuracy: 0.01)
        XCTAssertTrue(parts[1].fill)
        XCTAssertFalse(parts[1].stroke)
    }

    func testNoStoredLayoutUsesDefaultWithoutWriting() throws {
        let l = Shell.layout()
        XCTAssertEqual(l.pages.count, 5)
        XCTAssertNil(try Database.shared.kv(KVKey.layout))
    }

    func testStoredLayoutAndLooks() throws {
        try Database.shared.setKV(KVKey.layout, .object([
            "pages": .array([.object(["id": .string("p1"), "cells": .array([
                .object(["id": .string("a"), "kind": .string("app"), "ref": .string("music"),
                         "x": .number(1), "y": .number(2), "w": .number(1), "h": .number(1)]),
                .object(["id": .string("f"), "kind": .string("folder"), "name": .string("常用"),
                         "apps": .array([.string("diary"), .string("daily")]), "x": .number(0), "y": .number(0),
                         "w": .number(1), "h": .number(1)]),
            ])])]),
            "dock": .array([.string("chat"), .null, .string("settings")]),
            "wallpaper": .object(["home": .string("img_wall"), "lock": .null]),
        ]))
        let l = Shell.layout()
        XCTAssertEqual(l.pages.count, 1)
        XCTAssertEqual(l.pages[0].cells.first { $0.id == "a" }?.y, 2)
        XCTAssertEqual(l.pages[0].cells.first { $0.kind == "folder" }?.apps, ["diary", "daily"])
        XCTAssertEqual(l.dock, ["chat", nil, "settings", nil])
        XCTAssertEqual(l.wallpaperHome, "img_wall")

        let s: [String: JSONValue] = ["appIcons": .object(["chat": .object(["name": .string("消息"), "icon": .string("sms"),
                                                                             "label": .string("hide")])]),
                                      "iconLabelMode": .string("all")]
        let look = Shell.look("chat", settings: s)
        XCTAssertEqual(look?.name, "消息")
        XCTAssertEqual(look?.icon, "sms")
        XCTAssertFalse(Shell.showLabel(look?.label ?? "", settings: s))
        XCTAssertTrue(Shell.showLabel("", inDock: true, settings: s))
        XCTAssertFalse(Shell.showLabel("", inDock: true, settings: [:]))
        XCTAssertTrue(Shell.showLabel("", settings: [:]))
        XCTAssertFalse(Shell.showLabel("", settings: ["iconLabels": .bool(false)]))
        XCTAssertNil(Shell.look("nope", settings: s))
    }

    func testImportedBackupKeepsLayout() throws {
        try importFixture("data.json")
        let stored = try Database.shared.kv(KVKey.layout)
        let l = Shell.layout()
        if let stored { XCTAssertEqual(l, Shell.parse(stored)) } else { XCTAssertEqual(l.pages.count, 5) }
    }
}
