import SwiftUI

/// 转发的聊天记录（网页版 ForwardBits.js）：气泡、展开看全部、选转发到哪一段。

/// 会话里那一张「聊天记录」卡：标题、前三行、条数
struct ForwardCard: View {
    let message: Message

    var body: some View {
        let fw = Forward.items(of: message)
        VStack(alignment: .leading, spacing: Theme.sp1) {
            Text(fw.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
            ForEach(Array(fw.items.prefix(3).enumerated()), id: \.offset) { _, i in
                Text("\(i.who)：\(i.kind == "image" ? "[图片]" : i.text)")
                    .font(.system(size: 13)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Divider().padding(.top, Theme.sp1)
            Text("聊天记录 · \(fw.items.count) 条").font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .padding(Theme.sp3)
        .frame(width: 240, alignment: .leading)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// 点开看全部：转发那一刻的副本
struct ForwardDetailView: View {
    let message: Message
    var onOpenImage: ((String) -> Void)?

    var body: some View {
        let fw = Forward.items(of: message)
        List {
            ForEach(Array(fw.items.enumerated()), id: \.offset) { _, i in
                VStack(alignment: .leading, spacing: 4) {
                    Text(i.at > 0 ? "\(i.who) · \(Receipt.sepOf(i.at))" : i.who)
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    if !i.imageId.isEmpty {
                        LocalImage(id: i.imageId, maxPixel: 600, fit: true)
                            .frame(maxWidth: 200, maxHeight: 240, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rMd))
                            .onTapGesture { onOpenImage?(i.imageId) }
                    } else {
                        Text(i.text).font(.system(size: 15)).foregroundStyle(Theme.text).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
                .eiraRow()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(fw.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 选转发到哪一段。列当前身份名下的全部会话，当前这一段排在最前
struct ForwardPickView: View {
    let fromChatId: String
    let count: Int
    var onPick: (Chat) -> Void

    @State private var chats: [Chat] = []
    @State private var chars: [String: Character] = [:]
    @State private var problem: String?

    var body: some View {
        List {
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Theme.danger)
            }
            Section {
                if chats.isEmpty {
                    Text("没有可以转发的会话").foregroundStyle(Theme.text3)
                }
                ForEach(chats) { c in
                    Button { onPick(c) } label: { row(c) }
                        .buttonStyle(.plain)
                        .eiraRow()
                }
            } footer: {
                HelpNote("转发后在对方的会话中显示为一条聊天记录，对方在下一次回复时读到它。不会立即调用接口。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("转发 \(count) 条消息给")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func row(_ c: Chat) -> some View {
        let group = c.isGroup
        let ch = group ? nil : c.characterIds.first.flatMap { chars[$0] }
        let title = group ? GroupChat.title(c, members: c.characterIds.compactMap { chars[$0] }) : (ch?.displayName ?? "已删除的角色")
        let sub = c.id == fromChatId ? "当前会话" : group ? "\(c.characterIds.count) 位成员" : (ch?.signature ?? "")
        return HStack(spacing: Theme.sp3) {
            Avatar(imageId: group ? c.avatar : (ch?.avatar ?? ""), name: title, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1) }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func load() {
        do {
            let me = try Repo.chat(fromChatId)?.personaId ?? ""
            chats = try Forward.targets(from: fromChatId, personaId: me)
            chars = Dictionary(try Repo.characters().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        } catch {
            problem = "无法读取会话：\(error.localizedDescription)"
        }
    }
}
