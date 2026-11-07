import Foundation

/// 美化包的文件（网页版 system/skinfile.js，ARCHITECTURE 4.239）：导出成 JSON、TXT、DOCX，或复制为文字。
///
/// TXT 与 DOCX 里放的不是 JSON 原文，而是两行标记包着的 base64（经聊天软件转手，引号、换行被改了也读得回）；
/// 读回来走 `Skins.parsePack`。这是本应用自己导出的自己的格式（网页版第 17 条的例外），不认别家的格式。
///
/// 作者署名：导出时填一次，记在设置里（settings.skinAuthor，与网页版同一项），之后自动带上；名字后缀「by 作者」，
/// 只改导出去的那一份。
enum SkinFile {
    enum Format: String, CaseIterable, Identifiable {
        case json, txt, docx
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
    }

    static let begin = "-----BEGIN EIRA SKIN-----"
    static let end = "-----END EIRA SKIN-----"

    static func author(_ s: AppSettings = .load()) -> String {
        (s.raw["skinAuthor"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setAuthor(_ v: String) throws {
        var s = try AppSettings.loadForWrite()
        s.raw["skinAuthor"] = .string(v.trimmingCharacters(in: .whitespacesAndNewlines))
        try s.save()
    }

    /// 名字后缀「by 作者」。已经是这个作者的后缀就不再加
    static func signed(_ name: String, _ who: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = t.isEmpty ? "未命名" : t
        let a = who.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty || n.hasSuffix(" by \(a)") { return n }
        return "\(n) by \(a)"
    }

    /// 一份美化写成 TXT 的正文（与网页版 toText 同样的几行）
    static func toText(_ row: Row, who: String) throws -> String {
        let name = signed(row.string("name"), who)
        let json = try ChatTheme.pack(row, name: name, author: who.trimmingCharacters(in: .whitespacesAndNewlines))
        let b64 = Data(json.utf8).base64EncodedString()
        var lines: [String] = []
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 76, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[i..<j]))
            i = j
        }
        let a = who.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([
            "Eira 美化包：\(name)",
        ] + (a.isEmpty ? [] : ["作者：\(a)"]) + [
            "",
            "导入方法：在 Eira 的「美化」中点「导入美化包」选择本文件；",
            "或复制下方 BEGIN 一行到 END 一行的全部内容（连同这两行），在「粘贴导入」中粘贴。",
            "两行标记之间的内容请勿改动。",
            "",
            begin,
        ] + lines + [end, ""]).joined(separator: "\n")
    }

    /// 导出成一个文件，交给系统的分享。文件名「美化-名字.扩展名」
    static func export(_ row: Row, format: Format, who: String) throws -> URL {
        let name = signed(row.string("name"), who)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined(separator: "_")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skin-export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("美化-\(safe).\(format.rawValue)")
        try? FileManager.default.removeItem(at: url)
        switch format {
        case .json:
            try Data(ChatTheme.pack(row, name: name, author: who.trimmingCharacters(in: .whitespacesAndNewlines)).utf8).write(to: url, options: .atomic)
        case .txt:
            try Data(toText(row, who: who).utf8).write(to: url, options: .atomic)
        case .docx:
            try docx(toText(row, who: who), to: url)
        }
        return url
    }

    /// 一段文字写成最简单的 DOCX：一行一段（读回来走 DocText.read，与网页版 toDocx 读出来的一样）
    static func docx(_ text: String, to url: URL) throws {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let paras = text.components(separatedBy: "\n").map { line in
            line.isEmpty ? "<w:p/>" : "<w:p><w:r><w:t xml:space=\"preserve\">\(esc(line))</w:t></w:r></w:p>"
        }.joined()
        let doc = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"#
            + paras + "</w:body></w:document>"
        let types = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#
        let rels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#
        let z = try ZipWriter(url: url)
        try z.add(name: "[Content_Types].xml", data: Data(types.utf8))
        try z.add(name: "_rels/.rels", data: Data(rels.utf8))
        try z.add(name: "word/document.xml", data: Data(doc.utf8))
        try z.finish()
    }

    /// 导出之前先说清楚带走了什么（网页版 exportOne 的确认框）。没什么要说的为空
    static func exportNotes(_ row: Row) -> [String] {
        var lines: [String] = []
        let css = row.string("css")
        let (data, remote, local) = assets(css)
        if local > 0 { lines.append("其中 \(local) 处引用的是本机地址，导出后在别人那里显示为空白。") }
        if remote > 0 { lines.append("其中 \(remote) 处引用了网络地址，对方需要能访问该地址。") }
        if data > 0 { lines.append("其中 \(data) 处图片已内联在文件中，文件体积相应增大。") }
        if let st = SkinGen.shared.state(row["gen"]), st.images > 0 {
            lines.append("其中内嵌 \(st.images) 张图片，约 \(Int((Double(st.bytes) / 1024).rounded())) KB，一并带走。")
        }
        return lines
    }

    /// CSS 里 url() 引用的三种（网页版 assetsOf）：内联的、网络地址、本机地址
    static func assets(_ css: String) -> (data: Int, remote: Int, local: Int) {
        guard let re = try? NSRegularExpression(pattern: #"url\(\s*(['"]?)([^'")]+)\1\s*\)"#, options: [.caseInsensitive]) else { return (0, 0, 0) }
        let ns = css as NSString
        var d = 0, r = 0, l = 0
        for m in re.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
            let u = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces).lowercased()
            if u.hasPrefix("data:") { d += 1 } else if u.hasPrefix("http://") || u.hasPrefix("https://") { r += 1 } else { l += 1 }
        }
        return (d, r, l)
    }
}
