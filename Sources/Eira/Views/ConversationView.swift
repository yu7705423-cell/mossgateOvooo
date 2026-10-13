import PhotosUI
import SwiftUI

/// 一段一对一会话。
///
/// 发送与回复分开（网页版默认的「手动」节奏）：输入框里有字时点发送是发出这一条；
/// 输入框为空时点发送是请角色回复这一轮。一轮只调一次接口。
struct ConversationView: View {
    let chatId: String

    @State private var chat: Chat?
    @State private var char: Character?
    @State private var messages: [Message] = []
    @State private var pageSize = 100
    @State private var hasMore = false
    @State private var draft = ""
    @State private var busy = false
    @State private var job: Task<Void, Never>?
    @State private var problem: String?
    @State private var picked: [PhotosPickerItem] = []
    @State private var viewing: ViewingImage?

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
                        ForEach(messages) { m in
                            MessageRow(message: m, char: char, onRetry: m.isError ? { retry(m) } : nil,
                                       onOpenImage: { viewing = ViewingImage(id: $0) })
                                .id(m.id)
                        }
                        if busy {
                            Text("正在回复")
                                .font(.footnote).foregroundStyle(Theme.tertiaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.pad)
                                .id("busy")
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
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            sendPhotos(items)
        }
    }

    private var composer: some View {
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
                    Image(systemName: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "sparkles" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .accessibilityLabel(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请角色回复" : "发送")
            }
        }
        .padding(Theme.pad)
        .background(Theme.background)
    }

    // MARK: - 动作

    private func primary() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { generate(); return }
        do {
            let m = try ChatEngine.send(text: text, chatId: chatId)
            draft = ""
            messages.append(m)
            problem = nil
        } catch {
            problem = "消息未能保存：\(error.localizedDescription)"
        }
    }

    private func generate() {
        guard !busy else { return }
        busy = true
        problem = nil
        let id = chatId
        job = Task {
            do {
                try await ChatEngine.reply(chatId: id) { m in
                    Task { @MainActor in
                        if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i] = m } else { messages.append(m) }
                    }
                }
            } catch let e as AIError where e.cancelled {
                // 用户点了停止：已经落下的几条留着
            } catch is CancellationError {
                // 同上：停在两条之间的停顿里
            } catch is AIError {
                // 接口出错：已经落成一条失败的消息，带「重新请求」，不再重复显示
            } catch {
                await MainActor.run { problem = error.localizedDescription }
            }
            await MainActor.run { busy = false }
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
                    await MainActor.run { messages.append(m) }
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

/// 一条消息。按 kind 画；不认识的 kind 居中显示它的 content（协议文字，和网页版旧版的兜底一致）。
struct MessageRow: View {
    let message: Message
    let char: Character?
    var onRetry: (() -> Void)?
    var onOpenImage: ((String) -> Void)?

    private var mine: Bool { message.role == .user }

    var body: some View {
        Group {
            if message.isRecalled {
                centered(mine ? "你撤回了一条消息" : "对方撤回了一条消息")
            } else if message.isError {
                errorRow
            } else {
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
        }
    }

    private var bubbleRow: some View {
        HStack(alignment: .top, spacing: Theme.gap) {
            if mine { Spacer(minLength: 48) }
            if !mine { Avatar(imageId: char?.avatar ?? "", name: char?.displayName ?? "") }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
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
