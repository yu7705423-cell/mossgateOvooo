import Foundation

/// 在对话里发一份文件（网页版 system/docfile.js 的 sendFromUser，4.271）：文件本身存进文件域，落一条 kind 为 file 的消息，
/// 读出来的正文存在消息上。进上下文时只有最近一份文件带正文（按「文件正文最多带多少字」截断），更早的只带文件名。
/// 发文件和发图片一样，本身不触发回复。原生版暂不支持 xlsx，也不在原文件上填写。
enum ChatFiles {
    static let exts = ["txt", "md", "csv", "docx"]

    static func sizeText(_ n: Double) -> String {
        n >= 1_048_576 ? String(format: "%.1f MB", n / 1_048_576) : n >= 1024 ? "\(Int((n / 1024).rounded())) KB" : "\(Int(n)) B"
    }

    /// 存进文件域（与网页版同一个 files 域，导出时一并带上），返回文件 id
    static func save(_ data: Data, ext: String) throws -> String {
        let id = Ids.make("file")
        let dir = AppPaths.media.appendingPathComponent(MediaKind.files.rawValue, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("\(id).\(ext)"), options: .atomic)
        } catch {
            throw StoreError(message: "文件写入失败：\(error.localizedDescription)")
        }
        try Database.shared.registerMedia(kind: MediaKind.files.rawValue, id: id, ext: ext, bytes: data.count)
        return id
    }

    @discardableResult
    static func send(_ url: URL, chatId: String) throws -> Message {
        let name = url.lastPathComponent.isEmpty ? "文件" : url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard exts.contains(ext) else { throw StoreError(message: "只支持 txt、md、csv、docx") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw StoreError(message: "读不出这个文件：\(error.localizedDescription)") }
        let text = try DocText.read(url)
        let fileId = try save(data, ext: ext)
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: "[文件：\(name)]", kind: "file")
        m.row["fileId"] = .string(fileId)
        m.row["name"] = .string(name)
        m.row["ext"] = .string(ext)
        m.row["size"] = .number(Double(data.count))
        m.row["text"] = .string(text)
        m.row["slots"] = .number(0)
        m.row["media"] = .string("done")
        m = try Repo.append(m)
        if var c = try Repo.chat(chatId) {
            c.row["lastMessageAt"] = .number(Date().millis)
            c.row.touch()
            try Repo.save(c)
        }
        return m
    }

    /// 历史里那一份带正文的：窗口里最近一份有正文的文件（我发的，或角色发来、已经造好的）
    static func lastWithText(_ msgs: [Message]) -> String? {
        msgs.last(where: { $0.kind == "file" && !$0.row.string("text").isEmpty && ($0.role == .user || $0.row.string("media") == "done") })?.id
    }

    static func body(_ m: Message, _ s: AppSettings) -> String {
        let t = m.row.string("text")
        let cap = max(0, Int((s.raw["fileTextMax"]?.number ?? 6000).rounded()))   // 网页版默认 6000，0 = 全带（4.271）
        return cap > 0 && t.count > cap ? String(t.prefix(cap)) + "\n(truncated)" : t
    }
}
