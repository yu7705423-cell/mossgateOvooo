import Foundation
import ImageIO
import UIKit
import UserNotifications
import WidgetKit

/// iPhone 桌面组件的数据从哪来（网页版 system/iwidget.js，ARCHITECTURE 4.941）。
///
/// 组件扩展（EiraWidgets）读不到应用的库，这里把要显示的东西整理好，写进 App Group（WidgetStore）；
/// 组件上点的那几下（喝水、排便、服药）记在那边的队列里，打开应用时取回来记进健康记录。
/// 什么时候做：回到前台先取回点按、再交一遍；退到后台交一遍；改了「显示哪个角色」交一遍。
/// 不调接口（第 15 条）：日程与健康都是本机已有的数据，组件只是换个地方显示。
enum WidgetFeed {
    private static let sentKey = "eira-widget-sent"

    // MARK: - 显示哪个角色

    /// 「设置 - 主题 - iPhone 桌面组件」里选的（settings.iosWidgetChar，与网页版同一个键）；没选就取开着当日日程、最近聊过的那个角色
    static func charFor(_ s: AppSettings = .load()) -> Character? {
        let want = s.raw["iosWidgetChar"]?.string ?? ""
        if !want.isEmpty, let c = try? Repo.character(want) { return c }
        let chats = ((try? Repo.chats()) ?? []).filter { $0.characterIds.count == 1 }.sorted { $0.lastMessageAt > $1.lastMessageAt }
        for chat in chats {
            if let c = try? Repo.character(chat.characterIds[0]), DayPlan.isOn(c) { return c }
        }
        return ((try? Repo.characters()) ?? []).first { DayPlan.isOn($0) && !$0.isNpc }
    }

    static func chatOf(_ charId: String) -> Chat? {
        ((try? Repo.chats()) ?? []).first { $0.characterIds == [charId] }
    }

    /// 角色接下来一天半里每个时段在做什么：按 15 分钟往前看，时段或日期一变就是一格
    static func charEntries(_ char: Character, now: Date = Date()) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var key = ""
        let step: TimeInterval = 15 * 60
        var t = now
        while t < now.addingTimeInterval(36 * 3600) {
            defer { t = t.addingTimeInterval(step) }
            let slot = DayPlan.slotNow(char, t)
            let date = DayPlan.dateKey(char, t)
            guard "\(date)|\(slot.id)" != key else { continue }
            key = "\(date)|\(slot.id)"
            let text: String
            if let d = try? DayPlan.day(char.id, date: date) {
                let items = (d["items"]?.array ?? []).filter { $0["slot"]?.string == slot.id && $0["state"]?.string != DayPlan.drop }
                let joined = items.compactMap { $0["text"]?.string }.filter { !$0.isEmpty }.joined(separator: "；")
                text = joined.isEmpty ? "这一时段没有安排" : joined
            } else {
                text = "今天的日程尚未生成"
            }
            // 第一格从此刻起；其余落在十五分钟的整点上
            let at = out.isEmpty ? t : Date(timeIntervalSince1970: (t.timeIntervalSince1970 / step).rounded(.down) * step)
            out.append(["at": at.millis, "slot": slot.label, "text": text])
        }
        return out
    }

    // MARK: - 健康

    static func healthNow() -> [String: Any] {
        let d = Health.day(Health.me)
        let active = Health.activeMeds()
        let weight = d.weight > 0 ? String(format: "%.1f %@", Health.toDisplay(d.weight), Health.unit()) : "—"
        return ["date": d.date, "water": Int(d.water), "poop": d.poops.count,
                "medTaken": active.filter { d.took.contains($0.id) }.count, "medTotal": active.count, "weight": weight]
    }

    /// 组件上点「服药」记哪一样：今天还没吃的，先挑时间已经到了的（最早的那个时刻在前），没有就按名字第一样
    static func nextMed(now: Date = Date()) -> Row? {
        let took = Health.day(Health.me).took
        let left = Health.activeMeds().filter { !took.contains($0.id) }
        let hm = Health.hhmm(now)
        let due = left.filter { m in m.strings("times").contains { $0 <= hm } }
            .sorted { ($0.strings("times").min() ?? "") < ($1.strings("times").min() ?? "") }
        return due.first ?? left.sorted { $0.string("name") < $1.string("name") }.first
    }

    // MARK: - 交与取

    /// 把两样都交一遍。写不进去不抛：组件只是没更新，不影响应用
    @discardableResult
    static func sync(store: WidgetStore = .group, now: Date = Date()) -> Bool {
        guard store.defaults != nil else { return false }
        if let c = charFor() {
            let avatar = ChatFaces.of(chatOf(c.id), key: c.id, fallback: c.avatar)
            if sent(WidgetStore.avatarFile) != avatar {
                if let data = FaceThumbs.jpeg(avatar, maxPixel: 256) {
                    do { try store.writeImage(WidgetStore.avatarFile, data); markSent(WidgetStore.avatarFile, avatar) }
                    catch { Diagnostics.shared.record("widget-image-failed", ["error": error.localizedDescription]) }
                }
            }
            store.writeJSON(WidgetStore.charKey, ["name": c.displayName, "chatId": chatOf(c.id)?.id ?? "",
                                                  "avatar": WidgetStore.avatarFile, "entries": charEntries(c, now: now)])
        } else {
            store.writeJSON(WidgetStore.charKey, nil)
        }
        store.writeJSON(WidgetStore.healthKey, healthNow())
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }

    /// 取回组件上点的那几下，记进健康记录。回记了几下。记不进去的在屏幕上说（第 20 条）
    @discardableResult
    static func drain(store: WidgetStore = .group) -> Int {
        let taps = store.take()
        var n = 0
        for t in taps {
            do {
                switch t["kind"] as? String ?? "" {
                case "water": try Health.addWater(Health.me, 1)
                case "poop": try Health.addPoop(Health.me, Health.dateKey())
                case "med":
                    guard let m = nextMed() else { continue }
                    try Health.takeMed(m.id)
                default: continue
                }
                n += 1
            } catch {
                Problems.report("桌面组件上的记录未能保存：\(error.localizedDescription)")
            }
        }
        return n
    }

    /// 回到前台：先取回点按，再交一遍
    static func wake() {
        drain()
        sync()
    }

    private static func sent(_ name: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: sentKey) as? [String: String])?[name]
    }

    private static func markSent(_ name: String, _ id: String) {
        var m = (UserDefaults.standard.dictionary(forKey: sentKey) as? [String: String]) ?? [:]
        m[name] = id
        UserDefaults.standard.set(m, forKey: sentKey)
    }

    // MARK: - 通知扩展用的头像（4.711）

    /// 交给后台消息服务器的那几段会话（开着主动发起对话的角色）：头像缩成小图写进 App Group，通知扩展按会话取
    static func exportFaces(_ s: AppSettings = .load()) {
        guard let dir = NotifyFaces.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for char in (try? Repo.characters()) ?? [] {
            guard Proactive.config(char).on, let chat = Proactive.chatReady(char.id, s),
                  let url = NotifyFaces.file(chat.id, in: dir) else { continue }
            let face = ChatFaces.of(chat, key: char.id, fallback: char.avatar)
            let name = "face-" + chat.id
            guard sent(name) != face else { continue }
            if let data = FaceThumbs.jpeg(face, maxPixel: 180), (try? data.write(to: url, options: .atomic)) != nil { markSent(name, face) }
        }
    }
}

/// 头像缩成小图（桌面组件、通知上的那一张）。按显示大小缩着解码，不整张读进内存
enum FaceThumbs {
    static func jpeg(_ imageId: String, maxPixel: CGFloat) -> Data? {
        guard !imageId.isEmpty, let url = MediaStore.url(.images, id: imageId),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }

    /// 本地通知上的头像：单聊是这段会话里该显示的那张，群聊是群头像，没有就第一个成员的
    static func faceId(_ chat: Chat) -> String {
        if chat.isGroup {
            if !chat.avatar.isEmpty { return chat.avatar }
            return GroupChat.members(chat).first { !$0.avatar.isEmpty }?.avatar ?? ""
        }
        guard let id = chat.characterIds.first, let c = try? Repo.character(id) else { return "" }
        return ChatFaces.of(chat, key: c.id, fallback: c.avatar)
    }

    /// 写成临时文件交给系统（系统会把附件挪走）
    static func attachment(_ chat: Chat) -> UNNotificationAttachment? {
        guard let data = jpeg(faceId(chat), maxPixel: 180) else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("face-\(UUID().uuidString).jpg")
        guard (try? data.write(to: tmp)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "face", url: tmp, options: nil)
    }
}
