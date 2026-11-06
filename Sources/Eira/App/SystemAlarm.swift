import Foundation
import SwiftUI
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

/// 待办的提醒交给系统的两条路（网页版 system/alarm.js 与外壳 AlarmBridge，ARCHITECTURE 4.104e）：
/// - 系统闹钟（AlarmKit，iOS 26 起）：和「时钟」里自己定的闹钟同一套，穿透静音与专注模式，应用没在运行也照响。
///   不要 entitlement，只要 Info.plist 的 NSAlarmKitUsageDescription 加一次运行时授权；
/// - 系统通知：iOS 26 以前、或闹钟权限被拒时。到点弹一条通知，不穿透静音与专注模式。
/// 有系统闹钟且没有被拒就用它，否则退回通知。只排固定时刻，不做倒计时（倒计时那一档要配 Live Activity，没有它系统会撤掉闹钟）。
/// 编译用的 SDK 里没有 AlarmKit 时整段不编，照实说「这套构建里没有」。
protocol AlarmChannel: Sendable {
    /// alarm：系统闹钟；notify：系统通知
    var kind: String { get }
    func status() async -> TodoAlarm.Status
    /// 要授权。弹的是系统那张询问表
    func request() async -> TodoAlarm.Status
    /// 排一个，回系统那边的编号（写进待办的 alarmId）
    func add(todoId: String, title: String, at: Date) async throws -> String
    func remove(todoId: String, alarmId: String)
    /// 系统里现在挂着的本应用排的编号
    func list() async -> [String]
}

/// 系统通知那一条
struct NotifyAlarm: AlarmChannel {
    var kind: String { "notify" }

    func status() async -> TodoAlarm.Status {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unsupported
        }
    }

    func request() async -> TodoAlarm.Status {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        return await status()
    }

    func add(todoId: String, title: String, at: Date) async throws -> String {
        let c = UNMutableNotificationContent()
        c.title = "待办"
        c.body = title
        c.sound = .default
        c.threadIdentifier = "todo"
        c.userInfo = ["app": "todo"]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        let nid = TodoAlarm.noteId(todoId)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: nid, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        return nid
    }

    func remove(todoId: String, alarmId: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [TodoAlarm.noteId(todoId)])
    }

    func list() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(TodoAlarm.prefix) }
    }
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct TodoAlarmMeta: AlarmMetadata {
    init() {}
}

/// 系统闹钟那一条（iOS 26）
@available(iOS 26.0, *)
struct KitAlarm: AlarmChannel {
    var kind: String { "alarm" }

    func status() async -> TodoAlarm.Status {
        switch AlarmManager.shared.authorizationState {
        case .authorized: return .granted
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    /// 第一次弹询问表时 requestAuthorization 可能当场抛出（人还在看那张表）。抛完不当场认输：
    /// 隔半秒读一次系统的状态，读到允许就继续，读到拒绝才算拒绝，最多等三十秒（网页版外壳 ensureAuth 同样）
    func request() async -> TodoAlarm.Status {
        if AlarmManager.shared.authorizationState == .authorized { return .granted }
        _ = try? await AlarmManager.shared.requestAuthorization()
        for _ in 0..<60 {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return .granted
            case .denied: return .denied
            default: break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .notDetermined
    }

    func add(todoId: String, title: String, at: Date) async throws -> String {
        let uuid = TodoAlarm.uuid(from: todoId)
        let stop = AlarmButton(text: LocalizedStringResource(stringLiteral: "停止"), textColor: .white, systemImageName: "stop.fill")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title.isEmpty ? "待办" : title), stopButton: stop)
        let attributes = AlarmAttributes<TodoAlarmMeta>(presentation: AlarmPresentation(alert: alert), metadata: TodoAlarmMeta(),
                                                        tintColor: Color.primary)
        let config = AlarmManager.AlarmConfiguration<TodoAlarmMeta>(schedule: .fixed(at), attributes: attributes)
        _ = try await AlarmManager.shared.schedule(id: uuid, configuration: config)
        return uuid.uuidString
    }

    func remove(todoId: String, alarmId: String) {
        try? AlarmManager.shared.cancel(id: UUID(uuidString: alarmId) ?? TodoAlarm.uuid(from: todoId))
    }

    func list() async -> [String] {
        ((try? AlarmManager.shared.alarms) ?? []).map { $0.id.uuidString }
    }
}
#endif

enum SystemAlarm {
    /// 这套构建里有没有系统闹钟，系统够不够新
    static var kit: AlarmChannel? {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return KitAlarm() }
        #endif
        return nil
    }

    /// 没有系统闹钟时的原因
    static var kitWhy: String {
        #if canImport(AlarmKit)
        return "系统闹钟需要 iOS 26 或更新的系统"
        #else
        return "这个版本的构建里没有系统闹钟"
        #endif
    }
}
