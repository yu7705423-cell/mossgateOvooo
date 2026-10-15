import Foundation

/// HTML 卡片（网页版 system/htmlcard.js，ARCHITECTURE 4.250）：世界书里的一种条目，角色在聊天里按它发一张渲染好的卡片。
///
/// 一张卡片 = 世界书条目 { type: card, comment: 卡片名, content: 说明（进提示词）, keys, constant, …,
///   card: { html: 模板, fields: { 字段名 或 列表.子字段: { desc, max, long, lines, topics, scalar } }, width, ratio, height, images, authorField } }
///
/// 只用 HTML 与 CSS，不跑脚本：
///   1. 卡片画在不跑页面脚本的网页视图里，CSP 里 script-src 'none'、不许联网（开了外部图片的只放 https 图片）；
///   2. 渲染完先清洗：脚本、iframe、表单、meta、base、事件属性、javascript: 与外部链接一律拿掉；
///   3. 占位符不许出现在网址里（src、href、<style> 里）：角色填的值只能是文字，不能拼进外部地址把东西带出去。
/// 占位符是 Mustache 的一个子集：{{字段}}、{{#列表}}…{{/列表}}、{{^字段}}为空时{{/字段}}、列表项里的 {{.}}。
/// 应用自己填的几个：{{char}} {{user}} {{char_avatar}} {{user_avatar}} {{author_avatar}}。
enum HtmlCard {
    static let system = ["char", "user", "char_avatar", "user_avatar", "author_avatar"]
    private static let systemURL: Set<String> = ["char_avatar", "user_avatar", "author_avatar"]

    // MARK: - 内置卡片（Resources/cards.json，由 scripts/sync-cards.mjs 从网页版抄来）

    static let builtinBookId = "builtin-cards"

    static let builtinEntries: [[String: JSONValue]] = {
        guard let url = Bundle.main.url(forResource: "cards", withExtension: "json"),
              let data = try? Data(contentsOf: url), let v = try? JSONValue.parse(data) else { return [] }
        return (v["entries"]?.array ?? []).compactMap(\.object)
    }()

    /// 内置那本书挂不挂、停用了哪几张，记在设置里（builtinCards）
    static func builtinState(_ s: AppSettings) -> (global: Bool, off: [String]) {
        let o = s.raw["builtinCards"]?.object ?? [:]
        return (o["global"]?.bool == true, (o["off"]?.array ?? []).compactMap(\.string))
    }

    static func setBuiltin(_ s: inout AppSettings, global: Bool? = nil, card: String? = nil, on: Bool = true) {
        var o = s.raw["builtinCards"]?.object ?? [:]
        if let global { o["global"] = .bool(global) }
        if let card {
            var off = (o["off"]?.array ?? []).compactMap(\.string).filter { $0 != card }
            if !on { off.append(card) }
            o["off"] = .array(off.map { .string($0) })
        }
        s.raw["builtinCards"] = .object(o)
    }

    // MARK: - 尺寸

    static func size(_ card: [String: JSONValue]) -> (w: Double, h: Double) {
        let w: Double = card["width"]?.string == "full" ? 340 : 270
        let ratio = card["ratio"]?.string ?? "4:3"
        switch ratio {
        case "strip": return (w, 96)
        case "1:1": return (w, w)
        case "3:4": return (w, (w * 4 / 3).rounded())
        case "long": return (w, 520)
        case "custom": return (w, max(40, (card["height"]?.number ?? 300).rounded()))
        default: return (w, (w * 3 / 4).rounded())
        }
    }

    // MARK: - 模板

    private indirect enum Node {
        case text(String)
        case variable(name: String, attr: Bool, off: Bool)
        case section(name: String, inv: Bool, kids: [Node])
    }

    private static let tag = try! NSRegularExpression(pattern: #"\{\{\{?\s*([#^/]?)\s*([^{}]*?)\s*\}?\}\}"#)
    private static let urlAttrs: Set<String> = ["src", "href", "srcset", "action", "formaction", "poster", "data", "xlink:href",
                                                "background", "lowsrc", "ping", "cite", "longdesc", "manifest", "codebase", "dynsrc", "srcdoc"]
    private static let quietAttrs: Set<String> = ["alt", "title", "aria-label"]

    /// 占位符所在的位置：正文、某个属性里、<style> 里、标签里
    private static func context(_ before: String) -> (whereIs: String, attr: String) {
        let lt = before.range(of: "<", options: .backwards)?.lowerBound
        let gt = before.range(of: ">", options: .backwards)?.lowerBound
        if let open = before.range(of: #"<style[\s>]"#, options: [.regularExpression, .backwards, .caseInsensitive]) {
            let after = before[open.lowerBound...]
            if after.range(of: #"</style\s*>"#, options: [.regularExpression, .caseInsensitive]) == nil { return ("style", "") }
        }
        if let lt, gt == nil || lt > gt! {
            let inTag = String(before[lt...])
            if let r = inTag.range(of: #"([^\s"'=<>/]+)\s*=\s*(["']?)[^"'>]*$"#, options: .regularExpression) {
                let m = String(inTag[r])
                let name = m.prefix { $0 != "=" && !$0.isWhitespace }
                return ("attr", name.lowercased())
            }
            return ("tag", "")
        }
        return ("text", "")
    }

    private static func allowed(_ name: String, _ ctx: (whereIs: String, attr: String), images: Bool) -> Bool {
        if systemURL.contains(name) { return true }
        if ctx.whereIs == "text" { return true }
        if ctx.whereIs == "style" || ctx.whereIs == "tag" { return false }
        let a = ctx.attr
        if a.hasPrefix("on") || urlAttrs.contains(a) { return false }
        if images { return quietAttrs.contains(a) || a.hasPrefix("aria-") }
        return true
    }

    private static func parse(_ tpl: String, images: Bool) -> (root: [Node], problems: [(String, String)]) {
        // 栈里每一层：区块名、是否取反、子节点
        var stack: [(name: String, inv: Bool, kids: [Node])] = [("", false, [])]
        var problems: [(String, String)] = []
        let ns = tpl as NSString
        var last = 0
        func close(_ upTo: Int) {
            while stack.count > upTo {
                let top = stack.removeLast()
                stack[stack.count - 1].kids.append(.section(name: top.name, inv: top.inv, kids: top.kids))
            }
        }
        for m in tag.matches(in: tpl, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { stack[stack.count - 1].kids.append(.text(ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
            last = m.range.location + m.range.length
            let op = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            if op == "#" || op == "^" {
                stack.append((name, op == "^", []))
            } else if op == "/" {
                // 收错名字的、多收的都不理，只收最近那个同名的
                if let i = stack.indices.dropFirst().last(where: { stack[$0].name == name }) { close(i) }
            } else {
                let ctx = context(ns.substring(to: m.range.location))
                let ok = allowed(name, ctx, images: images)
                if !ok { problems.append((name, ctx.whereIs == "attr" ? ctx.attr : ctx.whereIs)) }
                stack[stack.count - 1].kids.append(.variable(name: name, attr: ctx.whereIs != "text", off: !ok))
            }
        }
        if last < ns.length { stack[stack.count - 1].kids.append(.text(ns.substring(from: last))) }
        close(1)
        return (stack[0].kids, problems)
    }

    struct Field: Equatable { var name: String; var list: Bool; var sub: [String] }

    /// 模板里要角色填的字段，按出现顺序。包着别的字段或 {{.}} 的区块算列表（字段设置 scalar 为真时按普通字段读）
    static func fields(_ tpl: String, _ cfg: [String: JSONValue] = [:]) -> [Field] {
        var out: [Field] = []
        func add(_ f: Field) -> Int {
            if let i = out.firstIndex(where: { $0.name == f.name }) { return i }
            out.append(f)
            return out.count - 1
        }
        func walk(_ kids: [Node], inList: Bool) {
            for k in kids {
                switch k {
                case .text: break
                case let .variable(name, _, _):
                    if name == "." || system.contains(name) || name.hasPrefix("img:") { continue }
                    if !inList { _ = add(Field(name: name, list: false, sub: [])) }
                case let .section(name, inv, sub):
                    if system.contains(name) || inList { walk(sub, inList: inList); continue }
                    var inner: [String] = []
                    var dot = false
                    func scan(_ ks: [Node]) {
                        for x in ks {
                            switch x {
                            case let .variable(n, _, _):
                                if n == "." { dot = true }
                                else if n != name && !system.contains(n) && !n.hasPrefix("img:") && !inner.contains(n) { inner.append(n) }
                            case let .section(_, _, s): scan(s)
                            case .text: break
                            }
                        }
                    }
                    scan(sub)
                    if !inv && (dot || !inner.isEmpty) && cfg[name]?["scalar"]?.bool != true {
                        let i = add(Field(name: name, list: true, sub: inner))
                        out[i].list = true
                        for n in inner where !out[i].sub.contains(n) { out[i].sub.append(n) }
                    } else {
                        _ = add(Field(name: name, list: false, sub: []))
                        walk(sub, inList: false)
                    }
                }
            }
        }
        walk(parse(tpl, images: false).root, inList: false)
        return out
    }

    /// 模板里填不了的那几处（编辑页提示用）
    static func problems(_ tpl: String, images: Bool) -> [String] {
        var out = parse(tpl, images: images).problems.map { p in
            "「\(p.0)」位于\(p.1 == "style" ? "样式表" : p.1 == "tag" ? "标签" : " \(p.1) 属性")中，不会被填入"
        }
        if tpl.range(of: #"<script[\s>]"#, options: [.regularExpression, .caseInsensitive]) != nil { out.append("模板中的脚本不会运行，渲染前会被移除") }
        return out
    }

    // MARK: - 渲染

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func cfgOf(_ card: [String: JSONValue], _ name: String, _ parent: String) -> [String: JSONValue] {
        card["fields"]?[parent.isEmpty ? name : "\(parent).\(name)"]?.object ?? [:]
    }

    private static func cut(_ v: String, _ max: Double?) -> String {
        let n = Int((max ?? 0).rounded())
        guard n > 0, v.count > n else { return v }
        return String(v.prefix(n)) + "…"
    }

    /// #话题#、#话题、@名字 各包一层 .eira-topic（先切再逐段转义）
    private static let topic = try! NSRegularExpression(pattern: #"#[^#\n]{1,40}#|#[^\s#，。！？、,.!?;；:：]+|@[^\s@，。！？、,.!?;；:：]+"#)
    private static func topicHtml(_ raw: String) -> String {
        let ns = raw as NSString
        var out = "", last = 0
        for m in topic.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            out += esc(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            out += "<span class=\"eira-topic\">\(esc(ns.substring(with: m.range)))</span>"
            last = m.range.location + m.range.length
        }
        return out + esc(ns.substring(from: last))
    }

    private static func plain(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : ""
        case .array(let a): return a.compactMap { x in x.object.map { $0.values.compactMap(plain).joined(separator: " ") } ?? plain(x) }.joined(separator: "、")
        case .object(let o): return o.values.compactMap(plain).joined(separator: " ")
        case .null: return nil
        }
    }

    private static func render(_ kids: [Node], _ stack: [JSONValue], _ card: [String: JSONValue], _ parentList: String) -> String {
        func lookup(_ name: String) -> JSONValue? {
            if name == "." { return stack.last }
            for c in stack.reversed() { if let o = c.object, let v = o[name] { return v } }
            return nil
        }
        var out = ""
        for k in kids {
            switch k {
            case .text(let t): out += t
            case let .variable(name, attr, off):
                if off { continue }
                guard let raw = lookup(name), let v = plain(raw) else { continue }
                if systemURL.contains(name) { out += esc(v); continue }
                let inItem = stack.count > 1
                let cfg = cfgOf(card, name == "." ? parentList : name, inItem && name != "." ? parentList : "")
                let text = attr || cfg["topics"]?.bool != true ? esc(cut(v, cfg["max"]?.number)) : topicHtml(cut(v, cfg["max"]?.number))
                if attr { out += text.replacingOccurrences(of: "\n", with: " "); continue }
                if cfg["long"]?.bool == true {
                    let lines = max(1, Int((cfg["lines"]?.number ?? 6).rounded()))
                    out += "<span class=\"eira-long\" style=\"max-height:\(String(format: "%.1f", Double(lines) * 1.5))em\">\(text)</span>"
                } else {
                    out += text.replacingOccurrences(of: "\n", with: "<br>")
                }
            case let .section(name, inv, sub):
                let v = lookup(name)
                let empty: Bool = {
                    guard let v else { return true }
                    switch v {
                    case .null: return true
                    case .string(let s): return s.isEmpty
                    case .bool(let b): return !b
                    case .array(let a): return a.isEmpty
                    default: return false
                    }
                }()
                if inv { if empty { out += render(sub, stack, card, parentList) }; continue }
                if empty { continue }
                if let a = v?.array {
                    for item in a { out += render(sub, stack + [item], card, name) }
                } else {
                    out += render(sub, stack, card, parentList)
                }
            }
        }
        return out
    }

    /// 模板填上值，得到一段 HTML（还没清洗）
    static func fill(_ card: [String: JSONValue], values: [String: JSONValue], sys: [String: String]) -> String {
        let images = card["images"]?.bool == true
        var top = values
        for n in system { if let v = sys[n] { top[n] = .string(v) } }
        let field = card["authorField"]?.string ?? ""
        let who = field.isEmpty ? "" : (plain(values[field] ?? .null) ?? "").trimmingCharacters(in: .whitespaces)
        top["author_avatar"] = .string(who.isEmpty ? "" : who == (sys["char"] ?? "").trimmingCharacters(in: .whitespaces) ? (sys["char_avatar"] ?? "")
            : who == (sys["user"] ?? "").trimmingCharacters(in: .whitespaces) ? (sys["user_avatar"] ?? "") : "")
        return render(parse(card["html"]?.string ?? "", images: images).root, [.object(top)], card, "")
    }

    // MARK: - 清洗（第三道墙：视图本来不跑脚本，CSP 也挡着联网）

    private static func strip(_ s: String, _ pattern: String) -> String {
        s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func sanitize(_ html: String, images: Bool) -> String {
        var s = html
        for t in ["script", "iframe", "frame", "frameset", "object", "embed", "applet", "noscript", "template", "portal"] {
            s = strip(s, "<\(t)\\b[\\s\\S]*?</\(t)\\s*>")
            s = strip(s, "<\(t)\\b[^>]*>")
        }
        for t in ["base", "meta", "frame"] { s = strip(s, "<\(t)\\b[^>]*>") }
        // 表单交不出去，外壳拿掉、里面的东西留着
        s = strip(s, #"</?form\b[^>]*>"#)
        // 外部样式表：只有开了外部图片、并且是 https 的留着
        s = s.replacingOccurrences(of: #"<link\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        // 事件属性、提交地址、target
        s = strip(s, #"\s(?:on[a-z]+|formaction|action|ping|srcdoc|target)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#)
        // 链接类属性：页内跳转、data: 图片与字体留着，开了外部图片时 https 的图片留着，其余拿掉
        let linky = #"\s(src|srcset|poster|background|xlink:href|href|data|lowsrc)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let re = try? NSRegularExpression(pattern: linky, options: .caseInsensitive) else { return s }
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            var v = ""
            for g in 3...5 where m.range(at: g).location != NSNotFound { v = ns.substring(with: m.range(at: g)); break }
            v = v.trimmingCharacters(in: .whitespaces)
            let keep = ((name == "href" || name == "xlink:href") && v.hasPrefix("#"))
                || v.range(of: #"^data:(image|font)/"#, options: [.regularExpression, .caseInsensitive]) != nil
                || (images && name != "href" && v.lowercased().hasPrefix("https://"))
            if keep { out += ns.substring(with: m.range) }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        // CSS 里的 javascript: 与 expression
        out = strip(out, #"javascript\s*:"#)
        return out
    }

    /// 所有卡片都垫着的一层。模板自己的样式写在后面，同名的以它为准
    static let baseCss = "html,body{margin:0;padding:0;height:100%}html{-webkit-text-size-adjust:100%;text-size-adjust:100%}"
        + "body{font-family:-apple-system,BlinkMacSystemFont,\"PingFang SC\",\"Helvetica Neue\",sans-serif;overflow-wrap:anywhere;line-height:1.5}"
        + "img{max-width:100%}.eira-long{display:block;overflow:auto;-webkit-overflow-scrolling:touch;white-space:pre-wrap}"
        + ".eira-scroll{overflow:auto;-webkit-overflow-scrolling:touch}"

    /// 一张卡片的整页。dark：应用是不是深色（<html> 挂 eira-dark）
    static func doc(_ card: [String: JSONValue], values: [String: JSONValue], sys: [String: String], dark: Bool) -> String {
        let images = card["images"]?.bool == true
        let body = sanitize(fill(card, values: values, sys: sys), images: images)
        let csp = "default-src 'none'; style-src 'unsafe-inline'\(images ? " https:" : ""); img-src data:\(images ? " https:" : ""); font-src data:\(images ? " https:" : ""); script-src 'none'"
        return "<!DOCTYPE html><html class=\"\(dark ? "eira-dark" : "eira-light")\"><head><meta charset=\"utf-8\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
            + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>\(baseCss)</style></head><body>\(body)</body></html>"
    }

    // MARK: - 角色写的那一段

    private static let fieldLine = try! NSRegularExpression(pattern: #"^([^：:\n]{1,24}?)\s*[：:]\s*([\s\S]*)$"#)

    /// 一段「字段：值」读成值。列表字段一行一项，子字段按顺序用｜隔开；认不出的行接在上一个字段后面
    static func parseValues(_ text: String, fields: [Field]) -> [String: JSONValue] {
        let byName = Dictionary(fields.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var values: [String: JSONValue] = [:]
        var lastKey: String?
        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let k = lastKey, let cur = values[k]?.string { values[k] = .string(cur + "\n") }
                continue
            }
            let m = ReplyParser.match(fieldLine, line)
            let key = m?[1].trimmingCharacters(in: .whitespaces) ?? ""
            let isField = m != nil && (fields.isEmpty || byName[key] != nil)
            if !isField {
                guard let k = lastKey else { continue }
                if var arr = values[k]?.array, let tail = arr.last?.string {
                    arr[arr.count - 1] = .string("\(tail)\n\(line)")
                    values[k] = .array(arr)
                } else if let cur = values[k]?.string {
                    values[k] = .string(cur.isEmpty ? line : "\(cur)\n\(line)")
                }
                continue
            }
            let f = byName[key] ?? Field(name: key, list: false, sub: [])
            let v = (m?[2] ?? "").trimmingCharacters(in: .whitespaces)
            lastKey = key
            if f.list {
                var arr = values[key]?.array ?? []
                let bits = v.split(whereSeparator: { $0 == "|" || $0 == "｜" }).map { $0.trimmingCharacters(in: .whitespaces) }
                if !f.sub.isEmpty {
                    var item: [String: JSONValue] = [:]
                    for (i, s) in f.sub.enumerated() { item[s] = .string(i < bits.count ? bits[i] : "") }
                    arr.append(.object(item))
                } else {
                    for b in bits where !b.isEmpty { arr.append(.string(b)) }
                }
                values[key] = .array(arr)
            } else if let cur = values[key]?.string, !cur.isEmpty {
                values[key] = .string("\(cur)\n\(v)")
            } else {
                values[key] = .string(v)
            }
        }
        for (k, v) in values { if let s = v.string { values[k] = .string(s.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        return values
    }

    /// 值写回成角色那种写法。消息正文、历史里角色读到的就是它
    static func block(name: String, values: [String: JSONValue], fields: [Field]) -> String {
        var lines = ["[卡片：\(name)]"]
        var order = fields.isEmpty ? values.keys.sorted() : fields.map(\.name)
        for k in values.keys.sorted() where !order.contains(k) { order.append(k) }
        for k in order {
            guard let v = values[k] else { continue }
            if let arr = v.array {
                let f = fields.first { $0.name == k }
                for item in arr {
                    if let o = item.object {
                        let keys = (f?.sub.isEmpty == false ? f!.sub : o.keys.sorted())
                        lines.append("\(k)：\(keys.map { o[$0]?.string ?? "" }.joined(separator: "｜"))")
                    } else if let s = plain(item) { lines.append("\(k)：\(s)") }
                }
            } else if let s = plain(v), !s.isEmpty {
                lines.append("\(k)：\(s)")
            }
        }
        lines.append("[/卡片]")
        return lines.joined(separator: "\n")
    }

    /// 列表、通知里那一行
    static func preview(name: String, values: [String: JSONValue]) -> String {
        let first = values.values.compactMap(\.string).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let tail = first.map { " " + String($0.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(30)) } ?? ""
        return "[卡片] \(name)\(tail)"
    }

    // MARK: - 找卡片

    struct Entry {
        var json: [String: JSONValue]
        var bookId: String
        var id: String { json["id"]?.string ?? "" }
        var name: String { (json["comment"]?.string ?? "").trimmingCharacters(in: .whitespaces) }
        var card: [String: JSONValue] { json["card"]?.object ?? [:] }
        var html: String { card["html"]?.string ?? "" }
        var fields: [Field] { HtmlCard.fields(html, card["fields"]?.object ?? [:]) }
    }

    private static func builtinBook(_ s: AppSettings) -> (global: Bool, entries: [Entry]) {
        let st = builtinState(s)
        return (st.global, builtinEntries.compactMap { e in
            guard let id = e["id"]?.string, !st.off.contains(id) else { return nil }
            return Entry(json: e, bookId: builtinBookId)
        })
    }

    /// 某个角色用得上的卡片：挂在它身上的与全局的对话用世界书里启用着的，加上挂上了的内置卡片
    static func cards(for char: Character, _ s: AppSettings = .load()) -> [Entry] {
        var out: [Entry] = []
        let books = ((try? Repo.lorebooks()) ?? []).filter { $0.purpose == "chat" && ($0.global || char.lorebookIds.contains($0.id)) }
        for b in books {
            for e in b.entries where e.isCard && e.enabled {
                let entry = Entry(json: e.json, bookId: b.id)
                if !entry.name.isEmpty && !entry.html.isEmpty { out.append(entry) }
            }
        }
        let bb = builtinBook(s)
        if bb.global || char.lorebookIds.contains(builtinBookId) { out += bb.entries }
        return out
    }

    /// 这一轮命中的卡片：常驻的，或者扫描窗口里出现了关键词的
    static func hits(for char: Character, scanText: String, _ s: AppSettings = .load()) -> [Entry] {
        let lower = scanText.lowercased()
        return cards(for: char, s).filter { e in
            if e.json["constant"]?.bool == true { return true }
            let keys = (e.json["keys"]?.array ?? []).compactMap(\.string).filter { !$0.isEmpty }
            let cs = e.json["caseSensitive"]?.bool == true
            return keys.contains { cs ? scanText.contains($0) : lower.contains($0.lowercased()) }
        }
    }

    /// 按消息上记的位置找；那一条删了或改了名字，再按名字找
    static func resolve(bookId: String, entryId: String, name: String, char: Character?) -> Entry? {
        if bookId == builtinBookId, let e = builtinEntries.first(where: { $0["id"]?.string == entryId }) {
            return Entry(json: e, bookId: builtinBookId)
        }
        if !bookId.isEmpty, let b = ((try? Repo.lorebooks()) ?? []).first(where: { $0.id == bookId }),
           let e = b.entries.first(where: { $0.id == entryId && $0.isCard }) {
            return Entry(json: e.json, bookId: b.id)
        }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        if let char, let hit = cards(for: char).first(where: { $0.name == n }) { return hit }
        for b in (try? Repo.lorebooks()) ?? [] {
            if let e = b.entries.first(where: { $0.isCard && ($0.json["comment"]?.string ?? "").trimmingCharacters(in: .whitespaces) == n }) {
                return Entry(json: e.json, bookId: b.id)
            }
        }
        return builtinEntries.first { ($0["comment"]?.string ?? "") == n }.map { Entry(json: $0, bookId: builtinBookId) }
    }

    /// 进提示词的那份清单：卡片名、说明、字段与字数。模板一个字都不进
    static func promptList(_ cards: [Entry]) -> String {
        cards.map { e in
            let desc = (e.json["content"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var out = ["· \(e.name)\(desc.isEmpty ? "" : ": \(desc)")"]
            for f in e.fields {
                let cfg = cfgOf(e.card, f.name, "")
                var bits: [String] = []
                if f.list { bits.append(f.sub.isEmpty ? "list" : "list, each item: \(f.sub.joined(separator: "｜"))") }
                if let mx = cfg["max"]?.number, mx > 0 { bits.append("up to \(Int(mx.rounded())) characters\(f.list ? " per item" : "")") }
                let d = (cfg["desc"]?.string ?? "").trimmingCharacters(in: .whitespaces)
                out.append("  \(f.name)\(bits.isEmpty ? "" : " (\(bits.joined(separator: "; ")))")\(d.isEmpty ? "" : ": \(d)")")
                for sub in f.sub {
                    let sc = cfgOf(e.card, sub, f.name)
                    let sd = (sc["desc"]?.string ?? "").trimmingCharacters(in: .whitespaces)
                    let smx = sc["max"]?.number ?? 0
                    guard !sd.isEmpty || smx > 0 else { continue }
                    out.append("    \(sub)\(smx > 0 ? " (up to \(Int(smx.rounded())) characters)" : "")\(sd.isEmpty ? "" : ": \(sd)")")
                }
            }
            return out.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: - 用户自己发卡片（网页版 CardSendSheet，4.253）

    /// 表单里一个字段一段文字；列表一行一项、子字段用｜隔开。转成角色那种写法再交给 parseValues 读
    static func formBlock(_ fields: [Field], _ form: [String: String]) -> String {
        fields.compactMap { f -> String? in
            let v = (form[f.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return nil }
            if f.list {
                return v.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    .map { "\(f.name)：\($0)" }.joined(separator: "\n")
            }
            return "\(f.name)：\(v)"
        }.joined(separator: "\n")
    }

    static func toForm(_ fields: [Field], _ values: [String: JSONValue]) -> [String: String] {
        var out: [String: String] = [:]
        for f in fields {
            guard let v = values[f.name] else { out[f.name] = ""; continue }
            if let a = v.array {
                out[f.name] = a.map { x in x.object.map { o in f.sub.map { o[$0]?.string ?? "" }.joined(separator: "｜") } ?? (plain(x) ?? "") }
                    .joined(separator: "\n")
            } else { out[f.name] = plain(v) ?? "" }
        }
        return out
    }

    /// 发出去的是一条 kind 为 card 的消息，正文是角色那种写法，角色读到的就是它
    @discardableResult
    static func send(_ entry: Entry, values: [String: JSONValue], chatId: String) throws -> Message {
        guard !values.isEmpty else { throw StoreError(message: "请至少填写一个字段") }
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: block(name: entry.name, values: values, fields: entry.fields), kind: "card")
        m.row["card"] = .object(["name": .string(entry.name), "bookId": .string(entry.bookId), "entryId": .string(entry.id), "values": .object(values)])
        m = try Repo.append(m)
        if var c = try Repo.chat(chatId) { c.row["lastMessageAt"] = .number(Date().millis); try Repo.save(c) }
        return m
    }

    /// 「帮我填」：用户点了才发，一次请求。交回来的是角色那种写法，取出方括号之间那几行
    static func fillByModel(_ entry: Entry, idea: String, charName: String, userName: String, recent: String) async throws -> [String: JSONValue] {
        let sys = Templates.render("task.card-fill", [
            "card": promptList([entry]), "name": entry.name,
            "idea": idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(nothing specific; fit the recent chat)" : idea,
            "char": charName.isEmpty ? "the character" : charName, "user": userName.isEmpty ? "the user" : userName,
            "recent": recent.isEmpty ? "(none)" : recent,
        ], settings: .load())
        let r = try await AIService.shared.send(task: "card.fill", system: sys, messages: [AIMessage(role: .user, content: "Fill in the card.")], maxTokens: 2000)
        let text = ReplyParser.stripThink(r.text).0
        let body: String
        if let m = text.range(of: #"[\[【]\s*(?:卡片|card)\s*[:：][^\]】\n]*[\]】]"#, options: [.regularExpression, .caseInsensitive]) {
            let rest = String(text[m.upperBound...])
            if let e = rest.range(of: #"[\[【]\s*/\s*(?:卡片|card)\s*[\]】]"#, options: [.regularExpression, .caseInsensitive]) {
                body = String(rest[..<e.lowerBound])
            } else { body = rest }
        } else { body = text }
        return parseValues(body.trimmingCharacters(in: .whitespacesAndNewlines), fields: entry.fields)
    }
}
