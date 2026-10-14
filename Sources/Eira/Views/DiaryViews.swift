import SwiftUI

/// 日记首页：我的、角色的。
struct DiaryHomeView: View {
    @State private var tab = 0
    @State private var mine: [Diary.Entry] = []
    @State private var writers: [Diary.Writer] = []
    @State private var chars: [Character] = []
    @State private var problem: String?
    @State private var writing = false
    @State private var hero = true

    var body: some View {
        List {
            HeroHeader(eyebrow: "DIARY", title: "日记", shown: $hero)
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
        .heroTitle("日记", heroShown: hero)
        .toolbar {
            if tab == 0 {
                ToolbarItem(placement: .primaryAction) {
                    Button { writing = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("写日记")
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
                Text("调用一次接口（走副用接口），由角色自己决定写不写、写多少。每天自动写一篇的开关在与该角色的会话设置里。")
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
                        Text(replay ?? e.text).textSelection(.enabled)
                        if !e.mine && Diary.parseProcess(e.process).edits > 0 {
                            Button(replaying ? "停止回放" : "回放写作过程") { replaying ? stop() : play(e) }.font(.footnote)
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
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .sheet(isPresented: $editing, onDismiss: load) { NavigationStack { DiaryEditView(id: id) } }
        .confirmationDialog("删除这一篇？删除后无法恢复。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Diary.remove(id); dismiss() } catch { note = "删除失败：\(error.localizedDescription)" }
            }
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

    /// 回放：一个字一个字打出来，删掉的那几段打完再一个字一个字删掉，停顿的地方停一下。
    private func play(_ e: Diary.Entry) {
        replaying = true
        replay = ""
        let steps = Diary.parseProcess(e.process).steps
        job = Task { @MainActor in
            var shown = ""
            for s in steps {
                if Task.isCancelled { break }
                if s.pause { try? await Task.sleep(nanoseconds: 900_000_000); continue }
                let piece = s.text.isEmpty ? s.deleted : s.text
                for ch in piece {
                    if Task.isCancelled { break }
                    shown.append(ch)
                    replay = shown
                    try? await Task.sleep(nanoseconds: 45_000_000)
                }
                if !s.deleted.isEmpty {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    for _ in s.deleted {
                        if Task.isCancelled { break }
                        shown.removeLast()
                        replay = shown
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                }
            }
            replaying = false
            replay = nil
        }
    }

    private func stop() {
        job?.cancel()
        job = nil
        replaying = false
        replay = nil
    }
}

/// 写或改一篇你的日记。
struct DiaryEditView: View {
    let id: String?
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var title = ""
    @State private var text = ""
    @State private var visibility = "self"
    @State private var charId = ""
    @State private var chars: [Character] = []
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                DatePicker("日期", selection: $date, displayedComponents: .date)
                TextField("标题（可不填）", text: $title)
                TextField("正文", text: $text, axis: .vertical).lineLimit(8...40)
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
                Text(visibility == "public"
                     ? "公开：所选角色（未选择时为所有角色）在当天及之后「设置 - 用量与上限」所设天数内的对话中读得到这一篇。"
                     : "仅自己：只在日记里显示，不写入任何对话。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
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
        guard let id, let row = try? Database.shared.get("diaries", id: id) else { return }
        let e = Diary.Entry(row: row)
        title = e.title; text = e.text; visibility = e.visibility; charId = e.charId
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        date = f.date(from: e.date) ?? Date()
    }

    private func save() {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        do {
            try Diary.saveMine(id: id, date: f.string(from: date), title: title, text: text,
                               visibility: visibility, charId: visibility == "public" ? charId : "")
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
            Text("开启后，每天到了设定时刻之后给角色一次写日记的机会，写不写由角色决定。每天调用一次接口（走副用接口）；当天已经有一篇时不写；失败当天不再自动尝试，第二天再试。只在应用打开时进行。")
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
