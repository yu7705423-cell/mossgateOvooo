import SwiftUI

/// 全部世界书。
struct LorebookListView: View {
    @State private var books: [Lorebook] = []
    @State private var opening: Target?
    @State private var problem: String?

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
        }
        .navigationTitle("世界书")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: create) { Image(systemName: "plus") }.accessibilityLabel("新建世界书")
            }
        }
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
                    Text("关闭时，只对在资料页挂上这本书的角色生效。")
                } else {
                    Text("这本书用于「\(LoreText.purposes[book?.purpose ?? ""] ?? "")」，原生版暂未使用。")
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
                Button("添加条目", action: addEntry)
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

    private func addEntry() {
        do {
            saveHeader()
            let id = try Knowledge.addEntry(bookId: bookId)
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
        if e.isCard { parts.append("网页卡片") }
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

    var body: some View {
        Form {
            if entry?.isCard == true {
                Section { Text("这是网页版的网页卡片条目，不作为设定注入。原生版暂不支持编辑卡片内容。").foregroundStyle(Theme.secondaryText) }
            }
            Section {
                TextField("标题（只给自己看）", text: $comment)
                TextField("内容", text: $content, axis: .vertical).lineLimit(4...30)
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
                Text("常驻的每轮都注入。其余的在最近几条消息里出现任一关键词时注入；填了次要关键词的，还要再出现其中一个。")
            }
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
                Text("优先级大的排在前面；优先级相同时按顺序从小到大。")
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
        } catch {
            problem = error.localizedDescription
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
            ])
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
                Text("挂上的世界书在与该角色对话时按关键词注入。")
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
