import Foundation

/// 每段会话最近一轮回复请求发了什么（网页版 ai/trace.js 的 keepLast / lastOf / sectionsOf，ARCHITECTURE 4.776）。
///
/// 会话菜单「上一轮发送的内容」读它：角色说错了生日、不该提的时候提了某件事，用来核对它那一轮到底读到了什么。
/// 「请求记录」要先打开才记，出了事再开已经晚了；这一份不用开：每段会话只留最近一轮，只在内存里（重开应用就没了），
/// 不落库、不随备份走，不调接口。图片只记「有一张」，不把图抄进来。换接口重试时记的是最后一次真正发出的那一份。
///
/// 谁要记：回复请求在发之前包一层 `LastSent.$chat.withValue(chatId)`，AIService 每发一次就记一次。
final class LastSent: @unchecked Sendable {
    struct Msg: Equatable, Sendable {
        var role: String
        var content: String
        var images: Int
    }

    struct Row: Equatable, Sendable {
        var at: Date
        var preset: String
        var model: String
        var system: String
        var messages: [Msg]
    }

    struct Section: Equatable, Sendable {
        var head: String
        var text: String
    }

    /// 这一次请求是哪段会话的回复（不是回复的请求为 nil，不记）
    @TaskLocal static var chat: String?

    static let shared = LastSent()
    /// 有新的一轮记下时发（object 是会话 id），打开着的那一页跟着刷新
    static let didKeep = Notification.Name("eira.lastSent.kept")

    private let lock = NSLock()
    private var byChat: [String: Row] = [:]

    func keep(_ chatId: String, preset: String, model: String, system: String, messages: [AIMessage], at: Date = Date()) {
        guard !chatId.isEmpty else { return }
        let row = Row(at: at, preset: preset, model: model, system: system,
                      messages: messages.map { Msg(role: $0.role.rawValue, content: $0.content, images: $0.images.count) })
        lock.lock()
        byChat[chatId] = row
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didKeep, object: chatId) }
    }

    func last(_ chatId: String) -> Row? {
        lock.lock(); defer { lock.unlock() }
        return byChat[chatId]
    }

    func clear() {
        lock.lock(); byChat = [:]; lock.unlock()
    }

    /// system 按区块抬头（`[对方是谁]` 这种单独一行的）切开，查看页一块一块折叠。抬头之前的那段叫「开头」
    static func sections(_ text: String) -> [Section] {
        var out: [Section] = []
        var head = "开头"
        var lines: [String] = []
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { out.append(Section(head: head, text: body)) }
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isHead(t) {
                flush()
                head = String(t.dropFirst().dropLast())
                lines = []
            } else {
                lines.append(line)
            }
        }
        flush()
        return out
    }

    /// 网页版的 /^\[[^\]\n]{1,20}\]$/：方括号里 1 到 20 个字，中间没有右括号
    static func isHead(_ t: String) -> Bool {
        guard t.count >= 3, t.first == "[", t.last == "]" else { return false }
        let inner = t.dropFirst().dropLast()
        return inner.count <= 20 && !inner.contains("]")
    }

    /// 插在聊天记录里的那条设定（现在几点、对方的日程……）含哪几块：标题上写出来
    static func headsOf(_ m: Msg) -> String {
        guard m.role == "system" else { return "" }
        let hs = sections(m.content).map(\.head).filter { $0 != "开头" }
        return hs.isEmpty ? "" : "（" + hs.joined(separator: "、") + "）"
    }

    static func roleLabel(_ role: String) -> String {
        ["system": "设定", "user": "你", "assistant": "角色"][role] ?? role
    }

    /// 复制出去的整段文字
    static func text(_ r: Row) -> String {
        let body = r.messages.enumerated().map { i, m in
            "--- \(i + 1) · \(roleLabel(m.role))\(m.images > 0 ? " · 含图片" : "") ---\n\(m.content)"
        }.joined(separator: "\n\n")
        return "=== system ===\n\(r.system)\n\n=== 聊天记录 ===\n\(body)"
    }
}
