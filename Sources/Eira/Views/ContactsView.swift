import SwiftUI

/// 「联系」：我的身份与全部角色。列表里只显示名字与一句话签名，人设一个字都不露（网页版第 6 条）。
struct ContactsView: View {
    @State private var chars: [Character] = []
    @State private var me: Persona?
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var problem: String?
    @State private var hero = true

    enum Route: Hashable {
        case profile(String)
        case edit(String)
        case chat(String)
        case personas
        case cardImport
        case archived
        case packImport
        case alts
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                HeroHeader(eyebrow: "CONTACTS", title: "联系", shown: $hero)
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
                Section {
                    NavigationLink(value: Route.personas) {
                        row(avatar: me?.avatar ?? "", name: me?.name ?? "我", sub: me?.signature ?? "")
                    }
                    .eiraRow()
                } header: { GroupTitle("我") }
                ForEach(groups) { g in
                    Section {
                        ForEach(g.chars) { c in
                            NavigationLink(value: Route.profile(c.id)) {
                                row(avatar: c.avatar, name: c.displayName, sub: c.signature)
                            }
                            .eiraRow()
                        }
                    } header: { GroupTitle(g.title) }
                }
                // NPC 由关系网生成，数量容易压过正主，单独一栏排在后面，不参与分组（网页版 contact/App.js）
                if !npcs.isEmpty {
                    Section {
                        ForEach(npcs) { c in
                            NavigationLink(value: Route.profile(c.id)) {
                                row(avatar: c.avatar, name: c.displayName, sub: c.signature)
                            }
                            .eiraRow()
                            .contextMenu { Button("转为普通角色") { unNpc(c) } }
                        }
                    } header: { GroupTitle("NPC · \(npcs.count)") } footer: {
                        HelpNote("NPC 由关系网生成，单独列出，不参与分组。长按可将其转为普通角色。转出后与其他角色同列，可加入分组；关系网中的关联不受影响。", title: "NPC")
                    }
                }
                // 角色开设的小号（4.305）：可以选择多个一并删除
                if altCount > 0 {
                    Section {
                        NavigationLink(value: Route.alts) {
                            HStack(spacing: Theme.sp3) {
                                SvgIcon(name: "users", size: 19, color: Theme.text2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("整理小号")
                                    Text("角色开设的小号共 \(altCount) 个。可以选择多个一并删除，连同会话与记忆。").font(.system(size: 12)).foregroundStyle(Theme.text3)
                                }
                            }
                        }
                        .eiraRow()
                    }
                }
                // 封存的角色不在列表里，收进「已封存」一行（网页版 4.557）
                if archivedCount > 0 {
                    Section {
                        NavigationLink(value: Route.archived) {
                            HStack(spacing: Theme.sp3) {
                                SvgIcon(name: "lock", size: 19, color: Theme.text2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("已封存")
                                    Text("共 \(archivedCount) 个角色").font(.system(size: 12)).foregroundStyle(Theme.text3)
                                }
                            }
                        }
                        .eiraRow()
                    }
                }
                if chars.isEmpty {
                    EmptyState(title: "暂无角色", desc: "点右上角新建，或在「设置 - 存储与备份 - 导入网页版备份」中导入。")
                        .listRowBackground(Color.clear)
                }
            }
            .searchable(text: $query, prompt: "搜索名字或备注")
            .heroTitle("联系", heroShown: hero)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("新建角色", action: create)
                        Button("从资料读取角色卡") { path.append(Route.cardImport) }
                        Button("导入角色包") { path.append(Route.packImport) }
                    } label: { NavIcon("plus") }
                    .accessibilityLabel("新建角色")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .profile(let id): CharacterProfileView(charId: id, path: $path)
                case .edit(let id): CharacterEditView(charId: id, path: $path)
                case .chat(let id): ConversationView(chatId: id)
                case .personas: PersonaListView()
                case .archived: ArchivedCharsView()
                case .alts: AltsPageView()
                case .packImport: CharPackImportView { id in
                    path.removeLast()
                    path.append(Route.profile(id))
                }
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

    private var archivedCount: Int { chars.filter { ($0.parentId ?? "").isEmpty && $0.archived }.count }
    private var altCount: Int { chars.filter { !($0.parentId ?? "").isEmpty }.count }
    private var npcs: [Character] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return chars.filter { ($0.parentId ?? "").isEmpty && !$0.archived && $0.isNpc }
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.remark.localizedCaseInsensitiveContains(q) }
    }

    private func unNpc(_ c: Character) {
        do { _ = try People.update(c, ["isNpc": .bool(false)]); reload() }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    /// 按分组列；小号不单列（它挂在本人名下），封存的不列（收在「已封存」里）。
    private var groups: [CharGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = chars.filter { ($0.parentId ?? "").isEmpty }
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.remark.localizedCaseInsensitiveContains(q) }
        let active = list.filter { !$0.archived && !$0.isNpc }
        var out: [CharGroup] = []
        let pinned = active.filter(\.pinned)
        if !pinned.isEmpty { out.append(CharGroup(title: "置顶", chars: pinned)) }
        var names: [String] = []
        for c in active where !c.pinned && !names.contains(c.group) { names.append(c.group) }
        for g in names.sorted(by: { a, b in a.isEmpty != b.isEmpty ? !a.isEmpty : a < b }) {
            out.append(CharGroup(title: g.isEmpty ? "未分组" : g, chars: active.filter { !$0.pinned && $0.group == g }))
        }
        return out
    }

    private func row(avatar: String, name: String, sub: String) -> some View {
        HStack(spacing: Theme.pad) {
            Avatar(imageId: avatar, name: name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1) }
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

/// 已封存的角色（网页版 contact/App.js 的 ArchivedPage，4.557）。点进去是编辑资料，解除封存的开关在那一页
struct ArchivedCharsView: View {
    @State private var list: [Character] = []
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            ForEach(list) { c in
                NavigationLink(value: ContactsView.Route.edit(c.id)) {
                    HStack(spacing: Theme.pad) {
                        Avatar(imageId: c.avatar, name: c.displayName, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.displayName).font(.system(size: 15, weight: .medium)).lineLimit(1)
                            Text("封存于 \(Self.day(c.row.number("archived") ?? 0))").font(.system(size: 12)).foregroundStyle(Theme.text3)
                        }
                    }
                }
                .eiraRow()
            }
            if list.isEmpty && problem == nil {
                EmptyState(title: "没有已封存的角色", desc: "")
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("已封存")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    /// 网页版 toLocaleDateString('zh-CN')：2026/10/16
    static func day(_ millis: Double) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(millis: millis))
        return "\(c.year ?? 0)/\(c.month ?? 0)/\(c.day ?? 0)"
    }

    private func reload() {
        do {
            list = try Repo.characters().filter { ($0.parentId ?? "").isEmpty && $0.archived }
                .sorted { ($0.row.number("archived") ?? 0) > ($1.row.number("archived") ?? 0) }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// 角色资料页：头像、名字、签名、年龄性别生日，以及「发消息」「编辑资料」、关系网、印象、近况、关系与小号（网页版 ProfilePage）。
/// 人设不在这里出现。
struct CharacterProfileView: View {
    let charId: String
    @Binding var path: NavigationPath
    @State private var char: Character?
    @State private var problem: String?
    @State private var groups: [Relations.Group] = []
    @State private var rels: [Relations.Rel] = []
    @State private var alts: [Character] = []
    @State private var parent: Character?
    @State private var impLine = ""
    @State private var impFresh = 0
    @State private var nowLine = ""
    @State private var meId = ""
    @State private var tieOf: TieTarget?

    struct TieTarget: Identifiable { let id: String }

    var body: some View {
        List {
            if let char {
                Section {
                    VStack(spacing: Theme.gap) {
                        Avatar(imageId: char.avatar, name: char.displayName, size: 88)
                        Text(char.displayName).font(Theme.serif(24))
                        if !char.remark.isEmpty && char.remark != char.name {
                            Text(char.name).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                        if !char.signature.isEmpty {
                            Text(char.signature).font(.subheadline).foregroundStyle(Theme.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                        let facts = [("年龄", char.row.string("age")), ("性别", char.row.string("gender")), ("生日", char.row.string("birthday"))]
                            .filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
                        if !facts.isEmpty {
                            HStack(spacing: Theme.sp5) {
                                ForEach(facts.indices, id: \.self) { i in
                                    VStack(spacing: 2) {
                                        Text(facts[i].1).font(.system(size: 15, weight: .semibold))
                                        Text(facts[i].0).font(.system(size: 11)).foregroundStyle(Theme.text3)
                                    }
                                }
                            }
                            .padding(.top, Theme.sp1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.pad)
                    .listRowBackground(Color.clear)
                }
                // 新版按钮：发消息是描边主按钮，编辑资料是文字次按钮
                Section {
                    HStack(spacing: Theme.sp2) {
                        Button("发消息", action: openChat).buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                        NavigationLink(value: ContactsView.Route.edit(char.id)) {
                            Text("编辑资料").frame(maxWidth: .infinity, minHeight: 44)
                                .font(.system(size: 15, weight: .medium))
                                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rBtn, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: Theme.sp4, bottom: 0, trailing: Theme.sp4))
                }
                if char.persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parent == nil {
                    Section {} footer: { Text("尚未填写人设。可在「编辑资料」中填写，或导入 txt / docx 文件。") }
                }
                Section {
                    NavigationLink { ImpressPageView(charId: char.id) } label: {
                        HStack {
                            IconRow(title: "\(char.row.string("name"))眼中的你", icon: "eye", value: impLine)
                            if impFresh > 0 { Text("\(impFresh) 条新").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2) }
                        }
                    }
                    NavigationLink { NowPageView(charId: char.id) } label: {
                        IconRow(title: "近况", icon: "clock", value: nowLine.isEmpty ? "日程、身体状态、在听的歌、朋友圈与日记" : nowLine)
                    }
                    NavigationLink { NetPageView(charId: char.id, path: $path) } label: { IconRow(title: "关系网", icon: "users") }
                    NavigationLink { MemoryListView(charId: char.id) } label: { IconRow(title: "记忆", icon: "brain") }
                    NavigationLink { CharacterLoreView(charId: char.id) } label: { IconRow(title: "世界书", icon: "book") }
                }
                // 关系按圈子分段（4.593）：没分过圈子时一段
                if groups.count <= 1 && (groups.first?.circle.isEmpty ?? true) {
                    Section {
                        ForEach(rels) { relRow($0) }
                        addRelRow
                    } header: { GroupTitle("关系 · \(rels.count)") }
                } else {
                    ForEach(groups) { g in
                        Section { ForEach(g.items) { relRow($0) } } header: { GroupTitle("\(g.circle.isEmpty ? "未分圈子" : g.circle) · \(g.items.count)") }
                    }
                    Section { addRelRow }
                }
                if !rels.isEmpty {
                    Section {
                        ForEach(rels) { r in
                            Button { tieOf = TieTarget(id: r.charId) } label: {
                                IconRow(title: Self.name(r.charId), icon: "lock", value: tieText(char.id, r.charId))
                            }
                            .buttonStyle(.plain)
                        }
                    } header: { GroupTitle("好友与拉黑") }
                }
                if let parent {
                    Section {} footer: {
                        Text("这是「\(parent.row.string("name"))」自己开的小号。\(char.row.string("altReason").isEmpty ? "" : "该角色给出的理由：\(char.row.string("altReason"))。")\(char.row.bool("altDisclosed") ? "该角色已承认这是自己的小号。" : "该角色尚未承认这是自己的小号。")")
                    }
                }
                if !alts.isEmpty {
                    Section {
                        ForEach(alts) { a in
                            NavigationLink(value: ContactsView.Route.profile(a.id)) {
                                IconRow(title: a.row.string("name"), icon: "user", value: a.row.string("altReason"))
                            }
                        }
                    } header: { GroupTitle("该角色的小号 · \(alts.count)") }
                }
                Section {
                    if char.isNpc {
                        Button { unNpc() } label: { IconRow(title: "转为普通角色", icon: "user") }
                    }
                    NavigationLink { CharPackExportView(charId: char.id) } label: { IconRow(title: "导出这个角色", icon: "download") }
                } footer: {
                    HelpNote("把这个角色和挂在它名下的会话、记忆、图片等打成一个角色包，网页版与本应用都能导入。", title: "导出这个角色")
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle(char?.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(item: $tieOf, onDismiss: reload) { t in
            NavigationStack { TieSheet(charId: charId, otherId: t.id, personaId: meId) }
        }
    }

    static func name(_ id: String) -> String {
        let n = (try? Repo.character(id))?.row.string("name") ?? ""
        return n.isEmpty ? "已删除" : n
    }

    /// 这一对之间的好友与拉黑，两个方向各一句（4.306）
    private func tieText(_ a: String, _ b: String) -> String {
        func one(_ x: String, _ y: String) -> String {
            let st = Ties.state(x, y, meId)
            return st.blocked ? "\(Self.name(x)) 已拉黑 \(Self.name(y))" : st.removed ? "\(Self.name(x)) 已删除 \(Self.name(y))" : ""
        }
        let t = [one(a, b), one(b, a)].filter { !$0.isEmpty }.joined(separator: " · ")
        return t.isEmpty ? "互为好友" : t
    }

    private func relRow(_ r: Relations.Rel) -> some View {
        NavigationLink(value: ContactsView.Route.profile(r.charId)) {
            IconRow(title: Self.name(r.charId), icon: "user", value: r.label)
        }
    }

    private var addRelRow: some View {
        NavigationLink { NpcPageView(charId: charId) } label: { IconRow(title: "关联角色", icon: "plus") }
    }

    private func reload() {
        do {
            char = try Repo.character(charId)
            guard let c = char else { problem = "该角色已被删除"; return }
            rels = Relations.of(charId)
            groups = Relations.grouped(charId)
            alts = try Repo.characters().filter { $0.parentId == charId }
            parent = try c.parentId.flatMap { try $0.isEmpty ? nil : Repo.character($0) }
            let me = try Repo.activePersona()
            meId = me?.id ?? ""
            let n = Impress.list(charId, meId).count
            let notes = Impress.notes(charId, meId).count
            impFresh = Impress.newCount(charId, meId)
            impLine = [n > 0 ? "\(n) 条印象" : "尚无印象", notes > 0 ? "\(notes) 条依据待整理" : "",
                       Impress.draft(charId, meId) != nil ? "整理结果待确认" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            nowLine = CharNow.line(CharNow.snapshot(charId, personaId: meId))
        } catch { problem = error.localizedDescription }
    }

    private func unNpc() {
        guard let c = char else { return }
        do { char = try People.update(c, ["isNpc": .bool(false)]) } catch { problem = "保存失败：\(error.localizedDescription)" }
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

/// 改这个角色对另一个角色的好友与拉黑（只改这一方）
private struct TieSheet: View {
    let charId: String
    let otherId: String
    let personaId: String
    @State private var blocked = false
    @State private var removed = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Toggle("拉黑", isOn: Binding(get: { blocked }, set: { v in set(blocked: v) }))
                Toggle("从联系人中删除", isOn: Binding(get: { removed }, set: { v in set(removed: v) }))
            } footer: {
                Text("这里改的是「\(CharacterProfileView.name(charId))」这一方的状态。拉黑后对方发来的消息会被拒收；删除后对方发来的消息无法送达，该角色也无法给对方发消息。角色也可以在对话中自己拉黑或删除。对方那一方的状态在对方的资料页中修改。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("\(CharacterProfileView.name(charId)) 对 \(CharacterProfileView.name(otherId))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .onAppear {
            let st = Ties.state(charId, otherId, personaId)
            blocked = st.blocked; removed = st.removed
        }
    }

    private func set(blocked b: Bool? = nil, removed r: Bool? = nil) {
        do {
            try Ties.set(charId, otherId, personaId, blocked: b, removed: r)
            let st = Ties.state(charId, otherId, personaId)
            blocked = st.blocked; removed = st.removed
            problem = nil
        } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}
