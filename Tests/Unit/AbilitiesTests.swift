import XCTest
@testable import Eira

/// 角色能力页（网页版 AbilitiesPage、capnote.blockerOf，ARCHITECTURE 4.646、4.485）：
/// 开着却不会生效时写明原因；页头列出全局关掉的与尚未开启的新功能；菜单上的「已开启 N 项」。
final class AbilitiesTests: XCTestCase {
    private func voice(enabled: Bool = true) -> JSONValue {
        .object(["enabled": .bool(enabled), "activeId": .string("v1"), "presets": .array([.object([
            "id": .string("v1"), "name": .string("测试"), "kind": .string("minimax"), "baseUrl": .string("https://tts.test"),
            "apiKey": .string("k"), "model": .string("speech-02-hd")])])])
    }

    private func char(_ fields: [String: JSONValue] = [:]) -> Character {
        Character(row: Row.new(prefix: "char", fields))
    }

    func testGlobalOffComesFirst() {
        let s = AppSettings(raw: ["capsOff": .array([.string("voice"), .string("transfer")])])
        XCTAssertEqual(Abilities.blocker("voice", char: char(), s), "已在「设定集 - 能力开关」中关闭，此处开启不会生效")
        XCTAssertEqual(Abilities.blocker("transfer", char: char(), s), "已在「设定集 - 能力开关」中关闭，此处开启不会生效")
        XCTAssertEqual(Abilities.blocker("gift", char: char(), s), "")
    }

    func testImageNeedsApi() {
        let s = AppSettings(raw: [:])
        XCTAssertEqual(Abilities.blocker("image", char: char(), s), "尚未配置生图接口，配置后生效")
    }

    func testVoiceNeedsApiThenVoiceId() {
        let none = AppSettings(raw: [:])
        XCTAssertEqual(Abilities.blocker("voice", char: char(), none), "尚未配置语音接口，配置后生效")
        // 配好了但总开关关着，同样算未配置
        let disabled = AppSettings(raw: ["services": .object(["voice": voice(enabled: false)])])
        XCTAssertEqual(Abilities.blocker("voice", char: char(), disabled), "尚未配置语音接口，配置后生效")

        let s = AppSettings(raw: ["services": .object(["voice": voice()])])
        XCTAssertEqual(Abilities.blocker("voice", char: char(), s), "当前语音接口上尚未填写这个角色的音色，填写后生效")
        // 音色填在别的接口上不算
        XCTAssertEqual(Abilities.blocker("voice", char: char(["voiceIds": .object(["v2": .string("x")])]), s),
                       "当前语音接口上尚未填写这个角色的音色，填写后生效")
        XCTAssertEqual(Abilities.blocker("voice", char: char(["voiceIds": .object(["v1": .string("female-1")])]), s), "")
    }

    /// 原生版直连网易云，曲库空着也能点歌，一起听不因曲库为空被挡
    func testListenNotBlockedByEmptyLibrary() {
        XCTAssertEqual(Abilities.blocker("listen", char: char(), AppSettings(raw: [:])), "")
    }

    func testHeaderLists() {
        let s = AppSettings(raw: ["capsOff": .array([.string("voice"), .string("video"), .string("dice")])])
        // 只列这一页上有的能力
        XCTAssertEqual(Abilities.shut(s), ["语音", "骰子"])
        XCTAssertEqual(Abilities.shut(AppSettings(raw: [:])), [])
        // 新功能没问过就是没开
        XCTAssertEqual(Abilities.fresh(AppSettings(raw: [:])), NewFeat.features.map(\.label))
        var on = AppSettings(raw: [:])
        for f in NewFeat.features { NewFeat.set(f.id, true, &on) }
        XCTAssertEqual(Abilities.fresh(on), [])
    }

    func testCount() {
        XCTAssertEqual(Abilities.countLabel(nil), "")
        // 不回复默认关，其余默认开
        XCTAssertEqual(Abilities.countLabel(char()), "已开启 \(Abilities.items.count - 1) 项")
        XCTAssertEqual(Abilities.countLabel(char(["canSendVoice": .bool(false), "canSilence": .bool(true)])),
                       "已开启 \(Abilities.items.count - 1) 项")
        XCTAssertEqual(Abilities.countLabel(char(["canSendVoice": .bool(false)])), "已开启 \(Abilities.items.count - 2) 项")
        XCTAssertFalse(Abilities.isOn("canSilence", char()))
        XCTAssertTrue(Abilities.isOn("canSendImage", char()))
        XCTAssertFalse(Abilities.isOn("noSuchKey", char()))
    }

    /// 每一项的能力 id 都是全局能力开关认得的，否则「已在全局关闭」永远对不上
    func testCapsKnownToGlobalSwitch() {
        let global = Set(CapsView.caps.map(\.id))
        for it in Abilities.items { XCTAssertTrue(global.contains(it.cap), it.cap) }
    }
}
