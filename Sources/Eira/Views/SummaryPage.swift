import SwiftUI

/// 会话菜单里的「记忆总结」（网页版 SummaryPage.js，4.535、4.606）：上面是这段对话积了多少、一个「立即总结」，
/// 下面是自动总结的开关与触发条件（离开会话、隔夜两条由 MemWatch 盯着，4.441）。自动总结仍是全局的（对所有会话生效），页面上写明；开关只在这一处（第 5 条），
/// 「设定集 - 记忆」那里只留一行状态。
/// 设了「每 N 轮」就按轮数：一次总结最早的 N 轮（用户定的「设多少轮就总结多少轮」），状态一律按轮数写，不再按条数。
struct SummaryPage: View {
    let chatId: String
    @ObservedObject private var model = SettingsModel.shared
    @State private var pending = 0
    @State private var sinceRounds = 0
    @State private var runs = 0
    @State private var summing = false
    @State private var note: String?
    @State private var problem: String?
    @State private var confirmRun = false
    @State private var confirmSkip = false
    /// 开启「每 N 轮」时发现各段对话有积压，先问（网页版 4.606）
    @State private var asking: (n: Int, list: [MemorySummary.Backlog])?
    /// 关掉时记住上次的轮数，再开回到它
    @State private var remembered = 6

    private var interval: Int { max(0, Int((model.s.raw["autoSummarizeInterval"]?.number ?? 0).rounded())) }
    private var autoOn: Bool { interval > 0 }
    private var memoryOn: Bool { model.s.raw["memoryEnabled"]?.bool ?? true }
    private var batch: Int { max(0, Int((model.s.raw["memoryBatch"]?.number ?? 200).rounded())) }
    /// 一批是多少：按轮数时是 N 轮，否则是「一次总结的条数」
    private var batchText: String { autoOn ? "\(interval) 轮" : "\(batch > 0 ? batch : pending) 条" }

    private var state: String {
        if !memoryOn { return "记忆已关闭，自动总结不会执行" }
        return autoOn ? "\(sinceRounds) 轮未总结 · 每 \(interval) 轮自动总结" : "自动总结已关闭"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("这段对话", value: "\(pending) 条未总结")
                Text(state).font(.footnote).foregroundStyle(Theme.text2)
                Button(summing ? "正在总结记忆" : "立即总结") {
                    if runs > 1 { confirmRun = true } else { summarize() }
                }
                .disabled(summing || pending < 2)
                if let note { Text(note).font(.footnote).foregroundStyle(Theme.text2) }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            } footer: {
                Text(summing ? "正在调用接口，完成后会给出结果。"
                     : runs > 1 ? "调用一次接口，总结最早未总结的一批（每批 \(batchText)，追平需 \(runs) 次）。"
                     : "调用一次接口，总结最早未总结的消息。")
            }
            if runs > 1 {
                Section {
                    Button("标记为已总结", role: .destructive) { confirmSkip = true }
                        .foregroundStyle(Theme.dangerText)
                } footer: {
                    Text("把这 \(pending) 条记为已总结，不调用接口，也不生成记忆。")
                }
            }
            Section {
                Toggle("按轮数自动总结", isOn: Binding(get: { autoOn }, set: toggleAuto))
                if autoOn {
                    NumberRow(title: "间隔轮数", value: Binding(get: { Double(interval) }, set: { v in
                        let n = Int(v.rounded())
                        guard n >= 1 else { return }
                        remembered = n
                        model.set("autoSummarizeInterval", .number(Double(n)))
                    }), unit: "轮", placeholder: "\(remembered)", range: 1...Double(Int32.max))
                }
            } header: {
                Text("自动总结 · 对所有会话生效")
            } footer: {
                if !memoryOn {
                    Text("记忆已在「设定集 - 记忆」中关闭，自动总结不会执行。上方的「立即总结」不受影响。")
                } else if autoOn {
                    Text("角色每回复 \(interval) 轮，自动总结这 \(interval) 轮的对话。积压多于 \(interval) 轮时，从最早的 \(interval) 轮开始总结。每次总结调用一次接口。")
                } else {
                    Text("已关闭。下方其他触发条件也都关着时，记忆只在点「立即总结」时才提取。")
                }
                HelpNote("间隔轮数填角色回复的轮数。数值越小记得越勤，接口调用也越频繁。", title: "记忆总结：间隔轮数")
            }
            Section {
                NumberRow(title: "未总结的消息达到", value: model.number("autoSummarizeMessages", 0), unit: "条", placeholder: "不看")
                NumberRow(title: "未总结的文字达到", value: model.number("autoSummarizeChars", 0), unit: "字", placeholder: "不看")
                NumberRow(title: "离开会话多少分钟后", value: model.number("autoSummarizeIdle", 0), unit: "分钟", placeholder: "不看")
                Toggle("隔夜总结", isOn: model.bool("autoSummarizeOvernight", false))
                NumberRow(title: "一次最多连续总结几批", value: model.number("autoSummarizeCatchUp", 1), unit: "批", placeholder: "追平")
            } header: {
                Text("其他触发条件")
            } footer: {
                Text("每次总结调用一次接口；连续总结几批就调用几次。")
                HelpNote("离开会话多少分钟后：退出一段会话（换到别处、回到主界面、应用退到后台）这么多分钟后，积压达到两轮即总结。对话结束是整理的自然时机。填 0 表示不看。", title: "记忆总结：离开会话后")
                HelpNote("隔夜总结：打开应用或回到前台时，积压里最后一条是前一天或更早的，即总结那段会话。关闭后不看。", title: "记忆总结：隔夜总结")
                HelpNote("条数与字数各自独立，与轮数任一条件先满足即总结，填 0 表示不看。触发后一次只总结最早的一批：设了轮数时一批是那么多轮，否则一批的条数在「设定集 - 记忆」的「一次总结的条数」中设置。一次最多连续总结几批：填几批就连着总结几批，每批调用一次接口；填 0 为追平为止。失败的那一次也算试过，要再攒够一个间隔才重试。", title: "记忆总结：其他触发条件")
            }
        }
        .navigationTitle("记忆总结")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if interval > 0 { remembered = interval }
            refresh()
        }
        .onChange(of: interval) { _, _ in refresh() }
        .confirmationDialog("总结记忆", isPresented: $confirmRun, titleVisibility: .visible) {
            Button("总结这一批") { summarize() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这段对话尚有 \(pending) 条未总结。一次总结最早的 \(batchText)，追平需要重复 \(runs) 次，每次调用一次接口。现在只总结最早的那一批。")
        }
        .confirmationDialog("标记为已总结", isPresented: $confirmSkip, titleVisibility: .visible) {
            Button("标记", role: .destructive) {
                do {
                    let n = try MemorySummary.markCaughtUp(chatId: chatId)
                    note = "已标记 \(n) 条。"
                    problem = nil
                } catch { problem = "未能保存：\(error.localizedDescription)" }
                refresh()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把 \(pending) 条消息记为已总结，不调用接口，也不会生成任何记忆。此后只总结新产生的对话。已有的记忆不受影响。")
        }
        .confirmationDialog("已有未总结的消息", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible) {
            if let a = asking {
                let msgs = a.list.reduce(0) { $0 + $1.msgs }
                let total = a.list.reduce(0) { $0 + $1.runs }
                Button("先总结积压（调用 \(total) 次接口）") { start(a, summarize: true) }
                Button("跳过积压（\(msgs) 条不生成记忆）") { start(a, summarize: false) }
                Button("暂不开启", role: .cancel) { asking = nil }
            }
        } message: {
            if let a = asking {
                let msgs = a.list.reduce(0) { $0 + $1.msgs }
                let total = a.list.reduce(0) { $0 + $1.runs }
                Text("\(a.list.count) 段对话共有 \(msgs) 条消息早于最近 \(a.n) 轮、尚未总结。先总结积压：每 \(a.n) 轮调用一次接口，共 \(total) 次，完成后再按轮数自动总结。跳过积压：这 \(msgs) 条标为已总结，不调用接口，也不生成记忆。")
            }
        }
    }

    private func refresh() {
        let p = (try? MemorySummary.pending(chatId: chatId)) ?? []
        pending = p.count
        sinceRounds = MemorySummary.roundsIn((try? MemorySummary.sinceTried(chatId: chatId)) ?? [])
        runs = MemorySummary.runsFor(p, every: interval, batch: batch)
    }

    private func toggleAuto(_ on: Bool) {
        if on {
            let n = remembered > 0 ? remembered : 6
            let list = memoryOn ? MemorySummary.backlog(every: n) : []
            if !list.isEmpty { asking = (n, list); return }
            model.set("autoSummarizeInterval", .number(Double(n)))
        } else {
            if interval > 0 { remembered = interval }
            model.set("autoSummarizeInterval", .number(0))
        }
    }

    /// 选好了：先总结积压（用户当场同意的次数，不经过 claim），或者把积压标为已总结；然后开启
    private func start(_ a: (n: Int, list: [MemorySummary.Backlog]), summarize: Bool) {
        asking = nil
        if !summarize {
            do { for b in a.list { try MemorySummary.skipBacklog(chatId: b.chatId, keep: a.n) } }
            catch { problem = "未能标记：\(error.localizedDescription)"; return }
            model.set("autoSummarizeInterval", .number(Double(a.n)))
            note = "已跳过 \(a.list.reduce(0) { $0 + $1.msgs }) 条。"
            refresh()
            return
        }
        // 先开启，每次总结按「最早的 N 轮」取，正好留下最近 N 轮
        model.set("autoSummarizeInterval", .number(Double(a.n)))
        let total = a.list.reduce(0) { $0 + $1.runs }
        note = "正在总结积压，共 \(total) 次。"
        summing = true
        let list = a.list
        Task {
            var done = 0
            var failed = ""
            outer: for b in list {
                for _ in 0..<b.runs {
                    do { _ = try await MemorySummary.extract(chatId: b.chatId); done += 1 }
                    catch { failed = error.localizedDescription; break outer }
                }
            }
            await MainActor.run {
                summing = false
                if failed.isEmpty { note = "积压已总结完，共 \(done) 次。" }
                else { note = nil; problem = "总结了 \(done) 次后失败：\(failed)。剩下的仍未总结，可稍后在各会话中「立即总结」。" }
                refresh()
            }
        }
    }

    private func summarize() {
        summing = true
        note = nil
        problem = nil
        let id = chatId
        Task {
            do {
                let r = try await MemorySummary.extract(chatId: id)
                await MainActor.run {
                    note = r.total + r.state == 0 ? "没有需要记录的新信息。"
                        : "新增 \(r.added) 条，更新 \(r.updated) 条，了结 \(r.closed) 条" + (r.state > 0 ? "，现状改写 \(r.state) 块。" : "。")
                }
            } catch {
                await MainActor.run { problem = "总结失败：\(error.localizedDescription)" }
            }
            await MainActor.run { summing = false; refresh() }
        }
    }
}
