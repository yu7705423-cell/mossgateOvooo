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

/// 那年今天：往年的这一天这段对话里说过什么，默认看今天，可以前后翻。每一年先露几条（默认值，不是上限）
struct OnThisDayView: View {
    let chatId: String
    @State private var at = Date()
    @State private var years: [OnThisDay.Year] = []
    @State private var open: Set<Int> = []
    @State private var meName = "我"

    var body: some View {
        List {
            Section {
                HStack {
                    Button("前一天") { step(-1) }.buttonStyle(.borderless)
                    Spacer()
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("后一天") { step(1) }.buttonStyle(.borderless)
                }
                if !Calendar.current.isDateInToday(at) {
                    Button("回到今天") { at = Date(); load() }
                }
                HelpNote("往年的同一天这段对话里说过什么。只列出你与角色都发过消息的日子；可以翻看前后的日期。只在本机查找，不调用接口。", title: "那年今天")
            }
            if years.isEmpty {
                Section { Text("往年的这一天没有对话记录。").foregroundStyle(Theme.text2) }
            }
            ForEach(years) { y in
                Section {
                    let shown = open.contains(y.year) ? y.msgs : Array(y.msgs.prefix(6))
                    ForEach(shown, id: \.id) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Theme.sp2) {
                                Text(m.role == .user ? meName : name(m.authorId)).font(.system(size: 13, weight: .semibold))
                                Text(Self.hm(m.createdAt)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                            }
                            Text(OnThisDay.textOf(m)).font(.system(size: 14))
                        }
                    }
                    if y.msgs.count > 6 {
                        Button(open.contains(y.year) ? "收起" : "展开全部 \(y.msgs.count) 条") {
                            if open.contains(y.year) { open.remove(y.year) } else { open.insert(y.year) }
                        }
                    }
                } header: { Text("\(y.ago) 年前 · \(String(y.year)) 年 · 共 \(y.msgs.count) 条") }
            }
        }
        .navigationTitle("那年今天")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let chat = (try? Repo.chat(chatId)) ?? nil
            let ps = (try? Repo.personas()) ?? []
            meName = (ps.first { $0.id == chat?.personaId } ?? ((try? Repo.activePersona()) ?? nil))?.name ?? "我"
            load()
        }
    }

    private var title: String {
        let c = Calendar.current.dateComponents([.month, .day], from: at)
        return "\(c.month ?? 0) 月 \(c.day ?? 0) 日" + (Calendar.current.isDateInToday(at) ? " · 今天" : "")
    }

    private func step(_ n: Int) {
        at = Calendar.current.date(byAdding: .day, value: n, to: at) ?? at
        open = []
        load()
    }

    private func load() { years = OnThisDay.ofChat(chatId, at: at) }

    private func name(_ id: String) -> String { ((try? Repo.character(id)) ?? nil)?.name ?? "角色" }

    static func hm(_ ms: Double) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date(millis: ms))
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// 互动标识（网页版 BadgeBits）：火花、等级、成长、隐藏成就、节日限定。全部本机按聊天记录算，不调接口
struct BadgesView: View {
    let chatId: String
    @State private var chat: Chat?
    @State private var show = true
    @State private var aware = false
    @State private var remind = true
    @State private var hour = 21
    @State private var loaded = false
    @State private var problem: String?
    @State private var granting = false
    @State private var awardName = ""
    @State private var awardReason = ""

    var body: some View {
        List {
            if let chat { content(chat) }
            Section {
                Toggle("显示标识", isOn: $show)
                Toggle("让角色知道", isOn: $aware)
                Toggle("火花快熄灭时提醒", isOn: $remind)
                if remind {
                    Stepper("提醒时间 \(hour):00", value: $hour, in: 0...23)
                }
                HelpNote("显示标识：在会话顶部的名字后面显示火花与连续互发的天数。让角色知道：连续互发的天数、今天是否已经互发、等级与刚解锁的标识写进提示词，默认关闭。标识全部在本机按聊天记录计算，不调用接口。一天里你与角色都至少发过一条，这一天才算互发。", title: "互动标识")
                Button("重新统计") {
                    do { try Badges.sync(chatId, full: true); reload() } catch { problem = "统计失败：\(error.localizedDescription)" }
                }
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("互动标识")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do { try Badges.sync(chatId) } catch { problem = "统计失败：\(error.localizedDescription)" }
            reload()
            show = Badges.shown(chat)
            aware = Badges.aware(chat)
            remind = Badges.remindOn(chat)
            hour = Badges.remindHour(chat)
            loaded = true
        }
        .onChange(of: show) { _, v in set("badgeShow", v) }
        .onChange(of: aware) { _, v in set("badgeAware", v) }
        .onChange(of: remind) { _, v in set("badgeRemind", v) }
        .onChange(of: hour) { _, v in setValue("badgeRemindHour", .number(Double(v))) }
        .alert("颁发一枚标识", isPresented: $granting) {
            TextField("名字（24 字以内）", text: $awardName)
            TextField("理由（可不填）", text: $awardReason)
            Button("颁发") { grant() }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func content(_ chat: Chat) -> some View {
        let s = Badges.streak(chat)
        let st = chat.row["stats"]?.object ?? [:]
        let unlocked = chat.row["unlocked"]?.object ?? [:]
        Section("火花") {
            row("连续互发", s.n > 0 ? "\(s.n) 天" + (s.form.map { " · \($0.name)" } ?? "") : "尚未开始")
            Text(["lit": "今天已经互发。", "risk": "今天尚未互发，零点之后火花熄灭。",
                  "ember": "火花昨天熄灭。今天由对方先开口并互发，可以接上。", "out": "火花已熄灭。"][s.state] ?? "你与角色在同一天都发过消息，火花就会点燃。")
                .font(.footnote).foregroundStyle(Theme.text2)
            row("最长", "\(s.best) 天")
        }
        let lv = Badges.level(chat)
        Section("等级") {
            row(lv.name, "第 \(lv.level) / \(lv.max) 级")
            ProgressView(value: lv.progress)
            NavigationLink("等级名称") { LevelNamesView(chatId: chatId) }
            NavigationLink("年度回顾") { YearReviewView(chatId: chatId) }
        }
        let aws = Badges.awards(chat)
        Section("颁发") {
            ForEach(aws) { a in
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name)
                    Text([a.by == "me" ? "你颁发" : "\(charName(a.by))颁发", a.reason, BadgeTime.day(a.at)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(Theme.text2)
                }
                .swipeActions {
                    Button("收回", role: .destructive) {
                        do { try Badges.dropAward(chatId, id: a.id); reload() } catch { problem = "未能收回：\(error.localizedDescription)" }
                    }
                }
            }
            if aws.isEmpty { Text("尚无颁发的标识。").foregroundStyle(Theme.text2) }
            Button("颁发一枚") { awardName = ""; awardReason = ""; granting = true }
            HelpNote("颁发的标识记在这段对话里，左滑可以收回。角色在回复中写 [授予：名字｜理由] 时同样记进这里；删掉那一条消息时一并收回。每一枚都计入等级。", title: "颁发标识")
        }
        Section("成长") {
            ForEach(Badges.tiers.filter { !$0.onlyLove || (chat.row.number("loveStartAt") ?? 0) > 0 }, id: \.id) { t in
                let v = Badges.tierValue(t, st, chat: chat, now: Date().millis)
                let next = t.steps.first { v < $0 }
                row(t.name, "\(v) \(t.unit)" + (next.map { " · 下一档 \($0)" } ?? " · 已满"))
            }
        }
        Section("隐藏成就") {
            ForEach(Badges.achievements, id: \.id) { a in
                if unlocked[a.id] != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name)
                        Text(a.desc).font(.footnote).foregroundStyle(Theme.text2)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("尚未解锁").foregroundStyle(Theme.text3)
                        Text(a.hint).font(.footnote).foregroundStyle(Theme.text3)
                    }
                }
            }
        }
        let lim = (chat.row["limited"]?.object ?? [:]).keys.sorted()
        if !lim.isEmpty {
            Section("节日限定") {
                ForEach(lim, id: \.self) { id in Text(Badges.label(id)) }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(Theme.text2) }
    }

    private func reload() { chat = (try? Repo.chat(chatId)) ?? nil }

    private func charName(_ id: String) -> String { ((try? Repo.character(id)) ?? nil)?.name ?? "角色" }

    private func grant() {
        let to = chat?.characterIds.first ?? ""
        do {
            guard try Badges.addAward(chatId, name: awardName, reason: awardReason, by: "me", to: to) != nil else { problem = "请填写名字"; return }
            reload()
        } catch { problem = "未能颁发：\(error.localizedDescription)" }
    }

    private func setValue(_ key: String, _ v: JSONValue) {
        guard loaded, var c = (try? Repo.chat(chatId)) ?? nil else { return }
        c.row[key] = v
        c.row.touch()
        do { try Repo.save(c); reload() } catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    private func set(_ key: String, _ v: Bool) {
        guard loaded, var c = (try? Repo.chat(chatId)) ?? nil else { return }
        c.row[key] = .bool(v)
        c.row.touch()
        do { try Repo.save(c); reload() } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}

/// 每一级叫什么由用户自己填（网页版 chat.levelNames），系统不替人定义关系
struct LevelNamesView: View {
    let chatId: String
    @State private var names: [String] = Array(repeating: "", count: Badges.levels.count)
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                ForEach(names.indices, id: \.self) { i in
                    TextField("第 \(i + 1) 级", text: $names[i])
                }
                HelpNote("等级按连续互发、消息数、通话与一起听的时长、相识天数、解锁与颁发的标识合成，共六级。名称空着时显示「第几级」。", title: "等级名称")
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("等级名称")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let cur = (((try? Repo.chat(chatId)) ?? nil)?.row["levelNames"]?.array ?? []).compactMap(\.string)
            names = (0..<Badges.levels.count).map { $0 < cur.count ? cur[$0] : "" }
        }
        .onDisappear {
            do { try Badges.setLevelNames(chatId, names) } catch { Problems.report("等级名称未能保存：\(error.localizedDescription)") }
        }
    }
}

/// 年度回顾（网页版 yearOf）：全部在本机按聊天记录算，不调接口
struct YearReviewView: View {
    let chatId: String
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var data: Badges.Year?
    @State private var years: [Int] = []

    var body: some View {
        List {
            if years.count > 1 {
                Picker("年份", selection: $year) { ForEach(years, id: \.self) { Text(String($0)).tag($0) } }
            }
            if let d = data {
                Section("这一年") {
                    row("消息", "\(d.n) 条（你 \(d.nU)，对方 \(d.nC)）")
                    row("有消息的日子", "\(d.activeDays) 天")
                    row("互发的日子", "\(d.bothDays) 天")
                    row("最长连续互发", "\(d.bestStreak) 天")
                    if let b = d.busiest { row("聊得最多的一天", "\(BadgeTime.day(b.at)) · \(b.n) 条") }
                    if let l = d.latest { row("最晚的一次", BadgeTime.clock(l)) }
                }
                if !d.words.isEmpty {
                    Section("最常说的词") {
                        ForEach(d.words.indices, id: \.self) { i in row(d.words[i].w, "\(d.words[i].n) 次") }
                    }
                }
                if !d.unlocked.isEmpty || !d.limited.isEmpty || !d.awards.isEmpty {
                    Section("这一年得到的标识") {
                        ForEach(d.unlocked + d.limited, id: \.self) { id in Text(Badges.label(id)) }
                        ForEach(d.awards) { a in Text(a.name) }
                    }
                }
                if d.n == 0 { Text("这一年没有消息。").foregroundStyle(Theme.text2) }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("年度回顾")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: year) { await load() }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(Theme.text2) }
    }

    private func load() async {
        guard let chat = (try? Repo.chat(chatId)) ?? nil else { return }
        let msgs = (try? Repo.messages(chatId: chatId)) ?? []
        if years.isEmpty {
            let cal = Calendar.current
            let ys = Set(msgs.map { cal.component(.year, from: Date(millis: $0.createdAt)) })
            years = ys.isEmpty ? [year] : ys.sorted(by: >)
            if !years.contains(year), let f = years.first { year = f; return }
        }
        data = Badges.yearOf(chat, msgs: msgs, year: year)
    }
}

private enum BadgeTime {
    private static func make(_ fmt: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = fmt
        return f
    }
    private static let ymd = make("yyyy年M月d日"), hm = make("HH:mm")
    static func day(_ t: Double) -> String { t > 0 ? ymd.string(from: Date(millis: t)) : "" }
    /// 哪一天的几点
    static func clock(_ t: Double) -> String { "\(day(t)) \(hm.string(from: Date(millis: t)))" }
}
