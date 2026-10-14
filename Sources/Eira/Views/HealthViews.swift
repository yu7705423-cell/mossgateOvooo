import SwiftUI

/// 健康首页（网页版 health/App.js）：今天的记录（你自己的），下面是历史、经期、用药、角色的身体状态、设置
struct HealthHomeView: View {
    @State private var tick = 0

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
                            try? Health.takeMed(m.id)
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
                } header: { Text("今天要吃的药") }
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
    @State private var tick = 0
    @State private var editing: MedDraft?
    @State private var problem: String?

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

    var body: some View {
        Form {
            Picker("体重单位", selection: Binding(get: { Health.unit(model.s) }, set: { model.set("weightUnit", .string($0)) })) {
                Text("公斤").tag("kg")
                Text("磅").tag("lb")
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
}
