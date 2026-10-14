import Foundation

/// 主屏的数据：哪些 app、各自的图标与名字、版式（网页版 registry.js、look.js、layout 这一份 kv）。
///
/// 图标、app 列表、新用户的默认版式由 scripts/sync-shell.mjs 从网页版抄进 Resources/shell.json，不手改。
/// 用户自己的版式、壁纸、改过的图标与名字都在导入的数据里（kv 的 layout 与 settings.appIcons），这里只读。
enum Shell {
    struct AppInfo: Sendable, Equatable {
        var id: String
        var name: String
        var icon: String
    }

    private static let data: [String: JSONValue] = {
        guard let url = Bundle.main.url(forResource: "shell", withExtension: "json"),
              let d = try? Data(contentsOf: url),
              let any = try? JSONSerialization.jsonObject(with: d) else { return [:] }
        return JSONValue(any: any).object ?? [:]
    }()

    static let icons: [String: String] = (data["icons"]?.object ?? [:]).compactMapValues(\.string)

    static let apps: [AppInfo] = (data["apps"]?.array ?? []).compactMap { v in
        guard let o = v.object, let id = o["id"]?.string else { return nil }
        return AppInfo(id: id, name: o["name"]?.string ?? id, icon: o["icon"]?.string ?? "")
    }

    static let defaultLayout: JSONValue = data["layout"] ?? .object([:])

    static func app(_ id: String) -> AppInfo? { apps.first { $0.id == id } }

    /// 原生版已经做了的 app。其余的点开是一页说明。
    static let nativeApps: Set<String> = ["chat", "contact", "preset", "settings", "diary", "daily", "music"]

    // MARK: - 图标与名字（网页版 look.js 的 appLook）

    struct Look: Sendable, Equatable {
        var id: String
        var name: String
        var icon: String
        /// 自定义图片，有则盖过线条图标
        var imageId: String
        /// 图片在格子里占多大（百分数），0 为整格
        var scale: Double
        /// 不要底板
        var bare: Bool
        /// 名称单独显示 / 隐藏：show、hide，空为跟随总设置
        var label: String
    }

    static func look(_ appId: String, settings s: [String: JSONValue]) -> Look? {
        guard let app = app(appId) else { return nil }
        let c = s["appIcons"]?.object?[appId]?.object ?? [:]
        let label = c["label"]?.string ?? ""
        return Look(id: appId,
                    name: c["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? app.name,
                    icon: c["icon"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? app.icon,
                    imageId: c["imageId"]?.string ?? "",
                    scale: c["scale"]?.number ?? 0,
                    bare: c["bare"]?.bool == true,
                    label: label == "show" || label == "hide" ? label : "")
    }

    // MARK: - 名称显示（网页版 look.js 的 labelMode / showLabel）

    static func labelMode(_ s: [String: JSONValue]) -> String {
        let m = s["iconLabelMode"]?.string ?? ""
        if ["all", "nodock", "none"].contains(m) { return m }
        return s["iconLabels"]?.bool == false ? "none" : "nodock"
    }

    static func showLabel(_ override: String, inDock: Bool = false, settings s: [String: JSONValue]) -> Bool {
        if override == "show" { return true }
        if override == "hide" { return false }
        let m = labelMode(s)
        return inDock ? m == "all" : m != "none"
    }

    /// 网格列数（网页版 layout.js 的 gridCols）：4、5、6，其余按 4。
    static func cols(_ s: [String: JSONValue]) -> Int {
        let n = Int(s["homeCols"]?.number ?? 4)
        return [4, 5, 6].contains(n) ? n : 4
    }

    // MARK: - 版式

    struct Cell: Identifiable, Sendable, Equatable {
        var id: String
        /// app、widget、folder
        var kind: String
        var ref: String
        var x: Int, y: Int, w: Int, h: Int
        /// 文件夹的名字、里面的 app
        var name: String
        var apps: [String]
        var label: String
        /// 文件夹自己换的封面
        var coverIcon: String
        var coverImageId: String
        /// 小组件自己的设置（网页版 cell.config）
        var config: [String: JSONValue]
    }

    struct Page: Identifiable, Sendable, Equatable {
        var id: String
        var cells: [Cell]
    }

    struct Layout: Sendable, Equatable {
        var pages: [Page]
        var dock: [String?]
        var dockHidden: Bool
        var currentPage: Int
        var wallpaperHome: String
    }

    static let dockSize = 4

    /// 读版式。没存过（新装、没导入）按网页版的默认版式画；读失败同样按默认画，但不写回（网页版第 20 条）。
    static func layout() -> Layout {
        let stored = (try? Database.shared.kv(KVKey.layout)) ?? nil
        return parse(stored ?? defaultLayout)
    }

    static func parse(_ v: JSONValue) -> Layout {
        let o = v.object ?? [:]
        let pages: [Page] = (o["pages"]?.array ?? []).enumerated().map { i, p in
            let po = p.object ?? [:]
            let cells: [Cell] = (po["cells"]?.array ?? []).enumerated().compactMap { j, c in
                guard let co = c.object else { return nil }
                let int = { (k: String, d: Int) -> Int in Int(co[k]?.number ?? Double(d)) }
                let cfg = co["config"]?.object ?? [:]
                return Cell(id: co["id"]?.string ?? "p\(i)c\(j)",
                            kind: co["kind"]?.string ?? "app",
                            ref: co["ref"]?.string ?? "",
                            x: max(0, int("x", 0)), y: max(0, int("y", 0)),
                            w: max(1, int("w", 1)), h: max(1, int("h", 1)),
                            name: co["name"]?.string ?? "",
                            apps: (co["apps"]?.array ?? []).compactMap(\.string),
                            label: co["label"]?.string ?? "",
                            coverIcon: cfg["icon"]?.string ?? "",
                            coverImageId: cfg["imageId"]?.string ?? "",
                            config: cfg)
            }
            return Page(id: po["id"]?.string ?? "p\(i)", cells: cells)
        }
        let dockRaw = o["dock"]?.array ?? []
        let dock: [String?] = (0..<dockSize).map { i in i < dockRaw.count ? dockRaw[i].string.flatMap { $0.isEmpty ? nil : $0 } : nil }
        return Layout(pages: pages.isEmpty ? [Page(id: "p1", cells: [])] : pages,
                      dock: dock,
                      dockHidden: o["dockHidden"]?.bool == true,
                      currentPage: Int(o["currentPage"]?.number ?? 0),
                      wallpaperHome: o["wallpaper"]?.object?["home"]?.string ?? "")
    }

    /// 消息的未读角标（网页版 Dock.js 的 unreadFor）：当前身份的会话未读之和。
    static func chatUnread() -> Int {
        let s = AppSettings.load()
        let active = s.raw["activePersonaId"]?.string ?? ""
        let chats = (try? Repo.chats()) ?? []
        let mine = chats.filter { $0.personaId == active }
        return (active.isEmpty || mine.isEmpty ? chats : mine).reduce(0) { $0 + $1.unread }
    }
}
