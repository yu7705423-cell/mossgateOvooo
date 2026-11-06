import Foundation
import PushKit
import UIKit
import UserNotifications

/// Eira 推送（网页版 ARCHITECTURE 4.896、4.948；外壳那头是 PushBridge 与 NotifyService）：应用关着时角色的消息与来电。
///
/// 后台消息服务器（BgPush，用户自己部署的 worker/push.js）替角色开口之后，经维护者的推送转发（worker/apns.js）请苹果叫醒手机：
/// 文字消息是锁屏上的通知（通知扩展 EiraNotify 在手机上解密后显示），来电是系统来电（SystemCall）。
///
/// 这里做的是登记：
/// - 要两个推送地址：普通推送（registerForRemoteNotifications）与来电推送（PushKit）；
/// - 拿推送地址去转发服务换一个签名（POST /register { token, kind } 回 { cred }），转发服务不存任何东西；
/// - 加密钥匙：第一次要时现生成 32 字节，存在本机并抄一份进 App Group 给通知扩展读；
/// - 三样一起写进后台消息的通知通道（kind 'eira'，和网页版一字不差），跟着下一次交任务交给用户自己的服务器。
///   **钥匙只交给用户自己的服务器**，转发服务只见过推送地址；聊天内容在用户的服务器上加密，转发看到的只有密文。
/// 登记记在本机（推送地址只对这一台手机、这一只 app 有效），不进设置、不进备份：导入网页版备份不会带进别的设备的登记。
///
/// 不调模型、不多花钱：消息照旧由服务器那一次调用产生（第 15 条的交接规矩不变），这里只决定结果怎样送到手机上。
@MainActor
final class EiraPush: NSObject, ObservableObject {
    static let shared = EiraPush()

    /// 维护者为原生版部署的推送转发（worker/apns.js，APNS_TOPIC 为 cn.eiraphone.native）。留空时由用户在页面上填写。
    /// 网页版那一台的 topic 是网页版外壳的包标识，原生版的推送地址交给它，苹果会回 DeviceTokenNotForTopic
    nonisolated static let siteRelay = ""

    nonisolated private static let regKey = "eira-push-reg"
    nonisolated private static let relayKey = "eira-push-relay"
    nonisolated private static let wantedKey = "eira-push-wanted"
    nonisolated private static let alertKey = "eira-push-alert"
    nonisolated private static let voipKey = "eira-push-voip"

    struct Tok: Codable, Equatable { var token: String; var cred: String }

    /// 本机的登记
    struct Reg: Codable, Equatable {
        var relay: String
        var alert: Tok
        var voip: Tok?
        var at: Double
    }

    @Published private(set) var busy = false
    @Published private(set) var problem = ""
    private var registry: PKPushRegistry?
    private var waiting: [CheckedContinuation<String?, Never>] = []

    // MARK: - 本机记着的

    nonisolated static func relay() -> String {
        let v = UserDefaults.standard.string(forKey: relayKey) ?? siteRelay
        return v.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    }

    nonisolated static func setRelay(_ v: String) { UserDefaults.standard.set(v, forKey: relayKey) }

    nonisolated static func relayOk(_ r: String = relay()) -> Bool {
        r.range(of: #"^https://[^/\s]+"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    nonisolated static func registration() -> Reg? {
        guard let d = UserDefaults.standard.data(forKey: regKey) else { return nil }
        return try? JSONDecoder().decode(Reg.self, from: d)
    }

    nonisolated static func setRegistration(_ r: Reg?) {
        if let r, let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: regKey) }
        else { UserDefaults.standard.removeObject(forKey: regKey) }
    }

    nonisolated static var systemAlertToken: String? { UserDefaults.standard.string(forKey: alertKey) }
    nonisolated static var systemVoipToken: String? { UserDefaults.standard.string(forKey: voipKey) }

    /// 加密钥匙（base64，32 字节）。存在本机，并抄一份进 App Group 给通知扩展读
    @discardableResult
    nonisolated static func key() -> String {
        var k = UserDefaults.standard.string(forKey: PushBox.keyName) ?? ""
        if Data(base64Encoded: k)?.count != 32 {
            k = PushBox.newKey()
            UserDefaults.standard.set(k, forKey: PushBox.keyName)
        }
        if let g = AppGroup.defaults, g.string(forKey: PushBox.keyName) != k { g.set(k, forKey: PushBox.keyName) }
        return k
    }

    /// 后台消息的通知通道选的是不是 Eira 推送
    nonisolated static func selected(_ s: AppSettings = .load()) -> Bool {
        BgPush.config(s)["channel"]?.object?["kind"]?.string == "eira"
    }

    /// 选着、登记过：服务器到点替角色开口之后由它推送
    nonisolated static func active(_ s: AppSettings = .load()) -> Bool { selected(s) && registration() != nil }

    /// 交给服务器的通道（网页版 bgpush.channelOut 的 eira 那一支）。ring：开着系统来电界面时，回复里有来电就发来电推送
    nonisolated static func channel(_ s: AppSettings = .load()) -> JSONValue {
        guard selected(s), let r = registration(), !r.relay.isEmpty else { return .null }
        var o: [String: JSONValue] = [
            "kind": .string("eira"), "relay": .string(r.relay), "key": .string(key()),
            "alert": .object(["token": .string(r.alert.token), "cred": .string(r.alert.cred)]),
            "hide": .bool(!Notifier.showsText(s)), "ring": .bool(SystemCall.isOn(s)),
        ]
        if let v = r.voip { o["voip"] = .object(["token": .string(v.token), "cred": .string(v.cred)]) }
        return .object(o)
    }

    // MARK: - 与推送转发之间

    struct RelayError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    nonisolated private static func post(_ url: String, _ body: [String: String]) async throws -> JSONValue {
        guard let u = URL(string: url) else { throw RelayError(message: "推送转发的地址无效") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw RelayError(message: "连不上推送转发，检查网络后再试") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONValue.parse(data)) ?? .object([:])
        guard (200..<300).contains(status) else {
            throw RelayError(message: j["error"]?.string ?? j["reason"]?.string ?? "推送转发返回 \(status)")
        }
        return j
    }

    /// 拿推送地址去转发服务换签名
    nonisolated static func sign(relay: String, kind: String, token: String) async throws -> String {
        let j = try await post(relay + "/register", ["token": token, "kind": kind])
        guard let cred = j["cred"]?.string, !cred.isEmpty else { throw RelayError(message: "推送转发没有登记成功") }
        return cred
    }

    /// 两个推送地址各换一个签名。来电推送的地址没有时只登记文字通知
    nonisolated static func signBoth(relay: String, alert: String, voip: String?) async throws -> Reg {
        let a = try await sign(relay: relay, kind: "alert", token: alert)
        var v: Tok?
        if let voip, !voip.isEmpty { v = Tok(token: voip, cred: try await sign(relay: relay, kind: "voip", token: voip)) }
        return Reg(relay: relay, alert: Tok(token: alert, cred: a), voip: v, at: Date().millis)
    }

    /// 让转发服务推一条不带内容的测试通知（只经过转发，不经过后台消息服务器）
    nonisolated static func test() async throws {
        guard let r = registration() else { throw RelayError(message: "尚未登记") }
        let j = try await post(r.relay + "/test", ["token": r.alert.token, "cred": r.alert.cred, "kind": "alert"])
        guard j["ok"]?.bool == true else { throw RelayError(message: "没有推出去：\(j["reason"]?.string ?? j["error"]?.string ?? "原因不明")") }
    }

    // MARK: - 推送地址

    /// 启动时叫：PushKit 要在启动时就接上，应用被来电推送叫醒时才接得住。登记过的，普通推送的地址也重新要一次（地址会变）
    func attach() {
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        r.desiredPushTypes = [.voIP]
        registry = r
        if UserDefaults.standard.bool(forKey: Self.wantedKey) { UIApplication.shared.registerForRemoteNotifications() }
        if Self.registration() != nil { Self.key() }
    }

    func didRegister(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: Self.alertKey)
        let w = waiting
        waiting = []
        w.forEach { $0.resume(returning: hex) }
        refreshIfChanged()
    }

    func didFail(_ error: Error) {
        problem = "系统没有给推送地址：\(error.localizedDescription)"
        let w = waiting
        waiting = []
        w.forEach { $0.resume(returning: nil) }
    }

    fileprivate func voipUpdated(_ hex: String?) {
        if let hex { UserDefaults.standard.set(hex, forKey: Self.voipKey) } else { UserDefaults.standard.removeObject(forKey: Self.voipKey) }
        refreshIfChanged()
    }

    /// 地址变了（系统会换）：登记过的重新换签名，并把新的通道交给服务器
    private func refreshIfChanged() {
        guard let reg = Self.registration(), !busy else { return }
        let alert = Self.systemAlertToken ?? reg.alert.token
        let voip = Self.systemVoipToken
        guard alert != reg.alert.token || voip != reg.voip?.token else { return }
        Task {
            do {
                Self.setRegistration(try await Self.signBoth(relay: reg.relay, alert: alert, voip: voip))
                if BgPush.isOn() { _ = try? await BgPush.plan(away: false) }
            } catch {
                problem = "推送地址已更换，重新登记未成功：\(error.localizedDescription)"
            }
        }
    }

    private func alertToken(wait seconds: Double) async -> String? {
        await withCheckedContinuation { cont in
            waiting.append(cont)
            UIApplication.shared.registerForRemoteNotifications()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                let w = EiraPush.shared.waiting
                EiraPush.shared.waiting = []
                w.forEach { $0.resume(returning: nil) }
            }
        }
    }

    // MARK: - 登记与停用

    /// 登记：要通知权限、要推送地址、去转发服务换签名，选为后台消息的通知通道
    func register() async throws {
        let relay = Self.relay()
        guard Self.relayOk(relay) else { throw RelayError(message: "请先填写推送转发的地址（https 开头）") }
        busy = true
        problem = ""
        defer { busy = false }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { throw RelayError(message: "未获得通知权限。可在系统「设置 - 通知 - Eiraowo」中允许后再登记") }
        UserDefaults.standard.set(true, forKey: Self.wantedKey)
        guard let alert = await alertToken(wait: 10) else {
            throw RelayError(message: problem.isEmpty ? "等了 10 秒，系统没有给推送地址。这个安装包可能没有推送权限（需要 TestFlight 版）" : problem)
        }
        var voip = Self.systemVoipToken
        if voip == nil {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            voip = Self.systemVoipToken
        }
        Self.key()
        let reg = try await Self.signBoth(relay: relay, alert: alert, voip: voip)
        Self.setRegistration(reg)
        SettingsModel.shared.update { s in
            var c = BgPush.config(s)
            var ch = c["channel"]?.object ?? [:]
            ch["kind"] = .string("eira")
            c["channel"] = .object(ch)
            s.raw["bgPush"] = .object(c)
        }
        if BgPush.isOn() { _ = try? await BgPush.plan(away: false) }
    }

    /// 停用：通知通道不再选它，本机的登记删掉；下一次交任务时服务器那边随之关掉
    func unregister() async {
        Self.setRegistration(nil)
        UserDefaults.standard.set(false, forKey: Self.wantedKey)
        SettingsModel.shared.update { s in
            var c = BgPush.config(s)
            var ch = c["channel"]?.object ?? [:]
            if ch["kind"]?.string == "eira" { ch["kind"] = .string("") }
            c["channel"] = .object(ch)
            s.raw["bgPush"] = .object(c)
        }
        if BgPush.isOn() { _ = try? await BgPush.plan(away: false) }
    }
}

// MARK: - 来电推送

extension EiraPush: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated { EiraPush.shared.voipUpdated(hex) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        MainActor.assumeIsolated { EiraPush.shared.voipUpdated(nil) }
    }

    /// 来电推送到了：解开盒子，报一通系统来电。苹果规定每一条都必须马上报，不报的话系统会结束应用、多次之后不再投递
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType, completion: @escaping () -> Void) {
        let ring = PushBox.ring(PushBox.open(payload.dictionaryPayload, key: EiraPush.key()))
        MainActor.assumeIsolated { SystemCall.shared.reportPushed(ring, completion: completion) }
    }
}
