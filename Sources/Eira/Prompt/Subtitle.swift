import Foundation

/// 字幕（网页版 system/subtitle.js，ARCHITECTURE 4.102）。模型看不见画面，但它读得到台词：字幕就是角色「在看」的那一路输入。
///
/// 认 SRT、ASS/SSA、WebVTT 三种，都拆成同一个形状 { at, end, text }（秒），text 去掉样式标记。解不出来给空数组。
enum Subtitle {
    struct Line: Equatable, Sendable {
        var at: Double
        var end: Double
        var text: String
    }

    // MARK: - 正则

    static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        // 模式都是写死在代码里的，写错是开发时的事
        try! NSRegularExpression(pattern: p, options: o)
    }

    static func groups(_ r: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let g = m.range(at: i)
            return g.location == NSNotFound ? nil : ns.substring(with: g)
        }
    }

    static func replace(_ s: String, _ r: NSRegularExpression, _ with: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: with)
    }

    /// 按正则切开（JS 的 split(regex)）
    static func split(_ s: String, _ r: NSRegularExpression) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        var from = 0
        for m in r.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: from, length: m.range.location - from)))
            from = m.range.location + m.range.length
        }
        out.append(ns.substring(from: from))
        return out
    }

    private static let assBlock = rx(#"\{[^}]*\}"#)
    private static let tag = rx(#"<[^>]+>"#)
    private static let assBreak = rx(#"\\N|\\n"#, [.caseInsensitive])
    private static let spaces = rx(#"\s+"#)
    private static let time = rx(#"^(?:(\d+):)?(\d+):(\d+)(?:[.,](\d+))?$"#)
    private static let blocks = rx(#"\r?\n\r?\n+"#)
    private static let newline = rx(#"\r?\n"#)
    private static let isAss = rx(#"^\s*\[Script Info\]|^Dialogue\s*:"#, [.caseInsensitive, .anchorsMatchLines])
    private static let formatLine = rx(#"^Format\s*:"#, [.caseInsensitive])
    private static let dialogueLine = rx(#"^Dialogue\s*:"#, [.caseInsensitive])

    static func clean(_ s: String) -> String {
        var t = replace(s, assBlock, "")
        t = replace(t, tag, "")
        t = replace(t, assBreak, " ")
        t = replace(t, spaces, " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 0:01:02.35 / 00:01:02,350 / 01:02.35 都认
    static func toSec(_ t: String) -> Double? {
        guard let m = groups(time, t.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let frac = m[4].flatMap { Double("0.\($0)") } ?? 0
        return (Double(m[1] ?? "0") ?? 0) * 3600 + (Double(m[2] ?? "0") ?? 0) * 60 + (Double(m[3] ?? "0") ?? 0) + frac
    }

    private static func parseSrtLike(_ text: String) -> [Line] {
        var out: [Line] = []
        for block in split(text, blocks) {
            let lines = split(block, newline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard let at = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let halves = lines[at].components(separatedBy: "-->").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ").first ?? ""
            }
            guard let a = toSec(halves.first ?? "") else { continue }
            let b = halves.count > 1 ? toSec(halves[1]) : nil
            let body = clean(lines[(at + 1)...].joined(separator: " "))
            if !body.isEmpty { out.append(Line(at: a, end: b ?? a + 3, text: body)) }
        }
        return out
    }

    private static func parseAss(_ text: String) -> [Line] {
        var out: [Line] = []
        var fields: [String] = []
        for raw in split(text, newline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let rest: String = {
                guard let i = line.firstIndex(of: ":") else { return "" }
                return String(line[line.index(after: i)...])
            }()
            if groups(formatLine, line) != nil && fields.isEmpty {
                fields = rest.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard groups(dialogueLine, line) != nil else { continue }
            // 正文里可能有逗号，所以按字段数切，最后一段整个留给 text
            let cols = rest.components(separatedBy: ",")
            func idx(_ k: String) -> Int? { fields.firstIndex(of: k) }
            let iStart = idx("start") ?? 1
            let iEnd = idx("end") ?? 2
            // 没有 Format 行时网页版取的是 slice(-1)，即最后一列
            let iText = idx("text") ?? (fields.isEmpty ? cols.count - 1 : fields.count - 1)
            let a = cols.indices.contains(iStart) ? toSec(cols[iStart]) : nil
            let b = cols.indices.contains(iEnd) ? toSec(cols[iEnd]) : nil
            let body = iText >= 0 && iText < cols.count ? clean(cols[iText...].joined(separator: ",")) : ""
            guard let a, !body.isEmpty else { continue }
            out.append(Line(at: a, end: b ?? a + 3, text: body))
        }
        return out
    }

    static func parse(_ text: String) -> [Line] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let lines = groups(isAss, text) != nil ? parseAss(text) : parseSrtLike(text)
        // 稳定排序：同一时刻的几句保持原来的先后
        return lines.enumerated().filter { !$0.element.text.isEmpty }
            .sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
            .map(\.element)
    }

    /// 这一刻正在显示的那一句（段评挂在它的起始秒上）。没有就 nil
    static func cueAt(_ lines: [Line], _ sec: Double) -> Line? {
        for l in lines {
            if l.at > sec { break }
            if sec <= l.end { return l }
        }
        return nil
    }

    /// 到这一刻为止的最后 n 句。角色读的就是这一小段
    static func recentLines(_ lines: [Line], _ sec: Double, _ n: Int = 8) -> [Line] {
        var out: [Line] = []
        for l in lines {
            if l.at > sec { break }
            out.append(l)
        }
        return Array(out.suffix(max(1, n)))
    }

    struct Density: Equatable {
        var count: Int
        var talky: Bool
        var quiet: Bool
        var gap: Double
    }

    /// 这一带是密集还是安静。纯本地算，不问模型：一起看时要不要发起这一轮，判据就是它（不写进提示词）
    static func density(_ lines: [Line], _ sec: Double, window: Double = 20) -> Density {
        guard !lines.isEmpty else { return Density(count: 0, talky: false, quiet: true, gap: .infinity) }
        let near = lines.filter { $0.end >= sec - window && $0.at <= sec + window }
        var gap = Double.infinity
        for l in lines {
            if l.at > sec { break }
            gap = sec - l.end
        }
        if gap < 0 { gap = 0 }
        return Density(count: near.count, talky: near.count >= 6, quiet: near.count <= 1 || gap >= 8, gap: gap)
    }

    /// 秒写成 1:23:45 或 12:34。提纲与倒回的那一行都按这个写
    static func stamp(_ sec: Double) -> String {
        let n = max(0, sec.isFinite ? Int(sec.rounded()) : 0)
        let h = n / 3600, m = (n % 3600) / 60, s = n % 60
        func pad(_ x: Int) -> String { x < 10 ? "0\(x)" : "\(x)" }
        return h > 0 ? "\(h):\(pad(m)):\(pad(s))" : "\(m):\(pad(s))"
    }

    /// 反过来：1:23:45 / 12:34 / 83 都读成秒。模型写的时间戳要靠它认（网页版 subtitle.toSeconds）
    static func toSeconds(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, t.allSatisfy(\.isASCII), t.allSatisfy(\.isNumber) { return Double(t) }
        let parts = t.components(separatedBy: ":").map { p -> Double? in
            let x = p.trimmingCharacters(in: .whitespaces)
            return x.isEmpty ? 0 : Double(x)
        }
        guard !parts.contains(where: { $0 == nil }) else { return nil }
        let v = parts.compactMap { $0 }
        if v.count == 2 { return v[0] * 60 + v[1] }
        if v.count == 3 { return v[0] * 3600 + v[1] * 60 + v[2] }
        return nil
    }

    /// 倒回那一行写的时刻（网页版 reply.js 的 subtitleSeconds）：全角冒号也认
    static func markSeconds(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "：", with: ":")
        if !t.isEmpty, t.allSatisfy(\.isASCII), t.allSatisfy(\.isNumber) { return Double(t) }
        let parts = t.components(separatedBy: ":").map { $0.isEmpty ? 0 : Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil || !($0!.isFinite) }) else { return nil }
        let v = parts.compactMap { $0 }
        if v.count == 2 { return v[0] * 60 + v[1] }
        if v.count == 3 { return v[0] * 3600 + v[1] * 60 + v[2] }
        return nil
    }

    /// 写成 SRT（片子自带的字幕轨、B 站的字幕都落成 SRT 存进片库）
    static func toSrt(_ lines: [Line]) -> String {
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        func st(_ s: Double) -> String {
            let ms = Int(((s.isFinite ? s : 0) * 1000).rounded())
            let rest = ms % 1000
            let msText = rest < 10 ? "00\(rest)" : rest < 100 ? "0\(rest)" : "\(rest)"
            return "\(two(ms / 3_600_000)):\(two((ms / 60000) % 60)):\(two((ms / 1000) % 60)),\(msText)"
        }
        return lines.enumerated().map { i, l in "\(i + 1)\n\(st(l.at)) --> \(st(l.end))\n\(l.text.trimmingCharacters(in: .whitespacesAndNewlines))\n" }
            .joined(separator: "\n")
    }
}
