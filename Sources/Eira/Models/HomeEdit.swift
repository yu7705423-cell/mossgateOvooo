import Foundation

/// 改主屏：壁纸（kv 的 layout.wallpaper.home）、各 app 的图标与名字（settings.appIcons），与网页版同一格式（look.js、AppearancePage）。
///
/// 版式这一份读失败时不写（网页版第 20 条：不拿读失败时的默认值回写）。没存过的按默认版式起一份再改。
/// 换下来的旧图不删：同一张图可能还被别处用着，删图要先核引用，交给存储页的清理。
enum HomeEdit {
    static let iconScale = (min: 50.0, max: 160.0, def: 100.0)

    /// slot：home 主界面，lock 锁屏
    static func setWallpaper(_ imageId: String?, slot: String = "home") throws {
        let stored = try Database.shared.kv(KVKey.layout)
        var o = (stored ?? Shell.defaultLayout).object ?? [:]
        var w = o["wallpaper"]?.object ?? [:]
        w[slot] = imageId.map { .string($0) } ?? .null
        for k in ["home", "lock"] where w[k] == nil { w[k] = .null }
        o["wallpaper"] = .object(w)
        try Database.shared.setKV(KVKey.layout, .object(o))
    }

    /// 改一个 app 的图标与名字。值为空串或 nil 的那一项删掉，回到默认
    static func patchIcon(_ s: inout AppSettings, _ appId: String, _ patch: [String: JSONValue?]) {
        var all = s.raw["appIcons"]?.object ?? [:]
        var cur = all[appId]?.object ?? [:]
        for (k, v) in patch {
            if let v, !v.isNull, v.string != "" { cur[k] = v } else { cur.removeValue(forKey: k) }
        }
        if let l = cur["label"]?.string, l != "show" && l != "hide" { cur.removeValue(forKey: "label") }
        if cur.isEmpty { all.removeValue(forKey: appId) } else { all[appId] = .object(cur) }
        s.raw["appIcons"] = .object(all)
    }

    static func resetIcon(_ s: inout AppSettings, _ appId: String) {
        var all = s.raw["appIcons"]?.object ?? [:]
        all.removeValue(forKey: appId)
        s.raw["appIcons"] = .object(all)
    }

    /// 图片大小：100 为默认（存的时候不写），其余钳在 50 到 160
    static func scaleValue(_ pct: Double) -> JSONValue? {
        let n = pct.rounded()
        if n == iconScale.def { return nil }
        return .number(Swift.max(iconScale.min, Swift.min(iconScale.max, n)))
    }
}
