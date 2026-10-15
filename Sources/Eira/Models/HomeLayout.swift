import Foundation

/// 主屏整理（网页版 screens/home/layout.js）：挪位置、挤开、对调、底栏、文件夹、移除与放回、加页删页。
///
/// 改的是 kv 里那份 layout 的原样 JSON：网页版写进去、原生版不认得的字段（格子上的、整份上的）原样留着。
/// **写回之前必须读到**（网页版第 20 条第一条路）：`begin()` 读库失败就抛错、不给改；
/// 库里本来没有这一条（新装、没导入）才从默认版式开始。
struct HomeLayout {
    typealias Obj = [String: JSONValue]

    var lay: Obj
    var cols: Int
    /// 一页最多放几行（主屏量出来的，至少 minRows）
    var cap: Int

    static let minRows = 6

    struct Failure: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    // MARK: - 读写

    /// 读出现在的版式准备改。读失败抛错（不拿默认值顶上，否则一存就把用户的版式盖掉）
    static func begin(settings s: [String: JSONValue], cap: Int = minRows) throws -> HomeLayout {
        let stored = try Database.shared.kv(KVKey.layout)
        return HomeLayout(lay: (stored ?? Shell.defaultLayout).object ?? [:], cols: Shell.cols(s), cap: max(minRows, cap))
    }

    func save() throws {
        try Database.shared.setKV(KVKey.layout, .object(lay))
    }

    // MARK: - 页与格子

    var pages: [Obj] {
        get { (lay["pages"]?.array ?? []).map { $0.object ?? [:] } }
        set { lay["pages"] = .array(newValue.map { .object($0) }) }
    }

    func cells(_ page: Obj) -> [Obj] { (page["cells"]?.array ?? []).map { $0.object ?? [:] } }

    private mutating func setCells(_ i: Int, _ cells: [Obj]) {
        var ps = pages
        guard ps.indices.contains(i) else { return }
        ps[i]["cells"] = .array(cells.map { .object($0) })
        pages = ps
    }

    var dock: [String?] {
        get {
            let raw = lay["dock"]?.array ?? []
            return (0..<Shell.dockSize).map { i in i < raw.count ? raw[i].string.flatMap { $0.isEmpty ? nil : $0 } : nil }
        }
        set { lay["dock"] = .array(newValue.map { id in id.map { JSONValue.string($0) } ?? .null }) }
    }

    var removed: [String] {
        get { (lay["removed"]?.array ?? []).compactMap(\.string) }
        set { lay["removed"] = .array(Array(NSOrderedSet(array: newValue)).compactMap { $0 as? String }.map { JSONValue.string($0) }) }
    }

    static func id(_ c: Obj) -> String { c["id"]?.string ?? "" }
    static func kind(_ c: Obj) -> String { c["kind"]?.string ?? "app" }
    static func ref(_ c: Obj) -> String { c["ref"]?.string ?? "" }
    static func x(_ c: Obj) -> Int { Int(c["x"]?.number ?? 0) }
    static func y(_ c: Obj) -> Int { Int(c["y"]?.number ?? 0) }
    static func w(_ c: Obj) -> Int { max(1, Int(c["w"]?.number ?? 1)) }
    static func h(_ c: Obj) -> Int { max(1, Int(c["h"]?.number ?? 1)) }
    static func apps(_ c: Obj) -> [String] { (c["apps"]?.array ?? []).compactMap(\.string) }

    private static func at(_ c: Obj, _ x: Int, _ y: Int) -> Obj {
        var c = c
        c["x"] = .number(Double(x)); c["y"] = .number(Double(y))
        return c
    }

    private static func newCell(_ fields: Obj) -> Obj {
        var c: Obj = ["id": .string(Ids.make("c"))]
        c.merge(fields) { _, n in n }
        return c
    }

    // MARK: - 空位

    private func occupied(_ cells: [Obj], skip: String? = nil) -> Set<String> {
        var taken = Set<String>()
        for c in cells where Self.id(c) != skip {
            for dy in 0..<Self.h(c) { for dx in 0..<Self.w(c) { taken.insert("\(Self.x(c) + dx),\(Self.y(c) + dy)") } }
        }
        return taken
    }

    private func fits(_ taken: Set<String>, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        guard x >= 0, x + w <= cols, y >= 0 else { return false }
        for dy in 0..<h { for dx in 0..<w where taken.contains("\(x + dx),\(y + dy)") { return false } }
        return true
    }

    /// 整理时多留一行；已经到一页能放的行数就不再多留
    func rows(_ page: Obj, editing: Bool) -> Int {
        let need = cells(page).map { Self.y($0) + Self.h($0) }.max() ?? 0
        return max(Self.minRows, need + (editing && need < cap ? 1 : 0))
    }

    /// 这一页所有空坐标
    func freeSlots(_ i: Int, rows: Int) -> [(x: Int, y: Int)] {
        guard pages.indices.contains(i) else { return [] }
        let taken = occupied(cells(pages[i]))
        var out: [(Int, Int)] = []
        for y in 0..<rows { for x in 0..<cols where !taken.contains("\(x),\(y)") { out.append((x, y)) } }
        return out.map { (x: $0.0, y: $0.1) }
    }

    private func findSpot(_ cells: [Obj], _ w: Int, _ h: Int, skip: String? = nil, maxRows: Int? = nil) -> (Int, Int)? {
        let taken = occupied(cells, skip: skip)
        let limit = max(maxRows ?? cap, h)
        var y = 0
        while y + h <= limit {
            var x = 0
            while x <= cols - w {
                if fits(taken, x, y, w, h) { return (x, y) }
                x += 1
            }
            y += 1
        }
        return nil
    }

    /// 离原来那一格最近的空位（竖着挪比横着挪更打眼，加一点分量）
    private func nearestSpot(_ cells: [Obj], _ w: Int, _ h: Int, _ ox: Int, _ oy: Int) -> (Int, Int)? {
        let taken = occupied(cells)
        let maxY = max(Self.minRows, cells.map { Self.y($0) + Self.h($0) }.max() ?? 0) - h
        var best: (Int, Int)?
        var bestD = Double.infinity
        if maxY >= 0 {
            for y in 0...maxY {
                for x in 0...max(0, cols - w) where fits(taken, x, y, w, h) {
                    let d = Double((x - ox) * (x - ox)) + 1.3 * Double((y - oy) * (y - oy))
                    if d < bestD { bestD = d; best = (x, y) }
                }
            }
        }
        return best
    }

    /// 被挤走的格子：本页就近、其次后面的页、都没有就新建一页
    private mutating func relocate(_ pi: Int, _ cell: Obj) {
        var ps = pages
        var here = cells(ps[pi])
        if let s = nearestSpot(here, Self.w(cell), Self.h(cell), Self.x(cell), Self.y(cell)) ?? findSpot(here, Self.w(cell), Self.h(cell)) {
            here.append(Self.at(cell, s.0, s.1))
            ps[pi]["cells"] = .array(here.map { .object($0) })
            pages = ps
            return
        }
        for i in (pi + 1)..<max(pi + 1, ps.count) {
            var cs = cells(ps[i])
            if let s = findSpot(cs, Self.w(cell), Self.h(cell)) {
                cs.append(Self.at(cell, s.0, s.1))
                ps[i]["cells"] = .array(cs.map { .object($0) })
                pages = ps
                return
            }
        }
        ps.append(["id": .string(Ids.make("p")), "cells": .array([.object(Self.at(cell, 0, 0))])])
        pages = ps
    }

    /// 按 id 在整本里找
    func locate(_ cellId: String) -> (page: Int, cell: Obj)? {
        for (i, p) in pages.enumerated() {
            if let c = cells(p).first(where: { Self.id($0) == cellId }) { return (i, c) }
        }
        return nil
    }

    private static func overlaps(_ c: Obj, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        Self.x(c) < x + w && Self.x(c) + Self.w(c) > x && Self.y(c) < y + h && Self.y(c) + Self.h(c) > y
    }

    // MARK: - 放与挪

    /// 在某个坐标放东西。挡路的挪走，不拒绝。放的是已经摆着的 app 时，先从原处摘下
    mutating func place(page pi: Int, x: Int, y: Int, _ next: Obj) throws {
        if Self.kind(next) == "app", !Self.ref(next).isEmpty { detach([Self.ref(next)]) }
        guard pages.indices.contains(pi) else { throw Failure(reason: "页面不存在") }
        let w = max(1, min(cols, Self.w(next)))
        let h = Self.h(next)
        let px = min(x, cols - w)
        guard px >= 0 else { throw Failure(reason: "一行只有 \(cols) 格，放不下这个宽度") }
        var here = cells(pages[pi])
        let displaced = here.filter { Self.overlaps($0, px, y, w, h) }
        let gone = Set(displaced.map(Self.id))
        here.removeAll { gone.contains(Self.id($0)) }
        var c = Self.newCell(next)
        c["x"] = .number(Double(px)); c["y"] = .number(Double(y))
        c["w"] = .number(Double(w)); c["h"] = .number(Double(h))
        here.append(c)
        setCells(pi, here)
        for d in displaced { relocate(pi, d) }
    }

    /// 把一个格子换成别的内容（在它原来的位置上）
    mutating func replace(_ cellId: String, with next: Obj) throws {
        guard let (pi, cell) = locate(cellId) else { throw Failure(reason: "位置不存在") }
        setCells(pi, cells(pages[pi]).filter { Self.id($0) != cellId })
        try place(page: pi, x: Self.x(cell), y: Self.y(cell), next)
    }

    /// 挪到某个坐标：正好和一个同样大小的重合就对调（跨页时各搬到对方那一页），否则挤开
    mutating func move(_ cellId: String, toPage di: Int, x: Int, y: Int) throws {
        guard pages.indices.contains(di) else { throw Failure(reason: "页面不存在") }
        guard let (fi, found) = locate(cellId) else { throw Failure(reason: "位置不存在") }
        var cell = found
        let px = min(max(0, x), cols - Self.w(cell))
        let others = cells(pages[di]).filter { Self.id($0) != cellId }
        let hit = others.filter { Self.overlaps($0, px, y, Self.w(cell), Self.h(cell)) }

        if hit.count == 1, Self.w(hit[0]) == Self.w(cell), Self.h(hit[0]) == Self.h(cell) {
            let other = Self.at(hit[0], Self.x(cell), Self.y(cell))
            cell = Self.at(cell, Self.x(hit[0]), Self.y(hit[0]))
            var from = cells(pages[fi]).filter { Self.id($0) != cellId && Self.id($0) != Self.id(other) }
            if fi == di {
                from.append(cell); from.append(other)
                setCells(fi, from)
            } else {
                from.append(other)
                setCells(fi, from)
                var dest = cells(pages[di]).filter { Self.id($0) != Self.id(other) }
                dest.append(cell)
                setCells(di, dest)
            }
            return
        }

        setCells(fi, cells(pages[fi]).filter { Self.id($0) != cellId })
        let gone = Set(hit.map(Self.id))
        var dest = cells(pages[di]).filter { !gone.contains(Self.id($0)) }
        dest.append(Self.at(cell, px, y))
        setCells(di, dest)
        for c in hit { relocate(di, c) }
    }

    // MARK: - 底栏

    enum Spot: Equatable {
        case cell(String)
        case slot(page: Int, x: Int, y: Int)
        case dock(Int)
    }

    /// 统一的挪动入口：网格的格子、网格的空位、底栏的槽位之间互相挪
    mutating func move(_ source: Spot, to target: Spot) throws {
        var d = dock
        switch (source, target) {
        case let (.dock(a), .dock(b)):
            d.swapAt(a, b)
            dock = d
        case let (.cell(id), .dock(b)):
            guard let (pi, cell) = locate(id) else { throw Failure(reason: "来源不存在") }
            guard Self.kind(cell) == "app" else { throw Failure(reason: "底部那一排只能放应用") }
            guard Self.w(cell) == 1, Self.h(cell) == 1 else { throw Failure(reason: "只能放 1x1 的应用") }
            let displaced = d[b]
            d[b] = Self.ref(cell)
            var here = cells(pages[pi]).filter { Self.id($0) != id }
            if let displaced {
                here.append(Self.newCell(["kind": .string("app"), "ref": .string(displaced), "x": .number(Double(Self.x(cell))),
                                          "y": .number(Double(Self.y(cell))), "w": .number(1), "h": .number(1)]))
            }
            setCells(pi, here)
            dock = d
        case let (.dock(a), .slot(pi, x, y)):
            guard let appId = d[a] else { throw Failure(reason: "这个位置是空的") }
            guard pages.indices.contains(pi) else { throw Failure(reason: "页面不存在") }
            d[a] = nil
            dock = d
            var here = cells(pages[pi])
            here.append(Self.newCell(["kind": .string("app"), "ref": .string(appId), "x": .number(Double(x)), "y": .number(Double(y)),
                                      "w": .number(1), "h": .number(1)]))
            setCells(pi, here)
        case let (.dock(a), .cell(id)):
            guard let appId = d[a] else { throw Failure(reason: "这个位置是空的") }
            guard let (pi, cell) = locate(id) else { throw Failure(reason: "目标不存在") }
            guard Self.kind(cell) == "app", Self.w(cell) == 1, Self.h(cell) == 1 else {
                throw Failure(reason: "底部那一排只能和 1x1 的应用互换")
            }
            d[a] = Self.ref(cell)
            dock = d
            setCells(pi, cells(pages[pi]).map { c in
                guard Self.id(c) == id else { return c }
                var c = c
                c["ref"] = .string(appId)
                return c
            })
        case let (.cell(id), .cell(other)):
            guard let (pi, t) = locate(other) else { throw Failure(reason: "目标不存在") }
            try move(id, toPage: pi, x: Self.x(t), y: Self.y(t))
        case let (.cell(id), .slot(pi, x, y)):
            try move(id, toPage: pi, x: x, y: y)
        case (.slot, _):
            throw Failure(reason: "这个位置是空的")
        }
    }

    // MARK: - 移除与放回

    /// 移除一个格子。app 与文件夹里的 app 记进 removed，否则下次自愈又把它摆回来
    mutating func remove(_ cellId: String) {
        guard let (pi, cell) = locate(cellId) else { return }
        setCells(pi, cells(pages[pi]).filter { Self.id($0) != cellId })
        let gone = Self.kind(cell) == "app" ? [Self.ref(cell)] : Self.kind(cell) == "folder" ? Self.apps(cell) : []
        if !gone.isEmpty { removed = removed + gone }
    }

    mutating func removeDock(_ i: Int) {
        var d = dock
        guard d.indices.contains(i), let id = d[i] else { return }
        d[i] = nil
        dock = d
        removed = removed + [id]
    }

    /// 放回来：从 removed 里划掉，再给它找个空位
    mutating func restore(_ appId: String) {
        removed = removed.filter { $0 != appId }
        heal()
    }

    /// 移除过、现在不在主界面上的
    var removedApps: [String] { removed.filter { Shell.app($0) != nil } }

    // MARK: - 页

    mutating func addPage() -> Int {
        var ps = pages
        ps.append(["id": .string(Ids.make("p")), "cells": .array([])])
        pages = ps
        return ps.count - 1
    }

    /// 只删空页，第一页不删
    @discardableResult
    mutating func removePage(_ i: Int) -> Bool {
        var ps = pages
        guard ps.count > 1, i > 0, ps.indices.contains(i), cells(ps[i]).isEmpty else { return false }
        ps.remove(at: i)
        pages = ps
        let cur = Int(lay["currentPage"]?.number ?? 0)
        lay["currentPage"] = .number(Double(min(cur, ps.count - 1)))
        return true
    }

    // MARK: - 格子本身的几项

    /// label：'show' | 'hide' | ''；title：小组件的名字
    mutating func setMeta(_ cellId: String, label: String? = nil, title: String? = nil) {
        guard let (pi, _) = locate(cellId) else { return }
        setCells(pi, cells(pages[pi]).map { c in
            guard Self.id(c) == cellId else { return c }
            var c = c
            if let label { if label == "show" || label == "hide" { c["label"] = .string(label) } else { c.removeValue(forKey: "label") } }
            if let title {
                let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16))
                if t.isEmpty { c.removeValue(forKey: "title") } else { c["title"] = .string(t) }
            }
            return c
        })
    }

    mutating func setConfig(_ cellId: String, _ config: Obj) {
        guard let (pi, _) = locate(cellId) else { return }
        setCells(pi, cells(pages[pi]).map { c in
            guard Self.id(c) == cellId else { return c }
            var c = c
            var cfg = c["config"]?.object ?? [:]
            cfg.merge(config) { _, n in n }
            c["config"] = .object(cfg)
            return c
        })
    }

    // MARK: - 文件夹

    /// 把这几个 app 从现在待的地方摘下来：网格、底栏、别的文件夹
    mutating func detach(_ ids: [String], keep: String? = nil) {
        let set = Set(ids)
        var ps = pages
        for i in ps.indices {
            var kept: [Obj] = []
            for c in cells(ps[i]) {
                if Self.kind(c) == "app" && set.contains(Self.ref(c)) { continue }
                if Self.kind(c) == "folder" && Self.id(c) != keep {
                    let next = Self.apps(c).filter { !set.contains($0) }
                    if next.isEmpty { continue }
                    var c = c
                    c["apps"] = .array(next.map { JSONValue.string($0) })
                    kept.append(c)
                    continue
                }
                kept.append(c)
            }
            ps[i]["cells"] = .array(kept.map { .object($0) })
        }
        pages = ps
        dock = dock.map { $0.flatMap { set.contains($0) ? nil : $0 } }
        removed = removed.filter { !set.contains($0) }
    }

    mutating func newFolder(page pi: Int, x: Int, y: Int, apps: [String], name: String) throws {
        let list = Array(NSOrderedSet(array: apps.filter { Shell.app($0) != nil })).compactMap { $0 as? String }
        guard !list.isEmpty else { throw Failure(reason: "请至少选择一个应用") }
        detach(list)
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        try place(page: pi, x: x, y: y, ["kind": .string("folder"), "name": .string(n.isEmpty ? "文件夹" : n),
                                         "apps": .array(list.map { JSONValue.string($0) }), "w": .number(1), "h": .number(1)])
    }

    /// 改文件夹的名字与里面装什么。装空了这个文件夹去掉
    mutating func setFolder(_ cellId: String, name: String, apps: [String]) throws {
        let keep = Array(NSOrderedSet(array: apps.filter { Shell.app($0) != nil })).compactMap { $0 as? String }
        detach(keep, keep: cellId)
        guard let (pi, cell) = locate(cellId), Self.kind(cell) == "folder" else { throw Failure(reason: "这个文件夹不存在了") }
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        setCells(pi, cells(pages[pi]).compactMap { c in
            guard Self.id(c) == cellId else { return c }
            if keep.isEmpty { return nil }
            var c = c
            c["apps"] = .array(keep.map { JSONValue.string($0) })
            c["name"] = .string(n.isEmpty ? "文件夹" : n)
            return c
        })
    }

    /// 从文件夹里拿一个出来，交给自愈找空位
    mutating func takeOut(_ cellId: String, app: String) throws {
        guard let (_, cell) = locate(cellId), Self.kind(cell) == "folder" else { throw Failure(reason: "这个文件夹不存在了") }
        try setFolder(cellId, name: cell["name"]?.string ?? "", apps: Self.apps(cell).filter { $0 != app })
        heal()
    }

    mutating func putInFolder(_ cellId: String, app: String) throws {
        guard let (_, cell) = locate(cellId), Self.kind(cell) == "folder" else { throw Failure(reason: "这个文件夹不存在了") }
        try setFolder(cellId, name: cell["name"]?.string ?? "", apps: Self.apps(cell) + [app])
    }

    var folders: [Obj] { pages.flatMap { cells($0) }.filter { Self.kind($0) == "folder" } }

    // MARK: - 自愈

    /// 去掉失效的与重复的、重叠的挪开、没摆出来又没被移除的 app 找个空位、空页去掉（第一页留着）。
    /// 不认识的小组件留着（多半是网页版新加的），不删
    mutating func heal() {
        var ps = pages.isEmpty ? [["id": .string(Ids.make("p")), "cells": .array([])]] : pages
        var seen = Set<String>()
        for i in ps.indices {
            var kept: [Obj] = []
            for raw in cells(ps[i]) {
                var c = raw
                c["w"] = .number(Double(max(1, min(cols, Self.w(c)))))
                c["h"] = .number(Double(max(1, min(6, Self.h(c)))))
                if Self.id(c).isEmpty { c["id"] = .string(Ids.make("c")) }
                switch Self.kind(c) {
                case "app":
                    let r = Self.ref(c)
                    if Shell.app(r) == nil || seen.contains(r) { continue }
                    seen.insert(r)
                case "folder":
                    var list: [String] = []
                    for a in Self.apps(c) where Shell.app(a) != nil && !seen.contains(a) { seen.insert(a); list.append(a) }
                    if list.isEmpty { continue }
                    c["apps"] = .array(list.map { JSONValue.string($0) })
                    c["w"] = .number(1); c["h"] = .number(1)
                    if (c["name"]?.string ?? "").isEmpty { c["name"] = .string("文件夹") }
                case "widget":
                    if Self.ref(c).isEmpty { continue }
                default:
                    continue
                }
                if !fits(occupied(kept), Self.x(c), Self.y(c), Self.w(c), Self.h(c)) {
                    guard let s = findSpot(kept, Self.w(c), Self.h(c), maxRows: 60) else { continue }
                    c = Self.at(c, s.0, s.1)
                }
                kept.append(c)
            }
            ps[i]["cells"] = .array(kept.map { .object($0) })
        }
        pages = ps

        var d = dock.map { id in id.flatMap { Shell.app($0) == nil ? nil : $0 } }
        for i in d.indices { if let id = d[i], d[..<i].contains(id) { d[i] = nil } }
        dock = d
        if lay["dockHidden"]?.bool != true { for id in d.compactMap({ $0 }) { seen.insert(id) } }
        removed = removed.filter { Shell.app($0) != nil && !seen.contains($0) }
        let gone = Set(removed)

        for app in Shell.apps where !seen.contains(app.id) && !gone.contains(app.id) {
            var ps = pages
            var done = false
            for i in ps.indices where !done {
                var cs = cells(ps[i])
                if let s = findSpot(cs, 1, 1) {
                    cs.append(Self.newCell(["kind": .string("app"), "ref": .string(app.id), "x": .number(Double(s.0)), "y": .number(Double(s.1)),
                                            "w": .number(1), "h": .number(1)]))
                    ps[i]["cells"] = .array(cs.map { .object($0) })
                    done = true
                }
            }
            if !done {
                ps.append(["id": .string(Ids.make("p")), "cells": .array([.object(Self.newCell(["kind": .string("app"), "ref": .string(app.id),
                    "x": .number(0), "y": .number(0), "w": .number(1), "h": .number(1)]))])])
            }
            pages = ps
            seen.insert(app.id)
        }

        let left = pages.enumerated().filter { i, p in i == 0 || !cells(p).isEmpty }.map(\.element)
        pages = left.isEmpty ? [["id": .string(Ids.make("p")), "cells": .array([])]] : left
        let cur = Int(lay["currentPage"]?.number ?? 0)
        lay["currentPage"] = .number(Double(min(max(0, cur), pages.count - 1)))
    }
}
