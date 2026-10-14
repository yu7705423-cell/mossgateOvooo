import Foundation

/// 导出成网页版的备份格式，网页版「设置 - 存储 - 恢复」能直接读回去（网页版 `src/system/backup.js` 的 build）。
///
/// - 带图片与文件：ZIP，`backup.json` 加 images/、images-orig/、files/；
/// - 只要数据：一份纯 JSON；
/// - 填了口令：整份按网页版 vault.js 的格式加密。
///
/// **接口与密钥默认不导出**（网页版同样）：备份会被发出去、放进网盘。要导出得在界面上明确打开。
/// 库里每一个数据域都导出，包括原生版不认识、从网页版导进来时原样存下的那些。
enum BackupExporter {
    struct Options: Sendable {
        var media = true
        var keys = false
        var password = ""
    }

    struct Result: Sendable {
        var file: URL
        var rows: Int
        var media: Int
        var bytes: Int
    }

    static func run(_ o: Options, progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> Result {
        let db = Database.shared
        let dataVersion = Int((try db.kv(KVKey.dataVersion))?.number ?? Double(BackupImporter.minDataVersion))
        let media = o.media ? try db.allMedia() : []

        var data: [String: Any] = [
            "_format": BackupImporter.format,
            "_version": 2,
            "_data": dataVersion,
            "_media": o.media,
            "_keys": o.keys,
            "_origs": media.contains { $0.kind == MediaKind.imagesOrig.rawValue },
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let persona = try db.kv(KVKey.persona) { data["persona"] = persona.any }
        if let layout = try db.kv(KVKey.layout) { data["layout"] = layout.any }
        data["settings"] = JSONValue.object(try sanitizedSettings(keys: o.keys)).any

        var rows = 0
        let collections = try db.collections()
        for (i, name) in collections.enumerated() {
            let list = try db.rawRows(name).compactMap { try? JSONSerialization.jsonObject(with: $0) }
            data[name] = list
            rows += list.count
            progress(0.3 * Double(i + 1) / Double(max(collections.count, 1)))
        }
        let json = try JSONSerialization.data(withJSONObject: data)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eira-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = TimeText.day(Date())
        var out: URL
        var written = 0
        if o.media {
            out = dir.appendingPathComponent("Eiraowo-备份-\(stamp).zip")
            let zip = try ZipWriter(url: out)
            try zip.add(name: "backup.json", data: json)
            for (i, m) in media.enumerated() {
                let url = AppPaths.media.appendingPathComponent(m.kind).appendingPathComponent("\(m.id).\(m.ext)")
                // 读不出来的那一张跳过，不连累整份；导完在结果里说
                guard let bytes = try? Data(contentsOf: url) else { continue }
                try zip.add(name: "\(m.kind)/\(m.id).\(m.ext)", data: bytes)
                written += 1
                if i % 20 == 0 { progress(0.3 + 0.6 * Double(i + 1) / Double(max(media.count, 1))) }
            }
            try zip.finish()
        } else {
            out = dir.appendingPathComponent("Eiraowo-备份-\(stamp).json")
            try json.write(to: out)
        }

        if !o.password.isEmpty {
            let sealed = dir.appendingPathComponent(out.deletingPathExtension().lastPathComponent + "-加密.bin")
            try Vault.seal(out, pass: o.password, to: sealed)
            try? FileManager.default.removeItem(at: out)
            out = sealed
        }
        progress(1)
        let bytes = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.intValue ?? 0
        Diagnostics.shared.record("export", ["rows": rows, "media": written, "keys": o.keys, "sealed": !o.password.isEmpty])
        return Result(file: out, rows: rows, media: written, bytes: bytes)
    }

    /// 不含密钥时：去掉接口与密钥；GitHub 备份的令牌与口令、后台消息的通知通道一律清空（网页版 build 的同一段）。
    /// 含密钥时：GitHub 备份的口令照样不进文件。
    static func sanitizedSettings(keys: Bool) throws -> [String: JSONValue] {
        var s = try AppSettings.loadForWrite().raw
        if case .object(var gh)? = s["githubBackup"] {
            gh["password"] = .string("")
            if !keys { gh["token"] = .string("") }
            s["githubBackup"] = .object(gh)
        }
        if keys { return s }
        s["services"] = nil
        s["apiKey"] = .string("")
        if case .object(var push)? = s["bgPush"], case .object(var ch)? = push["channel"] {
            for k in ["url", "key", "iv", "token"] { ch[k] = .string("") }
            push["channel"] = .object(ch)
            s["bgPush"] = .object(push)
        }
        return s
    }
}
