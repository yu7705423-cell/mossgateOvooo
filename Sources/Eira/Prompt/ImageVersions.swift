import Foundation

/// 图片版本（网页版 reply.js 的 versionsOf / addVersion / pickVersion / removeVersion，ARCHITECTURE 4.861）。
///
/// 一张图的各版都挂在这条消息上：imageVers 按生成先后排，imageId 是气泡里显示的那一版。老消息没有 imageVers，就只有气泡里那一张。
/// 重画不删旧的那一张，留在 imageVers 里。再生成一版是用户点了才调（每版一次生图接口），不是自动的，不进 ExtraCalls。
/// 删一版只从版本表里拿掉：原生版不自己删图（同 ImageGen.regenerate 的注释，网页版第 20 条）。
enum ImageVersions {
    /// 这条消息的全部版本，按生成先后
    static func of(_ row: Row) -> [String] {
        var v = row.strings("imageVers").filter { !$0.isEmpty }
        let cur = row.string("imageId")
        if !cur.isEmpty && !v.contains(cur) { v.append(cur) }
        return v
    }

    static func of(_ m: Message) -> [String] { of(m.row) }

    static func json(_ ids: [String]) -> JSONValue { .array(ids.map { .string($0) }) }

    /// 画好一张时：已经有版本表的，新的这一张接在后面
    static func noteDrawn(_ row: inout Row, _ id: String) {
        let vers = row.strings("imageVers")
        guard !vers.isEmpty else { return }
        row["imageVers"] = json(vers.filter { $0 != id } + [id])
    }

    /// 长按菜单里有没有「图片版本」：角色发的、有生图描述的图
    static func can(_ m: Message) -> Bool {
        m.kind == "image" && m.role == .char && !m.row.string("prompt").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // 正在画的版数只在内存里：页面关了、应用重开，画到一半的那一版本来也不会再落下
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [String: Int] = [:]
    static func busy(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return running[id] ?? 0 }
    private static func bump(_ id: String, _ d: Int) {
        lock.lock(); defer { lock.unlock() }
        let n = (running[id] ?? 0) + d
        if n > 0 { running[id] = n } else { running.removeValue(forKey: id) }
    }

    /// 按原描述再画一版，接在后面，不换掉气泡里那一张。返回新画的那一张的 id；失败抛出，由页面写明原因
    @discardableResult
    static func add(_ id: String) async throws -> String {
        guard let row = try Database.shared.get(Collections.messages, id: id), row.string("kind") == "image",
              !row.string("prompt").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError(message: "这条消息没有图片描述")
        }
        let s = AppSettings.load()
        guard let preset = s.activeImage, preset.ready else { throw StoreError(message: "还没有配置生图接口") }
        bump(id, 1)
        defer { bump(id, -1) }
        switch try await ImageGen.produce(row, preset: preset, settings: s) {
        case .image(let imageId):
            guard var cur = try Database.shared.get(Collections.messages, id: id) else { return imageId }
            cur["imageVers"] = json(of(cur) + [imageId])
            cur.touch()
            try Database.shared.put(Collections.messages, cur)
            return imageId
        case .refRejected(_, let why):
            throw StoreError(message: why)
        }
    }

    /// 气泡里改显示这一版
    @discardableResult
    static func pick(_ id: String, _ imageId: String) throws -> Message? {
        guard var row = try Database.shared.get(Collections.messages, id: id), of(row).contains(imageId) else { return nil }
        row["imageVers"] = json(of(row))
        row["imageId"] = .string(imageId)
        row["media"] = .string("done")
        row["mediaError"] = .string("")
        row["refMulti"] = nil
        row.touch()
        try Database.shared.put(Collections.messages, row)
        return Message(row: row)
    }

    /// 删掉一版。气泡里正显示的那一版不删
    @discardableResult
    static func remove(_ id: String, _ imageId: String) throws -> Bool {
        guard var row = try Database.shared.get(Collections.messages, id: id), !imageId.isEmpty, row.string("imageId") != imageId else { return false }
        row["imageVers"] = json(of(row).filter { $0 != imageId })
        row.touch()
        try Database.shared.put(Collections.messages, row)
        return true
    }
}
