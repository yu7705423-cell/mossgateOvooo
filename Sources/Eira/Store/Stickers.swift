import Foundation

/// 表情库（网页版 system/stickers.js）。记录在 stickers 数据域：name、keywords、group、imageId 或 url、useCount。
/// 自己建的空分组存在 settings.stickerGroups。
enum Stickers {
    static let collection = "stickers"
    static let defaultGroup = "默认"

    struct Item: Identifiable, Equatable {
        var row: Row
        var id: String { row.id }
        var name: String { row.string("name") }
        var group: String { Stickers.groupOf(row) }
        var imageId: String { row.string("imageId") }
        var url: String { row.string("url") }
        var keywords: [String] { row.strings("keywords") }
        var useCount: Double { row.number("useCount") ?? 0 }
    }

    static func groupOf(_ r: Row) -> String {
        let g = r.string("group").trimmingCharacters(in: .whitespaces)
        return g.isEmpty ? defaultGroup : g
    }

    static func all() throws -> [Item] {
        try Database.shared.all(collection).map { Item(row: $0) }
    }

    private static func saved(_ s: AppSettings) -> [String] {
        (s.raw["stickerGroups"]?.array ?? []).compactMap(\.string)
    }

    /// 分组。onlyUsed 时只给真的有表情的那几个（发送面板上不摆空标签页）。默认组排第一。
    static func groups(_ items: [Item], settings s: AppSettings, onlyUsed: Bool = false) -> [String] {
        var set = Set(items.map(\.group))
        if !onlyUsed { saved(s).forEach { set.insert($0) } }
        return set.sorted { a, b in
            if a == defaultGroup { return b != defaultGroup }
            if b == defaultGroup { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// 关键词默认从名字里切（网页版 splitKeywords）。
    static func splitKeywords(_ text: String) -> [String] {
        Array(text.components(separatedBy: CharacterSet(charactersIn: "|,，、").union(.whitespacesAndNewlines))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(12))
    }

    /// 从一张图建一个表情。图压到最长边 512（网页版 addFromBlob）。
    @discardableResult
    static func add(imageData: Data, name: String, group: String) throws -> Item {
        let imageId = try Images.save(imageData, maxPixel: 512)
        let n = name.trimmingCharacters(in: .whitespaces).isEmpty ? "未命名" : name.trimmingCharacters(in: .whitespaces)
        let row = Row.new(prefix: "stk", [
            "name": .string(n), "keywords": .array(splitKeywords(n).map { .string($0) }),
            "url": .null, "imageId": .string(imageId),
            "group": .string(group.isEmpty ? defaultGroup : group), "useCount": .number(0),
        ])
        try Database.shared.put(collection, row)
        return Item(row: row)
    }

    static func update(_ id: String, _ change: (inout Row) -> Void) throws {
        guard var row = try Database.shared.get(collection, id: id) else { return }
        change(&row)
        row.touch()
        try Database.shared.put(collection, row)
    }

    /// 删掉表情的记录。图留着：一张图可能几处共用，删图要先核引用（网页版第 20 条第三路），原生版还没有引用表。
    static func remove(_ id: String) throws {
        try Database.shared.delete(collection, id: id)
    }

    static func markUsed(_ id: String) {
        try? update(id) { $0["useCount"] = .number(($0.number("useCount") ?? 0) + 1) }
    }

    static func addGroup(_ s: inout AppSettings, _ name: String) -> String {
        let g = String(name.trimmingCharacters(in: .whitespaces).prefix(20))
        guard !g.isEmpty else { return "" }
        let list = saved(s)
        if !list.contains(g) && g != defaultGroup { s.raw["stickerGroups"] = .array((list + [g]).map { .string($0) }) }
        return g
    }

    /// 改名：组里的表情跟着走。
    static func renameGroup(_ s: inout AppSettings, from: String, to: String) throws {
        let b = String(to.trimmingCharacters(in: .whitespaces).prefix(20))
        guard !b.isEmpty, b != from else { return }
        for it in try all() where it.group == from { try update(it.id) { $0["group"] = .string(b) } }
        var list = saved(s).filter { $0 != from }
        if !list.contains(b) && b != defaultGroup { list.append(b) }
        s.raw["stickerGroups"] = .array(list.map { .string($0) })
    }

    /// 删分组：组里的表情挪进默认组，不删。
    static func removeGroup(_ s: inout AppSettings, _ name: String) throws {
        for it in try all() where it.group == name { try update(it.id) { $0["group"] = .string(defaultGroup) } }
        s.raw["stickerGroups"] = .array(saved(s).filter { $0 != name }.map { .string($0) })
    }
}
