import Foundation

/// 从 txt、md、docx 读出纯文本（网页版 src/system/doctext.js 的 readText）。
enum DocText {
    static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) }
        catch { throw StoreError(message: "读不出这个文件：\(error.localizedDescription)") }
        if url.pathExtension.lowercased() == "docx" { return try docx(data) }
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

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
