import SwiftUI

/// 健康首页（网页版 health/App.js）：今天的记录（你自己的），下面是历史、经期、用药、角色的身体状态、设置
struct HealthHomeView: View {
    @State private var tick = 0
    @State private var problem: String?

    var body: some View {
        let _ = tick
        Form {
            HealthDayFields(who: Health.me, date: Health.dateKey(), full: true) { tick += 1 }
            let meds = Health.activeMeds()
            if !meds.isEmpty {
                let took = Health.day(Health.me).took
                Section {
                    ForEach(meds) { m in
                        Button {
                            do { try Health.takeMed(m.id); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                            // 记下吃过：今天剩下的那几次提醒撤掉（网页版 4.482）
                            MedRemind.planSoon()
                            tick += 1
                        } label: {
                            HStack {
                                Image(systemName: took.contains(m.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(took.contains(m.id) ? Theme.accent : Theme.text3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.string("name")).foregroundStyle(Theme.text)
                                    let sub = [m.string("dose"), m.strings("times").joined(separator: "、")].filter { !$0.isEmpty }.joined(separator: " · ")
                                    if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(Theme.text3) }
                                }
                            }
                        }
                    }
                } header: { Text("今天要吃的药") } footer: {
                    if let problem { Text(problem).foregroundStyle(Theme.danger) }
                }
            }
            Section {
                NavigationLink { HealthLogView() } label: { Text("历史") }
                NavigationLink { HealthCycleView() } label: {
                    LabeledContent("经期", value: Health.openCycle() != nil ? "进行中" : (Health.predictCycle().map { "预计 \($0.next)" } ?? ""))
                }
                NavigationLink { HealthMedsView() } label: { LabeledContent("用药", value: meds.isEmpty ? "" : "\(meds.count) 种") }
                NavigationLink { HealthCharsView() } label: { Text("角色的身体状态") }
                NavigationLink { HealthSettingsView() } label: {
                    LabeledContent("设置", value: AppSettings.load().raw["healthInject"]?.bool == true ? "角色读得到" : "不进对话")
                }
            }
        }
        .navigationTitle("健康")
        .onAppear { tick += 1 }
        // 用药提醒往后续排；同步成功过的，顺带从「健康」读一次（十分钟内不重读）
        .task {
            await MedRemind.plan()
            if await HealthSync.autoSync() != nil { tick += 1 }
        }
    }
}

/// 一天的那几项。full 为你自己（含步数、体重、喝水）；角色那一份只有状态类的几项
struct HealthDayFields: View {
    let who: String
    let date: String
    var full = false
    var changed: () -> Void = {}
    @State private var tick = 0
    @State private var problem: String?
    @State private var sleepHours = ""
    @State private var steps = ""
    @State private var weight = ""
    @State private var note = ""

    var body: some View {
        let _ = tick
        let d = Health.day(who, date)
        Group {
            Section {
                HStack {
                    Text("睡眠")
                    Spacer()
                    TextField("小时", text: $sleepHours).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                        .onSubmit(saveNumbers)
                    Text("小时").foregroundStyle(Theme.text3)
                }
                if full {
                    HStack {
                        Text("步数")
                        Spacer()
                        TextField("0", text: $steps).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100)
                            .onSubmit(saveNumbers)
                    }
                    HStack {
                        Text("体重")
                        Spacer()
                        TextField("0", text: $weight).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                            .onSubmit(saveNumbers)
                        Text(Health.unit()).foregroundStyle(Theme.text3)
                    }
                    HStack {
                        Text("喝水")
                        Spacer()
                        Button { act { try Health.addWater(who, -1) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        Text("\(Int(d.water)) 杯").monospacedDigit().frame(minWidth: 44)
                        Button { act { try Health.addWater(who, 1) } } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
                    }
                }
            } header: { Text(full ? "今天 · \(date)" : date) }
            Section {
                Picker("心情", selection: Binding(get: { d.mood }, set: { v in act { try Health.set(who, date, ["mood": .string(v)]) } })) {
                    Text("未填").tag("")
                    ForEach(Health.moods, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("精力", selection: Binding(get: { d.energy }, set: { v in act { try Health.set(who, date, ["energy": .string(v)]) } })) {
                    Text("未填").tag("")
                    ForEach(Health.energy, id: \.id) { Text($0.label).tag($0.id) }
                }
                ChipFlow(items: Health.symptoms.map { ($0.id, $0.label) }, selected: Set(d.symptoms)) { id in
                    act { try Health.toggleSymptom(who, date, id) }
                }
            } header: { Text("状态与不适") }
            Section {
                ForEach(Array(d.poops.enumerated()), id: \.offset) { i, e in
                    HStack {
                        TextField("时间", text: Binding(get: { e.at }, set: { v in act { try Health.updatePoop(who, date, i, at: v) } }))
                            .keyboardType(.numbersAndPunctuation).frame(width: 64)
                        Picker("", selection: Binding(get: { e.form }, set: { v in act { try Health.updatePoop(who, date, i, form: v) } })) {
                            Text("形态未填").tag("")
                            ForEach(Health.poopForms, id: \.id) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden()
                        Spacer()
                        Button { act { try Health.removePoop(who, date, i) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(Theme.text3)
                    }
                }
                Button { act { try Health.addPoop(who, date) } } label: { Label("记一次", systemImage: "plus") }
            } header: { Text("排便") }
            Section {
                TextField("另外记一句", text: $note, axis: .vertical).lineLimit(1...4).onSubmit(saveNote)
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            }
        }
        .onAppear(perform: load)
        .onDisappear { saveNumbers(); saveNote() }
    }

    private func load() {
        let d = Health.day(who, date)
        sleepHours = d.sleepMin > 0 ? String(format: "%g", (d.sleepMin / 60 * 10).rounded() / 10) : ""
        steps = d.steps > 0 ? String(Int(d.steps)) : ""
        weight = d.weight > 0 ? String(format: "%g", Health.toDisplay(d.weight)) : ""
        note = d.note
    }

    private func saveNumbers() {
        let d = Health.day(who, date)
        var patch: [String: JSONValue] = [:]
        let sleep = (Double(sleepHours) ?? 0) * 60
        if sleep.rounded() != d.sleepMin.rounded() { patch["sleepMin"] = .number(max(0, sleep.rounded())) }
        if full {
            let st = Double(steps) ?? 0
            if st != d.steps { patch["steps"] = .number(max(0, st)) }
            let w = Double(weight).map { Health.fromDisplay($0) } ?? 0
            if abs(w - d.weight) > 0.001 { patch["weight"] = .number(max(0, w)) }
        }
        guard !patch.isEmpty else { return }
        act { try Health.set(who, date, patch) }
    }

    private func saveNote() {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n != Health.day(who, date).note else { return }
        act { try Health.set(who, date, ["note": .string(n)]) }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
        changed()
    }
}

/// 一排可以点选的小标签
struct ChipFlow: View {
    let items: [(id: String, label: String)]
    let selected: Set<String>
    var toggle: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
            ForEach(items, id: \.id) { it in
                Button { toggle(it.id) } label: {
                    Text(it.label).font(.system(size: 13))
                        .foregroundStyle(selected.contains(it.id) ? Theme.onAccent : Theme.text)
                        .padding(.horizontal, Theme.sp2).padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(selected.contains(it.id) ? Theme.accent : Theme.surface2, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 历史（网页版 LogPage）：记过的那些天，新的在前
struct HealthLogView: View {
    var body: some View {
        let list = Health.recent(Health.me, 90)
        List {
            if list.isEmpty { Text("尚无记录").foregroundStyle(Theme.text3) }
            ForEach(list, id: \.date) { d in
                NavigationLink { Form { HealthDayFields(who: Health.me, date: d.date, full: true) }.navigationTitle(d.date) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.date)
                        let bits = [Health.fmtSleep(d.sleepMin), d.steps > 0 ? "\(Int(d.steps)) 步" : "",
                                    d.weight > 0 ? "\(Health.toDisplay(d.weight)) \(Health.unit())" : "",
                                    d.water > 0 ? "\(Int(d.water)) 杯水" : "", Health.label(Health.moods, d.mood)].filter { !$0.isEmpty }
                        if !bits.isEmpty { Text(bits.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.text3) }
                    }
                }
            }
        }
        .navigationTitle("历史")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 经期（网页版 CyclePage）：开始、结束、平均周期与推算的下一次
struct HealthCycleView: View {
    @State private var tick = 0
    @State private var problem: String?

    var body: some View {
        let _ = tick
        let open = Health.openCycle()
        List {
            Section {
                if let open {
                    LabeledContent("进行中", value: "第 \(Health.daysBetween(open.string("start"), Health.dateKey()) + 1) 天")
                    Button("记录结束（今天）") { act { try Health.endCycle(open.id) } }
                } else {
                    Button("记录开始（今天）") { act { try Health.startCycle() } }
                }
                if let p = Health.predictCycle() {
                    LabeledContent("平均周期", value: "\(p.avg) 天（\(p.samples) 次）")
                    LabeledContent("下一次大约", value: p.next)
                }
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
            } footer: {
                Text("按你自己的记录算出的平均，不是医学判断。")
            }
            Section {
                ForEach(Health.listCycles()) { c in
                    LabeledContent(c.string("start"), value: c.string("end").isEmpty ? "未结束" : "至 \(c.string("end"))")
                        .swipeActions { Button("删除", role: .destructive) { act { try Health.removeCycle(c.id) } } }
                }
            } header: { Text("记录") }
        }
        .navigationTitle("经期")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = error.localizedDescription }
        tick += 1
    }
}

/// 用药（网页版 MedsPage）：只记吃什么、什么时候吃，不给任何用药建议
struct HealthMedsView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var tick = 0
    @State private var editing: MedDraft?
    @State private var problem: String?
    @State private var planState: MedRemind.PlanState?
    @State private var asking = false

    struct MedDraft: Identifiable {
        var id = UUID().uuidString
        var medId: String?
        var name = ""
        var dose = ""
        var times = ""
        var note = ""
        var active = true
    }

    var body: some View {
        let _ = tick
        List {
            Section {
                Toggle("到点提醒", isOn: Binding(get: { MedRemind.on(model.s) }, set: { v in
                    model.set("medRemind", .bool(v))
                    replan()
                }))
                let sys = sysLine
                VStack(alignment: .leading, spacing: 2) {
                    Text(sys.title)
                    if !sys.text.isEmpty { Text(sys.text).font(.footnote).foregroundStyle(Theme.secondaryText) }
                }
                if planState?.permission == true {
                    Button(asking ? "正在询问" : "允许通知") {
                        asking = true
                        Task { await MedRemind.askPermission(); planState = MedRemind.state; asking = false }
                    }
                    .disabled(asking)
                }
            } footer: {
                HelpNote("到设定的时间且当天还没有记下时，由系统发一条本机通知，应用关闭也照常提醒。系统对定时通知有数量上限，所以按每天的次数排几天、最多 14 天，打开应用或回到前台时往后续排。当天已经记下吃过的，当天剩下的不再提醒。不调用任何接口，也不上传。", title: "用药：到点提醒")
            }
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            let list = Health.listMeds()
            if list.isEmpty { Text("尚无").foregroundStyle(Theme.text3) }
            ForEach(list) { m in
                Button {
                    editing = MedDraft(medId: m.id, name: m.string("name"), dose: m.string("dose"),
                                       times: m.strings("times").joined(separator: " "), note: m.string("note"), active: m["active"]?.bool != false)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.string("name")).foregroundStyle(m["active"]?.bool == false ? Theme.text3 : Theme.text)
                        let sub = [m.string("dose"), m.strings("times").joined(separator: "、")].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(Theme.text3) }
                    }
                }
                .swipeActions { Button("删除", role: .destructive) { act { try Health.removeMed(m.id) } } }
            }
        }
        .navigationTitle("用药")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let st = MedRemind.state { planState = st } else { planState = await MedRemind.plan() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { editing = MedDraft() } label: { Image(systemName: "plus") }.accessibilityLabel("添加") }
        }
        .sheet(item: $editing) { d in
            NavigationStack { MedEditor(draft: d) { saved in
                editing = nil
                guard let x = saved else { return }
                let times = x.times.split(whereSeparator: { $0 == " " || $0 == "，" || $0 == "," || $0 == "、" })
                    .map { Health.poopTime(String($0)) }.filter { !$0.isEmpty }
                act { try Health.saveMed(id: x.medId, name: x.name, dose: x.dose, times: times, note: x.note, active: x.active) }
            } }
        }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = error.localizedDescription }
        tick += 1
        replan()
    }

    /// 加改删药、开关变了：重排交给系统的那一组
    private func replan() {
        Task { planState = await MedRemind.plan() }
    }

    /// 现在是哪一种（网页版 MedsPage 的 sysLine）：写清楚排到了哪天、为什么没交给系统
    private var sysLine: (title: String, text: String) {
        if !MedRemind.on(model.s) { return ("系统提醒已关闭", "到点提醒关闭后，已交给系统的提醒一并撤回。") }
        guard let ps = planState else { return ("正在交给系统", "") }
        if ps.ok {
            guard ps.n > 0, let until = ps.until else { return ("已交给系统", "目前没有需要提醒的时间。") }
            let c = Calendar.current.dateComponents([.month, .day], from: until)
            return ("已交给系统", "应用关闭后照常提醒，已排到 \(c.month ?? 0) 月 \(c.day ?? 0) 日。每次打开应用会自动往后续排，最多排 \(MedRemind.days) 天。")
        }
        if ps.permission { return ("未允许通知", "允许通知后，到点提醒交给系统发出，应用关闭也照常提醒。未允许时不提醒。") }
        return ("未能交给系统", ps.error.isEmpty ? "原因未知。" : ps.error)
    }

    struct MedEditor: View {
        @State var draft: MedDraft
        var done: (MedDraft?) -> Void

        var body: some View {
            Form {
                TextField("名称", text: $draft.name)
                TextField("用量（可不填）", text: $draft.dose)
                TextField("时间，例如 08:00 20:00", text: $draft.times).keyboardType(.numbersAndPunctuation)
                TextField("备注", text: $draft.note, axis: .vertical).lineLimit(1...4)
                Toggle("启用", isOn: $draft.active)
            }
            .navigationTitle(draft.medId == nil ? "添加" : "编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { done(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { done(draft) }.disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// 角色的身体状态（网页版 CharPage）：设定出来的，不是测出来的。开着时角色知道自己今天累不累、哪儿不舒服
struct HealthCharsView: View {
    var body: some View {
        let chars = ((try? Repo.characters()) ?? []).filter { !$0.isNpc && $0.parentId == nil && !$0.archived }
        List {
            ForEach(chars) { c in
                NavigationLink { HealthCharView(charId: c.id) } label: {
                    HStack(spacing: Theme.gap) {
                        Avatar(imageId: c.avatar, name: c.name, size: 32)
                        Text(c.displayName)
                        Spacer()
                        if Health.charOn(c) { Text(Health.statusText(c).isEmpty ? "开启" : Health.statusText(c)).font(.caption).foregroundStyle(Theme.text3) }
                    }
                }
            }
        }
        .navigationTitle("角色的身体状态")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HealthCharView: View {
    let charId: String
    @State private var tick = 0

    var body: some View {
        let _ = tick
        Form {
            Section {
                Toggle("记录这个角色的身体状态", isOn: Binding(get: { Health.charOn(try? Repo.character(charId)) },
                                                     set: { v in try? Health.setCharOn(charId, v); tick += 1 }))
            } footer: {
                HelpNote("开启后，下面填的今天的状态写进与该角色的对话，角色按这个来。这些是替角色设定的，不是测出来的。每天自动生成原生版暂未提供，可以手填。", title: "角色的身体状态")
            }
            if Health.charOn(try? Repo.character(charId)) {
                HealthDayFields(who: charId, date: Health.dateKey()) { tick += 1 }
            }
        }
        .navigationTitle((try? Repo.character(charId))?.displayName ?? "角色")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 健康的设置（网页版 SettingsPage）：体重单位、写进对话的三道开关
struct HealthSettingsView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var syncing = false
    @State private var hkNote = ""
    @State private var hkFailed = false

    var body: some View {
        Form {
            Picker("体重单位", selection: Binding(get: { Health.unit(model.s) }, set: { model.set("weightUnit", .string($0)) })) {
                Text("公斤").tag("kg")
                Text("磅").tag("lb")
            }
            Section {
                Button(syncing ? "正在同步" : "从「健康」app 同步") { syncHK() }.disabled(syncing)
                if !hkNote.isEmpty { Text(hkNote).font(.footnote).foregroundStyle(hkFailed ? Theme.danger : Theme.secondaryText) }
                Toggle("打开 Eira 时自动同步", isOn: model.bool("healthAutoSync", true))
                Text(autoLine).font(.footnote).foregroundStyle(Theme.secondaryText)
            } header: {
                Text("系统健康数据")
            } footer: {
                HelpNote("读取最近 30 天的睡眠、步数、体重、饮水与经期，写进每日记录；心情、不适、排便、备注与用药是手记的，同步不会改动。首次同步会弹出系统授权，给哪几项由你在那张表上决定。手动同步成功一次之后，打开 Eira 或从后台回到前台时自动读取上次同步以来的数据，十分钟内不重复读取，只读不再询问授权。只读本机，不调用接口，不向「健康」写入任何数据。", title: "健康：从「健康」app 同步")
            }
            Section {
                Toggle("我的记录写进对话", isOn: model.bool("healthInject", false))
                if model.s.raw["healthInject"]?.bool == true {
                    Toggle("包括排便", isOn: model.bool("healthPoopInject", false))
                    Toggle("包括经期", isOn: model.bool("healthCycleInject", false))
                }
            } footer: {
                Text("这些是身体数据，默认不交给角色。")
                HelpNote("开启后，当天的睡眠、步数、体重、喝水、心情、精力与不适写进每一次对话，只写数字与记下的事实。排便与经期各有单独的开关。不多调用接口。", title: "我的记录写进对话")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 自动同步那一行：现在开没开、上一次怎样（网页版 4.484 的 autoLine）
    private var autoLine: String {
        let base = "只读本机，不调用接口。"
        if !HealthSync.autoOn(model.s) { return base + "已关闭，只在点上面一行时同步。" }
        guard let last = HealthSync.last(model.s) else {
            return base + (HealthSync.everSynced(model.s) ? "打开应用时自动同步。" : "手动同步成功一次之后生效。")
        }
        let at = Date(millis: last["at"]?.number ?? 0)
        let f = DateFormatter()
        f.dateFormat = "M 月 d 日 HH:mm"
        if last["ok"]?.bool == true {
            return base + "上次同步：\(f.string(from: at))" + (last["auto"]?.bool == true ? "（自动）" : "") + "，写入 \(Int(last["days"]?.number ?? 0)) 天。"
        }
        let err = last["error"]?.string ?? ""
        return base + "上次同步失败（\(f.string(from: at))）：\(err.isEmpty ? "原因未知" : err)"
    }

    /// 手动同步：第一次弹系统授权表。拿不到时把系统给的原话写出来（多半是签名没带 HealthKit 权限）
    private func syncHK() {
        syncing = true
        hkNote = ""
        Task {
            do {
                let got = try await HealthSync.syncNow(days: 30)
                hkFailed = false
                hkNote = got.days > 0 || got.cycles > 0
                    ? "已写入 \(got.days) 天" + (got.cycles > 0 ? "，经期 \(got.cycles) 次" : "")
                    : "读到的数据是空的。请在「健康」app 的「共享」中确认已允许本应用读取。"
            } catch {
                hkFailed = true
                hkNote = error.localizedDescription
            }
            syncing = false
        }
    }
}
