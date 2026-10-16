import CoreText
import Foundation
import UIKit

/// 自定义字体（网页版 system/fonts.js）。记录存在 settings.fonts，与网页版同一种写法：
///   { id, name, fileId, bytes }       传的文件，存在本机
///   { id, name, url, fileId, bytes }  按网址添加、存了一份到本机
///   { id, name, url }                 只有链接：不存进应用的数据，文件放在系统缓存里，被系统清掉了用到时按网址再取一次
///   { id, name, css, family }         样式表网址（Google Fonts 那种）：原生版读不了样式表，不显示
/// 选中的那几槽：fontBody 正文、fontSerif 标题宋体（fontHand 手写体原生版暂时没有用到的地方，照旧留着）。
/// 用 CoreText 注册进本进程，按注册出来的 PostScript 名取字。
enum Fonts {
    struct Rec: Identifiable, Equatable {
        let id: String
        let name: String
        let fileId: String
        let url: String
        let css: String
        let bytes: Int
    }

    static func list(_ s: AppSettings) -> [Rec] {
        (s.raw["fonts"]?.array ?? []).compactMap { v in
            guard let id = v["id"]?.string, !id.isEmpty else { return nil }
            return Rec(id: id, name: v["name"]?.string ?? "字体", fileId: v["fileId"]?.string ?? "",
                       url: v["url"]?.string ?? v["source"]?.string ?? "", css: v["css"]?.string ?? "",
                       bytes: Int(v["bytes"]?.number ?? 0))
        }
    }

    // MARK: - 注册

    nonisolated(unsafe) private static var names: [String: String] = [:]
    /// 正文与标题宋体当前用的 PostScript 名；没选或注册不上为 nil，回到默认
    nonisolated(unsafe) private(set) static var body: String?
    nonisolated(unsafe) private(set) static var serif: String?
    nonisolated(unsafe) private(set) static var key = ""

    /// 注册一份字体文件，交回 PostScript 名
    static func register(_ data: Data) throws -> String {
        guard let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider),
              let ps = font.postScriptName as String? else {
            throw StoreError(message: "这个文件解析不出字体，请换一个 ttf 或 otf 文件")
        }
        var err: Unmanaged<CFError>?
        if !CTFontManagerRegisterGraphicsFont(font, &err) {
            // 已经注册过同一款（同名）也算成功
            if UIFont(name: ps, size: 12) == nil {
                throw StoreError(message: "这个字体未能装上，请换一个 ttf 或 otf 文件")
            }
        }
        return ps
    }

    /// 只有链接的字体放在系统缓存里（不进应用数据、不进备份；系统空间不够时可以清掉）
    static func cacheURL(_ id: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("fonts", isDirectory: true).appendingPathComponent("\(id).font")
    }

    /// 某条记录的 PostScript 名：本机存的、或缓存里有的就注册，都没有返回 nil
    static func psName(_ rec: Rec) -> String? {
        if let n = names[rec.id] { return n }
        var file: URL?
        if !rec.fileId.isEmpty { file = MediaStore.url(.files, id: rec.fileId) }
        else if !rec.url.isEmpty, let c = cacheURL(rec.id), FileManager.default.fileExists(atPath: c.path) { file = c }
        guard let file, let data = try? Data(contentsOf: file), let n = try? register(data) else { return nil }
        names[rec.id] = n
        return n
    }

    private static func download(_ link: String) async throws -> Data {
        guard let u = URL(string: link), u.scheme == "https" || u.scheme == "http" else { throw StoreError(message: "网址无效") }
        let (data, resp) = try await URLSession.shared.data(from: u)
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { throw StoreError(message: "下载失败") }
        return data
    }

    private static func writeCache(_ id: String, _ data: Data) {
        guard let c = cacheURL(id) else { return }
        try? FileManager.default.createDirectory(at: c.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: c, options: .atomic)
    }

    /// 选中的只有链接、缓存又被清掉了的：按网址取回来，取到了重新套用
    nonisolated(unsafe) private static var fetching: Set<String> = []
    private static func refetch(_ rec: Rec) {
        guard !fetching.contains(rec.id) else { return }
        fetching.insert(rec.id)
        Task.detached {
            defer { Task { @MainActor in Fonts.fetching.remove(rec.id) } }
            guard let data = try? await download(rec.url), (try? register(data)) != nil else { return }
            writeCache(rec.id, data)
            await MainActor.run { SettingsModel.shared.reload() }
        }
    }

    /// 设置读进来或改了之后调一次
    static func apply(_ s: AppSettings) {
        let all = list(s)
        func pick(_ key: String) -> String? {
            guard let id = s.raw[key]?.string, !id.isEmpty, let rec = all.first(where: { $0.id == id }) else { return nil }
            if let n = psName(rec) { return n }
            if rec.fileId.isEmpty && !rec.url.isEmpty { refetch(rec) }
            return nil
        }
        body = pick("fontBody")
        serif = pick("fontSerif")
        key = "\(body ?? "")|\(serif ?? "")"
    }

    // MARK: - 增删

    private static func ext(_ data: Data) -> String {
        data.starts(with: [0x4F, 0x54, 0x54, 0x4F]) ? "otf" : "ttf"
    }

    /// 传一个字体文件。先验能不能用，坏文件不存
    @discardableResult
    static func add(_ data: Data, name: String, url: String = "") throws -> Rec {
        let ps = try register(data)
        let fileId = try Files.save(data, ext: ext(data), type: "font/\(ext(data))")
        let id = "fnt-" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let n = name.replacingOccurrences(of: #"\.(ttf|otf|woff2?)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        var rec: [String: JSONValue] = ["id": .string(id), "name": .string(n.isEmpty ? "字体" : n), "fileId": .string(fileId),
                                        "bytes": .number(Double(data.count))]
        if !url.isEmpty { rec["url"] = .string(url) }
        var s = try AppSettings.loadForWrite()
        s.raw["fonts"] = .array((s.raw["fonts"]?.array ?? []) + [.object(rec)])
        try s.save()
        names[id] = ps
        return Rec(id: id, name: n, fileId: fileId, url: url, css: "", bytes: data.count)
    }

    /// 按字体文件的网址添加：只存链接，不存进应用的数据；先取一次验能不能用，文件放进系统缓存
    @discardableResult
    static func add(url raw: String) async throws -> Rec {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: link), u.scheme == "https" || u.scheme == "http" else { throw StoreError(message: "网址无效") }
        if u.host?.contains("fonts.googleapis.com") == true || u.pathExtension.lowercased() == "css" {
            throw StoreError(message: "原生版读不了样式表网址，请填写字体文件（ttf 或 otf）的网址")
        }
        let data = try await download(link)
        let ps = try register(data)
        let id = "fnt-" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let n = u.deletingPathExtension().lastPathComponent
        var s = try AppSettings.loadForWrite()
        s.raw["fonts"] = .array((s.raw["fonts"]?.array ?? []) + [.object(["id": .string(id), "name": .string(n.isEmpty ? "字体" : n), "url": .string(link)])])
        try s.save()
        writeCache(id, data)
        names[id] = ps
        return Rec(id: id, name: n, fileId: "", url: link, css: "", bytes: 0)
    }

    /// 只有链接的那种（网页版添加的）：存到本机
    static func keep(_ rec: Rec) async throws {
        guard rec.fileId.isEmpty, !rec.url.isEmpty, let u = URL(string: rec.url) else { return }
        let (data, _) = try await URLSession.shared.data(from: u)
        let ps = try register(data)
        let fileId = try Files.save(data, ext: ext(data), type: "font/\(ext(data))")
        var s = try AppSettings.loadForWrite()
        s.raw["fonts"] = .array((s.raw["fonts"]?.array ?? []).map { v in
            guard v["id"]?.string == rec.id, var o = v.object else { return v }
            o["fileId"] = .string(fileId)
            o["bytes"] = .number(Double(data.count))
            return .object(o)
        })
        try s.save()
        names[rec.id] = ps
    }

    /// 删掉一条；正在用的那一槽回到默认
    static func remove(_ id: String) throws {
        var s = try AppSettings.loadForWrite()
        s.raw["fonts"] = .array((s.raw["fonts"]?.array ?? []).filter { $0["id"]?.string != id })
        for k in ["fontBody", "fontSerif", "fontHand"] where s.raw[k]?.string == id { s.raw[k] = .null }
        try s.save()
        names.removeValue(forKey: id)
        if let c = cacheURL(id) { try? FileManager.default.removeItem(at: c) }
    }
}
