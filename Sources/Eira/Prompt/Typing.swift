import Foundation

/// 哪几段会话此刻正在生成（网页版 4.465、4.533）。离开会话页再回来，上一次点的回复可能还在生成：
/// 标题照样写「正在输入」、底栏照样给停止键。主动发起对话正在生成也算。
@MainActor
final class Typing: ObservableObject {
    static let shared = Typing()

    @Published private(set) var active: Set<String> = []
    private var jobs: [String: Task<Void, Never>] = [:]

    func isOn(_ chatId: String) -> Bool { active.contains(chatId) }

    /// 开始生成。job 为空时（主动消息）只亮着，停止键停不掉它
    func begin(_ chatId: String, job: Task<Void, Never>? = nil) {
        active.insert(chatId)
        if let job { jobs[chatId] = job }
    }

    func end(_ chatId: String) {
        active.remove(chatId)
        jobs[chatId] = nil
        NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
    }

    /// 停止键：取消这段会话正在跑的那一次
    func cancel(_ chatId: String) {
        jobs[chatId]?.cancel()
    }
}
