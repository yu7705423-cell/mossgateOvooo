import XCTest
@testable import Eira

/// 加号面板：默认顺序与「更多」、挪动、群里只出现说得通的几格、网页版存下的格子不丢。
final class PanelTests: XCTestCase {
    func testDefaults() {
        let s = AppSettings(raw: [:])
        XCTAssertEqual(Panel.order(s).first, "lore")
        XCTAssertEqual(Panel.more(s), ["lore", "dice", "file", "share"])
        XCTAssertFalse(Panel.onPanel(s, group: false).contains("lore"))
        XCTAssertEqual(Set(Panel.onPanel(s, group: true)), ["photo", "voice", "song", "offline"])
    }

    func testMoveAndMoreKeepWebIds() {
        var s = AppSettings(raw: ["panelOrder": .array(["watch", "photo", "voice"].map { .string($0) }),
                                  "panelMore": .array(["request"].map { .string($0) })])
        XCTAssertEqual(Array(Panel.order(s).prefix(3)), ["lore", "photo", "voice"])
        XCTAssertTrue(Panel.more(s).isEmpty)
        Panel.move(&s, "voice", -1)
        XCTAssertEqual(Array(Panel.order(s).prefix(3)), ["lore", "voice", "photo"])
        XCTAssertTrue((s.raw["panelOrder"]?.array ?? []).contains(.string("watch")))
        Panel.setMore(&s, "photo", true)
        XCTAssertEqual(Panel.more(s), ["photo"])
        XCTAssertTrue((s.raw["panelMore"]?.array ?? []).contains(.string("request")))
        XCTAssertFalse(Panel.onPanel(s, group: false).contains("photo"))
    }
}
