import SwiftUI

/// 元模式的会话页（网页版 chat/pages/MetaChat.js，ARCHITECTURE 4.817、4.832、4.851、4.903）。
/// 角色会话页里的东西（加号、心声、记忆、主动消息、标记解析……）一样都不用。回复按 Markdown 画。
/// 发出只落一条、不自动回复（4.851）：可以连发，再点「让对方回复」。长按：复制、编辑、引用、撤回、重新生成、从这里重新生成、
/// 存为世界书、多选、删除。
struct MetaChatView: View {
    let chatId: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var chat: Chat?
    @State private var messages: [Message] = []
    @State private var missing = false
    @State private var draft = ""
    @State private var quoting: Message?
    @State private var busy = false
    @State private var live = ""
    @State private var job: Task<Void, Never>?
    @State private var problem: String?
    @State private var notice: String?
    @State private var showStickers = false
    @State private var editing: Message?
    @State private var editText = ""
    @State private var loreText: String?
    @State private var picking: Set<String>?
    @State private var opened: Set<String> = []
    @FocusState private var typing: Bool

    var body: some View {
        Group {
            if missing {
                EmptyState(title: "这个元不存在或已删除")
            } else {
                VStack(spacing: 0) {
                    list
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp1)
                    }
                    if let notice {
                        Text(notice).font(.footnote).foregroundStyle(Theme.text2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp1)
                    }
                    if picking != nil { pickBar } else { composer }
                    if showStickers && picking == nil {
                        StickerPanel { st in sendSticker(st) }
                    }
                }
            }
        }
        .background(Theme.bg)
        .navigationTitle(busy ? "正在输入" : Meta.nameOf(chat))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { MetaSettingsView(chatId: chatId) } label: { NavIcon("more") }.accessibilityLabel("设置")
            }
        }
        .onAppear(perform: open)
        .onDisappear { Meta.looking.remove(chatId) }
        .onChange(of: scenePhase) { _, p in
            if p == .active { Meta.looking.insert(chatId); clearUnread() } else { Meta.looking.remove(chatId) }
        }
        .onReceive(NotificationCenter.chatChangesSettled) { _ in if !busy { reload() } }
        .sheet(item: $editing) { m in
            NavigationStack {
                Form { TextField("内容", text: $editText, axis: .vertical).lineLimit(3...20) }
                    .navigationTitle("编辑消息").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") { saveEdit(m) } }
                    }
            }
        }
        .sheet(isPresented: Binding(get: { loreText != nil }, set: { if !$0 { loreText = nil } })) {
            OocSaveSheet(chatId: chatId, initial: loreText ?? "", meta: true) { notice = $0; picking = nil }
        }
    }

    // MARK: - 列表

    private var lastTurnIds: Set<String> { Set(Meta.lastTurn(messages).map(\.id)) }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.sp3) {
                    if messages.isEmpty && !busy {
                        Text("默认只发送对话记录本身，不附加任何设定。在右上角可以填写系统提示词、选择预设与世界书。")
                            .font(.footnote).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                            .padding(Theme.sp5)
                    }
                    let last = lastTurnIds
                    ForEach(messages) { m in
                        row(m, inLast: last.contains(m.id)).id(m.id)
                    }
                    if busy {
                        HStack {
                            Group {
                                if live.isEmpty { Text("正在输入").font(.system(size: 14)).foregroundStyle(Theme.text3) }
                                else { MarkdownView(text: live) }
                            }
                            .padding(Theme.sp3)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
                            Spacer(minLength: 24)
                        }
                        .padding(.horizontal, Theme.sp4).id("live")
                    }
                }
                .padding(.vertical, Theme.sp3)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) } }
            .onChange(of: live) { _, _ in proxy.scrollTo("live", anchor: .bottom) }
            .onAppear { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
        }
    }

    @ViewBuilder private func row(_ m: Message, inLast: Bool) -> some View {
        let mine = m.role == .user
        let picked = picking?.contains(m.id) == true
        HStack(alignment: .top, spacing: Theme.sp2) {
            if picking != nil {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle").foregroundStyle(picked ? Theme.accent : Theme.text3)
            }
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                bubble(m)
                if inLast, let head = Meta.lastTurn(messages).first, head.id == m.id { versions(head) }
            }
            if !mine { Spacer(minLength: 24) }
        }
        .padding(.horizontal, Theme.sp4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard var p = picking else { return }
            if p.contains(m.id) { p.remove(m.id) } else { p.insert(m.id) }
            picking = p
        }
        .contextMenu { if picking == nil { menu(m, inLast: inLast) } }
    }

    @ViewBuilder private func bubble(_ m: Message) -> some View {
        let mine = m.role == .user
        if m.isRecalled {
            Button { if opened.contains(m.id) { opened.remove(m.id) } else { opened.insert(m.id) } } label: {
                Text(opened.contains(m.id) ? "你撤回了一条消息：\(m.content)" : "你撤回了一条消息")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain)
        } else if m.kind == "sticker" {
            StickerView(id: m.row.string("stickerId"), name: m.row.string("stickerName")).frame(width: 112, height: 112)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if !m.row.string("quoteText").isEmpty {
                    Text(m.row.string("quoteText")).font(.system(size: 12)).foregroundStyle(mine ? Theme.bubbleMineText.opacity(0.7) : Theme.text3)
                        .lineLimit(2).padding(.leading, 6)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
                }
                if mine {
                    Text(m.content).font(.system(size: 15)).foregroundStyle(Theme.bubbleMineText).fixedSize(horizontal: false, vertical: true)
                } else {
                    MarkdownView(text: m.content)
                }
            }
            .padding(.horizontal, Theme.bubblePadX).padding(.vertical, Theme.bubblePadY)
            .background(mine ? Theme.bubbleMine : Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
        }
    }

    /// 最后一轮有好几个版本时，下面左右翻（不调接口）
    @ViewBuilder private func versions(_ head: Message) -> some View {
        let swipes = head.row["swipes"]?.array ?? []
        if swipes.count > 1 {
            let i = Int(head.row.number("swipeIndex") ?? Double(swipes.count - 1))
            HStack(spacing: Theme.sp3) {
                Button { flip(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上一个版本")
                Text("\(i + 1) / \(swipes.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.text3)
                Button { flip(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下一个版本")
            }
            .font(.system(size: 12)).foregroundStyle(Theme.text2).disabled(busy)
        }
    }

    @ViewBuilder private func menu(_ m: Message, inLast: Bool) -> some View {
        let mine = m.role == .user
        Button { UIPasteboard.general.string = m.content } label: { Label("复制", systemImage: "doc.on.doc") }
        if m.kind == "text" && !m.isRecalled {
            Button { editText = m.content; editing = m } label: { Label("编辑", systemImage: "pencil") }
            Button { quoting = m; typing = true } label: { Label("引用", systemImage: "quote.bubble") }
        }
        if MessageActions.canRecall(m) {
            Button { act { replace(try MessageActions.recall(m)) } } label: { Label("撤回", systemImage: "arrow.uturn.backward") }
        }
        if !mine && inLast && !busy {
            Button { reply(regenerate: true) } label: { Label("重新生成", systemImage: "arrow.clockwise") }
        }
        if mine && !busy && m.id != messages.last?.id {
            Button { act { try Meta.cutAfter(m.id, chatId: chatId) }; reload(); reply() } label: {
                Label("从这里重新生成", systemImage: "arrow.counterclockwise")
            }
        }
        if m.kind == "text" && !m.isRecalled {
            Button { loreText = m.content } label: { Label("存为世界书", systemImage: "book") }
        }
        Button { picking = [m.id] } label: { Label("多选", systemImage: "checklist") }
        Button(role: .destructive) { act { try Database.shared.delete(Collections.messages, id: m.id) }; reload() } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private var pickBar: some View {
        let ids = picking ?? []
        let chosen = messages.filter { ids.contains($0.id) }
        return HStack {
            Button("取消") { picking = nil }
            Spacer()
            Button("存为世界书") { loreText = chosen.filter { $0.kind == "text" }.map(\.content).joined(separator: "\n\n") }
                .disabled(!chosen.contains { $0.kind == "text" })
            Spacer()
            Button("删除", role: .destructive) {
                act { for m in chosen { try Database.shared.delete(Collections.messages, id: m.id) } }
                picking = nil
                reload()
            }
            .disabled(chosen.isEmpty)
        }
        .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp3)
        .background(Theme.surface)
    }

    // MARK: - 输入栏

    private var composer: some View {
        VStack(spacing: Theme.sp1) {
            if let quoting {
                HStack {
                    Text("引用：\(quoting.content)").font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
                    Spacer()
                    Button { self.quoting = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("取消引用")
                }
                .padding(.horizontal, Theme.sp4)
            }
            HStack(alignment: .bottom, spacing: Theme.sp2) {
                Button { showStickers.toggle(); if showStickers { typing = false } } label: {
                    SvgIcon(name: "smile", size: 22, color: Theme.text)
                }
                .accessibilityLabel("表情")
                TextField("Aa…", text: $draft, axis: .vertical)
                    .focused($typing)
                    .onChange(of: typing) { _, t in if t { showStickers = false } }
                    .lineLimit(1...6)
                    .font(.system(size: 15))
                    .padding(.horizontal, Theme.sp3).padding(.vertical, Theme.sp2)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
                if busy {
                    Button { job?.cancel() } label: { SvgIcon(name: "close", size: 20, color: Theme.text) }.accessibilityLabel("停止")
                } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { reply() } label: { SvgIcon(name: "message", size: 22, color: Theme.text) }
                        .accessibilityLabel("让对方回复")
                        .disabled(messages.isEmpty)
                } else {
                    Button(action: send) { SvgIcon(name: "send", size: 22, color: Theme.accent) }.accessibilityLabel("发送")
                }
            }
            .padding(.horizontal, Theme.sp3).padding(.vertical, Theme.sp2)
        }
        .background(Theme.bg)
    }

    // MARK: - 动作

    private func open() {
        do {
            if Meta.valid(chatId) { try Meta.ensure(chatId) } else { missing = true; return }
        } catch { problem = "未能建立这段会话：\(error.localizedDescription)" }
        Meta.looking.insert(chatId)
        clearUnread()
        reload()
        // 离开再回来：回复还在跑就照样「正在输入」（4.851）
        if ChatEngine.isReplying(chatId) && job == nil { busy = true; poll() }
    }

    private func poll() {
        Task {
            while ChatEngine.isReplying(chatId) { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            await MainActor.run { if job == nil { busy = false; live = "" }; reload() }
        }
    }

    private func reload() {
        do {
            chat = try Repo.chat(chatId)
            messages = try Repo.messages(chatId: chatId)
            if chat == nil && chatId != Meta.firstChatId { missing = true }
        } catch { problem = "读取失败：\(error.localizedDescription)" }
    }

    private func clearUnread() {
        guard let c = try? Repo.chat(chatId), c.unread > 0 else { return }
        act { try Meta.set(chatId, ["unread": .number(0)]) }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
    }

    private func replace(_ m: Message) {
        if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i] = m }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let m = try Meta.send(text, chatId: chatId, quote: quoting)
            messages.append(m)
            draft = ""
            quoting = nil
            problem = nil
        } catch { problem = "消息未能保存：\(error.localizedDescription)" }
    }

    private func sendSticker(_ st: Stickers.Item) {
        do {
            let m = try ChatEngine.sendSticker(st, chatId: chatId, quote: quoting)
            messages.append(m)
            quoting = nil
            problem = nil
        } catch { problem = "消息未能保存：\(error.localizedDescription)" }
    }

    private func saveEdit(_ m: Message) {
        let t = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { problem = "内容不能为空。如需移除请使用删除"; return }
        var out = m
        out.row["content"] = .string(t)
        out.row.touch()
        act { try Repo.save(out); replace(out) }
        editing = nil
    }

    private func reply(regenerate: Bool = false) {
        guard !busy else { return }
        busy = true
        live = ""
        problem = nil
        notice = nil
        let id = chatId
        job = Task {
            ChatEngine.Replying.begin(id)
            defer { ChatEngine.Replying.end(id) }
            do {
                try await Meta.reply(chatId: id, regenerate: regenerate) { t in Task { @MainActor in live = t } }
            } catch let e as AIError where e.cancelled {
                // 停下：已经收到的那部分照常留下
            } catch is CancellationError {
            } catch {
                let msg = (regenerate ? "重新生成失败，原来的回复未改动：" : "回复失败：") + error.localizedDescription
                await MainActor.run { problem = msg }
            }
            await MainActor.run {
                busy = false
                live = ""
                job = nil
                reload()
            }
        }
    }

    private func flip(_ step: Int) {
        act { try Meta.switchVersion(chatId: chatId, step: step) }
        reload()
    }
}

/// 元的设置页（网页版 MetaSettings.js）。默认只发送对话记录本身，各项均为空或关闭时不附加任何内容
struct MetaSettingsView: View {
    let chatId: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = SettingsModel.shared
    @State private var chat: Chat?
    @State private var system = ""
    @State private var name = ""
    @State private var problem: String?
    @State private var confirmClear = false
    @State private var confirmDrop = false
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        Form {
            if let c = chat {
                let x = Meta.cfg(c)
                Section {
                    Text("默认只发送对话记录本身。下列各项均为空或关闭时，不附加任何内容。").font(.footnote).foregroundStyle(Theme.text2)
                }
                Section {
                    TextField("名字", text: $name).onSubmit { save(["metaName": .string(name.trimmingCharacters(in: .whitespaces))]) }
                    HelpNote("只用于区分几个元，不发送给模型。", title: "元：名字")
                    Picker("回复用的接口", selection: Binding(get: { x.apiId }, set: { save(["metaApiId": .string($0)]) })) {
                        Text("跟随主用").tag("")
                        ForEach(model.s.chatPresets) { p in
                            Text((p.name.isEmpty ? "未命名接口" : p.name) + (p.usable ? "" : "（未填全，改用主用）")).tag(p.id)
                        }
                    }
                    HelpNote("这个元的回复使用哪一套聊天接口。可以每个元各选一套，例如分别对话不同厂商的模型。选了某一套时只用这一套，失败不换下一套；跟随主用时按「设置 - 接口」中的设置决定是否换下一套。", title: "元：回复用的接口")
                    Toggle("一段一条", isOn: bind("metaSplit", x.split))
                    HelpNote("开启后，元的回复按空行分成多条消息显示，代码块不拆开。只改变显示方式，发送的内容与调用次数不变。关闭后每次回复为一条。", title: "元：一段一条")
                }
                Section {
                    TextField("留空", text: $system, axis: .vertical).lineLimit(4...14)
                    HelpNote("填写后作为系统提示词随每一轮发送，可使用 {{char}} 与 {{user}}。留空则不发送。", title: "元：系统提示词")
                } header: { Text("系统提示词") }
                Section {
                    Picker("使用的预设", selection: Binding(get: { x.presetId }, set: { save(["metaPresetId": .string($0)]) })) {
                        Text("不使用").tag("")
                        ForEach(Presets.list(model.s)) { p in Text(p.name.isEmpty ? "未命名预设" : p.name).tag(p.id) }
                    }
                    HelpNote("选择后使用该预设中自行添加的条目；预设中内置的提示词不发送。", title: "元：使用的预设")
                    NavigationLink { MetaBooksView(chatId: chatId) } label: {
                        LabeledContent("世界书", value: x.books.isEmpty ? "未挂" : "已挂 \(x.books.count) 本")
                    }
                    HelpNote("挂上的世界书按条目自己的开关与关键词触发；标为全局的世界书不会自动带入这段会话。", title: "元：世界书")
                } header: { Text("预设与世界书") }
                Section {
                    Toggle("当前时间", isOn: bind("metaTime", x.time))
                    HelpNote("开启后，每一轮在系统提示词末尾附上当前的日期、星期、时刻与时区。不额外调用接口。关闭后不附加。", title: "元：当前时间")
                    Toggle("距上一条消息", isOn: bind("metaGap", x.gap))
                    HelpNote("开启后，每一轮在系统提示词末尾附上距上一轮对话过去了多久。不额外调用接口。关闭后不附加。", title: "元：距上一条消息")
                } header: { Text("时间") }
                Section {
                    let has = !(((try? Database.shared.all("stickers")) ?? []).isEmpty)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("表情包", isOn: Binding(get: { x.sticker }, set: { v in act { try Meta.setCap(chatId, "sticker", v) } }))
                        if !has { Text("表情库中还没有表情包，在聊天的表情面板中添加后可用。").font(.footnote).foregroundStyle(Theme.text2) }
                    }
                    HelpNote("开启后，系统提示词后附上表情包的写法与表情库中的名称，元回复中独占一行的 [表情：名称] 显示为表情包。名称须与表情库一致，对不上的不显示。你这边发表情包不受这一项影响。", title: "元：可以发送表情包")
                } header: { Text("元可以发送") }
                Section {
                    Picker("在消息列表中", selection: Binding(get: { Meta.place(model.s) }, set: { v in
                        model.update { $0.raw["metaPlace"] = .string(v) }
                    })) {
                        Text("单独一组").tag("group")
                        Text("与其他会话一起").tag("mix")
                    }
                    HelpNote("单独一组：所有元排在角色会话下面单独一组。与其他会话一起：元与角色会话按时间排在一起，同样可以置顶、左滑与长按。对所有元生效。", title: "元：在消息列表中")
                    if Meta.place(model.s) == "mix" { Button("新建元") { newName = ""; creating = true } }
                    NavigationLink("上一轮发送的内容") { SentPageView(chatId: chatId) }
                    Button("清空聊天记录", role: .destructive) { confirmClear = true }.foregroundStyle(Theme.dangerText)
                    Button("删除这个元", role: .destructive) { confirmDrop = true }.foregroundStyle(Theme.dangerText)
                }
            } else {
                Text("这个元不存在或已删除。").foregroundStyle(Theme.text2)
            }
            ProblemSection(text: problem ?? model.problem)
        }
        .navigationTitle(Meta.nameOf(chat))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear(perform: flush)
        .confirmationDialog("这段会话的消息全部删除，无法恢复。系统提示词、预设与世界书的选择保留。", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { act { try Meta.clear(chatId) } }
        }
        .confirmationDialog("这个元的聊天记录、设置与它名下的记忆一并删除，无法恢复。世界书保留。", isPresented: $confirmDrop, titleVisibility: .visible) {
            Button("删除", role: .destructive) { act { try Meta.remove(chatId) }; chat = nil; dismiss() }
        }
        .alert("新建元", isPresented: $creating) {
            TextField("\(Meta.name) \(Meta.list().count + 1)", text: $newName)
            Button("取消", role: .cancel) {}
            Button("新建") { act { _ = try Meta.create(newName) } }
        }
    }

    private func bind(_ key: String, _ v: Bool) -> Binding<Bool> { Binding(get: { v }, set: { save([key: .bool($0)]) }) }

    private func load() {
        chat = (try? Repo.chat(chatId)) ?? nil
        let x = Meta.cfg(chat)
        system = x.system
        name = chat?.row.string("metaName") ?? ""
    }

    /// 系统提示词与名字离开时存一次（没改的不写）
    private func flush() {
        guard let c = (try? Repo.chat(chatId)) ?? nil else { return }
        var patch: [String: JSONValue] = [:]
        if system != c.row.string("metaSystem") { patch["metaSystem"] = .string(system) }
        let n = name.trimmingCharacters(in: .whitespaces)
        if n != c.row.string("metaName") { patch["metaName"] = .string(n) }
        if !patch.isEmpty { save(patch) }
    }

    private func save(_ patch: [String: JSONValue]) {
        act { try Meta.set(chatId, patch) }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); chat = try Repo.chat(chatId); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}

/// 挂哪几本世界书（网页版 MetaBooksPage）：书多时能搜，挂上的排在前面
struct MetaBooksView: View {
    let chatId: String
    @State private var query = ""
    @State private var books: [String] = []
    @State private var problem: String?

    var body: some View {
        let all = Meta.bookChoices()
        let key = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hit: (Lorebook) -> Bool = { key.isEmpty || $0.name.lowercased().contains(key) }
        let on = all.filter { books.contains($0.id) && hit($0) }
        let off = all.filter { !books.contains($0.id) && hit($0) }
        List {
            if all.isEmpty { EmptyState(title: "尚无世界书", desc: "在「设定集 - 世界书」中创建后，可在这里挂上。").listRowBackground(Color.clear) }
            if !on.isEmpty { Section { ForEach(on) { row($0) } } header: { Text("已挂上 · \(on.count)") } }
            if !off.isEmpty { Section { ForEach(off) { row($0) } } header: { Text("未挂上 · \(off.count)") } }
            if !all.isEmpty && on.isEmpty && off.isEmpty { Text("没有符合的世界书。").foregroundStyle(Theme.text3) }
            ProblemSection(text: problem)
        }
        .searchable(text: $query, prompt: "搜索世界书")
        .navigationTitle("世界书")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { books = ((try? Repo.chat(chatId)) ?? nil)?.row.strings("metaBooks") ?? [] }
    }

    private func row(_ b: Lorebook) -> some View {
        Toggle(isOn: Binding(get: { books.contains(b.id) }, set: { v in
            let next = v ? books + [b.id] : books.filter { $0 != b.id }
            do { try Meta.set(chatId, ["metaBooks": .array(next.map { .string($0) })]); books = next; problem = nil }
            catch { problem = "未能保存：\(error.localizedDescription)" }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(b.name.isEmpty ? "未命名世界书" : b.name)
                Text("\(b.entries.count) 条").font(.footnote).foregroundStyle(Theme.text2)
            }
        }
    }
}
