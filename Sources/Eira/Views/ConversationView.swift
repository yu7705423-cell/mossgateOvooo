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
                TextField("输入消息", text: $draft, axis: .vertical)
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
        }
        .background(Theme.background)
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
                } catch {
                    failed += 1
                    lastError = error.localizedDescription
                }
            }
            let summary = failed > 0 ? "有 \(failed) 张图片未能发送：\(lastError)" : nil
            await MainActor.run { problem = summary }
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
    enum Action { case copy, quote, edit, recall, delete }

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
                    case "text", "image", "clip", "voice", "sticker", "location", "dice":
                        bubbleRow
                    case "narration":
                        Text(message.row.string("narration").isEmpty ? message.content : message.row.string("narration"))
                            .font(.footnote.italic()).foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity).padding(.horizontal, Theme.pad * 2)
                    case "silence":
                        centered("对方已读，未回复")
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

    @ViewBuilder private var menu: some View {
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
        default:
            bubble(message.content)
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
