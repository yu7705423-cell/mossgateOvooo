import Foundation

/// 长按消息那一格一格的先后（网页版 system/menuorder.js，ARCHITECTURE 4.917）。
///
/// 存在 settings.msgMenuOrder，一串 id，和网页版同一个键、同一份 id：两边互相导入备份，排好的顺序照旧。
/// 读的时候丢掉不认识的、补上缺的（以后新加一格，老用户那边不会静默少一格）。恢复默认写成 null，与网页版一样。
/// 每一格出不出现照旧按那条消息自己的情况定，这里只管先后。菜单最后固定一格「调整顺序」，不参与排。
/// 原生版还没有的那几格（衣帽间、收藏馆……）照样留在顺序里，排序页上不列；挪动时它们留在原来的位置上。
enum MenuOrder {
    struct Item: Identifiable, Equatable {
        let id: String
        let icon: String
        let label: String
    }

    static let key = "msgMenuOrder"

    /// 网页版 MSG_ITEMS，默认顺序一字不差
    static let all: [Item] = [
        Item(id: "reply", icon: "reply", label: "引用"),
        Item(id: "copy", icon: "copy", label: "复制"),
        Item(id: "fav", icon: "bookmark", label: "收藏"),
        Item(id: "edit", icon: "edit", label: "编辑"),
        Item(id: "phototext", icon: "image", label: "改为文字图 / 改回文字"),
        Item(id: "voice", icon: "mic", label: "改为语音 / 改回文字"),
        Item(id: "regen", icon: "refresh", label: "重新生成"),
        Item(id: "redraw", icon: "image", label: "重画图片"),
        Item(id: "imgvers", icon: "layers", label: "图片版本"),
        Item(id: "astext", icon: "message", label: "显示为文字图 / 显示图片"),
        Item(id: "recall", icon: "undo", label: "撤回"),
        Item(id: "translate", icon: "translate", label: "翻译"),
        Item(id: "vision", icon: "eye", label: "识别图片"),
        Item(id: "think", icon: "brain", label: "查看思考"),
        Item(id: "transedit", icon: "edit", label: "改译文"),
        Item(id: "repair", icon: "sparkle", label: "修正格式"),
        Item(id: "listen", icon: "headphone", label: "一起听"),
        Item(id: "addsong", icon: "plus", label: "加入歌单"),
        Item(id: "remember", icon: "brain", label: "记住这句"),
        Item(id: "rewind", icon: "clock", label: "从这条起重新总结"),
        Item(id: "example", icon: "user", label: "收进示例"),
        Item(id: "served", icon: "alert", label: "生成信息"),
        Item(id: "compare", icon: "layers", label: "换接口对比"),
        Item(id: "keep", icon: "camera", label: "存相册"),
        Item(id: "note", icon: "notes", label: "存备忘"),
        Item(id: "lore", icon: "book", label: "存为世界书"),
        Item(id: "closet", icon: "hanger", label: "衣帽间"),
        Item(id: "collect", icon: "star", label: "收藏馆"),
        Item(id: "multi", icon: "check", label: "多选"),
        Item(id: "delete", icon: "trash", label: "删除"),
    ]

    /// 原生版长按菜单里真有的那几格（排序页只列这些）
    static let native: Set<String> = ["reply", "copy", "fav", "edit", "phototext", "voice", "imgvers", "regen", "redraw", "recall", "translate", "vision", "think",
                                      "transedit", "remember", "rewind", "example", "served", "compare", "keep", "note", "multi", "delete"]

    private static var ids: [String] { all.map(\.id) }

    static func item(_ id: String) -> Item? { all.first { $0.id == id } }

    /// 一份干净的顺序（全部三十项）
    static func order(_ s: AppSettings) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in (s.raw[key]?.array ?? []).compactMap(\.string) where ids.contains(id) && seen.insert(id).inserted { out.append(id) }
        for id in ids where seen.insert(id).inserted { out.append(id) }
        return out
    }

    /// 排序页上列的那几格
    static func shown(_ s: AppSettings) -> [String] { order(s).filter { native.contains($0) } }

    static func changed(_ s: AppSettings) -> Bool { s.raw[key]?.array != nil }

    /// 把排序页上列出的那几格换成新的先后：它们原来占着的那几个位置按新顺序依次填回，原生版不列的几格位置不动
    static func setShown(_ s: inout AppSettings, _ next: [String]) {
        var full = order(s)
        let slots = full.indices.filter { native.contains(full[$0]) }
        let clean = next.filter { native.contains($0) }
        guard clean.count == slots.count, Set(clean).count == clean.count else { return }
        for (k, i) in slots.enumerated() { full[i] = clean[k] }
        s.raw[key] = .array(full.map { .string($0) })
    }

    /// 排序页拖动松手（List.onMove 的写法）
    static func move(_ s: inout AppSettings, from: IndexSet, to: Int) {
        var list = shown(s)
        list.moveItems(fromOffsets: from, toOffset: to)
        setShown(&s, list)
    }

    static func reset(_ s: inout AppSettings) { s.raw[key] = .null }
}

extension Array {
    /// Foundation 里没有 SwiftUI 的 move(fromOffsets:toOffset:)，逻辑层自己写一份（测试里不引 SwiftUI）
    mutating func moveItems(fromOffsets from: IndexSet, toOffset to: Int) {
        let picked = from.sorted().map { self[$0] }
        let before = from.filter { $0 < to }.count
        for i in from.sorted(by: >) { remove(at: i) }
        insert(contentsOf: picked, at: Swift.min(count, Swift.max(0, to - before)))
    }
}
