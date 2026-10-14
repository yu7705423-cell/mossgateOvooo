import PhotosUI
import SwiftUI

/// 一段会话的设置。从会话右上角进来（网页版第 5 条：这段对话的事放在这段对话里）。
private struct EditTarget: Identifiable { var id: String }

struct ChatSettingsView: View {
    let chatId: String
    var onDeleted: () -> Void = {}
    /// 搜索这段会话的聊天记录：回到会话页打开搜索，选中一条后跳过去
    var onSearch: (() -> Void)?
    /// 进入多选：回到会话页，逐条勾选后一并删除
    var onSelect: (() -> Void)?
    /// 打开聊天背景：回到会话页，面板只占下半屏，每改一下都看得见
    var onLook: (() -> Void)?

    @State private var chat: Chat?
    @State private var pinned = false
    @State private var muted = false
    @State private var narration = false
    @State private var userNarration = false
    @State private var innerStyle = "quiet"
    /// 在这里打开角色卡（编辑资料）：一张自带导航的页，从「聊天」与「联系」进来的会话都打得开
    @State private var editingChar: String?
    @State private var cardPath = NavigationPath()
    /// 只在这段会话里换头像：换谁（角色 id 或 me），选好图后写进 chat.faces
    @State private var faceKey = ""
    @State private var pickingFace = false
    @State private var facePhoto: PhotosPickerItem?
    @State private var innerMode = "off"
    @State private var innerWhat = ""
    @State private var translateTo = ""
    @State private var translateRules = ""
    /// 常见的几个，够挑就行；要别的直接填（网页版 TranslatePage 的 COMMON）
    static let commonLangs = ["中文", "英文", "日文", "韩文", "法文", "德文", "西班牙文", "俄文"]
    @State private var presetId = ""
    @State private var summary = ""
    @State private var presets: [AppSettings.Preset] = []
    @State private var confirmClear = false
    @State private var confirmDelete = false
    @State private var problem: String?
    @State private var loaded = false
    @State private var backlog = 0
    @State private var summarizing = false
    @State private var summaryNote: String?

    var body: some View {
        Form {
            if chat?.isGroup == true { GroupMembersSection(chatId: chatId) }
            if let c = chat { faceSection(c) }
            if let onSearch {
                Section {
                    Button(action: onSearch) {
                        HStack {
                            Text("搜索聊天记录").foregroundStyle(Theme.text)
                            Spacer()
                            SvgIcon(name: "search", size: 16, color: Theme.text3)
                        }
                    }
                    if let onSelect {
                        Button(action: onSelect) { Text("多选消息").foregroundStyle(Theme.text) }
                    }
                    if let onLook {
                        Button(action: onLook) { Text("聊天背景").foregroundStyle(Theme.text) }
                    }
                }
            }
            Section {
                Toggle("置顶", isOn: $pinned)
                Toggle("免打扰", isOn: $muted)
            }
            PaceSection(chatId: chatId)
            if let c = chat, !c.isGroup, let charId = c.characterIds.first {
                Section {
                    Button { cardPath = NavigationPath(); editingChar = charId } label: {
                        HStack {
                            Text("角色卡与备注").foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.text3)
                        }
                    }
                } header: { Text("这个角色") }
                ProactiveSection(charId: charId)
                DayOnSection(charId: charId)
                MusicCharSection(charId: charId)
                DiaryAutoSection(charId: charId)
            }
            Section {
                NavigationLink {
                    TimeSettingsView()
                } label: {
                    HStack {
                        Text("时间感知")
                        Spacer()
                        Text(Self.timeState(AppSettings.load())).foregroundStyle(Theme.text3)
                    }
                }
            } footer: {
                Text("对所有会话生效。")
            }
            if chat?.isGroup == false {
                Section {
                    NavigationLink {
                        StatusBarSettingsView(chatId: chatId)
                    } label: {
                        HStack {
                            Text("状态栏")
                            Spacer()
                            Text(chat.map(StatusBar.active) == true ? "已开启" : "关闭").foregroundStyle(Theme.text3)
                        }
                    }
                }
            }
            ShowSection()
            Section {
                Toggle("旁白", isOn: $narration)
            } footer: {
                Text("开启后，角色的回复中可以夹带旁白，旁白显示为居中的斜体文字。关闭时，回复中的旁白不显示。")
            }
            Section {
                Toggle("我也写旁白", isOn: $userNarration)
            } footer: {
                Text("开启后，输入框上方出现「消息 旁白」切换。选择「旁白」后输入的内容以旁白发出，显示为居中的一行小字，发出后自动切回发送消息。旁白不单独触发回复，角色在下一次回复时一并读到。不额外调用接口。")
            }
            Section {
                Picker("心声", selection: $innerMode) {
                    Text("关闭").tag("off")
                    Text("随回复一起").tag("inline")
                    Text("单独生成").tag("apart")
                }
                if innerMode != "off" {
                    Picker("显示方式", selection: $innerStyle) {
                        Text("淡色小字").tag("quiet")
                        Text("打开一页").tag("card")
                    }
                    TextField("写什么（留空为默认）", text: $innerWhat, axis: .vertical).lineLimit(1...4)
                }
            } footer: {
                Text(innerMode == "apart"
                     ? "每一轮说完之后另调用一次接口，写出刚才那几句话背后的想法。每轮多一次调用（走副用接口）。"
                     : innerMode == "inline" ? "角色在每轮回复的最后写一行心声，对方看不到。不多调用接口。"
                     : "开启后显示角色每轮话语背后的想法。")
            }
            Section {
                Toggle("翻译这段对话", isOn: Binding(
                    get: { !translateTo.trimmingCharacters(in: .whitespaces).isEmpty },
                    set: { translateTo = $0 ? (translateTo.isEmpty ? "中文" : translateTo) : ""; save() }))
                if !translateTo.trimmingCharacters(in: .whitespaces).isEmpty {
                    TextField("译成什么语言", text: $translateTo)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.sp2) {
                            ForEach(Self.commonLangs, id: \.self) { l in
                                Button(l) { translateTo = l; save() }
                                    .font(.system(size: 13))
                                    .foregroundStyle(translateTo == l ? Theme.onAccent : Theme.text)
                                    .padding(.horizontal, Theme.sp3).padding(.vertical, 5)
                                    .background(translateTo == l ? Theme.accent : Theme.surface2, in: Capsule())
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    TextField("额外的翻译要求（例如：保留原文中的称呼）", text: $translateRules, axis: .vertical).lineLimit(1...4)
                }
            } header: {
                Text("翻译")
            } footer: {
                Text("开启后，角色每说一条同时给出译文，显示在气泡下方。随回复一起写出，不多调用接口；回复会变长，用量随之增加。列表以外的语言可直接填写，例如「粤语」「文言文」。额外的翻译要求在长按菜单「翻译这一条」时随原文一并发送；随回复给出的译文不使用此项。开启前已经发出的消息没有译文，需要重新生成才会带上。")
            }
            Section {
                Picker("预设", selection: $presetId) {
                    Text("跟随全局").tag("")
                    ForEach(presets) { p in Text(p.name).tag(p.id) }
                }
            } footer: {
                Text("预设决定这段会话的提示词条目、每轮条数与携带的历史。预设在「设定集 - 预设」中编辑。")
            }
            Section {
                TextField("尚无摘要", text: $summary, axis: .vertical).lineLimit(3...20)
            } header: {
                Text("更早之前发生过什么")
            } footer: {
                Text("写有内容时，每次请求都会带上这一段，作为携带的历史之前的经过。")
            }
            Section {
                LabeledContent("未总结的消息", value: "\(backlog) 条")
                Button(summarizing ? "总结中" : "立即总结", action: summarizeNow).disabled(summarizing || backlog < 2 || chat?.isGroup == true)
                Button("全部标为已总结") {
                    do { let n = try MemorySummary.markCaughtUp(chatId: chatId); summaryNote = "已将 \(n) 条标为已总结。"; refreshBacklog() }
                    catch { problem = "未能保存：\(error.localizedDescription)" }
                }
                .disabled(summarizing || backlog == 0)
                if let summaryNote { Text(summaryNote).font(.footnote).foregroundStyle(Theme.secondaryText) }
            } header: {
                Text("记忆总结")
            } footer: {
                Text("立即总结：把未总结的对话交给模型整理成记忆，调用一次接口（走记忆接口，没单独配时走副用）。一次最多处理「每次总结的条数」那么多条。全部标为已总结：不调用接口，之后只总结新的对话。自动总结的门槛在「设定集 - 记忆」中设置。")
            }
            Section {
                Button("清空聊天记录", role: .destructive) { confirmClear = true }.foregroundStyle(Theme.dangerText)
                Button("删除这段会话", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText)
            } footer: {
                Text("清空只删除消息，会话与角色保留；删除会话连同消息一并删除。均无法撤销。角色的记忆不受影响。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("会话设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清空后无法恢复。", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空聊天记录", role: .destructive) {
                do { try Database.shared.deleteAll(Collections.messages, where: chatId) }
                catch { problem = "清空失败：\(error.localizedDescription)" }
            }
        }
        .confirmationDialog("删除后无法恢复。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除这段会话", role: .destructive) {
                do { try People.deleteChat(chatId); onDeleted() }
                catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        }
        .onAppear(perform: load)
        .onChange(of: pinned) { _, _ in save() }
        .onChange(of: muted) { _, _ in save() }
        .sheet(item: Binding(get: { editingChar.map { EditTarget(id: $0) } }, set: { editingChar = $0?.id })) { t in
            NavigationStack(path: $cardPath) {
                CharacterEditView(charId: t.id, path: $cardPath)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { editingChar = nil } } }
            }
        }
        .photosPicker(isPresented: $pickingFace, selection: $facePhoto, matching: .images)
        .onChange(of: facePhoto) { _, item in
            guard let item else { return }
            facePhoto = nil
            let key = faceKey
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    let id = try Images.save(data, maxPixel: 512)
                    try ChatFaces.set(chatId, key: key, imageId: id)
                    await MainActor.run { reloadChat() }
                } catch {
                    await MainActor.run { problem = "头像未能保存：\(error.localizedDescription)" }
                }
            }
        }
        .onChange(of: narration) { _, _ in save() }
        .onChange(of: userNarration) { _, _ in save() }
        .onChange(of: presetId) { _, _ in save() }
        .onChange(of: innerMode) { _, _ in save() }
        .onChange(of: innerStyle) { _, _ in save() }
        .onDisappear(perform: save)
    }

    /// 只在这段会话里换头像（网页版 4.437）：角色卡与主页上换的才是所有会话一起换
    @ViewBuilder
    private func faceSection(_ c: Chat) -> some View {
        let faces = ChatFaces.faces(c)
        let members = c.characterIds.compactMap { try? Repo.character($0) }
        Section {
            if c.isGroup {
                Menu("更换成员的头像") {
                    ForEach(members) { m in
                        Button(GroupChat.nameIn(c, m)) { faceKey = m.id; pickingFace = true }
                    }
                }
            } else if let m = members.first {
                Button("更换角色的头像") { faceKey = m.id; pickingFace = true }
            }
            Button("更换我的头像") { faceKey = ChatFaces.me; pickingFace = true }
            ForEach(members.filter { faces[$0.id] != nil }) { m in
                Button(c.isGroup ? "恢复「\(GroupChat.nameIn(c, m))」的头像" : "恢复角色的头像") { clearFace(m.id) }
            }
            if faces[ChatFaces.me] != nil {
                Button("恢复我的头像") { clearFace(ChatFaces.me) }
            }
        } header: {
            Text("头像")
        } footer: {
            Text("只在这段会话中更换，其他会话、联系人、朋友圈与资料页仍显示原来的头像。所有会话一起换，在角色卡或主页中更换。")
        }
    }

    private func clearFace(_ key: String) {
        do { try ChatFaces.clear(chatId, key: key); reloadChat() }
        catch { problem = "头像未能恢复：\(error.localizedDescription)" }
    }

    private func reloadChat() {
        chat = try? Repo.chat(chatId)
        NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
    }

    /// 时间感知此刻的状态：系统时间 / 自定义时间 / 关闭
    static func timeState(_ s: AppSettings) -> String {
        guard Clock.enabled(s) else { return "关闭" }
        return Clock.isVirtual(s) ? "自定义时间" : "系统时间"
    }

    private func refreshBacklog() {
        backlog = (try? MemorySummary.pending(chatId: chatId).count) ?? 0
    }

    private func summarizeNow() {
        summarizing = true
        summaryNote = nil
        let id = chatId
        Task {
            do {
                let r = try await MemorySummary.extract(chatId: id)
                await MainActor.run {
                    summaryNote = r.total + r.state == 0 ? "没有需要新记下的内容。" : "新记 \(r.added) 条，更新 \(r.updated) 条，了结 \(r.closed) 条" + (r.state > 0 ? "，现状改写 \(r.state) 块。" : "。")
                }
            } catch {
                await MainActor.run { problem = "总结失败：\(error.localizedDescription)" }
            }
            await MainActor.run { summarizing = false; refreshBacklog() }
        }
    }

    private func load() {
        refreshBacklog()
        do {
            guard let c = try Repo.chat(chatId) else { problem = "这段会话不存在"; return }
            chat = c
            pinned = c.pinned; muted = c.muted; narration = c.row.bool("narration"); userNarration = c.row.bool("userNarration")
            innerMode = InnerVoice.mode(c); innerWhat = c.row.string("innerWhat"); innerStyle = InnerVoice.style(c)
            translateTo = c.row.string("translateTo")
            translateRules = c.row.string("translateRules")
            presetId = c.presetId; summary = c.summary
            presets = AppSettings.load().presets
            loaded = true
        } catch {
            problem = error.localizedDescription
        }
    }

    /// 只写改过的字段。页面刚打开时 load 赋值也会触发 onChange，那时和库里一样，不写。
    private func save() {
        guard loaded, let c = try? Repo.chat(chatId) else { return }
        var f: [String: JSONValue] = [:]
        if pinned != c.pinned { f["pinned"] = .bool(pinned) }
        if muted != c.muted { f["muted"] = .bool(muted) }
        if narration != c.row.bool("narration") { f["narration"] = .bool(narration) }
        if userNarration != c.row.bool("userNarration") { f["userNarration"] = .bool(userNarration) }
        if presetId != c.presetId { f["presetId"] = .string(presetId) }
        if summary != c.summary { f["summary"] = .string(summary) }
        if innerMode != InnerVoice.mode(c) { f["innerMode"] = .string(innerMode) }
        if innerStyle != InnerVoice.style(c) { f["innerStyle"] = .string(innerStyle) }
        let lang = translateTo.trimmingCharacters(in: .whitespaces)
        if lang != c.row.string("translateTo") { f["translateTo"] = .string(String(lang.prefix(40))) }
        if translateRules != c.row.string("translateRules") { f["translateRules"] = .string(String(translateRules.prefix(500))) }
        if innerWhat != c.row.string("innerWhat") { f["innerWhat"] = .string(String(innerWhat.prefix(300))) }
        guard !f.isEmpty else { return }
        var row = c.row
        for (k, v) in f { row[k] = v }
        row.touch()
        do { try Database.shared.put(Collections.chats, row); problem = nil }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}

/// 这个角色会不会主动找你（网页版 proactive.js 的 DEFAULTS，开关在角色身上）。
struct ProactiveSection: View {
    let charId: String
    @State private var on = false
    @State private var minutes = 60.0
    @State private var quietFrom = 0
    @State private var quietTo = 8
    @State private var loaded = false
    @State private var problem: String?
    @ObservedObject private var bg = BgPush.shared

    var body: some View {
        Section {
            Toggle("主动发起对话", isOn: $on)
            if on {
                NumberRow(title: "平均间隔", value: $minutes, unit: "分钟", placeholder: "60", range: 1...100000)
                Stepper("免打扰开始：\(quietFrom) 点", value: $quietFrom, in: 0...23)
                Stepper("免打扰结束：\(quietTo) 点", value: $quietTo, in: 0...23)
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("主动发起对话")
        } footer: {
            Text(footer)
        }
        .onAppear(perform: load)
        .onChange(of: on) { _, _ in save() }
        .onChange(of: minutes) { _, _ in save() }
        .onChange(of: quietFrom) { _, _ in save() }
        .onChange(of: quietTo) { _, _ in save() }
    }

    private var footer: String {
        var t = "开启后，角色在设定的间隔内主动发起对话，实际间隔在设定值的一半到一倍半之间。每次调用一次接口（走主用接口）。免打扰时段内不发，开始与结束相同表示不设。未读消息达到「设置 - 用量与上限」中的条数后暂停。"
        t += BgPush.isOn() ? "应用不在前台时由后台消息服务器代发。" : "只在应用打开时发送；应用不在前台时的代发见「设置 - 后台消息」。"
        if !bg.problem.isEmpty { t += "\n" + bg.problem }
        return t
    }

    private func load() {
        guard let c = try? Repo.character(charId) else { return }
        let cfg = Proactive.config(c)
        on = cfg.on; minutes = cfg.minutes; quietFrom = cfg.quietFrom; quietTo = cfg.quietTo
        loaded = true
    }

    private func save() {
        guard loaded, var c = try? Repo.character(charId) else { return }
        let old = Proactive.config(c)
        let next = Proactive.Config(on: on, minutes: max(1, minutes), quietFrom: quietFrom, quietTo: quietTo)
        guard old != next else { return }
        c.row["proactive"] = .bool(on)
        c.row["proactiveMinutes"] = .number(next.minutes)
        c.row["proactiveQuietFrom"] = .number(Double(quietFrom))
        c.row["proactiveQuietTo"] = .number(Double(quietTo))
        c.row.touch()
        do {
            try Database.shared.put(Collections.characters, c.row)
            Proactive.reschedule(charId)
            problem = nil
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
        }
    }
}

/// 会话里怎么显示：消息时刻、已读回执、译文（网页版「美化」页与「翻译」页里的全局几项）。对所有会话生效
struct ShowSection: View {
    @ObservedObject private var model = SettingsModel.shared

    private func pick(_ key: String, _ def: String) -> Binding<String> {
        Binding(get: { model.s.raw[key]?.string ?? def }, set: { model.set(key, .string($0)) })
    }

    var body: some View {
        Section {
            Picker("消息时刻", selection: pick("msgStamp", "gap")) {
                ForEach(Receipt.stamps.indices, id: \.self) { i in Text(Receipt.stamps[i].label).tag(Receipt.stamps[i].id) }
            }
            Toggle("显示已读回执", isOn: model.bool("msgRead", false))
            Picker("译文显示", selection: pick("translateShow", "both")) {
                Text("原文与译文").tag("both")
                Text("只显示译文").tag("trans")
                Text("只显示原文").tag("orig")
            }
            Picker("译文展开", selection: pick("translateOpen", "tap")) {
                Text("点击展开").tag("tap")
                Text("下一轮收起").tag("turn")
                Text("默认展开").tag("always")
            }
        } header: {
            GroupTitle("显示")
        } footer: {
            Text("对所有会话生效。按间隔：相隔五分钟以上时在两条消息之间显示一行时间。已读回执：角色开始回复时，之前发出的消息标为已读。心声默认收起，点角色的头像展开。")
        }
    }
}


/// 角色什么时候回（网页版 PacePage.js）：按按钮、发完就回、延迟回复。存在会话上，只对这段会话生效
struct PaceSection: View {
    let chatId: String
    @State private var chat: Chat?
    @State private var problem: String?

    var body: some View {
        Section {
            if let c = chat {
                Picker("回复节奏", selection: Binding(get: { Pace.mode(c) }, set: { set(["paceMode": .string($0)]) })) {
                    Text("按按钮").tag(Pace.manual)
                    Text("发完就回").tag(Pace.now)
                    Text("延迟回复").tag(Pace.paced)
                }
                if Pace.mode(c) == Pace.paced {
                    Stepper("空闲时的基准时长：\(Pace.base(c)) 秒", value: Binding(
                        get: { Pace.base(c) }, set: { set(["paceBase": .number(Double($0))]) }), in: 5...3600, step: 15)
                    Stepper(Pace.maxWait(c) == 0 ? "最长等多久：等到状态结束" : "最长等多久：\(Pace.maxWait(c) / 60) 分钟", value: Binding(
                        get: { Pace.maxWait(c) / 60 }, set: { set(["paceMax": .number(Double(max(0, $0) * 60))]) }), in: 0...1440, step: 5)
                    if !c.isGroup {
                        Toggle("休息时不回复", isOn: Binding(get: { Pace.sleepOn(c) }, set: { set(["paceSleep": .bool($0)]) }))
                    }
                    if Pace.pending(c) != nil {
                        HStack {
                            Text(Pace.pendingText(c)).font(.footnote).foregroundStyle(Theme.text2)
                            Spacer()
                            Button("取消") { try? Pace.clear(chatId); load() }.font(.footnote)
                        }
                    }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            }
        } header: {
            Text("节奏")
        } footer: {
            Text("按按钮：发出去只是发出去，什么时候回由发送键右边那个按钮决定。发完就回：消息一发出去就立刻生成回复，每条都调用一次接口。"
                 + "延迟回复：角色什么时候回取决于角色当时的状态。空闲时几分钟内回；「日常」里当前时段安排了事项，等这件事结束后回；"
                 + "免打扰时段（在「主动发起对话」中设置）内视为休息，起床后回。期间发出的多条消息一并回复，不消耗额外的接口调用；"
                 + "时刻由本地计算，不由模型决定。到点时应用不在前台的，在下次打开时补回。")
        }
        .onAppear(perform: load)
        if let c = chat { autoSections(c) }
    }

    /// 自动回复（网页版 PacePage 的 CharAuto 与 AutoSide）：都是固定的话，不调接口
    @ViewBuilder
    private func autoSections(_ c: Chat) -> some View {
        if !c.isGroup {
            let charDayOn = (c.characterIds.first.flatMap { try? Repo.character($0) }).map { DayPlan.isOn($0) } ?? false
            Section {
                Toggle("忙碌或休息时自动回复", isOn: Binding(get: { AutoReply.config(c, AutoReply.hers).on },
                                                    set: { setAuto(AutoReply.hers, ["on": .bool($0)]) }))
            } footer: {
                Text("开启后，角色在「日常」当前时段有事项、或处于免打扰时段时，发来消息会先收到一条自动回复。内容随每天的日程一并生成，不另外调用接口。每段忙碌或休息期间只回一次。正式回复在「延迟回复」下于忙完之后照常发出；其余节奏不再立即回复。"
                     + (charDayOn ? "" : "该角色尚未开启「日常」，开启后才有当前事项与自动回复的内容。"))
            }
        }
        let mine = AutoReply.config(c, AutoReply.mine)
        Section {
            Toggle("开启", isOn: Binding(get: { mine.on }, set: { v in
                if v && mine.text.isEmpty { problem = "请先填写自动回复的内容"; return }
                setAuto(AutoReply.mine, ["on": .bool(v)])
            }))
            TextField("回什么（例如：在忙，晚点回你）", text: Binding(get: { mine.text }, set: { setAuto(AutoReply.mine, ["text": .string($0)]) }), axis: .vertical)
                .lineLimit(1...3)
            Stepper(mine.max == 0 ? "最多回几条：不限" : "最多回几条：\(mine.max)", value: Binding(
                get: { mine.max }, set: { setAuto(AutoReply.mine, ["max": .number(Double(max(0, $0)))]) }), in: 0...999)
            Toggle("设结束时间", isOn: Binding(get: { mine.until > 0 }, set: { v in
                setAuto(AutoReply.mine, ["until": .number(v ? Date().addingTimeInterval(3600).millis : 0)])
            }))
            if mine.until > 0 {
                DatePicker("结束时间", selection: Binding(get: { Date(millis: mine.until) },
                                                       set: { setAuto(AutoReply.mine, ["until": .number($0.millis)]) }))
            }
        } header: {
            Text("我的自动回复")
        } footer: {
            Text((mine.on ? (mine.max > 0 ? "已开启，还可回 \(max(0, mine.max - mine.used)) 条。" : "已开启，不限条数。") : "")
                 + "开启后角色发来消息时，替你回一句固定的话，不经过模型，不消耗接口调用。条数或结束时间任一达到时自动关闭，并在对话中留下一行提示。双方的自动回复不会互相触发。")
        }
    }

    private func setAuto(_ side: String, _ patch: [String: JSONValue]) {
        do { try AutoReply.set(chatId, side, patch); load(); problem = nil }
        catch { problem = "未能保存：\(error.localizedDescription)" }
    }

    private func load() { chat = try? Repo.chat(chatId) }

    private func set(_ patch: [String: JSONValue]) {
        guard var c = try? Repo.chat(chatId) else { return }
        for (k, v) in patch { c.row[k] = v }
        if patch["paceMode"]?.string != nil && patch["paceMode"]?.string != Pace.paced { c.row["pacePending"] = .null }
        c.row.touch()
        do { try Repo.save(c); chat = c; problem = nil }
        catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}
