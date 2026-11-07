import SwiftUI
import UniformTypeIdentifiers

/// 书库（网页版 theater/BooksPage）：导入 txt 或 epub，先读出来给你看一眼，确认了再入库
struct BookLibraryView: View {
    @State private var books: [Books.Book] = []
    @State private var picking = false
    @State private var parsing = false
    @State private var parsed: ParsedTarget?
    @State private var dropping: Books.Book?
    @State private var problem: String?

    struct ParsedTarget: Identifiable { let id = UUID(); var p: Books.Parsed }

    static let types: [UTType] = [.plainText, .text] + [UTType(filenameExtension: "epub")].compactMap { $0 }

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if parsing { Text("正在读取文件").foregroundStyle(Theme.text2) }
            if books.isEmpty {
                Section {
                    EmptyState(title: "书库是空的", desc: "导入一本 txt 或 epub。导入之后可以自己读，也可以与角色一起读。")
                    Button("导入书籍") { picking = true }
                }
            } else {
                Section("共 \(books.count) 本") {
                    ForEach(books) { b in
                        NavigationLink { BookDetailView(bookId: b.id) } label: { BookRow(b: b) }
                            .swipeActions { Button("删除", role: .destructive) { dropping = b } }
                    }
                }
            }
        }
        .navigationTitle("书库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("导入") { picking = true } } }
        .documentPicker(isPresented: $picking, types: Self.types) { urls in
            guard let u = urls.first else { return }
            parsing = true
            problem = nil
            Task.detached {
                let r = Result { try Books.parse(u) }
                await MainActor.run {
                    parsing = false
                    switch r {
                    case .success(let p): parsed = ParsedTarget(p: p)
                    case .failure(let e): problem = e.localizedDescription
                    }
                }
            }
        }
        .sheet(item: $parsed, onDismiss: load) { t in NavigationStack { BookAddView(parsed: t.p) }.eiraLook() }
        .confirmationDialog("删除《\(dropping?.title ?? "")》", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let b = dropping { do { try Books.remove(b.id); load() } catch { problem = error.localizedDescription } }
                dropping = nil
            }
        } message: { Text("阅读进度与这本书的段评一并删除。") }
        .onAppear(perform: load)
    }

    private func load() { books = Books.all() }
}

struct BookRow: View {
    let b: Books.Book

    static func meta(_ b: Books.Book) -> String {
        var bits: [String] = []
        if !b.author.isEmpty { bits.append(b.author) }
        bits.append("\(b.chars) 字")
        bits.append("\(b.chapters.count) 章")
        if b.at > 0 { bits.append("读到 \(Books.percent(b))%") }
        return bits.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Theme.sp3) {
            // 有封面才画；没有就收成紧凑的一行，不画空框占位
            if !b.cover.isEmpty {
                LocalImage(id: b.cover, maxPixel: 180).frame(width: 40, height: 56).clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
            } else {
                SvgIcon(name: "book", size: 18, color: Theme.text2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(b.title).lineLimit(2)
                Text(Self.meta(b))
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
        }
    }
}

/// 导入确认页：书名、作者可改，看一眼读出来的正文与章节再存
struct BookAddView: View {
    let parsed: Books.Parsed
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section("书名") { TextField("书名", text: $title) }
            Section("作者") { TextField("可留空", text: $author) }
            Section("读出来的内容") {
                LabeledContent("正文", value: "\((parsed.text as NSString).length) 字")
                LabeledContent("章节", value: "\(parsed.chapters.count) 章")
                LabeledContent("格式", value: parsed.kind == "epub" ? "epub" : "纯文本")
                if parsed.cover != nil { LabeledContent("封面", value: "书里自带，一并存下") }
                Text(String(parsed.text.prefix(160)) + "…").font(.footnote).foregroundStyle(Theme.text2)
            }
            Section {
                Button(busy ? "正在保存" : "存入书库", action: save).disabled(busy)
            } footer: {
                HelpNote("正文只存在这台设备上，不会上传。章节按「第 N 章」一类的行自动划分，epub 按它自己的目录划分。txt 会自动判断编码，GBK 与 UTF-8 均可读取。", title: "导入书籍")
            }
        }
        .navigationTitle("导入书籍")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onAppear { if title.isEmpty { title = parsed.title; author = parsed.author } }
    }

    private func save() {
        busy = true
        do { try Books.add(parsed, title: title, author: author); dismiss() }
        catch { problem = error.localizedDescription }
        busy = false
    }
}

/// 书的资料页（网页版 BookPage）：读、一起读、书评、这本书
struct BookDetailView: View {
    let bookId: String
    @State private var book: Books.Book?
    @State private var reading: ReadTarget?
    @State private var picking = false
    @State private var problem: String?

    private func progress(_ b: Books.Book) -> String {
        guard b.at > 0 else { return "从头开始" }
        let ch: String = Books.chapterAt(b)?.chapter.title ?? ""
        return "读到 \(Books.percent(b))%" + (ch.isEmpty ? "" : " · " + ch)
    }

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let b = book {
                Section {
                    Button { reading = ReadTarget(bookId: b.id, chatId: nil) } label: {
                        TogetherRow(icon: "book", title: "继续阅读", sub: progress(b))
                    }
                    .buttonStyle(.plain)
                    Button { picking = true } label: { TogetherRow(icon: "users", title: "和角色一起读", sub: "") }.buttonStyle(.plain)
                } footer: {
                    HelpNote("和角色一起读：选一个角色，边读边聊。角色看得到你正读到的那一段", title: "和角色一起读")
                }
                Section {
                    NavigationLink { ReviewsView(kind: .book, subjectId: b.id) } label: {
                        TogetherRow(icon: "notes", title: "角色写的书评", sub: "\(Reviews.count(.book, b.id)) 篇")
                    }
                } footer: { Text("写一篇调用一次接口。") }
                Section("这本书") {
                    LabeledContent("作者", value: b.author.isEmpty ? "未填写" : b.author)
                    LabeledContent("字数", value: "\(b.chars) 字")
                    LabeledContent("章节", value: "\(b.chapters.count) 章")
                    LabeledContent("格式", value: b.kind == "epub" ? "epub" : "纯文本")
                }
            } else {
                EmptyState(title: "这本书已经不在了")
            }
        }
        .navigationTitle(book?.title ?? "书")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { book = Books.get(bookId) }
        .fullScreenCover(item: $reading, onDismiss: { book = Books.get(bookId) }) { t in BookReaderView(bookId: t.bookId, chatId: t.chatId) }
        .sheet(isPresented: $picking) {
            ChatPickSheet(title: "共读角色") { chatId in
                picking = false
                reading = ReadTarget(bookId: bookId, chatId: chatId)
            }
        }
    }
}

/// 选一段一对一的会话（一起读、发书摘）
struct ChatPickSheet: View {
    let title: String
    var pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let chats = Excerpt.targets()
        NavigationStack {
            List {
                if chats.isEmpty { EmptyState(title: "还没有一对一的会话", desc: "先在「聊天」里和一个角色说上话。") }
                ForEach(chats) { c in
                    if let ch = c.characterIds.first.flatMap({ (try? Repo.character($0)) ?? nil }) {
                        Button { pick(c.id) } label: {
                            HStack(spacing: Theme.sp3) {
                                Avatar(imageId: ch.avatar, name: ch.name, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ch.displayName)
                                    if !ch.signature.isEmpty { Text(ch.signature).font(.footnote).foregroundStyle(Theme.text2).lineLimit(1) }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .eiraLook()
    }
}

// MARK: - 阅读器的外观（网页版 system/reader.js，和全局主题分开存在 settings.reader）

struct ReaderLook {
    var raw: [String: JSONValue]

    static func load(_ s: AppSettings) -> ReaderLook { ReaderLook(raw: s.raw["reader"]?.object ?? [:]) }

    var effect: String { raw["effect"]?.string ?? "slide" }
    var fullscreen: Bool { raw["fullscreen"]?.bool ?? false }
    var paper: String { raw["paper"]?.string ?? "theme" }
    var bgColor: String { raw["bgColor"]?.string ?? "" }
    var textColor: String { raw["textColor"]?.string ?? "" }
    var fontSize: Double { raw["fontSize"]?.number ?? 17 }
    var lineHeight: Double { raw["lineHeight"]?.number ?? 1.85 }
    var tapTurn: Bool { raw["tapTurn"]?.bool ?? true }

    static let effects: [(id: String, label: String, desc: String)] = [
        ("instant", "无动画", "直接换页"),
        ("slide", "左右平移", "向左滑出，新的一页从右侧进来"),
        ("fade", "淡入淡出", "淡出之后换页，再淡入"),
        ("vertical", "上下翻页", "向上滑出，新的一页从下方进来"),
    ]
    static let papers: [(id: String, label: String)] = [("theme", "跟随主题"), ("paper", "纸白"), ("sepia", "米黄"), ("night", "夜间"), ("custom", "自定义")]

    static func color(_ hex: String) -> Color? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        guard h.hasPrefix("#") else { return nil }
        h.removeFirst()
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Color(Theme.hex(v))
    }

    var background: Color {
        switch paper {
        case "paper": return Color(Theme.hex(0xFFFFFF))
        case "sepia": return Color(Theme.hex(0xF4ECD8))
        case "night": return Color(Theme.hex(0x16181C))
        case "custom": return Self.color(bgColor) ?? Theme.surface
        default: return Theme.surface
        }
    }

    var ink: Color {
        if let c = Self.color(textColor) { return c }
        switch paper {
        case "paper": return Color(Theme.hex(0x1A1A1A))
        case "sepia": return Color(Theme.hex(0x4A3F35))
        case "night": return Color(Theme.hex(0xB9BCC2))
        default: return Theme.text
        }
    }
}

// MARK: - 阅读页

/// 一页一页地翻，按字数走（网页版 ReadPage 与 TogetherPage）。chatId 不为空时是和角色一起读：翻页时给角色一次开口的机会，下面是两人的对话。
///
/// 翻页的阅读页不认左缘右滑返回（用户定的：边缘滑动永远不离开阅读页）：页面自己左右滑翻页，左上角有返回键
struct BookReaderView: View {
    let bookId: String
    var chatId: String?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = SettingsModel.shared
    @State private var text: NSString = ""
    @State private var loaded = false
    @State private var at = 0
    @State private var dir = 1
    @State private var bare = false
    @State private var toc = false
    @State private var cfgOpen = false
    @State private var excerpting = false
    @State private var aheading = false
    @State private var para: Int?
    @State private var busy = false
    @State private var problem: String?
    @State private var chatOpen = false
    @State private var draft = ""
    @State private var ending = false
    @State private var tick = 0

    private var together: Bool { chatId != nil }

    var body: some View {
        let look = ReaderLook.load(model.s)
        let immersive = look.fullscreen && bare
        NavigationStack {
            ZStack {
                look.background.ignoresSafeArea()
                if !loaded {
                    ProgressView()
                } else if let b = Books.get(bookId) {
                    VStack(spacing: 0) {
                        page(b, look)
                        if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal) }
                        if !immersive {
                            ReadAheadLine(bookId: bookId, at: at, span: Books.page)
                            if let chatId { chatPanel(chatId) }
                            bottomBar(b)
                        }
                    }
                } else {
                    EmptyState(title: "这本书已经不在了")
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(immersive ? .hidden : .visible, for: .navigationBar)
            .toolbar { toolbar }
            .navigationDestination(item: $para) { p in ParaPageView(subject: ParaNotes.subject(.book, bookId), at: p) }
            .sheet(isPresented: $toc) { tocSheet }
            .sheet(isPresented: $cfgOpen) { NavigationStack { ReaderSettingsView() }.eiraLook() }
            .sheet(isPresented: $excerpting) { NavigationStack { ExcerptView(bookId: bookId, at: at) }.eiraLook() }
            .sheet(isPresented: $aheading) { NavigationStack { ReadAheadSheet(bookId: bookId, from: at) }.eiraLook() }
            .confirmationDialog("结束这一场", isPresented: $ending, titleVisibility: .visible) {
                Button("结束", role: .destructive) { ReadTogether.stop(); dismiss() }
            } message: { Text("会在会话中留下一条记录。书的进度保留。") }
        }
        .eiraLook()
        .onAppear(perform: appear)
        .onDisappear {
            EdgeBack.blocked = max(0, EdgeBack.blocked - 1)
            if together { ReadTogether.away() }
        }
        .onChange(of: look.fullscreen) { _, v in bare = v }
    }

    private var navTitle: String {
        if let chatId, let c = try? Repo.chat(chatId), let id = c.characterIds.first, let ch = (try? Repo.character(id)) ?? nil {
            return "和 \(ch.displayName) 一起读"
        }
        return Books.get(bookId)?.title ?? "阅读"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                HStack(spacing: 2) { Image(systemName: "chevron.left"); Text("返回") }
            }
            .accessibilityLabel("返回")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { aheading = true } label: { SvgIcon(name: together ? "notes" : "users", size: 20) }.accessibilityLabel("让角色先读")
            if !together {
                Button { excerpting = true } label: { SvgIcon(name: "notes", size: 20) }.accessibilityLabel("书摘")
            }
            Button { cfgOpen = true } label: { SvgIcon(name: "settings", size: 20) }.accessibilityLabel("阅读设置")
            Button("目录") { toc = true }
            if together { Button("结束") { ending = true } }
        }
    }

    private func appear() {
        EdgeBack.blocked += 1
        bare = ReaderLook.load(model.s).fullscreen
        if let chatId {
            do {
                let st = try ReadTogether.start(chatId: chatId, bookId: bookId)
                ReadTogether.markStart()
                ReadTogether.back()
                at = st.at
            } catch { problem = error.localizedDescription }
        } else {
            at = Books.get(bookId)?.at ?? 0
        }
        let id = bookId
        Task.detached {
            let t = Books.text(id)
            await MainActor.run { text = t; loaded = true }
        }
    }

    // MARK: 一页

    @ViewBuilder private func page(_ b: Books.Book, _ look: ReaderLook) -> some View {
        let paras = Books.paragraphs(text, from: at, span: Books.page)
        let counts = ParaNotes.counts(ParaNotes.subject(.book, bookId), from: at, span: Books.page)
        let ch = Books.chapterAt(b, at)
        GeometryReader { g in
            ScrollView {
                VStack(alignment: .leading, spacing: look.fontSize * 0.9) {
                    if let ch {
                        Text(ch.chapter.title).font(.system(size: 13)).foregroundStyle(look.ink.opacity(0.62))
                            .padding(.bottom, Theme.sp2)
                    }
                    ForEach(paras, id: \.at) { p in
                        HStack(alignment: .top, spacing: Theme.sp2) {
                            Text(p.text)
                                .font(.system(size: look.fontSize, design: .serif))
                                .lineSpacing(look.fontSize * max(0, look.lineHeight - 1))
                                .foregroundStyle(look.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ParaDot(n: counts[p.at] ?? 0, ink: look.ink) { para = p.at }
                        }
                    }
                }
                .padding(.horizontal, Theme.sp5).padding(.vertical, Theme.sp4)
                .id(at)
                .transition(pageTransition(look.effect))
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { loc in
                guard look.tapTurn else { return }
                let x = loc.x / max(1, g.size.width)
                if x < 0.33 { turn(-1, look) } else if x > 0.67 { turn(1, look) } else if look.fullscreen { bare.toggle() }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
                let w = v.translation.width, h = v.translation.height
                guard abs(w) > 60, abs(w) > abs(h) * 1.5 else { return }
                turn(w < 0 ? 1 : -1, look)
            })
        }
    }

    private func pageTransition(_ effect: String) -> AnyTransition {
        switch effect {
        case "fade": return .opacity
        case "vertical": return .asymmetric(insertion: .move(edge: dir > 0 ? .bottom : .top).combined(with: .opacity),
                                            removal: .move(edge: dir > 0 ? .top : .bottom).combined(with: .opacity))
        case "slide": return .asymmetric(insertion: .move(edge: dir > 0 ? .trailing : .leading).combined(with: .opacity),
                                         removal: .move(edge: dir > 0 ? .leading : .trailing).combined(with: .opacity))
        default: return .identity
        }
    }

    private func turn(_ d: Int, _ look: ReaderLook) {
        let to = at + d * Books.page
        guard to >= 0, to <= text.length - 1 else { return }
        go(to, d, look)
    }

    private func go(_ to: Int, _ d: Int, _ look: ReaderLook) {
        let next = max(0, min(max(0, text.length - 1), to))
        dir = d
        if look.effect == "instant" { at = next } else { withAnimation(.easeOut(duration: 0.19)) { at = next } }
        if together {
            ReadTogether.setAt(next)
            if ReadTogether.due() { speak() }
        } else {
            Books.setAt(bookId, next)
        }
    }

    // MARK: 下面那一条

    private func bottomBar(_ b: Books.Book) -> some View {
        let len = Books.slice(text, at, Books.page).utf16.count
        let total: Double = Double(max(1, text.length))
        let ratio: Double = Double(at + len) / total * 100
        let pct: Int = text.length > 0 ? min(100, Int(ratio.rounded())) : 0
        let st = ReadTogether.state
        let look = ReaderLook.load(model.s)
        let metaLine: String = together ? "\(st.pages) 页 · 角色发言 \(st.said) 次" : "\(at + 1) – \(at + len) / \(text.length) 字"
        return HStack(spacing: Theme.sp3) {
            Button { turn(-1, look) } label: { SvgIcon(name: "chevronLeft", size: 19, color: look.ink) }
                .accessibilityLabel("上一页").disabled(at <= 0)
            if together {
                Button(action: speak) {
                    if busy { ProgressView() } else { SvgIcon(name: "message", size: 18, color: look.ink) }
                }
                .accessibilityLabel("让角色说一句").disabled(busy)
            }
            Spacer()
            VStack(spacing: 1) {
                Text("\(pct)%").font(.system(size: 13))
                Text(metaLine)
                    .font(.system(size: 11)).opacity(0.7)
            }
            .foregroundStyle(look.ink)
            Spacer()
            Button { turn(1, look) } label: { SvgIcon(name: "chevronRight", size: 19, color: look.ink) }
                .accessibilityLabel("下一页").disabled(at + Books.page >= text.length)
        }
        .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp2)
    }

    // MARK: 一起读时的对话（网页版 4.1056）

    @ViewBuilder private func chatPanel(_ chatId: String) -> some View {
        let chat = try? Repo.chat(chatId)
        let manual = ReadTogether.replyOf(chat) == "manual"
        let name = (chat?.characterIds.first).flatMap { (try? Repo.character($0)) ?? nil }?.displayName ?? "角色"
        VStack(spacing: Theme.sp2) {
            Button { withAnimation(.easeOut(duration: 0.2)) { chatOpen.toggle() } } label: {
                HStack {
                    Text("与 \(name) 的对话").font(.system(size: 13))
                    Spacer()
                    SvgIcon(name: chatOpen ? "chevronDown" : "chevronUp", size: 15)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if chatOpen {
                TogetherTalk(chatId: chatId, since: ReadTogether.state.since, busy: busy, maxHeight: 220)
                HStack(spacing: Theme.sp3) {
                    Text("\(ReadTogether.howOf(chat) == "face" ? "在一起读" : "连线一起读") · \(manual ? "手动触发回复" : "发送后立即回复")")
                        .foregroundStyle(Theme.text2)
                    Spacer()
                    Button("切换方式") { cfg(chatId, how: ReadTogether.howOf(chat) == "face" ? "online" : "face") }
                    Button(manual ? "改为立即回复" : "改为手动回复") { cfg(chatId, reply: manual ? "auto" : "manual") }
                }
                .font(.system(size: 12))
            }
            TogetherInput(draft: $draft, manual: manual, busy: busy, send: { send(chatId, manual) }, reply: speak)
        }
        .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp2)
        .background(Theme.surface2.opacity(0.6))
        .id(tick)
    }

    private func cfg(_ chatId: String, how: String? = nil, reply: String? = nil) {
        do { try ReadTogether.setCfg(chatId, how: how, reply: reply); tick += 1 } catch { problem = "未能保存：\(error.localizedDescription)" }
    }

    private func send(_ chatId: String, _ manual: Bool) {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = ""
        chatOpen = true
        do {
            _ = try ChatEngine.send(text: t, chatId: chatId)
            NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
        } catch { problem = "消息未能保存：\(error.localizedDescription)"; return }
        if !manual { speak() }
    }

    /// 角色开口：一次调用，和聊天同一套接口，落进那段会话里（先记「试过」再发）
    private func speak() {
        guard let chatId, !busy else { return }
        busy = true
        problem = nil
        Task {
            do { try await ReadTogether.talk(chatId: chatId) { _ in } }
            catch { problem = error.localizedDescription }
            busy = false
            tick += 1
            NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
        }
    }

    // MARK: 目录

    private var tocSheet: some View {
        let b = Books.get(bookId)
        let cur = Books.chapterAt(b, at)?.index
        return NavigationStack {
            List {
                ForEach(Array((b?.chapters ?? []).enumerated()), id: \.offset) { i, c in
                    Button {
                        toc = false
                        go(c.start, c.start >= at ? 1 : -1, ReaderLook.load(model.s))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title)
                                Text("\(ReadAheadLine.percent(bookId, c.start))%").font(.footnote).foregroundStyle(Theme.text2)
                            }
                            Spacer()
                            if cur == i { SvgIcon(name: "check", size: 16) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { toc = false } } }
        }
        .eiraLook()
    }
}

/// 段落旁的小气泡：有评论显示条数，没有就是个淡气泡
struct ParaDot: View {
    let n: Int
    let ink: Color
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            Group {
                if n > 0 { Text(n > 99 ? "99" : "\(n)").font(.system(size: 10, weight: .semibold)).foregroundStyle(ink) }
                else { SvgIcon(name: "message", size: 11, color: ink.opacity(0.35)) }
            }
            .frame(width: 22, height: 22)
            .background(ink.opacity(n > 0 ? 0.12 : 0)).clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(n > 0 ? "这一段有 \(n) 条评论" : "评论这一段")
    }
}

/// 阅读设置（网页版 ReaderSettings）：和全局主题分开，改这里不动 app 的外观
struct ReaderSettingsView: View {
    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var resetting = false

    var body: some View {
        let look = ReaderLook.load(model.s)
        Form {
            Section {
                Toggle("全屏阅读", isOn: bind("fullscreen", look.fullscreen))
                Toggle("点两侧翻页", isOn: bind("tapTurn", look.tapTurn))
            } header: { Text("阅读时") } footer: {
                HelpNote("全屏阅读：隐藏顶栏与翻页条，整屏只剩正文，点正文中间可以再唤出来。点两侧翻页：点屏幕左侧三分之一向前，右侧三分之一向后。左右滑动正文也可以翻页")
            }
            Section("翻页方式") {
                ForEach(ReaderLook.effects, id: \.id) { e in
                    Button { set("effect", .string(e.id)) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.label)
                                Text(e.desc).font(.footnote).foregroundStyle(Theme.text2)
                            }
                            Spacer()
                            if look.effect == e.id { SvgIcon(name: "check", size: 16) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                Picker("纸色", selection: Binding(get: { look.paper }, set: { set("paper", .string($0)) })) {
                    ForEach(ReaderLook.papers, id: \.id) { p in Text(p.label).tag(p.id) }
                }
                if look.paper == "custom" {
                    TextField("背景颜色，例如 #ffffff", text: Binding(get: { look.bgColor }, set: { set("bgColor", .string($0.trimmingCharacters(in: .whitespaces))) }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                TextField("正文颜色，留空跟随纸色", text: Binding(get: { look.textColor }, set: { set("textColor", .string($0.trimmingCharacters(in: .whitespaces))) }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("纸色") } footer: {
                HelpNote("仅在阅读器内生效，与「设置 - 主题」互不影响。选择「自定义」后可以填背景颜色，留空时跟随主题。正文颜色留空则跟随纸色。")
            }
            Section {
                Stepper("字号：\(Int(look.fontSize))", value: Binding(get: { look.fontSize }, set: { set("fontSize", .number(max(10, min(40, $0)))) }), in: 10...40)
                Stepper("行距：\(String(format: "%.2f", look.lineHeight))", value: Binding(get: { look.lineHeight }, set: { set("lineHeight", .number(max(1, min(4, ($0 * 20).rounded() / 20)))) }), in: 1...4, step: 0.05)
            } footer: {
                HelpNote("行距是正文每行之间的倍数，1.8 左右较为宽松。", title: "字号与行距")
            }
            Section { Button("恢复默认外观") { resetting = true } }
        }
        .navigationTitle("阅读设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .confirmationDialog("恢复默认外观", isPresented: $resetting, titleVisibility: .visible) {
            Button("恢复默认") { model.set("reader", .object([:])) }
        }
    }

    /// 改一项：其余几项原样留着（网页版 reader.set 是整份合并写回）
    private func set(_ k: String, _ v: JSONValue) {
        model.update { s in
            var r = s.raw["reader"]?.object ?? [:]
            r[k] = v
            s.raw["reader"] = .object(r)
        }
    }

    private func bind(_ k: String, _ cur: Bool) -> Binding<Bool> {
        Binding(get: { cur }, set: { set(k, .bool($0)) })
    }
}

// MARK: - 让角色先读（网页版 ReadAhead）

/// 盯着你的进度：追上角色读到的位置时，选过「一直继续」且没到上限就悄悄再读一段，否则问一次
struct ReadAheadLine: View {
    let bookId: String
    let at: Int
    let span: Int
    @State private var asking = false
    @State private var busy = false
    @State private var snoozed = -1
    @State private var tick = 0
    @State private var problem: String?

    var body: some View {
        let _ = tick
        if let s = ReadAhead.state(bookId) {
            let total = Books.get(bookId)?.chars ?? 0
            let finished = total > 0 && s.at >= total
            VStack(spacing: 2) {
                HStack(spacing: Theme.sp1) {
                    SvgIcon(name: "book", size: 12, color: Theme.text2)
                    Text(finished ? "\(s.char.name) 已经把这本书读完了" : "\(s.char.name) 读到 \(pct(s.at))%")
                    if busy { ProgressView().scaleEffect(0.6) }
                }
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.text2)
            .padding(.vertical, 2)
            .onAppear(perform: check)
            .onChange(of: at) { _, _ in check() }
            .confirmationDialog(finished ? "\(s.char.name) 已经读到结尾" : "\(s.char.name) 已经看完了", isPresented: $asking, titleVisibility: .visible) {
                if finished {
                    Button("知道了") { try? ReadAhead.stop(bookId); tick += 1 }
                } else {
                    Button("继续读一段") { try? ReadAhead.advance(bookId, to: s.at, auto: false); read(auto: false) }
                    Button("一直继续，不再询问") {
                        try? ReadAhead.setAlways(bookId, true)
                        try? ReadAhead.advance(bookId, to: s.at, auto: false)
                        read(auto: true)
                    }
                    Button("先不用", role: .cancel) { snoozed = s.at }
                }
            } message: {
                Text(askText(s, finished: finished))
            }
        }
    }

    private func pct(_ at: Int) -> Int { Self.percent(bookId, at) }

    static func percent(_ bookId: String, _ at: Int) -> Int {
        let total: Int = Books.get(bookId)?.chars ?? 0
        guard total > 0 else { return 0 }
        let r: Double = Double(at) / Double(total) * 100
        return min(100, Int(r.rounded()))
    }

    private func askText(_ s: ReadAhead.State, finished: Bool) -> String {
        if finished { return "已经读到这本书的结尾，没有更多可读的内容了。" }
        if ReadAhead.hitCap(bookId) { return "已经连续自动读了 \(s.runs) 次，达到设定的上限。继续将重新开始计数，每次读一段都会调用一次接口。" }
        return "你已经读到 \(s.char.name) 读过的位置。让角色继续往下读一段，会调用一次接口。选择「一直继续」后最多再自动读 \(ReadAhead.maxRuns()) 次，达到上限会再次询问。"
    }

    private func check() {
        guard let s = ReadAhead.state(bookId), !busy, ReadAhead.caughtUp(bookId, youAt: at, span: span) else { return }
        let total = Books.get(bookId)?.chars ?? 0
        if total > 0 && s.at >= total { if snoozed != s.at { asking = true }; return }
        if ReadAhead.canAuto(bookId) { read(auto: true); return }
        if snoozed != s.at { asking = true }
    }

    private func read(auto: Bool) {
        guard ReadAhead.state(bookId) != nil, !busy else { return }
        busy = true
        problem = nil
        Task {
            do { try await ReadAhead.step(bookId, auto: auto) }
            catch { problem = error.localizedDescription + (auto ? "。已停止自动续读" : "") }
            busy = false
            tick += 1
        }
    }
}

/// 开始、换人、停下，也在这里改这一次注入多少字
struct ReadAheadSheet: View {
    let bookId: String
    let from: Int
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = SettingsModel.shared
    @State private var busy = false
    @State private var problem: String?
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let s = ReadAhead.state(bookId)
        let want = ReadAhead.chars(model.s)
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Text("把从当前位置起的一段正文交给角色读一遍。角色会挑出想说的段落留下评论，你读到那些段落时才会看见。一次注入无论多少字都只调用一次接口。")
                    .font(.footnote).foregroundStyle(Theme.text2)
                NumberRow(title: "本次注入字数", value: model.number("injectChars", Double(ReadAhead.defaultChars)), unit: "字", placeholder: "读到书末")
            } footer: {
                Text("当前设置为一次 \(want > 0 ? "\(want) 字" : "读到书末")。读完之后你追上它时会询问是否继续。")
            }
            if let s {
                Section("正在先读") {
                    HStack {
                        Avatar(imageId: s.char.avatar, name: s.char.name, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.char.displayName)
                            Text(stateText(s))
                                .font(.footnote).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        Button("停下") { try? ReadAhead.stop(bookId); tick += 1 }.buttonStyle(.borderless)
                    }
                }
            }
            Section(s == nil ? "让谁来读" : "换一个角色") {
                let list = ParaNotes.candidates()
                if list.isEmpty { Text("还没有角色。先在「联系」里建一个角色").foregroundStyle(Theme.text2) }
                ForEach(list) { c in
                    Button { go(c.id) } label: {
                        HStack {
                            Avatar(imageId: c.avatar, name: c.name, size: 34)
                            Text(c.displayName)
                            Spacer()
                            if busy { ProgressView() }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(busy)
                }
            }
        }
        .navigationTitle("让角色先读")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
    }

    private func stateText(_ s: ReadAhead.State) -> String {
        let left: Int = max(0, ReadAhead.maxRuns() - s.runs)
        let tail: String = s.always ? " · 已选择一直继续，最多再自动读 \(left) 次" : ""
        return "已读到 \(ReadAheadLine.percent(bookId, s.at))%" + tail
    }

    private func go(_ charId: String) {
        busy = true
        problem = nil
        Task {
            do {
                try ReadAhead.begin(bookId, charId: charId, from: from)
                let r = try await ReadAhead.run(bookId: bookId, charId: charId, from: from)
                try ReadAhead.advance(bookId, to: r.to, auto: false)
                dismiss()
            } catch { problem = error.localizedDescription }
            busy = false
            tick += 1
        }
    }
}

// MARK: - 段评（网页版 ParaPage）

struct ParaPageView: View {
    let subject: String
    let at: Int
    @State private var passage = ""
    @State private var title = ""
    @State private var notes: [ParaNotes.Note] = []
    @State private var busy = ""
    @State private var problem: String?
    @State private var notice: String?
    @State private var writing = false
    @State private var mine = ""
    @State private var crewing = false
    @State private var clearing = false
    @State private var dropping: ParaNotes.Note?

    var body: some View {
        let isVideo = ParaNotes.parse(subject).kind == .video
        let crew = ParaNotes.crew(subject)
        let foot: String = title.isEmpty ? "" : (isVideo ? "《\(title)》 · " + Subtitle.stamp(Double(at)) : "《\(title)》")
        let mode: String = SettingsModel.shared.s.raw["translateShow"]?.string ?? "both"
        let crewTitle: String = busy == "crew" ? "正在生成" : (isVideo ? "多人同看" : "多人共读")
        let names: String = crew.map(\.displayName).joined(separator: "、")
        let crewSub: String = crew.isEmpty ? "先选定参与的角色，之后每一段点一下即可" : "\(names) 各写一条 · 本次调用 \(ParaNotes.callsForCrew(crew.count)) 次"
        let readersTitle: String = busy == "readers" ? "正在生成" : "随机评论"
        let crewCount: String = crew.isEmpty ? "尚未选择" : "\(crew.count) 人"
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
            Section {
                Text(passage.isEmpty ? "这一处没有内容" : passage).font(.system(size: 15, design: .serif))
            } footer: { Text(foot) }
            Section(notes.isEmpty ? "这一段还没有评论" : "\(notes.count) 条评论") {
                ForEach(notes) { n in
                    ParaNoteRow(note: n, mode: mode)
                    .swipeActions { Button("删除", role: .destructive) { dropping = n } }
                }
            }
            Section {
                Button {
                    if crew.isEmpty { crewing = true } else {
                        let ids = crew.map(\.id)
                        run("crew") { try await ParaNotes.crewComments(subject, at: at, charIds: ids) }
                    }
                } label: {
                    TogetherRow(icon: "users", title: crewTitle, sub: crewSub)
                }
                .buttonStyle(.plain).disabled(!busy.isEmpty)
                Button { run("readers") { try await ParaNotes.readers(subject, at: at) } } label: {
                    TogetherRow(icon: "message", title: readersTitle, sub: "临时生成 \(ParaNotes.crowdCount()) 位读者的评论，调用 1 次")
                }
                .buttonStyle(.plain).disabled(!busy.isEmpty)
                Button { writing = true } label: { TogetherRow(icon: "edit", title: "自己写一条", sub: "写下你自己的想法，不调用接口") }.buttonStyle(.plain)
                Button { crewing = true } label: { TogetherRow(icon: "settings", title: "共读名单", sub: crewCount) }.buttonStyle(.plain)
            } header: { Text("评价者") } footer: { HelpNote("随机评论的读者不会存入联系人", title: "段评") }
        }
        .navigationTitle(isVideo ? Subtitle.stamp(Double(at)) : "这一段")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if !notes.isEmpty { Button("清空") { clearing = true } } } }
        .onAppear(perform: load)
        .sheet(isPresented: $writing) {
            NavigationStack {
                Form {
                    Section("我的想法") { TextEditor(text: $mine).frame(minHeight: 120) }
                    Section { Button("写好了", action: writeMine).disabled(mine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
                .navigationTitle("写一条")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { writing = false } } }
            }
            .eiraLook()
        }
        .sheet(isPresented: $crewing, onDismiss: load) { NavigationStack { CrewSheet(subject: subject) }.eiraLook() }
        .confirmationDialog("清空这一段的评论", isPresented: $clearing, titleVisibility: .visible) {
            Button("清空", role: .destructive) { do { try ParaNotes.clear(subject, at: at); load() } catch { problem = error.localizedDescription } }
        }
        .confirmationDialog("删除这一条", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let n = dropping { do { try ParaNotes.remove(n.id); load() } catch { problem = error.localizedDescription } }
                dropping = nil
            }
        }
    }

    private func load() {
        notes = ParaNotes.list(subject, at: at)
        let p = ParaNotes.parse(subject)
        if p.kind == .video {
            let v = VideoLib.get(p.id)
            title = v?.title ?? ""
            passage = Subtitle.recentLines(VideoLib.lines(v), Double(at), 5).map(\.text).joined(separator: "\n")
        } else {
            title = Books.get(p.id)?.title ?? ""
            let id = p.id, pos = at
            Task.detached {
                let t = Books.paragraphAt(Books.text(id), pos)
                await MainActor.run { passage = t }
            }
        }
    }

    private func run(_ what: String, _ make: @escaping () async throws -> [ParaNotes.Draft]) {
        guard busy.isEmpty else { return }
        busy = what
        problem = nil
        Task {
            do {
                let rows = try await make()
                if rows.isEmpty { notice = "这一次没有写出内容" } else {
                    try ParaNotes.keep(subject, at: at, rows)
                    notice = "新增 \(rows.count) 条"
                }
            } catch { problem = error.localizedDescription }
            busy = ""
            load()
        }
    }

    private func writeMine() {
        do {
            try ParaNotes.add(subject, at: at, .init(authorId: "", authorName: "我", kind: ParaNotes.meKind, text: mine))
            mine = ""
            writing = false
            load()
        } catch { problem = error.localizedDescription }
    }
}

/// 共读名单：存在作品上，挑一次之后每一段都用它
struct CrewSheet: View {
    let subject: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = SettingsModel.shared
    @State private var picked: Set<String> = []
    @State private var problem: String?

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                ForEach(ParaNotes.candidates()) { c in
                    Button { toggle(c.id) } label: {
                        HStack {
                            Avatar(imageId: c.avatar, name: c.name, size: 34)
                            Text(c.displayName)
                            Spacer()
                            if picked.contains(c.id) { SvgIcon(name: "check", size: 16) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                Toggle("一人一次调用", isOn: model.bool("crowdSeparate", false))
            } header: { Text("生成方式") } footer: {
                Text("关闭时一次调用写出所有人的评论，同一次里几个人容易写得相似。开启后每人单独调用一次，调用次数等于所选人数。")
            }
        }
        .navigationTitle("共读名单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .onAppear { picked = Set(ParaNotes.crew(subject).map(\.id)) }
    }

    private func toggle(_ id: String) {
        var next = picked
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        do {
            let order = ParaNotes.crew(subject).map(\.id).filter { next.contains($0) } + next.filter { id in !ParaNotes.crew(subject).contains { $0.id == id } }
            try ParaNotes.setCrew(subject, order)
            picked = next
        } catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}

// MARK: - 书摘（网页版 ExcerptSheet）

struct ExcerptView: View {
    let bookId: String
    let at: Int
    @Environment(\.dismiss) private var dismiss
    @State private var quote = ""
    @State private var note = ""
    @State private var picking = false
    @State private var problem: String?

    private func foot(_ b: Books.Book?) -> String {
        let title: String = b?.title ?? "这本书"
        let author: String = b?.author ?? ""
        return "摘自《\(title)》" + (author.isEmpty ? "" : " · " + author) + "。发出去之后是会话里的一条消息，不调用接口。"
    }

    var body: some View {
        let b = Books.get(bookId)
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                TextEditor(text: $quote).frame(minHeight: 140)
            } header: { Text("摘录") } footer: {
                Text(foot(b))
            }
            Section {
                TextField("可留空", text: $note)
            } header: { Text("留言") } footer: { HelpNote("留言写了会一并出现在卡片下方。") }
            Section { Button("选择角色并发送") { picking = true }.disabled(quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .navigationTitle("书摘")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .sheet(isPresented: $picking) {
            ChatPickSheet(title: "收件人") { chatId in
                picking = false
                do { try Excerpt.send(chatId: chatId, bookId: bookId, quote: quote, note: note, at: at); dismiss() }
                catch { problem = error.localizedDescription }
            }
        }
    }
}

// MARK: - 影评与书评（网页版 ReviewsPage）

struct ReviewsView: View {
    let kind: Reviews.Kind
    let subjectId: String
    @State private var list: [Reviews.Review] = []
    @State private var picking = false
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        let word = kind == .book ? "书评" : "影评"
        let title = kind == .book ? (Books.get(subjectId)?.title ?? "") : (VideoLib.get(subjectId)?.title ?? "")
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if busy { Text(kind == .book ? "正在按你读到的位置写" : "正在按看过的那一段写").foregroundStyle(Theme.text2) }
            if list.isEmpty {
                Section {
                    EmptyState(title: "还没有\(word)", desc: "让一个角色按\(kind == .book ? "读到" : "看到")的内容写一篇。每写一篇都留着，以后重看再写不会把旧的冲掉。")
                    Button("写一篇") { picking = true }.disabled(busy)
                }
            } else {
                Section("共 \(list.count) 篇") {
                    ForEach(list) { r in
                        NavigationLink { ReviewDetailView(review: r, kind: kind) } label: {
                            let c = (try? Repo.character(r.charId)) ?? nil
                            let first = r.text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c?.displayName ?? "某个角色")
                                Text("\(Self.when(r.createdAt)) · \(first)").font(.footnote).foregroundStyle(Theme.text2).lineLimit(1)
                            }
                        }
                    }
                }
            }
            Section {} footer: { Text("写一篇调用一次模型接口。在「一起看 - 设置」中可以开启收场时自动写，默认关闭。") }
        }
        .navigationTitle(title.isEmpty ? word : "\(title) · \(word)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(busy ? "写着" : "写一篇") { picking = true }.disabled(busy) } }
        .sheet(isPresented: $picking) {
            CharPickSheet(title: "执笔者") { c in
                picking = false
                write(c.id)
            }
        }
        .onAppear(perform: load)
    }

    static func when(_ ts: Double) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(millis: ts))
        return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    private func load() { list = Reviews.list(kind, subjectId) }

    private func write(_ charId: String) {
        busy = true
        problem = nil
        Task {
            do {
                let at = kind == .book ? Double(Books.get(subjectId)?.at ?? 0) : 0
                try await Reviews.write(kind, subjectId: subjectId, charId: charId, at: at)
            } catch { problem = error.localizedDescription }
            busy = false
            load()
        }
    }
}

struct ReviewDetailView: View {
    let review: Reviews.Review
    let kind: Reviews.Kind

    private var head: String {
        var t = ReviewsView.when(review.createdAt)
        if kind == .book && review.at > 0 {
            t += " · 读到 \(Books.percent(Books.get(review.subjectId), at: Int(review.at)))%"
        }
        return t
    }
    @Environment(\.dismiss) private var dismiss
    @State private var dropping = false
    @State private var problem: String?

    var body: some View {
        let c = (try? Repo.character(review.charId)) ?? nil
        let paras: [String] = review.text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sp3) {
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
                Text(head)
                    .font(.footnote).foregroundStyle(Theme.text2)
                ForEach(Array(paras.enumerated()), id: \.offset) { _, p in
                    Text(p).font(.system(size: 16, design: .serif)).lineSpacing(6)
                }
                Button("删除这一篇", role: .destructive) { dropping = true }.foregroundStyle(Theme.dangerText).padding(.top, Theme.sp4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.sp4)
        }
        .navigationTitle(c?.displayName ?? "某个角色")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除这一篇", isPresented: $dropping, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Reviews.remove(review.id); dismiss() } catch { problem = error.localizedDescription }
            }
        } message: { Text("只删这一篇，同一部的其他几篇不受影响。") }
    }
}

/// 段评的一条：头像（角色有头像就用）、署名、正文与译文
struct ParaNoteRow: View {
    let note: ParaNotes.Note
    let mode: String

    var body: some View {
        let ch: Character? = note.kind == ParaNotes.charKind && !note.authorId.isEmpty ? ((try? Repo.character(note.authorId)) ?? nil) : nil
        let p = MessageActions.transPair(note.text, note.textTrans, mode: mode)
        let name: String = note.authorName.isEmpty ? "未署名" : note.authorName
        return HStack(alignment: .top, spacing: Theme.sp3) {
            Avatar(imageId: ch?.avatar ?? "", name: note.authorName, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13)).foregroundStyle(Theme.text2)
                Text(p.main)
                if !p.sub.isEmpty { Text(p.sub).font(.footnote).foregroundStyle(Theme.text3) }
            }
        }
    }
}
