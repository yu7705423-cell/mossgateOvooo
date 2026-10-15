import SwiftUI

/// 我的日程（网页版 daily/MinePage.js，4.321）：今天、每周重复的、只在某一天的，加哪些角色读得到。
/// 从文件或截图导入要调接口，原生版暂未提供。
struct UserSchedView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var tick = 0
    @State private var editing: Edit?
    @State private var problem: String?

    struct Edit: Identifiable { let id: String }   // "new" 为新建

    var body: some View {
        let _ = tick
        let owner = UserSched.ownerOf("")
        let all = UserSched.list(owner)
        let now = UserSched.today(model.s, at: Date())
        let todays = UserSched.itemsOn(owner, now.key)
        let weekly = all.filter { $0.repeatMode == UserSched.weekly }
        let once = all.filter { $0.repeatMode == UserSched.once }.sorted { $0.date != $1.date ? $0.date < $1.date : $0.start < $1.start }
        let chars = ((try? Repo.characters()) ?? []).filter { !$0.isNpc && ($0.parentId ?? "").isEmpty && !$0.archived }
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                if todays.isEmpty { Text("今天没有安排").foregroundStyle(Theme.secondaryText) }
                ForEach(todays) { r in
                    let m = UserSched.minutes(now.time)
                    let a = UserSched.minutes(r.start), e = r.end.isEmpty ? a : UserSched.minutes(r.end)
                    row(r, sub: a <= m && m < max(e, a + 1) ? "正在进行" : "")
                }
            } header: { Text("今天 · \(now.key) \(UserSched.weekdays[max(0, UserSched.weekdayOfKey(now.key) - 1)])") }

            ForEach(1...7, id: \.self) { d in
                let rows = weekly.filter { $0.weekday == d }.sorted { UserSched.minutes($0.start) < UserSched.minutes($1.start) }
                if !rows.isEmpty {
                    Section(UserSched.weekdays[d - 1]) { ForEach(rows) { r in row(r, sub: weeksText(r)) } }
                }
            }
            if !once.isEmpty {
                Section("只在某一天") { ForEach(once) { r in row(r, sub: r.date) } }
            }
            Section {
                Button("添加日程") { editing = Edit(id: "new") }
            } footer: {
                HelpNote("日程是一段段占着的时间：课表、排班、通勤、固定的安排。每周重复的可以设起止日期与单双周；单双周按起始日期那一周算第一周，没有起始日期时按一年中的第几周算。日期与时刻按你的时区。从文件或截图导入原生版暂未提供。", title: "我的日程")
            }

            Section {
                Toggle("排角色日程时参考我的日程", isOn: model.bool("dayPlanUserSched", false))
                ForEach(chars) { c in
                    Toggle(c.displayName, isOn: Binding(get: { UserSched.visibleTo(c.id, model.s) },
                                                        set: { v in model.update { UserSched.setVisible(c.id, v, &$0) } }))
                }
            } header: { Text("角色读得到") } footer: {
                HelpNote("打开的角色在对话中读得到你的日程：今天与往前、往后几天各有什么安排，此刻在不在其中。读几天在「设置 - 用量与上限」。不另外调用接口，提示词随日程变长。「排角色日程时参考我的日程」开启后，为角色安排当天日程的那一次请求带上你今天的日程，同样不另外调用接口。", title: "我的日程：角色读得到")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("我的日程")
        .sheet(item: $editing, onDismiss: { tick += 1 }) { e in
            NavigationStack { UserSchedEditView(itemId: e.id == "new" ? nil : e.id) }
        }
        .onAppear { model.reload(); tick += 1 }
    }

    private func weeksText(_ r: UserSched.Item) -> String {
        [r.weeksMode == "odd" ? "单周" : r.weeksMode == "even" ? "双周" : "",
         r.from.isEmpty && r.to.isEmpty ? "" : "\(r.from.isEmpty ? "…" : r.from) 至 \(r.to.isEmpty ? "…" : r.to)"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func row(_ r: UserSched.Item, sub: String) -> some View {
        Button { editing = Edit(id: r.id) } label: {
            HStack(alignment: .top, spacing: Theme.sp3) {
                Text(UserSched.kinds.first { $0.id == r.kind }?.tag ?? "他")
                    .font(.caption2).foregroundStyle(Theme.text2)
                    .frame(width: 20, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).foregroundStyle(Theme.text)
                    Text([r.span, r.kind == "commute" ? [r.via, r.mins > 0 ? "约 \(r.mins) 分钟" : ""].filter { !$0.isEmpty }.joined(separator: " ") : r.place, sub]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .swipeActions {
            Button("删除", role: .destructive) {
                do { try UserSched.remove(r.id); problem = nil } catch { problem = "未能删除：\(error.localizedDescription)" }
                tick += 1
            }
        }
    }
}

/// 添加或改一条日程
struct UserSchedEditView: View {
    let itemId: String?
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "other"
    @State private var repeatMode = UserSched.weekly
    @State private var weekday = 1
    @State private var date = Date()
    @State private var start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var hasEnd = true
    @State private var end = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var title = ""
    @State private var place = ""
    @State private var note = ""
    @State private var weeks = "all"
    @State private var hasFrom = false
    @State private var from = Date()
    @State private var hasTo = false
    @State private var to = Date()
    @State private var origin = ""
    @State private var dest = ""
    @State private var via = ""
    @State private var mins = ""
    @State private var problem: String?
    @State private var loaded = false

    private static let dayF: DateFormatter = { let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static let hmF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Picker("类别", selection: $kind) { ForEach(UserSched.kinds, id: \.id) { Text($0.label).tag($0.id) } }
                if kind == "commute" {
                    TextField("从哪里出发", text: $origin)
                    TextField("到哪里", text: $dest)
                    Picker("交通方式", selection: $via) {
                        Text("未填").tag("")
                        ForEach(UserSched.ways, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("路上大概多少分钟", text: $mins).keyboardType(.numberPad)
                    TextField("名称，可留空", text: $title)
                } else {
                    TextField("名称", text: $title)
                    TextField("地点，可留空", text: $place)
                }
                TextField("备注，可留空", text: $note)
            }
            Section {
                Picker("重复", selection: $repeatMode) {
                    Text("每周").tag(UserSched.weekly)
                    Text("只在某一天").tag(UserSched.once)
                }
                .pickerStyle(.segmented)
                if repeatMode == UserSched.once {
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                } else {
                    Picker("周几", selection: $weekday) { ForEach(1...7, id: \.self) { Text(UserSched.weekdays[$0 - 1]).tag($0) } }
                    Picker("单双周", selection: $weeks) { ForEach(UserSched.weeks, id: \.id) { Text($0.label).tag($0.id) } }
                    Toggle("起始日期", isOn: $hasFrom)
                    if hasFrom { DatePicker("从", selection: $from, displayedComponents: .date) }
                    Toggle("结束日期", isOn: $hasTo)
                    if hasTo { DatePicker("到", selection: $to, displayedComponents: .date) }
                }
                DatePicker("开始", selection: $start, displayedComponents: .hourAndMinute)
                Toggle("结束时刻", isOn: $hasEnd)
                if hasEnd { DatePicker("结束", selection: $end, displayedComponents: .hourAndMinute) }
            } footer: {
                HelpNote("通勤填了路上多久、没填结束时刻时，结束时刻按出发加路上的时间算。结束时刻早于开始时刻时不记结束时刻。", title: "我的日程：编辑")
            }
            if itemId != nil {
                Section {
                    Button("删除这一条", role: .destructive) {
                        do { if let itemId { try UserSched.remove(itemId) }; dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
                    }
                    .foregroundStyle(Theme.dangerText)
                }
            }
        }
        .navigationTitle(itemId == nil ? "添加日程" : "编辑日程")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let itemId, let r = (try? Database.shared.get(UserSched.collection, id: itemId)).flatMap({ $0 }).map(UserSched.Item.init(row:)) else { return }
        kind = r.kind; repeatMode = r.repeatMode; weekday = max(1, r.weekday); weeks = r.weeksMode
        title = r.title; place = r.place; note = r.note
        origin = r.origin; dest = r.dest; via = r.via; mins = r.mins > 0 ? "\(r.mins)" : ""
        if let d = Self.dayF.date(from: r.date) { date = d }
        if let d = Self.dayF.date(from: r.from) { from = d; hasFrom = true }
        if let d = Self.dayF.date(from: r.to) { to = d; hasTo = true }
        if let d = Self.hmF.date(from: r.start) { start = d }
        hasEnd = !r.end.isEmpty
        if let d = Self.hmF.date(from: r.end) { end = d }
    }

    private func save() {
        var raw: [String: JSONValue] = [
            "kind": .string(kind), "repeat": .string(repeatMode), "title": .string(title), "place": .string(place), "note": .string(note),
            "start": .string(Self.hmF.string(from: start)), "end": .string(hasEnd ? Self.hmF.string(from: end) : ""),
        ]
        if repeatMode == UserSched.once {
            raw["date"] = .string(Self.dayF.string(from: date))
        } else {
            raw["weekday"] = .number(Double(weekday))
            raw["weeks"] = .string(weeks)
            raw["from"] = .string(hasFrom ? Self.dayF.string(from: from) : "")
            raw["to"] = .string(hasTo ? Self.dayF.string(from: to) : "")
        }
        if kind == "commute" {
            raw["origin"] = .string(origin); raw["dest"] = .string(dest); raw["via"] = .string(via)
            raw["mins"] = .number(Double(Int(mins) ?? 0))
        }
        do {
            if let itemId { try UserSched.update(itemId, raw) } else { try UserSched.create(UserSched.ownerOf(""), raw) }
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}
