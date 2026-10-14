import PhotosUI
import SwiftUI
import UIKit

/// 一段一对一会话。
///
/// 发送与回复分开（网页版默认的「手动」节奏）：输入框里有字时点发送是发出这一条；
/// 输入框为空时点发送是请角色回复这一轮。一轮只调一次接口。
///
/// 长按一条消息：复制、引用、编辑、撤回、删除。最后一轮下面有「重新生成」与版本切换。
struct ConversationView: View {
    let chatId: String
    /// 从搜索进来时要跳到的那一条
    var focusId: String? = nil

    @State private var chat: Chat?
    @State private var char: Character?
    @State private var members: [String: Character] = [:]
    @State private var messages: [Message] = []
    @State private var turn: ChatEngine.Turn?
    /// 一次画多少条：设置里的 chatPage（默认 60，0 为全画），往上翻按同样的数继续（网页版第 13 条：默认值不是上限）
    @State private var pageSize = ConversationView.pageStep
    static var pageStep: Int {
        let n = Int(AppSettings.load().num("chatPage", 60))
        return n > 0 ? n : 1_000_000
    }
    @State private var hasMore = false
    @State private var draft = ""
    @State private var quoting: Message?
    @State private var busy = false
    @State private var job: Task<Void, Never>?
    @State private var problem: String?
    @State private var picked: [PhotosPickerItem] = []
    @State private var viewing: ViewingImage?
    @State private var editing: Message?
    @State private var deleting: Message?
    @State private var showSettings = false
    @State private var showSearch = false
    /// 要滚过去的那一条；滚到之后闪一下
    @State private var jumpTo: String?
    @State private var flashId: String?
    @State private var forwarding = false
    @State private var openedForward: Message?
    @State private var editingTrans: Message?
    @State private var showStickers = false
    @State private var showPanel = false
    @State private var me: Persona?
    /// 最后一条在不在屏幕上：在的时候来了新消息才自动滚到底；往上翻着看时不把人拽下去，只数一数来了几条
    @State private var atBottom = true
    @State private var unseen = 0
    @State private var earlier = 0
    /// 多选：nil 为没在选
    @State private var picking: Set<String>?
    @State private var confirmBatchDelete = false
    @State private var notice: String?
    @State private var rememberedMemory: RememberedMemory?
    struct RememberedMemory: Identifiable { var id: String; var charId: String }
    @State private var composing: InteractSheet.Kind?
    @State private var recordingVoice = false
    @State private var calling: Character?
    @ObservedObject private var music = MusicPlayer.shared
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    struct ViewingImage: Identifiable { let id: String }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                messageScroll(proxy)
            }
            if let problem {
                Text(problem)
                    .font(.footnote).foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.pad).padding(.top, Theme.gap)
            }
            if picking != nil { pickBar } else { composer }
        }
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(picking != nil)
        .toolbar {
            if let picked = picking {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { picking = nil } }
                ToolbarItem(placement: .principal) {
                    Text("已选 \(picked.count) 条").font(.system(size: 17, weight: .semibold))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("全选") { picking = Set(messages.map(\.id)) }
                }
            } else if let char, chat?.isGroup == false, char.row["canCall"]?.bool != false {
                ToolbarItem(placement: .primaryAction) {
                    Button { calling = char } label: { NavIcon("phone") }
                        .accessibilityLabel("语音通话")
                        .disabled(busy)
                }
            }
            if picking == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { NavIcon("more") }.accessibilityLabel("会话设置")
                }
            }
        }
        .confirmationDialog("删除选中的 \(picking?.count ?? 0) 条消息。删除后无法恢复，也不再进入上下文。",
                            isPresented: $confirmBatchDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { removePicked() }
        }
        .sheet(item: $rememberedMemory) { r in
            NavigationStack { MemoryEditView(memoryId: r.id, charId: r.charId) }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        }
        .navigationDestination(isPresented: $showSettings) {
            ChatSettingsView(chatId: chatId, onDeleted: { showSettings = false; dismiss() },
                             onSearch: { showSettings = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showSearch = true } },
                             onSelect: { showSettings = false; picking = [] })
        }
        .sheet(isPresented: $forwarding) {
            NavigationStack {
                ForwardPickView(fromChatId: chatId, count: picking?.count ?? 0) { forwardPicked(to: $0) }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { forwarding = false } } }
            }
        }
        .sheet(item: $openedForward) { m in
            NavigationStack {
                ForwardDetailView(message: m)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { openedForward = nil } } }
            }
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                SearchChatView(chatId: chatId) { _, m in showSearch = false; jump(m) }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showSearch = false } } }
            }
        }
        .onAppear {
            Notifier.shared.visibleChat = chatId
            reload()
        }
        .onDisappear {
            if Notifier.shared.visibleChat == chatId { Notifier.shared.visibleChat = nil }
            markRead()
        }
        // 主动发起对话、后台消息取回落进了这一段：刷新，并当作已读
        .onReceive(NotificationCenter.default.publisher(for: .eiraChatChanged)) { note in
            guard (note.object as? String) == chatId, !busy else { return }
            reload()
            markRead()
        }
        .fullScreenCover(item: $viewing) { v in ImageViewer(imageId: v.id) }
        .sheet(item: $editing) { m in
            NavigationStack {
                EditMessageView(message: m) { saved in
                    replace(saved)
                    editing = nil
                    // 角色的图与语音按描述生成：描述改了，重新生成一份（用户点的，手动的一次）
                    if MessageActions.needsRegen(saved) && MessageActions.editableText(saved) != MessageActions.editableText(m) {
                        act(saved.kind == "image" ? .redraw : .revoice, saved)
                    }
                }
            }
        }
        .sheet(item: $editingTrans) { m in
            NavigationStack {
                EditMessageView(message: m, translation: true) { saved in
                    replace(saved)
                    editingTrans = nil
                }
            }
        }
        .confirmationDialog("删除后无法恢复。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { m in
            Button("删除这条消息", role: .destructive) { remove(m) }
        }
        .sheet(item: $composing) { k in
            NavigationStack {
                InteractSheet(kind: k) { a, b, amount, sub in
                    post {
                        switch k {
                        case .transfer: return try ChatEngine.sendTransfer(chatId: chatId, amount: amount, note: a)
                        case .gift: return try ChatEngine.sendGift(chatId: chatId, cover: a, inner: b)
                        case .takeout: return try ChatEngine.sendTakeout(chatId: chatId, kind: sub, item: a, amount: amount)
                        case .location: return try ChatEngine.sendLocation(chatId: chatId, place: a, address: b)
                        }
                    }
                    composing = nil
                }
            }
        }
        .fullScreenCover(item: $calling) { c in
            CallView(chatId: chatId, char: c) { reload() }
        }
        .sheet(isPresented: $recordingVoice) {
            VoiceComposeView(chatId: chatId, quote: quoting) { m in
                quoting = nil
                if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i] = m } else { messages.append(m) }
                turn = nil
            }
            .presentationDetents([.medium])
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            showPanel = false
            sendPhotos(items)
        }
    }

    /// 最后一轮下面那一行：重新生成，有几个版本时可以左右切换。
    private func turnBar(_ t: ChatEngine.Turn) -> some View {
        HStack(spacing: Theme.pad) {
            if t.versions.swipes.count > 1 {
                Button { switchVersion(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("上一个版本")
                Text("\(t.versions.index + 1)/\(t.versions.swipes.count)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                Button { switchVersion(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("下一个版本")
            }
            Button { generate(regenerate: true) } label: {
                Label("重新生成", systemImage: "arrow.clockwise").font(.footnote)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.pad + Theme.avatarSize + Theme.gap)
        .foregroundStyle(Theme.secondaryText)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if music.listenChat == chatId { ListenBar(chatId: chatId) }
            if let q = quoting {
                HStack {
                    Text("引用：\(q.content)").font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    Spacer()
                    Button { quoting = nil } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("取消引用")
                }
                .padding(.horizontal, Theme.pad).padding(.top, Theme.gap)
            }
            // 网页版的输入栏（.composer-bar）：加号、输入框、表情、发送。和消息区同底，不画分隔线
            HStack(alignment: .bottom, spacing: Theme.sp2) {
                sideButton("plus", label: showPanel ? "收起" : "添加内容") {
                    showPanel.toggle()
                    if showPanel { showStickers = false; typing = false }
                }
                TextField("Aa…", text: $draft, axis: .vertical)
                    .focused($typing)
                    .onChange(of: typing) { _, t in if t { showStickers = false; showPanel = false } }
                    .lineLimit(1...5)
                    .font(.system(size: 15))
                    .padding(.horizontal, Theme.sp3).padding(.vertical, Theme.sp2)
                    .frame(minHeight: Theme.composerH)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                sideButton("heart", label: showStickers ? "收起表情" : "表情") {
                    showStickers.toggle()
                    if showStickers { showPanel = false; typing = false }
                }
                if busy {
                    sendButton("close", size: 17, filled: false, stop: true, label: "停止") { job?.cancel() }
                } else if !draftEmpty {
                    sendButton("send", size: 17, filled: true, label: "发送", action: primary)
                } else {
                    sendButton("reply", size: 22, filled: false, label: "请角色回复", action: primary)
                }
            }
            .padding(.horizontal, Theme.sp3)
            .padding(.vertical, Theme.sp2)
            if showPanel { plusPanel }
            if showStickers {
                StickerPanel { st in sendSticker(st) }
            }
        }
        .background(Theme.bg)
    }

    /// 输入栏两侧的圆按钮（.composer-side）
    private func sideButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SvgIcon(name: icon, size: 20, color: Theme.text2)
                .frame(width: Theme.composerH, height: Theme.composerH)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 发送键（.send-btn）：有字时黑底圆键；空着时是「请角色回复」，不垫底；回复中是停止
    private func sendButton(_ icon: String, size: CGFloat, filled: Bool, stop: Bool = false, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SvgIcon(name: icon, size: size, color: filled ? Theme.onAccent : Theme.text)
                .frame(width: Theme.composerH, height: Theme.composerH)
                .background(Circle().fill(filled ? Theme.accent : (stop ? Theme.surface3 : Color.clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 加号面板（.composer-panel .panel-grid）：一行四格，浅灰圆角方块里一个线条图标，下面一行小字
    private var plusPanel: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.sp2), count: 4), spacing: Theme.sp4) {
            PhotosPicker(selection: $picked, maxSelectionCount: nil, matching: .images) {
                panelItem("image", "图片")
            }
            .disabled(busy)
            panelButton("mic", "语音") { recordingVoice = true }
            if chat?.isGroup == false {
                panelButton("headphone", "一起听") {
                    do { try music.startListen(chatId: chatId, autoplay: true) } catch { problem = error.localizedDescription }
                }
            }
            panelButton("wallet", "转账") { composing = .transfer }
            panelButton("gift", "礼物") { composing = .gift }
            panelButton("bag", "外卖") { composing = .takeout }
            panelButton("map", "位置") { composing = .location }
            panelButton("paw", "拍一拍") { post { try ChatEngine.pat(chatId: chatId) } }
            if let chat, chat.isGroup {
                Menu {
                    ForEach(GroupChat.members(chat)) { c in
                        Button(GroupChat.nameIn(chat, c)) { draft += "@\(GroupChat.nameIn(chat, c)) " }
                    }
                } label: { panelItem("users", "提到成员") }
            }
        }
        .padding(.horizontal, Theme.sp4)
        .padding(.top, Theme.sp3)
        .padding(.bottom, Theme.sp5)
        .background(Theme.bg)
        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
    }

    private func panelButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            showPanel = false
            action()
        } label: { panelItem(icon, label) }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func panelItem(_ icon: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            SvgIcon(name: icon, size: 22, color: Theme.text)
                .frame(width: 52, height: 52)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.text2)
        }
    }

    private func togglePick(_ id: String) {
        guard var p = picking else { return }
        if p.contains(id) { p.remove(id) } else { p.insert(id) }
        picking = p
    }

    /// 转发选中的几条：落在对方会话里，不调接口
    private func forwardPicked(to target: Chat) {
        guard let p = picking else { return }
        do {
            let all = try Repo.messages(chatId: chatId).filter { p.contains($0.id) }
            try Forward.send(from: chatId, to: target.id, list: all)
            forwarding = false
            picking = nil
            if target.id == chatId { reload() }
            notice = "已转发 \(all.count) 条消息。"
            NotificationCenter.default.post(name: .eiraChatChanged, object: target.id)
        } catch {
            forwarding = false
            problem = "转发失败：\(error.localizedDescription)"
        }
    }

    private func removePicked() {
        guard let p = picking else { return }
        do {
            for m in messages where p.contains(m.id) { try MessageActions.delete(m) }
            picking = nil
            reload()
        } catch { problem = "删除失败：\(error.localizedDescription)" }
    }

    /// 多选时底下那一条：取消、删除
    private var pickBar: some View {
        HStack {
            Button("取消") { picking = nil }.buttonStyle(EiraButtonStyle(kind: .ghost))
            Spacer()
            Button("转发") { forwarding = true }
                .buttonStyle(EiraButtonStyle(kind: .ghost))
                .disabled(picking?.isEmpty != false)
            Button("删除（\(picking?.count ?? 0)）") { confirmBatchDelete = true }
                .buttonStyle(EiraButtonStyle(kind: .danger))
                .disabled(picking?.isEmpty != false)
        }
        .padding(.horizontal, Theme.sp4)
        .padding(.vertical, Theme.sp2)
        .background(Theme.bg)
        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
    }

    private func post(_ make: () throws -> Message) {
        do {
            messages.append(try make())
            turn = nil
            problem = nil
        } catch {
            problem = "消息未能保存：\(error.localizedDescription)"
        }
    }

    private var isGroup: Bool { chat?.isGroup == true }

    /// 消息列表那一块。拆出来单独推断类型，整页写在 body 里编译器推断不过来
    private func messageScroll(_ proxy: ScrollViewProxy) -> some View {
        ScrollView { messageStack(proxy) }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: messages.last?.id) { _, id in
            guard let id else { return }
            // 自己发的一定滚到底；角色的只在贴着底部时滚，否则在右下角记一个数
            if atBottom || messages.last?.role == .user {
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            } else {
                unseen += 1
            }
        }
        .overlay(alignment: .bottomTrailing) { latestButton(proxy) }
        .onAppear {
            if let focusId { jump(focusId) } else if let id = messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
        }
        .onChange(of: jumpTo) { _, id in
            guard let id else { return }
            jumpTo = nil
            DispatchQueue.main.async {
                proxy.scrollTo(id, anchor: .center)
                withAnimation(.easeOut(duration: 0.2)) { flashId = id }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeOut(duration: 0.4)) { if flashId == id { flashId = nil } }
                }
            }
        }
    }

    private func messageStack(_ proxy: ScrollViewProxy) -> some View {
        LazyVStack(spacing: 0) {
            if hasMore {
                Button(earlier > 0 ? "查看更早的消息（还有 \(earlier) 条）" : "查看更早的消息") {
                    // 加载后视口钉在原来那一条上，不跳到最上面
                    let keep = messages.first?.id
                    pageSize += Self.pageStep
                    reload()
                    if let keep { DispatchQueue.main.async { proxy.scrollTo(keep, anchor: .top) } }
                }
                .font(.system(size: 12)).foregroundStyle(Theme.text2).padding(.vertical, Theme.sp2)
            }
            // 开场白：会话里还没有消息时显示，不存进库、不发给模型（网页版同样）
            if messages.isEmpty, let greet = char?.firstMessage, !greet.isEmpty, chat?.isGroup != true {
                HStack(alignment: .top, spacing: Theme.gap) {
                    Avatar(imageId: char?.avatar ?? "", name: char?.displayName ?? "")
                    Text(greet)
                        .font(.system(size: Theme.bubbleFont))
                        .lineSpacing(Theme.bubbleFont * 0.4)
                        .padding(.horizontal, Theme.bubblePadX).padding(.vertical, Theme.bubblePadY)
                        .foregroundStyle(Theme.bubbleTheirsText)
                        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
                        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                    Spacer(minLength: 48)
                }
                .padding(.horizontal, Theme.pad)
            }
            if messages.isEmpty && (isGroup || (char?.firstMessage ?? "").isEmpty) {
                Text(isGroup ? "发送第一条消息开始群聊。输入 @ 可指定成员回复" : "发送第一条消息开始对话")
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity).padding(.vertical, Theme.sp6)
            }
            // 时刻与已读回执（网页版 receipt.js）：按间隔时两条中间插一行时间；逐条时写在气泡旁边或下方
            let ctx = rowContext()
            ForEach(messages) { m in
                messageCell(m, ctx)
            }
            Color.clear.frame(height: 1)
                .onAppear { atBottom = true; unseen = 0 }
                .onDisappear { atBottom = false }
            if !busy, let turn {
                turnBar(turn)
            }
        }
        .padding(.vertical, Theme.pad)
    }

    /// 往上翻看时右下角那个「回到最新」，带新消息数
    @ViewBuilder private func latestButton(_ proxy: ScrollViewProxy) -> some View {
        if !atBottom && !messages.isEmpty {
            Button {
                if let id = messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                unseen = 0
            } label: {
                SvgIcon(name: "chevronDown", size: 18, color: Theme.text)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.surface).shadow(color: .black.opacity(0.1), radius: 8, y: 4))
                    .overlay(alignment: .topTrailing) {
                        if unseen > 0 {
                            Text(unseen > 99 ? "99+" : "\(unseen)").font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.onAccent).padding(.horizontal, 5)
                                .frame(minWidth: 17, minHeight: 17).background(Theme.accent, in: Capsule())
                                .offset(x: 4, y: -6)
                        }
                    }
            }
            .buttonStyle(.plain)
            .padding(Theme.sp3)
            .accessibilityLabel(unseen > 0 ? "回到最新，\(unseen) 条新消息" : "回到最新")
        }
    }

    /// 一行要用到的、整段会话共用的那几样，算一次传下去（ForEach 里写一长串，编译器推断不过来）
    private struct RowContext {
        var stampMode: String
        var readOn: Bool
        var upTo: Double
        var latestTurn: String
        var prevOf: [String: Message]
    }

    private func rowContext() -> RowContext {
        let st = SettingsModel.shared.s
        return RowContext(
            stampMode: Receipt.stampMode(st),
            readOn: Receipt.on(st),
            upTo: Receipt.readUpTo(messages),
            latestTurn: messages.last { $0.role == .char }?.turnId ?? "",
            prevOf: Dictionary(zip(messages.dropFirst().map(\.id), messages.dropLast()), uniquingKeysWith: { a, _ in a }))
    }

    /// 时刻与已读回执（网页版 receipt.js）：按间隔时两条中间插一行时间；逐条时写在气泡旁边或下方
    @ViewBuilder
    private func messageCell(_ m: Message, _ ctx: RowContext) -> some View {
        let prev: Message? = ctx.prevOf[m.id]
        let sep: Bool = ctx.stampMode == "gap" && Receipt.needSep(prev: prev, cur: m)
        let tight: Bool = !sep && Receipt.cont(prev: prev, cur: m)
        let top: CGFloat = prev == nil ? 0 : (tight ? 5 : Theme.sp4)
        VStack(spacing: 0) {
            if sep {
                Text(Receipt.sepOf(m.createdAt)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                    .padding(.vertical, Theme.sp1).padding(.bottom, Theme.sp3)
            }
            messageRow(m, ctx)
        }
        // 一轮与一轮之间 16；同一个人 3 分钟内接着说的收紧到 5（网页版 --bubble-gap / .is-cont）
        .padding(.top, top)
        .background(flashId == m.id ? Theme.groupFill : Color.clear)
        .id(m.id)
    }

    private func messageRow(_ m: Message, _ ctx: RowContext) -> MessageRow {
        let perEach: Bool = ctx.stampMode == "side" || ctx.stampMode == "below"
        let stamp: String = perEach ? Receipt.stampOf(m.createdAt) : ""
        let read: String = Receipt.textOf(m, upTo: ctx.upTo, on: ctx.readOn)
        let retry: (() -> Void)? = m.isError ? { self.retry(m) } : nil
        return MessageRow(message: m, char: speaker(of: m),
                          showName: isGroup,
                          stamp: stamp,
                          stampBelow: ctx.stampMode == "below",
                          read: read,
                          meAvatar: me?.avatar ?? "", meName: me?.name ?? "我",
                          latestTurn: ctx.latestTurn,
                          translateLang: chat?.row.string("translateTo") ?? "",
                          quoteName: quoteName(of: m),
                          nameOf: { reactorName($0) },
                          picking: picking != nil, picked: picking?.contains(m.id) == true,
                          onPick: { togglePick(m.id) },
                          onRetry: retry,
                          onOpenImage: { viewing = ViewingImage(id: $0) },
                          onAction: { act($0, m) })
    }

    private func reactorName(_ id: String) -> String {
        if id == "me" || id.isEmpty { return me?.name ?? "我" }
        if let c = members[id] { return c.displayName }
        return char?.id == id ? (char?.displayName ?? "对方") : "对方"
    }

    /// 标题：生成中写「正在输入」；群名加人数（成员与我，网页版 group.headcount），单聊是角色备注名
    private var pageTitle: String {
        guard let chat else { return "" }
        if busy { return "正在输入" }
        guard chat.isGroup else { return char?.displayName ?? chat.title }
        let list = chat.characterIds.compactMap { members[$0] }
        return "\(GroupChat.title(chat, members: list))（\(list.count + 1)）"
    }

    /// 引用块上写的名字：引的是我说的就写我的名字，否则写那位角色
    private func quoteName(of m: Message) -> String {
        guard !m.row.string("quoteText").isEmpty else { return "" }
        if m.row.string("quoteRole") == "user" { return me?.name ?? "我" }
        let id = m.row.string("quoteAuthorId")
        return members[id]?.displayName ?? (char?.id == id || id.isEmpty ? char?.displayName ?? "" : "")
    }

    /// 这一条是谁说的：群里按作者找成员，一对一就是这个角色。
    private func speaker(of m: Message) -> Character? {
        guard isGroup, let c = members[m.authorId] else { return char }
        return c
    }

    private func sendSticker(_ st: Stickers.Item) {
        do {
            let m = try ChatEngine.sendSticker(st, chatId: chatId, quote: quoting)
            quoting = nil
            messages.append(m)
            turn = nil
            problem = nil
        } catch {
            problem = "消息未能保存：\(error.localizedDescription)"
        }
    }

    private var draftEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - 动作

    private func primary() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { generate(); return }
        do {
            let m = try ChatEngine.send(text: text, chatId: chatId, quote: quoting)
            draft = ""
            quoting = nil
            messages.append(m)
            turn = nil
            problem = nil
        } catch {
            problem = "消息未能保存：\(error.localizedDescription)"
        }
    }

    private func act(_ action: MessageRow.Action, _ m: Message) {
        switch action {
        case .openForward:
            openedForward = m
        case .editTrans:
            editingTrans = m
        case .jumpQuote:
            let id = m.row.string("quoteId")
            if !id.isEmpty { jump(id) }
        case .translate:
            guard let chat else { return }
            Task {
                do {
                    let out = try await TranslateOne.run(m, chat: chat)
                    await MainActor.run { replace(out) }
                } catch {
                    await MainActor.run { problem = "翻译失败：\(error.localizedDescription)" }
                }
            }
        case .copy:
            UIPasteboard.general.string = m.content
        case .quote:
            quoting = m
        case .edit:
            editing = m
        case .recall:
            do { replace(try MessageActions.recall(m)) }
            catch { problem = "撤回失败：\(error.localizedDescription)" }
        case .delete:
            deleting = m
        case .copySong:
            UIPasteboard.general.string = m.row.string("songQuery").isEmpty ? m.content : m.row.string("songQuery")
        case .remember:
            guard let chat else { return }
            do {
                let r = try MessageActions.remember(m, chat: chat, char: char)
                rememberedMemory = RememberedMemory(id: r.memoryId, charId: r.charId)
            } catch { problem = error.localizedDescription }
        case .example:
            do { notice = try MessageActions.addExample(m) ? "已收进说话示例，可在编辑资料中修改" : "说话示例中已有这一句" }
            catch { problem = error.localizedDescription }
        case .served:
            notice = (try? MessageActions.servedText(m)) ?? "这一条生成时尚未记录模型"
        case .select:
            picking = [m.id]
        case .settle(let yes):
            do {
                let notice = try (m.kind == "gift" ? Interact.settleGift(m.id, open: yes)
                                  : m.kind == "takeout" ? Interact.settleTakeout(m.id, take: yes)
                                  : Interact.settleTransfer(m.id, take: yes))
                if let notice { _ = try Repo.append(notice) }
                reload()
            } catch { problem = "未能保存：\(error.localizedDescription)" }
        case .react(let e):
            do { try Interact.toggleReaction(m.id, emoji: e, by: "me"); reload() }
            catch { problem = "回应未能保存：\(error.localizedDescription)" }
        case .revoice:
            var pending = m
            pending.row["media"] = .string("pending")
            pending.row["mediaError"] = .string("")
            replace(pending)
            Task {
                do { _ = try await VoiceGen.regenerate(messageId: m.id) }
                catch { await MainActor.run { problem = "重新合成失败：\(error.localizedDescription)" } }
                await MainActor.run { reload() }
            }
        case .redraw:
            // 用户点的，手动的一次：改回生成中再画
            var pending = m
            pending.row["media"] = .string("pending")
            pending.row["mediaError"] = .string("")
            replace(pending)
            Task {
                do { _ = try await ImageGen.regenerate(messageId: m.id) }
                catch { await MainActor.run { problem = "重新生成失败：\(error.localizedDescription)" } }
                await MainActor.run { reload() }
            }
        }
    }

    private func replace(_ m: Message) {
        if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i] = m }
    }

    private func remove(_ m: Message) {
        do {
            try MessageActions.delete(m)
            reload()
        } catch {
            problem = "删除失败：\(error.localizedDescription)"
        }
    }

    /// 请角色回复；regenerate 时重新生成最后一轮。新落下的几条到了，旧的那一轮才从屏幕上拿掉。
    private func generate(regenerate: Bool = false) {
        guard !busy else { return }
        busy = true
        problem = nil
        let id = chatId
        let oldIds = regenerate ? Set(turn?.rows.map(\.id) ?? []) : []
        job = Task {
            do {
                try await ChatEngine.reply(chatId: id, regenerate: regenerate) { m in
                    Task { @MainActor in
                        if !oldIds.isEmpty { messages.removeAll { oldIds.contains($0.id) } }
                        if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i] = m } else { messages.append(m) }
                    }
                }
                // 自动总结记忆：门槛到了才调（默认三个门槛都关着），在后台跑，不挡着聊天
                Task.detached { _ = await MemorySummary.autoRun(chatId: id) }
            } catch let e as AIError where e.cancelled {
                // 用户点了停止：已经落下的几条留着
            } catch is CancellationError {
                // 同上：停在两条之间的停顿里
            } catch let e as AIError where !regenerate {
                _ = e   // 已经落成一条失败的消息，带「重新请求」，不再重复显示
            } catch {
                let message = regenerate ? "重新生成失败，原来的回复未改动：\(error.localizedDescription)" : error.localizedDescription
                await MainActor.run { problem = message }
            }
            await MainActor.run {
                busy = false
                reload()
            }
        }
    }

    /// 切到上一个或下一个版本：存着的原文重新切一遍，不调接口。
    private func switchVersion(_ step: Int) {
        guard !busy else { return }
        busy = true
        let id = chatId
        Task {
            do { try await ChatEngine.switchVersion(chatId: id, step: step) { _ in } }
            catch { await MainActor.run { problem = "切换版本失败：\(error.localizedDescription)" } }
            await MainActor.run {
                busy = false
                reload()
            }
        }
    }

    /// 选好的图按顺序一张一张存好、发出去。存不进去的那一张说明原因，其余照发。
    private func sendPhotos(_ items: [PhotosPickerItem]) {
        let id = chatId
        Task {
            var failed = 0
            var lastError = ""
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw StoreError(message: "无法读取所选图片")
                    }
                    let imageId = try Images.save(data)
                    let m = try ChatEngine.sendImage(imageId: imageId, chatId: id)
                    await MainActor.run { messages.append(m); turn = nil }
                    if m.row.string("vision") == "pending" { describe(m.id) }
                } catch {
                    failed += 1
                    lastError = error.localizedDescription
                }
            }
            let summary = failed > 0 ? "有 \(failed) 张图片未能发送：\(lastError)" : nil
            await MainActor.run { problem = summary }
        }
    }

    /// 识图选了单独的接口时，发出去的图在后台读成描述。读不出来照样是一张图，只是角色不知道图上有什么，在屏幕上写明。
    private func describe(_ messageId: String) {
        Task {
            do {
                guard let m = try await Vision.describe(messageId: messageId) else { return }
                await MainActor.run { if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i] = m } }
            } catch {
                await MainActor.run { problem = "识图失败，角色看不到这张图的内容：\(error.localizedDescription)" }
            }
        }
    }

    /// 失败的那一条删掉，重新请求这一轮。
    private func retry(_ m: Message) {
        do {
            try Database.shared.delete(Collections.messages, id: m.id)
            messages.removeAll { $0.id == m.id }
            generate()
        } catch {
            problem = "无法删除失败的那一条：\(error.localizedDescription)"
        }
    }

    private func reload() {
        do {
            chat = try Repo.chat(chatId)
            char = try chat?.characterIds.first.flatMap { try Repo.character($0) }
            me = try Repo.personas().first { $0.id == chat?.personaId } ?? Repo.activePersona()
            if let chat, chat.isGroup {
                members = Dictionary(GroupChat.members(chat).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            let list = try Repo.messages(chatId: chatId, limit: pageSize + 1)
            hasMore = list.count > pageSize
            messages = Array(list.suffix(pageSize))
            earlier = hasMore ? max(0, (try Database.shared.count(Collections.messages, where: chatId)) - messages.count) : 0
            turn = try ChatEngine.lastTurn(chatId: chatId)
        } catch {
            problem = error.localizedDescription
        }
    }

    /// 跳到某一条：还没画出来就把一次画的条数放大到能盖住它，再滚过去
    private func jump(_ id: String) {
        if !messages.contains(where: { $0.id == id }) {
            guard let all = try? Repo.messages(chatId: chatId), let i = all.firstIndex(where: { $0.id == id }) else {
                notice = "这条消息已不存在。"
                return
            }
            pageSize = max(pageSize, all.count - i)
            reload()
        }
        jumpTo = id
    }

    private func markRead() {
        guard var c = try? Repo.chat(chatId), c.unread > 0 else { return }
        c.row["unread"] = .number(0)
        do { try Repo.save(c) } catch { Problems.report("未读数写入失败：\(error.localizedDescription)") }
        Task { await Notifier.updateBadge() }
    }
}

/// 用户发转账、礼物、外卖、位置时填的那一页。有输入框，所以是整页（网页版第 23 条）。
struct InteractSheet: View {
    enum Kind: String, Identifiable { case transfer, gift, takeout, location; var id: String { rawValue } }
    let kind: Kind
    /// (主要的那一项, 第二项, 金额, 外卖的点法)
    let onSend: (String, String, Double, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var a = ""
    @State private var b = ""
    @State private var amount = ""
    @State private var sub = "self"

    private var amountValue: Double? {
        let t = amount.trimmingCharacters(in: .whitespaces)
        if kind == .takeout && t.isEmpty { return 0 }
        guard let v = Double(t), kind == .takeout ? v >= 0 : v > 0 else { return nil }
        return Interact.round(v)
    }

    private var title: String {
        switch kind {
        case .transfer: return "转账"
        case .gift: return "礼物"
        case .takeout: return "外卖"
        case .location: return "位置"
        }
    }

    private var ready: Bool {
        let filled = !a.trimmingCharacters(in: .whitespaces).isEmpty
        switch kind {
        case .transfer: return amountValue != nil
        case .takeout: return filled && amountValue != nil
        case .gift, .location: return filled
        }
    }

    var body: some View {
        Form {
            switch kind {
            case .transfer:
                Section {
                    TextField("金额", text: $amount).keyboardType(.decimalPad)
                    TextField("留言（可不填）", text: $a)
                } footer: {
                    Text("币种：\(Interact.currency().name)。对方可以收下或退回。")
                }
            case .gift:
                Section {
                    TextField("礼物名称", text: $a)
                    TextField("里面是什么（可不填）", text: $b)
                } footer: {
                    Text(Interact.giftBlind() ? "对方拆开之前只看得到礼物名称。里面不填时与名称相同。" : "里面不填时与名称相同。")
                }
            case .takeout:
                Section {
                    Picker("点法", selection: $sub) {
                        Text("自己吃").tag("self")
                        Text("请对方").tag("treat")
                        Text("让对方付").tag("ask")
                    }
                    .pickerStyle(.segmented)
                    TextField("点什么", text: $a)
                    TextField("金额（可不填）", text: $amount).keyboardType(.decimalPad)
                } footer: {
                    Text(sub == "self" ? "自己点自己吃，对方不需要表态。" : sub == "treat" ? "给对方点，自己付。对方可以收下或谢绝。" : "自己吃，让对方付。对方可以付款或不付。")
                }
            case .location:
                Section {
                    TextField("地点名称", text: $a)
                    TextField("地址（可不填）", text: $b)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("发送") { onSend(a, b, amountValue ?? 0, sub) }.disabled(!ready)
            }
        }
    }
}

/// 编辑一条文字消息。
struct EditMessageView: View {
    let message: Message
    /// 改的是译文而不是正文
    var translation = false
    var onSaved: (Message) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                TextField(translation ? "译文" : "内容", text: $text, axis: .vertical).lineLimit(3...20)
            } footer: {
                if translation {
                    Text("译文只在气泡下方显示。清空后保存即去掉译文。")
                } else if MessageActions.needsRegen(message) {
                    Text(message.kind == "image" ? "保存后按新的描述重新生成这张图片，调用一次生图接口。" : "保存后按新的文本重新生成这段语音，调用一次语音接口。")
                } else if message.role == .user && (message.kind == "image" || message.kind == "voice") {
                    Text("只改角色读到的文字，图片或录音本身不变。")
                } else if message.role == .char {
                    Text("修改后，角色在之后的对话中看到的是修改后的内容。")
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle(translation ? "改译文" : MessageActions.editTitle(message))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do { onSaved(try translation ? MessageActions.setTranslation(message, text) : MessageActions.edit(message, text: text)) }
                    catch { problem = "保存失败：\(error.localizedDescription)" }
                }
                .disabled(!translation && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { text = translation ? (message.row["translation"]?.string ?? "") : MessageActions.editableText(message) }
    }
}

/// 一条消息。按 kind 画；不认识的 kind 居中显示它的 content（协议文字，和网页版旧版的兜底一致）。
/// 长按出菜单（系统的上下文菜单，贴着这一条弹出，网页版第 23 条）。
struct MessageRow: View {
    enum Action { case copy, quote, edit, recall, delete, settle(Bool), react(String), redraw, revoice, remember, example, served, copySong, select, openForward, translate, editTrans, jumpQuote }

    let message: Message
    let char: Character?
    /// 群聊里在气泡上方写是谁说的
    var showName = false
    /// 气泡旁或气泡下的时刻、已读回执（空串为不显示）
    var stamp = ""
    var stampBelow = false
    var read = ""
    /// 我这边的头像
    var meAvatar = ""
    var meName = "我"
    /// 最新那一轮的 id：「下一轮收起」时，换了一轮就把点开的译文收回去
    var latestTurn = ""
    /// 这段会话译成哪种语言（空为不翻译）：长按菜单里「翻译 / 改译文」看它
    var translateLang = ""
    /// 引用的那一条是谁说的
    var quoteName = ""
    /// 回应是谁贴的：id 换成名字（me 为我）
    var nameOf: ((String) -> String)?
    /// 多选模式：点一下选中或取消，长按菜单停用
    var picking = false
    var picked = false
    var onPick: (() -> Void)?
    var onRetry: (() -> Void)?
    var onOpenImage: ((String) -> Void)?
    var onAction: ((Action) -> Void)?

    /// 角色撤回的那一条要过一会儿才折起来；到时间刷新一次
    @State private var tick = false
    /// 撤回的那一条点一下看原文
    @State private var reveal = false
    /// 这一张图此刻正在画（应用这次打开以来发出去的）
    @State private var drawing = true
    /// 心声默认藏着，点角色头像才展开（同一轮任意一条的头像都行）
    @State private var innerOpen = false
    /// 译文点一下展开或收起；「一直展开」时默认开着
    @State private var transOpen: Bool?
    /// 左右滑一下引用这一条：跟着手指走，松手弹回
    @State private var swipeX: CGFloat = 0

    private var mine: Bool { message.role == .user }

    var body: some View {
        let _ = tick
        Group {
            if message.isRecalled {
                VStack(spacing: 4) {
                    centered(mine ? "你撤回了一条消息" : "\(char?.displayName ?? "对方")撤回了一条消息")
                    if reveal { centered(message.content) }
                }
                .contentShape(Rectangle())
                .onTapGesture { reveal.toggle() }
            } else if message.isError {
                errorRow
            } else {
                Group {
                    switch message.kind {
                    case "text", "image", "clip", "voice", "sticker", "location", "dice", "transfer", "gift", "takeout", "call", "song", "forward":
                        bubbleRow
                    case "narration":
                        Text(message.row.string("narration").isEmpty ? message.content : message.row.string("narration"))
                            .font(.footnote.italic()).foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity).padding(.horizontal, Theme.pad * 2)
                    case "silence":
                        centered(message.row.bool("reacted") ? "已读，仅回应" : "已读，未回复")
                    case "notice":
                        centered(Self.unbracket(message.content))
                    default:
                        centered(message.content)
                    }
                }
                .contextMenu { if !picking { menu } }
            }
        }
        .overlay {
            if picking {
                Color.clear.contentShape(Rectangle()).onTapGesture { onPick?() }
            }
        }
        .overlay(alignment: .leading) {
            if picking {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(picked ? Theme.accent : Theme.text3)
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
                    .accessibilityLabel(picked ? "已选" : "未选")
            }
        }
        .task(id: message.id) {
            let wait = message.recallWait
            guard wait > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 50_000_000)
            tick.toggle()
        }
    }

    /// 按空行拆开（网页版 helpers.js 的 splitBubbles）
    static func paragraphs(_ s: String) -> [String] {
        let parts = s.components(separatedBy: "\n").reduce(into: [[String]]([[]])) { acc, line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { acc.append([]) } else { acc[acc.count - 1].append(line) }
        }
        let out = parts.map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return out.isEmpty ? [s] : out
    }

    /// 提示行存的是 `[…]`，显示时去掉外面那层括号。
    static func unbracket(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.first == "[", t.last == "]" else { return t }
        return String(t.dropFirst().dropLast())
    }

    @ViewBuilder private var menu: some View {
        if message.kind != "notice" && message.kind != "silence" {
            ControlGroup {
                ForEach(Interact.quick, id: \.self) { e in
                    Button(e) { onAction?(.react(e)) }
                }
            }
        }
        Button { onAction?(.quote) } label: { Label("引用", systemImage: "quote.bubble") }
        if message.kind == "song" {
            Button { onAction?(.copySong) } label: { Label("复制歌名", systemImage: "doc.on.doc") }
        } else {
            Button { onAction?(.copy) } label: { Label("复制", systemImage: "doc.on.doc") }
        }
        if MessageActions.canEdit(message) {
            Button { onAction?(.edit) } label: { Label("编辑", systemImage: "pencil") }
        }
        if TranslateOne.can(message, lang: translateLang) {
            Button { onAction?(.translate) } label: { Label(translation.isEmpty ? "翻译" : "重新翻译", systemImage: "character.bubble") }
        }
        if !message.isRecalled && (TranslateOne.can(message, lang: translateLang) || !translation.isEmpty) {
            Button { onAction?(.editTrans) } label: { Label("改译文", systemImage: "pencil.line") }
        }
        if MessageActions.canRecall(message) {
            Button { onAction?(.recall) } label: { Label("撤回", systemImage: "arrow.uturn.backward") }
        }
        if !mine && message.kind == "image" && SettingsModel.shared.s.imageReady && !message.row.string("prompt").isEmpty {
            Button { onAction?(.redraw) } label: { Label("重画图片", systemImage: "arrow.clockwise") }
        }
        if !MessageActions.bodyText(message).isEmpty {
            Button { onAction?(.remember) } label: { Label("记住这句", systemImage: "brain") }
        }
        if !mine && !MessageActions.bodyText(message).isEmpty && message.kind != "narration" {
            Button { onAction?(.example) } label: { Label("收进示例", systemImage: "text.quote") }
        }
        if !mine && !message.turnId.isEmpty {
            Button { onAction?(.served) } label: { Label("生成信息", systemImage: "info.circle") }
        }
        Button { onAction?(.select) } label: { Label("多选", systemImage: "checklist") }
        Button(role: .destructive) { onAction?(.delete) } label: { Label("删除", systemImage: "trash") }
    }

    private var translation: String { (message.row["translation"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var transShow: String {
        let v = SettingsModel.shared.s.raw["translateShow"]?.string ?? "both"
        return ["both", "trans", "orig"].contains(v) ? v : "both"
    }
    /// 只显示译文时，正文位置换成译文，点一下看到原文
    private var swapTrans: Bool { transShow == "trans" && !translation.isEmpty && message.kind == "text" }
    private var transIsOpen: Bool {
        transOpen ?? (SettingsModel.shared.s.raw["translateOpen"]?.string == "always" && transShow == "both")
    }

    private func avatarView(_ mine: Bool) -> some View {
        Avatar(imageId: mine ? meAvatar : (char?.avatar ?? ""), name: mine ? meName : (char?.displayName ?? ""))
            .onTapGesture {
                guard !mine else { return }
                NotificationCenter.default.post(name: .eiraInnerToggle, object: message.turnId.isEmpty ? message.id : message.turnId)
            }
            .accessibilityAddTraits(mine ? [] : .isButton)
            .accessibilityHint(mine ? "" : "展开或收起这一轮的心声")
    }

    @ViewBuilder private var meta: some View {
        if !stamp.isEmpty || !read.isEmpty {
            VStack(alignment: mine ? .trailing : .leading, spacing: 1) {
                if !stamp.isEmpty { Text(stamp) }
                if !read.isEmpty { Text(read) }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.text3)
            .padding(.bottom, stampBelow ? 0 : 3)
        }
    }

    private var bubbleRow: some View {
        HStack(alignment: .top, spacing: Theme.gap) {
            if mine { Spacer(minLength: 48) }
            if !mine { avatarView(false) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 5) {
                if showName && !mine {
                    Text(char?.displayName ?? "某人").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                let quote = message.row.string("quoteText")
                if !quote.isEmpty {
                    Text(quoteName.isEmpty ? quote : "\(quoteName)：\(quote)")
                        .font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                        .padding(.horizontal, Theme.sp2).padding(.vertical, Theme.sp1)
                        .background(Theme.groupFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .onTapGesture { onAction?(.jumpQuote) }
                        .accessibilityAddTraits(.isButton)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    if mine && !stampBelow { meta }
                    content
                        .contentShape(Rectangle())
                        .onTapGesture { if !translation.isEmpty && transShow != "orig" { transOpen = !transIsOpen } }
                    if !mine && !stampBelow { meta }
                }
                if stampBelow { meta }
                if transShow != "orig" && !translation.isEmpty && transIsOpen {
                    let extra = swapTrans ? message.content : translation
                    Text(extra).font(.system(size: 12)).foregroundStyle(Theme.text3).lineSpacing(3)
                }
                if let inner = message.row["inner"]?.string, !inner.isEmpty, innerOpen {
                    Text("心声：\(inner)").font(.footnote).foregroundStyle(Theme.tertiaryText)
                }
                reactions
                if !mine && message.row.bool("cutOff") {
                    Text("回复在此处中断").font(.caption).foregroundStyle(Theme.text3)
                }
                if !mine, let ban = message.row["ban"]?.array, !ban.isEmpty {
                    Text("命中禁写：\(ban.compactMap(\.string).joined(separator: "、"))").font(.caption).foregroundStyle(Theme.danger)
                }
            }
            if mine { avatarView(true) }
            if !mine { Spacer(minLength: 48) }
        }
        .padding(.horizontal, Theme.pad)
        .offset(x: swipeX)
        // 朝哪边滑都算，滑够松手就引用；起手在屏幕左右边缘那一条里的归系统的返回（网页版 SW_EDGE），竖着走得多的是在翻消息
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { v in
                    let w = UIScreen.main.bounds.width
                    guard !picking, v.startLocation.x > 24, v.startLocation.x < w - 24,
                          abs(v.translation.width) > abs(v.translation.height) * 1.4 else { return }
                    swipeX = max(-64, min(64, v.translation.width * 0.6))
                }
                .onEnded { _ in
                    if abs(swipeX) >= 40 {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onAction?(.quote)
                    }
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { swipeX = 0 }
                }
        )
        .onChange(of: latestTurn) { _, _ in
            if SettingsModel.shared.s.raw["translateOpen"]?.string == "turn" { transOpen = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .eiraInnerToggle)) { n in
            guard let key = n.object as? String, message.row["inner"]?.string?.isEmpty == false else { return }
            if key == message.id || (!message.turnId.isEmpty && key == message.turnId) { innerOpen.toggle() }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case "sticker":
            StickerView(id: message.row.string("stickerId"), name: message.row.string("stickerName"))
        case "image" where !message.imageId.isEmpty:
            LocalImage(id: message.imageId, maxPixel: 800, fit: true)
                .frame(maxWidth: 220, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                .onTapGesture { onOpenImage?(message.imageId) }
                .accessibilityLabel("图片")
                .accessibilityAddTraits(.isButton)
        case "image":
            imageCard
        case "clip":
            card(icon: "video", text: message.row.string("prompt").isEmpty ? message.content : message.row.string("prompt"))
        case "call":
            CallCard(message: message)
        case "song":
            SongCard(message: message)
        case "voice":
            VoiceBubble(message: message, mine: mine) { onAction?(.revoice) }
        case "location":
            card(icon: "mappin.and.ellipse", text: [message.row.string("place"), message.row.string("address")].filter { !$0.isEmpty }.joined(separator: " "))
        case "dice":
            diceCard
        case "transfer":
            transferCard
        case "gift":
            giftCard
        case "takeout":
            takeoutCard
        case "forward":
            ForwardCard(message: message)
                .onTapGesture { onAction?(.openForward) }
        default:
            // 正则替换里「屏幕上显示」的那一份；只显示译文时正文位置换成译文。按空行拆成几个气泡（网页版 splitBubbles）
            let shown = swapTrans ? translation : RegexRules.forDisplay(message.content, .init(who: mine ? "user" : "char", whereIs: "online", charIds: char.map { [$0.id] } ?? []), settings: SettingsModel.shared.s)
            let paras = Self.paragraphs(shown)
            VStack(alignment: mine ? .trailing : .leading, spacing: 5) {
                ForEach(paras.indices, id: \.self) { i in bubble(paras[i]) }
            }
        }
    }

    /// 角色发的图还没有画出来：描述，加上生成中、中断或失败的原因。能重新生成时给一个按钮。
    private var imageCard: some View {
        let media = message.row.string("media")
        let err = message.row.string("mediaError")
        let prompt = message.row.string("prompt").isEmpty ? message.content : message.row.string("prompt")
        let canRedraw = !mine && SettingsModel.shared.s.imageReady && !(media == "pending" && drawing)
        return VStack(alignment: .leading, spacing: 6) {
            card(icon: "photo", text: prompt)
            if media == "pending" {
                if drawing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在生成图片").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    Text("生成已中断").font(.caption).foregroundStyle(Theme.secondaryText)
                }
            } else if !err.isEmpty {
                Text(err).font(.caption).foregroundStyle(media == "error" ? Theme.danger : Theme.secondaryText)
            }
            if canRedraw && media != "done" {
                Button("重新生成") { onAction?(.redraw) }.font(.footnote).buttonStyle(.bordered)
            }
        }
        .task(id: "\(message.id)|\(media)") {
            drawing = media == "pending" && MediaJobs.isRunning(message.id)
        }
    }

    /// 气泡（.bubble）：角色的是白底加一道很淡的阴影，自己的是黑底白字；14 号字，行高 1.6
    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.bubbleFont))
            .lineSpacing(Theme.bubbleFont * 0.4)
            .textSelection(.disabled)
            .padding(.horizontal, Theme.bubblePadX).padding(.vertical, Theme.bubblePadY)
            .foregroundStyle(mine ? Theme.bubbleMineText : Theme.bubbleTheirsText)
            .background(mine ? Theme.bubbleMine : Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
            .shadow(color: .black.opacity(mine ? 0 : 0.06), radius: 1, y: 1)
    }

    /// 骰子：点数，加一行「骰子」或「N 面骰」
    private var diceCard: some View {
        let faces = Int(message.row.number("faces") ?? 6)
        return HStack(alignment: .firstTextBaseline, spacing: Theme.sp2) {
            Text("\(Int(message.row.number("value") ?? 0))").font(.system(size: 24, weight: .semibold).monospacedDigit())
            Text(faces == 6 ? "骰子" : "\(faces) 面骰").font(.system(size: 12)).foregroundStyle(Theme.text3)
        }
        .foregroundStyle(Theme.bubbleTheirsText)
        .padding(.horizontal, Theme.pad).padding(.vertical, Theme.sp2)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    }

    private func card(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.gap) {
            Image(systemName: icon).foregroundStyle(Theme.secondaryText)
            Text(text).font(.system(size: Theme.bubbleFont)).foregroundStyle(Theme.bubbleTheirsText)
        }
        .padding(Theme.pad)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    }

    /// 贴在这一条上的回应，按 emoji 归并。点自己贴的那一个就是取消。
    @ViewBuilder private var reactions: some View {
        let list = message.row["reactions"]?.array ?? []
        if !list.isEmpty {
            let groups = Dictionary(grouping: list.compactMap { r -> (String, String)? in
                guard let e = r["e"]?.string else { return nil }
                return (e, r["by"]?.string ?? "")
            }, by: { $0.0 })
            let order = list.compactMap { $0["e"]?.string }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            HStack(spacing: 4) {
                ForEach(order, id: \.self) { e in
                    let n = groups[e]?.count ?? 0
                    let mineToo = groups[e]?.contains { $0.1 == "me" } ?? false
                    let who = (groups[e] ?? []).map { nameOf?($0.1) ?? $0.1 }.joined(separator: "、")
                    Button { onAction?(.react(e)) } label: {
                        Text(n > 1 ? "\(e) \(n)" : e).font(.footnote)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(mineToo ? Theme.placeholder : Theme.bubbleTheirs, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Text("回应者：\(who)") }
                    .accessibilityLabel("\(e)，\(who)")
                }
            }
        }
    }

    /// 转账：金额、留言、状态。对方发来、还没处理的那一张可以收下或退回。
    private var transferCard: some View {
        let state = message.row.string("transfer")
        let code = message.row.string("currency")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.gap) {
                Image(systemName: "yensign.circle").foregroundStyle(Theme.secondaryText)
                Text(Interact.display(message.row.number("amount") ?? 0, code.isEmpty ? nil : code)).font(.headline)
            }
            let note = message.row.string("note")
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) }
            Text(Interact.transferLabel(state)).font(.caption).foregroundStyle(Theme.secondaryText)
            if !mine && state == "pending" {
                HStack {
                    Button("收下") { onAction?(.settle(true)) }
                    Button("退回") { onAction?(.settle(false)) }.foregroundStyle(Theme.secondaryText)
                }
                .font(.footnote).buttonStyle(.bordered)
            }
        }
        .padding(Theme.pad)
        .frame(minWidth: 160, alignment: .leading)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
    }

    /// 礼物：封面；拆开之后写里面是什么。自己送出去的在对方拆开之前也写明里面是什么（只有自己看得到）。
    private var giftCard: some View {
        let state = message.row.string("gift")
        let cover = message.row.string("cover")
        let inner = message.row.string("inner")
        let showInner = !inner.isEmpty && inner != cover && (state == "opened" || mine)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.gap) {
                Image(systemName: "gift").foregroundStyle(Theme.secondaryText)
                Text(cover).font(.headline)
            }
            if showInner { Text("里面是：\(inner)").font(.footnote).foregroundStyle(Theme.secondaryText) }
            Text(Interact.giftLabel(state)).font(.caption).foregroundStyle(Theme.secondaryText)
            if !mine && state == "pending" {
                HStack {
                    Button("拆开") { onAction?(.settle(true)) }
                    Button("拒收") { onAction?(.settle(false)) }.foregroundStyle(Theme.secondaryText)
                }
                .font(.footnote).buttonStyle(.bordered)
            }
        }
        .padding(Theme.pad)
        .frame(minWidth: 160, alignment: .leading)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
    }

    /// 外卖、请客、代付。对方请客或让你代付、还没表态的那一单可以表态。
    private var takeoutCard: some View {
        let kind = message.row.string("takeoutKind")
        let state = message.row.string("takeout")
        let code = message.row.string("currency")
        let title = kind == "treat" ? "请客" : kind == "ask" ? "代付" : "外卖"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.gap) {
                Image(systemName: "takeoutbag.and.cup.and.straw").foregroundStyle(Theme.secondaryText)
                Text("\(title)：\(message.row.string("item"))").font(.headline)
            }
            Text(Interact.display(message.row.number("amount") ?? 0, code.isEmpty ? nil : code)).font(.footnote).foregroundStyle(Theme.secondaryText)
            let label = Interact.takeoutLabel(kind, state)
            if !label.isEmpty { Text(label).font(.caption).foregroundStyle(Theme.secondaryText) }
            if !mine && state == "pending" && kind != "self" {
                HStack {
                    Button(kind == "treat" ? "收下" : "付款") { onAction?(.settle(true)) }
                    Button(kind == "treat" ? "谢绝" : "不付") { onAction?(.settle(false)) }.foregroundStyle(Theme.secondaryText)
                }
                .font(.footnote).buttonStyle(.bordered)
            }
        }
        .padding(Theme.pad)
        .frame(minWidth: 160, alignment: .leading)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
    }

    private func centered(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Theme.tertiaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.horizontal, Theme.pad * 2)
    }

    private var errorRow: some View {
        VStack(spacing: 4) {
            Text("回复失败：\(message.error)").font(.footnote).foregroundStyle(Theme.danger)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button("重新请求", action: onRetry).font(.footnote)
            }
        }
        .frame(maxWidth: .infinity).padding(.horizontal, Theme.pad * 2)
    }
}

/// 表情：库里存了图就用本地图，否则用网址，都没有显示名字。
struct StickerView: View {
    let id: String
    let name: String

    private var row: Row? {
        guard !id.isEmpty, let r = try? Database.shared.get("stickers", id: id) else { return nil }
        return r
    }

    var body: some View {
        let imageId = row?.string("imageId") ?? ""
        let url = row.flatMap { URL(string: $0.string("url")) }
        Group {
            if !imageId.isEmpty {
                LocalImage(id: imageId, maxPixel: 360, fit: true)
            } else if let url, url.scheme?.hasPrefix("http") == true {
                AsyncImage(url: url) { img in img.resizable().scaledToFit() } placeholder: { Theme.placeholder }
            } else {
                Text("[表情：\(name)]").foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: 120, maxHeight: 120)
    }
}

extension Notification.Name {
    /// 点了角色头像：展开或收起那一轮的心声（object 是 turnId，没有 turnId 时是消息 id）
    static let eiraInnerToggle = Notification.Name("eira.innerToggle")
}
