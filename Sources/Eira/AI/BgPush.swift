import Foundation
import UIKit

/// 后台消息（网页版 system/bgpush.js，ARCHITECTURE 4.226、4.242）：应用不在前台时，角色照样按「主动发起对话」的时间发消息。
///
/// 应用退到后台就什么都跑不了，所以交给用户自己部署的服务器（网页版 worker/push.js，同一台服务器）：
/// - 退到后台时：每个开了主动发起对话的角色，接下来几次开口的时间，连同到时候要发给模型的那一次完整请求，一起交给服务器；
/// - 服务器到点替你发，结果存着；
/// - 回到前台时：把结果取回来，照平时的样子落进会话，再请服务器删掉。
///
/// **同一次开口只能扣一次钱。** 后台消息开着时：退到后台一律归服务器；回到前台要先把结果取回来（成功失败都算这一次
/// 已经用掉）才恢复本机发；取不回来就本机也不发，界面上写明。应用开着时每四分钟报一次到，服务器看见就先不发。
/// 原生版没有 Web Push：登记时不带订阅，服务器照样到点替角色发、存着，打开应用时取回。
/// 与服务器之间的请求格式和网页版一字不差（服务器不会跟着应用更新）。
@MainActor
final class BgPush: ObservableObject {
    static let shared = BgPush()

    static let perCharDefault = 2
    static let markTime = "{{bg_time}}"
    static let markGap = "{{bg_gap}}"
    private static let devKey = "eira-bgpush-device"
    private static let aliveEvery: TimeInterval = 4 * 60

    /// 最近一次和服务器对不上的原因。空表示正常
    @Published private(set) var problem = ""
    @Published private(set) var settling = false
    private var foreground = true
    private var timer: Timer?
    private var proactiveTimer: Timer?

    struct Device: Codable, Equatable {
        var server: String
        var id: String
        var token: String
        var endpoint: String
    }

    // MARK: - 设置

    nonisolated static func config(_ s: AppSettings = .load()) -> [String: JSONValue] { s.raw["bgPush"]?.object ?? [:] }
    nonisolated static func server(_ s: AppSettings = .load()) -> String {
        (config(s)["server"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    }
    nonisolated static func serverOk(_ s: AppSettings = .load()) -> Bool {
        server(s).range(of: #"^https://[^/\s]+"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    nonisolated static func isOn(_ s: AppSettings = .load()) -> Bool { config(s)["on"]?.bool == true }
    nonisolated static func perChar(_ s: AppSettings = .load()) -> Int {
        max(1, Int((config(s)["perChar"]?.number ?? Double(perCharDefault)).rounded()))
    }

    nonisolated static func device() -> Device? {
        guard let d = UserDefaults.standard.data(forKey: devKey) else { return nil }
        return try? JSONDecoder().decode(Device.self, from: d)
    }
    nonisolated static func setDevice(_ d: Device?) {
        if let d, let data = try? JSONEncoder().encode(d) { UserDefaults.standard.set(data, forKey: devKey) }
        else { UserDefaults.standard.removeObject(forKey: devKey) }
    }

    // MARK: - 请求

    struct ApiError: LocalizedError {
        var status: Int
        var message: String
        var errorDescription: String? { message }
    }

    nonisolated static func api(_ path: String, method: String = "GET", body: JSONValue? = nil, auth: Bool = true) async throws -> JSONValue {
        let base = server()
        guard !base.isEmpty, let url = URL(string: base + path) else { throw ApiError(status: 0, message: "没有配置后台消息服务器") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if auth {
            guard let d = device(), d.server == base else { throw ApiError(status: 0, message: "本机还没有在后台消息服务器上登记") }
            req.setValue("Bearer \(d.id).\(d.token)", forHTTPHeaderField: "authorization")
        }
        if let body { req.httpBody = try body.encoded() }
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONValue.parse(data)) ?? .object([:])
        guard (200..<300).contains(status) else {
            throw ApiError(status: status, message: j["error"]?.string ?? "后台消息服务器返回 \(status)")
        }
        return j
    }

    /// 打开：在服务器上登记本机（不带推送订阅），交一次任务。
    func enable() async throws {
        guard Self.serverOk() else { throw StoreError(message: "请先填写后台消息服务器地址（https 开头）") }
        let base = Self.server()
        if Self.device()?.server != base {
            let got = try await Self.api("/device", method: "POST", body: .object([:]), auth: false)
            guard let id = got["id"]?.string ?? got["id"]?.number.map({ String(Int($0)) }), let token = got["token"]?.string else {
                throw StoreError(message: "后台消息服务器没有返回登记结果")
            }
            Self.setDevice(Device(server: base, id: id, token: token, endpoint: ""))
        }
        SettingsModel.shared.update { s in
            var c = Self.config(s)
            c["on"] = .bool(true)
            s.raw["bgPush"] = .object(c)
        }
        _ = try? await Self.plan(away: false)
    }

    /// 关掉：服务器上这台设备与它的任务一并删掉。
    func disable() async {
        SettingsModel.shared.update { s in
            var c = Self.config(s)
            c["on"] = .bool(false)
            s.raw["bgPush"] = .object(c)
        }
        if Self.device() != nil { _ = try? await Self.api("/device", method: "DELETE") }
        Self.setDevice(nil)
        problem = ""
    }

    // MARK: - 通知通道（Bark、PushPlus；设置在网页版填过的照用）

    nonisolated static func channelOut(_ s: AppSettings = .load()) -> JSONValue {
        let ch = config(s)["channel"]?.object ?? [:]
        let kind = ch["kind"]?.string ?? ""
        let hide = ch["hide"]?.bool == true
        if kind == "bark" {
            let url = (ch["url"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { return .null }
            let k = ch["key"]?.string ?? "", v = ch["iv"]?.string ?? ""
            let crypto = k.isEmpty && v.isEmpty ? "off" : ([16, 24, 32].contains(k.utf8.count) && v.utf8.count == 16 ? "ok" : "bad")
            var out: [String: JSONValue] = ["kind": .string("bark"), "url": .string(url), "hide": .bool(hide || crypto == "bad")]
            if crypto == "ok" { out["key"] = .string(k); out["iv"] = .string(v) }
            return .object(out)
        }
        if kind == "pushplus" {
            let token = (ch["token"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { return .null }
            return .object(["kind": .string("pushplus"), "token": .string(token), "hide": .bool(hide)])
        }
        return .null
    }

    // MARK: - 离开时交任务

    /// 这一刻要交给服务器的任务。每个角色一条，带着接下来几次的时间与到时候发给模型的那一次请求。拼任务不调任何接口。
    nonisolated static func jobsNow(now: Double = Date().millis) throws -> [JSONValue] {
        let s = AppSettings.load()
        guard let preset = AIService.chain(task: "chat.proactive", group: RouteGroup.of(task: "chat.proactive"), settings: s).first else { return [] }
        var out: [JSONValue] = []
        for char in try Repo.characters() {
            guard Proactive.config(char).on, let chat = Proactive.chatReady(char.id, s) else { continue }
            let room = Proactive.roomLeft(chat, s)
            let count = room > 0 ? min(room, perChar(s)) : perChar(s)
            let times = Proactive.upcoming(char.id, count: count, now: now)
            guard !times.isEmpty else { continue }
            let msgs = try Repo.messages(chatId: chat.id).filter { !$0.isError }
            let lastAt = msgs.map { $0.row.number("createdAt") ?? 0 }.max() ?? 0
            let p = try Proactive.payload(chat: chat, char: char, time: markTime, gap: markGap)
            guard let request = try? Self.request(preset, p) else { continue }
            out.append(.object([
                "due": .array(times.map { .number($0) }), "chatId": .string(chat.id), "charId": .string(char.id),
                "title": .string(char.displayName.isEmpty ? "Eira" : char.displayName), "lastAt": .number(lastAt),
                "tz": .string(TimeZone.current.identifier), "closing": .string(Proactive.closing), "request": request,
            ]))
        }
        return out
    }

    /// 到时候服务器替你发的那一次请求：{ provider, url, headers, body }，和网页版 prepareTextTask 同一形状。
    nonisolated static func request(_ p: ChatPreset, _ payload: Proactive.Payload) throws -> JSONValue {
        let req = try Provider.urlRequest(p, .init(system: payload.system, messages: payload.messages, maxTokens: payload.maxTokens,
                                                   stream: false, cache: false), idleSeconds: 0)
        guard let url = req.url?.absoluteString, let body = req.httpBody else { throw StoreError(message: "请求拼不出来") }
        var headers: [String: JSONValue] = [:]
        for (k, v) in req.allHTTPHeaderFields ?? [:] { headers[k] = .string(v) }
        return .object(["provider": .string(p.provider.rawValue), "url": .string(url), "headers": .object(headers),
                        "body": try JSONValue.parse(body)])
    }

    /// 交任务，顺便报到。away 为真是「要退到后台了」，服务器从这一刻起到点就发；否则是「还开着」。
    @discardableResult
    nonisolated static func plan(away: Bool) async throws -> JSONValue? {
        guard isOn(), device() != nil else { return nil }
        let body: JSONValue = .object(["away": .bool(away), "channel": channelOut(), "jobs": .array(try jobsNow())])
        return try await api("/plan", method: "POST", body: body)
    }

    // MARK: - 回来时取结果

    /// 把服务器替你发出去的那几条取回来，落进会话。返回落了几条。
    func collect() async throws -> Int {
        guard Self.device() != nil else { return 0 }
        let got = try await Self.api("/results")
        let results = (got["results"]?.array ?? []).sorted { ($0["firedAt"]?.number ?? 0) < ($1["firedAt"]?.number ?? 0) }
        if results.isEmpty { Proactive.rescheduleOverdue(); problem = ""; return 0 }
        var n = 0
        var touched = Set<String>()
        var failed: [String] = []
        for r in results {
            let charId = r["charId"]?.string ?? ""
            let fired = r["firedAt"]?.number ?? Date().millis
            if r["status"]?.string == "failed" {
                // 失败的也算这一次用掉了：模型那一次可能已经扣过钱，本机不补发
                if !charId.isEmpty { touched.insert(charId) }
                let name = (try? Repo.character(charId))?.displayName ?? "角色"
                let err = r["error"]?.string ?? "原因不明"
                failed.append("\(name)：\(err)")
                if !err.contains("已达每日上限") { await Usage.shared.note(task: "chat.proactive") }
                continue
            }
            guard let chat = try Repo.chat(r["chatId"]?.string ?? ""), let char = try Repo.character(charId),
                  let text = r["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            await Usage.shared.note(task: "chat.proactive")
            let rid = r["id"]?.string ?? Ids.make("bg")
            do {
                let made = try await ChatEngine.write(raw: text, chat: chat, char: char, turnId: "bg-\(rid)",
                                                      versions: .init(swipes: [text], index: 0, served: []), instant: true) { _ in }
                // 落在服务器发出去的那一刻，不是取回来的这一刻
                for (i, m) in made.enumerated() {
                    guard var row = try Database.shared.get(Collections.messages, id: m.id) else { continue }
                    row["createdAt"] = .number(fired + Double(i))
                    try Database.shared.put(Collections.messages, row)
                }
                try Proactive.bumpUnread(chat.id, made.count)
                n += made.count
                touched.insert(char.id)
            } catch {
                Problems.report("后台消息未能落进会话：\(error.localizedDescription)")
            }
        }
        let ids: [JSONValue] = results.compactMap { $0["id"] }
        _ = try? await Self.api("/ack", method: "POST", body: .object(["ids": .array(ids)]))
        // 刚替它发过（或者试过）的重新掷落点；离开期间到点、结果里却没有的同样归服务器，本机不补
        for id in touched { Proactive.reschedule(id) }
        for r in results { if let c = r["chatId"]?.string { NotificationCenter.default.post(name: .eiraChatChanged, object: c) } }
        Proactive.rescheduleOverdue()
        problem = failed.isEmpty ? "" : "服务器替角色发送失败 \(failed.count) 次（\(failed[0])）。失败的那一次不补发。"
        return n
    }

    /// 本机这会儿该不该让着服务器：后台消息开着时，不在前台、或者结果还没取回来，都归服务器。
    var holdsProactive: Bool {
        guard Self.isOn(), Self.device() != nil else { return false }
        return !foreground || settling
    }

    // MARK: - 跟着应用前后台走

    func didBecomeActive() {
        foreground = true
        if Self.isOn() && Self.device() != nil {
            settle()
            alive()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: Self.aliveEvery, repeats: true) { _ in
                Task { @MainActor in
                    BgPush.shared.alive()
                    if BgPush.shared.settling { BgPush.shared.settle() }
                }
            }
        }
        // 本机巡检：二三十秒一轮。主动消息的间隔按分钟算，这个精度够用
        proactiveTimer?.invalidate()
        proactiveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in BgPush.shared.tickProactive() }
        }
    }

    func didEnterBackground() {
        foreground = false
        timer?.invalidate(); timer = nil
        proactiveTimer?.invalidate(); proactiveTimer = nil
        guard Self.isOn(), Self.device() != nil else { return }
        // 退到后台时系统只给几秒：申请一段后台时间把任务交上去
        let id = UIApplication.shared.beginBackgroundTask(withName: "bgpush-plan", expirationHandler: nil)
        Task.detached {
            do { try await BgPush.plan(away: true) }
            catch { Diagnostics.shared.record("bgpush-plan-failed", ["error": error.localizedDescription]) }
            await MainActor.run { UIApplication.shared.endBackgroundTask(id) }
        }
    }

    private var ticking = false
    func tickProactive() {
        guard !ticking else { return }
        ticking = true
        let holds = holdsProactive
        Task.detached {
            await Proactive.tick(holds: holds)
            await MainActor.run { BgPush.shared.ticking = false }
        }
    }

    /// 取回结果。取回之前本机不发主动消息；取不回来就一直等，下次报到时再取。
    func settle() {
        settling = true
        Task {
            do {
                _ = try await collect()
                settling = false
            } catch {
                problem = "连不上后台消息服务器（\(error.localizedDescription)）。为避免同一次开口本机与服务器各发一次，恢复连接之前本机不发主动消息。"
            }
        }
    }

    func alive() {
        guard Self.isOn(), Self.device() != nil else { return }
        Task.detached { _ = try? await BgPush.api("/alive", method: "POST") }
    }
}
