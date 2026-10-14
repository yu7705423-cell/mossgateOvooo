import PhotosUI
import SwiftUI

/// 聊天 app（网页版 apps/chat/App.js）：底下四个页签，消息、联系人、朋友圈、主页。
/// 一条导航栈：会话 id（String）打开会话，ChatRoute 打开主页、动态、编辑资料。
struct ChatAppView: View {
    @ObservedObject private var notifier = Notifier.shared
    @State private var path = NavigationPath()
    @State private var unread = Shell.chatUnread()
    @AppStorage("eira.chat.tab") private var tab = "messages"

    enum ChatRoute: Hashable {
        case profile(String)
        case moment(String)
        case editChar(String)
        case editPersona(String)
        /// 在当前身份的全部会话里搜
        case search
        /// 打开会话并跳到那一条
        case focus(chatId: String, messageId: String)
    }

    struct TabItem: Identifiable { var id: String; var label: String; var icon: String }
    static let tabs: [TabItem] = [
        TabItem(id: "messages", label: "消息", icon: "message"), TabItem(id: "contacts", label: "联系人", icon: "users"),
        TabItem(id: "moments", label: "朋友圈", icon: "moments"), TabItem(id: "me", label: "主页", icon: "user"),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(Self.tabs.first { $0.id == tab }?.label ?? "消息")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
                .navigationDestination(for: String.self) { id in ConversationView(chatId: id) }
                .navigationDestination(for: ChatRoute.self) { r in
                    switch r {
                    case .profile(let id): ProfileView(subjectId: id, path: $path)
                    case .moment(let id): MomentDetailView(momentId: id, path: $path)
                    case .editChar(let id): CharacterEditView(charId: id, path: $path)
                    case .editPersona(let id): PersonaEditView(personaId: id)
                    case .search:
                        SearchChatView(chatId: nil) { c, m in path.append(ChatRoute.focus(chatId: c, messageId: m)) }
                    case .focus(let c, let m): ConversationView(chatId: c, focusId: m)
                    }
                }
        }
        .onAppear {
            // 从主屏的会话或通知打开时，聊天 app 刚出现，那一段还挂在这里
            if let id = notifier.openChat { notifier.openChat = nil; open(id) }
        }
        .onChange(of: notifier.openChat) { _, id in
            guard let id else { return }
            notifier.openChat = nil
            open(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .eiraChatChanged)) { _ in unread = Shell.chatUnread() }
    }

    private func open(_ chatId: String) {
        tab = "messages"
        path = NavigationPath([chatId])
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case "contacts": ChatContactsTab(path: $path)
        case "moments": MomentsTab(path: $path)
        case "me": ProfileView(subjectId: "me", path: $path, embedded: true)
        default: ChatListView(path: $path)
        }
    }

    /// 页签栏（.tabbar）：线条图标加一行小字，选中的用文字色，其余用三级灰
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs) { t in
                Button { tab = t.id } label: {
                    VStack(spacing: 3) {
                        SvgIcon(name: t.icon, size: 22, color: tab == t.id ? Theme.accent : Theme.text3)
                            .overlay(alignment: .topTrailing) {
                                if t.id == "messages" && unread > 0 {
                                    Text(unread > 99 ? "99+" : "\(unread)")
                                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.onAccent)
                                        .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                                        .background(Theme.accent, in: Capsule())
                                        .offset(x: 8, y: -4)
                                }
                            }
                        Text(t.label).font(.system(size: 11)).foregroundStyle(tab == t.id ? Theme.accent : Theme.text3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.label)
                .accessibilityAddTraits(tab == t.id ? .isSelected : [])
            }
        }
        .background(Theme.bg)
    }
}

// MARK: - 联系人页签（网页版 ContactsTab）

/// 按分组归拢，未分组排最后；NPC 单独一栏。封存的不列。点一位进它的主页。
struct ChatContactsTab: View {
    @Binding var path: NavigationPath
    @State private var chars: [Character] = []
    @State private var query = ""
    @State private var problem: String?

    struct CharGroup: Identifiable { var id: String; var chars: [Character] }

    private var groups: [CharGroup] {
        let key = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = key.isEmpty ? chars : chars.filter { c in
            [c.name, c.remark, c.signature, c.group].contains { $0.lowercased().contains(key) }
        }
        let byName: (Character, Character) -> Bool = { a, b in
            let pa = a.row.bool("pinned"), pb = b.row.bool("pinned")
            if pa != pb { return pa }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
        var map: [String: [Character]] = [:]
        for c in matched where !c.row.bool("isNpc") {
            let g = c.group.trimmingCharacters(in: .whitespaces)
            map[g.isEmpty ? "未分组" : g, default: []].append(c)
        }
        let names = map.keys.sorted { a, b in
            if a == "未分组" { return false }
            if b == "未分组" { return true }
            return a.localizedCompare(b) == .orderedAscending
        }
        var out = names.map { CharGroup(id: $0, chars: map[$0]!.sorted(by: byName)) }
        let npcs = matched.filter { $0.row.bool("isNpc") }.sorted(by: byName)
        if !npcs.isEmpty { out.append(CharGroup(id: "NPC", chars: npcs)) }
        return out
    }

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if chars.isEmpty {
                EmptyState(title: "暂无角色卡", desc: "角色卡是整套系统的核心数据。聊天、朋友圈与主页共用同一份。")
                    .listRowBackground(Color.clear)
            } else {
                // 搜索框（.search-bar）：浅灰胶囊
                HStack(spacing: Theme.sp2) {
                    SvgIcon(name: "search", size: 16, color: Theme.text3)
                    TextField("搜索姓名、签名或分组", text: $query).font(.system(size: 14))
                    if !query.isEmpty {
                        Button { query = "" } label: { SvgIcon(name: "close", size: 15, color: Theme.text3) }
                            .buttonStyle(.plain).accessibilityLabel("清空")
                    }
                }
                .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp2)
                .background(Theme.groupFill, in: Capsule())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: Theme.sp2, leading: Theme.sp4, bottom: Theme.sp2, trailing: Theme.sp4))
                .listRowSeparator(.hidden)
                if groups.isEmpty {
                    EmptyState(title: "无匹配的角色").listRowBackground(Color.clear)
                }
                ForEach(groups) { g in
                    Section {
                        ForEach(g.chars) { c in
                            NavigationLink(value: ChatAppView.ChatRoute.profile(c.id)) { row(c) }
                                .eiraRow()
                                .contextMenu {
                                    Button(c.row.bool("pinned") ? "取消置顶" : "在分组内置顶") { togglePin(c) }
                                    Button("编辑资料") { path.append(ChatAppView.ChatRoute.editChar(c.id)) }
                                }
                        }
                    } header: { GroupTitle("\(g.id) · \(g.chars.count)") }
                }
            }
            Section {
                Button("新建角色卡", action: create)
                    .buttonStyle(EiraButtonStyle(kind: .ghost, full: true))
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rBtn, style: .continuous))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: Theme.sp4, bottom: 0, trailing: Theme.sp4))
            }
        }
        .listStyle(.insetGrouped)
        .onAppear(perform: reload)
    }

    private func row(_ c: Character) -> some View {
        HStack(spacing: Theme.sp3) {
            Avatar(imageId: c.avatar, name: c.displayName, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.displayName).font(.system(size: 15, weight: .medium)).lineLimit(1)
                if !c.signature.isEmpty { Text(c.signature).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1) }
            }
        }
        .frame(minHeight: 38)
    }

    private func reload() {
        do {
            chars = try Repo.characters().filter { !$0.archived }
            problem = nil
        } catch { problem = "读取失败：\(error.localizedDescription)" }
    }

    private func togglePin(_ c: Character) {
        var row = c.row
        row["pinned"] = .bool(!c.row.bool("pinned"))
        row.touch()
        do { try Database.shared.put(Collections.characters, row); reload() }
        catch { problem = "置顶失败：\(error.localizedDescription)" }
    }

    private func create() {
        do {
            let c = try People.createCharacter()
            reload()
            path.append(ChatAppView.ChatRoute.editChar(c.id))
        } catch { problem = "新建失败：\(error.localizedDescription)" }
    }
}
