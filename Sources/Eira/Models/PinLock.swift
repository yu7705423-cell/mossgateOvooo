import CryptoKit
import Foundation
import LocalAuthentication

/// 本机的锁屏密码（网页版 system/pinlock.js，4.231）。设了之后每次打开应用都先停在锁屏上，输对了才进得去；
/// 切到后台再回来不要。存的是 settings.lockPin = { hash, salt, len }：加盐的 SHA-256，与网页版同一种写法，不存密码本身。
///
/// 忘了：网页版用登录账号验证；原生版没有账号服务，用本机的面容 ID 或手机密码验证一次，过了就清掉锁屏密码，数据不动。
enum PinLock {
    static let lengths = [4, 6]

    static func pin(_ s: AppSettings = .load()) -> [String: JSONValue]? {
        guard let o = s.raw["lockPin"]?.object, !(o["hash"]?.string ?? "").isEmpty else { return nil }
        return o
    }
    static func hasPin(_ s: AppSettings = .load()) -> Bool { pin(s) != nil }
    static func length(_ s: AppSettings = .load()) -> Int { pin(s)?["len"]?.number == 6 ? 6 : 4 }

    static func digest(_ pin: String, salt: String) -> String {
        SHA256.hash(data: Data("\(salt):\(pin)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func valid(_ pin: String) -> Bool {
        lengths.contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 设一个新密码（4 位或 6 位数字）
    static func set(_ pin: String) throws {
        guard valid(pin) else { throw StoreError(message: "密码为 4 位或 6 位数字") }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let salt = bytes.map { String(format: "%02x", $0) }.joined()
        var s = try AppSettings.loadForWrite()
        s.raw["lockPin"] = .object(["hash": .string(digest(pin, salt: salt)), "salt": .string(salt), "len": .number(Double(pin.count))])
        try s.save()
        clearFails()
    }

    /// 清掉密码。off 为真时锁屏一并关掉（网页版 lockoff）
    static func clear(lockOff: Bool = false) throws {
        var s = try AppSettings.loadForWrite()
        s.raw["lockPin"] = .null
        if lockOff { s.raw["showLockScreen"] = .bool(false) }
        try s.save()
        clearFails()
    }

    // MARK: - 输错之后的等待：连错五次开始要等，越错等得越久；重开应用不清零

    private static let failKey = "phone.pin.fail"
    private static let waits: [Double] = [30, 60, 300, 900]
    private static let free = 5

    private static func fails() -> (n: Int, until: Double) {
        let d = UserDefaults.standard.dictionary(forKey: failKey) ?? [:]
        return ((d["n"] as? Int) ?? 0, (d["until"] as? Double) ?? 0)
    }
    private static func clearFails() { UserDefaults.standard.removeObject(forKey: failKey) }

    /// 还要等几秒才能再试
    static func waitLeft(now: Date = Date()) -> Int { max(0, Int((fails().until - now.timeIntervalSince1970).rounded(.up))) }
    static func failCount() -> Int { fails().n }

    /// 核对。对了清掉错次；错了记一次，到了次数开始计时
    static func check(_ input: String, now: Date = Date()) -> Bool {
        guard let p = pin() else { return true }
        guard waitLeft(now: now) == 0 else { return false }
        if digest(input, salt: p["salt"]?.string ?? "") == p["hash"]?.string { clearFails(); return true }
        let n = fails().n + 1
        let wait = n >= free ? waits[min(n - free, waits.count - 1)] : 0
        UserDefaults.standard.set(["n": n, "until": wait > 0 ? now.timeIntervalSince1970 + wait : 0], forKey: failKey)
        return false
    }

    /// 忘了密码：用面容 ID 或手机密码验证本机主人
    static func verifyOwner() async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "验证后清除锁屏密码，数据不受影响。")) ?? false
    }
}
