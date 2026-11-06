import CryptoKit
import Foundation

/// Eira 推送的盒子（网页版 ARCHITECTURE 4.896，服务器那头是 worker/push.js 的 eiraBox）。
///
/// 用户自己部署的后台消息服务器拿手机给的钥匙（32 字节）把要显示的东西加密成 AES-GCM：
/// iv（12 字节）单独交，box 是密文连着 16 字节的校验，都是 base64。手机上 `SealedBox(combined: iv + box)` 解开。
/// 推送转发（worker/apns.js）只见过密文，钥匙从不经过它。
///
/// 文字通知：{ t: 标题, b: 正文, c: 会话 }；来电：{ c: 会话, n: 名字, v: 是否视频 }。
enum PushBox {
    /// 钥匙在 App Group 的 UserDefaults 里的键（与网页版外壳同名）
    static let keyName = "push.key"

    static func open(box: String, iv: String, key: String) -> [String: Any]? {
        guard let keyData = Data(base64Encoded: key), keyData.count == 32,
              let ivData = Data(base64Encoded: iv), ivData.count == 12,
              let boxData = Data(base64Encoded: box), boxData.count > 16,
              let sealed = try? AES.GCM.SealedBox(combined: ivData + boxData),
              let plain = try? AES.GCM.open(sealed, using: SymmetricKey(data: keyData)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
    }

    /// 推送里带的 box 与 iv，用这把钥匙解开
    static func open(_ info: [AnyHashable: Any], key: String?) -> [String: Any]? {
        guard let key, let box = info["box"] as? String, let iv = info["iv"] as? String else { return nil }
        return open(box: box, iv: iv, key: key)
    }

    /// 与服务器同一种写法封一个盒子（测试与自检用；真正的推送由服务器封）
    static func seal(_ obj: [String: Any], key: String) -> (box: String, iv: String)? {
        guard let keyData = Data(base64Encoded: key), keyData.count == 32,
              let plain = try? JSONSerialization.data(withJSONObject: obj),
              let sealed = try? AES.GCM.seal(plain, using: SymmetricKey(data: keyData)) else { return nil }
        return ((sealed.ciphertext + sealed.tag).base64EncodedString(), sealed.nonce.withUnsafeBytes { Data($0) }.base64EncodedString())
    }

    /// 新钥匙：32 个随机字节的 base64
    static func newKey() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    /// App Group 里那把钥匙（通知扩展读它）
    static func groupKey(_ d: UserDefaults? = AppGroup.defaults) -> String? {
        guard let k = d?.string(forKey: keyName), Data(base64Encoded: k)?.count == 32 else { return nil }
        return k
    }

    /// 文字通知解开之后的样子
    struct Alert: Equatable {
        var title: String
        var body: String
        var chatId: String
    }

    static func alert(_ obj: [String: Any]?) -> Alert? {
        guard let obj else { return nil }
        let a = Alert(title: obj["t"] as? String ?? "", body: obj["b"] as? String ?? "", chatId: obj["c"] as? String ?? "")
        return a.title.isEmpty && a.body.isEmpty ? nil : a
    }

    /// 来电推送解开之后的样子
    struct Ring: Equatable {
        var chatId: String
        var name: String
        var video: Bool
    }

    static func ring(_ obj: [String: Any]?) -> Ring? {
        guard let obj, let c = obj["c"] as? String, !c.isEmpty else { return nil }
        return Ring(chatId: c, name: obj["n"] as? String ?? "", video: obj["v"] as? Bool ?? false)
    }
}
