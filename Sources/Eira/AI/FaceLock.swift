import Foundation
import UIKit

/// 锁脸（网页版 system/facelock.js 与 imageprompt.js 的 faceApplies / ensureFaceDesc / wantsRef，ARCHITECTURE 4.402）。
///
/// 同一个人每次画出来长得都不一样，锁脸给几张照片，两条路：
///   A 读成外貌描述：照片交给能看图的模型读成一段话，缓存在卡上，之后每张拼进提示词。任何生图接口都能用，只花一次识图。
///   B 直传参考图：照片本身随生图请求发出去（OpenAI 兼容的 images/edits，或对话接口）。像不像看接口，支持的话比 A 准。
/// 先试 B，接口不认（没有 edits 这条路）才退回 A；超时、余额不足、500 不退，退过去是同一个错误再付一次钱。
///
/// 角色的存在角色卡上；「我」的存在身份（personas）上，字段同名，逻辑一样（用户要的）：
///   faceImages 照片（按先后），faceImage 始终是第一张，faceOne 只能传一张时用哪张，
///   faceLock 何时用（self 自拍或提到名字时，默认；always 每张都用；off 关闭），faceDesc 读出来的外貌，faceDescFailed 读失败的那一组。
enum FaceLock {
    enum Owner: Equatable {
        case char(String)
        case me(String)
        var collection: String { if case .char = self { return Collections.characters }; return Collections.personas }
        var id: String { switch self { case .char(let i), .me(let i): return i } }
        var isMe: Bool { if case .me = self { return true }; return false }
    }

    static func row(_ o: Owner) -> Row? { try? Database.shared.get(o.collection, id: o.id) }

    /// 照片，按先后。老数据只有 faceImage 的也认
    static func faces(_ r: Row?) -> [String] {
        guard let r else { return [] }
        let list = r.strings("faceImages").filter { !$0.isEmpty }
        if !list.isEmpty { return list }
        let one = r.string("faceImage")
        return one.isEmpty ? [] : [one]
    }

    /// 只能传一张时用哪一张：选过的还在就用它，否则第一张
    static func one(_ r: Row?) -> String? {
        let list = faces(r)
        let pick = r?.string("faceOne") ?? ""
        return list.contains(pick) ? pick : list.first
    }

    static func refs(_ r: Row?, preset: ImagePreset) -> [String] {
        let list = faces(r)
        guard !list.isEmpty else { return [] }
        return preset.json["refOne"]?.bool == true ? one(r).map { [$0] } ?? [] : list
    }

    /// 外貌描述对应的是哪一组照片。照片有增减就对不上，要重读
    static func descKey(_ r: Row?) -> String { faces(r).joined(separator: ",") }

    static func mode(_ r: Row?) -> String {
        let m = r?.string("faceLock") ?? ""
        return ["always", "off"].contains(m) ? m : "self"
    }

    /// 换一组照片。外貌描述随之作废（下次需要时重读一次），选过的那一张不在了就清掉
    static func setFaces(_ o: Owner, _ ids: [String]) throws {
        guard var r = row(o) else { return }
        var seen = Set<String>()
        let list = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        r["faceImages"] = .array(list.map { .string($0) })
        r["faceImage"] = list.first.map { .string($0) } ?? .null
        if !list.contains(r.string("faceOne")) { r["faceOne"] = .null }
        r["faceDesc"] = .string("")
        r["faceDescFailed"] = .string("")
        r.touch()
        try Database.shared.put(o.collection, r)
    }

    static func set(_ o: Owner, _ fields: [String: JSONValue]) throws {
        guard var r = row(o) else { return }
        for (k, v) in fields { r[k] = v }
        r.touch()
        try Database.shared.put(o.collection, r)
    }

    // MARK: - 这一张用不用

    // 涉及脸部：自拍一类的词，或者点了名（角色写「阿岚站在窗边」时画的就是该角色本人）
    private static let selfish = try! NSRegularExpression(pattern: "自拍|自照|正脸|我的脸|我的样子|镜子|镜头|selfie|头像|证件照", options: .caseInsensitive)
    // 两个人都在画面里：合照、我们（网页版 imageprompt.js 的 PAIR）
    private static let pair = try! NSRegularExpression(pattern: "合照|合影|我们|两个人|俩人|一起|together|couple|both of us", options: .caseInsensitive)

    private static func has(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// 角色的：自拍一类的词，或者提到了角色的名字
    static func appliesChar(_ r: Row?, prompt: String) -> Bool {
        let m = mode(r)
        guard m != "off", !faces(r).isEmpty else { return false }
        if m == "always" { return true }
        let name = r?.string("name").trimmingCharacters(in: .whitespaces) ?? ""
        return has(selfish, prompt) || (!name.isEmpty && prompt.contains(name))
    }

    /// 我的：合照、我们一类的词，或者提到了我的名字
    static func appliesMe(_ r: Row?, prompt: String) -> Bool {
        let m = mode(r)
        guard m != "off", !faces(r).isEmpty else { return false }
        if m == "always" { return true }
        let name = r?.string("name").trimmingCharacters(in: .whitespaces) ?? ""
        return has(pair, prompt) || (name.count >= 2 && prompt.contains(name))
    }

    /// 这一套接口走不走参考图：OpenAI 兼容开了「参考图」，或者对话接口（本来就是把图放进消息里发）
    static func wantsRef(_ p: ImagePreset) -> Bool {
        p.kind == "chat" || (p.kind == "openai" && p.json["ref"]?.string == "edits")
    }

    // MARK: - 读成外貌描述

    static func imageData(_ id: String) -> AIImage? {
        guard let url = MediaStore.url(.images, id: id), let data = try? Data(contentsOf: url) else { return nil }
        return AIImage(mediaType: Images.mediaType(ext: url.pathExtension), base64: data.base64EncodedString())
    }

    /// 读一次，缓存在卡上。自动的这一次**先记「试过」再发**（第 15 条）：失败了记着这一组，之后每画一张都不再读；
    /// 换照片或点「重新读取」会清掉。识图关着或没配全就不读，不报错，退回没有描述。
    static func ensureDesc(_ o: Owner, sample: String) async -> String {
        guard let r = row(o) else { return "" }
        let ids = faces(r)
        guard !ids.isEmpty else { return "" }
        let cached = r.string("faceDesc").trimmingCharacters(in: .whitespacesAndNewlines)
        if !cached.isEmpty { return cached }
        let key = descKey(r)
        if r.string("faceDescFailed") == key { return "" }
        let s = AppSettings.load()
        guard s.visionMode == "chat" || (s.visionMode == "api" && s.visionPreset != nil) else { return "" }
        let imgs = ids.compactMap(imageData)
        guard !imgs.isEmpty else { return "" }
        do { try set(o, ["faceDescFailed": .string(key)]) } catch { return "" }
        let ask = imgs.count > 1 ? "These photos show the same person. Describe this person as instructed." : "Describe this person as instructed."
        do {
            let text: String
            if s.visionMode == "api", let vp = s.visionPreset {
                let r = try await AIService.shared.send(task: "vision", preset: vp,
                                                        system: Templates.render("task.vision-describe", ["sample": sample], settings: s),
                                                        messages: [AIMessage(role: .user, content: ask, images: imgs)], maxTokens: 400)
                text = r.text
            } else {
                let r = try await AIService.shared.send(task: "chat.face-describe",
                                                        system: Templates.render("task.face-describe", ["sample": sample], settings: s),
                                                        messages: [AIMessage(role: .user, content: ask, images: imgs)], maxTokens: 400)
                text = r.text
            }
            let out = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !out.isEmpty else { return "" }
            try set(o, ["faceDesc": .string(out), "faceDescFailed": .string("")])
            return out
        } catch {
            Diagnostics.shared.record("face-desc-failed", ["error": error.localizedDescription])
            return ""
        }
    }

    // MARK: - 参考图

    /// 发出去之前压一道：最长边 1024、每张不超过约 600KB 的 JPEG（网页版 shrinkRef，4.467）。本来就小的原样不动
    static func shrink(_ id: String, edge: CGFloat = 1024, bytes: Int = 600 * 1024) -> (data: Data, type: String)? {
        guard let url = MediaStore.url(.images, id: id), let data = try? Data(contentsOf: url) else { return nil }
        guard let img = UIImage(data: data) else { return (data, Images.mediaType(ext: url.pathExtension)) }
        let big = max(img.size.width * img.scale, img.size.height * img.scale)
        if big <= edge && data.count <= bytes { return (data, Images.mediaType(ext: url.pathExtension)) }
        var out = data
        for (e, q) in [(edge, 0.85), (edge, 0.7), (edge, 0.55), (edge * 0.75, 0.6), (edge * 0.5, 0.6)] {
            let k = min(1, e / big)
            let size = CGSize(width: max(1, (img.size.width * img.scale * k).rounded()), height: max(1, (img.size.height * img.scale * k).rounded()))
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            let drawn = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpg = drawn.jpegData(compressionQuality: q) else { break }
            out = jpg
            if jpg.count <= bytes { break }
        }
        return (out, "image/jpeg")
    }
}
