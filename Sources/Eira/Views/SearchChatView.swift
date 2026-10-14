import SwiftUI

/// 搜索聊天记录（网页版 SearchPage）：一段会话里搜，或者在当前身份的全部会话里搜。正文与译文都算；
/// 点一条回到那段会话，跳到那一条并闪一下。只在本机找，不调接口。
struct SearchChatView: View {
    /// nil 为全部会话
    let chatId: String?
    var onPick: (_ chatId: String, _ messageId: String) -> Void

    @State private var query = ""
    @State private var hits: [Hit] = []
    @State private var searched = false
    @State private var names: [String: String] = [:]
    @FocusState private var focused: Bool

    struct Hit: Identifiable {
        var id: String { message.id }
        var message: Message
        var chatTitle: String
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: Theme.sp2) {
                    SvgIcon(name: "search", size: 16, color: Theme.text3)
                    TextField(chatId == nil ? "搜索全部会话" : "搜索这段会话", text: $query)
                        .font(.system(size: 15))
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit(run)
                    if !query.isEmpty {
                        Button { query = ""; hits = []; searched = false } label: { SvgIcon(name: "close", size: 15, color: Theme.text3) }
                            .buttonStyle(.plain).accessibilityLabel("清空")
                    }
                }
                .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp2)
                .background(Theme.groupFill, in: Capsule())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: Theme.sp2, leading: Theme.sp4, bottom: Theme.sp2, trailing: Theme.sp4))
                .listRowSeparator(.hidden)
            }
            if searched && hits.isEmpty {
                EmptyState(title: "没有找到", desc: "换一个词试试。正文与译文都会搜到。").listRowBackground(Color.clear)
            }
            if !hits.isEmpty {
                Section {
                    ForEach(hits) { h in
                        Button { onPick(h.message.chatId, h.message.id) } label: { row(h) }
                            .buttonStyle(.plain)
                            .eiraRow()
                    }
                } header: { GroupTitle("找到 \(hits.count) 条") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _, _ in run() }
        .onAppear { focused = true }
    }

    private func row(_ h: Hit) -> some View {
        let m = h.message
        let who = m.role == .user ? "我" : (names[m.authorId] ?? "某人")
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(chatId == nil ? "\(h.chatTitle) · \(who)" : who).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Text(Receipt.sepOf(m.createdAt)).font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            Text(snippet(m)).font(.system(size: 14)).foregroundStyle(Theme.text2).lineLimit(3)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// 命中那一处前后各留一截，长消息里也看得到关键词
    private func snippet(_ m: Message) -> AttributedString {
        let key = query.trimmingCharacters(in: .whitespaces)
        let text = Self.searchable(m)
        var shown = text
        if let r = text.range(of: key, options: .caseInsensitive) {
            let start = text.index(r.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
            shown = (start > text.startIndex ? "…" : "") + String(text[start...])
        }
        var a = AttributedString(shown)
        if !key.isEmpty, let r = a.range(of: key, options: .caseInsensitive) {
            a[r].foregroundColor = Theme.text
            a[r].font = .system(size: 14, weight: .semibold)
        }
        return a
    }

    static func searchable(_ m: Message) -> String {
        let tr = m.row.string("translation")
        return tr.isEmpty ? m.content : "\(m.content)\n\(tr)"
    }

    /// 本地找：正文或译文里有这个词的，新的在前。撤回的、失败的不算
    static func search(_ key: String, chatId: String?) throws -> [Message] {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return [] }
        let chats: [Chat]
        if let chatId {
            chats = try Repo.chat(chatId).map { [$0] } ?? []
        } else {
            let s = AppSettings.load()
            let active = s.raw["activePersonaId"]?.string ?? ""
            let all = try Repo.chats()
            let mine = all.filter { $0.personaId == active }
            chats = active.isEmpty || mine.isEmpty ? all : mine
        }
        var out: [Message] = []
        for c in chats {
            out += try Repo.messages(chatId: c.id).filter { m in
                !m.isError && !m.isRecalled && m.kind != "typing" && searchable(m).range(of: k, options: .caseInsensitive) != nil
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    private func run() {
        let k = query.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { hits = []; searched = false; return }
        let found = (try? Self.search(k, chatId: chatId)) ?? []
        let chars = Dictionary(((try? Repo.characters()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        names = chars.mapValues(\.displayName)
        var titles: [String: String] = [:]
        hits = found.map { m in
            if titles[m.chatId] == nil, let c = try? Repo.chat(m.chatId) {
                titles[m.chatId] = c.isGroup ? (c.title.isEmpty ? "群聊" : c.title) : (c.characterIds.first.flatMap { chars[$0]?.displayName } ?? "会话")
            }
            return Hit(message: m, chatTitle: titles[m.chatId] ?? "会话")
        }
        searched = true
    }
}
