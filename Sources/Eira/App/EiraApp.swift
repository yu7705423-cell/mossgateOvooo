import SwiftUI

@main
struct EiraApp: App {
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
    }
}
