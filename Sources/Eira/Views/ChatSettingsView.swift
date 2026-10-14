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

    @State private var chat: Chat?
    @State private var pinned = false
    @State private var muted = false
    @State private var narration = false
    @State private var userNarration = false
    /// 在这里打开角色卡（编辑资料）：一张自带导航的页，从「聊天」与「联系」进来的会话都打得开
    @State private var editingChar: String?
    @State private var cardPath = NavigationPath()
    @State private var innerMode = "off"
    @State private var innerWhat = ""
    @State private var translateTo = ""
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
                }
            }
            Section {
                Toggle("置顶", isOn: $pinned)
                Toggle("免打扰", isOn: $muted)
            }
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
                    TextField("写什么（留空为默认）", text: $innerWhat, axis: .vertical).lineLimit(1...4)
                }
            } footer: {
                Text(innerMode == "apart"
                     ? "每一轮说完之后另调用一次接口，写出刚才那几句话背后的想法。每轮多一次调用（走副用接口）。"
                     : innerMode == "inline" ? "角色在每轮回复的最后写一行心声，对方看不到。不多调用接口。"
                     : "开启后显示角色每轮话语背后的想法。")
            }
            Section {
                TextField("译成哪种语言（留空为不翻译）", text: $translateTo)
            } header: {
                Text("翻译")
            } footer: {
                Text("填写后，角色每条消息在同一行附上译文，显示在气泡下方。随回复一起写出，不多调用接口；回复会变长，用量随之增加。")
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
        .onChange(of: narration) { _, _ in save() }
        .onChange(of: userNarration) { _, _ in save() }
        .onChange(of: presetId) { _, _ in save() }
        .onChange(of: innerMode) { _, _ in save() }
        .onDisappear(perform: save)
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
            innerMode = InnerVoice.mode(c); innerWhat = c.row.string("innerWhat")
            translateTo = c.row.string("translateTo")
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
        let lang = translateTo.trimmingCharacters(in: .whitespaces)
        if lang != c.row.string("translateTo") { f["translateTo"] = .string(String(lang.prefix(40))) }
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
