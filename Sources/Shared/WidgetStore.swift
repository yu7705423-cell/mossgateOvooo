import Foundation
import UIKit

/// iPhone 桌面组件的数据（网页版 ARCHITECTURE 4.941，外壳那头是 WidgetBridge、组件是 EiraWidgets）。
///
/// 组件扩展读不到应用的库，所以由应用整理好写进 App Group：UserDefaults 里放 JSON（键与网页版外壳相同），
/// 图放在共用目录的 Widgets/ 下。组件只读、只画；组件上点的那几下记进同一处的队列，下次打开应用时应用取走、记进数据。
///
///   w.char    角色此刻：名字、头像文件、会话 id，以及接下来各时段的一串 { at, slot, text }（到点自己切）
///   w.health  健康今天：日期、喝水几杯、排便几次、药吃了几样 / 一共几样、体重
///   w.queue   组件上点的那几下：[{ kind, at, id }]
struct WidgetStore {
    static let charKey = "w.char"
    static let healthKey = "w.health"
    static let queueKey = "w.queue"
    static let avatarFile = "char-avatar.img"
    /// 组件上能点的几种。其余一律不认
    static let tapKinds: Set<String> = ["water", "poop", "med"]

    var defaults: UserDefaults?
    var dir: URL?

    /// 真正用的那一份：App Group
    static var group: WidgetStore {
        WidgetStore(defaults: AppGroup.defaults, dir: AppGroup.container?.appendingPathComponent("Widgets", isDirectory: true))
    }

    func readJSON(_ key: String) -> [String: Any]? {
        guard let s = defaults?.string(forKey: key), let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// 写一份 JSON；nil 是删掉（没有可显示的角色时）
    func writeJSON(_ key: String, _ obj: [String: Any]?) {
        guard let obj else { defaults?.removeObject(forKey: key); return }
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return }
        defaults?.set(s, forKey: key)
    }

    /// 文件名只许字母数字与点、横线：不能跳出这个目录
    static func okName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9._-]{1,80}$", options: .regularExpression) != nil
    }

    func writeImage(_ name: String, _ data: Data) throws {
        guard Self.okName(name), let dir else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    func image(_ name: String?) -> UIImage? {
        guard let name, Self.okName(name), let dir else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent(name).path)
    }

    /// 组件上点的一下：记进队列，健康的数字先在这边加上，打开应用之前看得到变化
    func record(_ kind: String, id: String = "", at: Date = Date()) {
        guard Self.tapKinds.contains(kind) else { return }
        var q = (defaults?.array(forKey: Self.queueKey) as? [[String: Any]]) ?? []
        q.append(["kind": kind, "at": (at.timeIntervalSince1970 * 1000).rounded(), "id": id])
        defaults?.set(q, forKey: Self.queueKey)
        guard var h = readJSON(Self.healthKey) else { return }
        switch kind {
        case "water": h["water"] = int(h["water"]) + 1
        case "poop": h["poop"] = int(h["poop"]) + 1
        case "med":
            let taken = int(h["medTaken"]), total = int(h["medTotal"])
            if taken < total { h["medTaken"] = taken + 1 }
        default: break
        }
        writeJSON(Self.healthKey, h)
    }

    /// 取走队列，取完清空
    func take() -> [[String: Any]] {
        let q = (defaults?.array(forKey: Self.queueKey) as? [[String: Any]]) ?? []
        defaults?.removeObject(forKey: Self.queueKey)
        return q
    }

    private func int(_ v: Any?) -> Int {
        if let n = v as? Int { return n }
        if let n = v as? Double { return Int(n) }
        if let n = v as? NSNumber { return n.intValue }
        return 0
    }
}
