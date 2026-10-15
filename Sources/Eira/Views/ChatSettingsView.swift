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
    @State private var showSkin = false
    @State private var query = ""

    var body: some View {
        Form {
            menuSections
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("聊天信息")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索设置项")
        .onAppear { if loaded { chat = try? Repo.chat(chatId); refreshBacklog(); presets = AppSettings.load().presets } else { load() } }
        .onChange(of: pinned) { _, _ in save() }
        .onChange(of: muted) { _, _ in save() }
        .sheet(item: Binding(get: { editingChar.map { EditTarget(id: $0) } }, set: { editingChar = $0?.id })) { t in
            NavigationStack(path: $cardPath) {
                CharacterEditView(charId: t.id, path: $cardPath)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { editingChar = nil } } }
            }
        }
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
        // 输入框也随改随存：子页返回时这一页会重新出现，不能等到整页关掉才存
        .navigationDestination(isPresented: $showSkin) { SkinPageView(chatId: chatId) }
        .onChange(of: summary) { _, _ in save() }
        .onChange(of: innerWhat) { _, _ in save() }
        .onChange(of: translateTo) { _, _ in save() }
        .onChange(of: translateRules) { _, _ in save() }
        .onDisappear(perform: save)
    }

    /// 菜单里的一项。分组、搜索、最近打开都读同一份，不各写一遍
    struct Entry: Identifiable {
        let id: String
        let group: String
        let title: String
        var value = ""
        /// 搜索时一并匹配的词：这一项点进去之后才看得到的开关
        var keys = ""
        /// 只在搜索结果里出现（上面四格已经有入口的）
        var searchOnly = false
        var action: (() -> Void)?
        var dest: AnyView?
    }

    private func entries(_ c: Chat) -> [Entry] {
        var out: [Entry] = []
        func add(_ id: String, _ group: String, _ title: String, _ value: String = "", keys: String = "", searchOnly: Bool = false,
                 action: (() -> Void)? = nil, dest: AnyView? = nil) {
            out.append(Entry(id: id, group: group, title: title, value: value, keys: keys, searchOnly: searchOnly, action: action, dest: dest))
        }
        if let onSearch { add("search", "", "搜索聊天记录", keys: "查找 消息", searchOnly: true, action: onSearch) }
        if let onSelect { add("select", "", "多选消息", keys: "批量 删除", searchOnly: true, action: onSelect) }
        if let onLook { add("look", "", "聊天背景", keys: "背景图 遮罩 顶栏 输入栏 颜色 旁白颜色", searchOnly: true, action: onLook) }
        add("skin", "", "美化", keys: "气泡 头像形状 显示头像 消息时刻 已读回执 译文显示", searchOnly: true,
            action: { showSkin = true })
        if c.isGroup {
            add("group", "这个群", "群资料", "\(c.characterIds.count) 人", keys: "成员 群名 群昵称",
                dest: AnyView(MenuPage("群资料") { GroupMembersSection(chatId: chatId); GroupProactiveSection(chatId: chatId) }))
            add("face", "这个群", "头像", ChatFaces.faces(c).isEmpty ? "" : "已更换", keys: "成员的头像 我的头像", dest: AnyView(facePage(c)))
        } else if let charId = c.characterIds.first {
            let char = try? Repo.character(charId)
            add("card", "这个角色", "角色卡与备注", keys: "人设 资料 编辑 备注",
                action: { cardPath = NavigationPath(); editingChar = charId })
            add("face", "这个角色", "头像", ChatFaces.faces(c).isEmpty ? "" : "已更换", keys: "角色的头像 我的头像", dest: AnyView(facePage(c)))
            add("proactive", "这个角色", "主动发起对话", Proactive.config(char).on ? "开启" : "关闭", keys: "主动消息 间隔 免打扰",
                dest: AnyView(MenuPage("主动发起对话") { ProactiveSection(charId: charId) }))
            add("day", "这个角色", "日常与日记", keys: "日程 随机事件 写日记",
                dest: AnyView(MenuPage("日常与日记") {
                    DayOnSection(charId: charId)
                    DiaryAutoSection(charId: charId)
                }))
            add("music", "这个角色", "角色在听什么", keys: "网易云 音乐 歌",
                dest: AnyView(MenuPage("角色在听什么") { MusicCharSection(charId: charId) }))
        }
        let how = "这段对话怎么聊"
        add("pace", how, "节奏与自动回复", Self.paceLabel(c) + (AutoReply.listTag(c).isEmpty ? "" : " · 自动回复"),
            keys: "回复节奏 按按钮 发完就回 延迟回复 自动回复 忙碌 休息",
            dest: AnyView(MenuPage("节奏与自动回复") { PaceSection(chatId: chatId) }))
        add("inner", how, "心声", Self.innerLabel(innerMode), keys: "想法 内心", dest: AnyView(MenuPage("心声") { innerSection }))
        if !c.isGroup {
            add("status", how, "状态栏", StatusBar.active(c) ? "开启" : "关闭", keys: "心情 所在地 进度条",
                dest: AnyView(StatusBarSettingsView(chatId: chatId)))
        }
        if !c.isGroup {
            add("drafts", how, "草稿箱", Drafts.on(c) ? "开启" : "关闭", keys: "没发出去 写了又删",
                dest: AnyView(DraftsView(chatId: chatId)))
        }
        add("narr", how, "旁白", narration || userNarration ? "开启" : "关闭", keys: "我也写旁白",
            dest: AnyView(MenuPage("旁白") { narrationSections }))
        add("translate", how, "翻译", translateTo.trimmingCharacters(in: .whitespaces).isEmpty ? "关闭" : translateTo, keys: "译文 语言",
            dest: AnyView(MenuPage("翻译") { translateSection }))
        add("preset", how, "预设与前情", presets.first(where: { $0.id == presetId })?.name ?? "跟随全局", keys: "提示词 更早之前 摘要",
            dest: AnyView(MenuPage("预设与前情") { presetSections }))
        add("time", how, "时间感知", Self.timeState(AppSettings.load()), keys: "时区 时间 日期 虚拟时间",
            dest: AnyView(TimeSettingsView()))
        add("summary", "记忆", "记忆总结", backlog > 0 ? "\(backlog) 条未总结" : "", keys: "总结 记住",
            dest: AnyView(MenuPage("记忆总结") { summarySection }))
        add("badges", "记忆", "互动标识", Badges.streak(c).n > 0 ? "连续 \(Badges.streak(c).n) 天" : "", keys: "火花 连续互发 成就 等级 亲密度",
            dest: AnyView(BadgesView(chatId: chatId)))
        add("otd", "记忆", "那年今天", keys: "往年 去年今天 回忆",
            dest: AnyView(OnThisDayView(chatId: chatId)))
        if !c.isGroup {
            add("bond", "记忆", "关系底色", keys: "你们之间 关系 现状 S 级",
                dest: AnyView(BondView(chatId: chatId)))
        }
        if !c.isGroup, Ties.pair(c) != nil {
            add("ties", "好友与拉黑", "好友与拉黑", Self.tieLabel(c), keys: "拉黑 删除好友 好友申请",
                dest: AnyView(MenuPage("好友与拉黑") { TiesSection(chatId: chatId) }))
        }
        add("more", "更多", "更多", "置顶、免打扰、清空与删除", keys: "置顶 免打扰 清空聊天记录 删除这段会话",
            dest: AnyView(MenuPage("更多") { moreSections }))
        return out
    }

    @ViewBuilder private func entryRow(_ e: Entry, showGroup: Bool = false) -> some View {
        let sub = showGroup && !e.group.isEmpty ? e.group : ""
        if let action = e.action {
            Button { ChatMenuRecent.note(e.id); action() } label: { row(e.title, e.value, sub: sub) }
        } else if let dest = e.dest {
            NavigationLink {
                dest.onAppear { ChatMenuRecent.note(e.id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title)
                        if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(Theme.text3) }
                    }
                    Spacer()
                    if !e.value.isEmpty { Text(e.value).foregroundStyle(Theme.text3).lineLimit(1) }
                }
            }
        }
    }

    /// 搜索框里有字时列命中的几项；没有字时是四格、最近打开、各组
    @ViewBuilder private var menuSections: some View {
        if let c = chat {
            let all = entries(c)
            let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                let hits = all.filter { "\($0.title) \($0.group) \($0.keys)".localizedCaseInsensitiveContains(key) }
                Section {
                    if hits.isEmpty { Text("没有找到，换一个关键词再试。").foregroundStyle(Theme.text3) }
                    ForEach(hits) { e in entryRow(e, showGroup: true) }
                }
            } else {
                tiles
                let recent = ChatMenuRecent.ids().compactMap { id in all.first(where: { $0.id == id && !$0.searchOnly }) }
                if !recent.isEmpty {
                    Section {
                        ForEach(recent) { e in entryRow(e) }
                    } header: { Text("最近打开") }
                }
                let groups = all.filter { !$0.searchOnly }.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
                ForEach(groups, id: \.self) { g in
                    Section {
                        ForEach(all.filter { $0.group == g && !$0.searchOnly }) { e in entryRow(e) }
                    } header: { Text(g) }
                }
            }
        }
    }

    // MARK: - 菜单的零件（网页版新版会话菜单：上面四格，下面一组一组，一行只写名字和当前状态，点进去再设置）

    /// 搜索、多选、背景、美化
    private var tiles: some View {
        Section {
            HStack(spacing: 0) {
                if let onSearch { tile("搜索", "search", action: onSearch) }
                if let onSelect { tile("多选", "check", action: onSelect) }
                if let onLook { tile("背景", "image", action: onLook) }
                tile("美化", "palette") { showSkin = true }
            }
            .padding(.vertical, Theme.sp2)
        }
    }

    private func tile(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileFace(label, icon) }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
    }

    private func tileFace(_ label: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            SvgIcon(name: icon, size: 20, color: Theme.text)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func row(_ title: String, _ value: String, sub: String = "") -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.text)
                if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(Theme.text3) }
            }
            Spacer()
            if !value.isEmpty { Text(value).foregroundStyle(Theme.text3).lineLimit(1) }
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.text3)
        }
    }

    static func paceLabel(_ c: Chat) -> String {
        [Pace.manual: "按按钮", Pace.now: "发完就回", Pace.paced: "延迟回复"][Pace.mode(c)] ?? ""
    }

    static func innerLabel(_ mode: String) -> String {
        ["inline": "随回复一起", "apart": "单独生成"][mode] ?? "关闭"
    }

    static func tieLabel(_ c: Chat) -> String {
        switch (Ties.userRejects(c), Ties.charRejects(c)) {
        case (_, "blocked"?): return "被角色拉黑"
        case (_, "removed"?): return "被角色删除"
        case ("blocked"?, _): return "已拉黑"
        case ("removed"?, _): return "已删除"
        default: return "好友"
        }
    }

    @ViewBuilder private var innerSection: some View {
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
            if innerMode == "apart" { Text("每轮多调用一次接口。") }
            HelpNote(innerMode == "apart"
                 ? "每一轮说完之后另调用一次接口，写出刚才那几句话背后的想法。每轮多一次调用（走副用接口）。"
                 : innerMode == "inline" ? "角色在每轮回复的最后写一行心声，对方看不到。不多调用接口。"
                 : "开启后显示角色每轮话语背后的想法。")
        }
    }

    @ViewBuilder private var narrationSections: some View {
        Section {
            Toggle("旁白", isOn: $narration)
        } footer: {
            HelpNote("开启后，角色的回复中可以夹带旁白，旁白显示为居中的斜体文字。关闭时，回复中的旁白不显示。")
        }
        Section {
            Toggle("我也写旁白", isOn: $userNarration)
        } footer: {
            HelpNote("开启后，输入框上方出现「消息 旁白」切换。选择「旁白」后输入的内容以旁白发出，显示为居中的一行小字，发出后自动切回发送消息。旁白不单独触发回复，角色在下一次回复时一并读到。不额外调用接口。")
        }
    }

    @ViewBuilder private var translateSection: some View {
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
            Text("回复变长，用量随之增加。")
            HelpNote("开启后，角色每说一条同时给出译文，显示在气泡下方。随回复一起写出，不多调用接口；回复会变长，用量随之增加。列表以外的语言可直接填写，例如「粤语」「文言文」。额外的翻译要求在长按菜单「翻译这一条」时随原文一并发送；随回复给出的译文不使用此项。开启前已经发出的消息没有译文，需要重新生成才会带上。")
        }
    }

    @ViewBuilder private var presetSections: some View {
        Section {
            Picker("预设", selection: $presetId) {
                Text("跟随全局").tag("")
                ForEach(presets) { p in Text(p.name).tag(p.id) }
            }
        } footer: {
            HelpNote("预设决定这段会话的提示词条目、每轮条数与携带的历史。预设在「设定集 - 预设」中编辑。")
        }
        Section {
            TextField("尚无摘要", text: $summary, axis: .vertical).lineLimit(3...20)
        } header: {
            Text("更早之前发生过什么")
        } footer: {
            HelpNote("写有内容时，每次请求都会带上这一段，作为携带的历史之前的经过。")
        }
    }

    @ViewBuilder private var summarySection: some View {
        Section {
            LabeledContent("未总结的消息", value: "\(backlog) 条")
            Button(summarizing ? "总结中" : "立即总结", action: summarizeNow).disabled(summarizing || backlog < 2 || chat?.isGroup == true)
            Button("全部标为已总结") {
                do { let n = try MemorySummary.markCaughtUp(chatId: chatId); summaryNote = "已将 \(n) 条标为已总结。"; refreshBacklog() }
                catch { problem = "未能保存：\(error.localizedDescription)" }
            }
            .disabled(summarizing || backlog == 0)
            if let summaryNote { Text(summaryNote).font(.footnote).foregroundStyle(Theme.secondaryText) }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } footer: {
            Text("立即总结调用一次接口。")
            HelpNote("立即总结：把未总结的对话交给模型整理成记忆，调用一次接口（走记忆接口，没单独配时走副用）。一次最多处理「每次总结的条数」那么多条。全部标为已总结：不调用接口，之后只总结新的对话。自动总结的门槛在「设定集 - 记忆」中设置。")
        }
    }

    @ViewBuilder private var moreSections: some View {
        Section {
            Toggle("置顶", isOn: $pinned)
            Toggle("免打扰", isOn: $muted)
        }
        Section {
            Button("清空聊天记录", role: .destructive) { confirmClear = true }.foregroundStyle(Theme.dangerText)
            Button("删除这段会话", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } footer: {
            Text("清空与删除均无法撤销。")
            HelpNote("清空只删除消息，会话与角色保留；删除会话连同消息一并删除。均无法撤销。角色的记忆不受影响。")
        }
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
    }

    /// 只在这段会话里换头像（网页版 4.437）：角色卡与主页上换的才是所有会话一起换
    private func facePage(_ c: Chat) -> some View {
        MenuPage("头像") {
            faceSection(c)
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .photosPicker(isPresented: $pickingFace, selection: $facePhoto, matching: .images)
    }

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
            HelpNote("只在这段会话中更换，其他会话、联系人、朋友圈与资料页仍显示原来的头像。所有会话一起换，在角色卡或主页中更换。")
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
    @State private var sending = false
    @State private var next: Double = 0
    @ObservedObject private var bg = BgPush.shared

    var body: some View {
        Section {
            Toggle("主动发起对话", isOn: $on)
            if on {
                NumberRow(title: "平均间隔", value: $minutes, unit: "分钟", placeholder: "60", range: 1...100000)
                Stepper("免打扰开始：\(quietFrom) 点", value: $quietFrom, in: 0...23)
                Stepper("免打扰结束：\(quietTo) 点", value: $quietTo, in: 0...23)
                HStack { Text("下一次预计"); Spacer(); Text(nextText).foregroundStyle(Theme.text2) }
            }
            Button(sending ? "正在发起" : "立即发起一次") { sendNow() }.disabled(sending)
            Text("点一次调用一次接口。").font(.footnote).foregroundStyle(Theme.text2)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("主动发起对话")
        } footer: {
            Text("每次开口调用一次接口。" + (bg.problem.isEmpty ? "" : "\n" + bg.problem))
            HelpNote(footer)
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
        next = Proactive.upcoming(charId, count: 1).first ?? 0
        loaded = true
    }

    /// 后台有服务器代发时，本机算的这个时刻只是估计
    private var nextText: String {
        guard next > 0 else { return "尚未排定" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(Date(millis: next)) ? "今天 HH:mm" : "M月d日 HH:mm"
        return f.string(from: Date(millis: next))
    }

    /// 用户点的，手动一次：不看间隔与免打扰，也不挪下一次的时间
    private func sendNow() {
        guard let chat = Proactive.soloChat(charId) else { problem = "与该角色还没有单聊"; return }
        if ((try? Repo.character(charId)) ?? nil)?.archived == true { problem = "封存的角色不再发起对话"; return }
        sending = true
        problem = nil
        Task {
            do {
                let made = try await Proactive.send(chatId: chat.id, charId: charId)
                if made.isEmpty { problem = "这段会话正在生成回复，稍后再试" }
            } catch { problem = "未能发起：\(error.localizedDescription)" }
            sending = false
        }
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
            next = Proactive.upcoming(charId, count: 1).first ?? 0
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
            HelpNote("对所有会话生效。按间隔：相隔五分钟以上时在两条消息之间显示一行时间。已读回执：角色开始回复时，之前发出的消息标为已读。心声默认收起，点角色的头像展开。")
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
            Text("发完就回时，每条消息调用一次接口。")
            HelpNote("按按钮：发出去只是发出去，什么时候回由发送键右边那个按钮决定。发完就回：消息一发出去就立刻生成回复，每条都调用一次接口。"
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
                HelpNote("开启后，角色在「日常」当前时段有事项、或处于免打扰时段时，发来消息会先收到一条自动回复。内容随每天的日程一并生成，不另外调用接口。每段忙碌或休息期间只回一次。正式回复在「延迟回复」下于忙完之后照常发出；其余节奏不再立即回复。"
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
            if mine.on { Text(mine.max > 0 ? "已开启，还可回 \(max(0, mine.max - mine.used)) 条。" : "已开启，不限条数。") }
            HelpNote((mine.on ? (mine.max > 0 ? "已开启，还可回 \(max(0, mine.max - mine.used)) 条。" : "已开启，不限条数。") : "")
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


/// 好友与拉黑（网页版 4.306、4.475）：我这一边拉黑、删除；角色拉黑了我时强制解除；角色删了我时发好友申请。单聊才有
struct TiesSection: View {
    let chatId: String
    @State private var chat: Chat?
    @State private var confirmBlock = false
    @State private var confirmRemove = false
    @State private var requesting = false
    @State private var requestNote = ""
    @State private var problem: String?

    var body: some View {
        if let c = chat, Ties.pair(c) != nil {
            let mine = Ties.userRejects(c)
            let theirs = Ties.charRejects(c)
            Section {
                if mine == "blocked" {
                    Button("解除拉黑") { act { try Ties.userSet(c, blocked: false) } }
                } else {
                    Button("拉黑", role: .destructive) { confirmBlock = true }
                }
                if mine == "removed" {
                    Button("重新添加") { act { try Ties.userSet(c, removed: false) } }
                } else {
                    Button("删除好友", role: .destructive) { confirmRemove = true }
                }
                if theirs == "blocked" {
                    Button("强制解除角色的拉黑") { act { _ = try Ties.forceUnblock(c) } }
                }
                if theirs == "removed" {
                    Button(Ties.pendingRequest(c) == nil ? "发送好友申请" : "重新发送好友申请") { requestNote = ""; requesting = true }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            } header: {
                Text("好友与拉黑")
            } footer: {
                if theirs == "blocked" { Text("角色已将你拉黑。") }
                if theirs == "removed" { Text("角色已将你删除。") }
                HelpNote("拉黑或删除后，你仍可发消息，角色仍可回复与主动发起对话，角色发来的每一条标为被拒收；角色从第一条被拒收起才知道。"
                     + (theirs == "blocked" ? "角色已将你拉黑：强制解除不经过角色，对话中留下一行提示，角色下一轮看得到。" : "")
                     + (theirs == "removed" ? "角色已将你删除：发送好友申请后点回复键，角色在那一次回复中决定是否通过，未通过的那一轮不送达。" : ""))
            }
            .confirmationDialog("拉黑后，角色发来的消息都标为被拒收。可以随时解除。", isPresented: $confirmBlock, titleVisibility: .visible) {
                Button("拉黑", role: .destructive) { act { try Ties.userSet(c, blocked: true) } }
            }
            .confirmationDialog("删除后，角色发来的消息都标为未送达。可以随时重新添加。", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("删除好友", role: .destructive) { act { try Ties.userSet(c, removed: true) } }
            }
            .alert("发送好友申请", isPresented: $requesting) {
                TextField("附言（可不填）", text: $requestNote)
                Button("发送") { act { _ = try Ties.request(c, text: requestNote) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("角色在下一次回复中决定是否通过。")
            }
        } else {
            Color.clear.frame(height: 0).onAppear(perform: load)
        }
    }

    private func load() { chat = try? Repo.chat(chatId) }

    private func act(_ f: () throws -> Void) {
        do {
            try f()
            load()
            problem = nil
            NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
        } catch {
            problem = "未能保存：\(error.localizedDescription)"
        }
    }
}

/// 会话菜单点进去的一页：一个表单，标题写在顶栏
struct MenuPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Form { content() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// 会话菜单里最近点开的几项（本机的使用习惯，不进库、不进备份）。各段会话共用一份：常点的那几项在哪段会话里都一样
enum ChatMenuRecent {
    private static let key = "phone.chatMenu.recent"
    static let keep = 4

    static func ids() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func note(_ id: String) {
        var list = ids().filter { $0 != id }
        list.insert(id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(keep)), forKey: key)
    }
}
