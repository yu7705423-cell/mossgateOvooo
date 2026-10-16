import SwiftUI

@main
struct EiraApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        CrashCollector.shared.start()
        Theme.install()
        let info = Bundle.main.infoDictionary ?? [:]
        // 后台刷新的任务要在启动完成之前登记
        Notifier.shared.install()
        Diagnostics.shared.record("launch", ["version": info["CFBundleShortVersionString"] as? String ?? "?",
                                             "build": info["CFBundleVersion"] as? String ?? "?"])
    }

    var body: some Scene {
        WindowGroup {
            RootView().eiraLook()
        }
        // 主动发起对话与后台消息跟着前后台走：前台本机发，后台交给服务器（BgPush）
        .onChange(of: phase) { _, p in
            MemWatch.scene(p)   // 记忆总结的「离开会话后」「隔夜」两条触发（默认都关）
            switch p {
            case .active:
                BgPush.shared.didBecomeActive()
                HealthSync.didBecomeActive()   // 吃药提醒重排、从「健康」自动同步（只在同步成功过一次之后）
            case .background:
                BgPush.shared.didEnterBackground()
                Notifier.scheduleRefresh()
                Task { await Notifier.updateBadge() }
            default: break
            }
        }
    }
}
