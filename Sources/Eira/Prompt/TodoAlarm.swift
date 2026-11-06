import Foundation
import UserNotifications

/// 待办的提醒（网页版 system/alarm.js，ARCHITECTURE 4.104e）。
///
/// 网页版在 App 外壳里交给 AlarmKit（iOS 26），浏览器里只在开着时提醒。原生版交给系统的本地通知：
/// 关掉应用也会在那个时刻弹出（不穿透静音与专注模式，这一点与系统闹钟不同，界面上照实写）。
/// 记号沿用网页版的字段：排上了记 alarmId（本地通知的编号「todo-待办 id」）与 alarmAt（排出去的是哪个时刻）。
/// 一定要系统接下了才写 alarmId，接不下就照实说，不虚报「已排入」。
///
/// 应用开着时另有一道：一分钟看一次表，到点而没有排进系统的那几条当场弹一条通知（rungAt 记下，只响一次）。
enum TodoAlarm {
    static let prefix = "todo-"
    static func noteId(_ todoId: String) -> String { prefix + todoId }

    static func timeOf(_ r: Todo.Item) -> Double { r.remindAt }
    static func isFuture(_ ms: Double, now: Date = Date()) -> Bool { ms > now.millis }

    /// 排出去的那个时刻和现在填的还是不是同一个。改过就得重排
    static func stale(_ r: Todo.Item) -> Bool { !r.alarmId.isEmpty && r.alarmAt != timeOf(r) }

    /// 挂着时刻、还没到、也还没做完的那几条
    static func upcoming(now: Date = Date()) -> [Todo.Item] {
        Todo.all().filter { $0.state == Todo.open && isFuture(timeOf($0), now: now) }.sorted { timeOf($0) < timeOf($1) }
    }

    /// 到点了、还没响过的
    static func due(now: Date = Date()) -> [Todo.Item] {
        Todo.all().filter { $0.state == Todo.open && timeOf($0) > 0 && timeOf($0) <= now.millis && $0.rungAt == 0 }
    }

    enum Status: String { case granted, denied, notDetermined, unsupported }

    static func status() async -> Status {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unsupported
        }
    }

    /// 系统那张询问表
    @discardableResult
    static func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 系统里现在挂着的本应用排的待办提醒（编号）
    static func listNative() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
    }

    struct Pair: Identifiable { var id: String; var text: String; var at: Double; var known: Bool }

    /// 逐条对账：本应用记着排了的那几条，系统那边认不认
    static func reconcile(_ ids: [String]?) -> [Pair] {
        let sys = Set(ids ?? [])
        return Todo.all().filter { !$0.alarmId.isEmpty }
            .map { Pair(id: $0.id, text: $0.text, at: timeOf($0), known: sys.contains($0.alarmId)) }
            .sorted { $0.at < $1.at }
    }

    enum Outcome: Equatable { case scheduled, past, gone, denied, failed(String) }

    /// 给这条待办排一条系统提醒。没问过授权的先问一次
    @discardableResult
    static func schedule(_ id: String, now: Date = Date()) async -> Outcome {
        guard let row = Todo.get(id) else { return .gone }
        let ms = timeOf(row)
        guard isFuture(ms, now: now) else { return .past }
        var st = await status()
        if st == .notDetermined { _ = await request(); st = await status() }
        guard st == .granted else { return .denied }
        let c = UNMutableNotificationContent()
        c.title = "待办"
        c.body = row.text
        c.sound = .default
        c.threadIdentifier = "todo"
        c.userInfo = ["app": "todo"]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: Date(millis: ms))
        let nid = noteId(id)
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: nid, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        } catch {
            return .failed(error.localizedDescription)
        }
        do { try Todo.update(id, ["alarmId": .string(nid), "alarmAt": .number(ms)]) }
        catch {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [nid])
            return .failed("提醒已排入系统，但记号未能保存：\(error.localizedDescription)")
        }
        return .scheduled
    }

    /// 只撤系统里那一条，不动记录（删除时用）
    static func unschedule(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [noteId(id)])
    }

    /// 撤掉系统里那一条，并清掉本地的记号。写不进去时在屏幕上说
    static func cancelLocal(_ id: String) {
        unschedule(id)
        do { _ = try Todo.update(id, ["alarmId": .string(""), "alarmAt": .number(0)]) }
        catch { Problems.report("提醒的记号未能清除：\(error.localizedDescription)") }
    }

    /// 改时刻：先撤旧的再排新的
    static func reschedule(_ id: String, at ms: Double) async -> Outcome {
        cancelLocal(id)
        do { try Todo.update(id, ["remindAt": .number(ms)]) } catch { return .failed(error.localizedDescription) }
        return await schedule(id)
    }

    /// 全撤了
    @discardableResult
    static func cancelAll() -> Int {
        let rows = Todo.all().filter { !$0.alarmId.isEmpty }
        for r in rows { cancelLocal(r.id) }
        return rows.count
    }

    // MARK: - 应用开着时的那一道

    /// 一次看表：到点的记下响过；没排进系统的当场弹一条（排进了的系统自己会弹）
    @discardableResult
    static func beat(now: Date = Date(), ring: (Todo.Item) -> Void = TodoAlarm.post) -> Int {
        var n = 0
        for r in due(now: now) {
            do { try Todo.update(r.id, ["rungAt": .number(now.millis)]) }
            catch { Problems.report("待办的提醒记号未能保存：\(error.localizedDescription)"); continue }
            if r.alarmId.isEmpty { ring(r); n += 1 }
        }
        return n
    }

    static func post(_ r: Todo.Item) {
        let c = UNMutableNotificationContent()
        c.title = "待办"
        c.body = r.text
        c.sound = .default
        c.threadIdentifier = "todo"
        c.userInfo = ["app": "todo"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "todo-now-\(r.id)", content: c, trigger: nil))
    }

    /// 一分钟一次，跟着调用方的 task 走（外壳在 .task 里调，界面关掉即停）
    static func loop() async {
        while !Task.isCancelled {
            beat()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    /// 结果写成一句提示
    static func describe(_ o: Outcome, at ms: Double) -> String {
        switch o {
        case .scheduled: return "已排入系统提醒，\(When.show(ms)) 通知"
        case .past: return "该时刻已经过去，未排入系统提醒"
        case .gone: return "这条待办已被删除"
        case .denied: return "未获得通知权限，未排入系统提醒。可在系统设置中允许本应用发送通知"
        case .failed(let e): return "未能排入系统提醒：\(e)"
        }
    }
}
