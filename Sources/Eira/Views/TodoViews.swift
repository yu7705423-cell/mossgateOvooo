import SwiftUI

/// 待办（网页版 apps/todo，新版的样子 4.526）：等待确认、有日期、随时，已完成收在最后。
/// 进来的路三条：对话中本地识别、角色在回复里写 [待办：…]、在这一页添加。前两条先落成等待确认，计入之后才算（4.104d）。
struct TodoHomeView: View {
    @State private var tick = 0
    @State private var editing: TodoEdit?
    @State private var adding = false
    @State private var newText = ""
    @State private var showDone = false
    @State private var problem: String?
    @State private var page: SubPage?

    var body: some View {
        let _ = tick
        let ask = Todo.pendingAll()
        let open = Todo.openOnes()
        let done = Todo.doneOnes()
        let withDate = open.filter(TodoText.dated), loose = open.filter { !TodoText.dated($0) }
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if !ask.isEmpty {
                Section {
                    ForEach(ask) { r in
                        HStack(alignment: .top, spacing: Theme.sp3) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.text).foregroundStyle(Theme.text)
                                Text([Todo.fromLabel(r.from), TodoText.charName(r)].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Button("计入") { act { try Todo.accept(r.id) } }.buttonStyle(.borderless)
                            Button("忽略") { act { try Todo.ignore(r.id) } }.buttonStyle(.borderless).foregroundStyle(Theme.text3)
                        }
                    }
                } header: { Text("等待确认 \(ask.count) 条") } footer: {
                    HelpNote("对话中识别到的与角色提出的均先列在此处，计入之后才成为待办。忽略的条目不再重复提示，可在识别设置中清除。", title: "等待确认")
                }
            }
            if !withDate.isEmpty {
                Section("有日期") { ForEach(withDate) { r in TodoRow(row: r, open: { editing = TodoEdit(id: r.id) }, changed: refresh) } }
            }
            if !loose.isEmpty {
                Section("随时") { ForEach(loose) { r in TodoRow(row: r, open: { editing = TodoEdit(id: r.id) }, changed: refresh) } }
            }
            if open.isEmpty {
                Section {
                    VStack(spacing: Theme.sp3) {
                        EmptyState(title: "没有未完成的待办")
                        Button("添加待办") { adding = true }.buttonStyle(.bordered)
                    }
                    .padding(.vertical, Theme.sp4)
                    .listRowBackground(Color.clear)
                }
            }
            if !done.isEmpty {
                Section {
                    DisclosureGroup("已完成 \(done.count)", isExpanded: $showDone) {
                        ForEach(done) { r in TodoRow(row: r, open: { editing = TodoEdit(id: r.id) }, changed: refresh) }
                    }
                }
            }
        }
        .navigationTitle("待办")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newText = ""; adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加待办")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { page = .notes } label: { Label("备忘", systemImage: "note.text") }
                    Button { page = .alarm } label: { Label("系统提醒", systemImage: "bell") }
                    Button { page = .detect } label: { Label("识别设置", systemImage: "gearshape") }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("更多")
            }
        }
        .alert("添加待办", isPresented: $adding) {
            TextField("要做的事", text: $newText)
            Button("添加") {
                do {
                    if let row = try Todo.addMine(newText) { editing = TodoEdit(id: row.id) }
                    problem = nil
                } catch { problem = "未能保存：\(error.localizedDescription)" }
                refresh()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $editing, onDismiss: refresh) { e in NavigationStack { TodoEditView(todoId: e.id) } }
        .navigationDestination(item: $page) { p in
            switch p {
            case .notes: NotesListView()
            case .alarm: TodoAlarmView()
            case .detect: TodoDetectView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .eiraTodosChanged)) { _ in tick += 1 }
        .onAppear(perform: refresh)
    }

    enum SubPage: Hashable { case notes, alarm, detect }

    private func refresh() { tick += 1 }

    private func act(_ job: () throws -> Void) {
        do { try job(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        refresh()
    }
}

struct TodoEdit: Identifiable { let id: String }

/// 列表上的字（网页版 App.js 的 remindNew、md、dated）
enum TodoText {
    static func md(_ key: String) -> String {
        let p = key.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? "\(p[1])月\(p[2])日" : key
    }

    static func mdhm(_ ms: Double) -> String {
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: Date(millis: ms))
        return "\(c.month ?? 0)月\(c.day ?? 0)日 " + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func full(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: Date(millis: ms))
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// 这条上的时刻怎么说：排进系统的和只在应用开着时提醒的分得清
    static func remind(_ r: Todo.Item) -> String {
        let ms = TodoAlarm.timeOf(r)
        guard ms > 0 else { return "" }
        if !r.alarmId.isEmpty { return "\(mdhm(ms)) 系统提醒" }
        return TodoAlarm.isFuture(ms) ? "\(mdhm(ms)) 提醒" : "\(mdhm(ms)) 已过"
    }

    static func dated(_ r: Todo.Item) -> Bool { r.isRepeat || !r.dueAt.isEmpty || !r.time.isEmpty || TodoAlarm.timeOf(r) > 0 }

    static func charName(_ r: Todo.Item) -> String {
        guard !r.charId.isEmpty else { return "" }
        return ((try? Repo.character(r.charId)) ?? nil)?.name ?? "已删除的角色"
    }

    static func meta(_ r: Todo.Item, today: String) -> String {
        let rep = r.isRepeat
        let done = rep ? Todo.doneOn(r, today) : r.state == Todo.done
        // 自己添加的不写来源，别处来的才写
        let fl = Todo.fromLabel(r.from)
        let from = fl == Todo.fromLabel(Todo.fromMe) ? "" : fl
        return [Todo.repeatText(r), r.dueAt.isEmpty ? "" : md(r.dueAt), r.time, remind(r), from, charName(r),
                done && !rep && r.doneAt > 0 ? "完成于 \(md(Todo.keyOf(ms: r.doneAt)))" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// 一行：左边可以直接点掉的圆圈，右边点进去改。每周重复的打勾只算今天（4.326）
struct TodoRow: View {
    let row: Todo.Item
    var open: () -> Void
    var changed: () -> Void

    var body: some View {
        let today = Todo.todayKey()
        let done = row.isRepeat ? Todo.doneOn(row, today) : row.state == Todo.done
        let meta = TodoText.meta(row, today: today)
        HStack(alignment: .top, spacing: Theme.sp3) {
            Button {
                do {
                    if row.isRepeat { try Todo.toggleOn(row.id, today) } else { try Todo.setState(row.id, done ? Todo.open : Todo.done) }
                } catch { Problems.report("待办未能保存：\(error.localizedDescription)") }
                changed()
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(done ? Theme.text2 : Theme.text3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(done ? "标为未完成" : "标为已完成")
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.text).foregroundStyle(done ? Theme.text3 : Theme.text)
                        .strikethrough(done && !row.isRepeat)
                    if !meta.isEmpty { Text(meta).font(.footnote).foregroundStyle(Theme.secondaryText) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 每周哪几天重复。一天都不选就是不重复
struct TodoRepeatDays: View {
    let value: [Int]
    var onChange: ([Int]) -> Void
    private static let names = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        HStack(spacing: Theme.sp2) {
            ForEach(1...7, id: \.self) { d in
                let on = value.contains(d)
                Button {
                    var n = Set(value)
                    if on { n.remove(d) } else { n.insert(d) }
                    onChange(n.sorted())
                } label: {
                    Text(Self.names[d - 1]).font(.system(size: 14))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(on ? Theme.background : Theme.text)
                        .background(Circle().fill(on ? Theme.text : Color.clear))
                        .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("周\(Self.names[d - 1])")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// 编辑一条待办：内容、每周重复、日期、时刻、提醒时刻与系统提醒、完成、来源、删除
struct TodoEditView: View {
    let todoId: String
    @Environment(\.dismiss) private var dismiss
    @State private var tick = 0
    @State private var text = ""
    @State private var whenText = ""
    @State private var loaded = false
    @State private var busy = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var confirmDelete = false

    private static let dayF: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let hmF: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        let _ = tick
        if let row = Todo.get(todoId) {
            form(row)
        } else {
            EmptyState(title: "该条待办已被删除").navigationTitle("编辑待办")
        }
    }

    private func form(_ row: Todo.Item) -> some View {
        let ms = TodoAlarm.timeOf(row)
        let read = When.parse(whenText)
        let at = read?.hasTime == true ? read!.at : 0
        let changed = TodoAlarm.stale(row)
        return Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let notice { Text(notice).foregroundStyle(Theme.text2) }
            Section("内容") {
                TextField("要做的事", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .onChange(of: text) { _, v in if loaded { patch(["text": .string(v)]) } }
            }
            Section {
                TodoRepeatDays(value: row.isRepeat ? row.weekdays : []) { v in
                    patch(v.isEmpty ? ["repeat": .string(""), "weekdays": .array([])]
                          : ["repeat": .string(Todo.weekly), "weekdays": .array(v.map { .number(Double($0)) }),
                             "from": .string(row.from.isEmpty ? Todo.todayKey() : row.from)])
                }
            } header: { Text("每周重复") } footer: {
                HelpNote("选择每周哪几天重复，不选表示不重复。重复的待办每一天分别完成，完成一次不影响下一次。", title: "每周重复")
            }
            if !row.isRepeat {
                Section {
                    Toggle("限定日期", isOn: Binding(get: { !row.dueAt.isEmpty },
                                                     set: { patch(["dueAt": .string($0 ? Self.dayF.string(from: Date()) : "")]) }))
                    if !row.dueAt.isEmpty {
                        DatePicker("日期", selection: Binding(get: { Self.dayF.date(from: row.dueAt) ?? Date() },
                                                             set: { patch(["dueAt": .string(Self.dayF.string(from: $0))]) }),
                                   displayedComponents: .date)
                    }
                } footer: { Text("不限定日期时，列在「随时」中。") }
            }
            Section {
                Toggle("时刻", isOn: Binding(get: { !row.time.isEmpty },
                                             set: { patch(["time": .string($0 ? "09:00" : "")]) }))
                if !row.time.isEmpty {
                    DatePicker("几点", selection: Binding(get: { Self.hmF.date(from: row.time) ?? Date() },
                                                         set: { patch(["time": .string(Self.hmF.string(from: $0))]) }),
                               displayedComponents: .hourAndMinute)
                }
            } footer: {
                HelpNote("可不填。填写后在「日常 - 我的日程」中按时间显示，不填则列在当天最上方。与下方的提醒时刻无关。", title: "时刻")
            }
            Section {
                TextField("明天七点", text: $whenText)
                    .onChange(of: whenText) { _, v in apply(v) }
                Text(whenText.trimmingCharacters(in: .whitespaces).isEmpty ? "留空表示不提醒。"
                     : at > 0 ? "识别为 \(When.show(at))"
                     : read != nil ? "只识别出日期，没有识别出时刻。补上「七点」一类的说法才能提醒。" : "没有识别出时间。")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
                if ms > 0 {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(changed ? "时刻已改，尚未重新排入" : !row.alarmId.isEmpty ? (TodoAlarm.isKitId(row.alarmId) ? "已排入系统闹钟" : "已排入系统提醒") : "尚未排入系统提醒")
                            Text(changed ? "系统中仍是 \(TodoText.full(row.alarmAt))。点击右侧重新排入。"
                                 : !row.alarmId.isEmpty ? "将于 \(TodoText.full(ms)) \(TodoAlarm.isKitId(row.alarmId) ? "响铃" : "通知")，关闭本应用后仍然有效。"
                                 : TodoAlarm.isFuture(ms) ? "将于 \(TodoText.full(ms)) 在本应用内提醒，关闭本应用后不再提醒。" : "该时刻已经过去。")
                                .font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        if !busy {
                            Button(changed ? "重新排入" : !row.alarmId.isEmpty ? "撤销" : "排入") { put(row, changed: changed) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            } header: { Text("提醒时刻") } footer: {
                HelpNote("可直接填写「明天七点」「后天下午三点半」「周四上午十点」一类的说法，也可填写具体日期与时刻。按当前的真实时间折算，与对话中设定的时间无关。排入系统提醒后，关闭本应用仍会在该时刻弹出通知；系统提醒不穿透静音与专注模式。", title: "提醒时刻")
            }
            Section {
                Toggle("已完成", isOn: Binding(get: { row.state == Todo.done },
                                              set: { v in run { try Todo.setState(todoId, v ? Todo.done : Todo.open) } }))
            } footer: {
                Text("来源：\(Todo.fromLabel(row.from))" + (TodoText.charName(row).isEmpty ? "" : " · \(TodoText.charName(row))"))
            }
            Section {
                Button("删除", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText)
            }
        }
        .navigationTitle("编辑待办")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .confirmationDialog("删除这条待办", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Todo.remove(todoId); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("删除后不可恢复。") }
        .onAppear {
            guard !loaded else { return }
            text = row.text
            whenText = !row.whenText.isEmpty ? row.whenText : (ms > 0 ? When.show(ms) : "")
            // 等两个输入框换完再开始写，免得把读出来的值又写一遍
            DispatchQueue.main.async { loaded = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .eiraTodosChanged)) { _ in tick += 1 }
    }

    private func patch(_ p: [String: JSONValue]) {
        run { try Todo.update(todoId, p) }
    }

    private func run<T>(_ job: () throws -> T) {
        do { _ = try job(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }

    /// 只写本地，不碰系统提醒（网页版 4.104g：每按一个键排一次会撞在同一个编号上）。排进系统由那个按钮来
    private func apply(_ v: String) {
        guard loaded else { return }
        let got = When.parse(v)
        patch(["remindAt": .number(got?.hasTime == true ? got!.at : 0), "rungAt": .number(0), "whenText": .string(v)])
    }

    private func put(_ row: Todo.Item, changed: Bool) {
        busy = true
        Task { @MainActor in
            if !row.alarmId.isEmpty && !changed {
                TodoAlarm.cancelLocal(row.id)
                notice = "已撤销系统提醒"
            } else {
                let r = await TodoAlarm.reschedule(row.id, at: TodoAlarm.timeOf(row))
                notice = TodoAlarm.describe(r, at: TodoAlarm.timeOf(row))
            }
            busy = false
            tick += 1
        }
    }
}

/// 识别设置：本地识别的开关、线索词、排除词；角色识别的说明；已忽略的清除
struct TodoDetectView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var cues = ""
    @State private var skips = ""
    @State private var loaded = false
    @State private var tick = 0
    @State private var notice: String?
    @State private var confirmClear = false

    var body: some View {
        let _ = tick
        let dropped = Todo.listOfState(Todo.drop)
        Form {
            if let notice { Text(notice).foregroundStyle(Theme.text2) }
            Section {
                Text("两处各看一遍。本地识别比对下方的线索词，不调用接口；角色识别由角色在回复中给出，随回复一并返回，同样不额外调用接口。两者均先列为等待确认，确认后才成为待办。")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            Section("本地识别") {
                Toggle("在对话中识别待办", isOn: model.bool("todoDetect", true))
            }
            Section {
                TextEditor(text: $cues).frame(minHeight: 120)
                    .onChange(of: cues) { _, v in if loaded { model.set("todoCues", .array(lines(v))) } }
            } header: { Text("线索词") } footer: {
                Text("消息中出现其中一条即列为等待确认，全部删除即等同于关闭本地识别。")
                HelpNote("每行一条。", title: "线索词")
            }
            Section {
                TextEditor(text: $skips).frame(minHeight: 100)
                    .onChange(of: skips) { _, v in if loaded { model.set("todoSkips", .array(lines(v))) } }
            } header: { Text("排除词") } footer: {
                HelpNote("线索词后紧接这些内容时不计入。例如「我想你」含有线索词「我想」，但并非待办。", title: "排除词")
            }
            Section {
                Button("恢复默认的线索词与排除词") {
                    model.update { $0.raw["todoCues"] = .null; $0.raw["todoSkips"] = .null }
                    loaded = false
                    load()
                    notice = "已恢复默认"
                }
            }
            Section("角色识别") {
                Text("开启后角色可在回复中提出待办，随回复一并返回，不额外调用接口。开关在「设定集 - 能力开关」的「记下待办」中，对所有角色生效。")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            if !dropped.isEmpty {
                Section("已忽略 \(dropped.count) 条") {
                    Button("清除已忽略的条目") { confirmClear = true }
                    Text("已忽略的条目保留下来是为了不再重复提示。清除之后，同样的内容会重新提示。").font(.footnote).foregroundStyle(Theme.text2)
                }
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("识别设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清除已忽略的条目", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除") {
                do { notice = "已清除 \(try Todo.clearDropped()) 条" } catch { notice = "未能清除：\(error.localizedDescription)" }
                tick += 1
            }
            Button("取消", role: .cancel) {}
        } message: { Text("共 \(dropped.count) 条。") }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        model.reload()
        cues = Todo.cues(model.s).joined(separator: "\n")
        skips = Todo.skips(model.s).joined(separator: "\n")
        // 等两个输入框换完再开始写，免得把读出来的值又写一遍
        DispatchQueue.main.async { loaded = true }
    }

    private func lines(_ v: String) -> [JSONValue] {
        v.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { .string($0) }
    }
}

/// 系统提醒：对账。本应用以为排了几个，系统那边实际挂着几个（网页版「系统闹钟」那一页）
struct TodoAlarmView: View {
    @State private var status: TodoAlarm.Status?
    @State private var channel: String?
    @State private var ids: [String]?
    @State private var tick = 0
    @State private var confirmAll = false
    @State private var notice: String?

    var body: some View {
        let _ = tick
        let mine = Todo.all().filter { !$0.alarmId.isEmpty }
        let pairs = TodoAlarm.reconcile(ids)
        let next = TodoAlarm.upcoming()
        List {
            if let notice { Text(notice).foregroundStyle(Theme.text2) }
            Section {
                LabeledContent("提醒方式", value: channel ?? "正在读取")
                if SystemAlarm.kit == nil { Text(SystemAlarm.kitWhy + "，当前使用系统通知。").font(.footnote).foregroundStyle(Theme.secondaryText) }
                HStack {
                    Text(channel == "系统闹钟" ? "闹钟权限" : "通知权限")
                    Spacer()
                    Text(statusText).foregroundStyle(Theme.secondaryText)
                }
                if let status, status != .granted {
                    Button("请求授权") { Task { @MainActor in _ = await TodoAlarm.request(); await refresh() } }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("两边对账")
                    Text(Self.tally(mine.count, ids))
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            } header: { Text("当前状态") } footer: {
                HelpNote("iOS 26 起使用系统闹钟：与「时钟」中的闹钟相同，在设定的时刻响铃，穿透静音与专注模式，关闭本应用后仍然有效。系统闹钟不可用或闹钟权限被拒绝时，改用系统通知：到点弹出通知，关闭本应用后仍然有效，不穿透静音与专注模式。未排入系统的待办仅在本应用运行时到点提醒。", title: "系统提醒")
            }
            if !mine.isEmpty {
                Section {
                    Button("撤销全部系统提醒", role: .destructive) { confirmAll = true }.foregroundStyle(Theme.dangerText)
                } footer: {
                    HelpNote("两边对不上时，可先全部撤销再逐条重新排入。", title: "撤销全部系统提醒")
                }
            }
            if !pairs.isEmpty {
                Section("逐条对账 \(pairs.count) 条") {
                    ForEach(pairs) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.text)
                            Text(When.show(p.at) + " · " + (ids == nil ? "系统一侧的登记情况尚未读取" : p.known ? "系统中已登记" : "系统中没有这一条。可撤销后重新排入"))
                                .font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
            Section {
                if next.isEmpty {
                    EmptyState(title: "没有即将到时的待办", desc: "在待办的编辑页中填写提醒时刻后，此处会列出。").listRowBackground(Color.clear)
                }
                ForEach(next) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.text)
                        Text(TodoText.remind(r)).font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                }
            } header: { Text(next.isEmpty ? "即将到时" : "即将到时 \(next.count) 条") }
        }
        .navigationTitle("系统提醒")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("刷新") { Task { @MainActor in await refresh() } } } }
        .confirmationDialog("撤销全部系统提醒", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("撤销", role: .destructive) {
                notice = "已撤销 \(TodoAlarm.cancelAll()) 个"
                Task { @MainActor in await refresh() }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("将撤销 \(mine.count) 个系统提醒。待办本身与其上的时刻保留，可逐条重新排入。") }
        .task { await refresh() }
    }

    static func tally(_ mine: Int, _ ids: [String]?) -> String {
        guard let ids else { return "本应用记录已排入 \(mine) 个。" }
        let same = ids.count == mine ? "两边一致。" : "两边不一致，可逐条撤销后重新排入。"
        return "本应用记录已排入 \(mine) 个，系统中实际挂着 \(ids.count) 个。" + same
    }

    private var statusText: String {
        switch status {
        case .granted: return "已授权"
        case .denied: return "已拒绝。可在系统设置中重新开启"
        case .notDetermined: return "尚未询问"
        case .unsupported: return "当前环境不支持"
        case nil: return "正在读取"
        }
    }

    @MainActor private func refresh() async {
        status = await TodoAlarm.status()
        channel = await TodoAlarm.channelName()
        ids = await TodoAlarm.listNative()
        tick += 1
    }
}

// MARK: - 备忘

/// 备忘（网页版 NotePage，4.104h）：要留着的字。和角色手机里的备忘录无关
struct NotesListView: View {
    @State private var q = ""
    @State private var tick = 0
    @State private var opened: TodoEdit?
    @State private var problem: String?

    var body: some View {
        let _ = tick
        let list = Notes.search(q)
        let total = (try? Database.shared.count(Notes.collection)) ?? 0
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if list.isEmpty {
                VStack(spacing: Theme.sp3) {
                    EmptyState(title: q.isEmpty ? "暂无备忘" : "没有匹配的备忘",
                               desc: q.isEmpty ? "可在此处新建，或在对话中长按消息选择「存备忘」。" : "换一个词再试。")
                    if q.isEmpty { Button("新建备忘", action: add).buttonStyle(.bordered) }
                }
                .padding(.vertical, Theme.sp4)
                .listRowBackground(Color.clear)
            }
            ForEach(list, id: \.id) { r in
                Button { opened = TodoEdit(id: r.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Notes.titleOf(r)).foregroundStyle(Theme.text)
                        Text([Notes.restOf(r), Notes.fromLabel(r.string("from")), Todo.keyOf(ms: r.number("updatedAt") ?? 0)]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(2)
                    }
                }
            }
        }
        .modifier(NotesSearch(on: total > 0, q: $q))
        .navigationTitle("备忘")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("新建", action: add) } }
        .navigationDestination(item: $opened) { e in NoteEditView(noteId: e.id) }
        .onAppear { tick += 1 }
    }

    private func add() {
        do { opened = TodoEdit(id: try Notes.add("").id); problem = nil }
        catch { problem = "未能新建：\(error.localizedDescription)" }
    }
}

extension TodoEdit: Hashable {}

private struct NotesSearch: ViewModifier {
    let on: Bool
    @Binding var q: String
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.searchable(text: $q, prompt: "搜索备忘") } else { content }
    }
}

struct NoteEditView: View {
    let noteId: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @State private var problem: String?
    @State private var confirmDelete = false

    var body: some View {
        if let row = Notes.get(noteId) {
            Form {
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
                Section {
                    TextEditor(text: $text).frame(minHeight: 260)
                        .onChange(of: text) { _, v in
                            guard loaded else { return }
                            do { try Notes.update(noteId, text: v); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                        }
                } footer: {
                    Text("\(Notes.fromLabel(row.string("from"))) · 更新于 \(Todo.keyOf(ms: row.number("updatedAt") ?? 0))")
                }
                Section {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ShareLink(item: text) { Label("存到系统备忘录", systemImage: "square.and.arrow.up") }
                    }
                } footer: {
                    Text("通过系统分享面板送出，在面板中选择「备忘录」即存入该应用。系统未开放直接写入的接口，因此需要在面板中选择一次。")
                }
                Section {
                    Button("删除", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText)
                }
            }
            .navigationTitle("备忘")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("删除这条备忘", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    do { try Notes.remove(noteId); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
                }
                Button("取消", role: .cancel) {}
            }
            .onAppear {
                guard !loaded else { return }
                text = row.string("text")
                DispatchQueue.main.async { loaded = true }
            }
        } else {
            EmptyState(title: "该条备忘已被删除").navigationTitle("备忘")
        }
    }
}

// MARK: - 会话里的确认栏

/// 输入栏上方那一条（网页版 Conversation 的 todo-bar）：这段对话里最早一条等待确认的待办，计入或忽略。
/// 那句话里说了时刻的，计入这一下把系统提醒一并排上（4.104g）
struct TodoAskBar: View {
    let chatId: String
    @State private var tick = 0
    @State private var notice: String?

    var body: some View {
        let _ = tick
        Group {
            if let ask = Todo.pendingOf(chatId).first {
                HStack(spacing: Theme.sp3) {
                    let ms = TodoAlarm.timeOf(ask)
                    Text(ms > 0 ? When.show(ms) : Todo.fromLabel(ask.from))
                        .font(.system(size: 11)).foregroundStyle(Theme.text2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
                    Text(ask.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                    Spacer()
                    Button("计入") { take(ask) }.font(.system(size: 13))
                    Button("忽略") {
                        do { try Todo.ignore(ask.id) } catch { Problems.report("待办未能保存：\(error.localizedDescription)") }
                        tick += 1
                    }
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.sp4).padding(.top, Theme.sp2)
            } else if let notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.sp4).padding(.top, Theme.sp2)
                    .task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        self.notice = nil
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .eiraTodosChanged)) { _ in tick += 1 }
    }

    private func take(_ ask: Todo.Item) {
        do { try Todo.accept(ask.id) } catch { Problems.report("待办未能保存：\(error.localizedDescription)"); return }
        let at = TodoAlarm.timeOf(ask)
        guard TodoAlarm.isFuture(at) else { notice = "已计入待办"; tick += 1; return }
        Task { @MainActor in
            let r = await TodoAlarm.schedule(ask.id)
            notice = r == .alarmed ? "已计入待办，\(When.show(at)) 响铃" : r == .scheduled ? "已计入待办，\(When.show(at)) 通知" : "已计入待办，\(When.show(at)) 在本应用内提醒"
            tick += 1
        }
    }
}
