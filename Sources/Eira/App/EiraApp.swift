import SwiftUI

@main
struct EiraApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        CrashCollector.shared.start()
        let info = Bundle.main.infoDictionary ?? [:]
        Diagnostics.shared.record("launch", ["version": info["CFBundleShortVersionString"] as? String ?? "?",
                                             "build": info["CFBundleVersion"] as? String ?? "?"])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        // 主动发起对话与后台消息跟着前后台走：前台本机发，后台交给服务器（BgPush）
        .onChange(of: phase) { _, p in
            switch p {
            case .active: BgPush.shared.didBecomeActive()
            case .background: BgPush.shared.didEnterBackground()
            default: break
            }
        }
    }
}
