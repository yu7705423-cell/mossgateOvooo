import Foundation
import UserNotifications

/// 待办的提醒（网页版 system/alarm.js，ARCHITECTURE 4.104e）。
///
/// 交给系统的有两条路（SystemAlarm）：iOS 26 起有系统闹钟（AlarmKit，穿透静音与专注模式，应用没在运行也照响），
/// 有它且闹钟权限没有被拒时用它；否则交给系统的本地通知（关掉应用也会在那个时刻弹出，不穿透静音与专注模式）。
/// 记号沿用网页版的字段：排上了记 alarmId（系统闹钟是按待办 id 散出来的 UUID，与网页版外壳同一种散法；
/// 本地通知是「todo-待办 id」）与 alarmAt（排出去的是哪个时刻）。一定要系统接下了才写 alarmId，接不下就照实说，不虚报「已排入」。
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

    enum Status: String, Sendable { case granted, denied, notDetermined, unsupported }

    // MARK: - 交给哪一条路

    /// 测试里换成假的两条路（kit 为空表示这台设备没有系统闹钟）
    nonisolated(unsafe) static var testChannels: (kit: AlarmChannel?, notify: AlarmChannel)?

    static var kitChannel: AlarmChannel? { testChannels.map { $0.kit } ?? SystemAlarm.kit }
    static var notifyChannel: AlarmChannel { testChannels?.notify ?? NotifyAlarm() }

    /// 这一次交给哪一条：有系统闹钟、且闹钟权限没有被拒，就用系统闹钟；否则用通知
    static func channel() async -> AlarmChannel {
        if let kit = kitChannel, await kit.status() != .denied { return kit }
        return notifyChannel
    }

    /// 系统闹钟排出来的编号是 UUID；本地通知的是 todo- 开头
    static func isKitId(_ alarmId: String) -> Bool { UUID(uuidString: alarmId) != nil }

    /// 待办的 id 是 td_xxx 这种，不是 UUID：按内容散成一个固定的 UUID（FNV-1a 铺满十六个字节，与网页版外壳 AlarmBridge.uuid 同一种散法）。
    /// 同一条待办每次都散出同一个，撤的时候才找得回它
    static func uuid(from id: String) -> UUID {
        if let direct = UUID(uuidString: id) { return direct }
        let bytes = Array(id.utf8)
        var a: UInt64 = 0xcbf29ce484222325
        for b in bytes { a = (a ^ UInt64(b)) &* 0x100000001b3 }
        var b2: UInt64 = a
        for b in bytes.reversed() { b2 = (b2 ^ UInt64(b)) &* 0x100000001b3 }
        var out = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: a.bigEndian) { for (i, x) in $0.enumerated() { out[i] = x } }
        withUnsafeBytes(of: b2.bigEndian) { for (i, x) in $0.enumerated() { out[8 + i] = x } }
        return UUID(uuid: (out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7],
                           out[8], out[9], out[10], out[11], out[12], out[13], out[14], out[15]))
    }

    /// 这一次用的那条路的授权状态
    static func status() async -> Status { await channel().status() }

    /// 这一次用的那条路现在叫什么（对账页上写明）
    static func channelName() async -> String { await channel().kind == "alarm" ? "系统闹钟" : "系统通知" }

    /// 系统那张询问表
    @discardableResult
    static func request() async -> Bool { await channel().request() == .granted }

    /// 系统里现在挂着的本应用排的待办提醒（编号）：两条路的都算
    static func listNative() async -> [String] {
        var ids = await notifyChannel.list()
        if let kit = kitChannel { ids += await kit.list() }
        return ids
    }

    struct Pair: Identifiable { var id: String; var text: String; var at: Double; var known: Bool }

    /// 逐条对账：本应用记着排了的那几条，系统那边认不认
    static func reconcile(_ ids: [String]?) -> [Pair] {
        let sys = Set(ids ?? [])
        return Todo.all().filter { !$0.alarmId.isEmpty }
            .map { Pair(id: $0.id, text: $0.text, at: timeOf($0), known: sys.contains($0.alarmId)) }
            .sorted { $0.at < $1.at }
    }

    /// scheduled：排进了系统通知；alarmed：排进了系统闹钟
    enum Outcome: Equatable { case scheduled, alarmed, past, gone, denied, failed(String) }

    /// 给这条待办排一个系统闹钟或系统提醒。没问过授权的先问一次；系统闹钟被拒了就退回通知
    @discardableResult
    static func schedule(_ id: String, now: Date = Date()) async -> Outcome {
        guard let row = Todo.get(id) else { return .gone }
        let ms = timeOf(row)
        guard isFuture(ms, now: now) else { return .past }
        var ch = await channel()
        var st = await ch.status()
        if st == .notDetermined { st = await ch.request() }
        if st != .granted && ch.kind == "alarm" {
            ch = notifyChannel
            st = await ch.status()
            if st == .notDetermined { st = await ch.request() }
        }
        guard st == .granted else { return .denied }
        let aid: String
        do { aid = try await ch.add(todoId: id, title: row.text, at: Date(millis: ms)) }
        catch { return .failed(error.localizedDescription) }
        do { try Todo.update(id, ["alarmId": .string(aid), "alarmAt": .number(ms)]) }
        catch {
            ch.remove(todoId: id, alarmId: aid)
            return .failed("提醒已排入系统，但记号未能保存：\(error.localizedDescription)")
        }
        return ch.kind == "alarm" ? .alarmed : .scheduled
    }

    /// 只撤系统里那一条，不动记录（删除时用）。两条路都撤：以前排的可能走的是另一条
    static func unschedule(_ id: String) {
        let aid = Todo.get(id)?.alarmId ?? ""
        notifyChannel.remove(todoId: id, alarmId: aid)
        kitChannel?.remove(todoId: id, alarmId: isKitId(aid) ? aid : uuid(from: id).uuidString)
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
        case .alarmed: return "已排入系统闹钟，\(When.show(ms)) 响铃"
        case .past: return "该时刻已经过去，未排入系统提醒"
        case .gone: return "这条待办已被删除"
        case .denied: return "未获得闹钟或通知权限，未排入系统。可在系统设置中允许本应用使用闹钟或发送通知"
        case .failed(let e): return "未能排入系统提醒：\(e)"
        }
    }
}
