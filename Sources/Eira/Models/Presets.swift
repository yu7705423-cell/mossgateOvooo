import Foundation

/// 预设（网页版 `system/presets.js`，ARCHITECTURE 4.384）。
///
/// 一套预设 = 条目顺序、改过措辞的那几段、注入区块的先后、每轮条数等几个数与上下文参数（`AppSettings.presetKeys`）。
/// **全局那一套就住在那几个设置键里**；别的几套是存起来的快照（settings.presets[].data）。
/// 换全局那一套 = 把现在那几个键存回它自己的快照，再把新那套的快照铺到那几个键上。
/// 没有 presets 时当作只有一套「默认」，用户动手时才落盘（网页版第 20 条：第一次打开不往库里写）。
///
/// 这里的函数只改传进来的那份设置，写库由调用方（SettingsModel.update）做。
enum Presets {
    static let defaultId = "default"

    struct Info: Identifiable, Equatable {
        let id: String
        let name: String
    }

    static func rows(_ s: AppSettings) -> [JSONValue] {
        let list = s.raw["presets"]?.array ?? []
        return list.isEmpty ? [.object(["id": .string(defaultId), "name": .string("默认"), "data": .null])] : list
    }

    static func list(_ s: AppSettings) -> [Info] {
        rows(s).compactMap { p in
            guard let id = p["id"]?.string else { return nil }
            return Info(id: id, name: p["name"]?.string ?? "未命名预设")
        }
    }

    static func activeId(_ s: AppSettings) -> String {
        let ids = list(s).map(\.id)
        if let a = s.raw["presetActive"]?.string, ids.contains(a) { return a }
        return ids.first ?? defaultId
    }

    static func name(_ s: AppSettings, _ id: String) -> String {
        list(s).first { $0.id == id }?.name ?? ""
    }

    /// 现在那几个设置键的值。
    static func snapshot(_ s: AppSettings) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for k in AppSettings.presetKeys { if let v = s.raw[k] { out[k] = v } }
        return out
    }

    private static func save(_ s: inout AppSettings, _ rows: [JSONValue], active: String? = nil) {
        let act = active ?? activeId(s)
        s.raw["presets"] = .array(rows)
        s.raw["presetActive"] = .string(act)
    }

    /// 复制一套（不给 from 时复制全局那一套），回新的那一套的 id。
    @discardableResult
    static func duplicate(_ s: inout AppSettings, from: String? = nil, name: String = "") -> String {
        let src = from ?? activeId(s)
        let row = rows(s).first { $0["id"]?.string == src }
        let data: JSONValue = src == activeId(s) ? .object(snapshot(s)) : (row?["data"] ?? .object([:]))
        let srcName = row?["name"]?.string ?? "预设"
        let id = Ids.make("ps")
        let n = String((name.isEmpty ? "\(srcName) 副本" : name).prefix(40))
        save(&s, rows(s) + [.object(["id": .string(id), "name": .string(n), "data": data.isNull ? .object([:]) : data])])
        return id
    }

    static func rename(_ s: inout AppSettings, _ id: String, _ name: String) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !n.isEmpty else { return }
        save(&s, rows(s).map { p in
            guard p["id"]?.string == id, case .object(var o) = p else { return p }
            o["name"] = .string(n)
            return .object(o)
        })
    }

    /// 设为全局那一套。那套快照里没有的键去掉，读的时候用出厂值（网页版写出厂值，效果相同）。
    static func activate(_ s: inout AppSettings, _ id: String) {
        let cur = activeId(s)
        guard id != cur, let target = rows(s).first(where: { $0["id"]?.string == id }) else { return }
        let snap = snapshot(s)
        let updated = rows(s).map { p -> JSONValue in
            guard p["id"]?.string == cur, case .object(var o) = p else { return p }
            o["data"] = .object(snap)
            return .object(o)
        }
        save(&s, updated, active: id)
        let data = target["data"]?.object ?? [:]
        for k in AppSettings.presetKeys { s.raw[k] = data[k] }
    }

    enum Failure: LocalizedError {
        case last, active
        var errorDescription: String? {
            switch self {
            case .last: return "至少保留一套预设"
            case .active: return "全局使用中的预设不能删除，请先换一套"
            }
        }
    }

    /// 删一套。选了它的会话改回跟随全局，由调用方在写库成功之后做（`chatsUsing`）。
    static func remove(_ s: inout AppSettings, _ id: String) throws {
        let all = rows(s)
        guard all.count > 1 else { throw Failure.last }
        guard id != activeId(s) else { throw Failure.active }
        save(&s, all.filter { $0["id"]?.string != id })
    }

    /// 某一套的值（设置的样子）：全局那一套就是设置本身；别的几套是快照叠在设置上，缺的键用出厂值。
    static func values(_ s: AppSettings, _ id: String) -> AppSettings {
        guard id != activeId(s), let row = rows(s).first(where: { $0["id"]?.string == id }) else { return s }
        let data = row["data"]?.object ?? [:]
        var out = s
        for k in AppSettings.presetKeys { out.raw[k] = data[k] }
        return out
    }

    /// 改某一套。全局那一套改设置；别的几套改它自己的快照，只收预设里的键。值为 nil 表示去掉这一项（回到出厂值）。
    static func patch(_ s: inout AppSettings, _ id: String, _ values: [String: JSONValue?]) {
        if id == activeId(s) || !list(s).contains(where: { $0.id == id }) {
            for (k, v) in values { s.raw[k] = v }
            return
        }
        save(&s, rows(s).map { p in
            guard p["id"]?.string == id, case .object(var o) = p else { return p }
            var data = o["data"]?.object ?? [:]
            for (k, v) in values where AppSettings.presetKeys.contains(k) { data[k] = v }
            o["data"] = .object(data)
            return .object(o)
        })
    }

    // MARK: - 导出导入：本应用自己的格式（网页版 FORMAT 'eira-preset'），两边互通

    static let format = "eira-preset"

    static func exportFile(_ s: AppSettings, _ id: String) throws -> URL {
        guard let row = rows(s).first(where: { $0["id"]?.string == id }) else { throw StoreError(message: "预设不存在") }
        let name = row["name"]?.string ?? "预设"
        let data: JSONValue = id == activeId(s) ? .object(snapshot(s)) : (row["data"]?.isNull == false ? row["data"]! : .object([:]))
        let obj: JSONValue = .object(["format": .string(format), "version": .number(1), "name": .string(name), "data": data])
        let safe = name.replacingOccurrences(of: #"[\\/:*?"<>|]"#, with: "_", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Eira预设-\(safe).json")
        try JSONSerialization.data(withJSONObject: obj.any, options: [.prettyPrinted]).write(to: url)
        return url
    }

    /// 读文件，存成新的一套，回它的 id。只收预设里的那几个键。
    static func importData(_ s: inout AppSettings, _ data: Data) throws -> String {
        guard case .object(let obj)? = try? JSONValue.parse(data) else { throw StoreError(message: "文件不是有效的预设") }
        guard obj["format"]?.string == format, case .object(let raw)? = obj["data"] else { throw StoreError(message: "文件不是本应用导出的预设") }
        var picked: [String: JSONValue] = [:]
        for k in AppSettings.presetKeys { if let v = raw[k] { picked[k] = v } }
        let id = Ids.make("ps")
        let name = String((obj["name"]?.string ?? "导入的预设").prefix(40))
        save(&s, rows(s) + [.object(["id": .string(id), "name": .string(name), "data": .object(picked)])])
        return id
    }

    /// 有几段会话选了这一套。
    static func chatsUsing(_ id: String) -> [Chat] {
        ((try? Repo.chats()) ?? []).filter { $0.presetId == id }
    }

    /// 删掉的那一套，选了它的会话改回跟随全局。
    static func releaseChats(_ id: String) throws {
        for var c in chatsUsing(id) {
            c.row["presetId"] = .string("")
            c.row.touch()
            try Repo.save(c)
        }
    }
}
