import AVFoundation
import CallKit
import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    /// 系统来电界面上挂断了正在应用里进行的那一通（object 是 chatId）。通话页据此挂断
    static let eiraSystemCallEnded = Notification.Name("eira.systemCallEnded")
}

/// 系统来电界面（网页版 ARCHITECTURE 4.895，外壳那头是 CallKitBridge）：角色打来的电话，你没在看那段会话时
/// 用 iPhone 自己的来电界面响，锁屏上整屏响铃。
///
/// - 只叠加：「设置 - 消息通知 - 系统来电界面」开着（`settings.callKit`，与网页版同一个键，默认关）才用；关着与从前一样，
///   没在看那段会话就记一条未接来电。弹不出来（国区限制、系统报错）照旧记未接，并发一条来电通知；原因记下来，设置页照实写；
/// - 接起来：打开那段会话，通话页直接接通（不再响第二遍）。通话本身照旧在应用里按回合进行；
/// - 拒接记「已拒接」，三十秒没人接记未接，都落一条通话记录（和应用里响铃的结果同一种写法）；
/// - 不进系统「电话」的最近通话（`includesCallsInRecents = false`）：那里是真号码的地方，通话记录在会话里；
/// - 应用关着时由 Eira 推送的来电推送叫醒（EiraPush），这里同样报一通。苹果规定每条来电推送都必须马上报一通来电，
///   解不开也报一通「来电」再马上收掉。
/// 不调任何接口；接通之后每一轮的花费和应用里接起来一样。
@MainActor
final class SystemCall: NSObject, ObservableObject {
    static let shared = SystemCall()
    /// 响多久没人接算未接（网页版外壳同样是三十秒，应用里响铃是二十秒）
    static let ringSec: TimeInterval = 30
    static let testId = "phone-callkit-test"
    static let unknownId = "phone-push-unknown"
    private static let lastKey = "callkit.last"

    nonisolated static func isOn(_ s: AppSettings = .load()) -> Bool { s.raw["callKit"]?.bool == true }

    enum State: String { case ringing, answered, inApp, declined, missed, ended }

    struct Entry {
        var uuid: UUID
        var charId: String
        var video: Bool
        var state: State
        var at: Date
        /// app：应用里读到 [去电] 弹的；push：来电推送叫醒弹的
        var origin: String
    }

    private(set) var calls: [String: Entry] = [:]

    /// 上一次弹没弹出来。error 为空表示弹出来了
    struct Last: Equatable { var ok: Bool; var error: String; var at: Double }
    @Published private(set) var last: Last? = SystemCall.readLast()

    private lazy var provider: CXProvider = {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = true
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        cfg.includesCallsInRecents = false
        let p = CXProvider(configuration: cfg)
        p.setDelegate(self, queue: nil)   // 回调在主线程
        return p
    }()

    /// 启动时叫一下：来电推送叫醒应用时，系统要在启动后很快看到这一通
    func attach() { _ = provider }

    // MARK: - 弹

    /// 弹一通来电。回 nil 表示弹出来了，否则是系统给的原因
    func ring(chatId: String, charId: String, name: String, video: Bool, origin: String = "app") async -> String? {
        await withCheckedContinuation { cont in
            report(chatId: chatId, charId: charId, name: name, video: video, origin: origin) { cont.resume(returning: $0) }
        }
    }

    private func report(chatId: String, charId: String, name: String, video: Bool, origin: String,
                        done: @escaping (String?) -> Void) {
        if let e = calls[chatId], e.state == .ringing || e.state == .answered || e.state == .inApp { done(nil); return }
        let uuid = UUID()
        let up = CXCallUpdate()
        let shown = name.isEmpty ? "来电" : name
        up.remoteHandle = CXHandle(type: .generic, value: shown)
        up.localizedCallerName = shown
        up.hasVideo = video
        up.supportsHolding = false
        up.supportsGrouping = false
        up.supportsUngrouping = false
        up.supportsDTMF = false
        calls[chatId] = Entry(uuid: uuid, charId: charId, video: video, state: .ringing, at: Date(), origin: origin)
        provider.reportNewIncomingCall(with: uuid, update: up) { err in
            Task { @MainActor in
                let me = SystemCall.shared
                if let err {
                    me.calls[chatId] = nil
                    let ns = err as NSError
                    let why = "系统没有弹出来电：\(err.localizedDescription)（\(ns.domain) \(ns.code)）"
                    me.note(why)
                    done(why)
                    return
                }
                me.note(nil)
                done(nil)
                try? await Task.sleep(nanoseconds: UInt64(Self.ringSec * 1_000_000_000))
                guard let e = me.calls[chatId], e.uuid == uuid, e.state == .ringing else { return }
                me.provider.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
                me.settle(chatId, as: .missed)
            }
        }
    }

    /// 来电推送叫醒（EiraPush）：解开了就按那段会话报一通；解不开也必须报一通，报完马上收掉
    func reportPushed(_ ring: PushBox.Ring?, completion: @escaping () -> Void) {
        let chat = ring.flatMap { try? Repo.chat($0.chatId) }
        guard let ring, let chat, !chat.isGroup, let charId = chat.characterIds.first else {
            report(chatId: Self.unknownId, charId: "", name: "来电", video: false, origin: "push") { _ in
                SystemCall.shared.dismiss(Self.unknownId)
                completion()
            }
            return
        }
        let name = ring.name.isEmpty ? ((try? Repo.character(charId))?.displayName ?? "") : ring.name
        report(chatId: chat.id, charId: charId, name: name, video: ring.video, origin: "push") { _ in completion() }
    }

    private func dismiss(_ chatId: String) {
        guard let e = calls.removeValue(forKey: chatId) else { return }
        provider.reportCall(with: e.uuid, endedAt: Date(), reason: .failed)
    }

    // MARK: - 应用里的通话页

    /// 系统界面上接起来、应用里还没接上的那一通：是不是视频。没有回 nil
    func answeredVideo(_ chatId: String) -> Bool? {
        guard let e = calls[chatId], e.state == .answered else { return nil }
        return e.video
    }

    /// 通话页接手这一通（接上了就不再由这里记结果，通话页挂断时自己落通话记录）
    func claim(_ chatId: String) -> Bool {
        guard calls[chatId]?.state == .answered else { return false }
        calls[chatId]?.state = .inApp
        return true
    }

    /// 通话页结束了：系统那边还开着就一起收掉，这一通从此忘掉
    func finish(_ chatId: String) {
        guard let e = calls.removeValue(forKey: chatId) else { return }
        if e.state == .ringing || e.state == .answered || e.state == .inApp {
            provider.reportCall(with: e.uuid, endedAt: Date(), reason: .remoteEnded)
        }
    }

    // MARK: - 结果落成通话记录

    /// 没接上应用里的通话页就结束了的那几种：落一条通话记录。测试来电不记
    private func settle(_ chatId: String, as state: State) {
        guard var e = calls[chatId] else { return }
        e.state = state
        e.at = Date()
        calls[chatId] = nil
        guard chatId != Self.testId, chatId != Self.unknownId, !e.charId.isEmpty else { return }
        do {
            switch state {
            case .missed:
                try CallEngine.missed(chatId: chatId, charId: e.charId, video: e.video)
            case .declined, .ended:
                // 接起来却没等到通话页接上就挂了，记「已取消」；响铃时挂掉是拒接
                try CallEngine.finish(chatId: chatId, charId: e.charId, direction: "in", outcome: state == .declined ? "declined" : "cancelled",
                                      seconds: 0, lines: [], userName: "", charName: "", video: e.video)
                NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
            default: break
            }
        } catch {
            Problems.report("通话记录未能保存：\(error.localizedDescription)")
        }
    }

    // MARK: - 弹不出来时

    /// 系统来电界面弹不出来：一定发一条来电通知（不看「消息通知」开关，网页版 4.895），点开进那段会话
    nonisolated static func postFallback(chatId: String, name: String, video: Bool) {
        let c = UNMutableNotificationContent()
        c.title = name.isEmpty ? "来电" : name
        c.body = video ? "视频通话" : "语音通话"
        c.sound = .default
        c.userInfo = ["chatId": chatId]
        c.threadIdentifier = chatId
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "call-\(chatId)", content: c, trigger: nil))
    }

    // MARK: - 上一次的结果与「试一次」

    nonisolated private static func readLast() -> Last? {
        guard let d = UserDefaults.standard.dictionary(forKey: lastKey), let at = d["at"] as? Double else { return nil }
        return Last(ok: d["ok"] as? Bool ?? false, error: d["error"] as? String ?? "", at: at)
    }

    private func note(_ why: String?) {
        let l = Last(ok: why == nil, error: why ?? "", at: Date().millis)
        UserDefaults.standard.set(["ok": l.ok, "error": l.error, "at": l.at], forKey: Self.lastKey)
        last = l
    }

    /// 过几秒响一通「测试来电」，人在这几秒里锁屏或切出去，看系统弹不弹得出来。接了或没接都直接收掉，不进通话
    func test(delay: Double = 3) async -> String? {
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
        defer { UIApplication.shared.endBackgroundTask(bg) }
        try? await Task.sleep(nanoseconds: UInt64(max(0, min(delay, 10)) * 1_000_000_000))
        calls[Self.testId] = nil
        return await ring(chatId: Self.testId, charId: "", name: "测试来电", video: false)
    }

    // MARK: - 系统的回调（在主线程）

    fileprivate func answered(_ action: CXAnswerCallAction) {
        guard let id = calls.first(where: { $0.value.uuid == action.callUUID })?.key else { action.fail(); return }
        calls[id]?.state = .answered
        calls[id]?.at = Date()
        // 声音按通话来配：能放也能录、可以用蓝牙耳机。系统随后激活这个会话
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
        action.fulfill()
        if id == Self.testId {
            let uuid = action.callUUID
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                SystemCall.shared.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                SystemCall.shared.calls[Self.testId] = nil
            }
            return
        }
        // 打开那段会话；会话页（已经开着的，或打开时）看到这一通就直接接通
        Notifier.shared.openChat = id
        NotificationCenter.default.post(name: .eiraIncomingCall, object: id, userInfo: ["video": calls[id]?.video ?? false, "answered": true])
    }

    fileprivate func ended(_ action: CXEndCallAction) {
        action.fulfill()
        guard let hit = calls.first(where: { $0.value.uuid == action.callUUID }) else { return }
        switch hit.value.state {
        case .ringing: settle(hit.key, as: .declined)
        case .answered: settle(hit.key, as: .ended)
        case .inApp:
            calls[hit.key] = nil
            NotificationCenter.default.post(name: .eiraSystemCallEnded, object: hit.key)
        default: calls[hit.key] = nil
        }
    }

    fileprivate func reset() {
        for (id, e) in calls {
            if e.state == .inApp { NotificationCenter.default.post(name: .eiraSystemCallEnded, object: id) }
        }
        calls = [:]
    }
}

extension SystemCall: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { SystemCall.shared.reset() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated { SystemCall.shared.answered(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated { SystemCall.shared.ended(action) }
    }

    /// 通话结束、系统收回声音通道：换回平时放声的样子
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        try? audioSession.setCategory(.playback, mode: .default)
    }
}
