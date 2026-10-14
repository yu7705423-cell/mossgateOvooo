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

    @State private var chat: Chat?
    @State private var char: Character?
    @State private var messages: [Message] = []
    @State private var turn: ChatEngine.Turn?
    @State private var pageSize = 100
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
    @State private var showStickers = false
    @State private var composing: InteractSheet.Kind?
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    struct ViewingImage: Identifiable { let id: String }

    var body: some View {
        VStack(spacing: 0) {
            if chat?.isGroup == true {
                Text("原生版暂不支持群聊，消息只供查看。")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
                    .padding(Theme.gap)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.gap) {
                        if hasMore {
                            Button("加载更早的消息") { pageSize += 100; reload() }
                                .font(.footnote).padding(.top, Theme.gap)
                        }
                        // 开场白：会话里还没有消息时显示，不存进库、不发给模型（网页版同样）
                        if messages.isEmpty, let greet = char?.firstMessage, !greet.isEmpty, chat?.isGroup != true {
                            HStack(alignment: .top, spacing: Theme.gap) {
                                Avatar(imageId: char?.avatar ?? "", name: char?.displayName ?? "")
                                Text(greet)
                                    .padding(.horizontal, Theme.pad).padding(.vertical, 8)
                                    .foregroundStyle(Theme.bubbleTheirsText)
                                    .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                                Spacer(minLength: 48)
                            }
                            .padding(.horizontal, Theme.pad)
                        }
                        ForEach(messages) { m in
                            MessageRow(message: m, char: char,
                                       onRetry: m.isError ? { retry(m) } : nil,
                                       onOpenImage: { viewing = ViewingImage(id: $0) },
                                       onAction: { act($0, m) })
                                .id(m.id)
                        }
                        if busy {
                            Text("正在回复")
                                .font(.footnote).foregroundStyle(Theme.tertiaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.pad)
                                .id("busy")
                        } else if let turn, chat?.isGroup != true {
                            turnBar(turn)
                        }
                    }
                    .padding(.vertical, Theme.pad)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.last?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .onAppear {
                    if let id = messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            if let problem {
                Text(problem)
                    .font(.footnote).foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.pad).padding(.top, Theme.gap)
            }
            if chat?.isGroup != true { composer }
        }
        .navigationTitle(char?.displayName ?? chat?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { Image(systemName: "ellipsis") }.accessibilityLabel("会话设置")
            }
        }
        .navigationDestination(isPresented: $showSettings) {
            ChatSettingsView(chatId: chatId, onDeleted: { showSettings = false; dismiss() })
        }
        .onAppear(perform: reload)
        .onDisappear { markRead() }
        .fullScreenCover(item: $viewing) { v in ImageViewer(imageId: v.id) }
        .sheet(item: $editing) { m in
            NavigationStack {
                EditMessageView(message: m) { saved in
                    replace(saved)
                    editing = nil
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
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
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
            if let q = quoting {
                HStack {
                    Text("引用：\(q.content)").font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    Spacer()
                    Button { quoting = nil } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("取消引用")
                }
                .padding(.horizontal, Theme.pad).padding(.top, Theme.gap)
            }
            HStack(alignment: .bottom, spacing: Theme.gap) {
                // 一次选几张不设上限（网页版第 13 条）
                PhotosPicker(selection: $picked, maxSelectionCount: nil, matching: .images) {
                    Image(systemName: "photo").font(.title2)
                }
                .accessibilityLabel("发送图片")
                .disabled(busy)
                Menu {
                    Button { composing = .transfer } label: { Label("转账", systemImage: "yensign.circle") }
                    Button { composing = .gift } label: { Label("礼物", systemImage: "gift") }
                    Button { composing = .takeout } label: { Label("外卖", systemImage: "takeoutbag.and.cup.and.straw") }
                    Button { composing = .location } label: { Label("位置", systemImage: "mappin.and.ellipse") }
                    Button { post { try ChatEngine.pat(chatId: chatId) } } label: { Label("拍一拍", systemImage: "hand.tap") }
                } label: {
                    Image(systemName: "plus.circle").font(.title2)
                }
                .accessibilityLabel("更多")
                .disabled(busy)
                Button {
                    showStickers.toggle()
                    if showStickers { typing = false }
                } label: {
                    Image(systemName: showStickers ? "keyboard" : "face.smiling").font(.title2)
                }
                .accessibilityLabel(showStickers ? "收起表情" : "表情")
                .disabled(busy)
                TextField("输入消息", text: $draft, axis: .vertical)
                    .focused($typing)
                    .onChange(of: typing) { _, t in if t { showStickers = false } }
                    .lineLimit(1...5)
                    .padding(.horizontal, Theme.pad).padding(.vertical, 8)
                    .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                if busy {
                    Button { job?.cancel() } label: {
                        Image(systemName: "stop.circle").font(.title2)
                    }
                    .accessibilityLabel("停止")
                } else {
                    Button(action: primary) {
                        Image(systemName: draftEmpty ? "sparkles" : "arrow.up.circle.fill").font(.title2)
                    }
                    .accessibilityLabel(draftEmpty ? "请角色回复" : "发送")
                }
            }
            .padding(Theme.pad)
            if showStickers {
                StickerPanel { st in sendSticker(st) }
            }
        }
        .background(Theme.background)
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
            let list = try Repo.messages(chatId: chatId, limit: pageSize + 1)
            hasMore = list.count > pageSize
            messages = Array(list.suffix(pageSize))
            turn = try ChatEngine.lastTurn(chatId: chatId)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func markRead() {
        guard var c = try? Repo.chat(chatId), c.unread > 0 else { return }
        c.row["unread"] = .number(0)
        do { try Repo.save(c) } catch { Problems.report("未读数写入失败：\(error.localizedDescription)") }
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
    var onSaved: (Message) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                TextField("内容", text: $text, axis: .vertical).lineLimit(3...20)
            } footer: {
                if message.role == .char {
                    Text("修改后，角色在之后的对话中看到的是修改后的内容。")
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("编辑消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do { onSaved(try MessageActions.edit(message, text: text)) }
                    catch { problem = "保存失败：\(error.localizedDescription)" }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { text = message.content }
    }
}

/// 一条消息。按 kind 画；不认识的 kind 居中显示它的 content（协议文字，和网页版旧版的兜底一致）。
/// 长按出菜单（系统的上下文菜单，贴着这一条弹出，网页版第 23 条）。
struct MessageRow: View {
    enum Action { case copy, quote, edit, recall, delete, settle(Bool), react(String) }

    let message: Message
    let char: Character?
    var onRetry: (() -> Void)?
    var onOpenImage: ((String) -> Void)?
    var onAction: ((Action) -> Void)?

    /// 角色撤回的那一条要过一会儿才折起来；到时间刷新一次
    @State private var tick = false
    /// 撤回的那一条点一下看原文
    @State private var reveal = false

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
                    case "text", "image", "clip", "voice", "sticker", "location", "dice", "transfer", "gift", "takeout":
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
                .contextMenu { menu }
            }
        }
        .task(id: message.id) {
            let wait = message.recallWait
            guard wait > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 50_000_000)
            tick.toggle()
        }
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
        Button { onAction?(.copy) } label: { Label("复制", systemImage: "doc.on.doc") }
        Button { onAction?(.quote) } label: { Label("引用", systemImage: "quote.bubble") }
        if MessageActions.canEdit(message) {
            Button { onAction?(.edit) } label: { Label("编辑", systemImage: "pencil") }
        }
        if MessageActions.canRecall(message) {
            Button { onAction?(.recall) } label: { Label("撤回", systemImage: "arrow.uturn.backward") }
        }
        Button(role: .destructive) { onAction?(.delete) } label: { Label("删除", systemImage: "trash") }
    }

    private var bubbleRow: some View {
        HStack(alignment: .top, spacing: Theme.gap) {
            if mine { Spacer(minLength: 48) }
            if !mine { Avatar(imageId: char?.avatar ?? "", name: char?.displayName ?? "") }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                let quote = message.row.string("quoteText")
                if !quote.isEmpty {
                    Text("引用：\(quote)").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
                content
                if let t = message.row["translation"]?.string, !t.isEmpty {
                    Text(t).font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                if let inner = message.row["inner"]?.string, !inner.isEmpty {
                    Text("心声：\(inner)").font(.footnote).foregroundStyle(Theme.tertiaryText)
                }
                reactions
                if !mine, let ban = message.row["ban"]?.array, !ban.isEmpty {
                    Text("命中禁写：\(ban.compactMap(\.string).joined(separator: "、"))").font(.caption).foregroundStyle(Theme.danger)
                }
            }
            if !mine { Spacer(minLength: 48) }
        }
        .padding(.horizontal, Theme.pad)
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
        case "image", "clip":
            card(icon: message.kind == "image" ? "photo" : "video", text: message.row.string("prompt").isEmpty ? message.content : message.row.string("prompt"))
        case "voice":
            card(icon: "waveform", text: message.row.string("voiceText").isEmpty ? message.content : message.row.string("voiceText"))
        case "location":
            card(icon: "mappin.and.ellipse", text: [message.row.string("place"), message.row.string("address")].filter { !$0.isEmpty }.joined(separator: " "))
        case "dice":
            card(icon: "dice", text: "\(Int(message.row.number("value") ?? 0))")
        case "transfer":
            transferCard
        case "gift":
            giftCard
        case "takeout":
            takeoutCard
        default:
            // 正则替换里「屏幕上显示」的那一份
            bubble(RegexRules.forDisplay(message.content, .init(who: mine ? "user" : "char", whereIs: "online", charIds: char.map { [$0.id] } ?? []), settings: SettingsModel.shared.s))
        }
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .textSelection(.disabled)
            .padding(.horizontal, Theme.pad).padding(.vertical, 8)
            .foregroundStyle(mine ? Theme.bubbleMineText : Theme.bubbleTheirsText)
            .background(mine ? Theme.bubbleMine : Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
    }

    private func card(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.gap) {
            Image(systemName: icon).foregroundStyle(Theme.secondaryText)
            Text(text).foregroundStyle(Theme.bubbleTheirsText)
        }
        .padding(Theme.pad)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
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
                    Button { onAction?(.react(e)) } label: {
                        Text(n > 1 ? "\(e) \(n)" : e).font(.footnote)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(mineToo ? Theme.placeholder : Theme.bubbleTheirs, in: Capsule())
                    }
                    .buttonStyle(.plain)
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
