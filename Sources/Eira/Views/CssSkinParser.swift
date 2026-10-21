import Foundation

// 网页版美化 CSS 读成原生样式（CssStyle.swift 里的格子）。
//
// 读法：去注释 → 切成规则（@media 深色、@keyframes、@font-face 记为跳过）→ 每条选择器对到一个钩子
// （`.ph-bubble`、`.ph-send:active`、`.ph-bubble-mine::after`……）→ 声明按层叠（!important、特异度、先后）
// 选出最后生效的一条 → 简写展开、var() 展开 → 读成 CssStyle。
// 每一条声明都在 CssReport 里记一笔：用上了、近似、跳过，各写原因（书面语，导入确认页照着列）。
// 纯函数，不读文件、不联网。值的读法在 CssValues.swift。

extension CssSkin {
    /// 读一份美化的 CSS。同一份 CSS 读过一次就记住结果（最多记 16 份）
    static func compile(_ css: String) -> CssCompiled {
        if let hit = CssCompileCache.shared.get(css) { return hit }
        let out = compileUncached(css)
        CssCompileCache.shared.put(css, out)
        return out
    }

    /// 不经缓存，每次重读
    static func compileUncached(_ css: String) -> CssCompiled {
        var c = CssCompiler()
        return c.run(css)
    }

    /// 契约里的全部钩子（网页版 system/skin-contract.js 的 HOOKS，不带 `ph-`）。不在这里的 `.ph-*` 记为跳过
    static let contractHooks: Set<String> = [
        "chat", "chat-body", "msg", "msg-mine", "msg-theirs", "face", "avatar", "col", "bubble", "bubble-mine",
        "bubble-theirs", "reacts", "react", "silence", "sticker", "quote", "quote-in", "meta", "stamp", "read",
        "time-sep", "recall", "trans", "transfer", "voice", "xhs", "call", "location", "gift", "outfit", "narration",
        "narration-mine", "narration-theirs", "narration-name", "narration-sep", "narration-text", "inner",
        "inner-card", "inner-card-text", "file", "status", "status-online", "status-offline", "status-item", "html",
        "msg-face", "side", "groom", "closet-share", "slip", "dresscode", "composer", "composer-input",
        "composer-btn", "plus", "sticker-btn", "composer-tabs", "composer-tab", "send", "panel", "badge", "award",
        "acquire", "mall-item", "mall-shot", "dream-card", "quiz-card", "forum-card", "slip-card", "slip-draw",
        "slip-reveal", "card", "toolbar", "reject", "proxy", "page", "navbar", "nav-title", "nav-left", "nav-right",
        "back", "nav-action", "forum-post-row", "forum-post", "forum-floor", "forum-composer", "forum-court",
        "forum-dm", "tabbar", "tab", "tab-on", "list", "list-item", "list-title", "sheet", "modal", "screen",
        "statusbar", "wallpaper", "home", "home-grid", "tile", "tile-name", "dock", "chats", "chats-search",
        "chats-section", "chats-section-title", "chats-group", "chat-row", "chat-row-pinned", "chat-row-unread",
        "chat-row-muted", "chat-row-group", "chat-row-main", "chat-row-top", "chat-row-star", "chat-row-name",
        "chat-row-time", "chat-row-bottom", "chat-row-preview", "chat-row-count", "group-face", "contacts",
        "contacts-search", "contacts-section", "contacts-section-title", "contacts-group", "contact-row",
        "contact-row-pinned", "contact-row-npc", "contact-row-main", "contact-row-name", "contact-row-sign",
        "contact-row-arrow", "contacts-add", "moments", "moments-cover", "moments-cover-acts", "moments-cover-btn",
        "moments-me", "moments-me-name", "moment", "moment-mine", "moment-main", "moment-name", "moment-text",
        "moment-photos", "moment-photo", "moment-song", "moment-foot", "moment-time", "moment-actions", "moment-act",
        "moment-like", "moment-comment-btn", "moment-delete", "moment-share", "moment-repost", "moment-comments",
        "moment-comment-list", "moment-comment", "moment-comment-name", "moment-recalled", "moment-recalled-line",
        "moment-detail-author", "moment-detail-name", "moment-detail-time", "moment-detail-pager",
        "moment-detail-slide", "moment-detail-dots", "moment-detail-dot", "moment-detail-foot", "moment-detail-text",
        "moment-detail-comments", "moment-detail-gone", "profile", "profile-me", "profile-head", "profile-face",
        "profile-face-base", "level-ring", "profile-stats", "profile-stat", "profile-stat-num", "profile-stat-label",
        "profile-bio", "profile-name", "profile-sign", "profile-acts", "profile-highlights", "profile-highlight",
        "profile-highlight-add", "profile-highlight-ring", "profile-highlight-img", "profile-highlight-name",
        "profile-tabs", "profile-tab", "profile-tab-on", "profile-grid", "profile-cell", "profile-cell-multi",
        "sched", "sched-week", "sched-col", "sched-col-today", "sched-tasks", "sched-task", "sched-item",
        "sched-class", "sched-work", "sched-commute", "sched-other", "sched-todo", "sched-tag", "sched-today",
        "quiz", "quiz-cover", "quiz-title", "quiz-desc", "quiz-progress", "quiz-question", "quiz-option",
        "quiz-option-on", "quiz-result", "quiz-compare",
    ]

    /// 契约里的全部变量（网页版 skin-contract.js 的 VARS，不带 `--`）
    static let contractVars: Set<String> = [
        "ph-quiz-accent", "ph-quiz-paper", "ph-quiz-ink", "ph-quiz-cover", "ph-bubble-r", "ph-bubble-px",
        "ph-bubble-py", "ph-bubble-fs", "ph-bubble-gap", "ph-bubble-gap-in", "ph-avatar-size", "ph-avatar-r",
        "ph-navbar-h", "ph-composer-h", "ph-composer-pad", "ph-chat-bg", "ph-narration-color", "ph-narration-fs",
        "ph-narration-name-color", "ph-narration-auto", "ph-inner-fg", "ph-inner-bg", "ph-inner-fs", "ph-inner-r",
        "ph-inner-bw", "ph-inner-bc", "ph-inner-card-fg", "ph-inner-card-bg", "ph-inner-card-fs", "ph-inner-card-r",
        "ph-inner-card-bw", "ph-inner-card-bc", "ph-status-fg", "ph-status-bg", "ph-status-fs", "ph-status-r",
        "ph-status-bw", "ph-status-bc", "ph-status-offline-fg", "ph-status-offline-bg", "ph-status-offline-fs",
        "ph-status-offline-r", "ph-status-offline-bw", "ph-status-offline-bc", "ph-chat-veil", "ph-bar-top",
        "ph-bar-top-blur", "ph-bar-bottom", "ph-bar-bottom-blur", "ph-tile-name-color", "ph-tile-plate",
        "ph-tile-scale", "ph-tile-glyph", "ph-dock-bg", "ph-sched-bg", "ph-sched-veil", "ph-bg", "ph-surface",
        "ph-surface-2", "ph-surface-3", "ph-border", "ph-border-2", "ph-text", "ph-text-2", "ph-text-3", "ph-accent",
        "ph-accent-weak", "ph-on-accent", "ph-group-fill",
    ]

    /// 原生版自己读的契约变量（气泡、头像、底栏、顶栏的尺寸）
    static let nativeVars: Set<String> = [
        "ph-bubble-r", "ph-bubble-px", "ph-bubble-py", "ph-bubble-fs", "ph-bubble-gap", "ph-bubble-gap-in",
        "ph-avatar-size", "ph-avatar-r", "ph-navbar-h", "ph-composer-h", "ph-composer-pad",
    ]

    /// 原生版另外认的钩子：一串里最后一条消息、最后一个气泡。
    /// 由 `.ph-msg-mine:not(:has(~ .ph-msg-mine))` 与 `:last-child`、`:last-of-type` 读出
    static let lastHooks: Set<String> = [
        "msg-last", "msg-mine-last", "msg-theirs-last", "bubble-last", "bubble-mine-last", "bubble-theirs-last",
    ]
}

/// 读过的结果。键是 CSS 原文
final class CssCompileCache: @unchecked Sendable {
    static let shared = CssCompileCache()
    private let lock = NSLock()
    private var map: [String: CssCompiled] = [:]
    private var order: [String] = []

    func get(_ key: String) -> CssCompiled? {
        lock.lock()
        defer { lock.unlock() }
        return map[key]
    }

    func put(_ key: String, _ value: CssCompiled) {
        lock.lock()
        defer { lock.unlock() }
        if map[key] == nil {
            order.append(key)
            if order.count > 16 { map.removeValue(forKey: order.removeFirst()) }
        }
        map[key] = value
    }
}

/// 读一份 CSS 的过程。只在 CssSkin.compile 里用
struct CssCompiler {
    typealias S = Unicode.Scalar
    typealias Kind = CssReport.Item.Kind

    /// 选择器对到钩子之后，这条规则里的声明怎么用
    enum Mode {
        /// 钩子本身（或它的伪元素、状态）
        case normal
        /// `.ph-X *`：只取文字相关的几项，记到 X 上
        case text
        /// `.ph-X svg`、`.ph-X img`：只认隐藏与颜色，记进 X 的 raw
        case icon
        /// `:root`、`html`、`body`：只收变量
        case root
    }

    struct Target {
        var key: CssKey
        var mode: Mode
        var spec: Int
        /// 选择器本身是近似读的，写给用户的原因
        var note: String?
    }

    /// 层叠里的一条候选
    struct Win {
        var value: String
        var important: Bool
        var spec: Int
        var order: Int
        var item: Int
    }

    struct Pending {
        var target: Target
        var prop: String
        var value: String
        var important: Bool
        var order: Int
        var item: Int
    }

    struct RawDecl {
        var prop: String
        var value: String
        var important: Bool
    }

    struct Mark {
        var item: Int
        var kind: Kind
        var reason: String
    }

    var items: [CssReport.Item] = []
    var order = 0
    /// 变量：名字带 `--`
    var varDecls: [String: Win] = [:]
    var pending: [Pending] = []
    /// 展开成单项之后的层叠结果
    var long: [CssKey: [String: Win]] = [:]
    /// 原文属性名的层叠结果（写进 CssStyle.raw）
    var raw: [CssKey: [String: Win]] = [:]

    // MARK: 入口

    mutating func run(_ css: String) -> CssCompiled {
        let a = Self.stripComments(Array(css.unicodeScalars))
        parseBlock(a, 0, a.count, skip: nil)

        var vars: [String: String] = [:]
        for (name, w) in varDecls {
            if let v = resolve(w.value, [name]) { vars[String(name.dropFirst(2))] = CssScan.trim(v) }
        }

        for p in pending { apply(p) }

        var styles: [CssKey: CssStyle] = [:]
        var marks: [Mark] = []
        for key in Set(long.keys).union(raw.keys) {
            let (st, m) = style(key)
            styles[key] = st
            marks += m
        }
        for m in marks { mark(m.item, m.kind, m.reason) }
        return CssCompiled(styles: styles, vars: vars, report: CssReport(items: items))
    }

    // MARK: 记账

    @discardableResult
    mutating func add(_ kind: Kind, _ selector: String, _ prop: String, _ reason: String) -> Int {
        items.append(CssReport.Item(kind: kind, selector: selector, property: prop, reason: reason))
        return items.count - 1
    }

    /// 改一条已记的账：跳过盖过近似，近似盖过用上
    mutating func mark(_ i: Int, _ kind: Kind, _ reason: String) {
        guard items.indices.contains(i) else { return }
        let cur = items[i].kind
        if (kind == .skipped && cur != .skipped) || (kind == .approx && cur == .used) {
            items[i].kind = kind
            items[i].reason = reason
        }
    }

    static func beats(_ a: Win, _ b: Win) -> Bool {
        if a.important != b.important { return a.important }
        if a.spec != b.spec { return a.spec > b.spec }
        return a.order > b.order
    }

    static func put(_ table: inout [CssKey: [String: Win]], _ key: CssKey, _ prop: String, _ w: Win) {
        if let old = table[key]?[prop], beats(old, w) { return }
        table[key, default: [:]][prop] = w
    }

    // MARK: 去注释

    /// 去掉 `/* */`。引号里与不带引号的 url(...) 里的不算注释
    static func stripComments(_ a: [S]) -> [S] {
        var out: [S] = []
        out.reserveCapacity(a.count)
        var i = 0
        var quote: S?
        var esc = false
        var rawURL = false
        while i < a.count {
            let c = a[i]
            if esc { out.append(c); esc = false; i += 1; continue }
            if c == "\\" { out.append(c); esc = true; i += 1; continue }
            if let q = quote {
                out.append(c)
                if c == q { quote = nil }
                i += 1
                continue
            }
            if rawURL {
                out.append(c)
                if c == ")" { rawURL = false }
                i += 1
                continue
            }
            if c == "\"" || c == "'" { quote = c; out.append(c); i += 1; continue }
            if c == "/", i + 1 < a.count, a[i + 1] == "*" {
                var j = i + 2
                while j + 1 < a.count, !(a[j] == "*" && a[j + 1] == "/") { j += 1 }
                i = j + 2
                out.append(" ")
                continue
            }
            if c == "(", urlBefore(out) {
                out.append(c)
                i += 1
                var j = i
                while j < a.count, CssScan.isSpace(a[j]) { j += 1 }
                if j < a.count, a[j] != "\"", a[j] != "'" { rawURL = true }
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// out 的末尾是不是 `url`（不区分大小写，前面不连着别的标识符）
    static func urlBefore(_ out: [S]) -> Bool {
        let n = out.count
        guard n >= 3 else { return false }
        let u = out[n - 3].value | 0x20, r = out[n - 2].value | 0x20, l = out[n - 1].value | 0x20
        guard u == 117, r == 114, l == 108 else { return false }
        return n == 3 || !CssScan.isIdent(out[n - 4])
    }

    // MARK: 切规则

    /// a[open] 是 `{`，返回配对的 `}` 的下标；没有配对的返回 to
    static func matchBrace(_ a: [S], _ open: Int, _ to: Int) -> Int {
        var depth = 0
        var quote: S?
        var esc = false
        var i = open
        while i < to {
            let c = a[i]
            if esc { esc = false; i += 1; continue }
            if c == "\\" { esc = true; i += 1; continue }
            if let q = quote {
                if c == q { quote = nil }
                i += 1
                continue
            }
            if c == "\"" || c == "'" { quote = c }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return to
    }

    mutating func parseBlock(_ a: [S], _ from: Int, _ to: Int, skip: String?) {
        var i = from
        while i < to {
            while i < to, CssScan.isSpace(a[i]) { i += 1 }
            guard i < to else { break }
            var j = i
            var quote: S?
            var esc = false
            var depth = 0
            var stop = to
            while j < to {
                let c = a[j]
                if esc { esc = false; j += 1; continue }
                if c == "\\" { esc = true; j += 1; continue }
                if let q = quote {
                    if c == q { quote = nil }
                    j += 1
                    continue
                }
                if c == "\"" || c == "'" { quote = c }
                else if c == "(" || c == "[" { depth += 1 }
                else if c == ")" || c == "]" { depth = max(0, depth - 1) }
                else if depth == 0 && (c == "{" || c == ";" || c == "}") { stop = j; break }
                j += 1
            }
            let prelude = CssScan.trim(CssScan.str(a[i..<stop]))
            if stop >= to {
                if !prelude.isEmpty { add(.skipped, Self.short(prelude), "", "这一段写法不完整，原生版不认") }
                break
            }
            if a[stop] == ";" || a[stop] == "}" {
                if prelude.hasPrefix("@") {
                    if let r = Self.statementReason(prelude) { add(.skipped, Self.short(prelude), "", r) }
                } else if !prelude.isEmpty {
                    add(.skipped, Self.short(prelude), "", "这一段写法不完整，原生版不认")
                }
                i = stop + 1
                continue
            }
            let close = Self.matchBrace(a, stop, to)
            let bodyFrom = stop + 1
            let bodyTo = max(bodyFrom, min(close, to))
            i = close + 1
            if prelude.hasPrefix("@") {
                atRule(prelude, a, bodyFrom, bodyTo, skip: skip)
            } else {
                handleRule(prelude, CssScan.str(a[bodyFrom..<bodyTo]), skip: skip)
            }
        }
    }

    /// 报告里的选择器太长时截短（data: 地址之类）
    static func short(_ s: String) -> String {
        s.unicodeScalars.count > 120 ? CssScan.str(s.unicodeScalars.prefix(120)) + "…" : s
    }

    /// `@xxx` 的名字，小写
    static func atName(_ prelude: String) -> String {
        var name: [S] = ["@"]
        for c in prelude.unicodeScalars.dropFirst() {
            guard CssScan.isIdent(c) else { break }
            name.append(c)
        }
        return CssScan.str(name).lowercased()
    }

    /// 以分号结尾的 @ 规则。nil 为不必记账（@charset）
    static func statementReason(_ prelude: String) -> String? {
        switch atName(prelude) {
        case "@charset": return nil
        case "@import": return "外部样式表原生版不载入"
        default: return "这条 @ 规则原生版不认"
        }
    }

    mutating func atRule(_ prelude: String, _ a: [S], _ from: Int, _ to: Int, skip: String?) {
        let low = prelude.lowercased()
        let sel = Self.short(prelude)
        switch Self.atName(prelude) {
        case "@media":
            if skip != nil {
                parseBlock(a, from, to, skip: skip)
            } else if low.contains("prefers-color-scheme") {
                parseBlock(a, from, to, skip: low.contains("dark") ? "深色模式的规则暂不读取" : nil)
            } else if low.contains("prefers-reduced-motion") || Self.mediaApplies(low) {
                parseBlock(a, from, to, skip: nil)
            } else {
                parseBlock(a, from, to, skip: "按屏幕尺寸等条件生效的规则原生版暂不读取")
            }
        case "@supports", "@layer":
            parseBlock(a, from, to, skip: skip)
        case "@keyframes", "@-webkit-keyframes":
            add(.skipped, sel, "", "动画原生版暂不读取")
        case "@font-face":
            add(.skipped, sel, "", "自定义字体原生版暂不读取")
        default:
            add(.skipped, sel, "", "这条 @ 规则原生版不认")
        }
    }

    /// `@media screen`、`@media all` 这类没有条件的
    static func mediaApplies(_ low: String) -> Bool {
        let rest = CssScan.words(String(low.dropFirst(6))).filter { !["only", "screen", "all", "and"].contains($0) }
        return rest.isEmpty
    }

    // MARK: 切声明

    static func declarations(_ body: String) -> (decls: [RawDecl], nested: Bool) {
        let a = Array(body.unicodeScalars)
        var out: [RawDecl] = []
        var nested = false
        var cur: [S] = []
        var depth = 0
        var quote: S?
        var esc = false
        var i = 0

        func flush() {
            let piece = cur
            cur = []
            guard let colon = piece.firstIndex(of: ":") else { return }
            let prop = CssScan.trim(CssScan.str(piece[piece.startIndex..<colon]))
            var valueScalars = Array(piece[(colon + 1)...])
            var important = false
            if let bang = valueScalars.lastIndex(of: "!"),
               CssScan.trim(CssScan.str(valueScalars[(bang + 1)...])).lowercased() == "important" {
                important = true
                valueScalars = Array(valueScalars[0..<bang])
            }
            let value = CssScan.trim(CssScan.str(valueScalars))
            guard !prop.isEmpty, !value.isEmpty else { return }
            out.append(RawDecl(prop: prop.hasPrefix("--") ? prop : prop.lowercased(), value: value, important: important))
        }

        while i < a.count {
            let c = a[i]
            if esc { cur.append(c); esc = false; i += 1; continue }
            if c == "\\" { cur.append(c); esc = true; i += 1; continue }
            if let q = quote {
                cur.append(c)
                if c == q { quote = nil }
                i += 1
                continue
            }
            if c == "\"" || c == "'" { quote = c; cur.append(c); i += 1; continue }
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) }
            if depth == 0 && c == ";" { flush(); i += 1; continue }
            if depth == 0 && c == "{" {
                nested = true
                cur = []
                i = matchBrace(a, i, a.count) + 1
                continue
            }
            cur.append(c)
            i += 1
        }
        flush()
        return (out, nested)
    }

    // MARK: 一条规则

    mutating func handleRule(_ selector: String, _ body: String, skip: String?) {
        if let skip {
            add(.skipped, Self.short(selector), "", skip)
            return
        }
        let (decls, nested) = Self.declarations(body)
        if nested { add(.skipped, Self.short(selector), "", "嵌套写法原生版不认") }
        for sel in CssScan.split(selector, on: ",") where !sel.isEmpty {
            switch target(sel) {
            case .skip(let reason):
                add(.skipped, Self.short(sel), "", reason)
            case .hit(let t):
                for d in decls { declare(t, Self.short(sel), d) }
            }
        }
    }

    mutating func declare(_ t: Target, _ sel: String, _ d: RawDecl) {
        order += 1
        if d.prop.hasPrefix("--") {
            let v = Self.varVerdict(d.prop)
            let idx = add(v.kind, sel, d.prop, v.reason)
            let w = Win(value: d.value, important: d.important, spec: 0, order: order, item: idx)
            if let old = varDecls[d.prop], Self.beats(old, w) { return }
            varDecls[d.prop] = w
            return
        }
        var prop = d.prop
        var v: (kind: Kind, reason: String, keep: Bool)
        switch t.mode {
        case .root:
            add(.skipped, sel, prop, "页面根元素的样式原生版不读取")
            return
        case .text:
            guard Self.textProps.contains(prop) else {
                add(.skipped, sel, prop, "子元素的这一项原生版不认")
                return
            }
            v = (kind: .approx, reason: "子元素的文字按整个元素处理", keep: true)
        case .icon:
            switch prop {
            case "display":
                prop = "-ph-icon-hidden"
                v = (kind: .used, reason: d.value.lowercased() == "none" ? "图标已隐藏" : "已读取", keep: true)
            case "fill", "color", "stroke":
                prop = "-ph-icon-color"
                v = (kind: .approx, reason: "图标颜色已记下，原生版按单色图标处理", keep: true)
            default:
                add(.skipped, sel, prop, "图标的这一项原生版不认")
                return
            }
        case .normal:
            let r = Self.verdict(prop, d.value, t.key.part)
            v = (kind: r.0, reason: r.1, keep: r.2)
            if v.kind == .used, let note = t.note { v = (kind: .approx, reason: note, keep: v.keep) }
        }
        let idx = add(v.kind, sel, d.prop, v.reason)
        guard v.keep else { return }
        pending.append(Pending(target: t, prop: prop, value: d.value, important: d.important, order: order, item: idx))
    }

    /// 变量记成什么
    static func varVerdict(_ name: String) -> (kind: Kind, reason: String) {
        let n = String(name.dropFirst(2))
        if n.hasPrefix("ph-") {
            if CssSkin.nativeVars.contains(n) { return (.used, "原生版按这个变量调整") }
            if CssSkin.contractVars.contains(n) { return (.skipped, "这个变量原生版暂不读取") }
            return (.skipped, "契约里没有这个变量")
        }
        return (.used, "作者自己的变量，已在用到的地方展开")
    }

    // MARK: 属性分类

    static let sides = ["top", "right", "bottom", "left"]

    /// 读进 CssStyle 的属性（含简写）
    static let visualProps: Set<String> = {
        var s: Set<String> = [
            "color", "opacity", "background", "background-color", "background-image", "background-size",
            "background-position", "background-repeat", "border", "border-width", "border-style", "border-color",
            "outline", "outline-width", "outline-style", "outline-color", "border-radius",
            "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius",
            "border-bottom-left-radius", "box-shadow", "text-shadow", "font", "font-size", "font-weight",
            "font-family", "letter-spacing", "line-height", "text-align", "padding", "margin", "width", "height",
            "min-width", "min-height", "gap", "row-gap", "column-gap", "transform", "display", "content",
        ]
        for side in CssCompiler.sides {
            s.insert("border-\(side)")
            for p in ["width", "style", "color"] { s.insert("border-\(side)-\(p)") }
            s.insert("padding-\(side)")
            s.insert("margin-\(side)")
        }
        return s
    }()

    /// `.ph-X *` 里认的几项
    static let textProps: Set<String> = [
        "color", "text-shadow", "font", "font-size", "font-weight", "font-family", "letter-spacing", "line-height",
    ]

    /// 第二步画成图片时还原的
    static let imageProps: Set<String> = [
        "filter", "-webkit-filter", "mix-blend-mode", "clip-path", "-webkit-clip-path", "backdrop-filter",
        "-webkit-backdrop-filter", "mask", "mask-image", "mask-size", "mask-position", "mask-repeat",
        "-webkit-mask", "-webkit-mask-image", "-webkit-mask-size", "-webkit-mask-position", "-webkit-mask-repeat",
        "background-blend-mode", "background-clip", "-webkit-background-clip", "-webkit-text-fill-color",
        "-webkit-text-stroke", "border-image", "border-image-source", "border-image-slice", "border-image-width",
        "border-image-repeat", "border-image-outset",
    ]

    /// 原生版的版式本来如此，写了不影响
    static let harmlessProps: Set<String> = [
        "align-items", "align-self", "align-content", "justify-content", "justify-items", "justify-self",
        "place-items", "place-content", "place-self", "flex", "flex-grow", "flex-shrink", "flex-basis", "flex-wrap",
        "flex-flow", "box-sizing", "overflow", "overflow-x", "overflow-y", "white-space", "text-overflow",
        "word-break", "overflow-wrap", "word-wrap", "pointer-events", "vertical-align", "cursor", "user-select",
        "-webkit-user-select", "-webkit-tap-highlight-color", "-webkit-touch-callout", "appearance",
        "-webkit-appearance", "-moz-appearance", "will-change", "contain", "isolation", "-webkit-font-smoothing",
        "-moz-osx-font-smoothing", "text-rendering", "font-feature-settings", "background-attachment",
        "background-origin", "list-style", "list-style-type", "resize", "touch-action",
        "-webkit-overflow-scrolling", "scroll-behavior", "hyphens", "-webkit-line-clamp", "line-clamp",
        "-webkit-box-orient", "outline-style-reset", "text-size-adjust", "-webkit-text-size-adjust",
        "backface-visibility", "-webkit-backface-visibility", "transform-origin", "font-display", "tab-size",
    ]

    /// 会改变版式，原生版不跟
    static let layoutProps: Set<String> = [
        "flex-direction", "order", "float", "clear", "grid", "grid-template", "grid-template-columns",
        "grid-template-rows", "grid-template-areas", "grid-area", "grid-column", "grid-row", "grid-auto-flow",
        "grid-auto-columns", "grid-auto-rows", "columns", "column-count", "writing-mode", "direction",
        "margin-inline", "margin-block", "padding-inline", "padding-block", "inset-inline", "inset-block",
    ]

    /// 原文记下，显示可能有出入
    static let rawOnlyProps: Set<String> = [
        "max-width", "max-height", "font-style", "font-variant", "text-decoration", "text-decoration-line",
        "text-decoration-color", "text-decoration-style", "text-decoration-thickness", "text-underline-offset",
        "text-transform", "text-indent", "caret-color", "aspect-ratio", "object-fit", "object-position",
        "visibility", "accent-color", "word-spacing", "outline-offset", "background-position-x",
        "background-position-y", "font-stretch", "-webkit-text-stroke-width", "-webkit-text-stroke-color",
    ]

    static let placeProps: Set<String> = ["top", "left", "right", "bottom", "inset", "z-index"]

    /// 一条声明记成什么：kind、原因、要不要进层叠
    static func verdict(_ prop: String, _ value: String, _ part: CssPart) -> (Kind, String, Bool) {
        let low = CssScan.trim(value).lowercased()
        let pseudo = part == .before || part == .after
        if prop == "content" {
            return pseudo ? (.used, "已读取", true) : (.skipped, "只有 ::before 与 ::after 才有 content", false)
        }
        if prop == "display" {
            return low == "none" ? (.used, "已读取", true) : (.used, "原生版的版式已经如此", true)
        }
        if visualProps.contains(prop) { return (.used, "已读取", true) }
        if prop == "position" {
            if pseudo { return (.approx, "伪元素的摆放位置按近似处理", true) }
            if low == "relative" || low == "static" { return (.used, "原生版的版式已经如此", true) }
            return (.skipped, "原生版不按这项挪动元素", false)
        }
        if placeProps.contains(prop) {
            if pseudo { return (.approx, "伪元素的摆放位置按近似处理", true) }
            if prop == "z-index" { return (.used, "原生版的版式已经如此", true) }
            return (.skipped, "原生版不按这项挪动元素", false)
        }
        if imageProps.contains(prop) { return (.approx, "第二步画成图片后还原", true) }
        if harmlessProps.contains(prop) { return (.used, "原生版的版式已经如此", true) }
        if rawOnlyProps.contains(prop) { return (.approx, "原文已记下，显示效果可能有出入", true) }
        if layoutProps.contains(prop) || prop.hasPrefix("grid-") {
            return (.skipped, "原生版的版式不随这一项改变", false)
        }
        if prop.hasPrefix("animation") || prop.hasPrefix("transition") || prop.hasPrefix("-webkit-animation")
            || prop.hasPrefix("-webkit-transition") {
            return (.skipped, "动画与过渡原生版暂不读取", false)
        }
        return (.skipped, "原生版不认这一项", false)
    }

    // MARK: 选择器

    struct Simple {
        enum Kind { case cls, id, tag, star, attr, pclass, pelem }
        var kind: Kind
        var name: String
        var arg: String?
    }

    struct Compound {
        /// 与前一个的关系：""（第一个）、" "、">"、"+"、"~"
        var comb: String
        var items: [Simple]
    }

    static func readIdent(_ a: [S], _ i: inout Int) -> String {
        var out: [S] = []
        while i < a.count {
            let c = a[i]
            if c == "\\" {
                if i + 1 < a.count { out.append(a[i + 1]) }
                i += 2
                continue
            }
            guard CssScan.isIdent(c) else { break }
            out.append(c)
            i += 1
        }
        return CssScan.str(out)
    }

    static func matchBracket(_ a: [S], _ open: Int) -> Int? {
        var quote: S?
        var i = open + 1
        while i < a.count {
            let c = a[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "]" {
                return i
            }
            i += 1
        }
        return nil
    }

    /// 一条选择器（不含逗号）切成复合选择器的序列。读不懂的返回 nil
    static func parseSelector(_ s: String) -> [Compound]? {
        let a = Array(CssScan.trim(s).unicodeScalars)
        guard !a.isEmpty else { return nil }
        var out: [Compound] = []
        var cur: [Simple] = []
        var comb = ""
        var pendingSpace = false
        var i = 0
        while i < a.count {
            let c = a[i]
            if CssScan.isSpace(c) { pendingSpace = true; i += 1; continue }
            if c == ">" || c == "+" || c == "~" {
                if !cur.isEmpty { out.append(Compound(comb: comb, items: cur)); cur = [] }
                guard !out.isEmpty else { return nil }
                comb = CssScan.str([c])
                pendingSpace = false
                i += 1
                continue
            }
            if pendingSpace {
                pendingSpace = false
                if !cur.isEmpty {
                    out.append(Compound(comb: comb, items: cur))
                    cur = []
                    comb = " "
                }
            }
            switch c {
            case ".":
                i += 1
                let n = readIdent(a, &i)
                guard !n.isEmpty else { return nil }
                cur.append(Simple(kind: .cls, name: n, arg: nil))
            case "#":
                i += 1
                let n = readIdent(a, &i)
                guard !n.isEmpty else { return nil }
                cur.append(Simple(kind: .id, name: n, arg: nil))
            case "*":
                i += 1
                cur.append(Simple(kind: .star, name: "*", arg: nil))
            case "[":
                guard let close = matchBracket(a, i) else { return nil }
                cur.append(Simple(kind: .attr, name: CssScan.str(a[(i + 1)..<close]), arg: nil))
                i = close + 1
            case ":":
                var kind = Simple.Kind.pclass
                i += 1
                if i < a.count, a[i] == ":" { kind = .pelem; i += 1 }
                let n = readIdent(a, &i).lowercased()
                guard !n.isEmpty else { return nil }
                var arg: String?
                if i < a.count, a[i] == "(" {
                    guard let close = CssScan.matchParen(a, i) else { return nil }
                    arg = CssScan.str(a[(i + 1)..<close])
                    i = close + 1
                }
                if kind == .pclass, ["before", "after", "first-line", "first-letter", "placeholder"].contains(n) {
                    kind = .pelem
                }
                cur.append(Simple(kind: kind, name: n, arg: arg))
            default:
                guard CssScan.isIdent(c) else { return nil }
                let n = readIdent(a, &i)
                guard !n.isEmpty else { return nil }
                cur.append(Simple(kind: .tag, name: n.lowercased(), arg: nil))
            }
        }
        guard !cur.isEmpty else { return nil }
        out.append(Compound(comb: comb, items: cur))
        return out
    }

    /// 特异度：编号 10000、类与属性与伪类 100、标签与伪元素 1。:where() 为 0，:not()/:is()/:has() 取参数里最高的
    static func spec(_ comps: [Compound]) -> Int {
        comps.reduce(0) { $0 + spec($1.items) }
    }

    static func spec(_ items: [Simple]) -> Int {
        var n = 0
        for s in items {
            switch s.kind {
            case .id: n += 10000
            case .cls, .attr: n += 100
            case .tag, .pelem: n += 1
            case .star: break
            case .pclass:
                if s.name == "where" { break }
                if ["not", "is", "has", "matches"].contains(s.name), let arg = s.arg {
                    var best = 0
                    for part in CssScan.split(arg, on: ",") {
                        var p = CssScan.trim(part)
                        while let f = p.unicodeScalars.first, f == ">" || f == "+" || f == "~" {
                            p = CssScan.trim(String(p.unicodeScalars.dropFirst()))
                        }
                        if let c = parseSelector(p) { best = max(best, spec(c)) }
                    }
                    n += best
                } else {
                    n += 100
                }
            }
        }
        return n
    }

    enum Hit {
        case hit(Target)
        case skip(String)
    }

    struct Info {
        var hook: String?
        var state: CssState = .normal
        var part: CssPart = .main
        var tag: String?
        var note: String?
    }

    enum Analysis {
        case ok(Info)
        case fail(String)
    }

    /// 这几个钩子作为前面的条件时不影响结果（整页、会话页）
    static let contextHooks: Set<String> = ["screen", "page", "chat", "chat-body", "html"]
    /// `.ph-X svg` 这类：X 里的图标
    static let iconTags: Set<String> = ["svg", "img", "path", "i", "use", "g", "circle", "rect", "image"]
    /// 能读出「最后一条」的钩子
    static let lastable: Set<String> = ["msg", "msg-mine", "msg-theirs", "bubble", "bubble-mine", "bubble-theirs"]

    static func isRoot(_ c: Compound) -> Bool {
        !c.items.isEmpty && c.items.allSatisfy {
            ($0.kind == .pclass && $0.name == "root") || ($0.kind == .tag && ($0.name == "html" || $0.name == "body"))
        }
    }

    /// `:not(:has(~ .ph-msg-mine))`：后面再没有同一种消息，即一串里的最后一条
    static func isLastSibling(_ arg: String) -> Bool {
        let flat = CssScan.str(arg.lowercased().unicodeScalars.filter { !CssScan.isSpace($0) })
        return [":has(~.ph-msg-mine)", ":has(~.ph-msg-theirs)", ":has(~.ph-msg)"].contains(flat)
    }

    /// 一个复合选择器对到哪个钩子、哪种状态、哪个部位
    func analyze(_ c: Compound) -> Analysis {
        var expanded: [Simple] = []
        for s in c.items {
            if s.kind == .pclass, s.name == "is" || s.name == "where" || s.name == "matches", let arg = s.arg,
               let inner = Self.parseSelector(arg), inner.count == 1,
               inner[0].items.allSatisfy({ $0.kind == .cls }) {
                expanded.append(contentsOf: inner[0].items)
            } else {
                expanded.append(s)
            }
        }
        var info = Info()
        var hooks: [String] = []
        var last = false
        for s in expanded {
            switch s.kind {
            case .cls:
                if s.name.hasPrefix("ph-") { hooks.append(String(s.name.dropFirst(3))) }
                else { return .fail("内部类名 .\(s.name) 原生版不认") }
            case .id:
                return .fail("按编号选元素的写法原生版不认")
            case .attr:
                return .fail("按属性选元素的写法原生版不认")
            case .tag:
                info.tag = s.name
            case .star:
                info.tag = "*"
            case .pelem:
                switch s.name {
                case "before": info.part = .before
                case "after": info.part = .after
                case "placeholder", "-webkit-input-placeholder", "-moz-placeholder": info.part = .placeholder
                default: return .fail("伪元素 ::\(s.name) 原生版没有")
                }
            case .pclass:
                switch s.name {
                case "active": info.state = .pressed
                case "focus", "focus-visible": info.state = .focused
                case "focus-within":
                    info.state = .focused
                    info.note = "按输入框聚焦时处理"
                case "hover": return .fail("触屏没有悬停状态")
                case "last-child", "last-of-type": last = true
                case "not":
                    guard let arg = s.arg, Self.isLastSibling(arg) else { return .fail("这种选择器原生版不认") }
                    last = true
                default:
                    return .fail("这种选择器原生版不认")
                }
            }
        }
        var uniq: [String] = []
        for h in hooks where !uniq.contains(h) { uniq.append(h) }
        let top = uniq.filter { h in !uniq.contains(where: { $0 != h && $0.hasPrefix(h + "-") }) }
        if top.count > 1 { info.note = "同时挂了几个钩子，按其中一个处理" }
        if var h = top.last {
            guard CssSkin.contractHooks.contains(h) else { return .fail("契约里没有 .ph-\(h)，原生版没有这个元素") }
            if last {
                guard Self.lastable.contains(h) else { return .fail("这种选择器原生版不认") }
                h += "-last"
            }
            info.hook = h
        } else if last {
            return .fail("这种选择器原生版不认")
        }
        return .ok(info)
    }

    /// 一条选择器对到哪里
    func target(_ sel: String) -> Hit {
        guard let comps = Self.parseSelector(sel) else { return .skip("这种选择器原生版不认") }
        if comps.contains(where: { $0.comb == "+" || $0.comb == "~" }) {
            return .skip("按相邻元素选择的写法原生版不认")
        }
        let spec = Self.spec(comps)
        let subject = comps[comps.count - 1]
        var ancestors = Array(comps.dropLast())
        if Self.isRoot(subject) {
            guard ancestors.allSatisfy(Self.isRoot) else { return .skip("这种选择器原生版不认") }
            return .hit(Target(key: CssKey(hook: "root"), mode: .root, spec: spec, note: nil))
        }
        var mode = Mode.normal
        var info: Info
        switch analyze(subject) {
        case .fail(let reason):
            return .skip(reason)
        case .ok(let found):
            if found.hook != nil {
                info = found
            } else {
                guard let tag = found.tag, found.part == .main, found.state == .normal,
                      let owner = ancestors.last else { return .skip("原生版没有这个元素") }
                if tag == "*" { mode = .text }
                else if Self.iconTags.contains(tag) { mode = .icon }
                else { return .skip("原生版没有这个元素") }
                switch analyze(owner) {
                case .fail(let reason): return .skip(reason)
                case .ok(let o):
                    guard o.hook != nil, o.part == .main else { return .skip("原生版没有这个元素") }
                    info = o
                }
                ancestors.removeLast()
            }
        }
        guard let hook = info.hook else { return .skip("原生版没有这个元素") }
        var note = info.note
        for anc in ancestors where !Self.isRoot(anc) {
            switch analyze(anc) {
            case .fail(let reason):
                return .skip(reason)
            case .ok(let a):
                guard let h = a.hook, a.part == .main, a.state == .normal, !CssSkin.lastHooks.contains(h) else {
                    return .skip("这种选择器原生版不认")
                }
                if Self.contextHooks.contains(h) { continue }
                if note == nil { note = "只按最后一个元素处理，不区分它所在的位置" }
            }
        }
        return .hit(Target(key: CssKey(hook: hook, state: info.state, part: info.part), mode: mode, spec: spec, note: note))
    }

    // MARK: var()

    static func isVarAt(_ a: [S], _ i: Int) -> Bool {
        guard i + 3 < a.count else { return false }
        guard a[i].value | 0x20 == 118, a[i + 1].value | 0x20 == 97, a[i + 2].value | 0x20 == 114, a[i + 3] == "(" else {
            return false
        }
        return i == 0 || !CssScan.isIdent(a[i - 1])
    }

    /// 展开 var()。变量没定义又没有后备值、或者互相引用成环时返回 nil
    func resolve(_ value: String, _ visiting: Set<String>, depth: Int = 0) -> String? {
        guard depth < 32 else { return nil }
        guard value.lowercased().contains("var(") else { return value }
        let a = Array(value.unicodeScalars)
        var out: [S] = []
        var i = 0
        var quote: S?
        var esc = false
        while i < a.count {
            let c = a[i]
            if esc { out.append(c); esc = false; i += 1; continue }
            if c == "\\" { out.append(c); esc = true; i += 1; continue }
            if let q = quote {
                out.append(c)
                if c == q { quote = nil }
                i += 1
                continue
            }
            if c == "\"" || c == "'" { quote = c; out.append(c); i += 1; continue }
            if Self.isVarAt(a, i) {
                let open = i + 3
                guard let close = CssScan.matchParen(a, open) else { return nil }
                let inner = Array(a[(open + 1)..<close])
                var name = CssScan.trim(CssScan.str(inner))
                var fallback: String?
                let parts = CssScan.split(CssScan.str(inner), on: ",")
                if parts.count > 1 {
                    name = parts[0]
                    // 后备值里可以再有逗号：取第一个逗号之后的全部
                    if let comma = Self.firstTopComma(inner) {
                        fallback = CssScan.trim(CssScan.str(inner[(comma + 1)...]))
                    }
                }
                var rep: String?
                if let w = varDecls[name], !visiting.contains(name) {
                    rep = resolve(w.value, visiting.union([name]), depth: depth + 1)
                }
                if rep == nil, let fb = fallback { rep = resolve(fb, visiting, depth: depth + 1) }
                guard let r = rep else { return nil }
                out.append(contentsOf: r.unicodeScalars)
                i = close + 1
                continue
            }
            out.append(c)
            i += 1
        }
        return CssScan.str(out)
    }

    static func firstTopComma(_ a: [S]) -> Int? {
        var depth = 0
        var quote: S?
        var esc = false
        for (i, c) in a.enumerated() {
            if esc { esc = false; continue }
            if c == "\\" { esc = true; continue }
            if let q = quote {
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" { quote = c }
            else if c == "(" { depth += 1 }
            else if c == ")" { depth -= 1 }
            else if c == ",", depth == 0 { return i }
        }
        return nil
    }

    // MARK: 简写展开

    mutating func apply(_ p: Pending) {
        guard let value = resolve(p.value, []) else {
            mark(p.item, .skipped, "用到的变量没有定义")
            return
        }
        let key = p.target.key
        let w = Win(value: value, important: p.important, spec: p.target.spec, order: p.order, item: p.item)
        if p.target.mode == .normal { Self.put(&raw, key, p.prop, w) }
        guard let longs = Self.expand(p.prop, value) else {
            mark(p.item, .skipped, "这个值无法识别")
            return
        }
        for (lp, lv) in longs {
            var lw = w
            lw.value = lv
            Self.put(&long, key, lp, lw)
            if lp == "background-size" || lp == "background-position" {
                if lv.contains(",") || lv.lowercased().contains("calc(") { mark(p.item, .approx, "第二步画成图片后还原") }
            }
            if lp == "background-image", key.part != .main, lv.lowercased().contains("url(") {
                mark(p.item, .approx, "第二步画成图片后还原")
            }
        }
    }

    static let borderStyles: Set<String> = [
        "none", "hidden", "solid", "dashed", "dotted", "double", "groove", "ridge", "inset", "outset",
    ]

    /// border / outline 简写：宽、样式、颜色
    static func borderParts(_ v: String) -> (width: String, style: String, color: String)? {
        var width: String?, style: String?, color: String?
        let ctx = CssValueContext()
        for w in CssScan.words(v) {
            let lw = w.lowercased()
            if borderStyles.contains(lw) {
                guard style == nil else { return nil }
                style = lw
            } else if ["thin", "medium", "thick"].contains(lw) || CssVal.length(w, ctx) != nil {
                guard width == nil else { return nil }
                width = w
            } else {
                guard color == nil else { return nil }
                color = w
            }
        }
        return (width ?? "medium", style ?? "none", color ?? "currentcolor")
    }

    /// 1 到 4 个值按 上 右 下 左 展开
    static func edges4(_ v: String) -> [String]? {
        let w = CssScan.words(v)
        switch w.count {
        case 1: return [w[0], w[0], w[0], w[0]]
        case 2: return [w[0], w[1], w[0], w[1]]
        case 3: return [w[0], w[1], w[2], w[1]]
        case 4: return w
        default: return nil
        }
    }

    /// 简写展开成单项。不是要读的属性返回空（只留原文），读不懂返回 nil
    static func expand(_ prop: String, _ value: String) -> [(String, String)]? {
        let v = CssScan.trim(value)
        switch prop {
        case "background":
            return expandBackground(v)
        case "border":
            guard let b = borderParts(v) else { return nil }
            return sides.flatMap { [("border-\($0)-width", b.width), ("border-\($0)-style", b.style), ("border-\($0)-color", b.color)] }
        case "border-top", "border-right", "border-bottom", "border-left":
            guard let b = borderParts(v) else { return nil }
            return [("\(prop)-width", b.width), ("\(prop)-style", b.style), ("\(prop)-color", b.color)]
        case "border-width", "border-style", "border-color":
            guard let four = edges4(v) else { return nil }
            let suffix = String(prop.dropFirst(7))
            return zip(sides, four).map { ("border-\($0.0)-\(suffix)", $0.1) }
        case "outline":
            guard let b = borderParts(v) else { return nil }
            return [("outline-width", b.width), ("outline-style", b.style), ("outline-color", b.color)]
        case "padding", "margin":
            guard let four = edges4(v) else { return nil }
            return zip(sides, four).map { ("\(prop)-\($0.0)", $0.1) }
        case "font":
            return expandFont(v)
        case "gap", "row-gap", "column-gap":
            guard let first = CssScan.words(v).first else { return nil }
            return [("gap", first)]
        case "-ph-icon-hidden":
            return [(prop, v.lowercased() == "none" ? "1" : "0")]
        case "-ph-icon-color":
            return [(prop, v)]
        default:
            return visualProps.contains(prop) ? [(prop, v)] : []
        }
    }

    static let repeatWords: Set<String> = ["repeat", "no-repeat", "repeat-x", "repeat-y", "space", "round"]
    static let boxWords: Set<String> = ["scroll", "fixed", "local", "border-box", "padding-box", "content-box", "text"]
    static let positionWords: Set<String> = ["left", "right", "top", "bottom", "center"]

    static func expandBackground(_ v: String) -> [(String, String)]? {
        let layers = CssScan.split(v, on: ",")
        let ctx = CssValueContext()
        var images: [String] = [], sizes: [String] = [], positions: [String] = [], repeats: [String] = []
        var color = "transparent"
        for (li, layer) in layers.enumerated() {
            var img = "none"
            var pos: [String] = [], size: [String] = [], rep: [String] = []
            var afterSlash = false
            for w in CssScan.words(layer, slash: true) {
                let lw = w.lowercased()
                if w == "/" { afterSlash = true; continue }
                if let f = CssScan.function(w), f.name == "url" || f.name.hasSuffix("gradient") || f.name.hasSuffix("image-set") {
                    img = w
                    continue
                }
                if lw == "none" { img = "none"; continue }
                if repeatWords.contains(lw) { rep.append(lw); continue }
                if boxWords.contains(lw) { continue }
                if afterSlash { size.append(w); continue }
                if positionWords.contains(lw) || CssVal.length(w, ctx) != nil { pos.append(w); continue }
                if li == layers.count - 1, CssVal.color(w, ctx) != nil { color = w; continue }
                return nil
            }
            images.append(img)
            sizes.append(size.joined(separator: " "))
            positions.append(pos.joined(separator: " "))
            repeats.append(rep.isEmpty ? "repeat" : rep.joined(separator: " "))
        }
        func list(_ a: [String]) -> String { a.allSatisfy({ $0.isEmpty }) ? "" : a.joined(separator: ", ") }
        return [
            ("background-color", color),
            ("background-image", images.allSatisfy({ $0 == "none" }) ? "none" : images.joined(separator: ", ")),
            ("background-size", list(sizes)),
            ("background-position", list(positions)),
            ("background-repeat", repeats.joined(separator: ", ")),
        ]
    }

    static let fontStyleWords: Set<String> = [
        "normal", "italic", "oblique", "small-caps", "condensed", "expanded", "semi-condensed", "semi-expanded",
        "ultra-condensed", "extra-condensed", "ultra-expanded", "extra-expanded",
    ]

    /// font 简写：[样式] [粗细] 字号[/行高] 字体
    static func expandFont(_ v: String) -> [(String, String)]? {
        let w = CssScan.words(v, slash: true)
        var i = 0
        var weight = "normal"
        while i < w.count {
            let lw = w[i].lowercased()
            if fontStyleWords.contains(lw) { i += 1; continue }
            if lw == "bold" || lw == "bolder" || lw == "lighter" { weight = lw; i += 1; continue }
            if let n = CssScan.number(lw), n.unit.isEmpty { weight = lw; i += 1; continue }
            break
        }
        guard i < w.count else { return nil }
        let size = w[i]
        guard CssVal.length(size, CssValueContext()) != nil || CssVal.fontSizeKeyword(size) != nil else { return nil }
        i += 1
        var lh = "normal"
        if i < w.count, w[i] == "/" {
            guard i + 1 < w.count else { return nil }
            lh = w[i + 1]
            i += 2
        }
        guard i < w.count else { return nil }
        let family = w[i...].joined(separator: " ")
        return [("font-weight", weight), ("font-size", size), ("line-height", lh), ("font-family", family)]
    }

    // MARK: 读成 CssStyle

    /// 一个键的全部单项读成样式。按下、聚焦时没写的边框宽度、样式等，取同一钩子平时的
    func style(_ key: CssKey) -> (CssStyle, [Mark]) {
        let own = long[key] ?? [:]
        let base: [String: Win] = key.state == .normal ? [:]
            : (long[CssKey(hook: key.hook, state: .normal, part: key.part)] ?? [:])
        var marks: [Mark] = []
        var st = CssStyle()
        var ctx = CssValueContext()

        func get(_ p: String) -> Win? { own[p] }
        func getF(_ p: String) -> Win? { own[p] ?? base[p] }
        func fail(_ w: Win) { marks.append(Mark(item: w.item, kind: .skipped, reason: "这个值无法识别")) }
        func approx(_ w: Win, _ reason: String) { marks.append(Mark(item: w.item, kind: .approx, reason: reason)) }
        let black = CssColor(r: 0, g: 0, b: 0, a: 1)
        let sizeKeywords: Set<String> = ["auto", "none", "fit-content", "max-content", "min-content", "inherit", "initial", "unset"]

        // 字号先读，em 要用
        func fontSize(_ w: Win) -> Double? {
            let t = CssScan.trim(w.value).lowercased()
            if let k = CssVal.fontSizeKeyword(t) { return k }
            switch CssVal.length(t, CssValueContext()) {
            case .px(let v)?: return max(0, v)
            case .percent(let p)?: return 16 * p / 100
            case nil: return nil
            }
        }
        if let w = get("font-size") {
            if let v = fontSize(w) {
                st.fontSize = v
                let t = w.value.lowercased()
                if t.hasSuffix("%") || (t.hasSuffix("em") && !t.hasSuffix("rem")) { approx(w, "相对字号按 16 像素换算") }
            } else {
                fail(w)
            }
        }
        if let f = st.fontSize ?? getF("font-size").flatMap(fontSize) { ctx.fontSize = f }

        if let w = get("color") {
            if w.value.lowercased() != "currentcolor" {
                if let c = CssVal.color(w.value, ctx) { st.color = c } else { fail(w) }
            }
        }
        ctx.color = st.color ?? getF("color").flatMap { CssVal.color($0.value, CssValueContext()) }

        func dimension(_ p: String) -> Double? {
            guard let w = get(p) else { return nil }
            if sizeKeywords.contains(CssScan.trim(w.value).lowercased()) { return nil }
            if let v = CssVal.px(w.value, ctx) { return max(0, v) }
            approx(w, "这个尺寸按原生默认处理")
            return nil
        }
        st.width = dimension("width")
        st.height = dimension("height")
        st.minWidth = dimension("min-width")
        st.minHeight = dimension("min-height")
        let sizeCtx = ctx
        let knownWidth = st.width ?? getF("width").flatMap { CssVal.px($0.value, sizeCtx) }
        let knownHeight = st.height ?? getF("height").flatMap { CssVal.px($0.value, sizeCtx) }
        ctx.width = knownWidth
        ctx.height = knownHeight

        if let w = get("opacity") {
            if let v = CssVal.fraction(w.value) { st.opacity = min(1, max(0, v)) } else { fail(w) }
        }

        // 背景
        let bgProps = ["background-color", "background-image", "background-size", "background-position", "background-repeat"]
        if bgProps.contains(where: { get($0) != nil }) {
            var bg = CssBackground()
            if let w = get("background-image") {
                for item in CssScan.split(w.value, on: ",") where !item.isEmpty {
                    if item.lowercased() == "none" { continue }
                    if let u = CssVal.url(item) {
                        bg.layers.append(.image(url: u))
                    } else if let g = CssVal.gradient(item, ctx) {
                        bg.layers.append(.gradient(g.gradient))
                        if g.approx { approx(w, "渐变里的像素位置按近似换算") }
                    } else if let f = CssScan.function(item), f.name.contains("gradient") || f.name.contains("image-set") {
                        approx(w, "第二步画成图片后还原")
                    } else {
                        fail(w)
                    }
                }
            }
            if let w = get("background-color") {
                if let c = CssVal.color(w.value, ctx) { bg.layers.append(.color(c)) } else { fail(w) }
            }
            if let w = get("background-size") { bg.size = CssScan.trim(w.value) }
            if let w = get("background-position") { bg.position = CssScan.trim(w.value) }
            if let w = get("background-repeat") {
                let first = CssScan.words(CssScan.split(w.value, on: ",").first ?? "").first?.lowercased() ?? "repeat"
                bg.repeatImage = first != "no-repeat"
                if first != "no-repeat" && first != "repeat" { approx(w, "只朝一个方向重复的背景按铺满处理") }
            }
            st.background = bg
        }

        // 边框
        func edge(_ prefix: String) -> CssBorder? {
            let names = ["\(prefix)-width", "\(prefix)-style", "\(prefix)-color"]
            guard names.contains(where: { get($0) != nil }) else { return nil }
            let style = getF(names[1]).map { CssScan.trim($0.value).lowercased() } ?? "none"
            if style == "none" || style == "hidden" { return CssBorder(width: 0, color: .clear) }
            var width = 3.0
            if let w = getF(names[0]) {
                switch CssScan.trim(w.value).lowercased() {
                case "thin": width = 1
                case "medium": width = 3
                case "thick": width = 5
                default:
                    if let v = CssVal.px(w.value, ctx) { width = max(0, v) } else { fail(w) }
                }
            }
            var color = ctx.color ?? black
            if let w = getF(names[2]) {
                if let c = CssVal.color(w.value, ctx) { color = c } else { fail(w) }
            }
            var name = "solid"
            if style == "dashed" || style == "dotted" { name = style }
            else if style != "solid", let w = getF(names[1]) { approx(w, "这种边框样式按实线处理") }
            return CssBorder(width: width, color: color, style: name)
        }
        let top = edge("border-top"), right = edge("border-right"), bottom = edge("border-bottom"), left = edge("border-left")
        if let top, let right, let bottom, let left, top == right, right == bottom, bottom == left {
            st.border = top
        } else {
            if let l = left ?? right {
                st.border = l
                if let r = right, r != l, let w = get("border-right-width") ?? get("border-right-color") ?? get("border-right-style") {
                    approx(w, "左右两边按同一种边框处理")
                }
                if let t = top, t != l { st.borderTop = t }
                if let b = bottom, b != l { st.borderBottom = b }
            } else {
                st.borderTop = top
                st.borderBottom = bottom
            }
        }
        st.outline = edge("outline")

        // 圆角
        let corners = ["border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius"]
        if let w = get("border-radius") ?? corners.lazy.compactMap({ get($0) }).first {
            let firstGroup = CssScan.split(w.value, on: "/").first ?? w.value
            let vals = CssScan.words(firstGroup)
            switch vals.first.flatMap({ CssVal.length($0, ctx) }) {
            case .px(let v)?: st.radius = max(0, v)
            case .percent(let p)?: st.radiusPercent = p
            case nil: fail(w)
            }
            if Set(vals).count > 1 || get("border-radius") == nil { approx(w, "四个角按同一个圆角处理") }
        }

        // 内外边距
        func edges(_ p: String) -> CssEdges? {
            guard Self.sides.contains(where: { get("\(p)-\($0)") != nil }) else { return nil }
            var e = CssEdges()
            for side in Self.sides {
                guard let w = getF("\(p)-\(side)") else { continue }
                var v = 0.0
                if let x = CssVal.px(w.value, ctx) { v = x }
                else if CssScan.trim(w.value).lowercased() == "auto" || CssVal.length(w.value, ctx) != nil {
                    approx(w, "自动与百分比的边距按 0 处理")
                } else { fail(w) }
                switch side {
                case "top": e.top = v
                case "right": e.right = v
                case "bottom": e.bottom = v
                default: e.left = v
                }
            }
            return e
        }
        st.padding = edges("padding")
        st.margin = edges("margin")

        if let w = get("box-shadow") {
            if let s = CssVal.shadows(w.value, ctx, text: false) { st.shadows = s } else { fail(w) }
        }
        if let w = get("text-shadow") {
            if let s = CssVal.shadows(w.value, ctx, text: true) { st.textShadows = s } else { fail(w) }
        }
        if let w = get("font-weight") {
            if let v = CssVal.fontWeight(w.value) { st.fontWeight = v } else { fail(w) }
        }
        if let w = get("font-family") {
            if let f = CssVal.fontFamily(w.value) { st.fontFamily = f } else { fail(w) }
        }
        if let w = get("letter-spacing") {
            if CssScan.trim(w.value).lowercased() == "normal" { st.letterSpacing = 0 }
            else if let v = CssVal.px(w.value, ctx) { st.letterSpacing = v }
            else { fail(w) }
        }
        if let w = get("line-height") {
            let t = CssScan.trim(w.value).lowercased()
            if t != "normal" {
                if let n = CssScan.number(t), n.unit.isEmpty {
                    st.lineHeight = n.value
                } else if let n = CssScan.number(t), n.unit == "%" {
                    st.lineHeight = n.value / 100
                } else if let v = CssVal.px(t, ctx) {
                    st.lineHeightPx = v
                    if ctx.fontSize > 0 { st.lineHeight = v / ctx.fontSize }
                } else {
                    fail(w)
                }
            }
        }
        if let w = get("text-align") {
            switch CssScan.trim(w.value).lowercased() {
            case "left", "start": st.textAlign = "left"
            case "right", "end": st.textAlign = "right"
            case "center": st.textAlign = "center"
            case "justify": st.textAlign = "justify"
            default: fail(w)
            }
        }
        if let w = get("gap") {
            if let v = CssVal.px(w.value, ctx) { st.gap = max(0, v) }
            else if CssScan.trim(w.value).lowercased() != "normal" { approx(w, "这个间距按原生默认处理") }
        }
        if let w = get("transform") {
            if let t = CssVal.transform(w.value, ctx) {
                st.transform = t.transform
                if t.approx { approx(w, "变换里有原生版不认的部分，按平移、旋转、缩放近似") }
            } else {
                fail(w)
            }
        }
        if let w = get("display") {
            st.hidden = CssScan.trim(w.value).lowercased() == "none"
        }
        if let w = get("content"), key.part != .main {
            if let c = CssVal.content(w.value) {
                if c.none { st.hidden = true } else { st.content = c.text }
            } else {
                approx(w, "content 里只认文字，计数与属性原生版不认")
            }
        }

        for (p, w) in raw[key] ?? [:] { st.raw[p] = w.value }
        if let w = get("-ph-icon-hidden") { st.raw["iconHidden"] = w.value }
        if let w = get("-ph-icon-color") {
            if CssVal.color(w.value, ctx) != nil { st.raw["iconColor"] = CssScan.trim(w.value) } else { fail(w) }
        }
        return (st, marks)
    }
}
