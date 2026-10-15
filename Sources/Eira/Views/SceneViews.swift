import SwiftUI

// 线下（网页版 apps/chat/pages/StageList.js、StageRead.js、StageSettings.js）。
// 一场一页：顶上署名与地点时刻，下面一段一段的正文。写的时候正文就在页面里往下长。

/// 这段会话的各场线下。从会话的加号面板进来
struct SceneListView: View {
    let chatId: String
    @State private var rows: [Row] = []
    @State private var creating = false
    @State private var opened: String?
    @State private var deleting: Row?
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                Button { creating = true } label: { Label("新的一场", systemImage: "plus") }
                HelpNote("线下：与角色当面相处，正文写成大段散文。一场挂在这段会话上，和线上共用角色卡、世界书、记忆与人设。线下的正文按时间排进线上的聊天记录，线上回复时读得到见面时发生的事。每写一段调用一次接口。", title: "线下")
            }
            if !rows.isEmpty {
                Section("各场") {
                    ForEach(rows, id: \.id) { r in
                        Button { opened = r.id } label: { row(r) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("删除", role: .destructive) { deleting = r }
                            }
                    }
                }
            }
            Section {
                NavigationLink("线下的外观") { StageLookView(sceneId: nil) }
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("线下")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .navigationDestination(isPresented: $creating) {
            SceneSetupView(chatId: chatId, sceneId: nil) { id in
                creating = false
                reload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { opened = id }
            }
        }
        .navigationDestination(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil; reload() } })) {
            if let id = opened { SceneReadView(sceneId: id) }
        }
        .confirmationDialog("删除这一场及其全部正文。无法恢复。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { r in
            Button("删除", role: .destructive) {
                do { try Scene.remove(r.id); reload() } catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        }
    }

    private func row(_ r: Row) -> some View {
        let title = r.string("title").isEmpty ? (r.string("place").isEmpty ? "未命名的一场" : r.string("place")) : r.string("title")
        let count = Scene.told(r.id).count
        let sub = [Self.date(r.number("updatedAt") ?? r.created ?? 0), "\(count) 段",
                   (r.number("endedAt") ?? 0) > 0 ? "已收场" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(Theme.text)
            Text(sub).font(.footnote).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    static func date(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let c = Calendar.current.dateComponents([.month, .day], from: Date(millis: ms))
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    private func reload() { rows = Scene.ofChat(chatId) }
}

// MARK: - 这一场的设置

/// 新建一场或改这一场的设置。sceneId 为 nil 时新建
struct SceneSetupView: View {
    let chatId: String
    let sceneId: String?
    var onDone: (String) -> Void = { _ in }

    @State private var draft = Scene.Draft()
    @State private var left: [String: JSONValue] = [:]
    @State private var chatChars: [Character] = []
    @State private var others: [Character] = []
    @State private var books: [Lorebook] = []
    @State private var tones: [Tone.Preset] = []
    @State private var problem: String?
    @State private var loaded = false
    @State private var editingTone: Tone.Preset?
    @Environment(\.dismiss) private var dismiss

    private var editing: Bool { sceneId != nil }

    var body: some View {
        Form {
            Section {
                TextField("标题", text: $draft.title)
                HelpNote("留空时列表中显示地点。", title: "线下：标题")
                TextField("地点，例如 旧书店", text: $draft.place)
                HelpNote("作为这一场的事实进入上下文。", title: "线下：地点")
                TextField("时刻，例如 2026-01-01 周三 14:30", text: $draft.at)
                HelpNote("这一场从什么时候开始。之后由正文里的时间标记继续推进。", title: "线下：时刻")
            }
            Section("情境") {
                TextField("例如 两人约好在这里见面，但对方迟到了四十分钟", text: $draft.note, axis: .vertical)
                    .lineLimit(3...8)
                HelpNote("这一场的前提。作为事实进入上下文，不作为写法上的要求。", title: "线下：情境")
            }
            if !editing {
                Section("谁先写") {
                    Picker("谁先写", selection: $draft.opening) {
                        Text("角色先写").tag(Scene.CHAR)
                        Text("我先写").tag(Scene.ME)
                    }
                    .pickerStyle(.segmented)
                }
            }
            castSection
            toneSection
            booksSection
            ProblemSection(text: problem)
        }
        .navigationTitle(editing ? "这一场" : "新的一场")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(editing ? "保存" : "开始", action: save).disabled(present.isEmpty && !editing)
            }
        }
        .onAppear(perform: load)
        .sheet(item: $editingTone) { t in
            NavigationStack { ToneEditView(preset: t) { reloadTones() } }
        }
    }

    // MARK: 在场角色

    private var present: [String] { draft.castIds.filter { left[$0] == nil || left[$0] == .null } }

    private func stateOf(_ id: String) -> String {
        if !draft.castIds.contains(id) { return "out" }
        if let v = left[id], v != .null { return "left" }
        return "in"
    }

    private func cycle(_ id: String) {
        switch stateOf(id) {
        case "out": draft.castIds.append(id); left[id] = nil
        case "in" where editing: left[id] = .number(Date().millis)
        default: draft.castIds.removeAll { $0 == id }; left[id] = nil
        }
    }

    private var castSection: some View {
        Section {
            ForEach(chatChars + others, id: \.id) { c in
                Button { cycle(c.id) } label: {
                    HStack {
                        Avatar(imageId: c.avatar, name: c.name, size: 30)
                        Text(c.displayName).foregroundStyle(Theme.text)
                        Spacer()
                        Text(["in": "在场", "left": "已离开", "out": "不在场"][stateOf(c.id)] ?? "")
                            .foregroundStyle(stateOf(c.id) == "in" ? Theme.text : Theme.text2)
                    }
                }
            }
            Toggle("角色可以自行进场", isOn: $draft.autoEnter)
            HelpNote(editing ? "点一下在「在场」「已离开」「不在场」之间切换。会话之外的角色只在这一场出现，不加进会话，也不记入记忆。开启「角色可以自行进场」后，会话里尚未在场的成员可由在场的角色叫进来。"
                     : "会话之外的角色也可以拉进这一场，只在这一场出现，不加进会话，也不记入记忆。开启「角色可以自行进场」后，会话里尚未在场的成员可由在场的角色叫进来。",
                     title: "线下：在场角色")
        } header: { Text("在场角色") }
    }

    // MARK: 文风

    private var toneSection: some View {
        Section {
            Button {
                draft.tones = []
            } label: {
                HStack { Text("不设定").foregroundStyle(Theme.text); Spacer(); if draft.tones.isEmpty { Image(systemName: "checkmark") } }
            }
            ForEach(tones) { t in
                Button { flipTone(t.id) } label: {
                    HStack {
                        Text(t.name).foregroundStyle(Theme.text)
                        Spacer()
                        if draft.tones.contains(t.id) { Image(systemName: "checkmark") }
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        do { try Tone.remove(t.id); draft.tones.removeAll { $0 == t.id }; reloadTones() }
                        catch { problem = "删除失败：\(error.localizedDescription)" }
                    }
                    Button("编辑") { editingTone = t }
                }
            }
            Button { flipTone("custom") } label: {
                HStack { Text("这一场自己写").foregroundStyle(Theme.text); Spacer(); if draft.tones.contains("custom") { Image(systemName: "checkmark") } }
            }
            if draft.tones.contains("custom") {
                TextField("写这一场要的文风。可以用 {{charName}} 与 {{userName}} 指代双方。", text: $draft.toneText, axis: .vertical)
                    .lineLimit(3...10)
            }
            Button("新建一份文风") { editingTone = Tone.Preset(id: "", name: "", text: "") }
            Button("恢复出厂的几份") {
                do { try Tone.resetBuiltin(); reloadTones() } catch { problem = "恢复失败：\(error.localizedDescription)" }
            }
            HelpNote("写入这一场的提示词，只管怎么写，不管角色是什么人。可以选多份，按选中的顺序依次写入。默认不设定，由角色卡与世界书决定。左滑一份可以编辑或删除；「恢复出厂的几份」让改过或删掉的内置预设回到原样，自己新建的不受影响。", title: "线下：文风")
        } header: { Text("文风") }
    }

    private func flipTone(_ id: String) {
        if draft.tones.contains(id) { draft.tones.removeAll { $0 == id } } else { draft.tones.append(id) }
    }

    private func reloadTones() {
        tones = Tone.list()
        SettingsModel.shared.reload()
    }

    // MARK: 世界书

    private var booksSection: some View {
        let attached = Set(chatChars.flatMap(\.lorebookIds))
        let mine = books.filter { $0.global || attached.contains($0.id) }
        let rest = books.filter { !($0.global || attached.contains($0.id)) }
        return Group {
            if !mine.isEmpty {
                Section {
                    ForEach(mine, id: \.id) { b in
                        Toggle(isOn: Binding(get: { !draft.offBookIds.contains(b.id) }, set: { on in
                            if on { draft.offBookIds.removeAll { $0 == b.id } } else { draft.offBookIds.append(b.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.name.isEmpty ? "未命名" : b.name)
                                Text(b.global ? "全局" : "角色已挂").font(.footnote).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                    HelpNote("这一场生效的世界书。角色已挂的与全局的默认生效，可以在这一场关掉；库里其余的书可以只在这一场挂上。", title: "线下：世界书")
                } header: { Text("这一场的世界书") }
            }
            if !rest.isEmpty {
                Section("只在这一场挂上") {
                    ForEach(rest, id: \.id) { b in
                        Toggle(b.name.isEmpty ? "未命名" : b.name, isOn: Binding(get: { draft.bookIds.contains(b.id) }, set: { on in
                            if on { draft.bookIds.append(b.id) } else { draft.bookIds.removeAll { $0 == b.id } }
                        }))
                    }
                }
            }
        }
    }

    // MARK: 读写

    private func load() {
        guard !loaded else { return }
        loaded = true
        let chat = (try? Repo.chat(chatId)) ?? nil
        chatChars = (chat?.characterIds ?? []).compactMap { (try? Repo.character($0)) ?? nil }
        let mineIds = Set(chatChars.map(\.id))
        others = ((try? Repo.characters()) ?? []).filter { !mineIds.contains($0.id) && !$0.isNpc }
        books = ((try? Repo.lorebooks()) ?? []).filter { $0.purpose == "chat" }
        tones = Tone.list()
        if let sceneId, let r = Scene.get(sceneId) {
            draft.title = r.string("title"); draft.place = r.string("place"); draft.at = r.string("at"); draft.note = r.string("note")
            draft.castIds = r.strings("castIds")
            draft.tones = Tone.ids(r); draft.toneText = r.string("toneText")
            draft.offBookIds = r.strings("offBookIds"); draft.bookIds = r.strings("bookIds")
            draft.autoEnter = r["autoEnter"]?.bool != false
            draft.enterIds = r["enterIds"]?.array?.compactMap(\.string)
            left = Scene.leftMap(r)
            // 这一场拉进来的会话外的角色也要列出来
            for id in draft.castIds where !chatChars.contains(where: { $0.id == id }) && !others.contains(where: { $0.id == id }) {
                if let c = (try? Repo.character(id)) ?? nil { others.append(c) }
            }
        } else {
            // 群里开线下：全员在场；上一次挑的文风、关掉的书预填（只是默认值）
            draft.castIds = chatChars.map(\.id)
            let s = AppSettings.load()
            draft.tones = (s.raw["sceneToneLast"]?.array ?? []).compactMap(\.string).filter { id in id == "custom" || tones.contains { $0.id == id } }
            draft.offBookIds = (s.raw["sceneBooksOffLast"]?.array ?? []).compactMap(\.string)
            draft.bookIds = (s.raw["sceneBooksOnLast"]?.array ?? []).compactMap(\.string)
        }
    }

    private func save() {
        do {
            if let sceneId {
                var patch: [String: JSONValue] = [
                    "title": .string(draft.title.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "place": .string(draft.place.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "at": .string(draft.at.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "note": .string(draft.note.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "castIds": .array(draft.castIds.map { .string($0) }),
                    "left": .object(left.filter { draft.castIds.contains($0.key) && $0.value != .null }),
                    "tones": .array(draft.tones.map { .string($0) }), "toneText": .string(draft.toneText),
                    "offBookIds": .array(draft.offBookIds.map { .string($0) }), "bookIds": .array(draft.bookIds.map { .string($0) }),
                    "autoEnter": .bool(draft.autoEnter),
                ]
                patch["enterIds"] = draft.enterIds.map { .array($0.map { .string($0) }) } ?? .null
                try Scene.update(sceneId, patch)
                SettingsModel.shared.reload()
                onDone(sceneId)
                dismiss()
            } else {
                let row = try Scene.create(chatId: chatId, draft)
                SettingsModel.shared.reload()
                onDone(row.id)
            }
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
        }
    }
}

/// 新建或改一份文风
struct ToneEditView: View {
    let preset: Tone.Preset
    var onSaved: () -> Void
    @State private var name = ""
    @State private var text = ""
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("名称") { TextField("例如 克制", text: $name) }
            Section("正文") {
                TextField("这段话会原样写进提示词", text: $text, axis: .vertical).lineLimit(8...20)
                HelpNote("这段话会原样写进提示词。英文写的指令不容易把措辞漏进输出里。可以用 {{charName}} 与 {{userName}} 指代双方。", title: "线下：文风正文")
            }
            ProblemSection(text: problem)
        }
        .navigationTitle(preset.id.isEmpty ? "新建文风" : "编辑文风")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    do {
                        if preset.id.isEmpty { try Tone.create(name: n.isEmpty ? "未命名" : n, text: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        else { try Tone.save(preset.id, name: n.isEmpty ? "未命名" : n, text: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        onSaved()
                        dismiss()
                    } catch { problem = "保存失败：\(error.localizedDescription)" }
                }
            }
        }
        .onAppear { name = preset.name; text = preset.text }
    }
}

// MARK: - 正文页

struct SceneReadView: View {
    let sceneId: String

    @State private var scene: Row?
    @State private var chat: Chat?
    @State private var me: Persona?
    @State private var beats: [Row] = []
    @State private var look = Stage.look(Stage.config())
    @State private var draft = ""
    @State private var director = false
    @State private var hold = false
    @State private var writing = false
    @State private var live = ""
    @State private var job: Task<Void, Never>?
    @State private var problem: String?
    @State private var notice: String?
    @State private var editing: Row?
    @State private var editText = ""
    @State private var showSetup = false
    @State private var showLook = false
    @State private var confirmEnd = false
    @State private var dropping: Row?
    @State private var opened = false
    @FocusState private var typing: Bool

    private var ended: Bool { (scene?.number("endedAt") ?? 0) > 0 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: look.paraGap * 1.6) {
                        header
                        ForEach(beats, id: \.id) { b in beatView(b) }
                        if writing {
                            Text(live.isEmpty ? "正在写" : live)
                                .font(look.font()).foregroundStyle(live.isEmpty ? look.dim : look.ink)
                                .lineSpacing(look.lineSpacing)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("live")
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Theme.sp5)
                    .padding(.vertical, Theme.sp6)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: beats.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: live) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) } }
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Theme.danger)
                    .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(look.bg)
            }
            composer
        }
        .background(look.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(look.bg, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("这一场的设置") { showSetup = true }
                    Button("线下的外观") { showLook = true }
                    if ended {
                        Button("重新开场") { reopen() }
                    } else {
                        Button("收场") { confirmEnd = true }
                    }
                } label: { SvgIcon(name: "more", size: 20, color: look.ink) }
                .accessibilityLabel("更多")
            }
        }
        .navigationDestination(isPresented: $showSetup) {
            if let chat { SceneSetupView(chatId: chat.id, sceneId: sceneId) { _ in reload() } }
        }
        .navigationDestination(isPresented: $showLook) { StageLookView(sceneId: sceneId) }
        .onAppear {
            reload()
            openIfDue()
        }
        .onDisappear { job?.cancel() }
        .confirmationDialog("收场后输入框关闭，正文保留，可以随时重新开场。", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("收场") {
                do { try Scene.end(sceneId); reload() } catch { problem = "收场失败：\(error.localizedDescription)" }
            }
        }
        .confirmationDialog("删除这一段及其之后的全部正文。无法恢复。", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
                            titleVisibility: .visible, presenting: dropping) { b in
            Button("删除", role: .destructive) {
                do { try Scene.dropFrom(b.id); reload() } catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        }
        .sheet(item: Binding(get: { editing.map { EditKey(id: $0.id) } }, set: { if $0 == nil { editing = nil } })) { _ in
            NavigationStack {
                Form { TextField("正文", text: $editText, axis: .vertical).lineLimit(6...40) }
                    .navigationTitle("改写这一段")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                if let b = editing {
                                    do { try Scene.editBeat(b.id, editText); reload() } catch { problem = "保存失败：\(error.localizedDescription)" }
                                }
                                editing = nil
                            }
                        }
                    }
            }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        }
    }

    private struct EditKey: Identifiable { let id: String }

    private var title: String {
        guard let s = scene else { return "线下" }
        let t = s.string("title").isEmpty ? s.string("place") : s.string("title")
        return t.isEmpty ? "线下" : t
    }

    // MARK: 刊头

    private var header: some View {
        let facts = [scene?.string("place") ?? "", Scene.timeOf(sceneId)].filter { !$0.isEmpty }
        let cast = scene.map { sc in Scene.presentOf(sc).map { Scene.nameIn(sc, $0) } } ?? []
        return VStack(alignment: .leading, spacing: 6) {
            if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(look.dim) }
            if !cast.isEmpty { Text("在场：\(cast.joined(separator: "、"))").font(.system(size: 13)).foregroundStyle(look.dim) }
            if ended { Text("已收场").font(.system(size: 13)).foregroundStyle(look.mark) }
            look.line.frame(height: 1).padding(.top, 4)
        }
    }

    // MARK: 一段

    @ViewBuilder
    private func beatView(_ b: Row) -> some View {
        if b.string("role") == Scene.DIRECTOR {
            HStack(alignment: .top, spacing: 6) {
                Text(b.bool("hold") ? "场外指示 · 一直有效" : "场外指示").font(.system(size: 12)).foregroundStyle(look.mark)
                Text(b.string("text")).font(.system(size: 13)).foregroundStyle(look.dim)
            }
            .padding(Theme.sp2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(look.line))
            .contextMenu {
                if b.bool("hold") {
                    Button("改为只管下一段") { setHold(b, false) }
                } else {
                    Button("改为一直有效") { setHold(b, true) }
                }
                Button("删除", role: .destructive) { dropOne(b) }
            }
        } else {
            let sign = scene.map { Scene.signOf(b, scene: $0, chat: chat, me: me) } ?? Scene.Sign()
            let versions = Scene.versions(b)
            let idx = Scene.swipeIndex(b)
            VStack(alignment: .leading, spacing: Theme.sp2) {
                if look.sign != "none" {
                    HStack(spacing: Theme.sp2) {
                        if look.sign == "full" && !sign.face.isEmpty { Avatar(imageId: sign.face, name: sign.name, size: 24) }
                        Text(sign.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(look.ink)
                        let sub = [sign.time].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !sub.isEmpty { Text(sub).font(.system(size: 12)).foregroundStyle(look.dim) }
                        if b.bool("pinned") { Text("已钉住").font(.system(size: 11)).foregroundStyle(look.mark) }
                    }
                }
                Text(RegexRules.forDisplay(b.string("text"), .init(who: sign.mine ? "user" : "char", whereIs: "offline", charIds: chat?.characterIds ?? [])))
                    .font(look.font()).foregroundStyle(look.ink)
                    .lineSpacing(look.lineSpacing)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let castLine = Scene.castLine(b)
                if !castLine.isEmpty { Text(castLine).font(.system(size: 12)).foregroundStyle(look.dim) }
                if versions.count > 1 {
                    HStack(spacing: Theme.sp3) {
                        Button { pick(b, idx - 1) } label: { Image(systemName: "chevron.left") }.disabled(idx == 0 || writing)
                        Text("\(idx + 1) / \(versions.count)").font(.system(size: 12)).foregroundStyle(look.dim)
                        Button { pick(b, idx + 1) } label: { Image(systemName: "chevron.right") }.disabled(idx >= versions.count - 1 || writing)
                    }
                    .foregroundStyle(look.ink)
                    .buttonStyle(.plain)
                }
                if look.sign == "full" { look.line.frame(height: 1).padding(.top, Theme.sp2) }
            }
            .contextMenu { beatMenu(b, versions: versions.count) }
        }
    }

    @ViewBuilder
    private func beatMenu(_ b: Row, versions: Int) -> some View {
        let mine = b.string("role") == Scene.ME
        let last = beats.last(where: { $0.string("role") != Scene.DIRECTOR })?.id == b.id
        Button("复制") { UIPasteboard.general.string = b.string("text") }
        Button("改写") { editText = b.string("text"); editing = b }
        if !mine && !ended {
            Button("重写这一段") { write(rewrite: b.id) }.disabled(writing)
            if last { Button("接着写") { write(more: true) }.disabled(writing) }
        }
        Button(b.bool("pinned") ? "取消钉住" : "钉住") {
            do { try Scene.togglePin(b.id); reload() } catch { problem = "操作失败：\(error.localizedDescription)" }
        }
        if versions > 1 {
            Button("删除当前这一版", role: .destructive) {
                do { try Scene.dropSwipe(b.id); reload() } catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        }
        Button("删除这一段", role: .destructive) { dropOne(b) }
        Button("从这一段起往后全删", role: .destructive) { dropping = b }
    }

    // MARK: 底栏

    @ViewBuilder
    private var composer: some View {
        if ended {
            Button("重新开场") { reopen() }
                .buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                .padding(Theme.sp4)
                .background(look.bg)
        } else {
            VStack(spacing: Theme.sp2) {
                HStack {
                    Picker("写的是", selection: $director) {
                        Text("我这一段").tag(false)
                        Text("场外指示").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    Spacer()
                    if director { Toggle("一直有效", isOn: $hold).toggleStyle(.button).font(.system(size: 13)) }
                }
                HStack(alignment: .bottom, spacing: Theme.sp2) {
                    TextField(director ? "写给角色的指示，不出现在正文里" : "写我这一段", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($typing)
                        .padding(.horizontal, Theme.sp3).padding(.vertical, Theme.sp2)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
                    if writing {
                        Button { job?.cancel() } label: { Image(systemName: "stop.circle").font(.title2) }
                            .accessibilityLabel("停止")
                    } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { write() } label: { Image(systemName: "text.append").font(.title2) }
                            .accessibilityLabel("让角色写下一段")
                    } else {
                        Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            .accessibilityLabel("发送")
                    }
                }
                .foregroundStyle(look.ink)
                HelpNote("底栏写的是「我这一段」时，发送后角色接着写一段；输入框空着时点右侧的按钮，角色直接写下一段。「场外指示」作为指令写进提示词，不出现在正文里，只管下一段；勾选「一直有效」后整场都生效。长按一段可以复制、改写、重写、接着写、钉住或删除；重写不删旧的，在这一段下方左右切换版本。每写一段调用一次接口。", title: "线下：写正文")
            }
            .padding(.horizontal, Theme.sp4)
            .padding(.vertical, Theme.sp3)
            .background(look.bg)
            .overlay(alignment: .top) { look.line.frame(height: 1) }
        }
    }

    // MARK: 动作

    private func reload() {
        scene = Scene.get(sceneId)
        chat = scene.flatMap { (try? Repo.chat($0.string("chatId"))) ?? nil }
        let ps = (try? Repo.personas()) ?? []
        me = ps.first { $0.id == chat?.personaId } ?? ((try? Repo.activePersona()) ?? nil)
        beats = Scene.beatsOf(sceneId)
        look = Stage.look(Stage.forScene(scene))
    }

    /// 角色先写的那一场，第一次打开时直接写开场
    private func openIfDue() {
        guard !opened else { return }
        opened = true
        if let scene, beats.isEmpty, scene.string("opening") != Scene.ME, !ended { write() }
    }

    private func reopen() {
        do { try Scene.update(sceneId, ["endedAt": .number(0)]); reload() } catch { problem = "操作失败：\(error.localizedDescription)" }
    }

    private func setHold(_ b: Row, _ on: Bool) {
        do { try Scene.updateBeat(b.id, ["hold": .bool(on)]); reload() } catch { problem = "操作失败：\(error.localizedDescription)" }
    }

    private func dropOne(_ b: Row) {
        do { try Scene.dropBeat(b.id); reload() } catch { problem = "删除失败：\(error.localizedDescription)" }
    }

    private func pick(_ b: Row, _ i: Int) {
        do { try Scene.pickSwipe(b.id, i); reload() } catch { problem = "切换失败：\(error.localizedDescription)" }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            if director {
                try Scene.addBeat(sceneId: sceneId, role: Scene.DIRECTOR, text: text, hold: hold)
                draft = ""
                reload()
                return
            }
            try Scene.addBeat(sceneId: sceneId, role: Scene.ME, authorId: "me", text: text)
            draft = ""
            reload()
            write()
        } catch {
            problem = "写入失败，这一段未保存：\(error.localizedDescription)"
        }
    }

    private func write(more: Bool = false, rewrite: String = "") {
        guard !writing else { return }
        if let c = scene.map(Scene.presentOf), c.contains(where: \.archived), rewrite.isEmpty, !more {
            notice = "封存的角色不再回复。"
            return
        }
        writing = true
        live = ""
        problem = nil
        typing = false
        let id = sceneId
        job = Task { @MainActor in
            do {
                let r = try await SceneRun.writeRound(sceneId: id, more: more, rewrite: rewrite) { text in
                    Task { @MainActor in live = text }
                }
                if !r.notes.isEmpty { notice = r.notes.joined(separator: "，") }
            } catch is CancellationError {
            } catch let e as AIError where e.cancelled {
            } catch {
                problem = error.localizedDescription
            }
            writing = false
            live = ""
            reload()
            NotificationCenter.default.post(name: .eiraChatChanged, object: chat?.id)
        }
    }
}

// MARK: - 外观

/// 线下的外观。sceneId 为 nil 改全局那份；给了也改全局那份（单场覆盖沿用网页版存下来的，不另开入口）
struct StageLookView: View {
    let sceneId: String?
    @ObservedObject private var model = SettingsModel.shared

    private var cfg: [String: JSONValue] { Stage.config(model.s) }
    private var look: Stage.Look { Stage.look(Stage.forScene(sceneId.flatMap(Scene.get), model.s)) }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Theme.sp2) {
                    Text("角色").font(look.font(14)).bold().foregroundStyle(look.ink)
                    Text("门口的风铃响了一下。书页还停在原处，窗外开始下雨。")
                        .font(look.font()).foregroundStyle(look.ink).lineSpacing(look.lineSpacing)
                    look.line.frame(height: 1)
                    Text("旧书店 · 14:30").font(.system(size: 12)).foregroundStyle(look.dim)
                }
                .padding(Theme.sp4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(look.bg, in: RoundedRectangle(cornerRadius: Theme.rMd))
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } header: { Text("预览") }
            Section("主题") {
                Picker("主题", selection: Binding(get: { cfg["theme"]?.string ?? "body" }, set: { Stage.useTheme($0) })) {
                    ForEach(Stage.themes) { t in Text(t.label).tag(t.id) }
                }
                .pickerStyle(.segmented)
                Toggle("衬线字体", isOn: Binding(get: { cfg["serif"]?.bool ?? true }, set: { Stage.set(["serif": .bool($0)]) }))
            }
            Section("排版") {
                Stepper("字号 \(Int(cfg["fontSize"]?.number ?? 17))", value: Binding(get: { cfg["fontSize"]?.number ?? 17 },
                                                                                  set: { Stage.set(["fontSize": .number($0)]) }), in: 12...28)
                Stepper(String(format: "行距 %.1f", cfg["lineHeight"]?.number ?? 1.9), value: Binding(get: { cfg["lineHeight"]?.number ?? 1.9 },
                                                                                                    set: { Stage.set(["lineHeight": .number(($0 * 10).rounded() / 10)]) }), in: 1.2...2.6, step: 0.1)
                Stepper(String(format: "段距 %.1f", cfg["paraGap"]?.number ?? 1), value: Binding(get: { cfg["paraGap"]?.number ?? 1 },
                                                                                              set: { Stage.set(["paraGap": .number(($0 * 10).rounded() / 10)]) }), in: 0...3, step: 0.1)
                Picker("署名", selection: Binding(get: { cfg["sign"]?.string ?? "full" }, set: { Stage.set(["sign": .string($0)]) })) {
                    ForEach(Stage.signs, id: \.id) { s in Text(s.label).tag(s.id) }
                }
                HelpNote("署名：「完整」写名字、时刻与头像，下面一道细线；「一行」只写名字与时刻；「不显示」正文之外什么都不写。", title: "线下：署名")
            }
            if (cfg["theme"]?.string ?? "body") == "custom" {
                Section("自定义颜色") {
                    colorRow("底色", "bgColor")
                    colorRow("正文", "ink")
                    colorRow("次要文字", "dim")
                    colorRow("细线", "line")
                    colorRow("标记", "mark")
                    HelpNote("填 #RRGGBB 形式的颜色，留空时用「正文」主题的颜色。", title: "线下：自定义颜色")
                }
            }
            Section {
                Button("恢复默认外观", role: .destructive) { Stage.reset() }
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("线下的外观")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func colorRow(_ label: String, _ key: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("#RRGGBB", text: Binding(get: { cfg[key]?.string ?? "" }, set: { Stage.set([key: .string($0.trimmingCharacters(in: .whitespaces))]) }))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxWidth: 120)
        }
    }
}
