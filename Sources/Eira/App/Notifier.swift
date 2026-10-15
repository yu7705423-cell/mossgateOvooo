import BackgroundTasks
import Combine
import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    /// 某段会话在界面之外多了消息（主动发起对话、后台消息取回）。正开着的页面据此刷新。
    static let eiraChatChanged = Notification.Name("eira.chatChanged")
}

extension NotificationCenter {
    /// 不在看那段会话的地方（主屏角标、会话列表、小组件）用这一路：一轮回复里连着发好几次，
    /// 停下来 0.3 秒再刷新一次，不每次都把整张列表重读一遍
    static var chatChangesSettled: AnyPublisher<Notification, Never> {
        NotificationCenter.default.publisher(for: .eiraChatChanged)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .eraseToAnyPublisher()
    }
}

/// 本地通知（路线图阶段 4）。
///
/// - 角色主动发来的消息：你没在看那段会话时弹一条；那段会话开了免打扰就不弹；
/// - 后台消息：应用不在前台时，系统不定时让应用醒来一小会儿（后台刷新），这时只向后台消息服务器问一句有没有新结果，
///   有就弹通知。**这一问不调模型、不花钱**，结果照旧在打开应用时取回落进会话；
/// - 点通知直接打开那段会话。
/// 开关在「设置 - 通知」，默认关：开的时候系统才问通知权限。
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let refreshId = "eira.bgpush.refresh"
    private static let notifiedKey = "eira-notified-results"

    /// 点了通知、要打开的那段会话
    @Published var openChat: String?
    /// 正在看的那段会话（这段来消息不弹）
    var visibleChat: String?
    @Published private(set) var authorized = false

    nonisolated static func isOn(_ s: AppSettings = .load()) -> Bool { s.raw["nativeNotify"]?.bool == true }
    /// 通知里写不写消息内容。不写就只说「发来一条消息」
    nonisolated static func showsText(_ s: AppSettings = .load()) -> Bool { s.raw["nativeNotifyText"]?.bool ?? true }

    func install() {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Notifier.handleRefresh(task)
        }
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        authorized = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    /// 打开开关：系统问一次权限。拒绝过的要去系统设置里开。
    func enable() async -> Bool {
        do {
            let ok = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            if ok { SettingsModel.shared.set("nativeNotify", .bool(true)) }
            return ok
        } catch {
            return false
        }
    }

    func disable() {
        SettingsModel.shared.set("nativeNotify", .bool(false))
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
    }

    // MARK: - 弹

    /// 通知上那一行：第一句，方括号标记去掉（网页版 worker/push.js 同样）。
    nonisolated static func line(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: #"[\[【][^\]】]*[\]】]"#, with: "", options: .regularExpression)
        let first = plain.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return String(first.prefix(120))
    }

    /// 某段会话来了角色的消息。开关关着、正在看这段、这段免打扰时不弹。
    nonisolated static func post(chatId: String, title: String, text: String, id: String = UUID().uuidString) {
        Task { @MainActor in NotificationCenter.default.post(name: .eiraChatChanged, object: chatId) }
        let s = AppSettings.load()
        guard isOn(s) else { return }
        if (try? Repo.chat(chatId))?.muted == true { return }
        Task { @MainActor in
            if UIApplication.shared.applicationState == .active && Notifier.shared.visibleChat == chatId { return }
            let c = UNMutableNotificationContent()
            c.title = title.isEmpty ? "Eiraowo" : title
            let l = line(text)
            c.body = showsText(s) && !l.isEmpty ? l : "发来一条消息"
            c.sound = .default
            c.userInfo = ["chatId": chatId]
            c.threadIdentifier = chatId
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
            await updateBadge()
        }
    }

    /// 断火提醒（互动标识）：按 Badges.remindPlan 排一条定时的本地通知，或者撤掉。每段会话一个标识，重排即替换
    nonisolated static func planStreak(_ chat: Chat, title: String) {
        let id = "streak-\(chat.id)"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard isOn(), !chat.muted, let plan = Badges.remindPlan(chat) else { return }
        let c = UNMutableNotificationContent()
        c.title = title.isEmpty ? "Eiraowo" : title
        c.body = "连续互发 \(plan.n) 天，今天尚未互发。零点之后火花熄灭。"
        c.sound = .default
        c.userInfo = ["chatId": chat.id]
        c.threadIdentifier = chat.id
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: plan.at)
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    /// 角标是全部会话的未读之和。
    static func updateBadge() async {
        guard isOn() else { return }
        let total = ((try? Repo.chats()) ?? []).filter { !$0.muted }.reduce(0) { $0 + $1.unread }
        try? await UNUserNotificationCenter.current().setBadgeCount(total)
    }

    // MARK: - 后台刷新：只问服务器有没有新结果

    /// 退到后台时排一次。系统决定什么时候真的叫醒，最早十五分钟后。
    nonisolated static func scheduleRefresh() {
        guard isOn(), BgPush.isOn(), BgPush.device() != nil else { return }
        let r = BGAppRefreshTaskRequest(identifier: refreshId)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    nonisolated static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let job = Task {
            let n = (try? await peekResults()) ?? 0
            task.setTaskCompleted(success: n >= 0)
        }
        task.expirationHandler = { job.cancel() }
    }

    /// 问服务器要结果，把还没弹过的成功那几条弹出来。不确认（ack）、不落库：打开应用时照常取回。
    /// 返回弹了几条。
    nonisolated static func peekResults() async throws -> Int {
        guard isOn(), BgPush.isOn(), BgPush.device() != nil else { return 0 }
        let got = try await BgPush.api("/results")
        var seen = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
        var n = 0
        for r in got["results"]?.array ?? [] where r["status"]?.string == "done" {
            guard let id = r["id"]?.string, !seen.contains(id), let chatId = r["chatId"]?.string else { continue }
            let title = (try? Repo.character(r["charId"]?.string ?? ""))?.displayName ?? "Eiraowo"
            post(chatId: chatId, title: title, text: r["text"]?.string ?? "", id: "bg-\(id)")
            seen.insert(id)
            n += 1
        }
        // 只留最近的几百个，取回过的结果服务器那边已经删了
        UserDefaults.standard.set(Array(seen.suffix(500)), forKey: notifiedKey)
        return n
    }

    // MARK: - 代理

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["chatId"] as? String
        await MainActor.run { if let id { Notifier.shared.openChat = id } }
    }
}
