import Foundation

/// 把一段 Markdown 切成一块一块（网页版 ui/markdown.js 认的那几种）：标题、段落、列表、引用、代码块、分隔线、表格。
/// 只切块，行内的粗体、斜体、行内代码、链接交给系统的 AttributedString 去画（MarkdownView）。
/// 元模式的回复与场外的答复按它画（网页版 4.817、4.819）；代码块里的长行折行，不把整只气泡撑出去（4.880）。
enum MarkdownBlocks {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet([String])
        case ordered(start: Int, items: [String])
        case quote(String)
        case code(lang: String, text: String)
        case rule
        case table([[String]])
    }

    static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var orderedStart = 1
        var quote: [String] = []
        var table: [[String]] = []
        var code: [String]?
        var codeLang = ""

        func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func flushLists() {
            if !bullets.isEmpty { out.append(.bullet(bullets)); bullets = [] }
            if !ordered.isEmpty { out.append(.ordered(start: orderedStart, items: ordered)); ordered = [] }
        }
        func flushQuote() { if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] } }
        func flushTable() { if !table.isEmpty { out.append(.table(table)); table = [] } }
        func flushAll() { flushPara(); flushLists(); flushQuote(); flushTable() }

        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    out.append(.code(lang: codeLang, text: c.joined(separator: "\n")))
                    code = nil
                } else {
                    c.append(line)
                    code = c
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = []
                continue
            }
            if trimmed.isEmpty { flushAll(); continue }
            if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushAll()
                let level = trimmed[m].filter { $0 == "#" }.count
                out.append(.heading(level: level, text: String(trimmed[m.upperBound...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flushAll()
                out.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushPara(); flushLists(); flushTable()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1 {
                flushPara(); flushLists(); flushQuote()
                let cells = trimmed.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // 表头下面那一行 |---|:---:| 不是内容
                if cells.allSatisfy({ $0.range(of: #"^:?-{1,}:?$"#, options: .regularExpression) != nil }) { continue }
                table.append(cells)
                continue
            }
            if let m = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flushPara(); flushQuote(); flushTable()
                if !ordered.isEmpty { out.append(.ordered(start: orderedStart, items: ordered)); ordered = [] }
                bullets.append(String(trimmed[m.upperBound...]))
                continue
            }
            if let m = trimmed.range(of: #"^\d{1,9}[.)]\s+"#, options: .regularExpression) {
                flushPara(); flushQuote(); flushTable()
                if !bullets.isEmpty { out.append(.bullet(bullets)); bullets = [] }
                if ordered.isEmpty { orderedStart = Int(trimmed[m].filter(\.isNumber)) ?? 1 }
                ordered.append(String(trimmed[m.upperBound...]))
                continue
            }
            // 列表项下面缩进接着写的一行：并进上一项
            if line.hasPrefix("  "), !bullets.isEmpty { bullets[bullets.count - 1] += "\n" + trimmed; continue }
            if line.hasPrefix("  "), !ordered.isEmpty { ordered[ordered.count - 1] += "\n" + trimmed; continue }
            flushLists(); flushQuote(); flushTable()
            para.append(line)
        }
        // 没写完的代码块（流式写到一半）照样画成代码块
        if let c = code { flushAll(); out.append(.code(lang: codeLang, text: c.joined(separator: "\n"))) }
        flushAll()
        return out
    }
}
