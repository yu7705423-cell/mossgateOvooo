import Foundation

/// 书（网页版 system/book.js）。txt 与 epub 读成一段纯文本加一张章节表，之后一切都按「第几个字」算。
///
/// 正文不进 ebooks 行里：另存进 files 域（与网页版同一处，导出时一并带上），要读时才取，取过一次缓存着。
/// 字数、进度、章节起点、段评的位置都按 UTF-16 计（和网页版 JS 字符串的长度同一个口径），导入的进度与段评才对得上。
enum Books {
    static let collection = "ebooks"
    /// 一页多少字。阅读页、一起读、进度都按它算
    static let page = 2400
    static let maxBytes = 80 * 1024 * 1024

    struct Chapter: Equatable, Sendable {
        var title: String
        var start: Int
        var end: Int
    }

    struct Book: Identifiable, Equatable, Sendable {
        var row: Row
        var id: String { row.id }
        var title: String { row.string("title") }
        var author: String { row.string("author") }
        var kind: String { row.string("kind") }
        var fileId: String { row.string("fileId") }
        var cover: String { row.string("cover") }
        var chars: Int { Int(row.number("chars") ?? 0) }
        var at: Int { Int(row.number("at") ?? 0) }
        var lastAt: Double { row.number("lastAt") ?? 0 }
        var chapters: [Chapter] {
            (row["chapters"]?.array ?? []).compactMap { c in
                guard let s = c["start"]?.number else { return nil }
                return Chapter(title: c["title"]?.string ?? "", start: Int(s), end: Int(c["end"]?.number ?? s))
            }
        }
        var crew: [String] { row.strings("crew") }
    }

    static func all() -> [Book] {
        ((try? Database.shared.all(collection)) ?? []).map(Book.init(row:)).sorted { $0.lastAt > $1.lastAt }
    }

    static func get(_ id: String) -> Book? {
        guard !id.isEmpty, let r = try? Database.shared.get(collection, id: id) else { return nil }
        return Book(row: r)
    }

    // MARK: - 读文件

    struct Parsed: Equatable {
        var kind: String
        var title: String
        var author: String
        var text: String
        var chapters: [Chapter]
        var cover: Data?
    }

    /// 中文 txt 十有八九是 GBK：先按 UTF-8 严格解一遍，不行再退回 GB18030、Big5
    static func decode(_ data: Data) -> String {
        var text: String
        if let t = String(data: data, encoding: .utf8) { text = t }
        else {
            let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
            text = String(data: data, encoding: gb) ?? String(data: data, encoding: big5) ?? String(decoding: data, as: UTF8.self)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    private static let chapterLine = Subtitle.rx(#"^[ \t　]*(?:第\s*[0-9零一二三四五六七八九十百千两]+\s*[章节回卷篇部]|序章|楔子|尾声|后记|番外|Chapter\s+\d+)[^\n]{0,40}$"#)

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 从正文里找章节。找不到就整本算一章
    static func chapters(of text: String) -> [Chapter] {
        var out: [Chapter] = []
        var at = 0
        for line in text.components(separatedBy: "\n") {
            let t = trimmed(line)
            if !t.isEmpty, Subtitle.groups(chapterLine, t) != nil, t.utf16.count <= 44 {
                out.append(Chapter(title: t, start: at, end: 0))
            }
            at += line.utf16.count + 1
        }
        let total = text.utf16.count
        if out.isEmpty { return [Chapter(title: "全文", start: 0, end: total)] }
        if out[0].start > 0 { out.insert(Chapter(title: "开头", start: 0, end: 0), at: 0) }
        for i in out.indices { out[i].end = i + 1 < out.count ? out[i + 1].start : total }
        return out
    }

    private static let scriptStyle = Subtitle.rx(#"<(script|style)[\s\S]*?</\1>"#, [.caseInsensitive])
    private static let blockEnd = Subtitle.rx(#"</(p|div|h[1-6]|li|br)>"#, [.caseInsensitive])
    private static let brTag = Subtitle.rx(#"<br\s*/?>"#, [.caseInsensitive])
    private static let anyTag = Subtitle.rx(#"<[^>]+>"#)
    private static let spaceNl = Subtitle.rx(#"[ \t]+\n"#)
    private static let manyNl = Subtitle.rx(#"\n{3,}"#)

    static func entities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
    }

    /// 网页转纯文本（网页版 book.js 的 strip）
    static func strip(_ html: String) -> String {
        var t = Subtitle.replace(html, scriptStyle, "")
        t = Subtitle.replace(t, blockEnd, "\n")
        t = Subtitle.replace(t, brTag, "\n")
        t = Subtitle.replace(t, anyTag, "")
        t = entities(t)
        t = Subtitle.replace(t, spaceNl, "\n")
        return Subtitle.replace(t, manyNl, "\n\n")
    }

    /// 一个标签里的属性
    static func attrs(_ tag: String) -> [String: String] {
        var out: [String: String] = [:]
        let r = Subtitle.rx(#"([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
        let ns = tag as NSString
        for m in r.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1))
            let v = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2))
                : m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
            out[k] = v
        }
        return out
    }

    static func tags(_ name: String, in xml: String) -> [String] {
        let r = Subtitle.rx(#"<(?:[\w-]+:)?"# + name + #"\b[^>]*>"#, [.caseInsensitive])
        let ns = xml as NSString
        return r.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// 第一个这一名字的元素里的文字（带命名空间前缀的也认，dc:title）
    static func firstText(_ name: String, in xml: String) -> String {
        let r = Subtitle.rx(#"<(?:[\w-]+:)?"# + name + #"\b[^>]*>([\s\S]*?)</(?:[\w-]+:)?"# + name + #">"#, [.caseInsensitive])
        guard let g = Subtitle.groups(r, xml), let body = g[1] else { return "" }
        return trimmed(entities(Subtitle.replace(body, anyTag, "")))
    }

    /// epub 就是一个 zip：container.xml 指向 opf，opf 里写着按什么顺序读哪几个文件
    static func parseEpub(_ data: Data) throws -> Parsed {
        let zip = try ZipReader(data: data)
        func pick(_ name: String) -> Data? {
            guard let hit = zip.names.first(where: { $0.lowercased() == name.lowercased() }), let e = zip.entry(named: hit) else { return nil }
            return zip.contents(of: e)
        }
        func text(_ d: Data) -> String { String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self) }
        guard let container = pick("META-INF/container.xml") else { throw StoreError(message: "这不是一个 epub：找不到 container.xml") }
        guard let root = tags("rootfile", in: text(container)).first, let opfPath = attrs(root)["full-path"], !opfPath.isEmpty else {
            throw StoreError(message: "这个 epub 里没写正文清单的位置")
        }
        guard let opfData = pick(opfPath) else { throw StoreError(message: "这个 epub 的正文清单丢了") }
        let opf = text(opfData)
        let base = opfPath.contains("/") ? String(opfPath[...opfPath.lastIndex(of: "/")!]) : ""
        func join(_ href: String) -> String {
            let p = href.hasPrefix("/") ? String(href.dropFirst()) : base + href
            return p.replacingOccurrences(of: #"[^/]+/\.\./"#, with: "", options: .regularExpression)
        }
        let title = firstText("title", in: opf)
        let author = firstText("creator", in: opf)

        struct Item { var href: String; var type: String; var props: String }
        var items: [String: Item] = [:]
        for t in tags("item", in: opf) {
            let a = attrs(t)
            items[a["id"] ?? ""] = Item(href: join(a["href"] ?? ""), type: a["media-type"] ?? "", props: a["properties"] ?? "")
        }
        // 封面：manifest 里标了 cover-image 的，或者 metadata 里指名的那个
        let coverId = tags("meta", in: opf).map(attrs).first { $0["name"] == "cover" }?["content"]
        let coverItem = items.values.first { $0.props.contains("cover-image") } ?? coverId.flatMap { items[$0] }
        let cover = coverItem.flatMap { $0.type.hasPrefix("image/") ? pick($0.href) : nil }

        let order = tags("itemref", in: opf).compactMap { attrs($0)["idref"] }.compactMap { items[$0] }
            .filter { $0.type.range(of: "html|xml", options: .regularExpression) != nil }
        guard !order.isEmpty else { throw StoreError(message: "这个 epub 里没有正文") }

        let head = Subtitle.rx(#"<h[1-3][^>]*>([\s\S]*?)</h[1-3]>"#, [.caseInsensitive])
        var parts: [String] = []
        var chapters: [Chapter] = []
        var at = 0
        for it in order {
            guard let d = pick(it.href) else { continue }
            let raw = text(d)
            let body = trimmed(strip(raw))
            guard !body.isEmpty else { continue }
            let name = trimmed(strip(Subtitle.groups(head, raw)?[1] ?? ""))
            chapters.append(Chapter(title: name.isEmpty ? "第 \(chapters.count + 1) 节" : name, start: at, end: 0))
            parts.append(body)
            at += body.utf16.count + 2
        }
        let all = parts.joined(separator: "\n\n")
        let total = all.utf16.count
        for i in chapters.indices { chapters[i].end = i + 1 < chapters.count ? chapters[i + 1].start : total }
        return Parsed(kind: "epub", title: title, author: author, text: all, chapters: chapters, cover: cover)
    }

    /// 读一个文件，还不入库。界面拿它先给用户看一眼
    static func parse(_ url: URL) throws -> Parsed {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxBytes else { throw StoreError(message: "文件超过 \(maxBytes / 1_048_576) MB") }
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) }
        catch { throw StoreError(message: "读不出这个文件：\(error.localizedDescription)") }
        let name = url.deletingPathExtension().lastPathComponent
        return try parse(data, name: name, epub: url.pathExtension.lowercased() == "epub")
    }

    static func parse(_ data: Data, name: String, epub: Bool) throws -> Parsed {
        if epub {
            var got = try parseEpub(data)
            if got.title.isEmpty { got.title = name }
            return got
        }
        let text = decode(data).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !trimmed(text).isEmpty else { throw StoreError(message: "这个文件里没有文字") }
        return Parsed(kind: "txt", title: name, author: "", text: text, chapters: chapters(of: text), cover: nil)
    }

    /// 真正入库。正文另存一份到 files，行里只留章节表
    @discardableResult
    static func add(_ p: Parsed, title: String, author: String) throws -> Book {
        guard !trimmed(p.text).isEmpty else { throw StoreError(message: "这本书没有正文") }
        let t = trimmed(title).isEmpty ? "未命名" : trimmed(title)
        let fileId = try Files.save(Data(p.text.utf8), ext: "txt", type: "text/plain")
        var cover: JSONValue = .null
        if let c = p.cover, let id = try? Images.save(c) { cover = .string(id) }
        let row = Row.new(prefix: "ebk", [
            "title": .string(t), "author": .string(trimmed(author)), "kind": .string(p.kind),
            "fileId": .string(fileId), "cover": cover, "chars": .number(Double(p.text.utf16.count)),
            "chapters": .array(p.chapters.map { .object(["title": .string($0.title), "start": .number(Double($0.start)), "end": .number(Double($0.end))]) }),
            "at": .number(0), "lastAt": .number(Date().millis),
        ])
        try Database.shared.put(collection, row)
        cache(row.id, p.text as NSString)
        // 各个角色书架上同名的占位，接上这本真书
        try? Shelf.linkImported(row.id)
        return Book(row: row)
    }

    /// 删书：书架上接着它的退回占位，段评一起清掉。正文与封面文件原样留在本机（原生版不自己删媒体）
    static func remove(_ id: String) throws {
        try Shelf.unlinkBook(id)
        try ParaNotes.dropSubject(ParaNotes.subject(.book, id))
        try Database.shared.delete(collection, id: id)
        lock.lock(); texts[id] = nil; lock.unlock()
    }

    // MARK: - 正文

    private static let lock = NSLock()
    nonisolated(unsafe) private static var texts: [String: NSString] = [:]

    private static func cache(_ id: String, _ t: NSString) { lock.lock(); texts[id] = t; lock.unlock() }

    /// 已经读进来的正文，没有就空（拼提示词时用，不读文件）
    static func peek(_ id: String) -> NSString? { lock.lock(); defer { lock.unlock() }; return texts[id] }

    /// 正文。第一次要用的时候才从 files 里取，之后缓存着
    static func text(_ id: String) -> NSString {
        if let t = peek(id) { return t }
        guard let b = get(id), !b.fileId.isEmpty, let url = MediaStore.url(.files, id: b.fileId),
              let d = try? Data(contentsOf: url, options: .alwaysMapped) else { return "" }
        let t = decode(d) as NSString
        cache(id, t)
        return t
    }

    /// 读到哪儿了。按字数记，换设备、换字号都不受影响
    static func setAt(_ id: String, _ at: Int) {
        guard var row = try? Database.shared.get(collection, id: id) else { return }
        let next = max(0, min(Int(row.number("chars") ?? 0), at))
        guard Double(next) != row.number("at") else { return }
        row["at"] = .number(Double(next))
        row["lastAt"] = .number(Date().millis)
        row.touch()
        do { try Database.shared.put(collection, row) }
        catch { Problems.report("阅读进度未能保存：\(error.localizedDescription)") }
    }

    /// 「读到百分之多少」= 当前这一页读完为止，和屏幕上那个数同一个口径
    static func percent(_ b: Book?, at: Int? = nil) -> Int {
        guard let b, b.chars > 0 else { return 0 }
        return min(100, Int((Double((at ?? b.at) + page) / Double(b.chars) * 100).rounded()))
    }

    /// 这个位置落在第几章
    static func chapterAt(_ b: Book?, _ at: Int? = nil) -> (chapter: Chapter, index: Int)? {
        guard let b else { return nil }
        let list = b.chapters
        let pos = at ?? b.at
        for i in stride(from: list.count - 1, through: 0, by: -1) where pos >= list[i].start { return (list[i], i) }
        return list.first.map { ($0, 0) }
    }

    struct Para: Equatable {
        /// 这一段在全书正文里的字符起点（段评挂在它上面）
        var at: Int
        var text: String
    }

    /// 这一页里的每一段，带上它在全书正文里的起点
    static func paragraphs(_ text: NSString, from: Int, span: Int = page) -> [Para] {
        let start = max(0, min(text.length, from))
        let chunk = text.substring(with: NSRange(location: start, length: min(text.length, start + span) - start))
        var out: [Para] = []
        var cursor = start
        for raw in chunk.components(separatedBy: "\n") {
            let t = trimmed(raw)
            if !t.isEmpty {
                let lead = raw.prefix { $0.isWhitespace }.utf16.count
                out.append(Para(at: cursor + lead, text: t))
            }
            cursor += raw.utf16.count + 1
        }
        return out
    }

    /// 从这个起点开始的那一整段（到下一个换行为止）
    static func paragraphAt(_ text: NSString, _ at: Int) -> String {
        let start = max(0, min(text.length, at))
        let nl = text.range(of: "\n", options: [], range: NSRange(location: start, length: text.length - start))
        let end = nl.location == NSNotFound ? text.length : nl.location
        return trimmed(text.substring(with: NSRange(location: start, length: end - start)))
    }

    /// 从某处起的一段正文
    static func slice(_ text: NSString, _ from: Int, _ size: Int = page) -> String {
        let start = max(0, min(text.length, from))
        return text.substring(with: NSRange(location: start, length: min(text.length, start + size) - start))
    }
}
