import UIKit

/// 系统只经 UIApplicationDelegate 交来的几件事：推送地址（EiraPush），以及启动时就要接上的来电推送与系统来电界面。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 来电推送叫醒应用时，PushKit 要在启动时就接上，系统来电界面也要马上报得出来
        SystemCall.shared.attach()
        EiraPush.shared.attach()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        EiraPush.shared.didRegister(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        EiraPush.shared.didFail(error)
    }
}
