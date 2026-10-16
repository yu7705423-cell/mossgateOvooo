import SwiftUI

/// 主屏下滑搜索（网页版 screens/home/Spotlight.js，4.541、4.646）。只在本机查：应用名、角色（名字、备注、签名）、群聊（群名、成员）、
/// 功能在哪儿（FindMap）。人设正文不参与、也不显示（第 6 条），角色那一行只写签名。不调用任何接口。
/// 打了字时最下面两行「在聊天记录中搜索」「在说明书中搜索」，带着词过去。
/// 点角色进那个角色的资料页；点功能进那一页，挂在对话上的先选是哪一段对话（只有一段时直接进去）。
struct SpotlightView: View {
    let settings: [String: JSONValue]
    var open: (String) -> Void
    var openChat: (String) -> Void
    var close: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var q = ""
    @State private var chars: [Character] = []
    @State private var chats: [Chat] = []
    @State private var path = NavigationPath()
    @FocusState private var focused: Bool

    private static let max = 6

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                searchBar
                ScrollView {
                    results.padding(.horizontal, 16)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ContactsView.Route.self) { route in
                switch route {
                case .profile(let id): CharacterProfileView(charId: id, path: $path)
                case .edit(let id): CharacterEditView(charId: id, path: $path)
                case .chat(let id): ConversationView(chatId: id)
                case .personas: PersonaListView()
                case .archived: ArchivedCharsView()
                case .cardImport: EmptyView()
                }
            }
        }
        .onAppear {
            chars = ((try? Repo.characters()) ?? []).filter { !$0.archived }
            chats = (try? Repo.chats()) ?? []
            focused = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                TextField("搜索应用、角色、会话与功能", text: $q)
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
    }

    @ViewBuilder private var results: some View {
        VStack(alignment: .leading, spacing: 4) {
            let typed = q.trimmingCharacters(in: .whitespaces)
            let k = typed.lowercased()
            let apps = matchedApps(k)
            let people = matchedChars(k)
            let convs = matchedChats(k)
            let feats = k.isEmpty ? [] : Array(FindMap.find(typed).prefix(Self.max))
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
                    NavigationLink(value: ContactsView.Route.profile(c.id)) {
                        rowLabel(icon: nil, avatar: c, title: c.displayName, sub: c.signature)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !convs.isEmpty {
                header(k.isEmpty ? "最近的会话" : "会话")
                ForEach(convs, id: \.id) { c in
                    Button { close(); openChat(c.id) } label: {
                        rowLabel(icon: c.isGroup ? "users" : "message", avatar: nil, title: title(c), sub: "")
                    }
                    .buttonStyle(.plain)
                }
            }
            if !feats.isEmpty {
                header("功能")
                ForEach(feats) { e in
                    FindPlaceLink(entry: e, chats: chats, names: names, openChat: { id in close(); openChat(id) }) {
                        rowLabel(icon: e.per == .global ? "sliders" : "message", avatar: nil, title: e.t, sub: e.at)
                    }
                }
            }
            if !k.isEmpty && apps.isEmpty && people.isEmpty && convs.isEmpty && feats.isEmpty {
                Text("没有找到相关的应用、角色、会话或功能。").font(.footnote).foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            if !k.isEmpty {
                header("更多")
                NavigationLink {
                    ChatHitsView(query: typed, names: names) { id in close(); openChat(id) }
                } label: {
                    rowLabel(icon: "message", avatar: nil, title: "在聊天记录中搜索「\(typed)」", sub: "")
                }
                .buttonStyle(.plain)
                NavigationLink {
                    HelpView(initialQuery: typed, openChat: { id in close(); openChat(id) })
                } label: {
                    rowLabel(icon: "notes", avatar: nil, title: "在说明书中搜索「\(typed)」", sub: "")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var names: [String: String] {
        Dictionary(chars.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(Theme.text3).padding(.top, 14).padding(.bottom, 4)
    }

    private func rowLabel(icon: String?, avatar: Character?, title: String, sub: String) -> some View {
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

    private func title(_ c: Chat) -> String { FindMap.title(c, names: names) }
}

// MARK: - 找功能：点了过去（主屏搜索与说明书共用）

/// 一项功能的入口。不挂在对话上的直接进那一页；挂在对话上的只有一段对话时直接进去，多段时先选；
/// 没有页面可去的（主屏长按）只显示位置。openChat 为空时（从设置里进的说明书）「搜索聊天记录」只显示位置
struct FindPlaceLink<Label: View>: View {
    let entry: FindMap.Entry
    let chats: [Chat]
    let names: [String: String]
    var openChat: ((String) -> Void)?
    @ViewBuilder var label: () -> Label

    var body: some View {
        let list = FindMap.chats(for: entry, in: chats)
        if !FindPlaceView.reachable(entry, openChat: openChat != nil) {
            label().opacity(0.7)
        } else if entry.per == .global || list.count == 1 {
            NavigationLink {
                FindPlaceView(dest: entry.dest, chat: list.first, openChat: openChat)
            } label: { label() }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                FindChatPickView(entry: entry, chats: list, names: names, openChat: openChat)
            } label: { label() }
            .buttonStyle(.plain)
        }
    }
}

/// 挂在对话上的一项，先选是哪一段对话（网页版 Spotlight 的 picking）
struct FindChatPickView: View {
    let entry: FindMap.Entry
    let chats: [Chat]
    let names: [String: String]
    var openChat: ((String) -> Void)?

    var body: some View {
        List {
            Section {
                if chats.isEmpty {
                    Text("还没有会话。开始一段对话后，在会话右上角的菜单中设置。").foregroundStyle(Theme.text3)
                }
                ForEach(chats) { c in
                    NavigationLink {
                        FindPlaceView(dest: entry.dest, chat: c, openChat: openChat)
                    } label: {
                        HStack(spacing: Theme.sp3) {
                            SvgIcon(name: c.isGroup ? "users" : "message", size: 17, color: Theme.text2)
                            Text(FindMap.title(c, names: names)).lineLimit(1)
                        }
                    }
                    .eiraRow()
                }
            } header: {
                GroupTitle("「\(entry.t)」按会话分别设置，选择一段会话")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(entry.t)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// FindMap 里 dest 对应的那一页。挂在对话上的那几页要传 chat
struct FindPlaceView: View {
    let dest: String
    var chat: Chat?
    var openChat: ((String) -> Void)?

    /// 画得出来的 dest（FindMapTests 核对表里每一项都在这里）
    static let known: Set<String> = [
        "abilities", "pace", "proactive", "inner", "extras", "status", "translate", "summary", "bond", "badges", "skin", "look",
        "search", "card", "ties", "more",
        "caps", "lore", "memory", "presets", "ban", "regex",
        "api", "routes", "memoryApi", "voice", "image", "music", "weather", "vision", "asr", "translateApi",
        "notify", "bgpush", "limits", "holidays", "appearance", "lockpin", "storage", "help", "feedback", "terms",
        "time", "stickers", "personas",
    ]

    /// 这一项能不能点过去：没有页面的不能；搜索聊天记录要能打开会话
    static func reachable(_ e: FindMap.Entry, openChat: Bool) -> Bool {
        guard known.contains(e.dest) else { return false }
        return e.dest != "search" || openChat
    }

    /// 挂在一段对话上的那几页
    static let perChat: Set<String> = ["abilities", "pace", "proactive", "inner", "extras", "status", "translate", "summary", "bond",
                                       "badges", "skin", "look", "search", "card", "ties", "more"]

    var body: some View {
        if Self.perChat.contains(dest) { chatPage } else { globalPage }
    }

    @ViewBuilder private var chatPage: some View {
        let chatId = chat?.id ?? ""
        let charId = chat?.characterIds.first ?? ""
        switch dest {
        case "abilities": AbilitiesPage(charId: charId)
        case "pace": MenuPage("节奏与自动回复") { PaceSection(chatId: chatId) }
        case "proactive": MenuPage("主动发起对话") { ProactiveSection(charId: charId) }
        case "inner": InnerSetPageView(chatId: chatId)
        case "extras": ExtrasPageView(chatId: chatId)
        case "status": StatusBarSettingsView(chatId: chatId)
        case "translate": TranslatePageView(chatId: chatId)
        case "summary": SummaryPage(chatId: chatId)
        case "bond": BondView(chatId: chatId)
        case "badges": BadgesView(chatId: chatId)
        case "skin": SkinPageView(chatId: chatId)
        case "look": ChatLookView(chatId: chatId)
        case "search": SearchChatView(chatId: chatId) { id, _ in openChat?(id) }
        case "card": FindCardEdit(charId: charId)
        case "ties": MenuPage("好友与拉黑") { TiesSection(chatId: chatId) }
        case "more": ChatMorePageView(chatId: chatId)
        default: EmptyView()
        }
    }

    @ViewBuilder private var globalPage: some View {
        switch dest {
        case "caps": CapsView()
        case "lore": LorebookListView()
        case "memory": MemoryCharsView()
        case "presets": PresetListView()
        case "ban": BanView()
        case "regex": RegexListView()
        case "api": ApiSettingsView()
        case "routes": RoutesView()
        case "memoryApi": MemoryApiView()
        case "voice": VoiceSettingsView()
        case "image": ImageSettingsView()
        case "music": MusicSettingsView()
        case "weather": WeatherSettingsView()
        case "vision": VisionSettingsView()
        case "asr": AsrSettingsView()
        case "translateApi": TranslateSettingsView()
        case "notify": NotifyView()
        case "bgpush": BgPushView()
        case "limits": UsageLimitsView()
        case "holidays": HolidaySettingsView()
        case "appearance": AppearanceView()
        case "lockpin": LockPinView()
        case "storage": StorageView()
        case "help": HelpView(openChat: openChat)
        case "feedback": FeedbackView()
        case "terms": TermsView()
        case "time": TimeSettingsView()
        case "stickers": StickerManagerView()
        case "personas": PersonaListView()
        default: EmptyState(title: "该功能没有可前往的页面")
        }
    }
}

/// 角色卡：编辑页要一条导航路径（删掉角色时退回），这里给它自己的一条
private struct FindCardEdit: View {
    let charId: String
    @State private var path = NavigationPath()
    var body: some View { CharacterEditView(charId: charId, path: $path) }
}

/// 「在聊天记录中搜索」：带着词在全部会话里找（SearchChatView.search，只在本机找、不调接口），点一条打开那段会话
struct ChatHitsView: View {
    let query: String
    let names: [String: String]
    var pick: (String) -> Void
    @State private var hits: [Message] = []
    @State private var titles: [String: String] = [:]
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if loaded && hits.isEmpty && problem == nil {
                EmptyState(title: "没有找到", desc: "正文与译文中均没有「\(query)」。").listRowBackground(Color.clear)
            }
            if !hits.isEmpty {
                Section {
                    ForEach(hits) { m in
                        Button { pick(m.chatId) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("\(titles[m.chatId] ?? "会话") · \(m.role == .user ? "我" : (names[m.authorId] ?? "某人"))")
                                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Spacer()
                                    Text(Receipt.sepOf(m.createdAt)).font(.system(size: 11)).foregroundStyle(Theme.text3)
                                }
                                Text(SearchChatView.searchable(m)).font(.system(size: 14)).foregroundStyle(Theme.text2).lineLimit(3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .eiraRow()
                    }
                } header: { GroupTitle("找到 \(hits.count) 条") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("「\(query)」")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            do {
                hits = try SearchChatView.search(query, chatId: nil)
                var t: [String: String] = [:]
                for id in Set(hits.map(\.chatId)) {
                    if let c = try Repo.chat(id) { t[id] = FindMap.title(c, names: names) }
                }
                titles = t
            } catch {
                problem = "未能读取聊天记录：\(error.localizedDescription)"
            }
            loaded = true
        }
    }
}
