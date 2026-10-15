import Foundation

/// 从 txt、md、csv、docx、xlsx 读出纯文本（网页版 doctext.js 的 readText、docfile.js 的 readXlsx）。
enum DocText {
    static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) }
        catch { throw StoreError(message: "读不出这个文件：\(error.localizedDescription)") }
        if url.pathExtension.lowercased() == "docx" { return try docx(data) }
        if url.pathExtension.lowercased() == "xlsx" { return try xlsx(data) }
        if ZipReader.looksLikeZip(data) { throw StoreError(message: "这个文件是压缩包。docx 请直接选择 .docx 文件") }
        return plain(data)
    }

    /// 纯文本：先按 UTF-8 读，读不通再按 GB18030（老的中文记事本常见）。
    static func plain(_ data: Data) -> String {
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: String.Encoding(rawValue: gb)) ?? ""
        return text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// docx：取 word/document.xml，一个 <w:p> 一段，<w:br/> 换行，只要 <w:t> 里的字。
    static func docx(_ data: Data) throws -> String {
        let zip = try ZipReader(data: data)
        guard let e = zip.entry(named: "word/document.xml"), let body = zip.contents(of: e),
              let xml = String(data: body, encoding: .utf8) else {
            throw StoreError(message: "这个 docx 里没有找到正文")
        }
        // 按 <w:p> 或 <w:p ...> 切段（不能按 "<w:p" 切：<w:pPr> 也是这个开头）
        let ns = xml as NSString
        let starts = try! NSRegularExpression(pattern: #"<w:p[\s>]"#)
            .matches(in: xml, range: NSRange(location: 0, length: ns.length)).map(\.range.location)
        let paras = starts.enumerated().map { i, at in
            ns.substring(with: NSRange(location: at, length: (i + 1 < starts.count ? starts[i + 1] : ns.length) - at))
        }
        let tRe = try! NSRegularExpression(pattern: #"<w:t(?:\s[^>]*)?>([\s\S]*?)</w:t>"#)
        let lines = paras.map { para -> String in
            let p = para.replacingOccurrences(of: #"<w:br\s*/?>"#, with: "<w:t>\n</w:t>", options: .regularExpression)
            let pns = p as NSString
            return tRe.matches(in: p, range: NSRange(location: 0, length: pns.length))
                .map { unescape(pns.substring(with: $0.range(at: 1))) }.joined()
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func all(_ pattern: String, _ s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        }
    }

    private static func texts(_ s: String) -> String {
        all(#"<t(?:\s[^>]*)?>([\s\S]*?)</t>"#, s).map { unescape($0[1]) }.joined()
    }

    /// xlsx：每张表一行一行，每格写成「坐标 内容」，用 | 隔开；不止一张表时每张前面一行 [表：名字]（与网页版 readXlsx 一致）
    static func xlsx(_ data: Data) throws -> String {
        let zip = try ZipReader(data: data)
        func text(_ name: String) -> String? { zip.entry(named: name).flatMap { zip.contents(of: $0) }.flatMap { String(data: $0, encoding: .utf8) } }
        guard let wb = text("xl/workbook.xml") else { throw StoreError(message: "这个 xlsx 里没找到工作簿") }
        var rels: [String: String] = [:]
        for tag in all(#"<Relationship\s[^>]*>"#, text("xl/_rels/workbook.xml.rels") ?? "").map({ $0[0] }) {
            if let id = all(#"\sId="([^"]+)""#, tag).first?[1], let target = all(#"\sTarget="([^"]+)""#, tag).first?[1] {
                rels[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/\(target)"
            }
        }
        var sheets: [(name: String, path: String)] = []
        for tag in all(#"<sheet\s[^>]*>"#, wb).map({ $0[0] }) {
            let name = unescape(all(#"\sname="([^"]*)""#, tag).first?[1] ?? "")
            let rid = all(#"\s[a-z]+:id="([^"]+)""#, tag).first?[1] ?? ""
            if let path = rels[rid] { sheets.append((name, path)) }
        }
        let shared = all(#"<si>([\s\S]*?)</si>"#, text("xl/sharedStrings.xml") ?? "").map { texts($0[1]) }
        let many = sheets.count > 1
        var out: [String] = []
        for sh in sheets {
            let xml = text(sh.path) ?? ""
            var rows: [Int: [String]] = [:]
            for m in all(#"<c\s([^>]*?)(?:/>|>([\s\S]*?)</c>)"#, xml) {
                guard let ref = all(#"(?:^|\s)r="([A-Z]+[0-9]+)""#, m[1]).first?[1] else { continue }
                let t = all(#"\bt="([^"]+)""#, m[1]).first?[1] ?? ""
                let inner = m[2]
                let v: String
                if t == "s" { v = Int(all(#"<v>([^<]*)</v>"#, inner).first?[1] ?? "").flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? "" }
                else if t == "inlineStr" { v = texts(inner) }
                else { v = unescape(all(#"<v>([^<]*)</v>"#, inner).first?[1] ?? "") }
                guard !v.isEmpty, let r = Int(ref.drop(while: { $0.isLetter })) else { continue }
                rows[r, default: []].append("\(many ? "\(sh.name)!" : "")\(ref) \(v.replacingOccurrences(of: "\n", with: " "))")
            }
            if many { out.append("[表：\(sh.name)]") }
            for r in rows.keys.sorted() { out.append(rows[r]!.joined(separator: " | ")) }
        }
        return out.joined(separator: "\n")
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
