import SwiftUI

/// 主屏下滑搜索（网页版 screens/home/Spotlight.js，4.541）。只在本机查：应用名、角色（名字、备注、签名）、群聊（群名、成员）。
/// 人设正文不参与、也不显示（第 6 条），角色那一行只写签名。不调用任何接口。
struct SpotlightView: View {
    let settings: [String: JSONValue]
    var open: (String) -> Void
    var openChat: (String) -> Void
    var close: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var q = ""
    @State private var chars: [Character] = []
    @State private var chats: [Chat] = []
    @FocusState private var focused: Bool

    private static let max = 6

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                    TextField("搜索应用、角色与会话", text: $q)
                        .focused($focused)
                        .submitLabel(.search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !q.isEmpty {
                        Button { q = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3) }
                            .accessibilityLabel("清除")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
                Button("取消", action: close).foregroundStyle(Theme.text)
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let k = q.trimmingCharacters(in: .whitespaces).lowercased()
                    let apps = matchedApps(k)
                    let people = matchedChars(k)
                    let convs = matchedChats(k)
                    if !apps.isEmpty {
                        header("应用")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 14) {
                            ForEach(apps, id: \.id) { a in
                                Button { close(); open(a.id) } label: {
                                    VStack(spacing: 5) {
                                        AppTileView(look: a, size: 52, home: HomeLook(wallpaper: false, dark: scheme == .dark, s: settings))
                                        Text(a.name).font(.system(size: 11)).lineLimit(1).foregroundStyle(Theme.text2)
                                    }
                                }
                                .buttonStyle(TilePress())
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    if !people.isEmpty {
                        header("角色")
                        ForEach(people, id: \.id) { c in
                            row(icon: nil, avatar: c, title: c.displayName, sub: c.signature) { close(); open("contact") }
                        }
                    }
                    if !convs.isEmpty {
                        header(k.isEmpty ? "最近的会话" : "会话")
                        ForEach(convs, id: \.id) { c in
                            row(icon: c.isGroup ? "users" : "message", avatar: nil, title: title(c), sub: "") { close(); openChat(c.id) }
                        }
                    }
                    if !k.isEmpty && apps.isEmpty && people.isEmpty && convs.isEmpty {
                        Text("没有找到相关的应用、角色或会话。").font(.footnote).foregroundStyle(Theme.text2)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear {
            chars = ((try? Repo.characters()) ?? []).filter { !$0.archived }
            chats = (try? Repo.chats()) ?? []
            focused = true
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(Theme.text3).padding(.top, 14).padding(.bottom, 4)
    }

    private func row(icon: String?, avatar: Character?, title: String, sub: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                if let avatar {
                    Avatar(imageId: avatar.avatar, name: avatar.name, size: 36)
                } else if let icon {
                    SvgIcon(name: icon, size: 17, color: Theme.text2).frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.text).lineLimit(1)
                    if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(Theme.text2).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func has(_ s: String, _ k: String) -> Bool { s.lowercased().contains(k) }

    private func matchedApps(_ k: String) -> [Shell.Look] {
        guard !k.isEmpty else { return [] }
        return Array(Shell.apps.compactMap { Shell.look($0.id, settings: settings) }
            .filter { has($0.name, k) || has($0.id, k) }.prefix(Self.max * 2))
    }

    private func matchedChars(_ k: String) -> [Character] {
        guard !k.isEmpty else { return [] }
        return Array(chars.filter { has($0.name, k) || has($0.remark, k) || has($0.signature, k) }.prefix(Self.max))
    }

    private func matchedChats(_ k: String) -> [Chat] {
        guard !k.isEmpty else { return Array(chats.sorted { $0.lastMessageAt > $1.lastMessageAt }.prefix(4)) }
        let names = Dictionary(chars.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return Array(chats.filter { c in
            c.characterIds.count > 1 && (has(c.title, k) || c.characterIds.contains { has(names[$0] ?? "", k) })
        }.prefix(Self.max))
    }

    private func title(_ c: Chat) -> String {
        if c.isGroup { return c.title.isEmpty ? "群聊" : c.title }
        let first = c.characterIds.first.flatMap { id in chars.first { $0.id == id } }
        return first?.displayName ?? (c.title.isEmpty ? "会话" : c.title)
    }
}
