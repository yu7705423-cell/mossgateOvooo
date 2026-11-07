import SwiftUI

/// 角色的书架（网页版 theater/ShelfPage）：书目默认是占位，你导入同名的书之后那一格接上真书，能读、能一起读
struct ShelfView: View {
    let charId: String
    @State private var items: [Shelf.Item] = []
    @State private var adding = false
    @State private var generating = false
    @State private var problem: String?

    var body: some View {
        let char = (try? Repo.character(charId)) ?? nil
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Button { adding = true } label: { TogetherRow(icon: "plus", title: "添加一本", sub: "") }.buttonStyle(.plain)
                Button { generating = true } label: { TogetherRow(icon: "sparkle", title: "按角色设定生成书目", sub: "") }.buttonStyle(.plain)
            } footer: { Text("生成书目一次调用一次接口，先列出来勾选再放上书架。") }
            if items.isEmpty {
                Section { EmptyState(title: "书架是空的", desc: "添加一本，或者按角色设定生成一批书目。") }
            } else {
                Section("共 \(items.count) 本") {
                    ForEach(items) { it in
                        NavigationLink { ShelfItemView(charId: charId, entryId: it.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.title)
                                Text([it.author, it.book != nil ? "已接上书库里的这一本 · 读到 \(Books.percent(it.book))%" : "占位，书库里还没有这一本", it.note]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                }
            }
            Section {} footer: {
                HelpNote("书架上的书默认是占位：只有书名、作者与备注。在书库中导入同名的书之后，那一格自动接上真书，可以阅读、一起读；也可以在那一本里手动接上。", title: "角色的书架")
            }
        }
        .navigationTitle("\(char?.displayName ?? "角色") 的书架")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .sheet(isPresented: $adding, onDismiss: load) { NavigationStack { ShelfAddView(charId: charId) }.eiraLook() }
        .sheet(isPresented: $generating, onDismiss: load) { NavigationStack { ShelfGenView(charId: charId) }.eiraLook() }
    }

    private func load() { items = Shelf.list(charId) }
}

struct ShelfAddView: View {
    let charId: String
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var note = ""
    @State private var problem: String?

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section("书名") { TextField("书名", text: $title) }
            Section("作者") { TextField("可留空", text: $author) }
            Section {
                TextField("可留空", text: $note)
            } header: { Text("备注") } footer: { HelpNote("这本书对角色的意义：何时读过、从何处得来、为何留存。") }
            Section {
                Button("放上书架") {
                    do { try Shelf.add(charId, title: title, author: author, note: note); dismiss() }
                    catch { problem = error.localizedDescription }
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("添加一本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
}

/// 按角色设定生成书目：数目自己填，生成的先列出来勾选再存（网页版第 6 条的例外：确认页）
struct ShelfGenView: View {
    let charId: String
    @Environment(\.dismiss) private var dismiss
    @State private var count = 8.0
    @State private var kind = "real"
    @State private var busy = false
    @State private var got: [Shelf.Suggestion]?
    @State private var picked: Set<String> = []
    @State private var problem: String?

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                NumberRow(title: "生成几本", value: $count, unit: "本", placeholder: "8", range: 1...Double(Int32.max))
                Picker("可以列的书", selection: $kind) {
                    ForEach(Shelf.kinds, id: \.id) { k in Text(k.label).tag(k.id) }
                }
                Button(busy ? "正在生成" : "生成", action: run).disabled(busy)
            } footer: { Text("一次调用生成一批，与聊天无关。") }
            if let got {
                Section("生成了 \(got.count) 本") {
                    if got.isEmpty { Text("没有生成可用的书目").foregroundStyle(Theme.text2) }
                    ForEach(got) { b in
                        Button { if picked.contains(b.id) { picked.remove(b.id) } else { picked.insert(b.id) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.title)
                                    Text([b.author, b.note].filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.text2)
                                }
                                Spacer()
                                if picked.contains(b.id) { SvgIcon(name: "check", size: 16) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    Button("放上书架（\(picked.count) 本）") {
                        Shelf.keep(charId, got.filter { picked.contains($0.id) })
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
        .navigationTitle("生成书目")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }

    private func run() {
        busy = true
        problem = nil
        Task {
            do {
                let r = try await Shelf.generate(charId, count: Int(count), kind: kind)
                got = r
                picked = Set(r.map(\.id))
            } catch { problem = error.localizedDescription }
            busy = false
        }
    }
}

/// 书架上的一本：接上真书或断开、读后感（一本一次调用，草稿看过再存）、拿下来
struct ShelfItemView: View {
    let charId: String
    let entryId: String
    @Environment(\.dismiss) private var dismiss
    @State private var item: Shelf.Item?
    @State private var linking = false
    @State private var draft = ""
    @State private var busy = false
    @State private var dropping = false
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let it = item {
                Section {
                    LabeledContent("书名", value: it.title)
                    if !it.author.isEmpty { LabeledContent("作者", value: it.author) }
                    if !it.note.isEmpty { LabeledContent("备注", value: it.note) }
                }
                Section {
                    if let b = it.book {
                        NavigationLink { BookDetailView(bookId: b.id) } label: { TogetherRow(icon: "book", title: b.title, sub: "读到 \(Books.percent(b))%") }
                        Button("断开") { link(nil) }
                    } else {
                        Text("占位。书库里还没有这一本。").foregroundStyle(Theme.text2)
                    }
                    Button("接上书库里的一本") { linking = true }
                } header: { Text("书库") }
                Section {
                    if !it.impression.isEmpty {
                        let p = MessageActions.transPair(it.impression, it.impressionTrans, mode: SettingsModel.shared.s.raw["translateShow"]?.string ?? "both")
                        Text(p.main)
                        if !p.sub.isEmpty { Text(p.sub).font(.footnote).foregroundStyle(Theme.text3) }
                    }
                    if !draft.isEmpty {
                        Text(draft).foregroundStyle(Theme.text2)
                        Button("保存这一篇") {
                            do { try Shelf.saveImpression(charId, entryId: entryId, draft); draft = ""; load() } catch { problem = error.localizedDescription }
                        }
                    }
                    Button(busy ? "正在写" : (it.impression.isEmpty ? "让角色写读后感" : "重新写")) { write() }.disabled(busy)
                } header: { Text("读后感") } footer: { Text("写一次调用一次接口。") }
                Section { Button("从书架拿下来", role: .destructive) { dropping = true } }
            }
        }
        .navigationTitle(item?.title ?? "书架")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .sheet(isPresented: $linking) {
            NavigationStack {
                List {
                    let books = Books.all()
                    if books.isEmpty { Text("书库是空的").foregroundStyle(Theme.text2) }
                    ForEach(books) { b in
                        Button { linking = false; link(b.id) } label: { BookRow(b: b) }.buttonStyle(.plain)
                    }
                }
                .navigationTitle("接上一本")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { linking = false } } }
            }
            .eiraLook()
        }
        .confirmationDialog("从书架拿下来", isPresented: $dropping, titleVisibility: .visible) {
            Button("拿下来", role: .destructive) {
                do { try Shelf.remove(charId, entryId); dismiss() } catch { problem = error.localizedDescription }
            }
        }
    }

    private func load() { item = Shelf.list(charId).first { $0.id == entryId } }

    private func link(_ bookId: String?) {
        do { try Shelf.link(charId, entryId, bookId: bookId); load() } catch { problem = error.localizedDescription }
    }

    private func write() {
        busy = true
        problem = nil
        Task {
            do { draft = try await Shelf.impression(charId, entryId: entryId) } catch { problem = error.localizedDescription }
            busy = false
        }
    }
}
