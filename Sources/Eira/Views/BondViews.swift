import SwiftUI

/// 关系底色（网页版 apps/chat/pages/BondPage.js）。改的是现状里的「你们之间」这一块；没写过时读关系底色。
/// 跟着这段对话走，入口在会话菜单的「记忆」一组（第 5 条）
struct BondView: View {
    let chatId: String
    @State private var char: Character?
    @State private var key = ""
    @State private var text = ""
    @State private var dirty = false
    @State private var locked = false
    @State private var manual = false
    @State private var at: Double = 0
    @State private var failed = ""
    @State private var stale = false
    @State private var sources: [Memory] = []
    @State private var busy = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var confirmRegen = false

    var body: some View {
        Form {
            Section {
                TextField("尚未生成。可以自己写，也可以由模型根据关系转折级记忆生成。", text: Binding(get: { text }, set: { text = $0; dirty = true }), axis: .vertical)
                    .lineLimit(4...12)
                HelpNote("这段内容每轮都会注入，说明你与角色目前处于什么关系。总结记忆时由模型随现状一起改写；也可以由标记为 S 级（关系转折）的记忆压缩生成，S 级记忆不再逐条注入。手动修改并保存后锁住，总结记忆与 S 级记忆变动都不再改写它，可以在下方解锁。留空则不注入。其余几块现状在「设定集 - 记忆」里该角色的「现状」页。", title: "关系底色")
                Button("保存") { save() }.disabled(!dirty)
                Button(busy ? "正在生成" : "重新生成") {
                    if manual || locked { confirmRegen = true } else { regen() }
                }
                .disabled(busy || sources.isEmpty)
                Text("重新生成调用一次接口（走记忆接口，没单独配时走副用）。").font(.footnote).foregroundStyle(Theme.text2)
            } header: { Text("正文") }
            Section {
                row("上次生成", at > 0 ? Self.when(at) : "尚未生成")
                row("来源记忆", "\(sources.count) 条")
                Text(locked ? "手写的版本已锁住。总结记忆与 S 级记忆变动都不会改写它。"
                     : stale ? "S 级记忆已有变动。开启「自动重压关系底色」时，下次发送消息时重新生成。"
                     : "随总结记忆自动改写。")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if !failed.isEmpty { Text("上次生成失败：\(failed)").font(.footnote).foregroundStyle(Theme.danger) }
                if locked || manual {
                    Button("解锁，恢复自动改写") { unlock() }
                }
            }
            Section {
                if sources.isEmpty {
                    Text("暂无。将记忆的重要级别设为 S，它就会进入这里。S 级用于关系的重大转折。").foregroundStyle(Theme.text2)
                }
                ForEach(sources, id: \.id) { m in Text(m.content).font(.system(size: 14)) }
            } header: { Text("来源：关系转折级记忆 \(sources.count)") }
            ProblemSection(text: problem)
        }
        .navigationTitle("关系底色")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .confirmationDialog("当前内容为手动编辑的版本，重新生成将覆盖它。", isPresented: $confirmRegen, titleVisibility: .visible) {
            Button("生成") { regen() }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(Theme.text2) }
    }

    static func when(_ ms: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f.string(from: Date(millis: ms))
    }

    private func reload() {
        guard let chat = (try? Repo.chat(chatId)) ?? nil, let cid = chat.characterIds.first,
              let c = (try? Repo.character(cid)) ?? nil else { problem = "该会话已不存在"; return }
        char = c
        key = (try? MemorySummary.stateKey(chat.personaId)) ?? "root"
        let st = MemorySummary.stateOf(char: c, key: key)
        if !dirty { text = st.blocks["us"] ?? "" }
        locked = st.locks.contains("us")
        let b = c.row["bonds"]?[key]
        manual = b?["manual"]?.bool == true
        at = b?["at"]?.number ?? 0
        failed = b?["failed"]?.string ?? ""
        stale = (try? Bond.stale(charId: c.id, personaId: chat.personaId)) ?? false
        sources = (try? Bond.sources(charId: c.id, personaId: chat.personaId)) ?? []
    }

    private func save() {
        guard let c = char else { return }
        do {
            try MemorySummary.setState(charId: c.id, key: key, block: "us", text: text)
            dirty = false
            notice = "已保存。总结记忆时不再自动改写这一块。"
            reload()
        } catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    private func unlock() {
        guard let c = char else { return }
        do {
            try MemorySummary.lockState(charId: c.id, key: key, block: "us", on: false)
            try Bond.unlock(charId: c.id, key: key)
            reload()
        } catch { problem = "操作失败：\(error.localizedDescription)" }
    }

    private func regen() {
        guard let c = char, let chat = (try? Repo.chat(chatId)) ?? nil else { return }
        guard !AIService.chain(task: "memory.bond", group: RouteGroup.of(task: "memory.bond"), settings: .load()).isEmpty else {
            problem = "尚未配置可用的接口，无法自动生成，可以手动填写。"
            return
        }
        busy = true
        problem = nil
        Task { @MainActor in
            do {
                // 用户点的：先解锁「你们之间」，生成的那一份写进去（网页版 force）
                try MemorySummary.lockState(charId: c.id, key: key, block: "us", on: false)
                try await Bond.refresh(charId: c.id, personaId: chat.personaId)
                dirty = false
                reload()
                notice = failed.isEmpty ? "已重新生成。" : nil
                if !failed.isEmpty { problem = "生成失败：\(failed)" }
            } catch { problem = "生成失败：\(error.localizedDescription)"; reload() }
            busy = false
        }
    }
}

/// 草稿箱（网页版 4.335）：开关与这段会话里角色写了没发的话。开关挂在会话上，默认关
struct DraftsView: View {
    let chatId: String
    @State private var on = false
    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Toggle("草稿箱", isOn: $on)
                HelpNote("开启后，角色可以在回复里留下写了又没发出去的话，不显示在聊天里，存在这里。写不写、写什么由角色决定。随回复一起，不另外调用接口。关闭后不再记录，已有的草稿保留。", title: "草稿箱")
            }
            Section {
                if rows.isEmpty { Text("还没有草稿。").foregroundStyle(Theme.text2) }
                ForEach(rows, id: \.id) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.string("text"))
                        Text(SceneListView.date(r.created ?? 0)).font(.footnote).foregroundStyle(Theme.text3)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            do { try Drafts.remove(r.id); reload() } catch { problem = "删除失败：\(error.localizedDescription)" }
                        }
                    }
                }
            } header: { Text("草稿") }
            ProblemSection(text: problem)
        }
        .navigationTitle("草稿箱")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            on = Drafts.on((try? Repo.chat(chatId)) ?? nil)
            reload()
            loaded = true
        }
        .onChange(of: on) { _, v in
            guard loaded else { return }
            do { try Drafts.setOn(chatId, v) } catch { problem = "保存失败：\(error.localizedDescription)" }
        }
    }

    private func reload() { rows = Drafts.list(chatId) }
}
