import SwiftUI
import UniformTypeIdentifiers

/// 全部世界书。
struct LorebookListView: View {
    @State private var books: [Lorebook] = []
    @State private var opening: Target?
    @State private var problem: String?
    @State private var importing = false
    @State private var batch: LoreBatch?
    @State private var exported: URL?

    struct LoreBatch: Identifiable { let id = UUID(); let drafts: [LoreFile.Draft]; let failed: [String] }

    struct Target: Identifiable, Hashable { let id: String }

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            ForEach(books) { b in
                Button { opening = Target(id: b.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.name.isEmpty ? "未命名世界书" : b.name).foregroundStyle(Theme.bubbleTheirsText)
                        Text(LoreText.summary(b)).font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            if books.isEmpty { Text("暂无世界书。").foregroundStyle(Theme.secondaryText) }
            Section {
                NavigationLink { LorePreviewView() } label: { Text("激活预览") }
                Button("从文件批量导入") { importing = true }
                if !books.isEmpty {
                    Button("导出全部为 txt") {
                        do { exported = try LoreFile.exportFile(books.map(\.row)) } catch { problem = "未能导出：\(error.localizedDescription)" }
                    }
                }
                if let exported {
                    ShareLink(item: exported) { Label("存储或发送导出的文件", systemImage: "square.and.arrow.up") }
                }
            } footer: {
                HelpNote("批量导入读 txt、md、docx，以及装有它们的 zip，每个文件一本：有「## 」小标题的一个小标题一条，没有就整篇一条。本应用导出的文件写明了每一条的关键词、常驻、位置与深度，导入时原样还原。读进来先进确认页，逐本确认后才保存。不做 JSON 导入。导出时一本为一个 txt，多本装进一个 zip。", title: "世界书：导入与导出")
            }
        }
        .navigationTitle("世界书")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: create) { NavIcon("plus") }.accessibilityLabel("新建世界书")
            }
        }
        .documentPicker(isPresented: $importing, types: ["txt", "md", "docx", "zip"].compactMap { UTType(filenameExtension: $0) }, multiple: true) { urls in
            guard !urls.isEmpty else { return }
            let r = LoreFile.readFiles(urls)
            batch = LoreBatch(drafts: r.drafts, failed: r.failed)
        }
        .sheet(item: $batch, onDismiss: reload) { b in NavigationStack { LoreImportView(drafts: b.drafts, failed: b.failed) } }
        .navigationDestination(item: $opening) { t in LorebookView(bookId: t.id) }
        .onAppear(perform: reload)
    }

    private func reload() {
        do { books = try Repo.lorebooks(); problem = nil } catch { problem = error.localizedDescription }
    }

    private func create() {
        do {
            let b = try Knowledge.createBook(name: "新世界书")
            reload()
            opening = Target(id: b.id)
        } catch {
            problem = "新建失败：\(error.localizedDescription)"
        }
    }
}

enum LoreText {
    static let purposes = ["chat": "对话", "image": "生图", "voice": "语音", "memory": "记忆", "forum": "论坛"]

    static func summary(_ b: Lorebook) -> String {
        var parts = ["\(b.entries.count) 条", purposes[b.purpose] ?? b.purpose]
        if b.global { parts.append("对全部角色生效") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// 一本世界书：名字、说明、是否对全部角色生效，以及它的条目。
struct LorebookView: View {
    let bookId: String
    @Environment(\.dismiss) private var dismiss
    @State private var book: Lorebook?
    @State private var name = ""
    @State private var description = ""
    @State private var global = false
    @State private var editingEntry: Target?
    @State private var confirmDelete = false
    @State private var problem: String?

    struct Target: Identifiable, Hashable { let id: String }

    var body: some View {
        Form {
            Section {
                TextField("名字", text: $name)
                TextField("说明", text: $description, axis: .vertical)
                if book?.purpose == "chat" {
                    Toggle("对全部角色生效", isOn: $global)
                }
            } footer: {
                if book?.purpose == "chat" {
                    HelpNote("关闭时，只对在资料页挂上这本书的角色生效。")
                } else {
                    HelpNote("这本书用于「\(LoreText.purposes[book?.purpose ?? ""] ?? "")」，原生版暂未使用。")
                }
            }
            Section("条目") {
                ForEach(book?.entries ?? []) { e in
                    Button { editingEntry = Target(id: e.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LoreEntryText.title(e)).foregroundStyle(e.enabled ? Theme.bubbleTheirsText : Theme.tertiaryText)
                            Text(LoreEntryText.summary(e)).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                Button("添加条目") { addEntry(card: false) }
                if book?.purpose == "chat" { Button("添加卡片") { addEntry(card: true) } }
            }
            Section {
                Button("删除这本世界书", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText)
            } footer: {
                Text("同时从各个角色身上摘下，无法撤销。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle(name.isEmpty ? "世界书" : name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $editingEntry) { t in LoreEntryEditView(bookId: bookId, entryId: t.id) }
        .confirmationDialog("删除后无法恢复。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Knowledge.deleteBook(bookId); dismiss() } catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        }
        .onAppear(perform: reload)
        .onDisappear(perform: saveHeader)
    }

    private func reload() {
        do {
            guard let b = try Knowledge.book(bookId) else { return }
            if book == nil { name = b.name; description = b.row.string("description"); global = b.global }
            book = b
        } catch {
            problem = error.localizedDescription
        }
    }

    /// 名字、说明、生效范围离开页面时存。
    private func saveHeader() {
        guard let b = book else { return }
        guard name != b.name || description != b.row.string("description") || global != b.global else { return }
        do {
            book = try Knowledge.updateBook(bookId, ["name": .string(name), "description": .string(description), "global": .bool(global)])
        } catch {
            Problems.report("世界书未能保存：\(error.localizedDescription)")
        }
    }

    private func addEntry(card: Bool) {
        do {
            saveHeader()
            let id = try Knowledge.addEntry(bookId: bookId, card: card)
            reload()
            editingEntry = Target(id: id)
        } catch {
            problem = "添加失败：\(error.localizedDescription)"
        }
    }
}

enum LoreEntryText {
    static func title(_ e: LoreEntry) -> String {
        if !e.comment.isEmpty { return e.comment }
        if !e.keys.isEmpty { return e.keys.joined(separator: "、") }
        return e.content.isEmpty ? "未命名条目" : String(e.content.prefix(20))
    }

    static func summary(_ e: LoreEntry) -> String {
        var parts: [String] = []
        if !e.enabled { parts.append("已关闭") }
        if e.isCard { parts.append("卡片") }
        parts.append(e.constant ? "常驻" : (e.keys.isEmpty ? "未填关键词" : "关键词触发"))
        parts.append(e.part == "before" ? "角色卡前" : "角色卡后")
        if e.depth > 0 { parts.append("插在倒数第 \(e.depth) 条之前") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// 编辑一条设定。
struct LoreEntryEditView: View {
    let bookId: String
    let entryId: String
    @Environment(\.dismiss) private var dismiss
    @State private var entry: LoreEntry?
    @State private var comment = ""
    @State private var keys = ""
    @State private var secondaryKeys = ""
    @State private var content = ""
    @State private var enabled = true
    @State private var constant = false
    @State private var caseSensitive = false
    @State private var probability = 100
    @State private var priority = 100
    @State private var order = 0
    @State private var part = "before"
    @State private var depth = 0
    @State private var confirmDelete = false
    @State private var problem: String?
    // HTML 卡片（type 为 card 的条目）
    @State private var card: [String: JSONValue] = [:]
    @State private var cardHtml = ""
    @State private var sample = ""
    @State private var preview = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            if entry?.isCard == true {
                Section {
                    TextField("卡片名（角色写 [卡片：卡片名]）", text: $comment)
                    TextField("说明（写进提示词，告诉角色这张卡片是什么）", text: $content, axis: .vertical).lineLimit(2...10)
                } footer: {
                    HelpNote("卡片条目不作为设定注入。常驻的或最近几条消息里出现关键词时，卡片名、说明与字段写进提示词，角色按字段填写，应用按模板画出来。模板本身不进提示词。", title: "HTML 卡片")
                }
                cardSections
            } else {
                Section {
                    TextField("标题（只给自己看）", text: $comment)
                    TextField("内容", text: $content, axis: .vertical).lineLimit(4...30)
                }
            }
            Section {
                Toggle("启用", isOn: $enabled)
                Toggle("常驻", isOn: $constant)
                if !constant {
                    TextField("关键词，用顿号或逗号隔开", text: $keys)
                    TextField("次要关键词（可留空）", text: $secondaryKeys)
                    Toggle("区分大小写", isOn: $caseSensitive)
                    Stepper("触发概率：\(probability)%", value: $probability, in: 0...100, step: 5)
                }
            } header: {
                Text("触发")
            } footer: {
                HelpNote("常驻的每轮都注入。其余的在最近几条消息里出现任一关键词时注入；填了次要关键词的，还要再出现其中一个。")
            }
            if entry?.isCard != true {
            Section {
                Picker("位置", selection: $part) {
                    Text("角色卡前").tag("before")
                    Text("角色卡后").tag("after")
                }
                Stepper(depth == 0 ? "深度：放在设定区" : "深度：插在倒数第 \(depth) 条之前", value: $depth, in: 0...200)
                Stepper("优先级：\(priority)", value: $priority, in: 0...1000, step: 10)
                Stepper("同级顺序：\(order)", value: $order, in: -1000...1000)
            } header: {
                Text("位置")
            } footer: {
                HelpNote("优先级大的排在前面；优先级相同时按顺序从小到大。")
            }
            }
            Section { Button("删除这条设定", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText) }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("编辑设定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .confirmationDialog("删除后无法恢复。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Knowledge.deleteEntry(bookId: bookId, entryId: entryId); dismiss() }
                catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard entry == nil else { return }
        do {
            guard let e = try Knowledge.book(bookId)?.entries.first(where: { $0.id == entryId }) else { problem = "这条设定不存在"; return }
            entry = e
            comment = e.comment; keys = e.keys.joined(separator: "、"); secondaryKeys = e.secondaryKeys.joined(separator: "、")
            content = e.content; enabled = e.enabled; constant = e.constant; caseSensitive = e.caseSensitive
            probability = Int(e.probability); priority = Int(e.priority); order = Int(e.order); part = e.part; depth = e.depth
            card = e.json["card"]?.object ?? [:]
            cardHtml = card["html"]?.string ?? ""
            sample = card["sampleText"]?.string ?? ""
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - 卡片

    private var cardFields: [HtmlCard.Field] { HtmlCard.fields(cardHtml, card["fields"]?.object ?? [:]) }

    private var cardToSave: [String: JSONValue] {
        var c = card
        c["html"] = .string(cardHtml)
        c["sampleText"] = .string(sample)
        return c
    }

    private func cfg(_ key: String) -> [String: JSONValue] { card["fields"]?[key]?.object ?? [:] }

    private func setCfg(_ key: String, _ name: String, _ v: JSONValue?) {
        var all = card["fields"]?.object ?? [:]
        var one = all[key]?.object ?? [:]
        one[name] = v
        all[key] = .object(one)
        card["fields"] = .object(all)
    }

    @ViewBuilder private var cardSections: some View {
        Section {
            TextField("模板（HTML 与 CSS）", text: $cardHtml, axis: .vertical)
                .lineLimit(6...40)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            ForEach(HtmlCard.problems(cardHtml, images: card["images"]?.bool == true), id: \.self) { p in
                Text(p).font(.footnote).foregroundStyle(Theme.danger)
            }
            Picker("宽度", selection: Binding(get: { card["width"]?.string == "full" ? "full" : "bubble" }, set: { card["width"] = .string($0) })) {
                Text("气泡宽").tag("bubble")
                Text("整行宽").tag("full")
            }
            Picker("比例", selection: Binding(get: { card["ratio"]?.string ?? "4:3" }, set: { card["ratio"] = .string($0) })) {
                Text("4:3").tag("4:3"); Text("1:1").tag("1:1"); Text("3:4").tag("3:4")
                Text("横条").tag("strip"); Text("长条").tag("long"); Text("自定高度").tag("custom")
            }
            if card["ratio"]?.string == "custom" {
                Stepper("高度 \(Int(card["height"]?.number ?? 300))", value: Binding(get: { Int(card["height"]?.number ?? 300) }, set: { card["height"] = .number(Double($0)) }), in: 40...1200, step: 10)
            }
            Toggle("允许外部图片", isOn: Binding(get: { card["images"]?.bool == true }, set: { card["images"] = .bool($0) }))
        } header: { Text("模板") } footer: {
            HelpNote("占位符：{{字段}}；列表 {{#列表}}…{{/列表}}，列表里的 {{.}} 或 {{子字段}}；为空时显示 {{^字段}}…{{/字段}}。应用自己填的有 {{char}} {{user}} {{char_avatar}} {{user_avatar}}。卡片只显示 HTML 与 CSS，不运行脚本、不联网；占位符不能放在网址、样式表里。允许外部图片后，模板里写死的 https 图片可以显示，占位符仍不能放进网址。", title: "卡片模板")
        }
        let fields = cardFields
        if !fields.isEmpty {
            Section {
                ForEach(fields, id: \.name) { f in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.list ? "\(f.name)（列表\(f.sub.isEmpty ? "" : "：" + f.sub.joined(separator: "｜"))）" : f.name).font(.footnote)
                        TextField("说明（英文，写进提示词）", text: Binding(get: { cfg(f.name)["desc"]?.string ?? "" }, set: { setCfg(f.name, "desc", $0.isEmpty ? nil : .string($0)) }))
                        TextField("字数上限（不填为不限）", text: Binding(get: { cfg(f.name)["max"]?.number.map { String(Int($0)) } ?? "" },
                                                                 set: { setCfg(f.name, "max", Int($0).map { .number(Double($0)) }) }))
                            .keyboardType(.numberPad)
                    }
                }
            } header: { Text("字段") }
        }
        Section {
            TextField("示例（一行一个「字段：值」）", text: $sample, axis: .vertical).lineLimit(3...12)
            let size = HtmlCard.size(card)
            CardWebView(html: preview).frame(width: size.w, height: size.h).frame(maxWidth: .infinity)
        } header: { Text("预览") }
        .task(id: "\(cardHtml)|\(sample)|\(card["width"]?.string ?? "")|\(card["ratio"]?.string ?? "")|\(card["images"]?.bool == true)|\(scheme == .dark)") {
            var c = cardToSave
            c["fields"] = card["fields"]
            let values = HtmlCard.parseValues(sample, fields: HtmlCard.fields(cardHtml, card["fields"]?.object ?? [:]))
            preview = HtmlCard.doc(c, values: values, sys: ["char": "角色", "user": "我"], dark: scheme == .dark)
        }
    }

    private func save() {
        do {
            try Knowledge.updateEntry(bookId: bookId, entryId: entryId, [
                "comment": .string(comment),
                "keys": .array(Knowledge.splitList(keys).map { .string($0) }),
                "secondaryKeys": .array(Knowledge.splitList(secondaryKeys).map { .string($0) }),
                "content": .string(content), "enabled": .bool(enabled), "constant": .bool(constant),
                "caseSensitive": .bool(caseSensitive), "probability": .number(Double(probability)),
                "priority": .number(Double(priority)), "order": .number(Double(order)),
                "part": .string(part), "depth": .number(Double(depth)),
            ].merging(entry?.isCard == true ? ["card": .object(cardToSave)] : [:]) { a, _ in a })
            dismiss()
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
        }
    }
}

/// 资料页上的「世界书」：这个角色挂了哪几本。对全部角色生效的书不用挂。
struct CharacterLoreView: View {
    let charId: String
    @State private var books: [Lorebook] = []
    @State private var attached: Set<String> = []
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                ForEach(books.filter { $0.purpose == "chat" }) { b in
                    if b.global {
                        LabeledContent(b.name.isEmpty ? "未命名世界书" : b.name, value: "对全部角色生效")
                    } else {
                        Toggle(b.name.isEmpty ? "未命名世界书" : b.name, isOn: Binding(
                            get: { attached.contains(b.id) },
                            set: { on in toggle(b.id, on) }))
                    }
                }
            } footer: {
                HelpNote("挂上的世界书在与该角色对话时按关键词注入。", title: "角色挂载的世界书")
            }
            Section { NavigationLink("管理全部世界书") { LorebookListView() } }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("世界书")
        .onAppear(perform: reload)
    }

    private func reload() {
        do {
            books = try Repo.lorebooks()
            attached = Set(try Repo.character(charId)?.lorebookIds ?? [])
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func toggle(_ id: String, _ on: Bool) {
        do {
            try Knowledge.setAttached(on, bookId: id, charId: charId)
            if on { attached.insert(id) } else { attached.remove(id) }
        } catch {
            problem = "未能保存：\(error.localizedDescription)"
        }
    }
}

/// 批量导入的确认页（网页版 lore/Batch.js）：逐本定名称、用途、全局、启用、常驻、位置，全部确定后一并保存。
/// 这是「先看一眼再决定存不存」的确认页，所以显示每本的开头几句
struct LoreImportView: View {
    let drafts: [LoreFile.Draft]
    let failed: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var opts: [UUID: LoreFile.Options] = [:]
    @State private var problem: String?

    private static let purposes: [(String, String)] = [("chat", "对话"), ("image", "生图"), ("voice", "语音"), ("memory", "记忆总结"), ("forum", "论坛")]

    var body: some View {
        let chosen = drafts.filter { opts[$0.id]?.include ?? true }
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if !failed.isEmpty { Text("未能读取：\(failed.joined(separator: "；"))").font(.footnote).foregroundStyle(Theme.danger) }
            if drafts.isEmpty { Text("没有读到可导入的内容。支持 txt、md、docx，以及装有它们的 zip。").foregroundStyle(Theme.secondaryText) }
            ForEach(drafts) { d in
                let o = Binding(get: { opts[d.id] ?? LoreFile.Options(d) }, set: { opts[d.id] = $0 })
                Section {
                    Toggle(isOn: o.include) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("导入这一本")
                            let first = String((d.entries.first?["content"]?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
                            Text("\(d.entries.count) 个条目\(first.isEmpty ? "" : "。\(first)")").font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if o.wrappedValue.include {
                        TextField("名称", text: o.name)
                        Picker("用途", selection: o.purpose) { ForEach(Self.purposes, id: \.0) { Text($0.1).tag($0.0) } }
                        if o.wrappedValue.purpose != "forum" { Toggle("全局生效", isOn: o.global) }
                        if d.own { Toggle("保留文件里每一条的设置", isOn: o.keepOwn) }
                        if !(d.own && o.wrappedValue.keepOwn) {
                            Toggle("启用", isOn: o.enabled)
                            Toggle("常驻", isOn: o.constant)
                            if o.wrappedValue.purpose == "chat" {
                                Picker("所属部分", selection: o.part) { Text("角色前").tag("before"); Text("角色后").tag("after") }
                                Stepper("注入深度 \(o.wrappedValue.depth)", value: o.depth, in: 0...Int(Int32.max))
                            }
                        }
                    }
                } header: { Text(d.source) } footer: {
                    HelpNote("全局生效：对所有角色注入，无需单独关联。常驻：每一轮都注入；关闭时条目需有关键词、在对话中提到才注入，从文件读入的条目多半没有关键词。注入深度 0 表示放在设定区，大于 0 表示插在对话中倒数第几条之前。", title: "世界书：导入确认")
                }
            }
        }
        .navigationTitle("导入世界书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(chosen.isEmpty ? "保存" : "保存 \(chosen.count) 本") {
                    do {
                        for d in chosen { try LoreFile.save(d, opts[d.id] ?? LoreFile.Options(d)) }
                        dismiss()
                    } catch { problem = "未能保存：\(error.localizedDescription)" }
                }
                .disabled(chosen.isEmpty)
            }
        }
    }
}

/// 激活预览（网页版 lore/App.js 的 PreviewPage）：输入一段对话，看会激活哪些条目、约占多少 token。不调接口
struct LorePreviewView: View {
    @State private var charId = ""
    @State private var text = ""

    var body: some View {
        let chars = ((try? Repo.characters()) ?? []).filter { !$0.isNpc }
        let char = chars.first { $0.id == charId } ?? chars.first
        let budget = Int(AppSettings.load().num("contextBudget", 0))
        let r = char.map { ChatPrompt.selectLore(char: $0, scanText: text, budget: budget > 0 ? Int((Double(budget) * 0.4).rounded()) : 0) }
        Form {
            Section {
                Picker("以哪个角色的视角", selection: Binding(get: { char?.id ?? "" }, set: { charId = $0 })) {
                    ForEach(chars) { Text($0.displayName).tag($0.id) }
                }
                TextField("粘贴最近几条消息", text: $text, axis: .vertical).lineLimit(4...12)
            } footer: {
                HelpNote("输入一段对话，看会激活哪些条目、约占多少 token。只算用于对话的世界书：全局生效的，与关联在这个角色上的。设了概率的条目每次结果可能不同。", title: "世界书：激活预览")
            }
            if let r {
                Section("命中 \(r.items.count) 条 · 约 \(r.used) tokens") {
                    if r.items.isEmpty { Text("无条目被激活").foregroundStyle(Theme.secondaryText) }
                    ForEach(r.items.indices, id: \.self) { i in
                        let e = r.items[i]
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e.comment.isEmpty ? String(e.content.prefix(20)) : e.comment)
                                Spacer()
                                Text(e.constant ? "常驻" : "命中").font(.caption).foregroundStyle(Theme.secondaryText)
                            }
                            Text(e.content).font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(4)
                        }
                    }
                }
            } else {
                Text("还没有角色。").foregroundStyle(Theme.secondaryText)
            }
        }
        .navigationTitle("激活预览")
    }
}
