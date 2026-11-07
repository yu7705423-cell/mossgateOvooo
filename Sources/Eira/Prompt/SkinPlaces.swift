import Foundation

/// 「美化」首页的文件夹（网页版 system/styleplaces.js 的 categories，ARCHITECTURE 4.810、4.811）：
/// 能写样式的地方按类列出，每一类是一个文件夹，里面正在使用的排在前面。
///
/// 编辑的地方不挪（第 5 条）：这里只画出现在的样子、带路去编辑。原生版里还没有的几处（外观的自定义 CSS、悬浮球、问卷）不列，
/// 它们的数据照旧留在库里、导出不丢。以后原生版做了，在 `categories` 里加一类。
enum SkinPlaces {
    /// 一样东西画成什么样
    enum Preview: Equatable {
        /// 一份会话美化（库里的或内置的），画成示例会话
        case skin(String)
        /// 一段样式或 HTML 原文
        case code(String)
    }

    /// 点「编辑」去哪儿
    enum Go: Equatable, Hashable {
        /// 这一份美化的详情页
        case skin(String)
        /// 全部会话的默认主题（「设置 - 主题 - 聊天主题」同一页）
        case global
        /// 这段会话的状态栏设置
        case status(String)
        /// 线下外观；nil 为所有线下共用的那一份
        case stage(String?)
        /// 世界书里的一条卡片
        case card(book: String, entry: String)
    }

    struct Item: Equatable, Identifiable {
        let key: String
        let title: String
        let sub: String
        var on = false
        var preview: Preview?
        var go: Go?
        var id: String { key }
    }

    struct Category: Equatable, Identifiable {
        let id: String
        let title: String
        /// SF Symbols 的名字
        let icon: String
        let desc: String
        /// 编辑位置
        let place: String
        var using: [Item] = []
        var rest: [Item] = []
        /// 这一类自己的编辑页（单一去处的那几类）
        var go: Go?
        /// 能在文件夹里新建一份
        var canNew = false

        /// 正在用的在前
        var items: [Item] { using.map { var i = $0; i.on = true; return i } + rest }
    }

    private static func has(_ v: JSONValue?) -> Bool {
        !(v?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func rows(_ c: String) -> [Row] { (try? Database.shared.all(c)) ?? [] }

    static func chatName(_ r: Row) -> String {
        let ids = r.strings("characterIds")
        if ids.count > 1 { return r.string("title").isEmpty ? "群聊" : r.string("title") }
        if let id = ids.first, let c = try? Database.shared.get(Collections.characters, id: id) {
            let n = c.string("name")
            if !n.isEmpty { return n }
        }
        return r.string("title").isEmpty ? "未命名会话" : r.string("title")
    }

    static func skinItem(_ r: Row, used: Int) -> Item {
        Item(key: r.id, title: r.string("name").isEmpty ? "未命名" : r.string("name"),
             sub: ChatTheme.isBuiltin(r.id) ? (used > 0 ? "内置，用于 \(used) 段会话" : "内置")
                : (used > 0 ? "用于 \(used) 段会话" : "尚未用于任何会话"),
             preview: .skin(r.id), go: .skin(r.id))
    }

    static func categories(settings s: AppSettings = .load()) -> [Category] {
        let chats = rows(Collections.chats)
        var usedBy: [String: Int] = [:]
        for c in chats {
            let id = c.string("skinId")
            if !id.isEmpty { usedBy[id, default: 0] += 1 }
        }
        let gid = s.raw["skinOff"]?.bool == true ? "" : (s.raw["globalSkinId"]?.string ?? "")
        let mine = Skins.all()
        let library = mine + ChatTheme.builtins
        let inUse = { (r: Row) in (usedBy[r.id] ?? 0) > 0 || r.id == gid }

        var out: [Category] = []
        out.append(Category(
            id: "chat", title: "会话美化", icon: "bubble.left.and.bubble.right", desc: "会话页面的气泡、顶栏、输入框与背景。一份可挂在多段会话上",
            place: "会话右上角菜单 - 主题",
            using: library.filter(inUse).map { skinItem($0, used: usedBy[$0.id] ?? 0) },
            rest: library.filter { !inUse($0) }.map { skinItem($0, used: 0) }, canNew: true))

        var app = Category(id: "app", title: "应用美化", icon: "square.grid.2x2", desc: "没有单独挂主题的会话使用的默认主题",
                           place: "美化 - 应用美化；设置 - 主题 - 聊天主题", go: .global)
        if let g = ChatTheme.row(gid) {
            var it = skinItem(g, used: usedBy[g.id] ?? 0)
            it = Item(key: "global", title: it.title, sub: "全部会话的默认", preview: it.preview, go: .global)
            app.using = [it]
        }
        out.append(app)

        var status = Category(id: "status", title: "状态栏", icon: "list.bullet.rectangle", desc: "每段会话线上、线下各一份",
                              place: "会话右上角菜单 - 状态栏 - 样式")
        for c in chats {
            let sb = c["statusBar"]
            let mode = has(sb?["online"]?["css"]) ? "online" : has(sb?["offline"]?["css"]) ? "offline" : ""
            guard !mode.isEmpty else { continue }
            status.using.append(Item(key: c.id, title: chatName(c), sub: mode == "online" ? "线上" : "线下",
                                     preview: .code(sb?[mode]?["css"]?.string ?? ""), go: .status(c.id)))
        }
        out.append(status)

        var inner = Category(id: "inner", title: "心声卡片", icon: "heart.text.square", desc: "心声显示成卡片时的 HTML 与样式，每段会话一份",
                             place: "会话右上角菜单 - 心声 - 心声卡片")
        for c in chats where has(c["innerCard"]?["html"]) {
            inner.using.append(Item(key: c.id, title: chatName(c), sub: "心声卡片", preview: .code(c["innerCard"]?["html"]?.string ?? "")))
        }
        out.append(inner)

        var stage = Category(id: "stage", title: "线下", icon: "book", desc: "所有线下页面共用的一份，以及某一场自己的一份",
                             place: "设置 - 外观 - 线下外观；线下某一场 - 外观", go: .stage(nil))
        if has(s.raw["stage"]?["css"]) {
            stage.using.append(Item(key: "stage", title: "线下外观", sub: "所有线下共用", preview: .code(s.raw["stage"]?["css"]?.string ?? ""), go: .stage(nil)))
        }
        let chatById = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for sc in rows("scenes") where has(sc["stage"]?["css"]) {
            stage.using.append(Item(key: sc.id, title: sc.string("title").isEmpty ? "未命名的一场" : sc.string("title"),
                                    sub: chatById[sc.string("chatId")].map(chatName) ?? "未命名会话",
                                    preview: .code(sc["stage"]?["css"]?.string ?? ""), go: .stage(sc.id)))
        }
        out.append(stage)

        var card = Category(id: "card", title: "HTML 卡片", icon: "rectangle.on.rectangle", desc: "角色在聊天中填写后发送的卡片",
                            place: "设定集 - 世界书 - 某本书 - 卡片条目")
        for b in rows(Collections.lorebooks) {
            for e in b["entries"]?.array ?? [] where e["type"]?.string == "card" && has(e["card"]?["html"]) {
                let eid = e["id"]?.string ?? ""
                let name = e["comment"]?.string ?? ""
                card.using.append(Item(key: "\(b.id):\(eid)", title: name.isEmpty ? "未命名卡片" : name, sub: b.string("name"),
                                       preview: .code(e["card"]?["html"]?.string ?? ""), go: .card(book: b.id, entry: eid)))
            }
        }
        out.append(card)

        var widget = Category(id: "widget", title: "主屏组件", icon: "chevron.left.forwardslash.chevron.right", desc: "HTML 写成的主屏小组件，在主屏整理时编辑",
                              place: "主屏 - 长按进入整理 - 点一下组件 - 编辑内容")
        let layout = (try? Database.shared.kv(KVKey.layout)) ?? nil
        for p in layout?["pages"]?.array ?? [] {
            for c in p["cells"]?.array ?? [] where c["kind"]?.string == "widget" && c["ref"]?.string == "custom" && has(c["config"]?["fileId"]) {
                let w = Int(c["w"]?.number ?? 0), h = Int(c["h"]?.number ?? 0)
                let name = c["config"]?["name"]?.string ?? c["title"]?.string ?? ""
                widget.using.append(Item(key: c["id"]?.string ?? UUID().uuidString, title: name.isEmpty ? "自定义组件" : name, sub: "\(w) × \(h) 格"))
            }
        }
        out.append(widget)
        return out
    }
}
