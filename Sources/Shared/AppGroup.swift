import Foundation

/// 应用与两个扩展（通知扩展 .notify、桌面组件 .widgets）共用的那一块地方：App Group `group.<应用的包标识>`。
///
/// 这一份源文件同时编进应用和两个扩展（project.yml 里三个 target 都列着 Sources/Shared），所以这里只用扩展里也能用的接口。
/// 包标识没有分到这个 App Group 时（开发者网站上没勾，见 docs/system-abilities.md），UserDefaults 照样能写能读，
/// 但那是各自沙盒里的一份，别的进程读不到；容器路径（`container`）是空的，据此判断「真的共用了没有」。
enum AppGroup {
    static let extensionSuffixes = [".notify", ".widgets"]

    /// 应用本身的包标识。在扩展里去掉最后那一段
    static var appBundleId: String {
        let me = Bundle.main.bundleIdentifier ?? "cn.eiraphone.native"
        for s in extensionSuffixes where me.hasSuffix(s) { return String(me.dropLast(s.count)) }
        return me
    }

    static var id: String { "group." + appBundleId }

    static var defaults: UserDefaults? { UserDefaults(suiteName: id) }

    /// 共用目录。分不到 App Group 时为空
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }

    static var shared: Bool { container != nil }
}
