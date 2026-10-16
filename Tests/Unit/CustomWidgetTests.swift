import XCTest
@testable import Eira

/// 主屏的自定义组件（网页版 widgets.js 的 custom、system/sandbox.js）：整页最前面是 CSP，桥带着这一格的 id；
/// 太大的不收；盒子里发出来的消息只认这一格、只认 JSON 对象；存进去的是网页版那几个键。
final class CustomWidgetTests: StoreTestCase {
    private func cell(_ id: String, config: [String: JSONValue] = [:]) -> Shell.Cell {
        Shell.Cell(id: id, kind: "widget", ref: CustomWidget.id, x: 0, y: 0, w: 4, h: 2, name: "", apps: [],
                   label: "", coverIcon: "", coverImageId: "", config: config)
    }

    // MARK: - 盒子

    func testDocumentStartsWithCspAndCarriesBridge() throws {
        let c = cell("cell-1", config: ["state": .object(["n": .number(3), "s": .string("</script><b>")])])
        let doc = CustomWidget.document("\u{FEFF}<!doctype html><html><body>hi</body></html>", cell: c, fit: "fit",
                                        vars: CustomWidget.themeVars(dark: false), scheme: "light")
        XCTAssertTrue(doc.hasPrefix("<!DOCTYPE html><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "), "CSP 在最前面")
        XCTAssertTrue(doc.contains("connect-src 'none'"))
        XCTAssertTrue(doc.contains("frame-src 'none'"))
        XCTAssertTrue(doc.contains("img-src data: blob: https:"), "主屏组件放开 https 图片")
        XCTAssertTrue(doc.contains("var ID=\"cell-1\""), "桥带着这一格的 id")
        XCTAssertTrue(doc.contains("window.webkit.messageHandlers.eiraWidget.postMessage"))
        XCTAssertTrue(doc.contains("'data-size',\"4x2\""))
        XCTAssertTrue(doc.contains("\"n\":3"), "存过的数据交进去")
        XCTAssertFalse(doc.contains("</script><b>"), "数据里的 </script> 截不断桥")
        XCTAssertTrue(doc.contains("html{overflow:hidden}"))
        // 它自己的 doctype 拿掉，我们的在最前；它的代码在桥之后
        let csp = try XCTUnwrap(doc.range(of: "Content-Security-Policy"))
        let script = try XCTUnwrap(doc.range(of: "<script>"))
        let body = try XCTUnwrap(doc.range(of: "<html><body>hi"))
        XCTAssertTrue(csp.lowerBound < script.lowerBound && script.lowerBound < body.lowerBound)
        XCTAssertEqual(doc.components(separatedBy: "<!doctype html>").count, 1)
        // 不交出按压转发与别的接口
        XCTAssertFalse(doc.contains("eiraHeld"))

        let cellDoc = CustomWidget.document("<p>x</p>", cell: cell("c2"), fit: "cell", vars: "", scheme: "dark")
        XCTAssertFalse(cellDoc.contains("html{overflow:hidden}"), "按格子大小时不缩放")
        XCTAssertTrue(cellDoc.contains("S={}"))
        XCTAssertTrue(cellDoc.contains("'data-scheme',\"dark\""))
    }

    func testThemeVarsCoverWebNames() {
        let v = CustomWidget.themeVars(dark: true)
        for name in CustomWidget.vars { XCTAssertTrue(v.contains(name + ":"), name) }
    }

    func testNavigationOnlyWithinTheDocument() {
        let blank = URL(string: "about:blank")
        XCTAssertTrue(CustomWidget.sameDocument(URL(string: "about:blank#top"), from: blank))
        XCTAssertFalse(CustomWidget.sameDocument(URL(string: "https://example.com/#x"), from: blank))
        XCTAssertFalse(CustomWidget.sameDocument(URL(string: "about:blank"), from: blank), "重新载入算跳走")
    }

    // MARK: - 大小

    func testOversizeRejected() {
        let max = CustomWidget.maxBytes
        XCTAssertEqual(CustomWidget.check(Data(repeating: 0x61, count: max + 1), paste: false), "文件太大，上限 512 KB")
        XCTAssertEqual(CustomWidget.check(Data(repeating: 0x61, count: max + 1), paste: true), "代码太长，上限 512 KB")
        XCTAssertNil(CustomWidget.check(Data(repeating: 0x61, count: max), paste: true))
        XCTAssertEqual(CustomWidget.check(Data("  \n".utf8), paste: true), "代码为空")
        XCTAssertThrowsError(try CustomWidget.saveHtml(Data(repeating: 0x61, count: max + 1), name: "a.html", paste: false))
    }

    // MARK: - 消息

    func testStateMessages() {
        let ok: [String: Any] = ["eiraWidget": "c1", "t": "state", "data": "{\"a\":1}"]
        XCTAssertEqual(CustomWidget.accept(ok, cellId: "c1", mainFrame: true), .state(.object(["a": .number(1)])))
        XCTAssertNil(CustomWidget.accept(ok, cellId: "c2", mainFrame: true), "别的格子")
        XCTAssertNil(CustomWidget.accept(ok, cellId: "c1", mainFrame: false), "子页面")
        XCTAssertNil(CustomWidget.accept(ok, cellId: "", mainFrame: true))
        XCTAssertNil(CustomWidget.accept(["eiraWidget": "c1", "t": "state", "data": "[1,2]"], cellId: "c1", mainFrame: true), "数组不收")
        XCTAssertNil(CustomWidget.accept(["eiraWidget": "c1", "t": "state", "data": "1"], cellId: "c1", mainFrame: true))
        XCTAssertNil(CustomWidget.accept(["eiraWidget": "c1", "t": "state", "data": "{bad"], cellId: "c1", mainFrame: true))
        XCTAssertNil(CustomWidget.accept(["eiraWidget": "c1", "t": "state", "data": ["a": 1]] as [String: Any], cellId: "c1", mainFrame: true), "data 必须是字符串")
        XCTAssertNil(CustomWidget.accept(["eiraWidget": "c1", "t": "down", "x": 1] as [String: Any], cellId: "c1", mainFrame: true), "按压不收")
        XCTAssertNil(CustomWidget.accept("state", cellId: "c1", mainFrame: true))

        let pad = String(repeating: "x", count: CustomWidget.stateMax)
        XCTAssertNil(CustomWidget.accept(["eiraWidget": "c1", "t": "state", "data": "{\"a\":\"\(pad)\"}"], cellId: "c1", mainFrame: true), "超过上限")
        let fits = "{\"a\":\"" + String(repeating: "x", count: CustomWidget.stateMax - 8) + "\"}"
        XCTAssertEqual(fits.utf16.count, CustomWidget.stateMax)
        XCTAssertNotNil(CustomWidget.accept(["eiraWidget": "c1", "t": "state", "data": fits], cellId: "c1", mainFrame: true), "正好在上限")

        XCTAssertEqual(CustomWidget.accept(["eiraWidget": "c1", "t": "size", "w": 170.4, "h": 80] as [String: Any], cellId: "c1", mainFrame: true), .size(170, 80))
    }

    // MARK: - 存

    func testConfigKeysWritten() throws {
        try Database.shared.setKV(KVKey.layout, .object([
            "pages": .array([.object(["id": .string("p1"), "cells": .array([
                .object(["id": .string("w1"), "kind": .string("widget"), "ref": .string("custom"),
                         "x": .number(0), "y": .number(0), "w": .number(2), "h": .number(2), "keepMe": .bool(true)]),
            ])])]),
        ]))
        let html = "<p>hello</p>"
        let cfg = try CustomWidget.saveHtml(Data(html.utf8), name: "a.html", paste: true)
        XCTAssertTrue(CustomWidget.apply(settings: [:]) { $0.setConfig("w1", cfg) })
        XCTAssertTrue(CustomWidget.apply(settings: [:]) { $0.setConfig("w1", ["fit": .string("cell")]) })
        CustomWidget.saveState("w1", .object(["k": .string("v")]), settings: [:])

        let lay = try XCTUnwrap(Database.shared.kv(KVKey.layout))
        let c = try XCTUnwrap(lay["pages"]?[0]?["cells"]?[0]?.object)
        let conf = try XCTUnwrap(c["config"]?.object)
        let fid = try XCTUnwrap(conf["fileId"]?.string)
        XCTAssertFalse(fid.isEmpty)
        XCTAssertEqual(conf["name"]?.string, "a.html")
        XCTAssertEqual(conf["fit"]?.string, "cell")
        XCTAssertEqual(conf["state"], .object(["k": .string("v")]))
        XCTAssertEqual(c["keepMe"]?.bool, true, "不认得的字段原样留着")

        let url = try XCTUnwrap(MediaStore.url(.files, id: fid))
        XCTAssertEqual(url.pathExtension, "html")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), html)
        CustomWidget.htmlCache[fid] = nil
        XCTAssertEqual(CustomWidget.text(fid), html, "从文件读回")
    }

    func testRegistered() {
        XCTAssertTrue(MoreWidgets.has(CustomWidget.id))
        XCTAssertEqual(HomeWidgets.def(CustomWidget.id)?.label, "自定义组件")
        XCTAssertEqual(HomeWidgets.def(CustomWidget.id)?.sizes.count, 5)
        XCTAssertEqual(MoreWidgets.all.first(where: { $0.id == CustomWidget.id })?.framed, true)
    }
}
