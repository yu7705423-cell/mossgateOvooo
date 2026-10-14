import SwiftUI

/// 一段会话的设置。从会话右上角进来（网页版第 5 条：这段对话的事放在这段对话里）。
struct ChatSettingsView: View {
    let chatId: String
    var onDeleted: () -> Void = {}

    @State private var chat: Chat?
    @State private var pinned = false
    @State private var muted = false
    @State private var narration = false
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
            Section {
                Toggle("置顶", isOn: $pinned)
                Toggle("免打扰", isOn: $muted)
            }
            Section {
                Toggle("旁白", isOn: $narration)
            } footer: {
                Text("开启后，角色的回复中可以夹带旁白，旁白显示为居中的斜体文字。关闭时，回复中的旁白不显示。")
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
                Button("清空聊天记录", role: .destructive) { confirmClear = true }
                Button("删除这段会话", role: .destructive) { confirmDelete = true }
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
        .onChange(of: narration) { _, _ in save() }
        .onChange(of: presetId) { _, _ in save() }
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
            pinned = c.pinned; muted = c.muted; narration = c.row.bool("narration")
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
        if presetId != c.presetId { f["presetId"] = .string(presetId) }
        if summary != c.summary { f["summary"] = .string(summary) }
        guard !f.isEmpty else { return }
        var row = c.row
        for (k, v) in f { row[k] = v }
        row.touch()
        do { try Database.shared.put(Collections.chats, row); problem = nil }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}
