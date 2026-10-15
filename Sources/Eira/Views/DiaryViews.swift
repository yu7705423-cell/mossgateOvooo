import PhotosUI
import SwiftUI

/// 日记首页（网页版 diary/App.js 的 Calendar，4.333）：一个月的日历，每天两个心情记号（左我，右选中的角色），
/// 写过日记的日期下一个小点。心情取自健康 app，不另存。点日期在下方看这一天，再点「查看当天」进时间线。
struct DiaryHomeView: View {
    @State private var year = 0
    @State private var month = 0
    @State private var sel = ""
    @State private var charId: String?
    @State private var writing = false
    @State private var hero = true
    @State private var tick = 0

    private static let monthNames = ["一月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "十一月", "十二月"]

    var body: some View {
        let _ = tick
        let today = Diary.todayMine()
        let choices = Diary.charChoices()
        let cid = charId ?? choices.first?.id ?? ""
        let day = sel.isEmpty ? today : sel
        List {
            HeroHeader(eyebrow: "DIARY", title: "日记", shown: $hero)
            if year > 0 {
                calendar(today: today, choices: choices, cid: cid, day: day)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("心情", value: [
                    "我：\(DiaryMood.label(Diary.moodOn(Diary.me, day)))",
                    cid.isEmpty ? "" : "\(DiaryMood.name(cid))：\(DiaryMood.label(Diary.moodOn(cid, day)))",
                ].filter { !$0.isEmpty }.joined(separator: "　"))
                ForEach(Diary.on(day, charId: cid)) { e in
                    NavigationLink { DiaryReadView(id: e.id) } label: {
                        Text(e.mine ? "我的日记" : "\(DiaryMood.name(e.owner))的日记")
                            + Text(e.title.isEmpty || e.locked ? "" : " · \(e.title)").foregroundColor(Theme.secondaryText)
                    }
                }
                NavigationLink { DiaryDayView(date: day, charId: cid) } label: { Text("查看当天") }
            } header: {
                Text("\(DiaryMood.dateText(day))\(day == today ? " · 今天" : "")")
            } footer: {
                HelpNote("「查看当天」按时间列出当天的聊天、纪念日、信与日记。", title: "日记：日历")
            }
            Section("角色的日记") {
                if choices.isEmpty {
                    Text("与角色建立会话后，角色的日记与心情会显示在日历上。").font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                ForEach(choices) { c in
                    NavigationLink { CharDiaryView(charId: c.id) } label: {
                        HStack(spacing: Theme.pad) {
                            Avatar(imageId: c.avatar, name: c.displayName, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.displayName)
                                let n = ((try? Diary.ofChar(c.id)) ?? []).count
                                Text(n > 0 ? "\(n) 篇" : (Diary.isAuto(c) ? "每天自动写，尚未写过" : "尚未写过"))
                                    .font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
                NavigationLink { DiaryListView() } label: { Text("全部日记") }
            }
        }
        .listStyle(.insetGrouped)
        .heroTitle("日记", heroShown: hero)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { writing = true } label: { NavIcon("edit") }.accessibilityLabel("写日记")
            }
        }
        .sheet(isPresented: $writing, onDismiss: { tick += 1 }) {
            NavigationStack { DiaryEditView(id: nil, start: day <= today ? day : today) }
        }
        .onAppear {
            if year == 0 {
                let p = today.split(separator: "-").compactMap { Int($0) }
                year = p.first ?? 2026; month = p.count > 1 ? p[1] : 1
            }
            tick += 1
        }
    }

    private func calendar(today: String, choices: [Character], cid: String, day: String) -> some View {
        let cells = Diary.month(year, month, charId: cid)
        var comps = DateComponents(); comps.year = year; comps.month = month; comps.day = 1
        let cal = Calendar(identifier: .gregorian)
        let first = cal.date(from: comps) ?? Date()
        let lead = (cal.component(.weekday, from: first) + 5) % 7      // 周一在前
        let days = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let grid: [String?] = Array(repeating: nil, count: lead) + (1...days).map { Optional(String(format: "%04d-%02d-%02d", year, month, $0)) }
        return VStack(spacing: Theme.sp3) {
            HStack {
                Button { go(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上个月")
                Spacer()
                Text(Self.monthNames[month - 1]).font(Theme.serif(20)) + Text("  \(String(year))").font(.footnote).foregroundColor(Theme.secondaryText)
                Spacer()
                Button { go(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下个月")
            }
            .buttonStyle(.plain)
            if !choices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.sp2) {
                        ForEach(choices) { c in chip(c.displayName, on: cid == c.id) { charId = c.id } }
                        chip("全部角色", on: cid.isEmpty) { charId = "" }
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 6) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                    Text(w).font(.caption2).foregroundStyle(Theme.tertiaryText)
                }
                ForEach(Array(grid.enumerated()), id: \.offset) { _, d in
                    if let d {
                        let c = cells[d] ?? Diary.Cell()
                        Button {
                            sel = d
                        } label: {
                            VStack(spacing: 3) {
                                Text("\(Int(d.suffix(2)) ?? 0)").font(.system(size: 14, weight: d == today ? .semibold : .regular))
                                    .foregroundStyle(d > today ? Theme.tertiaryText : Theme.text)
                                HStack(spacing: 2) {
                                    DiaryMood.mark(c.me)
                                    if !cid.isEmpty { DiaryMood.mark(c.char).opacity(0.55) }
                                }
                                .frame(height: 10)
                                Circle().fill(c.mine + c.theirs > 0 ? Theme.text2 : .clear).frame(width: 4, height: 4)
                            }
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(d == day ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height: 46)
                    }
                }
            }
            HStack(spacing: Theme.sp3) {
                ForEach(Diary.moods, id: \.id) { m in
                    HStack(spacing: 3) { DiaryMood.mark(m.id); Text(m.label) }
                }
                Spacer()
                Text(cid.isEmpty ? "心情为我的" : "左为我，右为\(DiaryMood.name(cid))")
            }
            .font(.caption2).foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, Theme.sp2)
    }

    private func chip(_ label: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label).font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .foregroundStyle(on ? Theme.onAccent : Theme.text)
                .background(on ? Theme.accent : Theme.surface2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func go(_ delta: Int) {
        month += delta
        if month < 1 { month = 12; year -= 1 }
        if month > 12 { month = 1; year += 1 }
    }
}

/// 心情记号与几处共用的小件：单色，四档四个形状，不靠颜色区分
enum DiaryMood {
    static let icons = ["good": "sun.max", "flat": "cloud", "low": "cloud.rain", "tense": "bolt"]

    @ViewBuilder static func mark(_ mood: String, size: CGFloat = 9) -> some View {
        if let n = icons[mood] {
            Image(systemName: n).font(.system(size: size, weight: .semibold)).foregroundStyle(Theme.text2)
        }
    }

    static func label(_ id: String) -> String { Diary.moods.first(where: { $0.id == id })?.label ?? "未记录" }

    static func name(_ id: String) -> String { ((try? Repo.character(id)) ?? nil)?.displayName ?? "" }

    static func dateText(_ d: String) -> String {
        let p = d.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? "\(p[1]) 月 \(p[2]) 日" : d
    }

    static func weekText(_ d: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = Calendar(identifier: .gregorian)
        guard let date = f.date(from: d) else { return "" }
        return "星期" + ["日", "一", "二", "三", "四", "五", "六"][Calendar(identifier: .gregorian).component(.weekday, from: date) - 1]
    }
}

/// 某一天（网页版 DayPage）：那一天发生过的事按时间排。只读已有记录，不调接口。「往年的今天」有记录才出现
struct DiaryDayView: View {
    let date: String
    let charId: String
    @State private var writing = false
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let list = Diary.timeline(date, charId: charId)
        let past = Diary.pastYears(date, charId: charId)
        let who = DiaryMood.name(charId)
        List {
            Section {
                HStack(spacing: Theme.sp5) {
                    moodBox("我", Diary.moodOn(Diary.me, date))
                    if !charId.isEmpty { moodBox(who, Diary.moodOn(charId, date)) }
                }
            } header: { Text("\(DiaryMood.dateText(date)) · \(DiaryMood.weekText(date))") }
            Section {
                if list.isEmpty { Text("这一天没有记录").foregroundStyle(Theme.secondaryText) }
                ForEach(Array(list.enumerated()), id: \.offset) { _, ev in row(ev, who: who) }
            }
            if !past.isEmpty {
                Section("往年的今天") {
                    ForEach(past) { d in
                        NavigationLink { DiaryReadView(id: d.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\((Int(date.prefix(4)) ?? 0) - (Int(d.date.prefix(4)) ?? 0)) 年前的今天").font(.caption).foregroundStyle(Theme.secondaryText)
                                Text(d.mine ? "我的日记" : "\(DiaryMood.name(d.owner))的日记")
                                Text(d.date + (d.title.isEmpty || d.locked ? "" : " · \(d.title)")).font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(DiaryMood.dateText(date))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("写日记") { writing = true } } }
        .sheet(isPresented: $writing, onDismiss: { tick += 1 }) { NavigationStack { DiaryEditView(id: nil, start: date) } }
        .onAppear { tick += 1 }
    }

    private func moodBox(_ who: String, _ mood: String) -> some View {
        HStack(spacing: 6) {
            DiaryMood.mark(mood, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(who).font(.caption).foregroundStyle(Theme.secondaryText)
                Text(DiaryMood.label(mood))
            }
        }
    }

    @ViewBuilder private func row(_ ev: Diary.Event, who: String) -> some View {
        let head = Text(ev.time).font(.caption.monospacedDigit()).foregroundColor(Theme.secondaryText)
        switch ev.type {
        case "chat":
            VStack(alignment: .leading, spacing: 2) {
                head
                Text("与\(who)聊了 \(ev.count) 条")
                if !ev.last.isEmpty { Text("最后一条：\(ev.last)").font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(1) }
            }
        case "anniversary":
            VStack(alignment: .leading, spacing: 2) {
                head
                Text(ev.title).fontWeight(.medium) + Text(ev.years > 0 ? "  \(ev.years) 周年" : "  纪念日").font(.caption).foregroundColor(Theme.secondaryText)
            }
        case "letter", "letterDue":
            VStack(alignment: .leading, spacing: 2) {
                head
                Text(ev.type == "letterDue" ? "定时寄出的信（待寄）" : ev.mine ? "寄给\(who)一封信" : "\(who)寄来一封信")
                if !ev.title.isEmpty { Text(ev.title).font(.footnote).foregroundStyle(Theme.secondaryText) }
            }
        default:
            if let r = try? Database.shared.get("diaries", id: ev.diaryId) {
                let d = Diary.Entry(row: r)
                NavigationLink { DiaryReadView(id: d.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        head
                        Text(d.mine ? "我的日记" : "\(DiaryMood.name(d.owner))的日记")
                        if !d.title.isEmpty && !d.locked { Text(d.title).font(.footnote).foregroundStyle(Theme.secondaryText) }
                    }
                }
            }
        }
    }
}

/// 全部日记：我的、角色的（从日历首页进来）
struct DiaryListView: View {
    @State private var tab = 0
    @State private var mine: [Diary.Entry] = []
    @State private var writers: [Diary.Writer] = []
    @State private var chars: [Character] = []
    @State private var problem: String?
    @State private var writing = false
    @State private var hero = true

    var body: some View {
        List {
            Picker("", selection: $tab) {
                Text("我的").tag(0)
                Text("角色的").tag(1)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if tab == 0 {
                if mine.isEmpty {
                    EmptyState(title: "尚无日记", desc: "点右上角写下第一篇。").listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(mine) { e in
                    NavigationLink { DiaryReadView(id: e.id) } label: { DiaryRow(entry: e, who: "") }
                }
            } else {
                if writers.isEmpty {
                    EmptyState(title: "尚无角色写过日记", desc: "在角色的日记页中可以请角色现在写一篇。").listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(writers) { w in
                    NavigationLink { CharDiaryView(charId: w.char.id) } label: {
                        HStack(spacing: Theme.pad) {
                            Avatar(imageId: w.char.avatar, name: w.char.displayName, size: Theme.listAvatarSize)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.char.displayName)
                                Text("最近一篇 \(w.last)").font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
                let others = chars.filter { c in !writers.contains { $0.char.id == c.id } }
                if !others.isEmpty {
                    Section("其他角色") {
                        ForEach(others) { c in
                            NavigationLink { CharDiaryView(charId: c.id) } label: { Text(c.displayName) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("全部日记")
        .toolbar {
            if tab == 0 {
                ToolbarItem(placement: .primaryAction) {
                    Button { writing = true } label: { NavIcon("edit") }.accessibilityLabel("写日记")
                }
            }
        }
        .sheet(isPresented: $writing, onDismiss: reload) {
            NavigationStack { DiaryEditView(id: nil) }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        do {
            mine = try Diary.mine()
            writers = try Diary.writers()
            chars = try Repo.characters()
            problem = nil
        } catch {
            problem = "读取失败：\(error.localizedDescription)"
        }
    }
}

struct DiaryRow: View {
    let entry: Diary.Entry
    let who: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.date).font(.footnote.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                if let k = Diary.kinds.first(where: { $0.id == entry.kind }), !entry.mine, k.id != "full" {
                    Text(k.label).font(.caption).foregroundStyle(Theme.tertiaryText)
                }
                if entry.locked { Image(systemName: "lock").font(.caption).foregroundStyle(Theme.tertiaryText) }
                if entry.mine && entry.visibility == "public" { Text("公开").font(.caption).foregroundStyle(Theme.tertiaryText) }
            }
            if !entry.title.isEmpty { Text(entry.title) }
            Text(entry.locked ? "已上锁" : entry.text).font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

/// 一个角色的日记，与「现在写一篇」。
struct CharDiaryView: View {
    let charId: String
    @State private var char: Character?
    @State private var entries: [Diary.Entry] = []
    @State private var writing = false
    @State private var note: String?
    @State private var noteIsError = false

    var body: some View {
        List {
            Section {
                Button(writing ? "正在写" : "现在写一篇") { write() }.disabled(writing)
                if let note { Text(note).font(.footnote).foregroundStyle(noteIsError ? Theme.danger : Theme.secondaryText) }
                if let err = char?.row.string("diaryAutoError"), !err.isEmpty {
                    Text("今天自动写日记失败：\(err)。明天到点后自动再试。").font(.footnote).foregroundStyle(Theme.danger)
                }
            } footer: {
                Text("调用一次接口。")
                HelpNote("调用一次接口（走副用接口），由角色自己决定写不写、写多少。每天自动写一篇的开关在与该角色的会话设置里。", title: "请角色写一篇")
            }
            ForEach(entries) { e in
                NavigationLink { DiaryReadView(id: e.id) } label: { DiaryRow(entry: e, who: char?.displayName ?? "") }
            }
        }
        .navigationTitle(char?.displayName ?? "日记")
        .onAppear(perform: reload)
    }

    private func reload() {
        char = try? Repo.character(charId)
        entries = (try? Diary.ofChar(charId)) ?? []
    }

    private func write() {
        writing = true
        note = nil
        Task {
            do {
                let out = try await Diary.write(charId: charId)
                note = out == .skipped ? "角色今天选择不写。" : "已写好一篇。"
                noteIsError = false
            } catch {
                note = "未能写成：\(error.localizedDescription)"
                noteIsError = true
            }
            writing = false
            reload()
        }
    }
}

/// 读一篇。角色上了锁的要输密码；写的过程可以回放。
struct DiaryReadView: View {
    let id: String
    @State private var entry: Diary.Entry?
    @State private var code = ""
    @State private var note: String?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var replay: String?
    @State private var replaying = false
    @State private var struckOut = ""
    @State private var speed = DiaryReadView.speedNow()
    @State private var viewing: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            if let e = entry {
                VStack(alignment: .leading, spacing: Theme.pad) {
                    HStack {
                        Text(e.date).font(.footnote.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                        if let m = Diary.moods.first(where: { $0.id == e.mood }) {
                            Text("心情 \(m.label)").font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                        if !e.mine, let k = Diary.kinds.first(where: { $0.id == e.kind }) {
                            Text(k.label).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if e.locked { lockPanel(e) } else {
                        if !e.title.isEmpty { Text(e.title).font(.title3) }
                        (Text(replay ?? e.text) + Text(struckOut).strikethrough().foregroundColor(Theme.tertiaryText))
                            .textSelection(.enabled)
                        ForEach(e.imageIds, id: \.self) { img in
                            LocalImage(id: img, maxPixel: 1000, fit: true)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
                                .onTapGesture { viewing = img }
                        }
                        let trans = [e.row.string("titleTrans"), e.row.string("textTrans")].filter { !$0.isEmpty }.joined(separator: "\n\n")
                        if !trans.isEmpty && replay == nil {
                            Text(trans).font(.subheadline).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
                        }
                        if !e.mine && Diary.parseProcess(e.process).edits > 0 {
                            HStack {
                                Button(replaying ? "停止回放" : "回放写作过程") { replaying ? stop() : play(e) }
                                Spacer()
                                Picker("速度", selection: Binding(get: { speed }, set: { setSpeed($0) })) {
                                    ForEach(Self.speeds, id: \.self) { v in Text(v < 1 ? "\(v == 0.25 ? "0.25" : "0.5")x" : "\(Int(v))x").tag(v) }
                                }
                                .pickerStyle(.menu)
                            }
                            .font(.footnote)
                        }
                    }
                    if let note { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) }
                }
                .padding(Theme.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(entry?.mine == true ? "我的日记" : ((try? Repo.character(entry?.owner ?? ""))?.displayName ?? "日记"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if entry?.mine == true && entry?.visibility != "lock" {
                        Button { editing = true } label: { Label("编辑", systemImage: "pencil") }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
                } label: { NavIcon("more") }
            }
        }
        .sheet(isPresented: $editing, onDismiss: load) { NavigationStack { DiaryEditView(id: id) } }
        .confirmationDialog("删除这一篇？删除后无法恢复。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Diary.remove(id); dismiss() } catch { note = "删除失败：\(error.localizedDescription)" }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            if let viewing { ImageViewer(imageId: viewing) }
        }
        .onAppear(perform: load)
        .onDisappear(perform: stop)
    }

    @ViewBuilder private func lockPanel(_ e: Diary.Entry) -> some View {
        if e.mine {
            Text("这一篇在网页版上了锁。原生版暂不支持打开你自己上锁的日记。").foregroundStyle(Theme.secondaryText)
        } else {
            let tries = Int(e.lock?["tries"]?.number ?? 0)
            Text("这一篇上了锁。").foregroundStyle(Theme.secondaryText)
            SecureField("密码", text: $code)
                .keyboardType(e.lock?["digits"]?.bool == true ? .numberPad : .default)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("打开") { open() }.disabled(code.isEmpty)
                Button("请角色给提示") { hint() }
            }
            .buttonStyle(.bordered)
            if tries > 0 { Text("已尝试 \(tries) 次。角色知道你试过几次、是否打开。").font(.footnote).foregroundStyle(Theme.secondaryText) }
            Text("请求提示会以你的名义在与该角色的会话中发一条消息，角色怎么回应由它自己决定。").font(.footnote).foregroundStyle(Theme.secondaryText)
        }
    }

    private func load() {
        if let r = try? Database.shared.get("diaries", id: id) { entry = Diary.Entry(row: r) } else { entry = nil }
    }

    private func open() {
        do {
            note = try Diary.tryOpen(id, code) ? nil : "密码不正确。"
            code = ""
            load()
        } catch { note = "未能保存：\(error.localizedDescription)" }
    }

    private func hint() {
        do {
            _ = try Diary.askHint(id)
            note = "已在会话中发出请求，回到会话请角色回复即可。"
            load()
        } catch { note = error.localizedDescription }
    }

    @State private var job: Task<Void, Never>?

    static let speeds: [Double] = [0.25, 0.5, 1, 2, 4]

    /// 回放速度：五档，选过的记在 settings.diaryPlaySpeed，下一篇照这一档放（网页版同一个键）
    static func speedNow() -> Double {
        let v = AppSettings.load().raw["diaryPlaySpeed"]?.number ?? 0.5
        return speeds.contains(v) ? v : 0.5
    }

    private func setSpeed(_ v: Double) {
        speed = v
        var st = AppSettings.load()
        st.raw["diaryPlaySpeed"] = .number(v)
        do { try st.save() } catch { note = "未能保存：\(error.localizedDescription)" }
    }

    /// 回放（网页版 Playback）：一个字一个字打出来；删掉的那段先打出来，停一下，划掉，再整段去掉；停顿的地方停一下。
    /// 速度中途可以换，下一个字起生效
    private func play(_ e: Diary.Entry) {
        replaying = true
        replay = ""
        struckOut = ""
        let steps = Diary.parseProcess(e.process).steps
        job = Task { @MainActor in
            var shown = ""
            func wait(_ ms: Double) async { try? await Task.sleep(nanoseconds: UInt64(ms / speed * 1_000_000)) }
            for s in steps {
                if Task.isCancelled { break }
                if s.pause { await wait(1300); continue }
                let piece = s.text.isEmpty ? s.deleted : s.text
                for ch in piece {
                    if Task.isCancelled { break }
                    shown.append(ch)
                    replay = shown
                    await wait(55 + Double.random(in: 0..<60) + ("。，！？\n".contains(ch) ? 220 : 0))
                }
                if !s.deleted.isEmpty && s.text.isEmpty {
                    await wait(700)
                    let n = s.deleted.count
                    replay = String(shown.dropLast(n))
                    struckOut = String(shown.suffix(n))
                    await wait(450)
                    shown = String(shown.dropLast(n))
                    replay = shown
                    struckOut = ""
                    await wait(120)
                }
            }
            replaying = false
            replay = nil
            struckOut = ""
        }
    }

    private func stop() {
        job?.cancel()
        job = nil
        replaying = false
        replay = nil
        struckOut = ""
    }
}

/// 写或改一篇你的日记。
struct DiaryEditView: View {
    let id: String?
    /// 新写一篇时的日期（从日历上点的那一天），空为今天
    var start = ""
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var title = ""
    @State private var text = ""
    @State private var visibility = "self"
    @State private var charId = ""
    @State private var mood = ""
    @State private var imageIds: [String] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var pickingAlbum = false
    @State private var chars: [Character] = []
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                DatePicker("日期", selection: $date, displayedComponents: .date)
                Picker("心情", selection: $mood) {
                    Text("未记录").tag("")
                    ForEach(Diary.moods, id: \.id) { m in Text(m.label).tag(m.id) }
                }
                TextField("标题（可不填）", text: $title)
                TextField("正文", text: $text, axis: .vertical).lineLimit(8...40)
            }
            Section("图片") {
                if !imageIds.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.sp2) {
                            ForEach(imageIds, id: \.self) { id in
                                LocalImage(id: id, maxPixel: 240)
                                    .frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        Button { imageIds.removeAll { $0 == id } } label: {
                                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.white, Color.black.opacity(0.5))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("移除这张")
                                        .padding(3)
                                    }
                            }
                        }
                    }
                }
                PhotosPicker(selection: $picked, matching: .images) { Text("从手机相册添加") }
                Button("从相册 app 添加") { pickingAlbum = true }
            }
            Section {
                Picker("可见范围", selection: $visibility) {
                    ForEach(Diary.visibility.indices, id: \.self) { i in Text(Diary.visibility[i].label).tag(Diary.visibility[i].id) }
                }
                if visibility == "public" {
                    Picker("给谁看", selection: $charId) {
                        Text("所有角色").tag("")
                        ForEach(chars) { Text($0.displayName).tag($0.id) }
                    }
                }
            } footer: {
                HelpNote("心情记在健康 app 的那一天里，与健康 app 是同一份。")
                HelpNote(visibility == "public"
                     ? "公开：所选角色（未选择时为所有角色）在当天及之后「设置 - 用量与上限」所设天数内的对话中读得到这一篇。"
                     : "仅自己：只在日记里显示，不写入任何对话。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { @MainActor in
                for item in items {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                        imageIds.append(try Images.save(data))
                    } catch { problem = "有图片未能存下：\(error.localizedDescription)" }
                }
            }
        }
        .sheet(isPresented: $pickingAlbum) {
            NavigationStack { AlbumPickView { ids in imageIds += ids.filter { !imageIds.contains($0) } } }
        }
        .navigationTitle(id == nil ? "写日记" : "编辑日记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .onAppear(perform: load)
    }

    private func load() {
        chars = (try? Repo.characters()) ?? []
        let f0 = DateFormatter()
        f0.dateFormat = "yyyy-MM-dd"
        if id == nil, let d = f0.date(from: start) { date = d }
        mood = Diary.moodOn(Diary.me, id == nil ? (start.isEmpty ? Diary.todayMine() : start) : "")
        guard let id, let row = try? Database.shared.get("diaries", id: id) else { return }
        let e = Diary.Entry(row: row)
        title = e.title; text = e.text; visibility = e.visibility; charId = e.charId
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        date = f.date(from: e.date) ?? Date()
        mood = Diary.moodOn(Diary.me, e.date)
        imageIds = e.imageIds
    }

    private func save() {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        do {
            try Diary.saveMine(id: id, date: f.string(from: date), title: title, text: text,
                               visibility: visibility, charId: visibility == "public" ? charId : "", imageIds: imageIds)
            if Diary.moodOn(Diary.me, f.string(from: date)) != mood { try Diary.setMyMood(f.string(from: date), mood) }
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// 会话设置里：这个角色要不要每天写一篇日记（网页版放在「主动发起对话」那一页）。
struct DiaryAutoSection: View {
    let charId: String
    @State private var on = false
    @State private var hour = Diary.hourDefault
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("每天写日记", isOn: $on)
            if on { Stepper("\(hour) 点之后", value: $hour, in: 0...23) }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } footer: {
            Text("每天调用一次接口。")
            HelpNote("开启后，每天到了设定时刻之后给角色一次写日记的机会，写不写由角色决定。每天调用一次接口（走副用接口）；当天已经有一篇时不写；失败当天不再自动尝试，第二天再试。只在应用打开时进行。")
        }
        .onAppear {
            guard let c = try? Repo.character(charId) else { return }
            on = Diary.isAuto(c); hour = Diary.hour(c); loaded = true
        }
        .onChange(of: on) { _, _ in save() }
        .onChange(of: hour) { _, _ in save() }
    }

    private func save() {
        guard loaded else { return }
        do { try Diary.patchChar(charId, ["diaryAuto": .bool(on), "diaryHour": .number(Double(hour))]); problem = nil }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}

/// 从相册 app 里挑几张（日记插图用）。只读，不改相册
struct AlbumPickView: View {
    var done: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: [String] = []

    var body: some View {
        let photos = Album.listAlbums().flatMap { Album.listPhotos($0.id) } + Album.listPhotos("")
        let withImage = photos.filter { !$0.imageId.isEmpty }
        ScrollView {
            if withImage.isEmpty { EmptyState(title: "相册里还没有图片") }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(withImage) { p in
                    Button {
                        if let i = chosen.firstIndex(of: p.imageId) { chosen.remove(at: i) } else { chosen.append(p.imageId) }
                    } label: {
                        LocalImage(id: p.imageId, maxPixel: 300)
                            .frame(minWidth: 0, maxWidth: .infinity).aspectRatio(1, contentMode: .fill).clipped()
                            .overlay(alignment: .topTrailing) {
                                if chosen.contains(p.imageId) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.white, Theme.accent).padding(4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("从相册选择")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("添加 \(chosen.count) 张") { done(chosen); dismiss() }.disabled(chosen.isEmpty) }
        }
    }
}
