import SwiftUI

// MARK: - 收藏（网页版 FavoritesPage.js，ARCHITECTURE 4.853）

/// 聊天「主页」右上角的书签进来。按收藏的先后列出，点一条跳回原对话的那一条，右边的叉取消收藏。
/// 整页就是这一个列表，页面自己滚（第 26 条）
struct FavoritesView: View {
    var onOpen: (String, String) -> Void
    @State private var list: [Message] = []
    @State private var chats: [String: Chat] = [:]
    @State private var chars: [String: Character] = [:]
    @State private var me: Persona?
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if list.isEmpty {
                EmptyState(title: "暂无收藏", desc: "长按一条消息，选择「收藏」。")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(list) { m in
                        Button { onOpen(m.chatId, m.id) } label: { row(m) }
                            .buttonStyle(.plain)
                            .eiraRow()
                    }
                } header: { Text("共 \(list.count) 条") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func row(_ m: Message) -> some View {
        let chat = chats[m.chatId]
        let mine = m.role == .user
        let group = chat?.isGroup == true
        let char = mine ? nil : chars[group ? m.authorId : (chat?.characterIds.first ?? m.authorId)]
        let who = mine ? (me?.name ?? "我") : (char?.displayName ?? "已删除的角色")
        let whereIs = group ? (chat.map { GroupChat.title($0, members: $0.characterIds.compactMap { chars[$0] }) } ?? "") : ""
        return HStack(alignment: .top, spacing: Theme.sp3) {
            Avatar(imageId: mine ? (me?.avatar ?? "") : (char?.avatar ?? ""), name: who, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(whereIs.isEmpty ? who : "\(who) · \(whereIs)").font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(Receipt.sepOf(m.createdAt)).font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                HStack(spacing: Theme.sp2) {
                    if m.kind == "image" && !m.imageId.isEmpty {
                        LocalImage(id: m.imageId, maxPixel: 120).frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                    }
                    Text(Favorites.line(m)).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(2)
                }
            }
            Button { unfav(m) } label: { SvgIcon(name: "close", size: 15, color: Theme.text3).frame(width: 30, height: 30) }
                .buttonStyle(.borderless)
                .accessibilityLabel("取消收藏")
        }
        .contentShape(Rectangle())
    }

    private func unfav(_ m: Message) {
        do { try Favorites.set(m, false); reload() }
        catch { problem = "取消收藏未能保存：\(error.localizedDescription)" }
    }

    private func reload() {
        do {
            list = try Favorites.all()
            chats = Dictionary(try Repo.chats().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            chars = Dictionary(try Repo.characters().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            me = try Repo.activePersona()
            problem = nil
        } catch { problem = "读取失败：\(error.localizedDescription)" }
    }
}

// MARK: - 上一轮发送的内容（网页版 SentPage.js，ARCHITECTURE 4.776）

/// 会话菜单「历史范围」下面一项。这段会话最近一轮回复请求的原文：设定按区块抬头切开，一块一块折叠；聊天记录另一组。
/// 只读、可复制，重新打开应用后清空，不调接口。
/// 人设正文在这一页原样出现：它就是用来核对角色读到了什么的，和导入确认页同一个理由（网页版 CLAUDE.md 第 6 条的例外）
struct SentPageView: View {
    let chatId: String
    @State private var row: LastSent.Row?
    @State private var open = ""
    @State private var copied = false

    var body: some View {
        List {
            if let row {
                Section {
                    LabeledContent("时间", value: row.at.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("接口", value: (row.preset.isEmpty ? "未命名" : row.preset) + (row.model.isEmpty ? "" : " · \(row.model)"))
                }
                let parts = LastSent.sections(row.system)
                Section {
                    ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                        block("s\(i)", title: p.head, text: p.text)
                    }
                } header: { Text("设定（\(parts.count) 块）") }
                Section {
                    ForEach(Array(row.messages.enumerated()), id: \.offset) { i, m in
                        block("m\(i)", title: "\(i + 1) · \(LastSent.roleLabel(m.role))\(m.images > 0 ? " · 含图片" : "")\(LastSent.headsOf(m))",
                              text: m.content)
                    }
                } header: { Text("聊天记录（\(row.messages.count) 条）") } footer: {
                    HelpNote("只读。显示的是最近一轮回复发送给模型的原文；换了接口重试时显示最后一次。只保存在本机内存中，重新打开应用后清空。不调用接口。", title: "上一轮发送的内容")
                }
            } else {
                EmptyState(title: "还没有记录", desc: "角色在这段对话里回复一次之后，这里显示那一轮发送给模型的全部内容。记录只保存在本机内存中，重新打开应用后清空。")
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("上一轮发送的内容")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let row {
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "已复制" : "复制") {
                        UIPasteboard.general.string = LastSent.text(row)
                        copied = true
                    }
                }
            }
        }
        .onAppear { row = LastSent.shared.last(chatId) }
        .onReceive(NotificationCenter.default.publisher(for: LastSent.didKeep)) { n in
            guard (n.object as? String) == chatId else { return }
            row = LastSent.shared.last(chatId)
            copied = false
        }
    }

    /// 一块：标题、字数，点一下展开或收起，默认收起
    @ViewBuilder private func block(_ key: String, title: String, text: String) -> some View {
        Button { open = open == key ? "" : key } label: {
            HStack {
                Text(title).foregroundStyle(Theme.text).lineLimit(2)
                Spacer()
                Text("\(text.count) 字").font(.caption).foregroundStyle(Theme.text3)
                Image(systemName: open == key ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(Theme.text3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open == key {
            Text(text).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
