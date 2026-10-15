import SwiftUI

/// 消息列表（聊天 app 的「消息」页签）：当前身份名下的会话，置顶的在前，其余按最后一条消息的时间倒排。
/// 导航由外面的 ChatAppView 管：会话 id 推进 path 就打开那一段。
struct ChatListView: View {
    @Binding var path: NavigationPath
    @State private var rows: [Item] = []
    @State private var loadError: String?
    @State private var deleting: Chat?
    @State private var newGroup = false

    struct Item: Identifiable {
        let chat: Chat
        let title: String
        let avatar: String
        let preview: String
        var tag = ""
        var id: String { chat.id }
    }

    var body: some View {
        Group {
            List {
                if let loadError {
                    Text(loadError).foregroundStyle(Theme.danger)
                }
                if rows.isEmpty && loadError == nil {
                    EmptyState(title: "暂无会话", desc: "可在「设置 - 存储与备份 - 导入网页版备份」中导入网页版的数据。")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                // 网页版的消息列表：一整块浅灰胶囊，行与行之间一条发丝线（.msg-list .capsule .msg-row）
                Section {
                    ForEach(rows) { item in
                        NavigationLink(value: item.chat.id) {
                            HStack(spacing: Theme.sp3) {
                                Avatar(imageId: item.avatar, name: item.title, size: Theme.listAvatarSize)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(alignment: .firstTextBaseline, spacing: Theme.sp2) {
                                        Text(item.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                        // 自动回复开着时名字旁一个小字：忙碌、休息、自动回复
                                        if !item.tag.isEmpty {
                                            Text(item.tag).font(.system(size: 10)).foregroundStyle(Theme.text3)
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                                        }
                                        Spacer(minLength: 0)
                                        Text(shortTime(item.chat.lastMessageAt))
                                            .font(.system(size: 11)).foregroundStyle(Theme.text3)
                                    }
                                    HStack(spacing: Theme.sp2) {
                                        Text((item.chat.muted ? "[免打扰] " : "") + item.preview).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if item.chat.unread > 0 {
                                            Text(item.chat.unread > 99 ? "99+" : "\(item.chat.unread)")
                                                .font(.system(size: 11).monospacedDigit())
                                                .padding(.horizontal, 5)
                                                .frame(minWidth: 17, minHeight: 17)
                                                .foregroundStyle(Theme.onAccent)
                                                .background(item.chat.muted ? Theme.text3 : Theme.accent, in: Capsule())
                                                .accessibilityLabel("\(item.chat.unread) 条未读")
                                        }
                                    }
                                }
                            }
                            .frame(minHeight: 62 - 2 * Theme.sp3)
                        }
                        .eiraRow()
                        // 长按（网页版 MessagesTab 的 PopMenu）：置顶、已读未读、免打扰、取下美化、删除
                        .contextMenu {
                            Button { togglePin(item.chat) } label: {
                                Label(item.chat.pinned ? "取消置顶" : "置顶", systemImage: item.chat.pinned ? "pin.slash" : "pin")
                            }
                            Button { patch(item.chat, ["unread": .number(item.chat.unread > 0 ? 0 : 1)]) } label: {
                                Label(item.chat.unread > 0 ? "标为已读" : "标为未读", systemImage: item.chat.unread > 0 ? "envelope.open" : "envelope.badge")
                            }
                            Button { patch(item.chat, ["muted": .bool(!item.chat.muted)]) } label: {
                                Label(item.chat.muted ? "取消免打扰" : "免打扰", systemImage: item.chat.muted ? "bell" : "bell.slash")
                            }
                            if !item.chat.row.string("skinId").isEmpty {
                                Button { patch(item.chat, ["skinId": .string("")]) } label: { Label("取下美化", systemImage: "paintbrush") }
                            }
                            Button(role: .destructive) { deleting = item.chat } label: { Label("删除", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { patch(item.chat, ["unread": .number(item.chat.unread > 0 ? 0 : 1)]) } label: {
                                Label(item.chat.unread > 0 ? "标为已读" : "标为未读", systemImage: item.chat.unread > 0 ? "envelope.open" : "envelope.badge")
                            }
                            .tint(Theme.accent)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = item.chat } label: { Label("删除", systemImage: "trash") }
                            Button { togglePin(item.chat) } label: {
                                Label(item.chat.pinned ? "取消置顶" : "置顶", systemImage: item.chat.pinned ? "pin.slash" : "pin")
                            }
                            .tint(Theme.text3)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { path.append(ChatAppView.ChatRoute.search) } label: { NavIcon("search") }.accessibilityLabel("搜索聊天记录")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { newGroup = true } label: { SvgIcon(name: "users", size: 20, color: Theme.text) }.accessibilityLabel("发起群聊")
                }
            }
            .sheet(isPresented: $newGroup) {
                NavigationStack { NewGroupView { id in reload(); path.append(id) } }
            }
            .onAppear(perform: reload)
            .refreshable { reload() }
            .onReceive(NotificationCenter.default.publisher(for: .eiraChatChanged)) { _ in reload() }
            .confirmationDialog("删除这段会话及其全部消息，角色的记忆保留。无法恢复。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { chat in
                Button("删除", role: .destructive) {
                    do { try People.deleteChat(chat.id); reload() } catch { loadError = "删除失败：\(error.localizedDescription)" }
                }
            }
        }
    }

    private func reload() {
        do {
            let s = AppSettings.load()
            let active = s.raw["activePersonaId"]?.string ?? ""
            var chats = try Repo.chats()
            // 只列当前身份的会话；一条都对不上（比如老数据没有 personaId）就全列
            let mine = chats.filter { $0.personaId == active }
            if !active.isEmpty && !mine.isEmpty { chats = mine }
            let chars = Dictionary(try Repo.characters().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            rows = try chats.map { chat in
                let first = chat.characterIds.first.flatMap { chars[$0] }
                let title = chat.isGroup
                    ? (chat.title.isEmpty ? chat.characterIds.compactMap { chars[$0]?.displayName }.joined(separator: "、") : chat.title)
                    : (first?.displayName ?? "已删除的角色")
                let last = try Repo.messages(chatId: chat.id, limit: 1).last
                // 群里的预览带上是谁说的（网页版 Row 的 who）
                var preview = last.map(previewText) ?? ""
                if chat.isGroup, let last, last.role == .char, !last.isRecalled, let who = chars[last.authorId] {
                    preview = "\(GroupChat.nameIn(chat, who))：\(preview)"
                } else if chat.isGroup, let last, last.role == .user, last.kind != "notice" {
                    preview = "我：\(preview)"
                }
                return Item(chat: chat, title: title,
                            avatar: chat.isGroup ? chat.avatar : first.map { ChatFaces.of(chat, key: $0.id, fallback: $0.avatar) } ?? "",
                            preview: preview,
                            tag: AutoReply.listTag(chat))
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func patch(_ chat: Chat, _ fields: [String: JSONValue]) {
        var row = chat.row
        for (k, v) in fields { row[k] = v }
        row.touch()
        do {
            try Database.shared.put(Collections.chats, row)
            NotificationCenter.default.post(name: .eiraChatChanged, object: chat.id)
            if fields["skinId"] != nil { NotificationCenter.default.post(name: .eiraSkinChanged, object: chat.id) }
            reload()
        } catch { loadError = "未能保存：\(error.localizedDescription)" }
    }

    private func togglePin(_ chat: Chat) {
        var row = chat.row
        row["pinned"] = .bool(!chat.pinned)
        row.touch()
        do { try Database.shared.put(Collections.chats, row); reload() }
        catch { loadError = "置顶失败：\(error.localizedDescription)" }
    }

    private func previewText(_ m: Message) -> String { MsgPreview.text(m) }
}

/// 列表上的时间：今天显示时分，今年显示月日，更早显示年月日。
func shortTime(_ millis: Double) -> String {
    guard millis > 0 else { return "" }
    let d = Date(millis: millis)
    let cal = Calendar.current
    if cal.isDateInToday(d) { return ShortTime.hm.string(from: d) }
    if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return ShortTime.md.string(from: d) }
    return ShortTime.ymd.string(from: d)
}

/// 列表每一行都要算，格式化器各建一个就够
private enum ShortTime {
    static func make(_ fmt: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = fmt
        return f
    }
    static let hm = make("HH:mm"), md = make("M月d日"), ymd = make("yyyy年M月d日")
}
