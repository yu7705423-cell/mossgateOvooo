import SwiftUI
import PhotosUI

/// 短信（网页版 apps/sms，ARCHITECTURE 4.307）。一段短信 = 你的一个号码 x 对面的一个号码；彩信就是带图的那一条。
/// 回复和聊天一样由你点「回复」才调一次接口；身份没确认时，角色只知道这是一个号码。
struct SmsAppView: View {
    enum Route: Hashable { case thread(String), new, blocked, numbers }
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            SmsHomeView(path: $path)
                .navigationDestination(for: Route.self) { r in
                    switch r {
                    case .thread(let id): SmsThreadView(threadId: id)
                    case .new: SmsNewView { id in path = [.thread(id)] }
                    case .blocked: SmsBlockedView()
                    case .numbers: SmsNumbersView()
                    }
                }
        }
    }
}

enum SmsText {
    static func time(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let d = Date(millis: ms)
        let cal = Calendar.current
        let c = cal.dateComponents([.month, .day, .hour, .minute], from: d)
        if cal.isDateInToday(d) { return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }
        return "\(c.month ?? 1)月\(c.day ?? 1)日"
    }

    /// 对面显示成什么：号码的主人是联系人里的角色（不是 NPC）就写名字，否则写号码。借号发来的只看得见号码
    static func title(_ t: Row) -> String {
        if let owner = PhoneNum.ownerOf(t.string("theirs")), !owner.isNpc, t.string("via").isEmpty { return owner.displayName }
        return t.string("theirs")
    }

    static func preview(_ m: Message?) -> String {
        guard let m else { return "暂无消息" }
        return m.kind == "image" ? "[彩信]" : m.content
    }
}

struct SmsHomeView: View {
    @Binding var path: [SmsAppView.Route]
    @State private var threads: [Row] = []
    @State private var last: [String: Message] = [:]
    @State private var caught = 0

    var body: some View {
        List {
            if threads.isEmpty {
                Section {
                    EmptyState(title: "暂无短信", desc: "短信按号码收发，与聊天分开。身份未确认时，对方只知道你的号码。")
                    Button("新建短信") { path.append(.new) }
                        .buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(threads, id: \.id) { t in
                        NavigationLink(value: SmsAppView.Route.thread(t.id)) { row(t) }
                    }
                }
            }
            Section {
                NavigationLink(value: SmsAppView.Route.blocked) {
                    HStack {
                        Text("已拦截")
                        Spacer()
                        if caught > 0 { Text("\(caught) 条").foregroundStyle(Theme.text2) }
                    }
                }
                HelpNote("拦截号码发来的短信收在这里，不提醒。", title: "短信：已拦截")
            }
        }
        .navigationTitle("短信")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { path.append(.numbers) } label: { SvgIcon(name: "phone", size: 20) }
                    .accessibilityLabel("我的号码")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { path.append(.new) } label: { SvgIcon(name: "edit", size: 20) }
                    .accessibilityLabel("新建短信")
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .eiraChatChanged)) { _ in reload() }
    }

    private func row(_ t: Row) -> some View {
        let unread = Int(t.number("unread") ?? 0)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(SmsText.title(t)).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if unread > 0 {
                    Text("\(unread)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.accent, in: Capsule())
                }
                Text(SmsText.time(t.number("lastMessageAt") ?? 0)).font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            Text("\(SmsText.preview(last[t.id])) · 我的号码 \(t.string("mine"))")
                .font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(1)
        }
    }

    private func reload() {
        threads = Sms.threadsOf()
        var out: [String: Message] = [:]
        for t in threads { out[t.id] = Sms.visible(t.id).last }
        last = out
        caught = Sms.intercepted().count
    }
}

struct SmsNewView: View {
    var opened: (String) -> Void
    @State private var mine: [String] = []
    @State private var from = ""
    @State private var to = ""
    @State private var contacts: [Character] = []
    @State private var problem: String?

    var body: some View {
        Form {
            Section("发送号码") {
                ForEach(mine, id: \.self) { n in
                    Button { from = n } label: {
                        HStack {
                            Text(n).foregroundStyle(Theme.text)
                            Spacer()
                            if n == from { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Section("发给") {
                TextField("号码", text: $to).keyboardType(.phonePad)
                HelpNote("输入号码，或从下方联系人中选择。", title: "短信：发给")
                Button("开始") { go(to) }
            }
            if !contacts.isEmpty {
                Section("联系人") {
                    ForEach(contacts, id: \.id) { c in
                        let n = PhoneNum.numberOf(c.id)
                        Button { go(n) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.displayName).foregroundStyle(Theme.text)
                                Text(n).font(.system(size: 13)).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                }
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("新建短信")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            mine = PhoneNum.mine()
            if from.isEmpty { from = mine.first ?? "" }
            contacts = ((try? Repo.characters()) ?? []).filter { ($0.parentId ?? "").isEmpty && !$0.isNpc }
        }
    }

    private func go(_ n: String) {
        let v = n.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !PhoneNum.digits(v).isEmpty else { problem = "请填写号码"; return }
        do { opened(try Sms.open(mine: from, theirs: v).id) } catch { problem = "开始失败：\(error.localizedDescription)" }
    }
}

struct SmsThreadView: View {
    let threadId: String
    @State private var thread: Row?
    @State private var msgs: [Message] = []
    @State private var draft = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var picked: PhotosPickerItem?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(threadId: String) {
        self.threadId = threadId
        _thread = State(initialValue: Sms.get(threadId))
        _msgs = State(initialValue: Sms.visible(threadId))
    }

    var body: some View {
        Group {
            if let t = thread {
                content(t)
            } else {
                ScrollView { EmptyState(title: "这段短信已不存在") }
                    .navigationTitle("短信")
            }
        }
        .onAppear(perform: reload)
    }

    private func content(_ t: Row) -> some View {
        let known = Sms.isKnown(t)
        let blocked = Sms.isBlocked(t.string("theirs"), t.string("personaId"))
        let guess = t.string("guess")
        return VStack(spacing: 0) {
            Text("我的号码 \(t.string("mine"))\(t.bool("confirmed") ? " · 已表明身份" : known ? " · 对方存过这个号码" : "")")
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                .padding(.vertical, Theme.sp2)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.sp2) {
                        ForEach(msgs, id: \.id) { m in bubble(m).id(m.id) }
                        if busy { Text("对方正在输入").font(.system(size: 12)).foregroundStyle(Theme.text3).id("busy") }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Theme.sp4)
                    .padding(.vertical, Theme.sp3)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: msgs.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) } }
            }
            if !guess.isEmpty && !known {
                VStack(alignment: .leading, spacing: Theme.sp2) {
                    Text("对方认为你是「\(guess)」。表明身份后，这段短信按你的身份继续。").font(.system(size: 13)).foregroundStyle(Theme.text)
                    HStack(spacing: Theme.sp4) {
                        Button("表明身份") { act { try Sms.confirm(t.id) }; notice = "已表明身份" }
                        Button("不表明") { act { try Sms.dismissGuess(t.id) } }.foregroundStyle(Theme.text2)
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
                .padding(Theme.sp3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface2)
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Theme.danger)
                    .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            composer
        }
        .navigationTitle(SmsText.title(t))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !known {
                        Button("表明身份") { act { try Sms.confirm(t.id) }; notice = "已表明身份" }
                    }
                    Button(blocked ? "取消拦截该号码" : "拦截该号码") { act { try Sms.setBlocked(t.string("theirs"), !blocked, t.string("personaId")) } }
                    Button("删除这段短信", role: .destructive) { confirmDelete = true }
                } label: { SvgIcon(name: "more", size: 20) }
                .accessibilityLabel("更多")
            }
        }
        .confirmationDialog("这段短信的全部消息一并删除，无法恢复。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Sms.remove(t.id); dismiss() } catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            sendPhoto(item)
        }
        .onReceive(NotificationCenter.default.publisher(for: .eiraChatChanged)) { _ in reload() }
    }

    @ViewBuilder
    private func bubble(_ m: Message) -> some View {
        if m.kind == "notice" {
            Text(m.content.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))).font(.system(size: 12)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity)
        } else {
            let mine = m.role == .user
            HStack {
                if mine { Spacer(minLength: 48) }
                VStack(alignment: .leading, spacing: 4) {
                    if m.kind == "image" {
                        if !m.imageId.isEmpty {
                            LocalImage(id: m.imageId, maxPixel: 600, fit: true).frame(maxWidth: 200, maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                        } else {
                            Text(m.row.string("media") == "error" || m.isError ? "图片生成失败" : "图片生成中").font(.system(size: 13)).foregroundStyle(Theme.text2)
                        }
                    } else {
                        Text(m.content).font(.system(size: Theme.bubbleFont))
                            .foregroundStyle(mine ? Theme.bubbleMineText : Theme.bubbleTheirsText)
                            .textSelection(.enabled)
                        let tr = m.row.string("translation").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !tr.isEmpty && tr != m.content {
                            Text(tr).font(.system(size: 12)).foregroundStyle(mine ? Theme.bubbleMineText.opacity(0.7) : Theme.text2)
                        }
                    }
                }
                .padding(.horizontal, Theme.bubblePadX).padding(.vertical, Theme.bubblePadY)
                .background(mine ? Theme.bubbleMine : Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
                if !mine { Spacer(minLength: 48) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Theme.sp2) {
            PhotosPicker(selection: $picked, matching: .images) { SvgIcon(name: "image", size: 22) }
                .accessibilityLabel("发送图片")
            TextField("短信", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, Theme.sp3).padding(.vertical, Theme.sp2)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .accessibilityLabel("发送")
            } else {
                Button(action: reply) { SvgIcon(name: "reply", size: 22) }
                    .disabled(busy)
                    .accessibilityLabel("回复")
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp3)
        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); reload() } catch { problem = "操作失败：\(error.localizedDescription)" }
    }

    private func reload() {
        thread = Sms.get(threadId)
        msgs = Sms.visible(threadId)
        if let t = thread, (t.number("unread") ?? 0) > 0 { try? Sms.markRead(t.id) }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try Sms.send(threadId, text: text)
            draft = ""
            problem = nil
            reload()
        } catch { problem = "写入失败，这条短信未保存：\(error.localizedDescription)" }
    }

    private func sendPhoto(_ item: PhotosPickerItem) {
        let id = threadId
        Task { @MainActor in
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw StoreError(message: "无法读取所选图片") }
                let imageId = try Images.save(data)
                let m = try Sms.sendImage(id, imageId: imageId)
                reload()
                // 选了单独的识图接口时，这一张交给它读成描述（与聊天里发图同一档）
                if let m, m.row.string("vision") == "pending" {
                    Task.detached { _ = try? await Vision.describe(messageId: m.id) }
                }
            } catch { problem = "图片处理失败：\(error.localizedDescription)" }
        }
    }

    private func reply() {
        guard !busy else { return }
        busy = true
        problem = nil
        let id = threadId
        Task { @MainActor in
            do {
                try await Sms.reply(threadId: id) { _ in Task { @MainActor in reload() } }
            } catch is CancellationError {
            } catch let e as AIError where e.cancelled {
            } catch { problem = error.localizedDescription }
            busy = false
            reload()
        }
    }
}

struct SmsBlockedView: View {
    @State private var numbers: [String] = []
    @State private var caught: [Sms.Caught] = []
    @State private var problem: String?

    var body: some View {
        List {
            if !numbers.isEmpty {
                Section("拦截的号码") {
                    ForEach(numbers, id: \.self) { n in
                        HStack {
                            Text(n)
                            Spacer()
                            Button("取消拦截") {
                                do { try Sms.setBlocked(n, false); reload() } catch { problem = "操作失败：\(error.localizedDescription)" }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            if caught.isEmpty {
                EmptyState(title: "没有拦截的短信").listRowBackground(Color.clear)
            } else {
                Section("拦截的短信") {
                    ForEach(caught) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.thread.string("theirs")).font(.system(size: 15, weight: .semibold))
                            Text("\(SmsText.preview(c.msg)) · \(SmsText.time(c.msg.createdAt)) · 发往 \(c.thread.string("mine"))")
                                .font(.system(size: 13)).foregroundStyle(Theme.text2)
                        }
                    }
                }
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("已拦截")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func reload() {
        numbers = Sms.blockedOf()
        caught = Sms.intercepted()
    }
}

struct SmsNumbersView: View {
    @State private var list: [String] = []
    @State private var names: [String: String] = [:]
    @State private var adding = false
    @State private var newNumber = ""
    @State private var removing: String?
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                ForEach(list, id: \.self) { n in
                    NavigationLink { SmsSavedView(number: n) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n)
                            Text(names[n].map { "\($0) 存过这个号码" } ?? "没有角色存过这个号码").font(.system(size: 13)).foregroundStyle(Theme.text2)
                        }
                    }
                    .swipeActions {
                        if list.count > 1 { Button("移除", role: .destructive) { removing = n } }
                    }
                }
            } footer: {
                Text("号码属于当前身份。点一个号码，勾选哪些角色存过它：存过的角色收到这个号码的短信时知道是你；没存过的角色只看到号码，记得你、记得你们的关系，但不知道发短信的是你，直到你表明身份或者它认出你。")
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("我的号码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("添加") { newNumber = ""; adding = true } }
        }
        .alert("添加号码", isPresented: $adding) {
            TextField("留空则自动生成", text: $newNumber).keyboardType(.phonePad)
            Button("取消", role: .cancel) {}
            Button("添加") {
                do { try PhoneNum.addMine(newNumber); reload() } catch { problem = error.localizedDescription }
            }
        } message: { Text("可以添加任意多个号码。用不同的号码发短信，对方看到的是不同的号码。") }
        .confirmationDialog("移除这个号码。已有的短信保留。", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { n in
            Button("移除", role: .destructive) {
                do { try PhoneNum.removeMine(n); reload() } catch { problem = error.localizedDescription }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        list = PhoneNum.mine()
        var out: [String: String] = [:]
        for n in list {
            let who = PhoneNum.savedBy(n).compactMap { (try? Repo.character($0)) ?? nil }.map(\.displayName)
            if !who.isEmpty { out[n] = who.joined(separator: "、") }
        }
        names = out
    }
}

/// 哪些角色存过这个号码（网页版 4.392）。存过的，用这个号码发短信时它知道是你
struct SmsSavedView: View {
    let number: String
    @State private var chars: [Character] = []
    @State private var saved: [String] = []
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                ForEach(chars, id: \.id) { c in
                    Toggle(c.displayName, isOn: Binding(get: { saved.contains(c.id) }, set: { on in
                        do { try PhoneNum.setSaved(number, c.id, on); saved = PhoneNum.savedBy(number) }
                        catch { problem = "保存失败：\(error.localizedDescription)" }
                    }))
                }
            } footer: {
                Text("勾选的角色存过这个号码：用这个号码发短信时，该角色知道是你，按你的身份注入。未勾选的角色只看到号码，可以表明身份。")
            }
            ProblemSection(text: problem)
        }
        .navigationTitle(number)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            chars = ((try? Repo.characters()) ?? []).filter { ($0.parentId ?? "").isEmpty }
            saved = PhoneNum.savedBy(number)
        }
    }
}
