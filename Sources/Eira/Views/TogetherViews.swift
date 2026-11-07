import SwiftUI

/// 「一起看」（网页版 apps/theater）：进来分两边，影片与书籍。片库与书库是全局的，「和谁一起」是开场时挑的一个人。
struct TogetherHomeView: View {
    @AppStorage("eira.together.tab") private var tab = "video"
    @State private var tick = 0
    @State private var watchChat: WatchTarget?
    @State private var reading: ReadTarget?
    @State private var startRow: VideoLib.Video?
    @State private var shelfPicking = false
    @State private var shelfChar: String?
    @State private var problem: String?

    var body: some View {
        let _ = tick
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TOGETHER").font(.system(size: 11, weight: .semibold)).kerning(2.2).foregroundStyle(Theme.text3)
                Text("一起看").font(Theme.serif(30)).kerning(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.sp4).padding(.bottom, Theme.sp3)
            Picker("", selection: $tab) {
                Text("影片").tag("video")
                Text("书籍").tag("book")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.sp4)
            List {
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
                if tab == "book" { bookSide } else { videoSide }
            }
        }
        .navigationTitle("一起看")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { EmptyView() }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { TogetherSettingsView() } label: { SvgIcon(name: "settings", size: 20) }.accessibilityLabel("设置")
            }
        }
        .navigationDestination(item: $shelfChar) { id in ShelfView(charId: id) }
        .fullScreenCover(item: $watchChat, onDismiss: { tick += 1 }) { t in WatchEntryView(chatId: t.id) }
        .fullScreenCover(item: $reading, onDismiss: { tick += 1 }) { t in BookReaderView(bookId: t.bookId, chatId: t.chatId) }
        .sheet(item: $startRow) { v in
            CharPickSheet(title: "和谁一起看《\(v.title)》") { c in
                startRow = nil
                StartWatch.begin(v, with: c) { id in watchChat = WatchTarget(id: id) } failed: { problem = $0 }
            }
        }
        .sheet(isPresented: $shelfPicking) {
            CharPickSheet(title: "书架归属", subtitle: { "\(Shelf.list($0.id).count) 本" }) { c in
                shelfPicking = false
                shelfChar = c.id
            }
        }
        .onAppear { tick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .eiraWatchChanged).receive(on: RunLoop.main)) { _ in tick += 1 }
    }

    @ViewBuilder private var videoSide: some View {
        let s = Watch.state
        if s.active, let row = Watch.current() {
            let char = (try? Repo.character(s.charId)) ?? nil
            Section("正在看") {
                Button { watchChat = WatchTarget(id: s.chatId) } label: {
                    TogetherRow(icon: "film", title: row.title, sub: "和 \(char?.displayName ?? "某个角色") · \(s.playing ? "播放中" : "已暂停")")
                }
                .buttonStyle(.plain)
            }
        }
        let all = VideoLib.all()
        Section {
            NavigationLink { VideoLibraryView() } label: { TogetherRow(icon: "film", title: "片库", sub: "共 \(all.count) 部") }
        }
        if !all.isEmpty {
            Section("最近加入") {
                ForEach(all.prefix(5)) { v in
                    Button { startRow = v } label: {
                        HStack {
                            TogetherRow(icon: "film", title: v.title,
                                        sub: VideoLib.hasSubtitle(v) ? "字幕 \(VideoLib.lines(v).count) 句" : "没有字幕。角色只知道进度，不知道演了什么")
                            Text("一起看").font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            Section {
                EmptyState(title: "片库是空的", desc: "在片库中添加一个播放地址，或者选择一个本机视频文件。")
                NavigationLink("添加影片") { VideoEditView(videoId: nil) }
            }
        }
        Section {} footer: {
            HelpNote("在片库或最近加入中点一部影片，选择一个角色即开始一起看；也可以在会话的输入面板中点「一起看」开场。", title: "开始一起看")
        }
    }

    @ViewBuilder private var bookSide: some View {
        let s = ReadTogether.state
        if s.active, let b = Books.get(s.bookId) {
            let char = (try? Repo.character(s.charId)) ?? nil
            Section("正在读") {
                Button { reading = ReadTarget(bookId: s.bookId, chatId: s.chatId) } label: {
                    TogetherRow(icon: "book", title: b.title, sub: "和 \(char?.displayName ?? "某个角色") · 已翻 \(s.pages) 页")
                }
                .buttonStyle(.plain)
            }
        }
        let books = Books.all()
        Section {
            NavigationLink { BookLibraryView() } label: { TogetherRow(icon: "book", title: "书库", sub: "共 \(books.count) 本") }
        }
        let inRead = books.filter { $0.at > 0 }.prefix(5)
        if !inRead.isEmpty {
            Section("在读") {
                ForEach(Array(inRead)) { b in
                    NavigationLink { BookDetailView(bookId: b.id) } label: {
                        TogetherRow(icon: "book", title: b.title, sub: (b.author.isEmpty ? "" : "\(b.author) · ") + "读到 \(Books.percent(b))%")
                    }
                }
            }
        }
        let shelves = Shelf.withShelf()
        Section {
            ForEach(Array(shelves.enumerated()), id: \.offset) { _, x in
                NavigationLink { ShelfView(charId: x.char.id) } label: {
                    TogetherRow(icon: "book", title: "\(x.char.displayName) 的书架", sub: "\(x.count) 本")
                }
            }
            Button { shelfPicking = true } label: { TogetherRow(icon: "plus", title: "给某个角色摆一个书架", sub: "") }
                .buttonStyle(.plain)
        } header: { Text("角色的书架") }
        if books.isEmpty {
            Section {
                EmptyState(title: "书库是空的", desc: "在书库中导入一个 txt 或 epub 文件。")
                NavigationLink("导入书籍") { BookLibraryView() }
            }
        }
        Section {} footer: { HelpNote("书在书里点「和角色一起读」开场。", title: "开始一起读") }
    }
}

struct WatchTarget: Identifiable { var id: String }
struct ReadTarget: Identifiable { var bookId: String; var chatId: String?; var id: String { bookId + "|" + (chatId ?? "") } }

struct TogetherRow: View {
    let icon: String
    let title: String
    let sub: String

    var body: some View {
        HStack(spacing: Theme.sp3) {
            SvgIcon(name: icon, size: 18, color: Theme.text2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(Theme.text2) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// 选一个角色（网页版 CharPicker）：主角色在前，不列小号
struct CharPickSheet: View {
    let title: String
    var subtitle: ((Character) -> String)?
    var pick: (Character) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let list = ((try? Repo.characters()) ?? []).filter { ($0.parentId ?? "").isEmpty && !$0.archived }
            .sorted { ($0.isNpc ? 1 : 0) < ($1.isNpc ? 1 : 0) }
        NavigationStack {
            List {
                if list.isEmpty { EmptyState(title: "还没有角色", desc: "先在「联系」里建一个角色。") }
                ForEach(list) { c in
                    Button { pick(c) } label: {
                        HStack(spacing: Theme.sp3) {
                            Avatar(imageId: c.avatar, name: c.name, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.displayName)
                                let sub = subtitle?(c) ?? c.signature
                                if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(Theme.text2).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .eiraLook()
    }
}

/// 从片库直接开始一起看（网页版 4.888 的 StartWatch）：进与这个角色的私聊里的那一场（没有私聊就建一段），直接到放映页。
/// 正在和别人看另一部时，结束那一场再开（会话里各留一条记录）
@MainActor
enum StartWatch {
    static func begin(_ v: VideoLib.Video, with c: Character, open: (String) -> Void, failed: (String) -> Void) {
        do {
            let pid = ((try? Repo.activePersona()) ?? nil)?.id ?? ""
            let chat = try People.chatFor(charId: c.id, personaId: pid)
            try Watch.begin(chatId: chat.id, videoId: v.id)
            open(chat.id)
        } catch { failed(error.localizedDescription) }
    }
}

/// 「一起看 - 设置」（网页版 theater/SettingsPage）：一起看与一起读的旋钮放在这个 app 里（第 5 条），用量与上限那一页列着会多调接口的几项
struct TogetherSettingsView: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                NumberRow(title: "角色自行开口的最短间隔", value: model.number("watchGap", 0), unit: "秒", placeholder: "只在你说话时")
                NumberRow(title: "每次提供的台词条数", value: model.number("watchLines", 8), unit: "条", placeholder: "8")
            } header: { Text("一起看") } footer: {
                Text("开启自行开口后，每次开口调用一次模型接口。")
                HelpNote("一起看时，角色自行开口至少相隔这个时长；对手戏正密时等到两倍。填 0 表示不主动开口，只在你说话时回应。台词条数：从当前进度往前取这么多句字幕写入上下文，条数越多每轮的上下文越长。")
            }
            Section {
                NumberRow(title: "角色自行开口的最短间隔", value: model.number("readGap", 0), unit: "页", placeholder: "只在你点的时候")
                NumberRow(title: "每次提供的本页字数", value: model.number("readChars", 900), unit: "字", placeholder: "不给正文")
            } header: { Text("一起读") } footer: {
                Text("开启自行开口后，每次开口调用一次模型接口。")
                HelpNote("一起读时，翻过这么多页角色才会自行开口一次。填 0 表示不主动开口，只在你点「让角色说一句」或发消息时发言。本页字数：把你正读的这一页截取这么多字写入上下文，填 0 表示不给正文，角色只知道书名、章节与进度。")
            }
            Section {
                NumberRow(title: "单次注入字数", value: model.number("injectChars", Double(ReadAhead.defaultChars)), unit: "字", placeholder: "读到书末")
                NumberRow(title: "最多自动续读几次", value: model.number("injectMaxRuns", Double(ReadAhead.defaultRuns)), unit: "次", placeholder: "从不自动")
            } header: { Text("让角色先读") } footer: {
                Text("选择「一直继续」之后，每次续读一次调用。")
                HelpNote("每次交给角色阅读的字数，无论多少字都只调用一次接口，填 0 表示一次读到书末。自动续读达到上限后会重新询问，不会一直读下去；填 0 表示从不自动续读，每次都询问。")
            }
            Section {
                NumberRow(title: "随机评论一次生成几条", value: model.number("crowdCount", 6), unit: "条", placeholder: "6")
            } header: { Text("段评") } footer: {
                HelpNote("每一段的评论页中，随机评论一次生成的读者条数。不设上限，一次生成无论多少条都只调用一次接口。这些读者不会存入联系人。多人共读的人选与生成方式，在那一段的评论页中设置。")
            }
            Section {
                Toggle("收场时自动写一篇", isOn: model.bool("reviewAuto", false))
            } header: { Text("影评与书评") } footer: {
                Text("一起看或一起读结束时，让角色按看过或读过的内容写一篇，各多调用一次模型接口。")
                HelpNote("关闭后仍可在片子或书的「影评 / 书评」中手动写。")
            }
            Section {
                NumberRow(title: "离开之后多久收场", value: model.number("watchAwayEnd", 15), unit: "分钟", placeholder: "一直保留")
            } header: { Text("两者共用") } footer: {
                HelpNote("从播放页或阅读页退出后，该场不会立即结束，以便中途处理别的事。超过这个时长未回来则自动收场，并在会话中留下记录。填 0 表示一直保留。")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("一起看与一起读")
        .navigationBarTitleDisplayMode(.inline)
    }
}
