import XCTest
import UIKit
@testable import Eira

/// 配色、模型列表、外观预设、底栏开关
final class AppearanceTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(MockNet.self)
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(MockNet.self)
        Palette.apply(nil)
        try super.tearDownWithError()
    }

    private func hex(_ c: UIColor?) -> String {
        guard let c else { return "" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// 黑白不盖令牌；选了一套就盖上；自定义缺的从雾蓝补；主色上的字按对比度选黑白
    func testPalette() {
        Palette.apply(.object(["id": .string("mono")]))
        XCTAssertNil(Palette.color("bg", dark: false))
        Palette.apply(.object(["id": .string("sage")]))
        XCTAssertEqual(hex(Palette.color("bg", dark: false)), "#F3F5F1")
        XCTAssertEqual(hex(Palette.color("accent", dark: true)), "#9DB8A2")
        XCTAssertEqual(hex(Palette.color("on-accent", dark: true)), "#000000", "深色那几套主色偏浅，用黑字")
        Palette.apply(.object(["id": .string("custom"), "custom": .object(["light": .object(["accent": .string("#112233")])])]))
        XCTAssertEqual(hex(Palette.color("accent", dark: false)), "#112233")
        XCTAssertEqual(hex(Palette.color("bg", dark: false)), "#F3F5F8")
        XCTAssertEqual(hex(Palette.color("on-accent", dark: false)), "#FFFFFF")
    }

    /// 拉模型列表：路径与头按各家写法；读一份列表不记请求次数；失败给出原因；搜索按包含与子序列
    func testModelList() async throws {
        MockNet.reset { _, _ in .init(status: 200, body: #"{"data":[{"id":"claude-b"},{"id":"claude-a"}]}"#) }
        let list = try await ModelList.fetch(provider: "anthropic", baseUrl: "https://relay.test/", apiKey: "k")
        XCTAssertEqual(list, ["claude-b", "claude-a"])
        XCTAssertEqual(MockNet.requests.first?.url?.absoluteString, "https://relay.test/v1/models?limit=200")
        XCTAssertEqual(MockNet.requests.first?.value(forHTTPHeaderField: "x-api-key"), "k")

        MockNet.reset { _, _ in .init(status: 200, body: #"{"data":[{"id":"gpt-x"}]}"#) }
        _ = try await ModelList.fetch(provider: "openai", baseUrl: "https://relay.test/v1", apiKey: "k")
        XCTAssertEqual(MockNet.requests.first?.url?.absoluteString, "https://relay.test/v1/models")

        MockNet.reset { _, _ in .init(status: 401, body: #"{"error":{"message":"bad key"}}"#) }
        do { _ = try await ModelList.fetch(provider: "openai", baseUrl: "", apiKey: "k"); XCTFail("应当报错") }
        catch { XCTAssertTrue(error.localizedDescription.contains("bad key")) }

        XCTAssertEqual(ModelList.filter(["gpt-4o", "claude-sonnet", "o4-mini"], "o4"), ["o4-mini"])
        XCTAssertEqual(ModelList.filter(["claude-sonnet"], "csn"), ["claude-sonnet"])
    }

    /// 外观预设：存下外观字段与版式，不带接口；换上时缺的图当没设过
    func testLookPresets() throws {
        try setSettings(["palette": .object(["id": .string("latte")]), "homeCols": .number(5), "apiKeySecret": .string("x"),
                         "appIcons": .object(["chat": .object(["imageId": .string("img_gone")])])])
        try Database.shared.setKV(KVKey.layout, .object(["pages": .array([]), "wallpaper": .object(["home": .string("img_gone")])]))
        let row = try Looks.save(name: "一")
        XCTAssertNil(row["look"]?["apiKeySecret"])
        XCTAssertEqual(row["look"]?["homeCols"]?.number, 5)

        try setSettings(["homeCols": .number(4)])
        let missing = try Looks.apply(row.id) { _ in false }
        XCTAssertEqual(missing, 2)
        let s = AppSettings.load()
        XCTAssertEqual(s.raw["homeCols"]?.number, 5)
        XCTAssertEqual(s.raw["palette"]?["id"]?.string, "latte")
        let lay = try XCTUnwrap(Database.shared.kv(KVKey.layout))
        XCTAssertEqual(lay["wallpaper"]?["home"], .null)
        XCTAssertEqual(lay["dockHidden"]?.bool, false)
    }

    /// 关底栏：底栏的应用进网格；再开：收回底栏
    func testDockHidden() throws {
        try Database.shared.setKV(KVKey.layout, .object([
            "pages": .array([.object(["id": .string("p1"), "cells": .array([])])]),
            "dock": .array([.string("chat"), .null, .null, .null]),
        ]))
        var h = try HomeLayout.begin(settings: [:])
        h.setDockHidden(true)
        XCTAssertTrue(h.pages.flatMap { h.cells($0) }.contains { HomeLayout.ref($0) == "chat" })
        h.setDockHidden(false)
        XCTAssertEqual(h.dock[0], "chat")
        XCTAssertFalse(h.pages.flatMap { h.cells($0) }.contains { HomeLayout.ref($0) == "chat" })
    }
}
