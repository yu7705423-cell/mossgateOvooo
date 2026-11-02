import SwiftUI

/// 搜索聊天记录（网页版 SearchPage）：一段会话里搜，或者在当前身份的全部会话里搜。正文与译文都算；
/// 点一条回到那段会话，跳到那一条并闪一下。只在本机找，不调接口。
///
/// 找的规则与做法在 ChatSearch。打字时停 0.25 秒再找，期间又改了词就取消上一次；找在后台线程上做，不卡输入。
struct SearchChatView: View {
    /// nil 为全部会话
    let chatId: String?
    var onPick: (_ chatId: String, _ messageId: String) -> Void

    @State private var query = ""
    @State private var hits: [Hit] = []
    @State private var searched = false
    @State private var names: [String: String] = [:]
    @State private var busy = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    typealias Hit = ChatSearch.Hit

    var body: some View {
        List {
            Section {
                HStack(spacing: Theme.sp2) {
                    SvgIcon(name: "search", size: 16, color: Theme.text3)
                    TextField(chatId == nil ? "搜索全部会话" : "搜索这段会话", text: $query)
                        .font(.system(size: 15))
                        .focused($focused)
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = ""; hits = []; searched = false; problem = nil } label: { SvgIcon(name: "close", size: 15, color: Theme.text3) }
                            .buttonStyle(.plain).accessibilityLabel("清空")
                    }
                }
                .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp2)
                .background(Theme.groupFill, in: Capsule())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: Theme.sp2, leading: Theme.sp4, bottom: Theme.sp2, trailing: Theme.sp4))
                .listRowSeparator(.hidden)
            }
            if let problem {
                Text(problem).font(.system(size: 14)).foregroundStyle(Theme.danger).listRowBackground(Color.clear)
            } else if busy && hits.isEmpty {
                Text("正在搜索").font(.system(size: 14)).foregroundStyle(Theme.text3).listRowBackground(Color.clear)
            } else if searched && hits.isEmpty {
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
        .task(id: query) { await run() }
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

    static func searchable(_ m: Message) -> String { ChatSearch.searchable(m) }

    /// 本地找：正文或译文里有这个词的，新的在前。撤回的、失败的不算（ChatSearch.run）
    static func search(_ key: String, chatId: String?) throws -> [Message] {
        try ChatSearch.run(key, chatId: chatId)
    }

    /// 词改了就重找：先停一会儿，这期间又改了词，这一次被取消、什么都不做；真正的查找放到后台线程
    @MainActor private func run() async {
        let k = query.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { hits = []; searched = false; busy = false; problem = nil; return }
        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
        busy = true
        let scope = chatId
        let job = Task.detached(priority: .userInitiated) { try ChatSearch.found(k, chatId: scope) }
        let result = await withTaskCancellationHandler { await job.result } onCancel: { job.cancel() }
        if Task.isCancelled { return }
        busy = false
        switch result {
        case .success(let f):
            hits = f.hits
            names = f.names
            problem = nil
        case .failure(let e):
            hits = []
            problem = "未能读取聊天记录：\(e.localizedDescription)"
        }
        searched = true
    }
}
