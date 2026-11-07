import AVFoundation
import Combine
import SwiftUI

/// 一起看的播放器（网页版 WatchPage 里那个 <video> 与 watch.attach）。整个应用只有一个：
/// 放映页打开时接上、每秒把进度写进 Watch；离开放映页暂停（这一场不结束）；角色写的 [暂停] [继续] [倒回] 经通知到这里。
/// 候选地址一个接一个试；B 站的全部放不了时重取一次地址（约两小时过期），还不行就在画面底下写明原因（网页版 4.887、4.897）。
@MainActor
final class WatchPlayer: ObservableObject {
    static let shared = WatchPlayer()

    let player = AVPlayer()
    @Published private(set) var at: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var problem = ""
    private(set) var videoId = ""
    private var urls: [URL] = []
    private var index = 0
    private var renewed = false
    private var timer: Timer?
    private var control: NSObjectProtocol?

    init() {
        control = NotificationCenter.default.addObserver(forName: .eiraWatchControl, object: nil, queue: .main) { [weak self] n in
            let act = n.userInfo?["act"] as? String ?? ""
            let to = n.userInfo?["to"] as? Double
            Task { @MainActor in self?.handle(act, to) }
        }
    }

    /// 放映页打开时：同一部接着放，换了一部重新取地址
    func open(_ v: VideoLib.Video) async {
        startTick()
        Watch.back()
        if videoId == v.id, player.currentItem != nil { return }
        videoId = v.id
        problem = ""
        renewed = false
        // 两边不同时响：一起听、自己在听的歌先停
        if MusicPlayer.shared.listenChat != nil { MusicPlayer.shared.endListen() }
        if MusicPlayer.shared.playing { MusicPlayer.shared.toggle() }
        await load(from: 0)
    }

    private func load(from: Double) async {
        guard let v = VideoLib.get(videoId) else { problem = "这部片已不在片库中"; return }
        do { urls = try await VideoLib.sources(v) } catch { problem = error.localizedDescription; return }
        guard !urls.isEmpty else { problem = "这部片没有可以播放的地址"; return }
        play(0, from: from)
    }

    private func play(_ i: Int, from: Double) {
        index = i
        let bili = VideoLib.get(videoId)?.bili != nil
        // B 站的视频服务器查来源页：带上（网页版整页不带来源页，原生版可以直接带对的那一个）
        let asset = AVURLAsset(url: urls[i], options: bili ? ["AVURLAssetHTTPHeaderFieldsKey": BiliApi.playHeaders] : nil)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        if from > 0 { player.seek(to: CMTime(seconds: from, preferredTimescale: 600)) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        problem = ""
    }

    private func failed(_ error: Error?) {
        let from = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
        if index + 1 < urls.count { play(index + 1, from: from); return }
        if VideoLib.get(videoId)?.bili != nil && !renewed {
            renewed = true
            Task { await load(from: from) }
            return
        }
        let host = urls.indices.contains(index) ? (urls[index].host ?? "") : ""
        let why = error.map { $0.localizedDescription } ?? "未知错误"
        problem = "视频无法播放" + (host.isEmpty ? "" : "：视频服务器 \(host) 拒绝了请求，或返回的格式无法播放")
            + "（\(why)\(urls.count > 1 ? "，已试过 \(urls.count) 个地址" : "")）"
    }

    private func startTick() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in WatchPlayer.shared.beat() }
        }
    }

    private func beat() {
        if let item = player.currentItem, item.status == .failed { failed(item.error); return }
        let t = player.currentTime().seconds
        let d = player.currentItem?.duration.seconds ?? 0
        at = t.isFinite ? t : 0
        duration = d.isFinite ? d : 0
        playing = player.timeControlStatus != .paused
        Watch.tick(at: at, duration: duration, playing: playing)
    }

    /// 离开放映页：画面停了，这一场不结束
    func leave() {
        player.pause()
        timer?.invalidate()
        timer = nil
        playing = false
        Watch.away()
    }

    /// 这一场收了：放下片子
    func close() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        timer?.invalidate()
        timer = nil
        videoId = ""
        urls = []
        playing = false
        at = 0
    }

    func toggle() { if player.timeControlStatus == .paused { player.play() } else { player.pause() } ; beatSoon() }

    func seek(_ sec: Double) {
        let to = max(0, duration > 0 ? min(sec, duration) : sec)
        player.seek(to: CMTime(seconds: to, preferredTimescale: 600))
        at = to
        Watch.tick(at: to, duration: duration, playing: playing)
    }

    private func beatSoon() { Task { @MainActor in try? await Task.sleep(nanoseconds: 200_000_000); beat() } }

    private func handle(_ act: String, _ to: Double?) {
        guard player.currentItem != nil else { return }
        switch act {
        case "pause": player.pause()
        case "resume": player.play()
        case "seek": if let to { seek(to) }
        default: break
        }
        beatSoon()
    }
}

/// 画面（AVPlayerLayer，不带系统的控制条）
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    final class Box: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Box {
        let b = Box()
        b.playerLayer.player = player
        b.playerLayer.videoGravity = .resizeAspect
        b.backgroundColor = .black
        return b
    }

    func updateUIView(_ b: Box, context: Context) { b.playerLayer.player = player }
}

/// 从会话的加号面板、片库、首页进来的那一页：这段会话正在一起看就是放映页，没有就是选片页
struct WatchEntryView: View {
    let chatId: String
    @Environment(\.dismiss) private var dismiss
    @State private var tick = 0

    var body: some View {
        let _ = tick
        NavigationStack {
            Group {
                if Watch.inChat(chatId) { WatchScreen(chatId: chatId) } else { WatchPickView(chatId: chatId) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("返回")
                }
            }
        }
        .eiraLook()
        .onReceive(NotificationCenter.default.publisher(for: .eiraWatchChanged).receive(on: RunLoop.main)) { _ in
            let now = Watch.inChat(chatId)
            if now != lastActive { lastActive = now; tick += 1 }
        }
    }

    @State private var lastActive = false
}

/// 选片页（网页版 WatchPage 的 Picker）：一起看的方式、累积时长、片库
struct WatchPickView: View {
    let chatId: String
    @State private var videos: [VideoLib.Video] = []
    @State private var chat: Chat?
    @State private var char: Character?
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            WatchCfgSection(chatId: chatId, kind: .watch)
            if let char {
                Section {
                    Toggle("这部片它看过", isOn: Binding(get: { char.row.bool("watchedBefore") }, set: { setSeen($0) }))
                } header: { Text("该角色") } footer: {
                    HelpNote("开启后，角色在一起看时知道后续情节，但仍不会说破。关闭则只知道已经播放过的部分。存在角色卡上，对这个角色看的每一部都生效")
                }
            }
            Section("一起看了多久") {
                let t = Watch.totals(chat)
                Text(t.count > 0 ? "和\(char?.displayName ?? "对方")一共看了 \(Watch.fmt(t.seconds))，\(t.count) 次" : "还没有一起看过")
                    .foregroundStyle(Theme.text2)
            }
            if videos.isEmpty {
                Section {
                    EmptyState(title: "片库是空的", desc: "先在片库中添加一部影片并导入字幕，再回到这里开始。")
                    NavigationLink("前往片库") { VideoLibraryView() }
                }
            } else {
                Section {
                    ForEach(videos) { v in
                        Button { start(v) } label: { VideoRowLabel(v: v) }.buttonStyle(.plain)
                    }
                } header: { Text("片库 · \(videos.count) 部") } footer: {
                    HelpNote("角色看不到画面，它读到的是字幕。没有字幕的影片也能一起看，但角色只知道当前进度。", title: "选片")
                }
            }
        }
        .navigationTitle("一起看")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink("片库") { VideoLibraryView() } } }
        .onAppear(perform: load)
    }

    private func load() {
        videos = VideoLib.all()
        chat = try? Repo.chat(chatId)
        char = (chat?.characterIds.first).flatMap { (try? Repo.character($0)) ?? nil }
    }

    private func setSeen(_ v: Bool) {
        guard let id = char?.id else { return }
        do {
            guard var row = try Database.shared.get(Collections.characters, id: id) else { return }
            row["watchedBefore"] = .bool(v)
            row.touch()
            try Database.shared.put(Collections.characters, row)
            load()
        } catch { problem = "未能保存：\(error.localizedDescription)" }
    }

    private func start(_ v: VideoLib.Video) {
        do { try Watch.begin(chatId: chatId, videoId: v.id) } catch { problem = error.localizedDescription }
    }
}

/// 一部片在列表里的那一行：片名、字幕几句、有没有提纲
struct VideoRowLabel: View {
    let v: VideoLib.Video

    private func sub(_ n: Int) -> String {
        guard n > 0 else { return "没有字幕。角色将只知道进度，不知道演了什么" }
        return "字幕 \(n) 句" + (VideoLib.hasOutline(v) ? " · 已有剧情提纲" : "")
    }

    var body: some View {
        let n = VideoLib.lines(v).count
        HStack(spacing: Theme.sp3) {
            SvgIcon(name: "film", size: 18, color: Theme.text2)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.title).lineLimit(2)
                Text(sub(n))
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// 一起看、一起读的两项（网页版 4.932、4.1056），存在会话上
struct WatchCfgSection: View {
    enum Kind { case watch, read }
    let chatId: String
    let kind: Kind
    @State private var how = "online"
    @State private var reply = "auto"
    @State private var problem: String?

    var body: some View {
        Section {
            Picker("方式", selection: Binding(get: { how }, set: { save(how: $0) })) {
                Text(kind == .watch ? "连线一起看" : "连线一起读").tag("online")
                Text(kind == .watch ? "在一起看" : "在一起读").tag("face")
            }
            Picker("回复", selection: Binding(get: { reply }, set: { save(reply: $0) })) {
                Text("发送后立即回复").tag("auto")
                Text("手动触发回复").tag("manual")
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text(kind == .watch ? "一起看的方式" : "一起读的方式")
        } footer: {
            HelpNote("连线：角色知道你们各在各的地方、通过消息聊天。在一起：角色知道你们在同一个地方。手动触发时，发送消息不调用接口；点「让角色回复」调用一次")
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .eiraChatChanged).receive(on: RunLoop.main)) { _ in load() }
    }

    private func load() {
        let c = try? Repo.chat(chatId)
        how = kind == .watch ? Watch.howOf(c) : ReadTogether.howOf(c)
        reply = kind == .watch ? Watch.replyOf(c) : ReadTogether.replyOf(c)
    }

    private func save(how h: String? = nil, reply r: String? = nil) {
        do {
            if kind == .watch { try Watch.setCfg(chatId, how: h, reply: r) } else { try ReadTogether.setCfg(chatId, how: h, reply: r) }
            if let h { how = h }
            if let r { reply = r }
            problem = nil
            NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
        } catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}

/// 一起看、一起读那一页下面的对话：这段会话的文字消息与提示，最近 30 条，往上翻点「查看更早的消息」再多 30 条（网页版 4.1074）
struct TogetherTalk: View {
    let chatId: String
    /// 一起读只列这一场开始之后的（网页版 4.1056）
    var since: Double = 0
    var busy: Bool
    var maxHeight: CGFloat = .infinity
    @State private var msgs: [Message] = []
    @State private var shown = 30
    @State private var total = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.sp2) {
                    if total > msgs.count {
                        Button("查看更早的消息 · 还有 \(total - msgs.count) 条") { shown += 30; load() }
                            .font(.footnote).foregroundStyle(Theme.text2).frame(maxWidth: .infinity)
                    }
                    if msgs.isEmpty && since > 0 { TalkLine(text: "这一场还没有消息", notice: true, me: false) }
                    ForEach(msgs) { m in line(m).id(m.id) }
                    if busy { TalkLine(text: "正在输入", notice: true, me: false).id("busy") }
                }
                .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp2)
            }
            .frame(maxHeight: maxHeight)
            .onAppear { load(); scroll(proxy) }
            .onChange(of: msgs.last?.id) { _, _ in scroll(proxy) }
            .onChange(of: busy) { _, _ in scroll(proxy) }
            .onReceive(NotificationCenter.default.publisher(for: .eiraChatChanged).receive(on: RunLoop.main)) { _ in load() }
        }
    }

    @ViewBuilder private func line(_ m: Message) -> some View {
        if m.kind == "notice" || m.kind == "watch" || m.kind == "read" {
            TalkLine(text: m.content.replacingOccurrences(of: #"^\[|\]$"#, with: "", options: .regularExpression), notice: true, me: false)
        } else {
            let mode = SettingsModel.shared.s.raw["translateShow"]?.string ?? "both"
            let p = MessageActions.transPair(m.kind == "sticker" ? "[表情]" : m.kind == "image" ? "[图片]" : m.content,
                                             m.row.string("translation"), mode: mode)
            TalkLine(text: p.main, sub: p.sub, notice: false, me: m.role == .user)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let id = busy ? "busy" : msgs.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
    }

    /// 读最近一截就够：往上翻一次多读 30 条
    func load() {
        let all = ((try? Repo.messages(chatId: chatId, limit: shown * 3 + 60)) ?? [])
        let talk = all.filter { m in
            guard since <= 0 || m.createdAt >= since, !m.isError, !m.isRecalled else { return false }
            if since > 0 { return ["text", "notice", "sticker", "image", "watch"].contains(m.kind) && (!m.content.isEmpty || m.kind != "text") }
            return m.kind == "text" || m.kind == "notice"
        }
        total = talk.count
        msgs = Array(talk.suffix(shown))
    }
}

struct TalkLine: View {
    let text: String
    var sub: String = ""
    let notice: Bool
    let me: Bool

    var body: some View {
        HStack {
            if me { Spacer(minLength: 40) }
            VStack(alignment: me ? .trailing : .leading, spacing: 2) {
                Text(text).font(.system(size: notice ? 12 : 15)).foregroundStyle(notice ? Theme.text3 : Theme.text)
                if !sub.isEmpty { Text(sub).font(.system(size: 12)).foregroundStyle(Theme.text3) }
            }
            .padding(.horizontal, notice ? 0 : Theme.sp3).padding(.vertical, notice ? 0 : Theme.sp2)
            .background(notice ? Color.clear : (me ? Theme.surface3 : Theme.surface2))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
            if !me { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: notice ? .center : (me ? .trailing : .leading))
    }
}

/// 一行输入：说点什么、发送；手动触发回复时多一个「让角色回复」
struct TogetherInput: View {
    @Binding var draft: String
    var manual: Bool
    var busy: Bool
    var send: () -> Void
    var reply: () -> Void

    var body: some View {
        HStack(spacing: Theme.sp2) {
            TextField("说点什么", text: $draft)
                .textFieldStyle(.plain)
                .padding(.horizontal, Theme.sp3).frame(height: Theme.composerH)
                .background(Theme.surface2).clipShape(Capsule())
                .submitLabel(.send).onSubmit(send)
            Button(action: send) { SvgIcon(name: "send", size: 18) }
                .accessibilityLabel("发送").disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            if manual {
                Button(action: reply) { SvgIcon(name: "message", size: 18) }.accessibilityLabel("让角色回复").disabled(busy)
            }
        }
    }
}

/// 放映页（网页版 WatchPage 的 Screen）：画面、控制条、字幕偏移、对话、输入、方式那一行
struct WatchScreen: View {
    let chatId: String
    @ObservedObject private var wp = WatchPlayer.shared
    @State private var video: VideoLib.Video?
    @State private var draft = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var full = false
    @State private var ending = false
    @State private var chat: Chat?
    @State private var cueNote: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lines = VideoLib.lines(video)
        let cue = Subtitle.cueAt(lines, wp.at)
        let manual = Watch.replyOf(chat) == "manual"
        VStack(spacing: 0) {
            stage(cue: cue)
            bar
            if !lines.isEmpty { sync }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal) }
            TogetherTalk(chatId: chatId, busy: busy)
            TogetherInput(draft: $draft, manual: manual, busy: busy, send: send, reply: talk)
                .padding(.horizontal, Theme.sp4).padding(.top, Theme.sp2)
            modeRow(manual: manual).padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp2)
        }
        .navigationTitle(video?.title ?? "一起看")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("结束") { ending = true } } }
        .confirmationDialog("结束一起看", isPresented: $ending, titleVisibility: .visible) {
            Button("结束", role: .destructive) { Watch.stop(); wp.close() }
        } message: { Text("将记录本次观看的时长与进度。") }
        .navigationDestination(item: $cueNote) { at in
            if let v = video { ParaPageView(subject: ParaNotes.subject(.video, v.id), at: at) }
        }
        .fullScreenCover(isPresented: $full) { WatchFullView(chatId: chatId, busy: $busy, talk: talk, send: sendText) }
        .task {
            chat = try? Repo.chat(chatId)
            let v = Watch.current()
            video = v
            if let v { await wp.open(v) }
        }
        // 每五秒问一次该不该让角色自己开口（判断在 Watch.due，本地算）
        .task(id: chatId) { await WatchAuto.loop(busy: $busy) }
        .onDisappear { if !full { wp.leave() } }
        .onReceive(NotificationCenter.default.publisher(for: .eiraChatChanged).receive(on: RunLoop.main)) { _ in chat = try? Repo.chat(chatId) }
    }

    @ViewBuilder private func stage(cue: Subtitle.Line?) -> some View {
        ZStack(alignment: .bottom) {
            PlayerSurface(player: wp.player)
                .onTapGesture { wp.toggle() }
            VStack(spacing: Theme.sp1) {
                if !wp.problem.isEmpty {
                    Text(wp.problem).font(.system(size: 12)).foregroundStyle(.white).padding(Theme.sp2)
                        .background(Color.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                }
                if let cue, let v = video { CueLine(cue: cue, subject: ParaNotes.subject(.video, v.id)) { cueNote = Int(cue.at.rounded()) } }
            }
            .padding(Theme.sp2)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color.black)
    }

    private var bar: some View {
        HStack(spacing: Theme.sp3) {
            Button { full = true } label: { SvgIcon(name: "maximize", size: 18) }.accessibilityLabel("全屏")
            Button { wp.toggle() } label: { SvgIcon(name: wp.playing ? "pause" : "play", size: 19) }.accessibilityLabel(wp.playing ? "暂停" : "播放")
            Button { wp.seek(wp.at - 15) } label: { SvgIcon(name: "skipPrev", size: 19) }.accessibilityLabel("后退十五秒")
            Slider(value: Binding(get: { wp.duration > 0 ? min(wp.at, wp.duration) : 0 }, set: { wp.seek($0) }),
                   in: 0...max(1, wp.duration))
            Text(Subtitle.stamp(wp.at)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.text2)
        }
        .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp2)
    }

    /// 字幕对不上是常事，而且只有正在看的时候才发现：调整放在这一屏上，改完立刻生效（偏移是读出来的时候才加的）
    private var sync: some View {
        let off = VideoLib.offset(video)
        return HStack(spacing: Theme.sp3) {
            Text("字幕").foregroundStyle(Theme.text2)
            Button("提前") { nudge(-0.5) }.accessibilityLabel("字幕提前半秒")
            Text(VideoLib.signed(off) + " 秒").monospacedDigit()
            Button("推迟") { nudge(0.5) }.accessibilityLabel("字幕推迟半秒")
            if off != 0 { Button("归零") { nudge(-off) } }
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, Theme.sp4)
    }

    private func nudge(_ d: Double) {
        guard let v = video else { return }
        do { video = try VideoLib.update(v.id, .init(offset: VideoLib.offset(v) + d)) }
        catch { problem = error.localizedDescription }
    }

    private func modeRow(manual: Bool) -> some View {
        HStack(spacing: Theme.sp3) {
            Text("\(Watch.howOf(chat) == "face" ? "在一起看" : "连线一起看") · \(manual ? "手动触发回复" : "发送后立即回复")")
                .foregroundStyle(Theme.text2)
            Spacer()
            Button("切换方式") { cfg(how: Watch.howOf(chat) == "face" ? "online" : "face") }
            Button(manual ? "改为立即回复" : "改为手动回复") { cfg(reply: manual ? "auto" : "manual") }
        }
        .font(.system(size: 12))
    }

    private func cfg(how: String? = nil, reply: String? = nil) {
        do { try Watch.setCfg(chatId, how: how, reply: reply); chat = try Repo.chat(chatId) }
        catch { problem = "未能保存：\(error.localizedDescription)" }
    }

    private func send() { sendText(draft); draft = "" }

    private func sendText(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        do {
            _ = try ChatEngine.send(text: t, chatId: chatId)
            NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
        } catch { problem = "消息未能保存：\(error.localizedDescription)"; return }
        // 手动触发（4.932）：发出去只是发出去，攒几条再点「让角色回复」
        if Watch.replyOf(chat) != "manual" { talk() }
    }

    private func talk() {
        guard !busy else { return }
        busy = true
        problem = nil
        Task {
            do { try await Watch.talk(chatId: chatId) { _ in } }
            catch { problem = error.localizedDescription }
            busy = false
            NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
        }
    }
}

/// 画面底下那一句台词，旁边一个评论这一句的小气泡（段评挂在这一句的起始秒上）
struct CueLine: View {
    let cue: Subtitle.Line
    let subject: String
    var open: () -> Void

    var body: some View {
        let n = ParaNotes.list(subject, at: Int(cue.at.rounded())).count
        HStack(spacing: Theme.sp2) {
            Text(cue.text).font(.system(size: 14)).foregroundStyle(.white).multilineTextAlignment(.center)
            Button(action: open) {
                Group {
                    if n > 0 { Text(n > 99 ? "99" : "\(n)").font(.system(size: 10, weight: .semibold)) }
                    else { SvgIcon(name: "message", size: 11, color: .white) }
                }
                .foregroundStyle(.white).frame(width: 20, height: 20)
                .background(Color.white.opacity(n > 0 ? 0.3 : 0.15)).clipShape(Circle())
            }
            .accessibilityLabel(n > 0 ? "这一句有 \(n) 条评论" : "评论这一句")
        }
        .padding(.horizontal, Theme.sp2).padding(.vertical, Theme.sp1)
        .background(Color.black.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
    }
}

/// 全屏（网页版 4.889）：只剩画面；点一下叫出控制条与输入，消息改成弹幕从右往左飘过画面上部。
/// 默认按「向左转」横过来（settings.watchRotate：90 向左、-90 向右、0 不转，与网页版同一个键）
struct WatchFullView: View {
    let chatId: String
    @Binding var busy: Bool
    var talk: () -> Void
    var send: (String) -> Void
    @ObservedObject private var wp = WatchPlayer.shared
    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var panel = false
    @State private var draft = ""
    @State private var flying: [Flying] = []
    @State private var seen: Set<String>?
    @State private var lane = 0

    struct Flying: Identifiable, Equatable { var id: String; var text: String; var me: Bool; var lane: Int }

    private var rot: Double {
        let v = model.s.raw["watchRotate"]?.number ?? (model.s.raw["watchLandscape"]?.bool == false ? 0 : 90)
        return v == 90 || v == -90 ? v : 0
    }
    private var danmaku: Bool { model.s.raw["watchDanmaku"]?.bool != false }

    var body: some View {
        GeometryReader { g in
            let w = rot == 0 ? g.size.width : g.size.height
            let h = rot == 0 ? g.size.height : g.size.width
            ZStack {
                Color.black
                PlayerSurface(player: wp.player)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { panel.toggle() } }
                if danmaku { lanes(width: w) }
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            SvgIcon(name: "close", size: 18, color: .white).frame(width: 36, height: 36)
                                .background(Color.black.opacity(0.4)).clipShape(Circle())
                        }
                        .accessibilityLabel("退出全屏")
                        Spacer()
                    }
                    Spacer()
                    if let v = Watch.current(), let cue = Subtitle.cueAt(VideoLib.lines(v), wp.at) {
                        Text(cue.text).font(.system(size: 15)).foregroundStyle(.white).padding(.horizontal, Theme.sp2)
                            .background(Color.black.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
                    }
                    if panel { controls }
                }
                .padding(Theme.sp4)
            }
            .frame(width: w, height: h)
            .rotationEffect(.degrees(rot))
            .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .onAppear { seen = Set(recent().map(\.id)) }
        .task(id: chatId) { await WatchAuto.loop(busy: $busy) }
        .onReceive(NotificationCenter.default.publisher(for: .eiraChatChanged).receive(on: RunLoop.main)) { _ in fly() }
    }

    private func recent() -> [Message] { (try? Repo.messages(chatId: chatId, limit: 20)) ?? [] }

    /// 进全屏之后新来的每一条（双方的）从右往左飘过，五条轨道轮流用
    private func fly() {
        guard var s = seen else { return }
        let fresh = recent().filter { !s.contains($0.id) }
        for m in fresh { s.insert(m.id) }
        seen = s
        guard danmaku else { return }
        let mode = model.s.raw["translateShow"]?.string ?? "both"
        for m in fresh where m.kind == "text" && !m.content.trimmingCharacters(in: .whitespaces).isEmpty {
            let text = MessageActions.transPair(m.content, m.row.string("translation"), mode: mode).main
            flying.append(Flying(id: m.id, text: text, me: m.role == .user, lane: lane % 5))
            lane += 1
        }
    }

    private func lanes(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(flying) { f in
                DanmakuItem(text: f.text, me: f.me, width: width) { flying.removeAll { $0.id == f.id } }
                    .offset(y: 44 + CGFloat(f.lane) * 30)
            }
            if busy { Text("正在输入").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).offset(x: 12, y: 200) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var controls: some View {
        VStack(spacing: Theme.sp2) {
            HStack(spacing: Theme.sp4) {
                Button { wp.toggle() } label: { SvgIcon(name: wp.playing ? "pause" : "play", size: 18, color: .white) }.accessibilityLabel(wp.playing ? "暂停" : "播放")
                Button { wp.seek(wp.at - 15) } label: { SvgIcon(name: "skipPrev", size: 18, color: .white) }.accessibilityLabel("后退十五秒")
                Text(Subtitle.stamp(wp.at)).font(.system(size: 12).monospacedDigit())
                Button(action: talk) { SvgIcon(name: "message", size: 18, color: .white) }.accessibilityLabel("让角色说一句").disabled(busy)
                Button { model.set("watchDanmaku", .bool(!danmaku)) } label: { SvgIcon(name: "forum", size: 18, color: .white).opacity(danmaku ? 1 : 0.5) }
                    .accessibilityLabel(danmaku ? "关闭弹幕" : "开启弹幕")
                Button { turn(90) } label: { SvgIcon(name: "rotateLeft", size: 18, color: .white).opacity(rot == 90 ? 1 : 0.6) }
                    .accessibilityLabel(rot == 90 ? "转回竖屏" : "向左转")
                Button { turn(-90) } label: { SvgIcon(name: "rotateRight", size: 18, color: .white).opacity(rot == -90 ? 1 : 0.6) }
                    .accessibilityLabel(rot == -90 ? "转回竖屏" : "向右转")
            }
            HStack(spacing: Theme.sp2) {
                TextField("说点什么", text: $draft).textFieldStyle(.plain)
                    .padding(.horizontal, Theme.sp3).frame(height: 34)
                    .background(Color.white.opacity(0.15)).clipShape(Capsule())
                    .submitLabel(.send).onSubmit { send(draft); draft = "" }
                Button { send(draft); draft = "" } label: { SvgIcon(name: "send", size: 18, color: .white) }.accessibilityLabel("发送")
            }
        }
        .foregroundStyle(.white)
        .padding(Theme.sp3)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
    }

    private func turn(_ v: Double) { model.set("watchRotate", .number(rot == v ? 0 : v)) }
}

/// 一条弹幕：从右边进来，八秒飘到左边，飘完自己删掉
struct DanmakuItem: View {
    let text: String
    let me: Bool
    let width: CGFloat
    var done: () -> Void
    @State private var x: CGFloat = 0

    var body: some View {
        Text(text).font(.system(size: 15, weight: me ? .semibold : .regular)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .fixedSize()
            .offset(x: x)
            .onAppear {
                x = width
                withAnimation(.linear(duration: 8)) { x = -width }
                Task { try? await Task.sleep(nanoseconds: 8_200_000_000); done() }
            }
    }
}

/// 放映页开着时每五秒问一次 Watch.due()（网页版 WatchPage 的 setInterval），到点才让角色说一句。页面关了就停
@MainActor
enum WatchAuto {
    static func loop(busy: Binding<Bool>) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { break }
            guard !busy.wrappedValue, Watch.due() else { continue }
            busy.wrappedValue = true
            await Watch.autoTurn { _ in }
            busy.wrappedValue = false
            NotificationCenter.default.post(name: .eiraChatChanged, object: Watch.state.chatId)
        }
    }
}
