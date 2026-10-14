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
                Section("最近播放") {
                    if recent.isEmpty { Text("该账号暂无播放记录。").font(.footnote).foregroundStyle(Theme.secondaryText) }
                    ForEach(Array(recent.enumerated()), id: \.offset) { i, t in
                        TrackRow(title: t.title, artist: t.artist, cover: t.cover) { player.play(neSongs(recent), at: i) }
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
            Section {
                NavigationLink { LibraryView() } label: {
                    HStack { Text("本机曲库"); Spacer(); Text("已收 \(librarySize) 首").foregroundStyle(Theme.secondaryText) }
                }
            } footer: {
                Text("本页的数据来自你登录的网易云账号，读取时直接连网易云，不经过模型接口。")
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
    @State private var results: [NeTrack] = []
    @State private var searching = false
    @State private var problem: String?
    @State private var sharing: MusicLibrary.Song?

    var body: some View {
        List {
            TextField("搜索歌曲、歌手", text: $key).submitLabel(.search).onSubmit(run)
            if searching { ProgressView() }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            ForEach(Array(results.enumerated()), id: \.offset) { i, t in
                TrackRow(title: t.title, artist: [t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " · "), cover: t.cover,
                         right: AnyView(Menu {
                             Button("收入本机曲库") { _ = try? MusicLibrary.fromNetease(t) }
                             Button("分享到会话") { sharing = try? MusicLibrary.fromNetease(t) }
                         } label: { Image(systemName: "ellipsis") })) {
                    player.play(neSongs(results), at: i)
                }
            }
            if results.isEmpty && !searching {
                Text("输入关键词后按回车开始搜索。点击结果即可播放。").font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
        .sheet(item: $sharing) { s in NavigationStack { ShareSongView(song: s) } }
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
                } header: { Text("听歌排行") }
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

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Button("全部播放") { player.play(songs, at: 0) }.disabled(songs.isEmpty)
                Button("导入本机音频") { importing = true }
            } footer: {
                Text("网易云收入的曲目只保存标识，播放地址在每次播放时重新获取。导入的音频文件存在本机。")
            }
            Section("歌曲 · \(songs.count)") {
                ForEach(Array(songs.enumerated()), id: \.offset) { i, s in
                    TrackRow(title: s.title, artist: s.source == "netease" ? "网易云" + (s.artist.isEmpty ? "" : " · \(s.artist)") : "本机文件" + (s.artist.isEmpty ? "" : " · \(s.artist)"),
                             cover: s.cover, right: AnyView(Menu {
                                 Button("分享到会话") { sharing = s }
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
    @State private var tracks: [MusicLibrary.Song] = []

    var body: some View {
        List {
            Button("全部播放（共 \(tracks.count) 首）") { player.play(tracks, at: 0) }.disabled(tracks.isEmpty)
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, s in
                TrackRow(title: s.title, artist: s.artist, cover: s.cover) { player.play(tracks, at: i) }
                    .swipeActions { Button("移除", role: .destructive) { try? MusicLibrary.removeTrack(listId, s.id); tracks = MusicLibrary.tracks(listId) } }
            }
        }
        .navigationTitle((try? Database.shared.get("playlists", id: listId))?.string("name") ?? "歌单")
        .onAppear { tracks = MusicLibrary.tracks(listId) }
    }
}

/// 正在播放：封面、歌词、进度与控制。
struct NowPlayingView: View {
    @ObservedObject private var player = MusicPlayer.shared
    @State private var lines: [MusicLibrary.Line] = []
    @State private var pure = false
    @State private var drag: Double?

    var body: some View {
        VStack(spacing: Theme.pad) {
            if let s = player.current {
                CoverView(url: s.cover, name: s.title, size: 220).padding(.top, Theme.pad * 2)
                Text(s.title).font(.title3)
                Text(s.artist).foregroundStyle(Theme.secondaryText)
                if !player.error.isEmpty { Text(player.error).font(.footnote).foregroundStyle(Theme.danger) }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 8) {
                            if lines.isEmpty { Text(pure ? "纯音乐，请欣赏" : "暂无歌词").foregroundStyle(Theme.secondaryText) }
                            ForEach(lines.indices, id: \.self) { i in
                                let on = i == activeLine
                                VStack {
                                    Text(lines[i].text).foregroundStyle(on ? Theme.bubbleTheirsText : Theme.tertiaryText)
                                    if !lines[i].trans.isEmpty { Text(lines[i].trans).font(.footnote).foregroundStyle(Theme.tertiaryText) }
                                }
                                .id(i)
                                .onTapGesture { player.seek(lines[i].at) }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: activeLine) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
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
                Text("用网易云音乐 App 扫码并确认。本机只保存登录后的 cookie，不收密码。可截图后在网易云 App 里识别相册中的二维码。")
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
                Text("原生版直接连接网易云，不需要另外部署接口服务器。登录后可读最近播放与歌单，在本机播放的歌曲会记入该账号的听歌记录。")
            }
            Section {
                TextField("来源地址 realIP（可不填）", text: realIPBinding).keyboardType(.numbersAndPunctuation)
            } footer: {
                Text("网易云按出口 IP 风控（提示 -462）时，填一个中国大陆 IP 后重试。未填写时用本机随机生成的一个国内 IP。")
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
                Text("角色的网易云账号在与该角色的会话设置里登录。登录后，请求回复之前按上面的间隔读一次它的最近播放，写进这一轮的上下文；只调网易云，不调用模型接口。")
            }
        }
        .navigationTitle("音乐服务")
        .sheet(isPresented: $login, onDismiss: { model.reload() }) {
            NavigationStack { NeLoginView(charId: "") { login = false } }
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
            Text("一起听：角色可以邀请你一起听、点歌、分享歌曲、整理自己的歌单，不调用额外接口。角色登录网易云后，它的最近播放会写进对话的上下文；一起听时播放的歌也记入它的账号。")
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
    @ObservedObject private var player = MusicPlayer.shared

    var body: some View {
        let song = MusicLibrary.song(message.row.string("songId"))
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
            if let song {
                Button { player.playOne(song) } label: {
                    Image(systemName: player.current?.id == song.id && player.playing ? "pause.circle" : "play.circle").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("播放")
            }
        }
        .padding(Theme.pad)
        .frame(minWidth: 200, alignment: .leading)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
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
