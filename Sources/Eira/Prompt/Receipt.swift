import Foundation

/// 消息上的时刻与已读回执（网页版 system/receipt.js，ARCHITECTURE 4.112）。
///
/// 「已读」= 角色开始生成回复的那一瞬：它动笔了，就是看见了；一直没回，就一直是未读。只给自己发的消息打。
/// 绝大多数已读不存，是推出来的：最后一条角色消息之前的都看过了，只有它之后发的那几条才记 readAt。
enum Receipt {
    /// 已读回执，默认关
    static func on(_ s: AppSettings) -> Bool { s.raw["msgRead"]?.bool == true }

    /// 时刻怎么显示：gap 按间隔在两条中间插一行（默认）、side 每条旁边、below 每条下方、off 不显示
    static let stamps: [(id: String, label: String)] = [("gap", "按间隔"), ("side", "每条旁边"), ("below", "每条下方"), ("off", "不显示")]
    static func stampMode(_ s: AppSettings) -> String {
        let v = s.raw["msgStamp"]?.string ?? ""
        return ["gap", "side", "below", "off"].contains(v) ? v : "gap"
    }

    /// 相隔多久才写一行时间
    static let sepGap: Double = 5 * 60_000

    /// 两条消息中间要不要写一行时间。第一条总是写
    static func needSep(prev: Message?, cur: Message) -> Bool {
        guard cur.createdAt > 0 else { return false }
        guard let prev, prev.createdAt > 0 else { return true }
        return cur.createdAt - prev.createdAt >= sepGap
    }

    // 每一行消息都要算一次，格式化器只建一个（建一个 DateFormatter 的开销比格式化本身大得多）
    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func hm(_ d: Date) -> String { hmFormatter.string(from: d) }

    /// 分隔行上的时间：今天只写时分，昨天写「昨天」，一周内写星期，今年写月日，更早的带年份
    static func sepOf(_ ms: Double, now: Date = Date()) -> String {
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        let t = hm(d)
        if days <= 0 { return t }
        if days == 1 { return "昨天 \(t)" }
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: d)
        if days < 7 { return "\(["周日", "周一", "周二", "周三", "周四", "周五", "周六"][((c.weekday ?? 1) - 1) % 7]) \(t)" }
        if c.year == cal.component(.year, from: now) { return "\(c.month ?? 1)月\(c.day ?? 1)日 \(t)" }
        return "\(c.year ?? 0)年\(c.month ?? 1)月\(c.day ?? 1)日 \(t)"
    }

    /// 气泡上的时刻：当天只写时分，隔天带上日期
    static func stampOf(_ ms: Double, now: Date = Date()) -> String {
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        if d >= Calendar.current.startOfDay(for: now) { return hm(d) }
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 1)月\(c.day ?? 1)日 \(hm(d))"
    }

    /// 这段会话里最后一条角色消息的时刻。在它之前发出去的，都已经被看过了
    static func readUpTo(_ msgs: [Message]) -> Double {
        msgs.filter { $0.role == .char }.map(\.createdAt).max() ?? 0
    }

    /// 角色动笔之前：把此刻还悬着的那几条标成已读。已经标过的不再动
    @discardableResult
    static func markRead(chatId: String, at: Double = Date().millis) throws -> Int {
        let msgs = try Repo.messages(chatId: chatId, limit: 200)
        let line = readUpTo(msgs)
        var n = 0
        for m in msgs where m.role == .user && m.row["readAt"] == nil && m.createdAt > line {
            var row = m.row
            row["readAt"] = .number(at)
            try Database.shared.put(Collections.messages, row)
            n += 1
        }
        return n
    }

    /// 这一条该显示什么：不是自己发的或者回执关着，回来空字符串
    static func textOf(_ m: Message, upTo: Double, on: Bool) -> String {
        guard on, m.role == .user else { return "" }
        return (m.row["readAt"]?.number != nil || m.createdAt <= upTo) ? "已读" : "未读"
    }

    /// 同一个人接着说的那一条（3 分钟内、都是说的话）：和上一条之间收紧
    static func cont(prev: Message?, cur: Message) -> Bool {
        guard let prev else { return false }
        let talk: (Message) -> Bool = { $0.kind != "notice" && $0.kind != "scene" }
        return talk(prev) && talk(cur) && prev.role == cur.role && prev.authorId == cur.authorId
            && cur.createdAt - prev.createdAt < 3 * 60_000
    }
}
