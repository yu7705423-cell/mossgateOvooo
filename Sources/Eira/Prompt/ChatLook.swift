import Foundation

/// 聊天背景与上下栏（网页版 system/chatlook.js，ARCHITECTURE 4.198）。
///
/// 这一段会话自己的设置，不是美化包：存在会话记录上（chat.look），换一段不影响另一段。字段与网页版一字不差，
/// 导入的会话照用，导出给网页版也读得回。
///
///     look: { bg, veil, split, top: Bar, bottom: Bar, narr }
///     Bar:  { style: solid | clear | glass, color: '' | '#rrggbb', alpha: 不透明度, blur, fg: '' | light | dark }
///
/// 界面上写「透明度」，存的是不透明度（alpha），两者相加为 100。没设过的那一栏就是应用本来的样子。
enum ChatLook {
    static let styles: [(id: String, label: String)] = [("solid", "实色"), ("clear", "半透明"), ("glass", "毛玻璃")]
    static let fgs: [(id: String, label: String)] = [("", "跟随主题"), ("light", "浅色"), ("dark", "深色")]
    /// 预设几种低饱和的底色（网页版 COLORS）。空串是「跟随主题」
    static let colors = ["", "#FFFFFF", "#F2F2F7", "#E9E4DA", "#DCE4EA", "#E4DCE6", "#DDE6DA",
                         "#8E8E93", "#3A3A3C", "#1C1C1E", "#000000"]

    struct Bar: Equatable {
        var style = "solid"
        var color = ""
        var alpha = 70
        var blur = 20
        var fg = ""

        /// 这一栏动过没有。实色、跟随主题、跟随字色就是应用本来的样子
        var isSet: Bool { style != "solid" || !color.isEmpty || !fg.isEmpty }

        var json: JSONValue {
            .object(["style": .string(style), "color": .string(color), "alpha": .number(Double(alpha)),
                     "blur": .number(Double(blur)), "fg": .string(fg)])
        }
    }

    struct Look: Equatable {
        var bg = ""
        var veil = 0
        var split = false
        var top = Bar()
        var bottom = Bar()
        var narr = ""

        var isSet: Bool { !bg.isEmpty || top.isSet || bottom.isSet || !narr.isEmpty }
    }

    private static func isHex(_ s: String) -> Bool {
        s.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }

    private static func clamp(_ v: JSONValue?, _ lo: Int, _ hi: Int, _ d: Int) -> Int {
        guard let n = v?.number, n.isFinite else { return d }
        return min(hi, max(lo, Int(n.rounded())))
    }

    static func bar(_ raw: JSONValue?) -> Bar {
        let o = raw?.object ?? [:]
        var b = Bar()
        if let s = o["style"]?.string, styles.contains(where: { $0.id == s }) { b.style = s }
        if let c = o["color"]?.string, c.isEmpty || isHex(c) { b.color = c }
        b.alpha = clamp(o["alpha"], 0, 100, 70)
        b.blur = clamp(o["blur"], 0, 40, 20)
        if let f = o["fg"]?.string, fgs.contains(where: { $0.id == f }) { b.fg = f }
        return b
    }

    /// 一段会话的设置，缺的项补默认值。上下没分开时 bottom 就是 top
    static func of(_ chat: Chat) -> Look {
        let l = chat.row["look"]?.object ?? [:]
        var out = Look()
        out.bg = l["bg"]?.string ?? ""
        out.veil = clamp(l["veil"], 0, 90, 0)
        out.split = l["split"]?.bool == true
        out.top = bar(l["top"])
        out.bottom = out.split ? bar(l["bottom"]) : out.top
        if let n = l["narr"]?.string, isHex(n) { out.narr = n }
        return out
    }

    /// 改一部分。top / bottom 按项合并；刚分开时，下面那一栏从上面那一栏抄一份起步
    static func set(_ chatId: String, _ patch: [String: JSONValue]) throws {
        guard var c = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
        var cur = c.row["look"]?.object ?? [:]
        let wasSplit = cur["split"]?.bool == true
        for (k, v) in patch {
            if (k == "top" || k == "bottom"), case .object(let p) = v {
                var b = cur[k]?.object ?? [:]
                for (kk, vv) in p { b[kk] = vv }
                cur[k] = .object(b)
            } else {
                cur[k] = v
            }
        }
        if patch["split"]?.bool == true && !wasSplit && cur["bottom"] == nil {
            cur["bottom"] = cur["top"] ?? Bar().json
        }
        c.row["look"] = .object(cur)
        c.row.touch()
        try Repo.save(c)
    }

    /// 换背景图。旧图不删：可能还有别的会话或相册在用，原生版尚无引用表，宁可留着
    static func setBg(_ chatId: String, imageId: String) throws {
        try set(chatId, ["bg": .string(imageId)])
    }

    /// 全部恢复默认
    static func reset(_ chatId: String) throws {
        guard var c = try Repo.chat(chatId) else { return }
        c.row["look"] = .null
        c.row.touch()
        try Repo.save(c)
    }

    /// 把这一段的设置照搬到其余全部会话（群聊在内）。背景图共用同一个 id。回改了几段
    @discardableResult
    static func applyToAll(_ chatId: String) throws -> Int {
        guard let src = try Repo.chat(chatId) else { return 0 }
        let look = src.row["look"] ?? .null
        var n = 0
        for var c in try Repo.chats() where c.id != chatId {
            c.row["look"] = look
            c.row.touch()
            try Repo.save(c)
            n += 1
        }
        return n
    }
}
