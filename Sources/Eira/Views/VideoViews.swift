import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 片库（网页版 theater/VideosPage）：片子要么一个地址，要么一个本机文件，要么 B 站的一部。
/// 比曲库多两样：字幕（角色唯一读得到的东西）与剧情提纲（一部片一次调用，用户点了才调）。
struct VideoLibraryView: View {
    @State private var list: [VideoLib.Video] = []
    @State private var busy = ""
    @State private var problem: String?
    @State private var notice: String?
    @State private var editing: EditTarget?
    @State private var startRow: VideoLib.Video?
    @State private var dropping: VideoLib.Video?
    @State private var watchChat: WatchTarget?
    @State private var reviews: String?

    struct EditTarget: Identifiable { var id: String; var videoId: String? }

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
            Section {
                NavigationLink { BiliHomeView() } label: { TogetherRow(icon: "search", title: "从 B 站添加", sub: "") }
            } footer: {
                HelpNote("搜索 B 站视频或粘贴链接，加入片库时自动读取字幕。可以扫码登录哔哩哔哩，登录后能读取 AI 字幕", title: "从 B 站添加")
            }
            if list.isEmpty {
                Section {
                    EmptyState(title: "片库是空的", desc: "可选择本机视频、填写播放地址或从 B 站添加，并为其导入字幕。")
                    Button("添加影片") { editing = EditTarget(id: "new", videoId: nil) }
                }
            } else {
                Section {
                    ForEach(list) { v in row(v) }
                } header: { Text("共 \(list.count) 部") } footer: {
                    Text("剧情提纲需要调用一次模型接口，读完整份字幕后按时间切分。观看时只注入已经播放过的段落，尚未演到的部分不会出现在角色可见的内容中。")
                }
            }
        }
        .navigationTitle("片库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("添加") { editing = EditTarget(id: "new", videoId: nil) } } }
        .sheet(item: $editing, onDismiss: load) { t in NavigationStack { VideoEditView(videoId: t.videoId) }.eiraLook() }
        .sheet(item: $startRow) { v in
            CharPickSheet(title: "和谁一起看《\(v.title)》") { c in
                startRow = nil
                StartWatch.begin(v, with: c) { id in watchChat = WatchTarget(id: id) } failed: { problem = $0 }
            }
        }
        .fullScreenCover(item: $watchChat, onDismiss: load) { t in WatchEntryView(chatId: t.id) }
        .navigationDestination(item: $reviews) { id in ReviewsView(kind: .video, subjectId: id) }
        .confirmationDialog("从片库移除", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }), titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                if let v = dropping { do { try VideoLib.remove(v.id); load() } catch { problem = error.localizedDescription } }
                dropping = nil
            }
        } message: { Text("将移除「\(dropping?.title ?? "")」，挂在它台词上的段评一并删除。") }
        .onAppear(perform: load)
    }

    private func row(_ v: VideoLib.Video) -> some View {
        let n = VideoLib.lines(v).count
        let segs = v.outline.count
        let off = VideoLib.offset(v)
        let revs = Reviews.count(.video, v.id)
        let sub = [v.bili != nil ? "B 站" : "", n > 0 ? "字幕 \(n) 句" : "没有字幕",
                   off != 0 ? "偏移 \(off > 0 ? "+" : "")\(String(format: "%g", off)) 秒" : "",
                   segs > 0 ? "提纲 \(segs) 段" : "未生成提纲", revs > 0 ? "影评 \(revs) 篇" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(spacing: Theme.sp3) {
            TogetherRow(icon: "film", title: v.title, sub: busy == v.id ? "正在生成提纲" : sub)
            Button("一起看") { startRow = v }.buttonStyle(.borderless).font(.footnote)
            Menu {
                if VideoLib.canOutline(v) {
                    Button(VideoLib.hasOutline(v) ? "重新生成提纲" : "生成提纲") { outline(v) }.disabled(!busy.isEmpty)
                }
                Button("影评") { reviews = v.id }
                Button("编辑") { editing = EditTarget(id: v.id, videoId: v.id) }
                Button("移除", role: .destructive) { dropping = v }
            } label: { SvgIcon(name: "more", size: 18, color: Theme.text2).frame(width: 32, height: 32) }
            .accessibilityLabel("更多")
        }
    }

    private func load() { list = VideoLib.all() }

    private func outline(_ v: VideoLib.Video) {
        busy = v.id
        problem = nil
        Task {
            do { let segs = try await VideoLib.generateOutline(v.id); notice = "已生成 \(segs.count) 段剧情提纲" }
            catch { problem = error.localizedDescription }
            busy = ""
            load()
        }
    }
}

/// 从相册选的视频：抄进临时目录再交出来
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in SentTransferredFile(m.url) } importing: { r in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (r.file.pathExtension.isEmpty ? "mov" : r.file.pathExtension))
            try FileManager.default.copyItem(at: r.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}

/// 添加、编辑一部片（网页版 VideosPage 的 EditSheet）。表里是草稿，按了保存才算数
struct VideoEditView: View {
    let videoId: String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""
    @State private var fileId = ""
    @State private var fileName = ""
    @State private var subtitle = ""
    @State private var offset = 0.0
    @State private var bili: VideoLib.Bili?
    @State private var reading = false
    @State private var picking = false
    @State private var subPicking = false
    @State private var photo: PhotosPickerItem?
    @State private var problem: String?
    @State private var notice: String?
    @State private var loaded = false

    var body: some View {
        let count = Subtitle.parse(subtitle).count
        let fromBili = bili != nil && url.trimmingCharacters(in: .whitespaces).isEmpty && fileId.isEmpty
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
            Section("片名") { TextField("片名", text: $title) }
            if fromBili, let b = bili {
                Section("来源") {
                    Text("B 站 \(b.bvid)" + (b.part.isEmpty ? "" : " · \(b.part)")).foregroundStyle(Theme.text2)
                }
            }
            Section {
                TextField("https://...", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onChange(of: url) { _, v in if !v.isEmpty { fileId = ""; fileName = "" } }
            } header: { Text("播放地址") } footer: {
                HelpNote("直接指向视频文件的地址。地址与本机文件二选一，填了地址则不需要选择文件。B 站的片填写地址或选择本机文件后，不再从 B 站播放。")
            }
            Section {
                Text(!fileName.isEmpty ? "已选择：\(fileName)" : !fileId.isEmpty ? "已有视频文件。重新选择将替换它。" : "文件保存在本机，不会上传到任何服务器。")
                    .font(.footnote).foregroundStyle(Theme.text2)
                PhotosPicker(selection: $photo, matching: .videos) { Text("从相册选择") }
                Button("从文件选择") { picking = true }
                if !fileId.isEmpty { Button("移除", role: .destructive) { fileId = ""; fileName = "" } }
            } header: { Text("本机视频") }
            Section {
                TextEditor(text: $subtitle).frame(minHeight: 140).font(.system(size: 13).monospaced())
                Button("导入字幕文件") { subPicking = true }
                if !fileId.isEmpty { Button(reading ? "读取中" : "从视频中读取") { readEmbedded() }.disabled(reading) }
                if fromBili { Button(reading ? "读取中" : "从 B 站重新读取") { rereadBili() }.disabled(reading) }
            } header: { Text("字幕") } footer: {
                Text("支持 SRT、ASS 与 WebVTT。\(count > 0 ? "当前已识别 \(count) 句。" : "")选择 MP4 或 MOV 时会自动读取其内封字幕轨，读不到则需自行导入。角色看不到画面，台词是它唯一能读到的内容。")
            }
            Section {
                Stepper("字幕偏移：\(offset > 0 ? "+" : "")\(String(format: "%g", offset)) 秒", value: $offset, in: -60...60, step: 0.5)
            } footer: {
                HelpNote("字幕整体提前或推迟这么多秒，用于字幕与手中片源版本不一致的情况。正数表示字幕推迟出现，负数表示提前。观看时也可以随时调整。", title: "字幕偏移")
            }
            Section {
                Button(videoId == nil ? "添加" : "保存", action: save)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || (url.trimmingCharacters(in: .whitespaces).isEmpty && fileId.isEmpty && bili == nil))
            } footer: {
                if videoId != nil { Text("更换字幕后，原有的剧情提纲会一并作废，需要重新生成。") }
            }
        }
        .navigationTitle(videoId == nil ? "添加影片" : "编辑影片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .documentPicker(isPresented: $picking, types: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { urls in
            if let u = urls.first { take(u) }
        }
        .documentPicker(isPresented: $subPicking, types: [.plainText, .text, .data]) { urls in
            guard let u = urls.first else { return }
            subtitle = DocText.plain((try? Data(contentsOf: u)) ?? Data())
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                do {
                    if let m = try await item.loadTransferable(type: PickedMovie.self) { take(m.url) }
                } catch { problem = "读不出这段视频：\(error.localizedDescription)" }
                photo = nil
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let id = videoId, let v = VideoLib.get(id) else { return }
        title = v.title
        url = v.url
        fileId = v.fileId
        subtitle = v.subtitle
        offset = VideoLib.offset(v)
        bili = v.bili
    }

    /// 选好一个视频文件：拷进本机文件域；片子自己带字幕就不必再去找一份（读不到不吭声）
    private func take(_ src: URL) {
        let ext = src.pathExtension
        if VideoLib.needsConvert(ext) { notice = "\(src.lastPathComponent) 的格式本机无法播放，需要先转换为 MP4 再导入。仍然保存时，很可能无法播放。" }
        do {
            let id = try VideoLib.saveFile(from: src)
            fileId = id
            fileName = src.lastPathComponent
            url = ""
            if title.trimmingCharacters(in: .whitespaces).isEmpty { title = src.deletingPathExtension().lastPathComponent }
            if subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let u = MediaStore.url(.files, id: id) {
                Task {
                    if let got = await VideoLib.subtitleFromFile(u) { subtitle = got.srt; notice = "已从视频中读出 \(got.lines) 句字幕" }
                }
            }
        } catch { problem = error.localizedDescription }
    }

    private func readEmbedded() {
        guard let u = MediaStore.url(.files, id: fileId) else { problem = "找不到这个视频文件"; return }
        reading = true
        Task {
            if let got = await VideoLib.subtitleFromFile(u) {
                subtitle = got.srt
                notice = "已读出 \(got.lines) 句" + (got.tracks > 1 ? "，共 \(got.tracks) 轨" : "")
            } else {
                notice = "该文件中没有可直接读取的字幕轨。可以另外导入 SRT、VTT 或 ASS 字幕文件"
            }
            reading = false
        }
    }

    /// B 站的片：重新读一次字幕（当初没登录、读不到 AI 字幕的，登录后可以再读）
    private func rereadBili() {
        guard let b = bili else { return }
        reading = true
        Task {
            do {
                if let t = BiliApi.pickTrack(try await BiliApi.subtitleTracks(b.bvid, cid: b.cid)) {
                    let srt = try await BiliApi.subtitleSrt(t)
                    subtitle = srt
                    notice = "已读出 \(Subtitle.parse(srt).count) 句（\(t.label)）"
                } else {
                    notice = BiliApi.loggedIn() ? "该视频没有字幕" : "该视频没有公开字幕；在「从 B 站添加」中登录后可以读取 AI 字幕"
                }
            } catch { problem = error.localizedDescription }
            reading = false
        }
    }

    private func save() {
        do {
            if let id = videoId {
                try VideoLib.update(id, .init(title: title, offset: offset, subtitle: subtitle, url: url, fileId: fileId))
            } else {
                let v = try VideoLib.add(title: title, url: url, fileId: fileId, subtitle: subtitle)
                if offset != 0 { try VideoLib.update(v.id, .init(offset: offset)) }
            }
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

// MARK: - B 站

/// 从 B 站找片（网页版 BiliPage，4.883、4.885）：登录、搜索、贴链接、最近观看、稍后再看、收藏夹都在这一页。
/// 选中一部读一次视频信息（分 P 的先选一 P），能取到字幕就一并取来，存进片库
struct BiliHomeView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var tab = "search"
    @State private var q = ""
    @State private var hits: [BiliApi.Hit]?
    @State private var history: [BiliApi.Hit]?
    @State private var next: BiliApi.Cursor?
    @State private var later: [BiliApi.Hit]?
    @State private var folders: [BiliApi.Folder]?
    @State private var busy = ""
    @State private var problem: String?
    @State private var notice: String?
    @State private var login = false
    @State private var loggingOut = false
    @State private var parts: BiliApi.Info?

    var body: some View {
        let logged = BiliApi.loggedIn(model.s)
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
            Section {
                if logged {
                    Button { loggingOut = true } label: { LabeledContent("哔哩哔哩账号", value: BiliApi.nick(model.s).isEmpty ? "已登录" : BiliApi.nick(model.s)) }
                } else {
                    Button { login = true } label: { LabeledContent("登录哔哩哔哩", value: "未登录") }
                }
            } footer: {
                HelpNote("不登录也可以搜索与播放；AI 字幕需要登录后才能读取，清晰度也更高。扫码登录，凭据只保存在这台设备上，请求从这台设备直接发往 B 站，不经过任何服务器。")
            }
            Section {
                Picker("", selection: $tab) {
                    Text("搜索").tag("search")
                    Text("最近观看").tag("history")
                    Text("稍后再看").tag("later")
                    Text("收藏夹").tag("fav")
                }
                .pickerStyle(.segmented)
                .onChange(of: tab) { _, t in fetchIfNeeded(t) }
            }
            if tab == "search" {
                Section {
                    HStack {
                        TextField("搜索视频，或粘贴 B 站链接、BV 号", text: $q).submitLabel(.search).onSubmit(go)
                        Button(busy == "search" ? "搜索中" : "搜索", action: go).disabled(q.trimmingCharacters(in: .whitespaces).isEmpty || !busy.isEmpty)
                    }
                }
                if let hits { hitList("搜索结果 · \(hits.count) 条", hits, empty: "没有搜到结果") }
            } else if !logged {
                Section {
                    EmptyState(title: "需要登录哔哩哔哩", desc: "登录后可以查看自己的最近观看、稍后再看与收藏夹。")
                    Button("登录") { login = true }
                }
            } else if tab == "history" {
                if let history {
                    hitList("最近观看 · 已读取 \(history.count) 条", history, empty: "没有观看记录",
                            more: next != nil ? { fetch("history", more: true) } : nil)
                } else { loadingRow }
            } else if tab == "later" {
                if let later { hitList("稍后再看 · \(later.count) 个", later, empty: "稍后再看是空的") } else { loadingRow }
            } else if let folders {
                Section("收藏夹 · \(folders.count) 个") {
                    if folders.isEmpty { Text("没有收藏夹").foregroundStyle(Theme.text2) }
                    ForEach(folders) { f in
                        NavigationLink { BiliFavView(folder: f) } label: { LabeledContent(f.title, value: "\(f.count) 个") }
                    }
                }
            } else { loadingRow }
            if tab != "search" && logged {
                Section { Button("刷新") { fetch(tab) }.disabled(!busy.isEmpty) }
            }
            Section {} footer: {
                Text("加入片库时读取一次视频信息与字幕，播放地址在开始播放时读取。大会员专享与有版权限制的视频无法播放。")
            }
        }
        .navigationTitle("从 B 站添加")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $login, onDismiss: { model.reload() }) { NavigationStack { BiliLoginView { login = false } }.eiraLook() }
        .confirmationDialog("退出登录", isPresented: $loggingOut, titleVisibility: .visible) {
            Button("退出", role: .destructive) {
                do { try BiliApi.logout(); model.reload(); history = nil; later = nil; folders = nil; tab = "search" }
                catch { problem = error.localizedDescription }
            }
        } message: { Text("将删除这台设备上保存的哔哩哔哩登录凭据。片库中已加入的影片不受影响。") }
        .confirmationDialog("选择分 P", isPresented: Binding(get: { parts != nil }, set: { if !$0 { parts = nil } }), titleVisibility: .visible) {
            if let info = parts {
                ForEach(Array(info.pages.enumerated()), id: \.offset) { i, p in
                    Button("P\(i + 1) \(p.part) · \(Subtitle.stamp(p.seconds))") { addPage(info, p) }
                }
            }
        }
    }

    private var loadingRow: some View {
        Section { Text(busy == "load" ? "正在读取" : "尚未读取").foregroundStyle(Theme.text2) }
    }

    @ViewBuilder private func hitList(_ title: String, _ list: [BiliApi.Hit], empty: String, more: (() -> Void)? = nil) -> some View {
        Section(title) {
            if list.isEmpty { Text(empty).foregroundStyle(Theme.text2) }
            ForEach(list) { h in
                HStack(spacing: Theme.sp3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.title).lineLimit(2)
                        Text([h.author, h.part, h.seconds > 0 ? Subtitle.stamp(h.seconds) : "",
                              h.progress > 0 && h.seconds > 0 ? "看到 \(Subtitle.stamp(h.progress))" : "",
                              h.plays > 0 ? (h.plays >= 10000 ? String(format: "%.1f 万次播放", h.plays / 10000) : "\(Int(h.plays)) 次播放") : ""]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                    Spacer(minLength: 0)
                    Button(busy == h.bvid ? "加入中" : "加入片库") { add(h.bvid) }.buttonStyle(.borderless).font(.footnote).disabled(!busy.isEmpty)
                }
            }
            if let more { Button(busy == "more" ? "加载中" : "加载更多", action: more).disabled(!busy.isEmpty) }
        }
    }

    private func go() {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, busy.isEmpty else { return }
        busy = "search"
        problem = nil
        Task {
            do {
                // 贴的是链接或 BV 号：直接加这一部
                let bv = try await BiliApi.bvidOf(t)
                if !bv.isEmpty { busy = ""; add(bv); q = ""; return }
                hits = try await BiliApi.search(t)
            } catch { problem = error.localizedDescription }
            busy = ""
        }
    }

    private func add(_ bvid: String) {
        guard busy.isEmpty else { return }
        busy = bvid
        problem = nil
        Task {
            do {
                let info = try await BiliApi.view(bvid)
                if info.pages.count > 1 { parts = info; busy = ""; return }
                if let p = info.pages.first { try await finish(info, p) }
            } catch { problem = error.localizedDescription }
            busy = ""
        }
    }

    private func addPage(_ info: BiliApi.Info, _ p: BiliApi.Info.Page) {
        parts = nil
        busy = info.bvid
        Task {
            do { try await finish(info, p) } catch { problem = error.localizedDescription }
            busy = ""
        }
    }

    private func finish(_ info: BiliApi.Info, _ p: BiliApi.Info.Page) async throws {
        let r = try await BiliApi.add(info, page: p)
        notice = r.lines > 0 ? "已加入片库，字幕 \(r.lines) 句。在片库中点「一起看」开始播放"
            : "已加入片库。\(r.why)。在片库中点「一起看」开始播放"
    }

    private func fetchIfNeeded(_ t: String) {
        switch t {
        case "history": if history == nil { fetch(t) }
        case "later": if later == nil { fetch(t) }
        case "fav": if folders == nil { fetch(t) }
        default: break
        }
    }

    private func fetch(_ t: String, more: Bool = false) {
        guard BiliApi.loggedIn(), busy.isEmpty else { return }
        busy = more ? "more" : "load"
        Task {
            do {
                switch t {
                case "history":
                    let r = try await BiliApi.history(more ? next : nil)
                    let have = more ? (history ?? []) : []
                    let seen = Set(have.map(\.bvid))
                    history = have + r.items.filter { !seen.contains($0.bvid) }
                    next = r.next
                case "later": later = try await BiliApi.toView()
                case "fav": folders = try await BiliApi.favFolders()
                default: break
                }
            } catch { problem = error.localizedDescription }
            busy = ""
        }
    }
}

/// 一个收藏夹里的视频，一页 20 个，点「加载更多」再取一页
struct BiliFavView: View {
    let folder: BiliApi.Folder
    @State private var items: [BiliApi.Hit]?
    @State private var page = 0
    @State private var more = false
    @State private var busy = ""
    @State private var problem: String?
    @State private var notice: String?
    @State private var parts: BiliApi.Info?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
            if let items {
                Section("已读取 \(items.count) 个") {
                    if items.isEmpty { Text("这个收藏夹里没有可以播放的视频").foregroundStyle(Theme.text2) }
                    ForEach(items) { h in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.title).lineLimit(2)
                                Text([h.author, h.seconds > 0 ? Subtitle.stamp(h.seconds) : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(Theme.text2)
                            }
                            Spacer(minLength: 0)
                            Button(busy == h.bvid ? "加入中" : "加入片库") { add(h.bvid) }.buttonStyle(.borderless).font(.footnote).disabled(!busy.isEmpty)
                        }
                    }
                    if more { Button(busy == "more" ? "加载中" : "加载更多") { load(page + 1) }.disabled(!busy.isEmpty) }
                }
            } else {
                Text("正在读取").foregroundStyle(Theme.text2)
            }
        }
        .navigationTitle(folder.title.isEmpty ? "收藏夹" : folder.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if items == nil { load(1) } }
        .confirmationDialog("选择分 P", isPresented: Binding(get: { parts != nil }, set: { if !$0 { parts = nil } }), titleVisibility: .visible) {
            if let info = parts {
                ForEach(Array(info.pages.enumerated()), id: \.offset) { i, p in
                    Button("P\(i + 1) \(p.part) · \(Subtitle.stamp(p.seconds))") { finish(info, p) }
                }
            }
        }
    }

    private func load(_ pn: Int) {
        busy = pn == 1 ? "load" : "more"
        Task {
            do {
                let r = try await BiliApi.favItems(folder.id, page: pn)
                let have = pn == 1 ? [] : (items ?? [])
                let seen = Set(have.map(\.bvid))
                items = have + r.items.filter { !seen.contains($0.bvid) }
                page = pn
                more = r.more
            } catch {
                problem = error.localizedDescription
                if pn == 1 { items = [] }
            }
            busy = ""
        }
    }

    private func add(_ bv: String) {
        busy = bv
        Task {
            do {
                let info = try await BiliApi.view(bv)
                if info.pages.count > 1 { parts = info } else if let p = info.pages.first { finish(info, p) }
            } catch { problem = error.localizedDescription }
            busy = ""
        }
    }

    private func finish(_ info: BiliApi.Info, _ p: BiliApi.Info.Page) {
        parts = nil
        Task {
            do {
                let r = try await BiliApi.add(info, page: p)
                notice = r.lines > 0 ? "已加入片库，字幕 \(r.lines) 句" : "已加入片库。\(r.why)"
            } catch { problem = error.localizedDescription }
        }
    }
}

/// 扫码登录哔哩哔哩（网页版 BiliLoginPage 与 ui/qrlogin.js）
struct BiliLoginView: View {
    var onDone: () -> Void
    @State private var status = "正在取二维码"
    @State private var image: UIImage?
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
            } header: { Text("扫码登录") } footer: {
                HelpNote("请使用哔哩哔哩 App 扫描二维码并确认。登录后可以读取 AI 字幕，清晰度也更高。登录凭据只保存在这台设备上，请求从这台设备直接发往 B 站，不经过任何服务器。")
            }
        }
        .navigationTitle("登录哔哩哔哩")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { onDone() } } }
        .onAppear(perform: start)
        .onDisappear { job?.cancel() }
    }

    private func start() {
        job?.cancel()
        job = Task {
            do {
                let r = try await BiliApi.qrStart()
                image = qr(r.url)
                status = "等待扫码"
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let c = try await BiliApi.qrCheck(r.key)
                    switch c.code {
                    case 800: status = "二维码已过期"; start(); return
                    case 802: status = "已扫码，请在手机上确认"
                    case 803:
                        let nick = try await BiliApi.saveLogin(c.cookie)
                        status = "已登录：\(nick)"
                        onDone()
                        return
                    default: break
                    }
                }
            } catch is CancellationError {
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
