import XCTest
@testable import Eira

/// 改主屏：换壁纸只动 wallpaper.home，版式其余原样；没存过版式时按默认起一份；
/// 图标与名字写进 settings.appIcons，清空的一项回到默认，100% 不写
final class HomeEditTests: StoreTestCase {
    func testWallpaperOnFreshInstallStartsFromDefault() throws {
        XCTAssertNil(try Database.shared.kv(KVKey.layout))
        try HomeEdit.setWallpaper("img_a")
        let l = Shell.layout()
        XCTAssertEqual(l.wallpaperHome, "img_a")
        XCTAssertEqual(l.pages.count, Shell.parse(Shell.defaultLayout).pages.count)
        try HomeEdit.setWallpaper(nil)
        XCTAssertEqual(Shell.layout().wallpaperHome, "")
    }

    func testWallpaperKeepsOtherLayoutFields() throws {
        try Database.shared.setKV(KVKey.layout, .object([
            "pages": .array([.object(["id": .string("p9"), "cells": .array([])])]),
            "dock": .array([.string("chat")]),
            "wallpaper": .object(["home": .null, "lock": .string("img_lock")]),
            "extra": .string("留着"),
        ]))
        try HomeEdit.setWallpaper("img_b")
        let raw = try XCTUnwrap(Database.shared.kv(KVKey.layout)?.object)
        XCTAssertEqual(raw["extra"]?.string, "留着")
        XCTAssertEqual(raw["wallpaper"]?.object?["lock"]?.string, "img_lock")
        XCTAssertEqual(raw["wallpaper"]?.object?["home"]?.string, "img_b")
        XCTAssertEqual(Shell.layout().pages.first?.id, "p9")
    }

    func testIconPatchAndReset() throws {
        var s = AppSettings(raw: [:])
        HomeEdit.patchIcon(&s, "chat", ["name": .string("消息"), "imageId": .string("img_x"), "scale": HomeEdit.scaleValue(130),
                                        "label": .string("hide")])
        var look = try XCTUnwrap(Shell.look("chat", settings: s.raw))
        XCTAssertEqual(look.name, "消息")
        XCTAssertEqual(look.imageId, "img_x")
        XCTAssertEqual(look.scale, 130)
        XCTAssertEqual(look.label, "hide")
        HomeEdit.patchIcon(&s, "chat", ["name": .string(""), "scale": HomeEdit.scaleValue(100), "label": .string("bogus")])
        look = try XCTUnwrap(Shell.look("chat", settings: s.raw))
        XCTAssertEqual(look.name, "聊天")
        XCTAssertEqual(look.scale, 0)
        XCTAssertEqual(look.label, "")
        XCTAssertEqual(HomeEdit.scaleValue(500)?.number, 160)
        HomeEdit.resetIcon(&s, "chat")
        XCTAssertNil(s.raw["appIcons"]?.object?["chat"])
    }
}
