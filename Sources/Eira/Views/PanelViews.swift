import SwiftUI

/// 整理加号面板（网页版 PanelPage）：上下挪顺序，放在面板上还是收进「更多」
struct PanelEditView: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        let order = Panel.order(model.s)
        let more = Panel.more(model.s)
        List {
            Section {
                ForEach(order.indices, id: \.self) { i in
                    let id = order[i]
                    if let it = Panel.item(id) {
                        HStack(spacing: Theme.sp3) {
                            SvgIcon(name: it.icon, size: 18, color: Theme.text)
                            Text(it.label)
                            Spacer()
                            Button { model.update { Panel.move(&$0, id, -1) } } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless).disabled(i == 0).accessibilityLabel("上移")
                            Button { model.update { Panel.move(&$0, id, 1) } } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless).disabled(i == order.count - 1).accessibilityLabel("下移")
                        }
                        Toggle("收进「更多」", isOn: Binding(get: { more.contains(id) }, set: { v in model.update { Panel.setMore(&$0, id, v) } }))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text2)
                    }
                }
                HelpNote("加号面板里的格子按这里的顺序排列。收进「更多」的格子要先点「更多」才出现。群聊里只出现说得通的几格（图片、语音、骰子、分享音乐、线下）。", title: "整理面板")
            }
            Section {
                Button("恢复默认") { model.update { Panel.reset(&$0) } }
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("整理面板")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 加号面板里的「世界书」（网页版 LoreSheet 的世界书那一半）：这个角色用不用某本书，展开逐条开关。
/// 和「设定集 - 世界书」改的是同一份；全局生效的书在这里关掉，对所有角色停用
struct LoreQuickView: View {
    let charId: String
    @State private var char: Character?
    @State private var books: [Lorebook] = []
    @State private var open: Set<String> = []
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                ForEach(books, id: \.id) { b in
                    let on = b.global || (char?.lorebookIds.contains(b.id) ?? false)
                    Toggle(isOn: Binding(get: { on }, set: { flip(b, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.name.isEmpty ? "未命名" : b.name)
                            Text("\(b.entries.count) 个条目\(b.global ? " · 全局生效" : "")").font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                    if !b.entries.isEmpty {
                        Button(open.contains(b.id) ? "收起条目" : "展开条目") {
                            if open.contains(b.id) { open.remove(b.id) } else { open.insert(b.id) }
                        }
                        .font(.footnote)
                    }
                    if open.contains(b.id) {
                        ForEach(b.entries, id: \.id) { e in
                            Toggle(isOn: Binding(get: { e.enabled }, set: { setEntry(b, e, $0) })) {
                                Text(e.comment.isEmpty ? String(e.content.prefix(16)) : e.comment).font(.system(size: 14))
                            }
                            .padding(.leading, Theme.sp4)
                        }
                    }
                }
                if books.isEmpty { Text("还没有对话用途的世界书。在「设定集 - 世界书」中新建或导入。").foregroundStyle(Theme.text2) }
                HelpNote("开关表示该角色是否使用这本世界书。全局生效的书对所有角色生效，在此关闭后对所有角色停用。展开可以逐条开关。与「设定集 - 世界书」里的是同一份。", title: "会话里的世界书")
            } header: { Text(char.map { "「\($0.name)」用的世界书" } ?? "世界书") }
            ProblemSection(text: problem)
        }
        .navigationTitle("世界书")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func reload() {
        char = (try? Repo.character(charId)) ?? nil
        books = ((try? Repo.lorebooks()) ?? []).filter { $0.purpose == "chat" }
    }

    private func flip(_ b: Lorebook, _ on: Bool) {
        do {
            if b.global { _ = try Knowledge.updateBook(b.id, ["global": .bool(on)]) }
            else { try Knowledge.setAttached(on, bookId: b.id, charId: charId) }
            reload()
        } catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    private func setEntry(_ b: Lorebook, _ e: LoreEntry, _ on: Bool) {
        do { try Knowledge.updateEntry(bookId: b.id, entryId: e.id, ["enabled": .bool(on)]); reload() }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}
