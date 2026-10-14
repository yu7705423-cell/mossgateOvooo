import SwiftUI

/// 情侣空间首页（网页版 space/App.js）：当前身份的每段单人会话就是一个空间
struct SpaceHomeView: View {
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let me = (try? Repo.activePersona())?.id ?? ""
        let list = Space.spaces(personaId: me)
        List {
            if list.isEmpty {
                EmptyState(title: "尚无空间", desc: "与角色有了一对一的会话之后，这里出现你们的空间。")
                    .listRowBackground(Color.clear)
            }
            ForEach(list, id: \.chat.id) { x in
                NavigationLink { SpacePageView(chatId: x.chat.id) } label: {
                    HStack(spacing: Theme.sp3) {
                        HStack(spacing: -10) {
                            Avatar(imageId: ChatFaces.of(x.chat, key: x.char.id, fallback: x.char.avatar), name: x.char.name, size: 40)
                            Avatar(imageId: ChatFaces.of(x.chat, key: ChatFaces.me, fallback: (try? Repo.activePersona())?.avatar ?? ""), name: "我", size: 40)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(x.char.displayName).font(.system(size: 15, weight: .medium))
                            Text(Self.subtitle(x.chat)).font(.caption).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("情侣空间")
        .onAppear { Space.deliverDue(); tick += 1 }
    }

    static func subtitle(_ chat: Chat) -> String {
        var bits: [String] = []
        if let d = Space.togetherDays(chat) { bits.append("在一起第 \(d) 天") }
        if let next = Space.upcoming(chat.id).first(where: { $0.left >= 0 }) {
            bits.append(next.left == 0 ? "今天是\(next.item.string("title"))" : "\(next.item.string("title"))还有 \(next.left) 天")
        }
        let open = Space.pacts(chat.id).filter { $0.row.string("pact") == Space.pactOpen }.count
        if open > 0 { bits.append("\(open) 个约定") }
        return bits.isEmpty ? "尚未设置在一起的日子" : bits.joined(separator: " · ")
    }
}

/// 一个空间（网页版 SpacePage）：在一起的日子、纪念日、约定、信箱、记录、让角色知道这些
struct SpacePageView: View {
    let chatId: String
    @State private var tick = 0
    @State private var problem: String?
    @State private var settingStart = false
    @State private var startDate = Date()

    var body: some View {
        let _ = tick
        Form {
            if let chat = try? Repo.chat(chatId), let char = chat.characterIds.first.flatMap({ try? Repo.character($0) }) {
                let st = Space.stats(chat)
                Section {
                    VStack(spacing: Theme.sp2) {
                        Text(char.displayName).font(Theme.serif(20))
                        if let d = st.days {
                            Text("在一起第 \(d) 天").font(.system(size: 15)).foregroundStyle(Theme.text2)
                        }
                        Button(st.days == nil ? "设置在一起的日子" : "修改在一起的日子") {
                            startDate = (chat.row.number("loveStartAt")).map { Date(millis: $0) } ?? Date()
                            settingStart = true
                        }
                        .font(.footnote)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.sp2)
                }
                Section {
                    NavigationLink { SpaceDaysView(chatId: chatId) } label: {
                        LabeledContent("纪念日", value: Space.days(chatId).isEmpty ? "尚无" : "\(Space.days(chatId).count) 个")
                    }
                    NavigationLink { SpacePactsView(chatId: chatId) } label: {
                        LabeledContent("约定", value: st.pactsOpen + st.pactsDone == 0 ? "尚无" : "\(st.pactsOpen) 个进行中，\(st.pactsDone) 个已完成")
                    }
                    NavigationLink { SpaceMailView(chatId: chatId) } label: {
                        LabeledContent("信箱", value: st.letters + st.drafts == 0 ? "空" : "已寄出 \(st.letters)，未寄出 \(st.drafts)")
                    }
                }
                Section {
                    logRow("礼物", "gift", st.gifts, "件")
                    logRow("去过的地方", "location", st.places, "处")
                    logRow("通话", "call", st.calls, "次")
                    LabeledContent("一起听", value: st.listenCount > 0 ? "\(Int(st.listenCount)) 次 · \(Int(st.listenSeconds / 60)) 分钟" : "尚无记录")
                } header: { Text("记录") }
                Section {
                    Toggle("让角色知道这些", isOn: Binding(get: { Space.injectOn(chat) }, set: { v in act { try Space.setInject(chatId, v) } }))
                } footer: {
                    Text("这会增加每次请求的长度。")
                    HelpNote("开启后，每次对话都会附带在一起的天数、三十天内将到的纪念日与还没完成的约定。礼物、地点、信的正文本来就在聊天记录里，不重复附带。", title: "让角色知道这些")
                }
                if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
            } else {
                Text("空间不存在。对应的一对一对话可能已被删除。").foregroundStyle(Theme.text3)
            }
        }
        .navigationTitle("情侣空间")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tick += 1 }
        .sheet(isPresented: $settingStart) {
            NavigationStack {
                Form {
                    DatePicker("起始日", selection: $startDate, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                    Section {
                        Button("清除", role: .destructive) { act { try Space.setStart(chatId, 0) }; settingStart = false }
                    } footer: {
                        HelpNote("设定后，空间与上下文中会显示在一起的天数。")
                    }
                }
                .navigationTitle("在一起的日子")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { settingStart = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { act { try Space.setStart(chatId, Calendar.current.startOfDay(for: startDate).millis) }; settingStart = false }
                    }
                }
            }
        }
    }

    private func logRow(_ title: String, _ kind: String, _ n: Int, _ unit: String) -> some View {
        NavigationLink { SpaceLogView(chatId: chatId, kind: kind, title: title) } label: {
            LabeledContent(title, value: n > 0 ? "\(n) \(unit)" : "尚无记录")
        }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }
}

/// 某一种记录：这段会话里的礼物、位置、通话（只读）
struct SpaceLogView: View {
    let chatId: String
    let kind: String
    let title: String

    var body: some View {
        let list = Space.records(chatId, kind).reversed()
        List {
            if list.isEmpty { Text("尚无记录").foregroundStyle(Theme.text3) }
            ForEach(Array(list), id: \.id) { m in
                VStack(alignment: .leading, spacing: 2) {
                    Text(MsgPreview.text(m)).lineLimit(2)
                    Text("\(m.role == .user ? "我" : "对方") · \(PhotoPageView.at(m.createdAt))").font(.caption).foregroundStyle(Theme.text3)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 纪念日（网页版 DaysPage）
struct SpaceDaysView: View {
    let chatId: String
    @State private var tick = 0
    @State private var editing: EditDay?
    @State private var problem: String?

    struct EditDay: Identifiable {
        var id: String
        var title: String
        var date: Date
        var yearly: Bool
    }

    var body: some View {
        let _ = tick
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            let list = Space.upcoming(chatId)
            if list.isEmpty { Text("尚无纪念日").foregroundStyle(Theme.text3) }
            ForEach(list, id: \.item.id) { x in
                Button {
                    editing = EditDay(id: x.item.id, title: x.item.string("title"), date: Self.date(x.item.string("date")) ?? Date(),
                                      yearly: x.item.bool("yearly"))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(x.item.string("title")).foregroundStyle(Theme.text)
                            Text(x.item.string("date") + (x.item.bool("yearly") ? " · 每年" : "")).font(.caption).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        Text(x.left == 0 ? "今天" : x.left > 0 ? "还有 \(x.left) 天" : "已过去").foregroundStyle(Theme.text2)
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) { act { try Space.removeItem(x.item.id) } }
                }
            }
        }
        .navigationTitle("纪念日")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = EditDay(id: "", title: "", date: Date(), yearly: true) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加纪念日")
            }
        }
        .sheet(item: $editing) { e in
            NavigationStack { DayEditor(day: e) { saved in
                editing = nil
                guard let saved else { return }
                act {
                    let key = Self.key(saved.date)
                    if saved.id.isEmpty { try Space.addDay(chatId: chatId, title: saved.title, date: key, yearly: saved.yearly) }
                    else { try Space.updateDay(saved.id, title: saved.title, date: key, yearly: saved.yearly) }
                }
            } }
        }
    }

    static func key(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func date(_ key: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = error.localizedDescription }
        tick += 1
    }

    struct DayEditor: View {
        @State var day: EditDay
        var done: (EditDay?) -> Void

        var body: some View {
            Form {
                TextField("名称，例如「认识的日子」", text: $day.title)
                DatePicker("日期", selection: $day.date, displayedComponents: .date)
                Toggle("每年重复", isOn: $day.yearly)
            }
            .navigationTitle(day.id.isEmpty ? "添加纪念日" : "编辑纪念日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { done(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { done(day) }.disabled(day.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// 约定（网页版 PactsPage）：进行中、已完成；新增、标记完成、删除
struct SpacePactsView: View {
    let chatId: String
    @State private var tick = 0
    @State private var adding = false
    @State private var newTitle = ""
    @State private var problem: String?

    var body: some View {
        let _ = tick
        let all = Space.pacts(chatId)
        let open = all.filter { $0.row.string("pact") != Space.pactDone }
        let done = all.filter { $0.row.string("pact") == Space.pactDone }
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                if open.isEmpty { Text("尚无").foregroundStyle(Theme.text3) }
                ForEach(open, id: \.id) { m in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.row.string("title"))
                            Text(m.role == .user ? "我提出的" : "对方提出的").font(.caption).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        Button("完成") {
                            act {
                                guard let n = try Space.completePact(m.id) else { return }
                                _ = try Repo.append(n)
                                NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
                            }
                        }
                        .buttonStyle(.borderless).font(.footnote)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { act { try Database.shared.delete(Collections.messages, id: m.id) } }
                    }
                }
            } header: { Text("进行中") } footer: {
                HelpNote("完成后对话中会留下一行提示，角色即可知道这件事做到了。删除该提示将使约定回到未完成。", title: "约定")
            }
            if !done.isEmpty {
                Section {
                    ForEach(done, id: \.id) { m in
                        Text(m.row.string("title")).foregroundStyle(Theme.text2)
                    }
                } header: { Text("已完成") }
            }
        }
        .navigationTitle("约定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { newTitle = ""; adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("新增约定")
            }
        }
        .alert("新增约定", isPresented: $adding) {
            TextField("约定的事", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("发出") {
                act {
                    _ = try Repo.append(try Space.makePact(chatId: chatId, role: .user, authorId: "me", title: newTitle))
                    NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
                }
            }
        } message: {
            Text("约定会作为一条消息发进对话。")
        }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = error.localizedDescription }
        tick += 1
    }
}

/// 信箱（网页版 MailPage）：写信、留在信箱或寄出、定时投递、拆信日期；已寄出的信
struct SpaceMailView: View {
    let chatId: String
    @State private var tick = 0
    @State private var composing: Draft?
    @State private var reading: Message?
    @State private var problem: String?

    struct Draft: Identifiable {
        var id = UUID().uuidString
        var draftId: String?
        var title = ""
        var body = ""
        var sealOn = false
        var openDate = Date().addingTimeInterval(86_400 * 7)
        var timed = false
        var sendDate = Date().addingTimeInterval(3600)
    }

    var body: some View {
        let _ = tick
        let kept = Space.drafts(chatId)
        let sent = Space.records(chatId, "letter").reversed()
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if !kept.isEmpty {
                Section {
                    ForEach(kept) { d in
                        Button {
                            var x = Draft(draftId: d.id, title: d.string("title"), body: d.string("body"))
                            if let o = d.number("openAt"), o > 0 { x.sealOn = true; x.openDate = Date(millis: o) }
                            if let a = d.number("sendAt"), a > 0 { x.timed = true; x.sendDate = Date(millis: a) }
                            composing = x
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.string("title").isEmpty ? "没有抬头" : d.string("title")).foregroundStyle(Theme.text)
                                Text(d.string("body")).font(.caption).foregroundStyle(Theme.text3).lineLimit(1)
                                if let a = d.number("sendAt"), a > 0 {
                                    Text("定时 \(PhotoPageView.at(a)) 寄出").font(.caption).foregroundStyle(Theme.text3)
                                }
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { act { try Space.removeItem(d.id) } }
                            Button("寄出") { act { try Space.sendDraft(d.id) } }.tint(Theme.accent)
                        }
                    }
                } header: { Text("还没寄出 \(kept.count)") }
            }
            Section {
                if sent.isEmpty { Text("信箱是空的").foregroundStyle(Theme.text3) }
                ForEach(Array(sent), id: \.id) { m in
                    Button { reading = m } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.row.string("title").isEmpty ? "没有抬头" : m.row.string("title")).foregroundStyle(Theme.text)
                            Text("\(m.role == .user ? "我" : "对方") · \(PhotoPageView.at(m.createdAt))"
                                 + (Space.sealed(m) ? " · 未到拆信日期" : "")).font(.caption).foregroundStyle(Theme.text3)
                        }
                    }
                }
            } header: { Text("已寄出 \(sent.count)") } footer: {
                HelpNote("角色可以在回复里写信。网页版另有让角色主动写信的三个开关，原生版暂未提供，设置原样保留。", title: "信箱")
            }
        }
        .navigationTitle("信箱")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Space.deliverDue(); tick += 1 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { composing = Draft() } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("写信")
            }
        }
        .sheet(item: $composing) { d in
            NavigationStack { LetterEditor(draft: d) { action, x in
                composing = nil
                act {
                    let openAt = x.sealOn ? Space.openAt(of: x.openDate) : 0
                    switch action {
                    case "send": try Space.sendLetter(chatId: chatId, title: x.title, body: x.body, openAt: openAt)
                        if let id = x.draftId { try Space.removeItem(id) }
                    case "keep": try Space.saveDraft(chatId: chatId, id: x.draftId, title: x.title, body: x.body,
                                                      sendAt: x.timed ? x.sendDate.millis : 0, openAt: openAt)
                    default: break
                    }
                    NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
                }
            } }
        }
        .sheet(item: $reading) { m in
            NavigationStack {
                ScrollView {
                    let closed = Space.sealed(m) && m.role != .user
                    VStack(alignment: .leading, spacing: Theme.sp3) {
                        Text(closed ? "这封信封着，要到拆信日期才能拆开。" : m.row.string("body")).textSelection(.enabled)
                        if !closed, !m.row.string("bodyTrans").isEmpty {
                            Text(m.row.string("bodyTrans")).font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.pad)
                }
                .navigationTitle(m.row.string("title").isEmpty ? "信" : m.row.string("title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { reading = nil } } }
            }
        }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = error.localizedDescription }
        tick += 1
    }

    struct LetterEditor: View {
        @State var draft: Draft
        var done: (String, Draft) -> Void

        var body: some View {
            Form {
                TextField("信封上写什么（可不写）", text: $draft.title)
                Section {
                    TextField("正文", text: $draft.body, axis: .vertical).lineLimit(8...30)
                }
                Section {
                    Toggle("拆信日期", isOn: $draft.sealOn)
                    if draft.sealOn {
                        DatePicker("日期", selection: $draft.openDate, in: Date()..., displayedComponents: .date)
                    }
                    Toggle("定时寄出", isOn: $draft.timed)
                    if draft.timed {
                        DatePicker("时刻", selection: $draft.sendDate, in: Date()...)
                    }
                } footer: {
                    HelpNote("填了拆信日期，角色在这一天之前只看得到信封，读不到内容。定时寄出的信留在信箱里，到点打开应用时寄出。", title: "写信")
                }
            }
            .navigationTitle("写信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { done("cancel", draft) } }
                ToolbarItem(placement: .confirmationAction) {
                    Menu("完成") {
                        if !draft.timed { Button("寄出") { done("send", draft) } }
                        Button(draft.timed ? "存入信箱，到点寄出" : "留在信箱") { done("keep", draft) }
                    }
                    .disabled(draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
