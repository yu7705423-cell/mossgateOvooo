import Foundation

/// 会话加号面板的格子（网页版 system/panel.js）。
///
/// 格子多了一屏放不下，分两层：常用的留在面板上，其余收进「更多」。哪些留在面板上、按什么顺序由用户自己定，代码只给默认。
/// 顺序（settings.panelOrder）与「在不在更多里」（settings.panelMore）分开存，和网页版同两个键：挪进挪出都不动顺序。
/// 原生版还没有的格子（一起看、申请……）不列；网页版存下的顺序里有它们也不碍事，读的时候跳过。
enum Panel {
    struct Item: Identifiable, Equatable {
        let id: String
        let icon: String
        let label: String
    }

    static let items: [Item] = [
        Item(id: "lore", icon: "book", label: "世界书"),
        Item(id: "photo", icon: "image", label: "图片"),
        Item(id: "voice", icon: "mic", label: "语音"),
        Item(id: "transfer", icon: "wallet", label: "转账"),
        Item(id: "call", icon: "phone", label: "通话"),
        Item(id: "video", icon: "film", label: "视频通话"),
        Item(id: "gift", icon: "gift", label: "礼物"),
        Item(id: "location", icon: "map", label: "位置"),
        Item(id: "listen", icon: "headphone", label: "一起听"),
        Item(id: "song", icon: "music", label: "分享音乐"),
        Item(id: "takeout", icon: "bag", label: "外卖"),
        Item(id: "pat", icon: "paw", label: "拍一拍"),
        Item(id: "share", icon: "compass", label: "共享位置"),
        Item(id: "dice", icon: "grid", label: "骰子"),
        Item(id: "offline", icon: "book", label: "线下"),
        Item(id: "file", icon: "folder", label: "文件"),
        Item(id: "card", icon: "layers", label: "卡片"),
    ]

    private static let all = items.map(\.id)
    /// 默认收进「更多」的：网页版 DEFAULT_MORE 里原生版也有的那几格
    static let defaultMore = ["lore", "video", "share", "dice", "card", "file"]
    /// 群里说得通的那几格（网页版 GROUP_TAPS）：转账、礼物、通话这些都是对着一个人的
    static let groupOK: Set<String> = ["photo", "voice", "dice", "song", "offline"]

    static func item(_ id: String) -> Item? { items.first { $0.id == id } }

    /// 读出一份干净的顺序：丢掉不认识的，补上缺的（世界书补在最前）
    static func order(_ s: AppSettings) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in (s.raw["panelOrder"]?.array ?? []).compactMap(\.string) where all.contains(id) && seen.insert(id).inserted { out.append(id) }
        for id in all where seen.insert(id).inserted {
            if id == "lore" { out.insert(id, at: 0) } else { out.append(id) }
        }
        return out
    }

    /// 从来没设过才用默认。设成空数组是「全都放面板上」
    static func more(_ s: AppSettings) -> Set<String> {
        guard let raw = s.raw["panelMore"]?.array else { return Set(defaultMore) }
        return Set(raw.compactMap(\.string).filter { all.contains($0) })
    }

    static func visible(_ id: String, group: Bool) -> Bool { !group || groupOK.contains(id) }

    static func onPanel(_ s: AppSettings, group: Bool) -> [String] {
        let m = more(s)
        return order(s).filter { !m.contains($0) && visible($0, group: group) }
    }

    static func inMore(_ s: AppSettings, group: Bool) -> [String] {
        let m = more(s)
        return order(s).filter { m.contains($0) && visible($0, group: group) }
    }

    /// 写回去时保留网页版存着的、原生版不认识的那几格，网页版那边的顺序不受影响
    private static func keepUnknown(_ s: AppSettings, _ key: String) -> [String] {
        (s.raw[key]?.array ?? []).compactMap(\.string).filter { !all.contains($0) }
    }

    static func setMore(_ s: inout AppSettings, _ id: String, _ yes: Bool) {
        var m = more(s)
        if yes { m.insert(id) } else { m.remove(id) }
        let mine = order(s).filter { m.contains($0) }
        s.raw["panelMore"] = .array((mine + keepUnknown(s, "panelMore")).map { .string($0) })
    }

    /// 往上或往下挪一格（dir 为 -1 或 1）
    static func move(_ s: inout AppSettings, _ id: String, _ dir: Int) {
        var list = order(s)
        guard let i = list.firstIndex(of: id) else { return }
        let j = i + (dir < 0 ? -1 : 1)
        guard j >= 0, j < list.count else { return }
        list.swapAt(i, j)
        s.raw["panelOrder"] = .array((list + keepUnknown(s, "panelOrder")).map { .string($0) })
    }

    static func reset(_ s: inout AppSettings) {
        s.raw["panelOrder"] = .array(all.map { .string($0) })
        s.raw["panelMore"] = .array(defaultMore.map { .string($0) })
    }
}
