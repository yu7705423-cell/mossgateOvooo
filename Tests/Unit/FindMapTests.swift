import XCTest
@testable import Eira

/// 找功能（网页版 findmap 测试，4.646）：表里每一项都有页可去；按词、按整句都找得到；会话菜单里不重复列挂在对话上的那几项。
final class FindMapTests: XCTestCase {
    func testEveryEntryHasAPage() {
        var seen = Set<String>()
        for e in FindMap.entries {
            XCTAssertTrue(seen.insert(e.t).inserted, "重名：\(e.t)")
            XCTAssertFalse(e.at.isEmpty, e.t)
            XCTAssertFalse(e.k.isEmpty, e.t)
            if e.dest.isEmpty { continue }
            XCTAssertTrue(FindPlaceView.known.contains(e.dest), "画不出来：\(e.dest)")
            // 挂在对话上的那几页要先选对话；不挂的不能落到要对话的页上
            XCTAssertEqual(e.per != .global, FindPlaceView.perChat.contains(e.dest), e.t)
        }
        XCTAssertTrue(FindPlaceView.perChat.isSubset(of: FindPlaceView.known))
    }

    func testFind() {
        XCTAssertTrue(FindMap.find("").isEmpty)
        XCTAssertTrue(FindMap.find("   ").isEmpty)
        XCTAssertEqual(FindMap.find("备份").first?.t, "存储与备份")
        XCTAssertEqual(FindMap.find("API").first?.t, "主用接口")
        // 打一整句：句子里含着表里的某个词也算
        XCTAssertEqual(FindMap.find("接口密钥").first?.t, "主用接口")
        XCTAssertEqual(FindMap.find("怎么让角色发语音").first?.t, "角色能力")
        XCTAssertEqual(FindMap.find("隔夜").first?.t, "记忆总结")
        XCTAssertTrue(FindMap.find("锁屏密码").contains { $0.t == "锁屏密码" })
        XCTAssertTrue(FindMap.find("一个不存在的词组合xyz").isEmpty)
    }

    func testScopes() {
        // 会话菜单里只给不挂在对话上的
        XCTAssertTrue(FindMap.find("翻译", scope: "chat").allSatisfy { $0.per == .global })
        XCTAssertTrue(FindMap.find("翻译", scope: "chat").contains { $0.t == "翻译接口" })
        // 群聊：只在单聊里有的不列
        XCTAssertFalse(FindMap.find("状态栏", group: true).contains { $0.t == "状态栏" })
        XCTAssertTrue(FindMap.find("心声", group: true).contains { $0.t == "心声" })
    }

    func testTermsText() {
        XCTAssertEqual(TermsView.title, "Eira 使用须知")
        XCTAssertEqual(TermsView.sections.count, 8)
        XCTAssertTrue(TermsView.sections.allSatisfy { !$0.body.isEmpty })
        XCTAssertTrue(FindMap.find("使用须知").first?.dest == "terms")
    }
}

/// 回应样式（网页版 4.474）：默认线条；八个有画法；少写变体选择符也认；emoji 那一档一律不换。源码里不写 emoji，从码点生成。
final class ReactLookTests: XCTestCase {
    private func cp(_ codes: UInt32...) -> String {
        String(String.UnicodeScalarView(codes.compactMap { Unicode.Scalar($0) }))
    }

    func testStyleAndDrawn() {
        var s = AppSettings.load()
        s.raw["reactStyle"] = nil
        XCTAssertEqual(ReactLook.style(s), ReactLook.line)
        s.raw["reactStyle"] = .string("emoji")
        XCTAssertEqual(ReactLook.style(s), ReactLook.emoji)
        s.raw["reactStyle"] = .string("line")
        XCTAssertEqual(ReactLook.style(s), ReactLook.line)

        XCTAssertEqual(ReactLook.drawn.count, 8)
        XCTAssertEqual(ReactLook.iconOf(cp(0x2764, 0xFE0F), style: "line"), "reactHeart")
        XCTAssertEqual(ReactLook.iconOf(cp(0x2764), style: "line"), "reactHeart")
        XCTAssertEqual(ReactLook.iconOf(cp(0x203C), style: "line"), "reactBang")
        XCTAssertEqual(ReactLook.iconOf(cp(0x1F622), style: "line"), "reactCry")
        XCTAssertEqual(ReactLook.iconOf(cp(0x2764, 0xFE0F), style: "emoji"), "")
        // 没有画法的照旧显示 emoji
        XCTAssertEqual(ReactLook.iconOf(cp(0x1F64F), style: "line"), "")
        // 图标都在 shell.json 里
        for d in ReactLook.drawn { XCTAssertNotNil(Shell.icons[d.icon], d.icon) }
    }
}

/// 选小组件（网页版 4.592）：分组标签按装饰、仿界面、基础、ins 风；每个组件都落在一组里；宽的排前面；卡片不漏尺寸。
final class WidgetPickTests: XCTestCase {
    func testGroupsAndCards() {
        let ids = HomeWidgets.groups.map(\.id)
        XCTAssertEqual(ids, ["decor", "mimic", "base", "ins"])
        XCTAssertEqual(WidgetPickerView.tabs.map(\.id), ids.filter { g in HomeWidgets.all.contains { $0.group == g } })
        for d in HomeWidgets.all { XCTAssertTrue(ids.contains(d.group), d.id) }
        XCTAssertEqual(HomeWidgets.group(of: "dw-moon"), "decor")
        XCTAssertEqual(HomeWidgets.group(of: "ins-profile"), "decor")
        XCTAssertEqual(HomeWidgets.group(of: "mm-post"), "mimic")
        XCTAssertEqual(HomeWidgets.group(of: "ins-polaroid"), "ins")
        XCTAssertEqual(HomeWidgets.group(of: "note"), "base")
        XCTAssertFalse(HomeWidgets.def("dw-moon")?.desc.isEmpty ?? true)

        var total = 0
        for g in ids {
            let cards = WidgetPickerView.cards(in: g)
            total += cards.count
            let ratios = cards.map { Double($0.w) / Double($0.h) }
            XCTAssertEqual(ratios, ratios.sorted(by: >), g)
        }
        XCTAssertEqual(total, HomeWidgets.all.reduce(0) { $0 + $1.sizes.count })
    }
}
