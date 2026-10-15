import Foundation

/// 外观预设（网页版 system/looks.js）：把整套装修拍个快照存进 looks 这一域，随时切回去。
/// 存的是壁纸、图标、图标位置、小组件与主题参数，不碰角色、聊天记录、接口这些。
enum Looks {
    static let collection = "looks"

    /// settings 里属于外观的那些字段（与网页版 LOOK_KEYS 同一份，再加原生版的配色与字号）
    static let keys = ["theme", "appIcons", "iconColor", "iconShadow", "iconLabels", "iconLabelMode", "tilePlate", "iconLabelColor", "glass",
                       "homeCols", "iconScale", "dockColor", "homeSwipe", "homePageFx",
                       "bottomLift", "customCSS", "statusBar", "showLockScreen",
                       "fontBody", "fontSerif", "fontHand", "palette", "fontScale"]

    struct Item: Identifiable {
        let row: Row
        var id: String { row.id }
        var name: String { row.string("name").isEmpty ? "未命名" : row.string("name") }
        var updated: Double { row.number("updatedAt") ?? row.created ?? 0 }
        var wallpaper: String { row["layout"]?["wallpaper"]?["home"]?.string ?? "" }
        var cellCount: Int { (row["layout"]?["pages"]?.array ?? []).reduce(0) { $0 + ($1["cells"]?.array?.count ?? 0) } }
    }

    static func all() throws -> [Item] {
        try Database.shared.all(collection).map(Item.init).sorted { $0.updated > $1.updated }
    }

    private static func snapshot() throws -> [String: JSONValue] {
        let s = try AppSettings.loadForWrite()
        var look: [String: JSONValue] = [:]
        for k in keys { if let v = s.raw[k] { look[k] = v } }
        let layout = try Database.shared.kv(KVKey.layout) ?? Shell.defaultLayout
        return ["look": .object(look), "layout": layout]
    }

    @discardableResult
    static func save(name: String) throws -> Row {
        var fields = try snapshot()
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        fields["name"] = .string(n.isEmpty ? "未命名" : String(n.prefix(30)))
        let row = Row.new(prefix: "look", fields)
        try Database.shared.put(collection, row)
        return row
    }

    /// 用现在的样子覆盖一个已有预设
    static func overwrite(_ id: String) throws {
        guard var row = try Database.shared.get(collection, id: id) else { throw StoreError(message: "这个预设已不存在") }
        for (k, v) in try snapshot() { row[k] = v }
        row.touch()
        try Database.shared.put(collection, row)
    }

    static func rename(_ id: String, _ name: String) throws {
        guard var row = try Database.shared.get(collection, id: id) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        row["name"] = .string(n.isEmpty ? "未命名" : String(n.prefix(30)))
        row.touch()
        try Database.shared.put(collection, row)
    }

    static func remove(_ id: String) throws { try Database.shared.delete(collection, id: id) }

    /// 换上一套。图已经不在的当没设过（不把界面弄成空白），返回缺了几张
    @discardableResult
    static func apply(_ id: String, has: (String) -> Bool) throws -> Int {
        guard let row = try Database.shared.get(collection, id: id) else { throw StoreError(message: "这个预设已不存在") }
        var missing = 0
        var lay = row["layout"]?.object ?? [:]
        var wall = lay["wallpaper"]?.object ?? [:]
        for k in ["home", "lock"] {
            if let w = wall[k]?.string, !w.isEmpty, !has(w) { missing += 1; wall[k] = .null }
        }
        if lay["wallpaper"] != nil { lay["wallpaper"] = .object(wall) }
        var look = row["look"]?.object ?? [:]
        if var icons = look["appIcons"]?.object {
            for (app, v) in icons {
                if let img = v["imageId"]?.string, !img.isEmpty, !has(img), var o = v.object {
                    missing += 1
                    o["imageId"] = .null
                    icons[app] = .object(o)
                }
            }
            look["appIcons"] = .object(icons)
        }
        // 底栏开关跟着那一套布局走：存的时候开着就没有这一项，换上时要打开
        if lay["pages"] != nil && lay["dockHidden"] == nil { lay["dockHidden"] = .bool(false) }

        // 先读到现在的两份再写（读失败不写，网页版第 20 条）
        var s = try AppSettings.loadForWrite()
        let current = try Database.shared.kv(KVKey.layout)?.object ?? Shell.defaultLayout.object ?? [:]
        for (k, v) in look { s.raw[k] = v }
        try s.save()
        var merged = current
        for (k, v) in lay { merged[k] = v }
        try Database.shared.setKV(KVKey.layout, .object(merged))
        return missing
    }
}
