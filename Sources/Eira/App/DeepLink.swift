import Foundation

/// 从应用外面点进来的链接（`eiraowo://`）：桌面组件、通知。
///
///   eiraowo://chat/<会话>            打开那段会话
///   eiraowo://open?app=<app>         打开某个 app（例如 health）
///   eiraowo://open                   只打开应用
/// 桌面组件的按钮在系统不支持可交互组件时退回链接：eiraowo://widget/<种类>，打开应用并记下这一下。
enum DeepLink {
    enum Target: Equatable {
        case chat(String)
        case app(String)
        case widgetTap(String)
        case home
    }

    static let scheme = "eiraowo"

    static func parse(_ url: URL) -> Target? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let host = url.host ?? ""
        let first = url.pathComponents.filter { $0 != "/" }.first ?? ""
        switch host {
        case "chat": return first.isEmpty ? .app("chat") : .chat(first)
        case "widget": return WidgetStore.tapKinds.contains(first) ? .widgetTap(first) : nil
        case "open":
            let app = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "app" }?.value ?? ""
            return app.isEmpty ? .home : .app(app)
        default: return nil
        }
    }

    @MainActor
    static func handle(_ url: URL) {
        switch parse(url) {
        case .chat(let id): Notifier.shared.openChat = id
        case .app(let app): Notifier.shared.openApp = app
        case .widgetTap(let kind):
            WidgetStore.group.record(kind)
            WidgetFeed.wake()
            Notifier.shared.openApp = "health"
        case .home, nil: break
        }
    }
}
