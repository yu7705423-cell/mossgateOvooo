import SwiftUI

/// 「联系」：我的身份与全部角色。列表里只显示名字与一句话签名，人设一个字都不露（网页版第 6 条）。
struct ContactsView: View {
    @State private var chars: [Character] = []
    @State private var me: Persona?
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var problem: String?

    enum Route: Hashable {
        case profile(String)
        case edit(String)
        case chat(String)
        case personas
        case cardImport
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
                Section("我") {
                    NavigationLink(value: Route.personas) {
                        row(avatar: me?.avatar ?? "", name: me?.name ?? "我", sub: me?.signature ?? "")
                    }
                }
                ForEach(groups) { g in
                    Section(g.title) {
                        ForEach(g.chars) { c in
                            NavigationLink(value: Route.profile(c.id)) {
                                row(avatar: c.avatar, name: c.displayName, sub: c.signature)
                            }
                        }
                    }
                }
                if chars.isEmpty {
                    Text("暂无角色。点右上角新建，或在「设置 - 存储与备份 - 导入网页版备份」中导入。").foregroundStyle(Theme.secondaryText)
                }
            }
            .searchable(text: $query, prompt: "搜索名字或备注")
            .navigationTitle("联系")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("新建角色", action: create)
                        Button("从资料读取角色卡") { path.append(Route.cardImport) }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建角色")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .profile(let id): CharacterProfileView(charId: id, path: $path)
                case .edit(let id): CharacterEditView(charId: id, path: $path)
                case .chat(let id): ConversationView(chatId: id)
                case .personas: PersonaListView()
                case .cardImport: CardImportView { id in
                    path.removeLast()
                    path.append(Route.profile(id))
                }
                }
            }
            .onAppear(perform: reload)
        }
    }

    struct CharGroup: Identifiable {
        let title: String
        let chars: [Character]
        var id: String { title }
    }

    /// 按分组列；小号不单列（它挂在本人名下），归档的放最后。
    private var groups: [CharGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = chars.filter { ($0.parentId ?? "").isEmpty }
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.remark.localizedCaseInsensitiveContains(q) }
        let active = list.filter { !$0.archived }
        var out: [CharGroup] = []
        let pinned = active.filter(\.pinned)
        if !pinned.isEmpty { out.append(CharGroup(title: "置顶", chars: pinned)) }
        var names: [String] = []
        for c in active where !c.pinned && !names.contains(c.group) { names.append(c.group) }
        for g in names.sorted(by: { a, b in a.isEmpty != b.isEmpty ? !a.isEmpty : a < b }) {
            out.append(CharGroup(title: g.isEmpty ? "未分组" : g, chars: active.filter { !$0.pinned && $0.group == g }))
        }
        let archived = list.filter(\.archived)
        if !archived.isEmpty { out.append(CharGroup(title: "已归档", chars: archived)) }
        return out
    }

    private func row(avatar: String, name: String, sub: String) -> some View {
        HStack(spacing: Theme.pad) {
            Avatar(imageId: avatar, name: name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(1) }
            }
        }
    }

    private func reload() {
        do {
            chars = try Repo.characters().sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
            me = try Repo.activePersona()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func create() {
        do {
            let c = try People.createCharacter()
            reload()
            path.append(Route.edit(c.id))
        } catch {
            problem = "新建失败：\(error.localizedDescription)"
        }
    }
}

/// 角色资料页：头像、名字、签名，以及「发消息」「编辑资料」。人设不在这里出现。
struct CharacterProfileView: View {
    let charId: String
    @Binding var path: NavigationPath
    @State private var char: Character?
    @State private var problem: String?

    var body: some View {
        List {
            if let char {
                Section {
                    VStack(spacing: Theme.gap) {
                        Avatar(imageId: char.avatar, name: char.displayName, size: 88)
                        Text(char.displayName).font(.title3)
                        if !char.remark.isEmpty && char.remark != char.name {
                            Text(char.name).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                        if !char.signature.isEmpty {
                            Text(char.signature).font(.subheadline).foregroundStyle(Theme.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.pad)
                }
                Section {
                    Button(action: openChat) { Label("发消息", systemImage: "bubble.left") }
                    NavigationLink(value: ContactsView.Route.edit(char.id)) { Label("编辑资料", systemImage: "pencil") }
                }
                Section {
                    NavigationLink { MemoryListView(charId: char.id) } label: { Label("记忆", systemImage: "brain") }
                    NavigationLink { CharacterLoreView(charId: char.id) } label: { Label("世界书", systemImage: "books.vertical") }
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle(char?.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func reload() {
        do { char = try Repo.character(charId) } catch { problem = error.localizedDescription }
    }

    private func openChat() {
        do {
            let me = try People.ensureActivePersona()
            let chat = try People.chatFor(charId: charId, personaId: me.id)
            path.append(ContactsView.Route.chat(chat.id))
        } catch {
            problem = "无法打开会话：\(error.localizedDescription)"
        }
    }
}
