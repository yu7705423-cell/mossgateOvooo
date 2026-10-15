import Foundation

/// 世界书的文件：批量导入与导出（网页版 system/lorefile.js，ARCHITECTURE 4.235）。
///
/// 只认 txt、md、docx，外加装着它们的 zip。不做 JSON（规约第 17 条）。一个文件一本，写法：
///
///     # 书名
///     用途：对话
///     全局生效：否
///
///     ## 条目标题
///     关键词：甲、乙
///     常驻：否
///     启用：是
///     位置：角色前
///     深度：0
///
///     正文……
///
/// 别处来的文字也照这个读：有 `## ` 小标题就一个小标题一条，没有就整篇一条，标题取文件名。
/// 读进来先在确认页上逐本定设置，确定了才入库。
enum LoreFile {
    static let purposeName = ["chat": "对话", "image": "生图", "voice": "语音", "memory": "记忆总结", "forum": "论坛"]
    static let purposeOf = ["对话": "chat", "生图": "image", "语音": "voice", "记忆总结": "memory", "记忆": "memory", "论坛": "forum"]
    static let cardOpen = "----- 卡片模板开始 -----", cardClose = "----- 卡片模板结束 -----"

    private static func yes(_ v: String) -> Bool {
        v.trimmingCharacters(in: .whitespaces).range(of: #"^(是|开|开启|true|yes|1)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func yn(_ v: Bool) -> String { v ? "是" : "否" }

    struct Draft: Identifiable {
        let id = UUID()
        var source: String
        var name: String
        var purpose = "chat"
        var global = false
        var description = ""
        var entries: [[String: JSONValue]] = []
        /// 条目里带着本应用自己写的设置行（导出再导回来的那种）
        var own = false
    }

    struct Options {
        var include = true
        var name: String
        var purpose: String
        var global: Bool
        var keepOwn: Bool
        var enabled = true
        var constant: Bool
        var part = "before"
        var depth = 0

        init(_ d: Draft) {
            name = d.name; purpose = d.purpose; global = d.global; keepOwn = d.own
            // 没有关键词的条目只有常驻才会注入。整篇读成一条的那种没有关键词，默认常驻
            constant = !d.entries.contains { !($0["keys"]?.array ?? []).isEmpty }
        }
    }

    static func blankEntry() -> [String: JSONValue] {
        ["id": .string(Ids.make("e")), "comment": .string(""), "keys": .array([]), "secondaryKeys": .array([]), "content": .string(""),
         "enabled": .bool(true), "constant": .bool(false), "priority": .number(100), "order": .number(0),
         "part": .string("before"), "depth": .number(0), "caseSensitive": .bool(false), "probability": .number(100)]
    }

    private static func list(_ v: String) -> JSONValue { .array(Knowledge.splitList(v).map { .string($0) }) }

    /// 正文里夹着的卡片模板（base64 的 JSON）取出来
    private static func takeCard(_ text: String) -> (card: JSONValue, rest: String)? {
        guard let a = text.range(of: cardOpen), let b = text.range(of: cardClose, range: a.upperBound..<text.endIndex) else { return nil }
        let raw = text[a.upperBound..<b.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(raw)), let card = try? JSONValue.parse(data) else { return nil }
        let rest = (String(text[..<a.lowerBound]) + String(text[b.upperBound...])).trimmingCharacters(in: .whitespacesAndNewlines)
        return (card.object != nil ? card : .object([:]), rest)
    }

    private static let setting = try! NSRegularExpression(pattern: #"^(关键词|次要关键词|常驻|启用|位置|深度|优先级|概率|类型)[:：]\s*(.*)$"#)

    private static func entryOf(_ title: String, _ body: String) -> (entry: [String: JSONValue], set: Int) {
        var e = blankEntry()
        e["comment"] = .string(title.trimmingCharacters(in: .whitespaces))
        let lines = body.components(separatedBy: "\n")
        var i = 0
        while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        var set = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            let ns = t as NSString
            guard let m = setting.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { break }
            set += 1
            let k = ns.substring(with: m.range(at: 1)), v = ns.substring(with: m.range(at: 2))
            switch k {
            case "关键词": e["keys"] = list(v)
            case "次要关键词": e["secondaryKeys"] = list(v)
            case "常驻": e["constant"] = .bool(yes(v))
            case "启用": e["enabled"] = .bool(yes(v))
            case "位置": e["part"] = .string(v.contains("后") ? "after" : "before")
            case "深度": e["depth"] = .number(max(0, (Double(v) ?? 0).rounded()))
            case "优先级": e["priority"] = .number(Double(v) ?? 100)
            case "概率": e["probability"] = .number(max(0, min(100, Double(v) ?? 100)))
            case "类型": if v.contains("卡片") { e["type"] = .string("card") }
            default: break
            }
            i += 1
        }
        let content = lines[i...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        e["content"] = .string(content)
        if let c = takeCard(content) {
            e["type"] = .string("card"); e["card"] = c.card; e["content"] = .string(c.rest)
        } else if e["type"]?.string == "card" {
            e["card"] = .object(["html": .string(""), "fields": .object([:]), "width": .string("bubble"), "ratio": .string("4:3"),
                                 "images": .bool(false), "sampleText": .string("")])
        }
        return (e, set)
    }

    /// 一段文本读成一本书的草稿。name 是取不到 # 标题时用的名字（文件名）
    static func fromText(_ text: String, name: String = "", source: String = "") -> Draft {
        var src = text.replacingOccurrences(of: "\r\n", with: "\n")
        if src.hasPrefix("\u{FEFF}") { src.removeFirst() }
        let lines = src.components(separatedBy: "\n")
        var d = Draft(source: source.isEmpty ? name : source, name: name.isEmpty ? "未命名世界书" : name)
        var i = 0
        while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        if i < lines.count, lines[i].hasPrefix("# ") {
            d.name = String(lines[i].dropFirst(2)).trimmingCharacters(in: .whitespaces)
            i += 1
        }
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { i += 1; continue }
            guard let colon = t.firstIndex(where: { $0 == ":" || $0 == "：" }) else { break }
            let k = String(t[..<colon]), v = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch k {
            case "用途": d.purpose = purposeOf[v] ?? "chat"
            case "全局生效": d.global = yes(v)
            case "说明": d.description = v
            default: break
            }
            guard ["用途", "全局生效", "说明"].contains(k) else { break }
            d.own = true
            i += 1
        }
        // 按行首的「## 」切
        var lead: [String] = []
        var parts: [(title: String, body: [String])] = []
        for line in lines[min(i, lines.count)...] {
            if line.hasPrefix("## ") { parts.append((String(line.dropFirst(3)), [])) }
            else if parts.isEmpty { lead.append(line) }
            else { parts[parts.count - 1].body.append(line) }
        }
        let leadText = lead.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        func constant(_ title: String, _ content: String) -> [String: JSONValue] {
            var e = blankEntry()
            e["comment"] = .string(title); e["content"] = .string(content); e["constant"] = .bool(true)
            return e
        }
        if parts.isEmpty {
            if !leadText.isEmpty { d.entries.append(constant(d.name, leadText)) }
            return d
        }
        if !leadText.isEmpty { d.entries.append(constant("前言", leadText)) }
        for p in parts {
            let r = entryOf(p.title, p.body.joined(separator: "\n"))
            if r.set > 0 { d.own = true }
            d.entries.append(r.entry)
        }
        return d
    }

    private static func baseName(_ n: String) -> String {
        let last = n.split(separator: "/").last.map(String.init) ?? n
        return last.replacingOccurrences(of: #"\.(txt|md|docx)$"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static func readable(_ n: String) -> Bool {
        n.range(of: #"\.(txt|md|docx)$"#, options: [.regularExpression, .caseInsensitive]) != nil
            && n.range(of: #"(^|/)(__MACOSX/|\.)"#, options: .regularExpression) == nil
    }

    /// 选中的文件读成草稿。zip 里的 txt、md、docx 一个一本。读不了的记进 failed，不拦别的
    static func readFiles(_ urls: [URL]) -> (drafts: [Draft], failed: [String]) {
        var drafts: [Draft] = [], failed: [String] = []
        func one(_ data: Data, _ name: String) {
            let text = name.lowercased().hasSuffix(".docx") ? ((try? DocText.docx(data)) ?? "") : DocText.plain(data)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { failed.append("\(name)：没有文字"); return }
            drafts.append(fromText(text, name: baseName(name), source: name))
        }
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: u) else { failed.append("\(u.lastPathComponent)：读不出这个文件"); continue }
            if u.pathExtension.lowercased() == "zip" {
                do {
                    let z = try ZipReader(data: data)
                    for e in z.entries where readable(e.name) {
                        if let d = z.contents(of: e) { one(d, e.name) } else { failed.append("\(e.name)：解不开") }
                    }
                } catch { failed.append("\(u.lastPathComponent)：\(error.localizedDescription)") }
            } else { one(data, u.lastPathComponent) }
        }
        return (drafts, failed)
    }

    /// 确认页上定好的草稿入库
    @discardableResult
    static func save(_ d: Draft, _ o: Options) throws -> Lorebook {
        let entries: [JSONValue] = d.entries.map { e in
            var x = e
            x["id"] = .string(Ids.make("e"))
            if !(o.keepOwn && d.own) {
                x["enabled"] = .bool(o.enabled); x["constant"] = .bool(o.constant)
                x["part"] = .string(o.part == "after" ? "after" : "before"); x["depth"] = .number(Double(max(0, o.depth)))
            }
            return .object(x)
        }
        let name = o.name.trimmingCharacters(in: .whitespaces)
        var row = Row.new(prefix: "lb", [
            "name": .string(name.isEmpty ? "未命名世界书" : name), "description": .string(d.description),
            // 论坛世界书只进绑了它的论坛，「全局」对它不起作用
            "global": .bool(o.purpose == "forum" ? false : o.global), "entries": .array(entries),
        ])
        for p in ["image", "voice", "memory", "forum"] {
            row["for\(p.prefix(1).uppercased())\(p.dropFirst())"] = .bool(o.purpose == p)
        }
        try Database.shared.put(Collections.lorebooks, row)
        return Lorebook(row: row)
    }

    // MARK: - 导出

    private static func cardBlock(_ card: JSONValue) -> String {
        let data = (try? card.encoded()) ?? Data("{}".utf8)
        let b64 = data.base64EncodedString()
        var lines = [cardOpen]
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 76, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[i..<j]))
            i = j
        }
        lines.append(cardClose)
        return lines.joined(separator: "\n")
    }

    /// 一本书写成文本
    static func toText(_ book: Row) -> String {
        let purpose = book.bool("forImage") ? "image" : book.bool("forVoice") ? "voice" : book.bool("forMemory") ? "memory" : book.bool("forForum") ? "forum" : "chat"
        var out = ["# \(book.string("name").isEmpty ? "未命名世界书" : book.string("name"))", "用途：\(purposeName[purpose] ?? "对话")",
                   "全局生效：\(yn(book.bool("global")))"]
        if !book.string("description").isEmpty { out.append("说明：\(book.string("description").replacingOccurrences(of: "\n", with: " "))") }
        for v in book["entries"]?.array ?? [] {
            guard let e = v.object else { continue }
            let content = (e["content"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let comment = e["comment"]?.string ?? ""
            out += ["", "## \(comment.isEmpty ? (String(content.prefix(18)).replacingOccurrences(of: "\n", with: " ").isEmpty ? "未命名条目" : String(content.prefix(18)).replacingOccurrences(of: "\n", with: " ")) : comment)"]
            let keys = e["keys"]?.array?.compactMap(\.string) ?? []
            if !keys.isEmpty { out.append("关键词：\(keys.joined(separator: "、"))") }
            let sec = e["secondaryKeys"]?.array?.compactMap(\.string) ?? []
            if !sec.isEmpty { out.append("次要关键词：\(sec.joined(separator: "、"))") }
            let card = e["type"]?.string == "card"
            if card { out.append("类型：卡片") }
            out += ["常驻：\(yn(e["constant"]?.bool == true))", "启用：\(yn(e["enabled"]?.bool != false))",
                    "位置：\(e["part"]?.string == "after" ? "角色后" : "角色前")", "深度：\(max(0, Int((e["depth"]?.number ?? 0).rounded())))"]
            if let p = e["priority"]?.number, p != 100 { out.append("优先级：\(Weather.fmt(p))") }
            if let p = e["probability"]?.number, p != 100 { out.append("概率：\(Weather.fmt(p))") }
            out += ["", content]
            if card { out += ["", cardBlock(e["card"] ?? .object([:]))] }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func safe(_ n: String) -> String {
        let s = String(n.replacingOccurrences(of: #"[\\/:*?"<>|\n\r\t]"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).prefix(60))
        return s.isEmpty ? "世界书" : s
    }

    /// 导出成 txt：一本时一个文件，多本时装进一个 zip。回来的是写好的文件地址
    static func exportFile(_ books: [Row]) throws -> URL {
        guard !books.isEmpty else { throw StoreError(message: "没有选中任何世界书") }
        let dir = FileManager.default.temporaryDirectory
        var seen: [String: Int] = [:]
        let names = books.map { b -> String in
            let base = safe(b.string("name"))
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            return "\(n > 1 ? "\(base) (\(n))" : base).txt"
        }
        if books.count == 1 {
            let url = dir.appendingPathComponent(names[0])
            try Data(toText(books[0]).utf8).write(to: url)
            return url
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let url = dir.appendingPathComponent("世界书-\(f.string(from: Date())).zip")
        try? FileManager.default.removeItem(at: url)
        let z = try ZipWriter(url: url)
        for (i, b) in books.enumerated() { try z.add(name: names[i], data: Data(toText(b).utf8)) }
        try z.finish()
        return url
    }
}
