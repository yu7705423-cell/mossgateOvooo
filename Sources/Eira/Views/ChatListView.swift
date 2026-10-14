import SwiftUI

/// 消息列表：当前身份名下的会话，置顶的在前，其余按最后一条消息的时间倒排。
struct ChatListView: View {
    @State private var rows: [Item] = []
    @State private var loadError: String?
    @State private var deleting: Chat?
    @State private var newGroup = false
    @State private var path: [String] = []

    struct Item: Identifiable {
        let chat: Chat
        let title: String
        let avatar: String
        let preview: String
        var id: String { chat.id }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let loadError {
                    Text(loadError).foregroundStyle(Theme.danger)
                }
                if rows.isEmpty && loadError == nil {
                    Text("暂无会话。可在「设置 - 导入网页版备份」中导入网页版的数据。")
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(rows) { item in
                    NavigationLink(value: item.chat.id) {
                        HStack(spacing: Theme.pad) {
                            Avatar(imageId: item.avatar, name: item.title, size: Theme.listAvatarSize)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.title).font(.body).lineLimit(1)
                                    Spacer()
                                    Text(shortTime(item.chat.lastMessageAt))
                                        .font(.caption).foregroundStyle(Theme.tertiaryText)
                                }
                                Text(item.preview).font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleting = item.chat } label: { Label("删除", systemImage: "trash") }
                        Button { togglePin(item.chat) } label: {
                            Label(item.chat.pinned ? "取消置顶" : "置顶", systemImage: item.chat.pinned ? "pin.slash" : "pin")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("消息")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newGroup = true } label: { Image(systemName: "person.3") }.accessibilityLabel("新建群聊")
                }
            }
            .sheet(isPresented: $newGroup) {
                NavigationStack { NewGroupView { id in reload(); path.append(id) } }
            }
            .navigationDestination(for: String.self) { id in
                ConversationView(chatId: id)
            }
            .onAppear(perform: reload)
            .refreshable { reload() }
            .confirmationDialog("删除这段会话及其全部消息，无法恢复。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
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
                return Item(chat: chat, title: title,
                            avatar: chat.isGroup ? chat.avatar : (first?.avatar ?? ""),
                            preview: last.map(previewText) ?? "")
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func togglePin(_ chat: Chat) {
        var row = chat.row
        row["pinned"] = .bool(!chat.pinned)
        row.touch()
        do { try Database.shared.put(Collections.chats, row); reload() }
        catch { loadError = "置顶失败：\(error.localizedDescription)" }
    }

    private func previewText(_ m: Message) -> String {
        if m.isRecalled { return "撤回了一条消息" }
        if m.isError { return "回复失败" }
        return m.content
    }
}

/// 列表上的时间：今天显示时分，今年显示月日，更早显示年月日。
func shortTime(_ millis: Double) -> String {
    guard millis > 0 else { return "" }
    let d = Date(millis: millis)
    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    if cal.isDateInToday(d) { f.dateFormat = "HH:mm" }
    else if cal.isDate(d, equalTo: Date(), toGranularity: .year) { f.dateFormat = "M月d日" }
    else { f.dateFormat = "yyyy年M月d日" }
    return f.string(from: d)
}
