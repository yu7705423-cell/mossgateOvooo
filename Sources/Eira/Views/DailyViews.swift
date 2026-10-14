import SwiftUI

/// 日常首页：今天每个角色在做什么，以及吃什么、事件库。
struct DailyHomeView: View {
    @State private var chars: [Character] = []
    @State private var eventCount = 0
    @State private var hero = true

    var body: some View {
        List {
            HeroHeader(eyebrow: Theme.todayLine(), title: "日常", shown: $hero)
            // 新版日常（.dyn-cards）：每个角色一张浅灰卡，名字与时段一行，正在做的事用宋体
            Section {
                if chars.isEmpty {
                    EmptyState(title: "还没有角色", desc: "在「联系」中创建角色后，这里会显示每个角色的今天。")
                        .listRowBackground(Color.clear)
                }
                ForEach(chars) { c in
                    NavigationLink { DayTodayView(charId: c.id) } label: { card(c) }
                        .listRowBackground(Theme.surface2)
                }
            } header: { GroupTitle("今天") }
            .listRowSeparator(.hidden)
            Section {
                NavigationLink { FoodRegionsView() } label: { IconRow(title: "吃什么", icon: "cup") }
                NavigationLink { EventLibraryView() } label: { IconRow(title: "事件库", icon: "spark", value: "共 \(eventCount) 条") }
            } footer: {
                Text("日程由模型按人设生成，一天一次。撞上的事、运势与三顿吃什么都由本地随机数决定，不额外调用接口。")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        }
        .listRowSpacing(Theme.sp2)
        .heroTitle("日常", heroShown: hero)
        .onAppear {
            chars = ((try? Repo.characters()) ?? []).filter { !$0.row.bool("isNpc") && $0.row.string("parentId").isEmpty }
            eventCount = ((try? DayPlan.events()) ?? []).count
        }
    }

    private func card(_ c: Character) -> some View {
        let b = DayPlan.brief(c)
        let doing = b?.nowItems.first
        let now: String = {
            if !DayPlan.isOn(c) { return "未开启当日日程" }
            guard let b else { return "今天还没有安排" }
            if let first = b.nowItems.first { return first }
            return b.total > 0 ? "\(b.doneCount) / \(b.total) 已完成" : "这个时段没有安排"
        }()
        return VStack(alignment: .leading, spacing: Theme.sp2) {
            HStack(spacing: Theme.sp2) {
                Avatar(imageId: c.avatar, name: c.displayName, size: 32)
                Text(c.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if let b { Text(b.slot.label).font(.system(size: 12)).foregroundStyle(Theme.text2) }
            }
            if doing != nil {
                Text(now).font(Theme.serif(20)).lineSpacing(4)
            } else {
                Text(now).font(.system(size: 14)).foregroundStyle(Theme.text2)
            }
            let extra: [String] = {
                var out: [String] = []
                if let ev = b?.event, let t = ev["text"]?.string {
                    let tone = ev["tone"]?.string == "good" ? "好事 · " : ev["tone"]?.string == "bad" ? "坏事 · " : ""
                    out.append(tone + t)
                }
                if let b, !b.meal.isEmpty { out.append(b.meal) }
                return out
            }()
            if !extra.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(extra, id: \.self) { Text($0).lineLimit(2) }
                }
                .font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
        }
        .padding(.vertical, Theme.sp2)
    }
}

/// 一个角色的今天。
struct DayTodayView: View {
    let charId: String
    @State private var char: Character?
    @State private var row: Row?
    @State private var busy = false
    @State private var problem: String?
    @State private var confirmRedo = false
    @State private var showRecent = false

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let c = char {
                if !DayPlan.isOn(c) {
                    Section {
                        Text("这个角色还没有开启当日日程。").foregroundStyle(Theme.secondaryText)
                        Button("现在开启") {
                            do { try Diary.patchChar(charId, ["dayOn": .bool(true)]); reload() }
                            catch { problem = "未能保存：\(error.localizedDescription)" }
                        }
                    } footer: {
                        Text("开启后，该角色每天第一次请求回复之前排一次当天的日程，调用一次接口（走副用接口）；失败当天不再自动排。")
                    }
                } else if let row {
                    content(c, row)
                } else {
                    Section {
                        Text("\(DayPlan.dateKey(c)) 还没有安排").foregroundStyle(Theme.secondaryText)
                        Button(busy ? "正在安排" : "现在安排") { make(force: false) }.disabled(busy)
                    } footer: {
                        Text("调用一次接口排今天的日程；撞上的事与三顿吃什么由本地随机决定。")
                    }
                }
            }
        }
        .navigationTitle(char?.displayName ?? "今天")
        .toolbar {
            if row != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { confirmRedo = true } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("重新安排").disabled(busy)
                }
            }
        }
        .confirmationDialog("重新安排今天", isPresented: $confirmRedo, titleVisibility: .visible) {
            Button("重新安排") { make(force: true) }
        } message: {
            Text("今天已有的安排、撞上的事与三顿吃什么将全部重掷，调用一次接口。")
        }
        .sheet(isPresented: $showRecent) { NavigationStack { DayRecentView(charId: charId) } }
        .onAppear(perform: reload)
    }

    @ViewBuilder private func content(_ c: Character, _ d: Row) -> some View {
        let cur = DayPlan.slotNow(c)
        Section {
            Text("\(d.string("date")) · 现在是\(cur.label) · 运势\(DayPlan.luckLabel(d.number("luck") ?? 0))。还没到的时段，角色只知道自己打算做什么。")
                .font(.footnote).foregroundStyle(Theme.secondaryText)
            if !d.string("planFailed").isEmpty {
                Text("日程未能生成：\(d.string("planFailed"))。撞上的事与三顿吃什么不受影响，已照常生成。为避免重复计费，今天不会再自动重试，明天自动安排一次；可点击右上角手动重新安排。")
                    .font(.footnote).foregroundStyle(Theme.danger)
            }
        }
        let items = d["items"]?.array ?? []
        let meals = d["meals"]?.array ?? []
        let ev = d["event"]
        ForEach(DayPlan.slots) { s in
            let list = items.filter { $0["slot"]?.string == s.id }
            let meal = meals.first { m in DayPlan.meals.first { $0.slot == s.id }?.id == m["meal"]?.string }
            let evHere = ev?["slot"]?.string == s.id ? ev : nil
            if !list.isEmpty || meal != nil || evHere != nil {
                Section(s.label + (s.id == cur.id ? "（现在）" : "")) {
                    if let meal {
                        VStack(alignment: .leading) {
                            Text(meal["name"]?.string ?? "")
                            Text([DayPlan.meals.first { $0.id == meal["meal"]?.string }?.label ?? "", meal["place"]?.string ?? ""]
                                .filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    ForEach(list.indices, id: \.self) { i in
                        let it = list[i]
                        let state = it["state"]?.string ?? DayPlan.plan
                        Button { cycle(d, it) } label: {
                            VStack(alignment: .leading) {
                                Text(it["text"]?.string ?? "").strikethrough(state == DayPlan.drop)
                                    .foregroundStyle(state == DayPlan.drop ? Theme.tertiaryText : Theme.bubbleTheirsText)
                                Text(DayPlan.stateLabel(state)).font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    if let e = evHere {
                        let tone = e["tone"]?.string == "good" ? "好事" : e["tone"]?.string == "bad" ? "坏事" : "不好不坏"
                        let arrived = DayPlan.slotIndex(s.id) <= DayPlan.slotIndex(cur.id)
                        VStack(alignment: .leading) {
                            Text(e["text"]?.string ?? "")
                            Text("撞上的事 · \(tone)" + (arrived ? "" : " · 时段未到，角色还不知道")).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
        }
        Section {
            if ev?.object == nil { Text("今天没有撞上什么事。大部分日子本来就是这样。").font(.footnote).foregroundStyle(Theme.secondaryText) }
            Button("看看最近几天") { showRecent = true }
        } footer: {
            Text("点击任意一条切换状态：计划中 · 已完成 · 已取消。角色在对话中也可以自己标记。")
        }
    }

    private func cycle(_ d: Row, _ it: JSONValue) {
        let s = it["state"]?.string ?? DayPlan.plan
        let next = s == DayPlan.plan ? DayPlan.done : s == DayPlan.done ? DayPlan.drop : DayPlan.plan
        do { try DayPlan.setState(charId, date: d.string("date"), itemId: it["id"]?.string ?? "", next); reload() }
        catch { problem = "未能保存：\(error.localizedDescription)" }
    }

    private func reload() {
        char = try? Repo.character(charId)
        row = char.flatMap { try? DayPlan.today($0) }
    }

    /// 你点的：手动，不经过「当天只自动一次」。
    private func make(force: Bool) {
        busy = true
        problem = nil
        Task {
            do { try await DayPlan.makeToday(charId, force: force) }
            catch { problem = "未能安排：\(error.localizedDescription)" }
            busy = false
            reload()
        }
    }
}

struct DayRecentView: View {
    let charId: String
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []

    var body: some View {
        List(rows, id: \.id) { d in
            let items = d["items"]?.array ?? []
            VStack(alignment: .leading, spacing: 2) {
                Text(d.string("date"))
                Text("\(items.filter { $0["state"]?.string == DayPlan.done }.count) / \(items.count) 完成").font(.footnote).foregroundStyle(Theme.secondaryText)
                if let t = d["event"]?["text"]?.string { Text("撞上：\(t)").font(.footnote).foregroundStyle(Theme.secondaryText) }
                let meals = (d["meals"]?.array ?? []).compactMap { $0["name"]?.string }
                if !meals.isEmpty { Text(meals.joined(separator: "、")).font(.footnote).foregroundStyle(Theme.secondaryText) }
            }
        }
        .navigationTitle("最近几天")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .onAppear { rows = (try? DayPlan.recent(charId, 7)) ?? [] }
    }
}

// MARK: - 事件库

struct EventLibraryView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var counts: [String: Int] = [:]
    @State private var total = 0

    var body: some View {
        List {
            Section {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        ForEach(DayPlan.tones) { Text($0.label).font(.caption).foregroundStyle(Theme.secondaryText) }
                    }
                    ForEach(DayPlan.domains) { d in
                        GridRow {
                            Text(d.label).font(.caption).foregroundStyle(Theme.secondaryText)
                            ForEach(DayPlan.tones) { t in
                                NavigationLink { EventCellView(domain: d, tone: t) } label: {
                                    Text("\(counts["\(d.id):\(t.id)"] ?? 0)").font(.body.monospacedDigit())
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                NavigationLink { EventBatchView() } label: { Text("批量生成") }
            } footer: {
                Text("共 \(total) 条。横向是色彩，纵向是领域。点任意一格查看与编辑该格的词条。事件库全局共用；每个角色要不要撞上事，在与该角色的会话设置里设置。")
            }
            Section {
                NumberRow(title: "每天撞上一件事的概率", value: chanceBinding, unit: "%", placeholder: "不发生", range: 0...100)
                NumberRow(title: "刚抽过的压一压", value: model.number("eventCooldown", 12), unit: "条", placeholder: "不压")
                NumberRow(title: "吃过的压一压", value: model.number("mealCooldown", 8), unit: "顿", placeholder: "不压")
            } footer: {
                Text("概率是基础值，运势差、隔了几天没撞上事时会略升。「压一压」让最近抽过的那几条暂时更难再被抽中。")
            }
        }
        .navigationTitle("事件库")
        .onAppear(perform: reload)
    }

    private var chanceBinding: Binding<Double> {
        Binding(get: { ((model.s.raw["eventChance"]?.number ?? 0.35) * 100).rounded() },
                set: { model.set("eventChance", .number(min(100, max(0, $0)) / 100)) })
    }

    private func reload() {
        let all = (try? DayPlan.events()) ?? []
        total = all.count
        counts = Dictionary(grouping: all, by: { $0.string("cell") }).mapValues(\.count)
    }
}

struct EventCellView: View {
    let domain: DayPlan.Choice
    let tone: DayPlan.Choice
    @State private var rows: [Row] = []
    @State private var editing: Row?
    @State private var adding = false
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                Text("\(domain.label)：\(domain.hint)。\(tone.label)：\(tone.hint)。共 \(rows.count) 条。").font(.footnote).foregroundStyle(Theme.secondaryText)
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
            }
            ForEach(rows, id: \.id) { r in
                HStack {
                    Button { editing = r } label: {
                        VStack(alignment: .leading) {
                            Text(r.string("text")).foregroundStyle(r.bool("off") ? Theme.tertiaryText : Theme.bubbleTheirsText)
                            let w = r.number("weight") ?? 1
                            Text([DayPlan.rarities.first { $0.id == r.string("rarity") }?.label ?? "平常", w != 1 ? "权重 \(Int(w))" : "",
                                  r.bool("off") ? "已停用" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Toggle("", isOn: Binding(get: { !r.bool("off") }, set: { on in patch(r, ["off": .bool(!on)]) })).labelsHidden()
                }
                .swipeActions {
                    Button(role: .destructive) {
                        do { try Database.shared.delete("events", id: r.id); reload() } catch { problem = error.localizedDescription }
                    } label: { Label("删除", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("\(domain.label) · \(tone.label)")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加词条") } }
        .sheet(item: $editing, onDismiss: reload) { r in NavigationStack { EventEditView(domain: domain, tone: tone, row: r) } }
        .sheet(isPresented: $adding, onDismiss: reload) { NavigationStack { EventEditView(domain: domain, tone: tone, row: nil) } }
        .onAppear(perform: reload)
    }

    private func patch(_ r: Row, _ f: [String: JSONValue]) {
        var r = r
        for (k, v) in f { r[k] = v }
        r.touch()
        do { try Database.shared.put("events", r); reload() } catch { problem = error.localizedDescription }
    }

    private func reload() { rows = (try? Database.shared.all("events", where: "\(domain.id):\(tone.id)")) ?? [] }
}


struct EventEditView: View {
    let domain: DayPlan.Choice
    let tone: DayPlan.Choice
    let row: Row?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var rarity = "common"
    @State private var weight = 1.0
    @State private var problem: String?

    var body: some View {
        Form {
            TextField("事件（最多 60 字）", text: $text, axis: .vertical)
            Picker("分量", selection: $rarity) { ForEach(DayPlan.rarities) { Text($0.label).tag($0.id) } }.pickerStyle(.segmented)
            NumberRow(title: "权重", value: $weight, placeholder: "1", range: 1...1000)
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
        }
        .navigationTitle(row == nil ? "添加词条" : "编辑词条")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .onAppear {
            guard let row else { return }
            text = row.string("text"); rarity = row.string("rarity").isEmpty ? "common" : row.string("rarity"); weight = row.number("weight") ?? 1
        }
    }

    private func save() {
        do {
            if var r = row {
                let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                guard !t.isEmpty else { throw StoreError(message: "请填写事件") }
                r["text"] = .string(t); r["rarity"] = .string(rarity); r["weight"] = .number(max(1, weight))
                r.touch()
                try Database.shared.put("events", r)
            } else {
                try DayPlan.addEvent(domain: domain.id, tone: tone.id, rarity: rarity, text: text, weight: weight)
            }
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

/// 批量生成：每格填几条，一格一次请求；生成的先过目，勾选的才入库。
struct EventBatchView: View {
    @State private var want: [String: Double] = [:]
    @State private var rarity = "common"
    @State private var running = false
    @State private var progress = ""
    struct Draft { var cell: String; var text: String; var keep: Bool }
    @State private var results: [Draft] = []
    @State private var failed: [String] = []
    @State private var saved: String?

    private var cells: [(String, Int)] { want.compactMap { $0.value >= 1 ? ($0.key, Int($0.value)) : nil }.sorted { $0.0 < $1.0 } }

    var body: some View {
        Form {
            if results.isEmpty {
                ForEach(DayPlan.domains) { d in
                    Section(d.label) {
                        ForEach(DayPlan.tones) { t in
                            NumberRow(title: t.label, value: Binding(get: { want["\(d.id):\(t.id)"] ?? 0 }, set: { want["\(d.id):\(t.id)"] = $0 }),
                                      unit: "条", placeholder: "0")
                        }
                    }
                }
                Section {
                    Picker("这一批的分量", selection: $rarity) { ForEach(DayPlan.rarities) { Text($0.label).tag($0.id) } }.pickerStyle(.segmented)
                    Button(running ? progress : "生成 \(cells.count) 格，共 \(cells.reduce(0) { $0 + $1.1 }) 条", action: run)
                        .disabled(running || cells.isEmpty)
                    if let saved { Text(saved).font(.footnote).foregroundStyle(Theme.secondaryText) }
                } footer: {
                    Text("每一格调用一次接口（走副用接口）。生成的词条先列出来，勾选后才入库。")
                }
            } else {
                Section("确认入库") {
                    ForEach(results.indices, id: \.self) { i in
                        Toggle(results[i].text, isOn: $results[i].keep)
                    }
                }
                if !failed.isEmpty { Section("这几格没成") { ForEach(failed, id: \.self) { Text($0).font(.footnote) } } }
                Section {
                    Button("保存 \(results.filter(\.keep).count) 条", action: save)
                    Button("放弃", role: .destructive) { results = []; failed = [] }.foregroundStyle(Theme.dangerText)
                }
            }
        }
        .navigationTitle("批量生成")
    }

    private func run() {
        running = true
        failed = []
        let plan = cells
        Task {
            var out: [Draft] = []
            for (i, c) in plan.enumerated() {
                progress = "第 \(i + 1) / \(plan.count) 格"
                let p = c.0.split(separator: ":").map(String.init)
                do {
                    for t in try await DayPlan.generateEvents(domain: p[0], tone: p[1], rarity: rarity, count: c.1) {
                        out.append(Draft(cell: c.0, text: t, keep: true))
                    }
                } catch {
                    failed.append("\(c.0)：\(error.localizedDescription)")
                }
            }
            results = out
            running = false
        }
    }

    private func save() {
        var n = 0
        for r in results where r.keep {
            let p = r.cell.split(separator: ":").map(String.init)
            if (try? DayPlan.addEvent(domain: p[0], tone: p[1], rarity: rarity, text: r.text)) != nil { n += 1 }
        }
        saved = "已入库 \(n) 条"
        results = []
        want = [:]
    }
}

// MARK: - 吃什么

struct FoodRegionsView: View {
    struct Region: Identifiable { var name: String; var count: Int; var id: String { name } }
    @State private var regions: [Region] = []
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        List(regions) { r in
            NavigationLink { FoodListView(region: r.name) } label: {
                HStack { Text(r.name.isEmpty ? "不分地区" : r.name); Spacer(); Text("\(r.count) 条").foregroundStyle(Theme.secondaryText) }
            }
        }
        .navigationTitle("吃什么")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("新增地区") } }
        .alert("新增地区", isPresented: $adding) {
            TextField("地区（最多 20 字）", text: $newName)
            Button("添加") {
                let n = String(newName.trimmingCharacters(in: .whitespaces).prefix(20))
                if !n.isEmpty && !regions.contains(where: { $0.name == n }) { regions.append(Region(name: n, count: 0)) }
                newName = ""
            }
            Button("取消", role: .cancel) { newName = "" }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let all = (try? Database.shared.all("recipes")) ?? []
        var names = [""] + all.map { $0.string("region") }
        names += ((try? Repo.characters()) ?? []).map { DayPlan.region($0) }
        var seen = Set<String>()
        regions = names.filter { seen.insert($0).inserted }.map { n in Region(name: n, count: all.filter { $0.string("region") == n }.count) }
    }
}

struct FoodListView: View {
    let region: String
    @State private var rows: [Row] = []
    @State private var editing: Row?
    @State private var adding = false
    @State private var generating = false
    @State private var count = 20.0
    @State private var meal = ""
    @State private var note: String?

    var body: some View {
        List {
            Section {
                NumberRow(title: "生成条数", value: $count, unit: "条", placeholder: "20", range: 1...1000)
                Picker("哪一顿", selection: $meal) {
                    Text("不限").tag("")
                    ForEach(DayPlan.meals, id: \.id) { Text($0.label).tag($0.id) }
                }
                Button(generating ? "正在生成" : "生成") { generate() }.disabled(generating)
                if let note { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) }
            } footer: {
                Text("调用一次接口（走副用接口），生成的直接入库，可逐条停用或删除。")
            }
            ForEach(rows, id: \.id) { r in
                HStack {
                    Button { editing = r } label: {
                        VStack(alignment: .leading) {
                            Text(r.string("name")).foregroundStyle(r.bool("off") ? Theme.tertiaryText : Theme.bubbleTheirsText)
                            Text([DayPlan.meals.first { $0.id == r.string("meal") }?.label ?? "不限", r.string("place"), r.string("note")]
                                .filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Toggle("", isOn: Binding(get: { !r.bool("off") }, set: { on in
                        var x = r; x["off"] = .bool(!on); x.touch(); try? Database.shared.put("recipes", x); reload()
                    })).labelsHidden()
                }
                .swipeActions {
                    Button(role: .destructive) { try? Database.shared.delete("recipes", id: r.id); reload() } label: { Label("删除", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("吃什么 · \(region.isEmpty ? "不分地区" : region)")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加") } }
        .sheet(item: $editing, onDismiss: reload) { r in NavigationStack { FoodEditView(region: region, row: r) } }
        .sheet(isPresented: $adding, onDismiss: reload) { NavigationStack { FoodEditView(region: region, row: nil) } }
        .onAppear(perform: reload)
    }

    private func reload() { rows = (try? DayPlan.recipes(region: region)) ?? [] }

    private func generate() {
        generating = true
        note = nil
        Task {
            do { note = "已入库 \(try await DayPlan.generateRecipes(region: region, meal: meal, count: max(1, Int(count)))) 条" }
            catch { note = "未能生成：\(error.localizedDescription)" }
            generating = false
            reload()
        }
    }
}

struct FoodEditView: View {
    let region: String
    let row: Row?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var place = ""
    @State private var noteText = ""
    @State private var meal = ""
    @State private var problem: String?

    var body: some View {
        Form {
            TextField("名称", text: $name)
            TextField("店（可不填）", text: $place)
            TextField("说明（可不填）", text: $noteText)
            Picker("哪一顿", selection: $meal) {
                Text("不限").tag("")
                ForEach(DayPlan.meals, id: \.id) { Text($0.label).tag($0.id) }
            }
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
        }
        .navigationTitle(row == nil ? "添加" : "编辑")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .onAppear {
            guard let row else { return }
            name = row.string("name"); place = row.string("place"); noteText = row.string("note"); meal = row.string("meal")
        }
    }

    private func save() {
        let n = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
        guard !n.isEmpty else { problem = "请填写名称"; return }
        var r = row ?? Row.new(prefix: "rc", ["region": .string(region), "price": .number(0), "off": .bool(false)])
        r["name"] = .string(n); r["place"] = .string(String(place.prefix(40))); r["note"] = .string(String(noteText.prefix(60))); r["meal"] = .string(meal)
        r.touch()
        do { try Database.shared.put("recipes", r); dismiss() } catch { problem = error.localizedDescription }
    }
}

/// 会话设置里：这个角色的当日日程与随机事件。
struct DayOnSection: View {
    let charId: String
    @State private var dayOn = false
    @State private var eventsOn = true
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("当日日程", isOn: $dayOn)
            Toggle("随机事件", isOn: $eventsOn)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("日常")
        } footer: {
            Text("当日日程：开启后，每天第一次请求回复之前排一次当天的日程，调用一次接口（走副用接口），失败当天不再自动排；角色能读到今天的安排并可以自己勾掉。随机事件：从事件库里按概率抽，不调用接口。")
        }
        .onAppear {
            guard let c = try? Repo.character(charId) else { return }
            dayOn = DayPlan.isOn(c); eventsOn = c.row["eventsOn"]?.bool != false; loaded = true
        }
        .onChange(of: dayOn) { _, _ in save() }
        .onChange(of: eventsOn) { _, _ in save() }
    }

    private func save() {
        guard loaded else { return }
        do { try Diary.patchChar(charId, ["dayOn": .bool(dayOn), "eventsOn": .bool(eventsOn)]); problem = nil }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}
