import Foundation

/// 读网页版「设置 - 存储」导出的备份，整份换进本地库。照网页版 `src/system/backup.js` 的 restore：
///
/// - 按内容认格式，不按扩展名：加密的先解开；`PK` 开头是 ZIP（`backup.json` 加 images/、files/），否则是纯 JSON；
/// - **先把包整个读出来、确认没问题，再动现有数据。** 媒体先写进暂存目录，记录在一个事务里整体替换，
///   任何一步失败，库保持导入之前的样子；
/// - 图片与文件按原来的 id 放回去；内容是 ZIP 的坏图（网页版 4.273）不放，报到结果里；
/// - 备份里带了接口就用备份里的，没带就留着这台设备自己的。
///
/// 和网页版不同的一处：网页版只恢复它认识的数据域，原生版把备份里的每一个数据域都存下来，
/// 现在不认识的以后支持了直接能读。
enum BackupImporter {
    static let format = "mini-phone-backup"

    /// 网页版写这份代码时的数据结构版本（schema.js 的 DATA_VERSION）。
    /// 更老的备份要经网页版的迁移才是现在的结构，原生版不重写那些迁移。
    static let minDataVersion = 12

    struct Report: Sendable {
        var rows: Int
        var collections: Int
        var media: Int
        var bad: [String]
        var dataVersion: Int
        var keptLocalServices: Bool
    }

    enum Failure: LocalizedError {
        case notBackup, noJSON([String]), tooOld(Int)
        var errorDescription: String? {
            switch self {
            case .notBackup: return "不是 Eira 的备份文件"
            case .noJSON(let names):
                return names.isEmpty ? "这个包里一条记录都读不出来，可能不是 Eira 的备份"
                    : "包里没有 backup.json。里面是：\(names.prefix(5).joined(separator: "、"))\(names.count > 5 ? " 等" : "")"
            case .tooOld(let v):
                return "这份备份来自较早的网页版（数据版本 \(v)）。请先在网页版里恢复这份备份，再重新导出一份，然后导入。"
            }
        }
    }

    /// `progress` 在任意线程上调用，取值 0...1。
    static func run(file: URL, password: String, progress: @escaping @Sendable (Double) -> Void) throws -> Report {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }

        var data: Data
        do { data = try Data(contentsOf: file, options: .alwaysMapped) }
        catch { throw StoreError(message: "读不出这个文件：\(error.localizedDescription)") }

        // 加了口令的先解开到临时文件
        var plainURL: URL?
        defer { if let plainURL { try? FileManager.default.removeItem(at: plainURL) } }
        if Vault.isSealed(data) {
            if password.isEmpty { throw Vault.Failure.needPass }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("eira-backup-\(UUID().uuidString)")
            plainURL = tmp
            try Vault.open(data, pass: password, to: tmp)
            data = try Data(contentsOf: tmp, options: .alwaysMapped)
        }
        progress(0.05)

        // 读出 backup.json 与 ZIP 里的条目
        var zip: ZipReader?
        let jsonData: Data
        if ZipReader.looksLikeZip(data) {
            let z = try ZipReader(data: data)
            guard let e = z.entry(named: "backup.json"), let d = z.contents(of: e) else { throw Failure.noJSON(z.names) }
            jsonData = d
            zip = z
        } else {
            jsonData = data
        }
        guard let root = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
              root["_format"] as? String == format else { throw Failure.notBackup }
        let dataVersion = (root["_data"] as? NSNumber)?.intValue ?? 0
        if dataVersion < minDataVersion { throw Failure.tooOld(dataVersion) }
        progress(0.15)

        // 媒体先写进暂存目录
        let staging = try MediaStore.Staging()
        var bad: [String] = []
        if let zip {
            var media: [(ZipReader.Entry, MediaKind, String, String)] = []
            for e in zip.entries {
                let parts = e.name.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2, let kind = MediaKind(rawValue: parts[0]),
                      !parts[1].isEmpty, !parts[1].contains("/") else { continue }
                let file = parts[1]
                if let dot = file.firstIndex(of: "."), dot != file.startIndex {
                    media.append((e, kind, String(file[..<dot]), String(file[file.index(after: dot)...])))
                } else {
                    media.append((e, kind, file, "bin"))
                }
            }
            // 原图挂在压缩后的那一张上（网页版 4.400），那一张不在就不放：放在最后处理
            media.sort { ($0.1 == .imagesOrig ? 1 : 0) < ($1.1 == .imagesOrig ? 1 : 0) }
            var haveImages = Set<String>()
            for (i, item) in media.enumerated() {
                let (e, kind, id, ext) = item
                if kind == .imagesOrig && !haveImages.contains(id) { continue }
                guard let content = zip.contents(of: e) else { bad.append(e.name); continue }
                // 内容本身是 ZIP 的图：网页版从前切片存坏的那一种，放进来也显示不出，不放
                if kind != .files && content.count >= 4 && Array(content.prefix(4)) == [0x50, 0x4b, 0x03, 0x04] {
                    bad.append(e.name); continue
                }
                do { try staging.write(kind, id: id, ext: ext, data: content) }
                catch { staging.discard(); throw error }
                if kind == .images { haveImages.insert(id) }
                if i % 20 == 0 { progress(0.15 + 0.55 * Double(i) / Double(max(media.count, 1))) }
            }
        }
        progress(0.7)

        // 记录：整体替换
        let db = Database.shared
        var rows = 0
        var collections = 0
        let current = (try? db.kv(KVKey.settings))?.object ?? [:]
        var keptLocal = false
        do {
            try db.replaceAll { batch in
                for (name, value) in root where !name.hasPrefix("_") {
                    guard let list = value as? [Any] else { continue }
                    let objects = list.compactMap { $0 as? [String: Any] }
                    guard !objects.isEmpty || isKnownCollection(name) else { continue }
                    collections += 1
                    for obj in objects {
                        guard let id = obj["id"] as? String, !id.isEmpty else { continue }
                        let json = try JSONSerialization.data(withJSONObject: obj)
                        try batch.put(name, id: id, json: json,
                                      idx: Collections.indexValue(name, any: obj),
                                      created: (obj["createdAt"] as? NSNumber)?.doubleValue)
                        rows += 1
                    }
                }
                for item in staging.written {
                    try batch.registerMedia(kind: item.kind.rawValue, id: item.id, ext: item.ext, bytes: item.bytes)
                }
                if let persona = root["persona"] as? [String: Any] {
                    try batch.setKV(KVKey.persona, JSONValue(any: persona))
                }
                if let incoming = root["settings"] as? [String: Any] {
                    let (merged, kept) = mergeSettings(current: current, incoming: JSONValue(any: incoming).object ?? [:])
                    keptLocal = kept
                    try batch.setKV(KVKey.settings, .object(merged))
                }
                if let layout = root["layout"] as? [String: Any] {
                    try batch.setKV(KVKey.layout, JSONValue(any: layout))
                }
                try batch.setKV(KVKey.dataVersion, .number(Double(dataVersion)))
                try batch.setKV(KVKey.importedAt, .number(Date().millis))
            }
        } catch {
            staging.discard()
            throw error
        }
        progress(0.9)
        try staging.commit()
        progress(1)

        return Report(rows: rows, collections: collections, media: staging.written.count, bad: bad,
                      dataVersion: dataVersion, keptLocalServices: keptLocal)
    }

    /// 网页版 restore 里那段：备份没带接口（导出时没勾「含密钥」）就留着本机的，带了就用备份的。
    /// GitHub 备份的令牌与口令同理：备份里是空的就留着本机的。
    static func mergeSettings(current: [String: JSONValue], incoming: [String: JSONValue]) -> ([String: JSONValue], Bool) {
        var out = current
        out.merge(incoming) { _, new in new }
        let hasKeys = incoming["services"].map { !$0.isNull } ?? false
        if !hasKeys {
            out["services"] = current["services"]
            out["apiKey"] = current["apiKey"]
        } else {
            out["apiKey"] = incoming["apiKey"] ?? .string("")
        }
        if case .object(var gh)? = incoming["githubBackup"], case .object(let mine)? = current["githubBackup"] {
            for key in ["token", "password"] where (gh[key]?.string ?? "").isEmpty {
                gh[key] = mine[key] ?? .string("")
            }
            out["githubBackup"] = .object(gh)
        }
        return (out, !hasKeys)
    }

    private static func isKnownCollection(_ name: String) -> Bool {
        Collections.indexField[name] != nil
            || [Collections.characters, Collections.chats, Collections.personas, Collections.lorebooks].contains(name)
    }
}
