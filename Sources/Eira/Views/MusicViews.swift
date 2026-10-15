import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

/// 网易云封面。取不到就是一个方块加首字。
struct CoverView: View {
    let url: String
    let name: String
    var size: CGFloat = 48

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if let img = phase.image { img.resizable().scaledToFill() }
            else {
                ZStack {
                    Theme.placeholder
                    Text(String(name.prefix(1))).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 「音乐」：首页（最近播放、歌单、本机曲库）、搜索、我的。下面一条正在播放。
struct MusicHomeView: View {
    @State private var tab = 0
    @ObservedObject private var player = MusicPlayer.shared

    var body: some View {
        VStack(spacing: 0) {
            // 新版页头：眉题 MUSIC，宋体标题随所在的页签换（网页版 music/App.js 的 titles[tab]）
            VStack(alignment: .leading, spacing: 2) {
                Text("MUSIC").font(.system(size: 11, weight: .semibold)).kerning(2.2).foregroundStyle(Theme.text3)
                Text(["首页", "搜索", "我的"][tab]).font(Theme.serif(30)).kerning(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.sp4).padding(.bottom, Theme.sp3)
            Picker("", selection: $tab) {
                Text("首页").tag(0)
                Text("搜索").tag(1)
                Text("我的").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.sp4)
            switch tab {
            case 1: MusicSearchView()
            case 2: MusicMineView()
            default: MusicFrontView()
            }
            NowBar()
        }
        .navigationTitle("音乐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { EmptyView() } }
    }
}

struct NowBar: View {
    @ObservedObject private var player = MusicPlayer.shared

    var body: some View {
        if let s = player.current {
            NavigationLink { NowPlayingView() } label: {
                HStack(spacing: Theme.gap) {
                    CoverView(url: s.cover, name: s.title, size: 40)
                    VStack(alignment: .leading) {
                        Text(s.title).lineLimit(1)
                        Text(!player.error.isEmpty ? player.error : player.loading ? "正在取播放地址" : s.artist)
                            .font(.footnote).foregroundStyle(player.error.isEmpty ? Theme.secondaryText : Theme.danger).lineLimit(1)
                    }
                    Spacer()
                    Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill") }
                        .accessibilityLabel(player.playing ? "暂停" : "播放")
                    Button { player.next() } label: { Image(systemName: "forward.fill") }.accessibilityLabel("下一首")
                }
                .padding(Theme.pad)
                .background(Theme.groupedBackground)
            }
            .buttonStyle(.plain)
        }
    }
}

struct TrackRow: View {
    let title: String
    let artist: String
    let cover: String
    var right: AnyView? = nil
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: Theme.gap) {
            Button(action: onTap) {
                HStack(spacing: Theme.gap) {
                    CoverView(url: cover, name: title, size: 44)
                    VStack(alignment: .leading) {
                        Text(title).lineLimit(1)
                        if !artist.isEmpty { Text(artist).font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(1) }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let right { right }
        }
    }
}

private func neSongs(_ list: [NeTrack]) -> [MusicLibrary.Song] {
    list.compactMap { try? MusicLibrary.fromNetease($0) }
}

struct MusicFrontView: View {
    @ObservedObject private var player = MusicPlayer.shared
    @State private var recent: [NeTrack] = []
    @State private var lists: [Netease.Playlist] = []
    @State private var problem: String?
    @State private var librarySize = 0

    var body: some View {
        List {
            if Netease.userCookie().isEmpty {
                Section {
                    Text("尚未登录网易云。登录后可查看最近播放与歌单，在此播放的歌曲会记入该账号的听歌记录。不登录也可以搜索与播放。")
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                    NavigationLink { MusicSettingsView() } label: { Text("前往登录") }
                }
            } else {
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
                Section {
                    if recent.isEmpty { Text("该账号暂无播放记录。").font(.footnote).foregroundStyle(Theme.secondaryText) }
                    ForEach(Array(recent.enumerated()), id: \.offset) { i, t in
                        TrackRow(title: t.title, artist: t.artist, cover: t.cover) { player.play(neSongs(recent), at: i) }
                    }
                } header: {
                    HStack {
                        Text("最近播放")
                        Spacer()
                        if !recent.isEmpty { Button("全部播放") { player.play(neSongs(recent), at: 0) }.font(.footnote) }
                    }
                }
                Section("我的歌单 · \(lists.count)") {
                    ForEach(lists) { l in
                        NavigationLink { NePlaylistView(list: l) } label: {
                            HStack {
                                CoverView(url: l.cover, name: l.name, size: 44)
                                VStack(alignment: .leading) {
                                    Text(l.name)
                                    Text("\(l.count) 首" + (l.mine ? "" : " · 收藏")).font(.footnote).foregroundStyle(Theme.secondaryText)
                                }
                            }
                        }
                    }
                }
            }
            QQMusicSection()
            Section {
                NavigationLink { LibraryView() } label: {
                    HStack { Text("本机曲库"); Spacer(); Text("已收 \(librarySize) 首").foregroundStyle(Theme.secondaryText) }
                }
            } footer: {
                HelpNote("本页的数据来自你登录的网易云账号，读取时直接连网易云，不经过模型接口。")
            }
        }
        .task {
            librarySize = ((try? MusicLibrary.songs()) ?? []).count
            guard !Netease.userCookie().isEmpty else { return }
            do {
                recent = try await Netease.recent(limit: 12).songs
                lists = try await Netease.playlists()
                problem = nil
            } catch { problem = error.localizedDescription }
        }
    }
}

struct MusicSearchView: View {
    @ObservedObject private var player = MusicPlayer.shared
    @State private var key = ""
    @State private var source = "netease"
    @State private var results: [NeTrack] = []
    @State private var qqResults: [QQMusic.Track] = []
    @State private var searching = false
    @State private var problem: String?
    @State private var sharing: MusicLibrary.Song?

    var body: some View {
        List {
            Picker("来源", selection: $source) {
                Text("网易云").tag("netease")
                Text("QQ 音乐").tag("qq")
            }
            .pickerStyle(.segmented)
            .onChange(of: source) { _, _ in if !key.trimmingCharacters(in: .whitespaces).isEmpty { run() } }
            TextField("搜索歌曲、歌手", text: $key).submitLabel(.search).onSubmit(run)
            if searching { ProgressView() }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            if source == "netease" {
                ForEach(Array(results.enumerated()), id: \.offset) { i, t in
                    TrackRow(title: t.title, artist: [t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " · "), cover: t.cover,
                             right: AnyView(Menu {
                                 Button("收入本机曲库") { _ = try? MusicLibrary.fromNetease(t) }
                                 Button("分享到会话") { sharing = try? MusicLibrary.fromNetease(t) }
                             } label: { Image(systemName: "ellipsis") })) {
                        player.play(neSongs(results), at: i)
                    }
                }
            } else {
                ForEach(Array(qqResults.enumerated()), id: \.offset) { i, t in
                    TrackRow(title: t.title, artist: t.artist, cover: t.cover,
                             right: AnyView(Menu {
                                 Button("收入本机曲库") { _ = try? MusicLibrary.fromQQ(t) }
                                 Button("分享到会话") { sharing = try? MusicLibrary.fromQQ(t) }
                             } label: { Image(systemName: "ellipsis") })) {
                        player.play(qqSongs(qqResults), at: i)
                    }
                }
            }
            if results.isEmpty && qqResults.isEmpty && !searching {
                Text(source == "qq" && !QQMusic.loggedIn()
                     ? "未登录 QQ 音乐也可以搜索；播放取不到地址时，在「设置 - 音乐服务」登录 QQ 音乐后再试。"
                     : "输入关键词后按回车开始搜索。点击结果即可播放。")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
        .sheet(item: $sharing) { s in NavigationStack { ShareSongView(song: s) } }
    }

    private func run() {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        searching = true
        problem = nil
        let src = source
        Task { @MainActor in
            do {
                if src == "qq" { qqResults = try await QQMusic.search(k); results = []; if qqResults.isEmpty { problem = "没有匹配的歌曲" } }
                else { results = try await Netease.search(k); qqResults = []; if results.isEmpty { problem = "没有匹配的歌曲" } }
            } catch { problem = "搜索失败：\(error.localizedDescription)" }
            searching = false
        }
    }
}

/// QQ 音乐的结果收进曲库再交给播放器（收过的不重复收）
func qqSongs(_ list: [QQMusic.Track]) -> [MusicLibrary.Song] { list.compactMap { try? MusicLibrary.fromQQ($0) } }

/// 选一段会话，把这首歌分享过去。
struct ShareSongView: View {
    let song: MusicLibrary.Song
    @Environment(\.dismiss) private var dismiss
    @State private var chats: [Chat] = []
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            ForEach(chats) { c in
                Button(c.isGroup ? GroupChat.title(c, members: GroupChat.members(c)) : ((c.characterIds.first.flatMap { try? Repo.character($0) })?.displayName ?? c.title)) {
                    do { try MusicListen.share(song, chatId: c.id); dismiss() }
                    catch { problem = "未能分享：\(error.localizedDescription)" }
                }
            }
        }
        .navigationTitle("分享到")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onAppear { chats = (try? Repo.chats()) ?? [] }
    }
}

struct MusicMineView: View {
    @ObservedObject private var player = MusicPlayer.shared
    @State private var profile: Netease.Profile?
    @State private var week = true
    @State private var rank: [NeTrack] = []
    @State private var problem: String?

    var body: some View {
        List {
            if Netease.userCookie().isEmpty {
                NavigationLink { MusicSettingsView() } label: { Text("尚未登录网易云，前往登录") }
            } else {
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
                if let p = profile {
                    Section {
                        HStack(spacing: Theme.pad) {
                            CoverView(url: p.avatar, name: p.nickname, size: 64)
                            VStack(alignment: .leading) {
                                Text(p.nickname).font(.title3)
                                if !p.signature.isEmpty { Text(p.signature).font(.footnote).foregroundStyle(Theme.secondaryText) }
                                Text("Lv.\(p.level) · UID \(p.uid)").font(.caption).foregroundStyle(Theme.tertiaryText)
                            }
                        }
                        LabeledContent("累计听歌", value: "\(p.listenSongs)")
                        LabeledContent("关注", value: "\(p.follows)")
                        LabeledContent("粉丝", value: "\(p.followeds)")
                        LabeledContent("入驻天数", value: "\(p.createDays)")
                    }
                }
                Section {
                    Picker("", selection: $week) { Text("最近一周").tag(true); Text("所有时间").tag(false) }.pickerStyle(.segmented)
                    ForEach(Array(rank.prefix(50).enumerated()), id: \.offset) { i, t in
                        TrackRow(title: "\(i + 1). \(t.title)", artist: t.artist, cover: t.cover,
                                 right: AnyView(Text("\(t.count) 次").font(.footnote).foregroundStyle(Theme.secondaryText))) {
                            player.play(neSongs(Array(rank.prefix(50))), at: i)
                        }
                    }
                } header: { Text("听歌排行") } footer: {
                    if !rank.isEmpty {
                        let sec = rank.reduce(0) { $0 + $1.seconds * $1.count }
                        Text("\(week ? "最近一周" : "所有时间")累计时长约 \(sec >= 3600 ? "\(sec / 3600) 小时 \(sec % 3600 / 60) 分钟" : "\(sec / 60) 分钟")。按排行中各曲目的时长与播放次数估算，不含排行以外的曲目。")
                    }
                }
            }
        }
        .task(id: week) {
            guard !Netease.userCookie().isEmpty else { return }
            do {
                if profile == nil { profile = try await Netease.profile() }
                rank = try await Netease.record(week: week)
                problem = nil
            } catch { problem = error.localizedDescription }
        }
    }
}

struct NePlaylistView: View {
    let list: Netease.Playlist
    @ObservedObject private var player = MusicPlayer.shared
    @State private var tracks: [NeTrack] = []
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Button("全部播放（共 \(tracks.count) 首）") { player.play(neSongs(tracks), at: 0) }.disabled(tracks.isEmpty)
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(title: t.title, artist: t.artist, cover: t.cover,
                         right: AnyView(Button { _ = try? MusicLibrary.fromNetease(t) } label: { Image(systemName: "plus") }.buttonStyle(.plain)
                            .accessibilityLabel("收入本机曲库"))) {
                    player.play(neSongs(tracks), at: i)
                }
            }
        }
        .navigationTitle(list.name)
        .task {
            do { tracks = try await Netease.playlistTracks(list.id) } catch { problem = error.localizedDescription }
        }
    }
}

/// 本机曲库：收进来的网易云歌曲、导入的音频文件；以及你与角色的歌单。
struct LibraryView: View {
    @ObservedObject private var player = MusicPlayer.shared
    @State private var songs: [MusicLibrary.Song] = []
    @State private var lists: [Row] = []
    @State private var importing = false
    @State private var problem: String?
    @State private var sharing: MusicLibrary.Song?
    @State private var editing: SongEditView.Target?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Button("全部播放") { player.play(songs, at: 0) }.disabled(songs.isEmpty)
                Button("导入本机音频") { importing = true }
                Button("按播放地址添加") { editing = .new }
            } footer: {
                HelpNote("网易云收入的曲目只保存标识，播放地址在每次播放时重新获取。导入的音频文件存在本机。")
            }
            Section("歌曲 · \(songs.count)") {
                ForEach(Array(songs.enumerated()), id: \.offset) { i, s in
                    TrackRow(title: s.title, artist: (s.source == "netease" ? "网易云" : s.source == "qq" ? "QQ 音乐" : "本机文件") + (s.artist.isEmpty ? "" : " · \(s.artist)"),
                             cover: s.cover, right: AnyView(Menu {
                                 Button("分享到会话") { sharing = s }
                                 Button(s.source == "netease" || s.source == "qq" ? "编辑歌词" : "编辑") { editing = .song(s.id) }
                                 Button("移除", role: .destructive) { try? MusicLibrary.remove(s.id); reload() }
                             } label: { Image(systemName: "ellipsis") })) {
                        player.play(songs, at: i)
                    }
                }
            }
            if !lists.isEmpty {
                Section("歌单") {
                    ForEach(lists, id: \.id) { l in
                        let owner = l.string("owner")
                        let whose = owner == MusicLibrary.me ? "我的歌单" : "\((try? Repo.character(owner))?.displayName ?? "已删除的角色")的歌单"
                        NavigationLink { LocalListView(listId: l.id) } label: {
                            VStack(alignment: .leading) {
                                Text(l.string("name"))
                                Text("\(whose) · \(l.strings("trackIds").count) 首").font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("本机曲库")
        .documentPicker(isPresented: $importing, types: [.audio], multiple: true) { urls in
            for u in urls {
                do {
                    let data = try Data(contentsOf: u)
                    try MusicLibrary.addLocal(title: u.deletingPathExtension().lastPathComponent, artist: "", data: data, ext: u.pathExtension)
                } catch { problem = "「\(u.lastPathComponent)」未能导入：\(error.localizedDescription)" }
            }
            reload()
        }
        .sheet(item: $sharing) { s in NavigationStack { ShareSongView(song: s) } }
        .sheet(item: $editing, onDismiss: reload) { t in NavigationStack { SongEditView(target: t) } }
        .onAppear(perform: reload)
    }

    private func reload() {
        songs = (try? MusicLibrary.songs()) ?? []
        lists = (try? MusicLibrary.lists()) ?? []
    }
}

struct LocalListView: View {
    let listId: String
    @ObservedObject private var player = MusicPlayer.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [MusicLibrary.Song] = []
    @State private var confirmDelete = false
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Button("全部播放（共 \(tracks.count) 首）") { player.play(tracks, at: 0) }.disabled(tracks.isEmpty)
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, s in
                TrackRow(title: s.title, artist: s.artist, cover: s.cover) { player.play(tracks, at: i) }
                    .swipeActions { Button("移除", role: .destructive) { try? MusicLibrary.removeTrack(listId, s.id); tracks = MusicLibrary.tracks(listId) } }
            }
        }
        .navigationTitle((try? Database.shared.get("playlists", id: listId))?.string("name") ?? "歌单")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("删除歌单", role: .destructive) { confirmDelete = true }
                } label: { NavIcon("more") }
            }
        }
        .confirmationDialog("删除这个歌单。里面的歌留在曲库中。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除歌单", role: .destructive) {
                do { try MusicLibrary.removeList(listId); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
        }
        .onAppear { tracks = MusicLibrary.tracks(listId) }
    }
}

/// 添加或编辑一首（网页版 LibraryPage 的 EditSheet）：名称、歌手、播放地址、歌词（可粘贴 LRC 或导入 .lrc 文件）。
/// 网易云的只改歌词
struct SongEditView: View {
    enum Target: Identifiable {
        case new, song(String)
        var id: String { if case .song(let x) = self { return x }; return "new" }
    }

    let target: Target
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var url = ""
    @State private var lyric = ""
    @State private var problem: String?
    @State private var pickingLrc = false
    @State private var loaded = false

    private var song: MusicLibrary.Song? { if case .song(let id) = target { return MusicLibrary.song(id) }; return nil }

    var body: some View {
        let netease = song?.source == "netease" || song?.source == "qq"
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if netease {
                Text("该曲目来自\(song?.source == "qq" ? "QQ 音乐" : "网易云")，名称、歌手与播放地址以那边为准，此处只能编辑歌词。").font(.footnote).foregroundStyle(Theme.secondaryText)
            } else {
                Section {
                    TextField("歌曲名称", text: $title)
                    TextField("歌手，可留空", text: $artist)
                    TextField(song?.audioId.isEmpty == false ? "播放地址（已有本机文件，可留空）" : "播放地址 https://...", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    HelpNote("播放地址直接指向音频文件。地址与本机文件二选一；已导入本机文件的歌曲可以不填地址。", title: "音乐：编辑歌曲")
                }
            }
            Section {
                TextField("粘贴 LRC 歌词，每行形如 [00:12.30]歌词", text: $lyric, axis: .vertical)
                    .lineLimit(6...20).font(.system(size: 13, design: .monospaced))
                Button("导入 .lrc 文件") { pickingLrc = true }
            } header: { Text("歌词") } footer: {
                let n = MusicLibrary.parseLyric(lyric).count
                Text(lyric.isEmpty ? "未填写歌词" : n > 0 ? "识别到 \(n) 行带时间的歌词" : "没有识别到带时间的歌词行")
            }
        }
        .navigationTitle(song == nil ? "添加歌曲" : "编辑歌曲")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .documentPicker(isPresented: $pickingLrc, types: [.plainText, .data]) { urls in
            guard let u = urls.first else { return }
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: u), let t = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .utf16) {
                lyric = t
                problem = nil
            } else { problem = "读不出这个文件，请确认是 UTF-8 编码的 .lrc 文本" }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let s = song { title = s.title; artist = s.artist; url = s.url; lyric = s.lyric }
        }
    }

    private func save() {
        do {
            if let s = song { try MusicLibrary.edit(s.id, title: title, artist: artist, url: url, lyric: lyric) }
            else { try MusicLibrary.addURL(title: title, artist: artist, url: url, lyric: lyric) }
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

/// 正在播放：封面、歌词、进度与控制。
struct NowPlayingView: View {
    @ObservedObject private var player = MusicPlayer.shared
    @State private var lyricView = false
    @State private var showTrans = true
    @State private var heldUntil = Date.distantPast
    @State private var lines: [MusicLibrary.Line] = []
    @State private var pure = false
    @State private var drag: Double?

    var body: some View {
        VStack(spacing: Theme.pad) {
            if let s = player.current {
                let hasTrans = lines.contains { !$0.trans.isEmpty }
                if !lyricView {
                    // 封面一面：大封面与当前这一句，点一下看整页歌词（网页版 NowPage 的 cover / lyric 两面）
                    Button { lyricView = true } label: {
                        VStack(spacing: Theme.pad) {
                            CoverView(url: s.cover, name: s.title, size: 220).padding(.top, Theme.pad * 2)
                            Text(s.title).font(.title3).foregroundStyle(Theme.text)
                            Text(s.artist).foregroundStyle(Theme.secondaryText)
                            VStack(spacing: 4) {
                                Text(lines.isEmpty ? (pure ? "纯音乐，请欣赏" : "暂无歌词") : lines[activeLine].text)
                                    .foregroundStyle(Theme.bubbleTheirsText)
                                if showTrans, !lines.isEmpty, !lines[activeLine].trans.isEmpty {
                                    Text(lines[activeLine].trans).font(.footnote).foregroundStyle(Theme.tertiaryText)
                                }
                            }
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看歌词")
                    Spacer(minLength: 0)
                } else {
                    Button { lyricView = false } label: {
                        VStack(spacing: 2) {
                            Text(s.title).font(.headline).foregroundStyle(Theme.text)
                            Text(s.artist).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.top, Theme.pad)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到封面")
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 8) {
                                if lines.isEmpty { Text(pure ? "纯音乐，请欣赏" : "暂无歌词").foregroundStyle(Theme.secondaryText) }
                                ForEach(lines.indices, id: \.self) { i in
                                    let on = i == activeLine
                                    VStack {
                                        Text(lines[i].text).foregroundStyle(on ? Theme.bubbleTheirsText : Theme.tertiaryText)
                                        if showTrans && !lines[i].trans.isEmpty { Text(lines[i].trans).font(.footnote).foregroundStyle(Theme.tertiaryText) }
                                    }
                                    .id(i)
                                    .onTapGesture { player.seek(lines[i].at) }
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .simultaneousGesture(DragGesture().onChanged { _ in heldUntil = Date().addingTimeInterval(3) })
                        .onChange(of: activeLine) { _, i in
                            // 手动滑过之后三秒内不自动跟随
                            guard Date() > heldUntil else { return }
                            withAnimation { proxy.scrollTo(i, anchor: .center) }
                        }
                        .onAppear { proxy.scrollTo(activeLine, anchor: .center) }
                    }
                }
                if !player.error.isEmpty { Text(player.error).font(.footnote).foregroundStyle(Theme.danger) }
                if hasTrans {
                    HStack {
                        Spacer()
                        Button { showTrans.toggle() } label: {
                            Image(systemName: "character.bubble").foregroundStyle(showTrans ? Theme.text : Theme.tertiaryText)
                        }
                        .accessibilityLabel(showTrans ? "隐藏翻译" : "显示翻译")
                    }
                }
                Slider(value: Binding(get: { drag ?? player.seconds }, set: { drag = $0 }), in: 0...max(1, player.duration)) { editing in
                    if !editing, let d = drag { player.seek(d); drag = nil }
                }
                HStack {
                    Text(MusicPlayer.fmt(player.seconds)); Spacer(); Text(MusicPlayer.fmt(player.duration))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                HStack(spacing: Theme.pad * 3) {
                    Button { cycleMode() } label: { Image(systemName: modeIcon) }.accessibilityLabel("播放模式")
                    Button { player.prev() } label: { Image(systemName: "backward.fill").font(.title2) }.accessibilityLabel("上一首")
                    Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 52)) }
                        .accessibilityLabel(player.playing ? "暂停" : "播放")
                    Button { player.next() } label: { Image(systemName: "forward.fill").font(.title2) }.accessibilityLabel("下一首")
                }
                .padding(.bottom, Theme.pad * 2)
            } else {
                Text("当前没有在播放的歌曲").foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, Theme.pad)
        .task(id: player.current?.id) {
            guard let s = player.current else { return }
            lines = []
            let r = await MusicLibrary.lyricOf(s)
            lines = r.lines
            pure = r.pure
        }
    }

    private var activeLine: Int {
        let t = player.seconds + 0.2
        return lines.lastIndex { $0.at <= t } ?? 0
    }

    private var modeIcon: String {
        switch SettingsModel.shared.s.raw["playMode"]?.string {
        case "shuffle": return "shuffle"
        case "one": return "repeat.1"
        default: return "repeat"
        }
    }

    private func cycleMode() {
        let cur = SettingsModel.shared.s.raw["playMode"]?.string ?? "order"
        SettingsModel.shared.set("playMode", .string(cur == "order" ? "shuffle" : cur == "shuffle" ? "one" : "order"))
    }
}

/// 网易云扫码登录。owner 空是你的账号，否则是那个角色的。
struct NeLoginView: View {
    let charId: String
    var onDone: () -> Void
    @State private var key = ""
    @State private var status = "正在取二维码"
    @State private var image: UIImage?
    @State private var cookie = ""
    @State private var problem: String?
    @State private var job: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                if let image {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 220).frame(maxWidth: .infinity)
                }
                Text(status).font(.footnote).foregroundStyle(Theme.secondaryText)
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            } header: {
                Text("扫码登录")
            } footer: {
                HelpNote("用网易云音乐 App 扫码并确认。本机只保存登录后的 cookie，不收密码。可截图后在网易云 App 里识别相册中的二维码。")
            }
            Section {
                TextField("MUSIC_U=...", text: $cookie, axis: .vertical).lineLimit(2...6)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存") { save(cookie) }.disabled(cookie.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("粘贴 cookie")
            }
        }
        .navigationTitle(charId.isEmpty ? "登录网易云" : "角色的网易云账号")
        .onAppear(perform: start)
        .onDisappear { job?.cancel() }
    }

    private func start() {
        job?.cancel()
        job = Task {
            do {
                let k = try await Netease.qrKey()
                key = k
                image = qr(Netease.qrURL(k))
                status = "等待扫码"
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    let r = try await Netease.qrCheck(k)
                    switch r.code {
                    case 800: status = "二维码已过期"; start(); return
                    case 802: status = "已扫码，请在手机上确认"
                    case 803: save(r.cookie); return
                    default: break
                    }
                }
            } catch is CancellationError {
            } catch { problem = error.localizedDescription }
        }
    }

    private func save(_ c: String) {
        Task {
            do {
                let nick = try await Netease.saveLogin(c, charId: charId)
                status = nick.isEmpty ? "已保存" : "已登录：\(nick)"
                onDone()
            } catch { problem = error.localizedDescription }
        }
    }

    private func qr(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 「设置 - 音乐服务」：你的网易云账号、角色在听什么、听歌记录与歌词。
struct MusicSettingsView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var login = false
    @State private var qqLogin = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                let nick = Netease.config(model.s)["nickname"]?.string ?? ""
                if Netease.userCookie(model.s).isEmpty {
                    Button("登录网易云") { login = true }
                } else {
                    LabeledContent("已登录", value: nick.isEmpty ? "网易云账号" : nick)
                    Button("退出登录", role: .destructive) {
                        do { try Netease.logout(); model.reload() } catch { problem = error.localizedDescription }
                    }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            } header: {
                Text("我的网易云账号")
            } footer: {
                HelpNote("原生版直接连接网易云，不需要另外部署接口服务器。登录后可读最近播放与歌单，在本机播放的歌曲会记入该账号的听歌记录。")
            }
            Section {
                if QQMusic.loggedIn(model.s) {
                    LabeledContent("已登录", value: "QQ 号 \(QQMusic.uin(model.s))")
                    Button("退出登录", role: .destructive) {
                        do { try QQMusic.logout(); model.reload() } catch { problem = error.localizedDescription }
                    }
                } else {
                    Button("扫码登录 QQ 音乐") { qqLogin = true }
                }
            } header: {
                Text("我的 QQ 音乐账号")
            } footer: {
                Text("非官方接入，QQ 音乐改版后可能暂时不能用。")
                HelpNote("原生版直接连接 QQ 音乐，走的是 QQ 音乐网页与客户端自己用的接口，不是公开接口。用手机 QQ 扫码登录；登录信息只存在本机。登录后可以播放、读自己建的歌单；会员歌曲需要会员账号。网易云找不到角色点的歌时，会到 QQ 音乐找。QQ 音乐的歌导出给网页版时只保留名称与歌手。", title: "QQ 音乐")
            }
            Section {
                TextField("来源地址 realIP（可不填）", text: realIPBinding).keyboardType(.numbersAndPunctuation)
            } footer: {
                HelpNote("网易云按出口 IP 风控（提示 -462）时，填一个中国大陆 IP 后重试。未填写时用本机随机生成的一个国内 IP。")
            }
            Section {
                NumberRow(title: "角色的听歌记录多久读一次", value: gapBinding, unit: "分钟", placeholder: "只手动读")
                NumberRow(title: "多久以前的记录不再告诉角色", value: model.number("musicFresh", 120), unit: "分钟", placeholder: "不限")
                NumberRow(title: "听满多少秒才记一次听歌", value: model.number("scrobbleAfter", 30), unit: "秒", placeholder: "立即")
                Toggle("分享的歌带上歌词", isOn: model.bool("songLyric", true))
                NumberRow(title: "歌词带前几句", value: model.number("songLyricLines", 20), unit: "句", placeholder: "整首")
            } header: {
                Text("角色在听什么")
            } footer: {
                HelpNote("角色的网易云账号在与该角色的会话设置里登录。登录后，请求回复之前按上面的间隔读一次它的最近播放，写进这一轮的上下文；只调网易云，不调用模型接口。")
            }
        }
        .navigationTitle("音乐服务")
        .sheet(isPresented: $login, onDismiss: { model.reload() }) {
            NavigationStack { NeLoginView(charId: "") { login = false } }
        }
        .sheet(isPresented: $qqLogin, onDismiss: { model.reload() }) {
            NavigationStack { QQLoginView { qqLogin = false } }
        }
    }

    private var realIPBinding: Binding<String> {
        Binding(get: { Netease.config(model.s)["realIP"]?.string ?? "" },
                set: { v in try? Netease.patchConfig(["realIP": .string(v.trimmingCharacters(in: .whitespaces))]); model.reload() })
    }

    private var gapBinding: Binding<Double> {
        Binding(get: { Netease.config(model.s)["recentGap"]?.number ?? 5 },
                set: { v in try? Netease.patchConfig(["recentGap": .number(max(0, v))]); model.reload() })
    }
}

/// 会话设置里：一起听开关、角色的网易云账号、查看角色在听什么。
struct MusicCharSection: View {
    let charId: String
    @State private var canListen = true
    @State private var nick = ""
    @State private var logged = false
    @State private var login = false
    @State private var note: String?
    @State private var loaded = false

    var body: some View {
        Section {
            Toggle("一起听", isOn: $canListen)
            if canListen {
                if logged {
                    LabeledContent("角色的网易云", value: nick.isEmpty ? "已登录" : nick)
                    Button("查看角色在听什么") { pull() }
                    Button("退出角色的网易云", role: .destructive) { try? Netease.logout(charId: charId); load() }.foregroundStyle(Theme.dangerText)
                } else {
                    Button("登录角色的网易云账号") { login = true }
                }
            }
            if let note { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) }
        } header: {
            Text("音乐")
        } footer: {
            HelpNote("一起听：角色可以邀请你一起听、点歌、分享歌曲、整理自己的歌单，不调用额外接口。角色登录网易云后，它的最近播放会写进对话的上下文；一起听时播放的歌也记入它的账号。")
        }
        .sheet(isPresented: $login, onDismiss: load) { NavigationStack { NeLoginView(charId: charId) { login = false } } }
        .onAppear(perform: load)
        .onChange(of: canListen) { _, v in if loaded { try? Diary.patchChar(charId, ["canListen": .bool(v)]) } }
    }

    private func load() {
        guard let c = try? Repo.character(charId) else { return }
        canListen = c.row["canListen"]?.bool != false
        logged = !c.row.string("neteaseCookie").isEmpty
        nick = c.row.string("neteaseNick")
        loaded = true
    }

    private func pull() {
        note = "正在读取"
        Task {
            do {
                let r = try await Netease.pullRecent(charId)
                note = (r.kind == "recent" ? "刚刚在听：" : "最近常听：") + (r.songs.first?.label ?? "")
            } catch { note = error.localizedDescription }
        }
    }
}

/// 会话里的一张歌曲卡片：点一下就放。
struct SongCard: View {
    let message: Message
    /// 歌只在 songId 变了时读一次库：放歌时播放器每秒一变，不让每张卡跟着查库
    @State private var song: MusicLibrary.Song?

    init(message: Message) {
        self.message = message
        _song = State(initialValue: MusicLibrary.song(message.row.string("songId")))
    }

    var body: some View {
        let state = message.row.string("songState")
        let q = MusicLibrary.splitQuery(message.row.string("songQuery"))
        HStack(spacing: Theme.gap) {
            CoverView(url: song?.cover ?? "", name: song?.title ?? q.title, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song?.title ?? q.title).lineLimit(1)
                Text(state == "pending" ? "正在查找" : state == "missing" ? "没有找到这首歌" : (song?.artist ?? q.artist))
                    .font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let song { SongCardPlay(song: song) }
        }
        .padding(Theme.pad)
        .frame(minWidth: 200, alignment: .leading)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
        .task(id: message.row.string("songId") + "|" + state) { song = MusicLibrary.song(message.row.string("songId")) }
    }
}

/// 卡片上的播放键：只有它观察播放器
private struct SongCardPlay: View {
    let song: MusicLibrary.Song
    @ObservedObject private var player = MusicPlayer.shared

    var body: some View {
        Button { player.playOne(song) } label: {
            Image(systemName: player.current?.id == song.id && player.playing ? "pause.circle" : "play.circle").font(.title2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("播放")
    }
}

/// 一起听的时候，输入框上面那一条。
struct ListenBar: View {
    let chatId: String
    @ObservedObject private var player = MusicPlayer.shared

    var body: some View {
        HStack(spacing: Theme.gap) {
            Image(systemName: "headphones").foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading) {
                Text("一起听 · " + (player.current?.title ?? "")).font(.footnote).lineLimit(1)
                if !player.error.isEmpty { Text(player.error).font(.caption).foregroundStyle(Theme.danger).lineLimit(1) }
            }
            Spacer()
            Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill") }.accessibilityLabel(player.playing ? "暂停" : "播放")
            Button { player.next() } label: { Image(systemName: "forward.fill") }.accessibilityLabel("下一首")
            Button("结束") { player.stop(); player.endListen() }.font(.footnote)
        }
        .padding(.horizontal, Theme.pad).padding(.vertical, 6)
        .background(Theme.groupedBackground)
    }
}

/// 会话加号面板的「分享音乐」（网页版 SongCard.js 的 SongPicker）：搜一首，点一下就发进这段会话
struct SongPickView: View {
    let chatId: String
    var done: () -> Void
    @State private var key = ""
    @State private var results: [NeTrack] = []
    @State private var searching = false
    @State private var problem: String?

    var body: some View {
        List {
            TextField("搜索歌曲、歌手", text: $key).submitLabel(.search).onSubmit(run)
            if searching { ProgressView() }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            ForEach(Array(results.enumerated()), id: \.offset) { _, t in
                Button {
                    do {
                        let song = try MusicLibrary.fromNetease(t)
                        _ = try MusicListen.share(song, chatId: chatId)
                        NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
                        done()
                    } catch { problem = "未能分享：\(error.localizedDescription)" }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).foregroundStyle(Theme.text)
                        Text([t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.text3)
                    }
                }
            }
        }
        .navigationTitle("分享音乐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: done) } }
    }

    private func run() {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        searching = true
        problem = nil
        Task {
            do { results = try await Netease.search(k); if results.isEmpty { problem = "没有匹配的歌曲" } }
            catch { problem = "搜索失败：\(error.localizedDescription)" }
            searching = false
        }
    }
}

/// QQ 音乐扫码登录：显示二维码，每两秒问一次进度；确认之后换成 QQ 音乐的登录信息。每一步出错都写在屏幕上
struct QQLoginView: View {
    var done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var qr: QQMusic.QR?
    @State private var status = "正在取二维码"
    @State private var problem: String?
    @State private var job: Task<Void, Never>?

    var body: some View {
        VStack(spacing: Theme.sp4) {
            if let qr, let img = UIImage(data: qr.image) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220)
                    .padding(Theme.sp3).background(Color.white, in: RoundedRectangle(cornerRadius: Theme.rMd))
            } else {
                ProgressView().frame(width: 220, height: 220)
            }
            Text(status).font(.footnote).foregroundStyle(Theme.secondaryText)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger).multilineTextAlignment(.center) }
            Text("用手机 QQ 扫描二维码，在手机上确认登录。可以截图后在手机 QQ 里从相册识别。")
                .font(.footnote).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            Button("换一张") { start() }
            Spacer()
        }
        .padding(Theme.pad)
        .navigationTitle("登录 QQ 音乐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { job?.cancel(); dismiss() } } }
        .onAppear(perform: start)
        .onDisappear { job?.cancel() }
    }

    private func start() {
        job?.cancel()
        problem = nil
        qr = nil
        status = "正在取二维码"
        job = Task { @MainActor in
            do {
                let q = try await QQMusic.qrStart()
                qr = q
                status = "等待扫码"
                var fails = 0
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    // 切去 QQ 确认时应用在后台：不问，回到前台立刻问（网页版 4.622）
                    if UIApplication.shared.applicationState != .active { continue }
                    let r: (state: QQMusic.QRState, cookies: [String: String])
                    do { r = try await QQMusic.qrCheck(q.qrsig) }
                    catch let e as QQMusic.QQError where e.transient {
                        // 那一下被系统掐断（切去 QQ 时常见）：接着问，连着 8 次才算失败
                        fails += 1
                        if fails >= 8 { throw e }
                        status = "网络中断，正在重试"
                        continue
                    }
                    fails = 0
                    switch r.state {
                    case .waiting: status = "等待扫码"
                    case .scanned: status = "已扫码，请在手机上确认"
                    case .expired: status = "二维码已过期，点「换一张」"; return
                    case .failed(let m): problem = m; return
                    case .done(let url):
                        status = "正在完成登录"
                        _ = try await QQMusic.finishLogin(checkSigURL: url, cookies: r.cookies)
                        done()
                        return
                    }
                }
            } catch is CancellationError {
            } catch { problem = error.localizedDescription; status = "未能登录" }
        }
    }
}

/// QQ 音乐的一张歌单：读出来点一首就放
struct QQPlaylistView: View {
    let id: String
    var name = ""
    @ObservedObject private var player = MusicPlayer.shared
    @State private var tracks: [QQMusic.Track] = []
    @State private var title = ""
    @State private var problem: String?
    @State private var loading = true

    var body: some View {
        List {
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            if loading { ProgressView() }
            if !tracks.isEmpty {
                Button("全部播放（共 \(tracks.count) 首）") { player.play(qqSongs(tracks), at: 0) }
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(title: t.title, artist: t.artist, cover: t.cover) { player.play(qqSongs(tracks), at: i) }
            }
        }
        .navigationTitle(title.isEmpty ? (name.isEmpty ? "歌单" : name) : title)
        .task {
            do { let r = try await QQMusic.playlistTracks(id); tracks = r.tracks; title = r.name; problem = tracks.isEmpty ? "这张歌单是空的，或者不公开" : nil }
            catch { problem = error.localizedDescription }
            loading = false
        }
    }
}

/// 首页里的 QQ 音乐一块：登录了列出自己建的歌单；也可以贴一张歌单的链接打开
struct QQMusicSection: View {
    @State private var lists: [QQMusic.Playlist] = []
    @State private var problem: String?
    @State private var link = ""

    var body: some View {
        Section {
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            ForEach(lists) { l in
                NavigationLink { QQPlaylistView(id: l.id, name: l.name) } label: {
                    HStack {
                        CoverView(url: l.cover.replacingOccurrences(of: "http://", with: "https://"), name: l.name, size: 44)
                        VStack(alignment: .leading) {
                            Text(l.name)
                            Text("\(l.count) 首").font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
            TextField("粘贴 QQ 音乐歌单链接或编号", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
            if let id = QQMusic.playlistId(link) {
                NavigationLink { QQPlaylistView(id: id) } label: { Text("打开这张歌单（\(id)）") }
            } else if !link.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("没有从这段文字里认出歌单编号").font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        } header: { Text("QQ 音乐") }
        .task {
            guard QQMusic.loggedIn() else { return }
            do { lists = try await QQMusic.myPlaylists() } catch { problem = error.localizedDescription }
        }
    }
}
