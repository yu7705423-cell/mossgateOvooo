import PhotosUI
import SwiftUI

/// 一段会话的设置。从会话右上角进来（网页版第 5 条：这段对话的事放在这段对话里）。
private struct EditTarget: Identifiable { var id: String }

struct ChatSettingsView: View {
    let chatId: String
    /// 删除会话已经不在这一页（网页版「更多」页没有它，删除在消息列表长按）；参数留着，调用方不用改
    var onDeleted: () -> Void = {}
    /// 搜索这段会话的聊天记录：回到会话页打开搜索，选中一条后跳过去
    var onSearch: (() -> Void)?
    /// 进入多选：回到会话页，逐条勾选后一并删除
    var onSelect: (() -> Void)?
    /// 打开聊天背景：回到会话页，面板只占下半屏，每改一下都看得见
    var onLook: (() -> Void)?

    @State private var chat: Chat?
    /// 在这里打开角色卡（编辑资料）：一张自带导航的页，从「聊天」与「联系」进来的会话都打得开
    @State private var editingChar: String?
    @State private var cardPath = NavigationPath()
    /// 只在这段会话里换头像：换谁（角色 id 或 me），选好图后写进 chat.faces
    @State private var faceKey = ""
    @State private var pickingFace = false
    @State private var facePhoto: PhotosPickerItem?
    @State private var problem: String?
    @State private var loaded = false
    @State private var backlog = 0
    @State private var sinceRounds = 0
    /// 那年今天：往年的今天有记录才出现在菜单里（网页版 otdYears）。翻一遍要过整段历史，只在进来时翻
    @State private var otd: [OnThisDay.Year] = []
    @State private var showSkin = false
    @State private var query = ""
    /// 角色主页：一张自带导航的页（主页里还能点进动态、编辑资料）
    @State private var profileChar: String?
    @State private var profilePath = NavigationPath()

    var body: some View {
        Form {
            menuSections
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("聊天信息")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索设置项")
        .onAppear(perform: load)
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
        .navigationDestination(isPresented: $showSkin) { SkinPageView(chatId: chatId) }
        .sheet(item: Binding(get: { profileChar.map { EditTarget(id: $0) } }, set: { profileChar = $0?.id })) { t in
            NavigationStack(path: $profilePath) {
                ProfileView(subjectId: t.id, path: $profilePath)
                    .navigationDestination(for: ChatAppView.ChatRoute.self) { r in
                        switch r {
                        case .profile(let id): ProfileView(subjectId: id, path: $profilePath)
                        case .moment(let id): MomentDetailView(momentId: id, path: $profilePath)
                        case .editChar(let id): CharacterEditView(charId: id, path: $profilePath)
                        case .editPersona(let id): PersonaEditView(personaId: id)
                        case .search: EmptyView()
                        case .focus(let c, let m): ConversationView(chatId: c, focusId: m)
                        }
                    }
                    .navigationDestination(for: String.self) { id in ConversationView(chatId: id) }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { profileChar = nil } } }
            }
        }
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

    /// 分组与先后照网页版 Conversation.js 的会话菜单：这个角色 / 这段对话怎么聊 / 记忆 / 回顾 / 好友与拉黑 / 更多
    private func entries(_ c: Chat) -> [Entry] {
        var out: [Entry] = []
        func add(_ id: String, _ group: String, _ title: String, _ value: String = "", keys: String = "", searchOnly: Bool = false,
                 action: (() -> Void)? = nil, dest: AnyView? = nil) {
            out.append(Entry(id: id, group: group, title: title, value: value, keys: keys, searchOnly: searchOnly, action: action, dest: dest))
        }
        if let onSearch { add("search", "", "搜索聊天记录", keys: "查找 消息", searchOnly: true, action: onSearch) }
        if let onSelect { add("select", "", "多选消息", keys: "批量 删除", searchOnly: true, action: onSelect) }
        if let onLook { add("look", "", "聊天背景", keys: "背景图 遮罩 顶栏 输入栏 颜色 旁白颜色", searchOnly: true, action: onLook) }
        add("skin", "", "美化", keys: "气泡 头像形状 显示头像 消息时刻 已读回执", searchOnly: true,
            action: { showSkin = true })
        if c.isGroup {
            add("group", "这个群", "群资料", "\(c.characterIds.count) 人", keys: "成员 群名 群昵称 成员私下找你 私信",
                dest: AnyView(groupPage))
            add("face", "这个群", "头像", ChatFaces.faces(c).isEmpty ? "" : "已更换", keys: "成员的头像 我的头像", dest: AnyView(facePage(c)))
            add("abilities", "这个群", "成员的能力", "\(c.characterIds.count) 人",
                keys: "角色能力 能力 开关 语音 图片 音色 生图提示词 锁脸",
                dest: AnyView(GroupAbilitiesView(chatId: chatId)))
        } else if let charId = c.characterIds.first {
            add("card", "这个角色", "角色卡与备注", keys: "人设 资料 编辑 备注",
                action: { cardPath = NavigationPath(); editingChar = charId })
            add("abilities", "这个角色", "角色能力", Abilities.countLabel(try? Repo.character(charId)),
                keys: "能力 开关 语音 图片 发图 表情 转账 通话 电话 来电 一起听 礼物 约定 外卖 拍一拍 备注 锁屏密码 撤回 回应 不回复 骰子 位置 标识 音色 生图提示词 锁脸 长相",
                dest: AnyView(AbilitiesPage(charId: charId)))
            add("face", "这个角色", "头像", ChatFaces.faces(c).isEmpty ? "" : "已更换", keys: "角色的头像 我的头像", dest: AnyView(facePage(c)))
            add("day", "这个角色", "日常与日记", keys: "日程 随机事件 写日记",
                dest: AnyView(MenuPage("日常与日记") {
                    DayOnSection(charId: charId)
                    DiaryAutoSection(charId: charId)
                }))
            add("music", "这个角色", "角色在听什么", keys: "网易云 音乐 歌",
                dest: AnyView(MenuPage("角色在听什么") { MusicCharSection(charId: charId) }))
            // 角色主页（网页版 Conversation.js 的「角色主页」）：朋友圈式的个人页，人设不在那里出现
            add("profile", "这个角色", "角色主页", keys: "主页 朋友圈 精选", action: { profilePath = NavigationPath(); profileChar = charId })
        }
        let how = "这段对话怎么聊"
        let autoOn = c.isGroup ? AutoReply.membersOn(c) > 0 || AutoReply.isOn(c, AutoReply.mine) : !AutoReply.listTag(c).isEmpty
        add("pace", how, "节奏与自动回复", Self.paceLabel(c) + (autoOn ? " · 自动回复" : ""),
            keys: "回复节奏 按按钮 发完就回 延迟回复 自动回复 忙碌 休息 成员的自动回复 休息时不回复",
            dest: AnyView(MenuPage("节奏与自动回复") { PaceSection(chatId: chatId) }))
        if c.isGroup {
            // 群里一段时间没有消息时由成员先开口，以及各成员私下给你发消息，都在群资料里（网页版 4.649）
            add("proactive", how, "主动发起对话", GroupProactive.config(c).on ? "已开启" : "关闭",
                keys: "主动消息 群里主动开口 成员私下找你 私信 间隔 免打扰",
                dest: AnyView(groupPage))
        } else if let charId = c.characterIds.first {
            let char = try? Repo.character(charId)
            add("proactive", how, "主动发起对话", Proactive.config(char).on ? "已开启" : "关闭",
                keys: "主动消息 间隔 免打扰 深夜",
                dest: AnyView(MenuPage("主动发起对话") { ProactiveSection(charId: charId) }))
        }
        add("inner", how, "心声", Self.innerLabel(InnerVoice.mode(c)), keys: "想法 内心 显示方式 样式 字色 字号",
            dest: AnyView(InnerSetPageView(chatId: chatId)))
        add("extras", how, "互动", c.isGroup ? "旁白 · 我也写旁白" : "旁白 · 拍一拍 · \(ChatEngine.diceFaces(c)) 面骰子",
            keys: "旁白 我也写旁白 草稿箱 拍一拍 后缀 骰子 几面",
            dest: AnyView(ExtrasPageView(chatId: chatId)))
        if !c.isGroup {
            add("status", how, "状态栏", StatusBar.active(c) ? "已开启" : "关闭", keys: "心情 所在地 进度条",
                dest: AnyView(StatusBarSettingsView(chatId: chatId)))
            add("share", how, "共享位置", Self.geoLabel(c), keys: "位置 距离 城市 坐标",
                dest: AnyView(GeoView(chatId: chatId)))
        }
        let lang = c.row.string("translateTo").trimmingCharacters(in: .whitespaces)
        add("translate", how, "翻译", lang.isEmpty ? "关闭" : lang, keys: "译文 语言 显示哪一种 译文怎么显示 只显示译文 只显示原文",
            dest: AnyView(TranslatePageView(chatId: chatId)))
        add("preset", how, "预设", ChatPresetPage.label(c), keys: "提示词 条目 参数",
            dest: AnyView(ChatPresetPage(chatId: chatId)))
        add("history", how, "历史范围", HistoryRangePage.label(c), keys: "上下文 历史 读几条 条数 轮数",
            dest: AnyView(HistoryRangePage(chatId: chatId)))
        if c.isGroup {
            add("lore", how, "世界书", "在各成员的角色资料里设置", keys: "设定 词条",
                dest: AnyView(GroupLorePage(chatId: chatId)))
        } else if let charId = c.characterIds.first {
            let names = Self.loreNames(charId)
            add("lore", how, "世界书", names.isEmpty ? "没有生效的世界书" : "生效中：\(names)", keys: "设定 词条 内置卡片",
                dest: AnyView(LoreQuickView(charId: charId)))
        }
        add("time", how, "时间感知", Self.timeState(AppSettings.load()), keys: "时区 时间 日期 虚拟时间",
            dest: AnyView(TimeSettingsView()))
        add("summary", "记忆", "记忆总结", summaryState, keys: "总结 记住",
            dest: AnyView(SummaryPage(chatId: chatId)))
        if !c.isGroup {
            add("bond", "记忆", "关系底色", keys: "你们之间 关系 现状 S 级",
                dest: AnyView(BondView(chatId: chatId)))
        }
        add("badges", "回顾", "互动标识", Badges.streak(c).n > 0 ? "连续 \(Badges.streak(c).n) 天" : "", keys: "火花 连续互发 成就 等级 亲密度",
            dest: AnyView(BadgesView(chatId: chatId)))
        if let first = otd.first {
            add("otd", "回顾", "那年今天", "\(first.ago) 年前的今天，共 \(first.msgs.count) 条", keys: "往年 去年今天 回忆",
                dest: AnyView(OnThisDayView(chatId: chatId)))
        }
        if !c.isGroup, Ties.pair(c) != nil {
            add("ties", "好友与拉黑", "好友与拉黑", Self.tieLabel(c), keys: "拉黑 删除好友 好友申请",
                dest: AnyView(MenuPage("好友与拉黑") { TiesSection(chatId: chatId) }))
        }
        add("more", "更多", "更多", c.isGroup ? "表情包、每轮的接口调用" : "表情包、每轮的接口调用、清空数据",
            keys: "表情包 每轮的接口调用 清空聊天记录 清空记忆",
            dest: AnyView(ChatMorePageView(chatId: chatId)))
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

    /// 群资料：成员、成员私下找你、群里主动开口（网页版 GroupInfo）
    private var groupPage: some View {
        MenuPage("群资料") {
            GroupMembersSection(chatId: chatId)
            GroupDMSection(chatId: chatId)
            GroupProactiveSection(chatId: chatId)
        }
    }

    /// 共享位置那一行（网页版 geo.summary）：两端都填了写「甲 到 乙 · 距离」，没开写关闭
    static func geoLabel(_ c: Chat) -> String {
        let st = Geo.state(c)
        guard st.on, let me = st.me, let ch = st.char else { return "关闭" }
        let km = Geo.distance(me, ch)
        let d = km == nil ? "缺少坐标" : Geo.distanceText(km)
        return "\(me.place.isEmpty ? "未命名" : me.place) 到 \(ch.place.isEmpty ? "未命名" : ch.place) · \(d)"
    }

    /// 这个角色此刻生效的对话用世界书（网页版 lore.chatBooksFor：全局的加这个角色挂着的）
    static func loreNames(_ charId: String) -> String {
        guard let char = (try? Repo.character(charId)) ?? nil else { return "" }
        return ((try? Repo.lorebooks()) ?? [])
            .filter { $0.purpose == "chat" && ($0.global || char.lorebookIds.contains($0.id)) }
            .map { $0.name.isEmpty ? "未命名" : $0.name }
            .joined(separator: "、")
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

    /// 菜单那一行（网页版 Conversation.js）：按轮数时写「几轮未总结 · 每 N 轮自动总结」，没开时写条数
    private var summaryState: String {
        let s = AppSettings.load()
        let every = Int((s.raw["autoSummarizeInterval"]?.number ?? 0).rounded())
        if every > 0 { return "\(sinceRounds) 轮未总结 · 每 \(every) 轮自动总结" }
        return "\(backlog) 条未总结 · 自动总结已关闭"
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
        sinceRounds = MemorySummary.roundsIn((try? MemorySummary.sinceTried(chatId: chatId)) ?? [])
    }

    /// 每次回到菜单都重读：子页各自写库，菜单各行的当前状态跟着变
    private func load() {
        refreshBacklog()
        do {
            guard let c = try Repo.chat(chatId) else { problem = "这段会话不存在"; return }
            chat = c
            if !loaded { otd = OnThisDay.ofChat(chatId) }
            loaded = true
        } catch {
            problem = error.localizedDescription
        }
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
    @State private var emo = false
    @State private var emoFrom = 1
    @State private var emoTo = 4
    @State private var emoDays = 5.0
    @ObservedObject private var bg = BgPush.shared

    var body: some View {
        Section {
            Toggle("主动发起对话", isOn: $on)
            if on {
                NumberRow(title: "平均间隔", value: $minutes, unit: "分钟", placeholder: "60", range: 1...100000)
                Stepper("免打扰开始：\(quietFrom) 点", value: $quietFrom, in: 0...23)
                Stepper("免打扰结束：\(quietTo) 点", value: $quietTo, in: 0...23)
                HStack { Text("下一次预计"); Spacer(); Text(nextText).foregroundStyle(Theme.text2) }
                Toggle("深夜那一档", isOn: $emo)
                if emo {
                    Stepper("深夜从 \(emoFrom) 点", value: $emoFrom, in: 0...23)
                    Stepper("到 \(emoTo) 点", value: $emoTo, in: 0...23)
                    NumberRow(title: "距上次至少隔", value: $emoDays, unit: "天", placeholder: "0", range: 0...365)
                    HelpNote("深夜那一档：在设定的深夜时段内，角色以夜里醒着的状态开口，每次调用一次接口。距上次至少隔设定的天数，填 0 表示每晚都可能。不受免打扰时段限制；只在应用打开时发送。", title: "深夜那一档")
                }
            }
            Button(sending ? "正在发起" : "立即发起一次") { sendNow() }.disabled(sending)
            Text("点一次调用一次接口。").font(.footnote).foregroundStyle(Theme.text2)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("主动发起对话")
        } footer: {
            Text("每次开口调用一次接口。" + (bg.problem.isEmpty ? "" : "\n" + bg.problem))
            HelpNote("开启后，聊天停下来、隔了设定的间隔没有新消息时，角色主动发起对话。间隔从最后一条消息（任何一方）算起，实际间隔在设定值的 0.5 至 1.5 倍之间随机取值；最后一条消息距今不到设定值的一半时不发送。正在聊天、回复尚未落下或排着延迟回复时不发送。每次调用一次接口（走主用接口）。免打扰时段内不发，开始与结束相同表示不设。未读消息达到「设置 - 用量与上限」中的条数后暂停。"
                     + (BgPush.isOn() ? "应用不在前台时由后台消息服务器代发。" : "只在应用打开时发送；应用不在前台时的代发见「设置 - 后台消息」。"), title: "主动发起对话")
        }
        .onAppear(perform: load)
        .onChange(of: on) { _, _ in save() }
        .onChange(of: minutes) { _, _ in save() }
        .onChange(of: quietFrom) { _, _ in save() }
        .onChange(of: quietTo) { _, _ in save() }
        .onChange(of: emo) { _, _ in saveEmo() }
        .onChange(of: emoFrom) { _, _ in saveEmo() }
        .onChange(of: emoTo) { _, _ in saveEmo() }
        .onChange(of: emoDays) { _, _ in saveEmo() }
    }

    private func load() {
        guard let c = try? Repo.character(charId) else { return }
        let cfg = Proactive.config(c)
        on = cfg.on; minutes = cfg.minutes; quietFrom = cfg.quietFrom; quietTo = cfg.quietTo
        next = Proactive.upcoming(charId, count: 1).first ?? 0
        emo = cfg.emo; emoFrom = cfg.emoFrom; emoTo = cfg.emoTo; emoDays = Double(cfg.emoDays)
        loaded = true
    }

    private func saveEmo() {
        guard loaded, var c = try? Repo.character(charId) else { return }
        c.row["emo"] = .bool(emo)
        c.row["emoFrom"] = .number(Double(emoFrom))
        c.row["emoTo"] = .number(Double(emoTo))
        c.row["emoDays"] = .number(max(0, emoDays.rounded()))
        c.row.touch()
        do { try Database.shared.put(Collections.characters, c.row); problem = nil }
        catch { problem = "保存失败：\(error.localizedDescription)" }
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
        if ((try? Repo.character(charId)) ?? nil)?.archived == true { problem = "封存的角色不再发起对话"; return }
        // 只在群里认识的成员（从群资料「成员私下找你」进来）：建一段单聊再发（网页版 4.649）
        let found: Chat?
        do { found = try Proactive.ensureSoloChat(charId) } catch { problem = "未能建立单聊：\(error.localizedDescription)"; return }
        guard let chat = found else { problem = "与该角色还没有单聊，也不在同一个群里"; return }
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
            self.next = Proactive.upcoming(charId, count: 1).first ?? 0
            problem = nil
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
        }
    }
}

/// 群资料里的「成员私下找你」（网页版 4.649）：逐个成员进他自己的「主动发起对话」。开关仍在角色身上，与单聊菜单里的是同一份；
/// 只在群里认识、还没有单聊的成员，到点时建一段单聊再发
struct GroupDMSection: View {
    let chatId: String
    @State private var members: [Character] = []
    @State private var chat: Chat?

    var body: some View {
        Section {
            ForEach(members) { m in
                NavigationLink {
                    MenuPage("主动发起对话") { ProactiveSection(charId: m.id) }
                        .onDisappear(perform: load)
                } label: {
                    HStack {
                        Text(chat.map { GroupChat.nameIn($0, m) } ?? m.displayName)
                        Spacer()
                        Text(Proactive.config(m).on ? "已开启" : "关闭").foregroundStyle(Theme.text3)
                    }
                }
            }
        } header: {
            Text("成员私下找你")
        } footer: {
            HelpNote("各成员是否主动给你发私信，与该角色单聊菜单里的「主动发起对话」是同一个开关。与你还没有单聊的成员，到点时先建立一段单聊再发送。每次开口调用一次接口。", title: "成员私下找你")
        }
        .onAppear(perform: load)
    }

    private func load() {
        chat = (try? Repo.chat(chatId)) ?? nil
        members = chat.map { GroupChat.members($0) } ?? []
    }
}

/// 会话里怎么显示：消息时刻、已读回执（网页版 SkinPage 的这两项，对所有会话生效）。
/// 译文显示哪一种、怎么展开在会话菜单的「翻译」页（网页版 4.529），这里不再放第二份（第 5 条：一个开关一个入口）
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
        } header: {
            GroupTitle("显示")
        } footer: {
            HelpNote("显示消息在本机出现的时刻，与角色写在正文里的时间无关。按间隔：相邻两条相隔五分钟以上时，在中间居中显示一行时间。每条：在每条消息旁或下方显示时分，隔天带上日期。对所有会话生效。", title: "消息时刻")
            HelpNote("在自己发出的消息旁标注已读或未读。角色开始生成回复时记为已读，一直没有回复则保持未读。关闭后不再标注。对所有会话生效。", title: "显示已读回执")
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
                    // 群里同样有这一项（网页版 4.649）：各成员按自己的免打扰时段算休息
                    Toggle("休息时不回复", isOn: Binding(get: { Pace.sleepOn(c) }, set: { set(["paceSleep": .bool($0)]) }))
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
            if chat?.isGroup == true {
                HelpNote("休息时不回复：各成员自己的免打扰时段（在各成员的「主动发起对话」中设置）内视为休息。关闭后按空闲计算。", title: "休息时不回复（群聊）")
            }
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
        if c.isGroup {
            groupAuto(c)
        } else {
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

    /// 群聊：每个成员一份自动回复（网页版 PacePage 的 GroupAuto，4.649）。逐个成员开关，写明此刻在做什么。暂时离开在群里不适用
    @ViewBuilder
    private func groupAuto(_ c: Chat) -> some View {
        let members = GroupChat.members(c)
        let now = Clock.now(AppSettings.load()).millis
        Section {
            ForEach(members) { m in
                let st = Pace.state(c, char: m, at: now)
                let what = st.kind == "busy" ? "正在\(st.what)" : st.kind == "asleep" ? "休息中" : "空闲"
                Toggle(isOn: Binding(get: { AutoReply.member(c, m.id).on }, set: { setMember(m.id, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(GroupChat.nameIn(c, m))
                        Text("当前：\(what)" + (DayPlan.isOn(m) ? "" : "。尚未开启「日常」，没有当前事项与自动回复的内容"))
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
            }
        } header: {
            Text("成员的自动回复")
        } footer: {
            HelpNote("开启后，该成员在「日常」当前时段有事项、或处于自己的免打扰时段时，你在群里发消息会先收到该成员的一条自动回复，每段忙碌或休息期间只回一次；之后在这段时间里，群里的回复不再写该成员的话。", title: "成员的自动回复")
            HelpNote("内容按各成员的设定与正在做的事写成，随每天的日程一并生成，不另外调用接口。所有能发言的成员都回过自动回复时，这一条不再立即回复，延迟回复档在忙完之后照常回复。", title: "成员的自动回复：内容与回复")
        }
    }

    private func setMember(_ charId: String, _ on: Bool) {
        do { try AutoReply.setMember(chatId, charId, ["on": .bool(on)]); load(); problem = nil }
        catch { problem = "未能保存：\(error.localizedDescription)" }
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

/// 拍一拍的后缀（网页版 extras.js 与 ExtrasPage）：后缀由被拍的一方设定。拍角色时写在角色那一份上，
/// 角色拍你时用你自己的（全局一份）。网页版「拍角色时」在角色卡里；原生版的角色卡还没有这一项，先放在「互动」页。群聊只有后一项
struct PatSection: View {
    let charId: String?
    @ObservedObject private var model = SettingsModel.shared
    @State private var charPat = ""
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        if let charId {
            Section {
                TextField(Interact.patSuffixes[0], text: $charPat)
                chips { charPat = $0 }
            } header: {
                Text("拍角色时显示的后缀")
            } footer: {
                HelpNote("你拍角色时，提示写成「你拍了拍角色」加上这一段，例如「的头」。留空则使用「的头」。只对这个角色生效，在该角色参与的各个单聊中一致。", title: "拍一拍：拍角色时")
            }
            .onAppear {
                charPat = (((try? Repo.character(charId)) ?? nil)?.row.string("patSuffix")) ?? ""
                loaded = true
            }
            .onChange(of: charPat) { _, v in
                guard loaded, let c = (try? Repo.character(charId)) ?? nil else { return }
                do { _ = try People.update(c, ["patSuffix": .string(String(v.prefix(20)))]); problem = nil }
                catch { problem = "保存失败：\(error.localizedDescription)" }
            }
        }
        Section {
            TextField(Interact.patSuffixes[0], text: model.textBinding("patSuffix"))
            chips { v in model.set("patSuffix", .string(v)) }
        } header: {
            Text("别人拍我时显示的后缀")
        } footer: {
            HelpNote("双击头像即可拍一拍。后缀由被拍的一方设定，所以这一项是角色拍你时显示的。拍角色时显示的是上面那一项。留空则使用「的头」。对所有角色生效。", title: "拍一拍：别人拍我时")
        }
        if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
    }

    private func chips(_ pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(Interact.patSuffixes, id: \.self) { x in
                    Button(x) { pick(x) }.buttonStyle(.bordered).font(.footnote)
                }
            }
        }
    }
}
