import PhotosUI
import SwiftUI

/// 角色手机（网页版 apps/theirs）。拿起角色那台手机看一眼：先挑角色，看见的第一屏是锁屏，解开之后是一块桌面。
/// 书架、身体状态、今天这些数据在别处有主，这里只读；生成的东西（会话、相册、备忘录、浏览记录）是这台手机自己的。
struct TheirsPickView: View {
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let chars = ((try? Repo.characters()) ?? []).filter { !$0.isNpc && ($0.parentId ?? "").isEmpty && !$0.archived }
        Group {
            if chars.isEmpty {
                EmptyState(title: "还没有角色", desc: "在「联系」中建立角色之后，可以在这里查看属于该角色的手机。")
            } else {
                List {
                    Section {
                        ForEach(chars) { c in
                            NavigationLink { TheirsPhoneView(charId: c.id) } label: {
                                HStack(spacing: Theme.sp3) {
                                    Avatar(imageId: c.avatar, name: c.name, size: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.displayName).foregroundStyle(Theme.text)
                                        Text(bits(c)).font(.caption).foregroundStyle(Theme.text3).lineLimit(1)
                                    }
                                }
                            }
                        }
                    } header: { Text("共 \(chars.count) 个角色") } footer: {
                        HelpNote("这里只做查看。书架、身体状态与今天的内容在各自的设定页中修改，本页不作改动。", title: "角色手机")
                    }
                }
            }
        }
        .navigationTitle("角色手机")
        .onAppear { tick += 1 }
    }

    private func bits(_ c: Character) -> String {
        var out: [String] = []
        if Theirs.isOpen(c.id) { out.append("已解锁") }
        if Health.charOn(c) { out.append("身体状态") }
        if DayPlan.isOn(c) { out.append("今天") }
        return out.isEmpty ? "锁屏已启用" : out.joined(separator: " · ")
    }
}

/// 一台手机：锁着就是锁屏，解开是桌面。解开只在这一次打开应用期间有效
struct TheirsPhoneView: View {
    let charId: String
    @State private var unlocked = false

    var body: some View {
        Group {
            if unlocked { TheirsHomeView(charId: charId) { unlocked = false } }
            else { TheirsLockView(charId: charId) { unlocked = true } }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { unlocked = Theirs.isOpen(charId) }
    }
}

/// 壁纸：换过的优先，没换过用角色卡的封面；都没有就留底色
private struct TheirsWall: View {
    let imageId: String

    var body: some View {
        GeometryReader { g in
            if imageId.isEmpty {
                Theme.surface2
            } else {
                LocalImage(id: imageId, maxPixel: 1400)
                    .frame(width: g.size.width, height: g.size.height).clipped()
                    .overlay(Color.black.opacity(0.28))
            }
        }
        .ignoresSafeArea()
    }
}

struct TheirsLockView: View {
    let charId: String
    var onOpen: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var wrong = 0
    @State private var hint: String?
    @State private var giveUp = false
    @State private var revealed: String?
    @State private var tick = 0

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "del"]

    var body: some View {
        let _ = tick
        if let char = (try? Repo.character(charId)) ?? nil, let lock = Theirs.lock(charId) {
            let wall = Theirs.wallShown(char)
            let fg: Color = wall.isEmpty ? Theme.text : .white
            ZStack {
                TheirsWall(imageId: wall)
                VStack(spacing: Theme.sp4) {
                    Spacer(minLength: Theme.sp6)
                    Avatar(imageId: char.avatar, name: char.name, size: 88)
                    HStack(spacing: 14) {
                        ForEach(0..<lock.code.count, id: \.self) { i in
                            Circle().strokeBorder(fg, lineWidth: 1.2)
                                .background(Circle().fill(i < code.count ? fg : .clear))
                                .frame(width: 13, height: 13)
                        }
                    }
                    Text(wrong > 0 ? "密码错误，已尝试 \(wrong) 次" : "\(lock.code.count) 位密码")
                        .font(.footnote).foregroundStyle(fg.opacity(0.85))
                    if let hint {
                        Text(hint).font(.footnote).foregroundStyle(fg).multilineTextAlignment(.center).padding(.horizontal, Theme.sp6)
                    }
                    if let revealed {
                        Text(revealed).font(.footnote).foregroundStyle(fg).multilineTextAlignment(.center).padding(.horizontal, Theme.sp6)
                    }
                    Spacer()
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 22), count: 3), spacing: 16) {
                        ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                            if k.isEmpty {
                                Color.clear.frame(width: 72, height: 72)
                            } else {
                                Button { tap(k, lock: lock) } label: {
                                    Group {
                                        if k == "del" { Image(systemName: "delete.left") } else { Text(k).font(.system(size: 28, weight: .light)) }
                                    }
                                    .frame(width: 72, height: 72)
                                    .foregroundStyle(fg)
                                    .overlay(Circle().strokeBorder(fg.opacity(k == "del" ? 0 : 0.5), lineWidth: 1))
                                    .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(k == "del" ? "删除" : k)
                            }
                        }
                    }
                    VStack(spacing: Theme.sp2) {
                        if lock.left > 0 {
                            Button("向\(char.name)询问线索（还有 \(lock.left) 条）") {
                                do { hint = try Theirs.nextHint(charId) ?? "该角色没有更多线索了" } catch { hint = "未能保存：\(error.localizedDescription)" }
                                tick += 1
                            }
                        } else {
                            Button("直接查看密码") { giveUp = true }
                        }
                        Button("退出这台手机") { dismiss() }
                    }
                    .font(.footnote).foregroundStyle(fg)
                    .padding(.bottom, Theme.sp4)
                }
            }
            .confirmationDialog("查看后这台手机将直接打开，不再需要推测。", isPresented: $giveUp, titleVisibility: .visible) {
                Button("查看") {
                    revealed = "密码是 \(lock.code)\(lock.why.isEmpty ? "" : "。\(lock.why)")"
                    Theirs.open(charId)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { onOpen() }
                }
            }
        } else {
            EmptyState(title: "这个角色已经不在了")
        }
    }

    private func tap(_ k: String, lock: Theirs.Lock) {
        if k == "del" { if !code.isEmpty { code.removeLast() }; return }
        guard code.count < lock.code.count else { return }
        code += k
        guard code.count == lock.code.count else { return }
        if Theirs.tryCode(charId, code) {
            Theirs.open(charId)
            onOpen()
        } else {
            wrong += 1
            code = ""
        }
    }
}

/// 一块桌面：壁纸铺满、顶上时间、中间一排应用、底下一条你的工具（生成、外观、锁上、退出）
struct TheirsHomeView: View {
    let charId: String
    var onLock: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tick = 0

    struct Tile: Identifiable { let id: String; let icon: String; let label: String }

    static let apps: [Tile] = [
        .init(id: "chats", icon: "message", label: "聊天"), .init(id: "album", icon: "camera", label: "相册"),
        .init(id: "notes", icon: "note.text", label: "备忘录"), .init(id: "browser", icon: "magnifyingglass", label: "浏览器"),
        .init(id: "body", icon: "waveform.path.ecg", label: "身体状态"), .init(id: "day", icon: "calendar", label: "今天"),
    ]

    var body: some View {
        let _ = tick
        if let char = (try? Repo.character(charId)) ?? nil {
            let wall = Theirs.wallShown(char)
            let fg: Color = wall.isEmpty ? Theme.text : .white
            let tiles = Self.apps.filter { t in
                switch t.id {
                case "body": return Health.charOn(char)
                case "day": return DayPlan.isOn(char)
                default: return true
                }
            }
            ZStack {
                TheirsWall(imageId: wall)
                VStack(spacing: Theme.sp5) {
                    VStack(spacing: 2) {
                        Text(clock(char)).font(.system(size: 56, weight: .light)).monospacedDigit()
                        Text("\(DayPlan.weekday(char))　\(char.name)").font(.footnote)
                    }
                    .foregroundStyle(fg)
                    .padding(.top, Theme.sp6)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.sp3), count: 4), spacing: Theme.sp5) {
                        ForEach(tiles) { t in
                            NavigationLink { page(t.id) } label: { cell(t, fg: fg) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.pad)
                    Spacer()
                    HStack {
                        NavigationLink { TheirsMakeView(charId: charId) } label: { dock("sparkles", "生成") }
                        NavigationLink { TheirsLookView(charId: charId) } label: { dock("photo", "外观") }
                        Button { Theirs.relock(charId); onLock() } label: { dock("lock", "锁上") }
                        Button { dismiss() } label: { dock("chevron.left", "退出") }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(fg)
                    .padding(.vertical, Theme.sp3)
                    .background(Color.black.opacity(wall.isEmpty ? 0.04 : 0.22), in: RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
                    .padding(.horizontal, Theme.pad)
                    .padding(.bottom, Theme.sp3)
                }
            }
            .onAppear { tick += 1 }
        } else {
            EmptyState(title: "这个角色已经不在了")
        }
    }

    private func clock(_ char: Character) -> String {
        let f = DateFormatter()
        f.timeZone = DayPlan.zone(char)
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    private func cell(_ t: Tile, fg: Color) -> some View {
        let over = Theirs.icon(charId, t.id)
        return VStack(spacing: 6) {
            Group {
                if !over.imageId.isEmpty {
                    LocalImage(id: over.imageId, maxPixel: 180)
                } else {
                    ZStack {
                        Theme.surface
                        Image(systemName: over.icon.isEmpty ? t.icon : over.icon).font(.system(size: 22)).foregroundStyle(Theme.text)
                    }
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            Text(over.name.isEmpty ? t.label : over.name).font(.system(size: 11)).foregroundStyle(fg).lineLimit(1)
        }
    }

    private func dock(_ icon: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 18))
            Text(label).font(.system(size: 11))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func page(_ id: String) -> some View {
        switch id {
        case "chats": TheirsChatsView(charId: charId)
        case "album": TheirsAlbumView(charId: charId)
        case "notes": TheirsNotesView(charId: charId)
        case "browser": TheirsBrowserView(charId: charId)
        case "body": TheirsBodyView(charId: charId)
        default: TheirsDayView(charId: charId)
        }
    }
}

private struct MakeLink: View {
    let charId: String
    var body: some View { NavigationLink("生成") { TheirsMakeView(charId: charId) } }
}

// MARK: - 备忘录与浏览器

struct TheirsNotesView: View {
    let charId: String
    @State private var tick = 0
    @State private var dropping: Int?
    @State private var problem: String?

    var body: some View {
        let _ = tick
        let list = Theirs.notes(charId)
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if list.isEmpty {
                EmptyState(title: "还没有备忘录", desc: "在右上角「生成」中依据该角色的设定生成。").listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(Array(list.enumerated()), id: \.offset) { i, n in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(n.title.isEmpty ? "无标题" : n.title).font(.system(size: 15, weight: .medium))
                            if !n.text.isEmpty { Text(n.text).font(.system(size: 14)).foregroundStyle(Theme.text2) }
                            let trans = [n.titleTrans, n.textTrans].filter { !$0.isEmpty }.joined(separator: "\n")
                            if !trans.isEmpty { Text(trans).font(.caption).foregroundStyle(Theme.text3) }
                        }
                        .swipeActions { Button("删除", role: .destructive) { dropping = i } }
                    }
                } header: { Text("共 \(list.count) 条") } footer: {
                    HelpNote("这些内容依据该角色的设定生成，不是该角色在对话中说过的话。向左滑动可以删除一条。", title: "角色手机的备忘录")
                }
            }
        }
        .navigationTitle("备忘录")
        .toolbar { ToolbarItem(placement: .primaryAction) { MakeLink(charId: charId) } }
        .onAppear { tick += 1 }
        .confirmationDialog("删除这一条。删除后无法恢复，可以重新生成。", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let i = dropping { do { try Theirs.removeNote(charId, at: i); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" } }
                tick += 1
            }
        }
    }
}

struct TheirsBrowserView: View {
    let charId: String
    @State private var tick = 0
    @State private var dropping: Int?
    @State private var problem: String?

    var body: some View {
        let _ = tick
        let list = Theirs.visits(charId)
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if list.isEmpty {
                EmptyState(title: "还没有搜索记录", desc: "在右上角「生成」中依据该角色的设定生成。").listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(Array(list.enumerated()), id: \.offset) { i, v in
                        HStack(spacing: Theme.sp3) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.query)
                                if !v.queryTrans.isEmpty { Text(v.queryTrans).font(.caption).foregroundStyle(Theme.text3) }
                                Text(v.site.isEmpty ? "没有打开结果" : v.site).font(.caption).foregroundStyle(Theme.text3)
                            }
                        }
                        .swipeActions { Button("删除", role: .destructive) { dropping = i } }
                    }
                } header: { Text("搜索记录 \(list.count) 条") } footer: {
                    HelpNote("新的在上。这些内容依据该角色的设定生成，其中的站点名称不指向真实网页。", title: "角色手机的浏览器")
                }
            }
        }
        .navigationTitle("浏览器")
        .toolbar { ToolbarItem(placement: .primaryAction) { MakeLink(charId: charId) } }
        .onAppear { tick += 1 }
        .confirmationDialog("删除这一条。删除后无法恢复，可以重新生成。", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let i = dropping { do { try Theirs.removeVisit(charId, at: i); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" } }
                tick += 1
            }
        }
    }
}

// MARK: - 聊天

struct TheirsChatsView: View {
    let charId: String
    @State private var tick = 0
    @State private var adding = false
    @State private var name = ""
    @State private var problem: String?
    @State private var dropping: Theirs.PhoneChat?
    @State private var opened: String?

    var body: some View {
        let _ = tick
        let real = ((try? Repo.chats()) ?? []).filter { !$0.isGroup && $0.characterIds == [charId] }
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
        let made = Theirs.chatsOf(charId)
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if real.isEmpty && made.isEmpty {
                EmptyState(title: "还没有会话", desc: "在右上角「生成」中生成这台手机里的会话列表，或者直接给某个人发消息。").listRowBackground(Color.clear)
            }
            if !real.isEmpty {
                Section {
                    ForEach(real) { c in
                        NavigationLink { TheirsRealView(chatId: c.id) } label: {
                            let me = ((try? Repo.personas()) ?? []).first(where: { $0.id == c.personaId })
                            let remark = c.row.string("charRemark").trimmingCharacters(in: .whitespaces)
                            HStack(spacing: Theme.sp3) {
                                Avatar(imageId: me?.avatar ?? "", name: me?.name ?? "我", size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(remark.isEmpty ? (me?.name ?? "我") : remark)
                                    Text(lastText(c.id)).font(.caption).foregroundStyle(Theme.text3).lineLimit(1)
                                }
                            }
                        }
                    }
                } header: { Text("与你") } footer: {
                    HelpNote("「与你」是真实的对话记录，在这台手机上只作查看。", title: "角色手机的聊天")
                }
            }
            if !made.isEmpty {
                Section {
                    ForEach(made) { c in
                        NavigationLink { TheirsChatView(chatId: c.id) } label: {
                            let npc = c.npcId.isEmpty ? nil : (try? Repo.character(c.npcId)) ?? nil
                            HStack(spacing: Theme.sp3) {
                                Avatar(imageId: npc?.avatar ?? "", name: c.name, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name)
                                    Text([c.preview.isEmpty ? "还没有内容" : c.preview, c.filled ? "\(c.lines.count) 条" : "点击后生成"].joined(separator: " · "))
                                        .font(.caption).foregroundStyle(Theme.text3).lineLimit(1)
                                }
                            }
                        }
                        .swipeActions { Button("删除", role: .destructive) { dropping = c } }
                    }
                } header: { Text("其他 \(made.count) 条") } footer: {
                    HelpNote("除「与你」之外的会话依据该角色的设定生成，其中的人名与已有角色一致时会关联到该角色。右上角「发消息」可以直接给某个人发消息。", title: "角色手机的聊天")
                }
            }
        }
        .navigationTitle("聊天")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("发消息") { name = ""; adding = true } }
            ToolbarItem(placement: .primaryAction) { MakeLink(charId: charId) }
        }
        .navigationDestination(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
            if let opened { TheirsChatView(chatId: opened) }
        }
        .onAppear { tick += 1 }
        .sheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    let have = Set(made.map(\.name))
                    let known = Theirs.known(charId).filter { !have.contains($0.name) }
                    if !known.isEmpty {
                        Section("该角色认识的人") {
                            ForEach(known.indices, id: \.self) { i in
                                let k = known[i]
                                Button { start(k.id, k.name) } label: { LabeledContent(k.name, value: k.label) }
                            }
                        }
                    }
                    Section {
                        TextField("对方的名称", text: $name)
                        Button("发起会话") {
                            let n = name.trimmingCharacters(in: .whitespaces)
                            let hit = ((try? Repo.characters()) ?? []).first(where: { $0.name == n })
                            start(hit?.id ?? "", n)
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    } header: { Text("其他人") } footer: {
                        HelpNote("填写对方的名称。名称与已有角色一致时会关联到该角色。", title: "角色手机：发消息")
                    }
                }
                .navigationTitle("发消息给")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { adding = false } } }
            }
        }
        .confirmationDialog("删除这条会话。删除后无法恢复，可以重新生成。", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
                            titleVisibility: .visible, presenting: dropping) { c in
            Button("删除", role: .destructive) {
                do { try Theirs.removeChat(c.id); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                tick += 1
            }
        }
    }

    private func lastText(_ chatId: String) -> String {
        guard let m = ((try? Repo.messages(chatId: chatId, limit: 1)) ?? []).last else { return "还没有消息" }
        return MsgPreview.text(m)
    }

    private func start(_ npcId: String, _ who: String) {
        do {
            let c = try Theirs.startChat(charId, npcId: npcId, name: who)
            adding = false
            problem = nil
            tick += 1
            opened = c.id
        } catch { problem = error.localizedDescription; adding = false }
    }
}

/// 一段和别人的会话。进来才生成；在这里打出去的那一句是代发：以该角色的身份发给对方，一次发送一次请求要对方回话
struct TheirsChatView: View {
    let chatId: String
    @State private var tick = 0
    @State private var busy = false
    @State private var err: String?
    @State private var failed = "make"
    @State private var draft = ""
    @State private var mode = Theirs.proxyUnaware
    @State private var regen = false

    var body: some View {
        let _ = tick
        if let row = Theirs.chat(chatId) {
            let char = (try? Repo.character(row.charId)) ?? nil
            let npc = row.npcId.isEmpty ? nil : (try? Repo.character(row.npcId)) ?? nil
            let lines = row.lines
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Theme.sp2) {
                            if busy && lines.isEmpty {
                                HStack { ProgressView(); Text("正在生成这一段对话").font(.footnote).foregroundStyle(Theme.text3) }.padding(.top, Theme.sp6)
                            }
                            if let err {
                                VStack(spacing: Theme.sp2) {
                                    Text(err).font(.footnote).foregroundStyle(Theme.danger)
                                    Button(failed == "reply" ? "让对方回复" : "再试一次") { failed == "reply" ? reply() : make() }
                                        .disabled(busy)
                                }
                                .padding(Theme.pad)
                            }
                            if !busy && lines.isEmpty && err == nil {
                                EmptyState(title: "还没有内容", desc: "在下面写一句，以\(char?.name ?? "该角色")的身份发给\(row.name)。")
                                Button("生成一整段") { make() }
                            }
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                                let mine = l.from == "char"
                                HStack(alignment: .top, spacing: Theme.sp2) {
                                    if mine { Spacer(minLength: 40) }
                                    if !mine { Avatar(imageId: npc?.avatar ?? "", name: row.name, size: 28) }
                                    VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                                        Text(l.text).font(.system(size: 15))
                                            .padding(.horizontal, Theme.bubblePadX).padding(.vertical, Theme.bubblePadY)
                                            .background(mine ? Theme.surface3 : Theme.surface2,
                                                        in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
                                        if !l.textTrans.isEmpty { Text(l.textTrans).font(.caption).foregroundStyle(Theme.text3) }
                                        if !l.rejected.isEmpty {
                                            Text(l.rejected == "blocked" ? "被对方拒收" : "未送达").font(.caption2).foregroundStyle(Theme.danger)
                                        }
                                    }
                                    if mine { Avatar(imageId: char?.avatar ?? "", name: char?.name ?? "", size: 28) }
                                    if !mine { Spacer(minLength: 40) }
                                }
                                .id(i)
                            }
                            if busy && !lines.isEmpty {
                                HStack { ProgressView(); Text("对方正在回复").font(.footnote).foregroundStyle(Theme.text3) }
                            }
                        }
                        .padding(Theme.pad)
                    }
                    .onChange(of: lines.count) { _, n in if n > 0 { withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) } } }
                    .onAppear { if !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) } }
                }
                VStack(spacing: Theme.sp2) {
                    Picker("代发", selection: $mode) {
                        Text("角色不知道").tag(Theirs.proxyUnaware)
                        Text("角色知道").tag(Theirs.proxyAware)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField("以\(char?.name ?? "该角色")的身份发送", text: $draft, axis: .vertical)
                            .lineLimit(1...4).textFieldStyle(.roundedBorder).disabled(busy)
                        Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)) }
                            .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("发送")
                    }
                    Text("每发送一次调用一次副用接口，由对方回复。").font(.caption2).foregroundStyle(Theme.text3)
                    HelpNote("这一段对话依据该角色与对方的设定生成，生成的内容不进入任何聊天上下文。在此处发送的消息是代发：以该角色的身份写入这一段，每发送一次调用一次副用接口，由对方回复；发送失败时已写入的消息保留。「重新生成」会整段替换，包括自行发送的消息。", title: "角色手机：代发")
                }
                .padding(Theme.pad)
                .background(Theme.background)
            }
            .navigationTitle(row.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(busy ? "请稍候" : "重新生成") { if lines.isEmpty { make() } else { regen = true } }.disabled(busy)
                }
            }
            .confirmationDialog("当前这一段对话将被整段替换，其中自行发送的消息也会一并删除。", isPresented: $regen, titleVisibility: .visible) {
                Button("重新生成", role: .destructive) { make() }
            }
            .onAppear {
                mode = Theirs.proxyMode(row.charId)
                // 第一次进来、还没有正文时生成一次（用户点进来这一下就是要它）
                if !row.filled && !busy && err == nil { make() }
            }
        } else {
            EmptyState(title: "这条会话已经不在了")
        }
    }

    private func make() {
        busy = true; err = nil
        Task { @MainActor in
            do { _ = try await Theirs.makeChat(chatId) } catch { err = error.localizedDescription; failed = "make" }
            busy = false; tick += 1
        }
    }

    private func reply() {
        busy = true; err = nil
        Task { @MainActor in
            do { _ = try await Theirs.reply(chatId) } catch { err = error.localizedDescription; failed = "reply" }
            busy = false; tick += 1
        }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        do {
            let rejected = try Theirs.sendOther(chatId, t, mode: mode)
            draft = ""
            tick += 1
            if !rejected.isEmpty {
                err = rejected == "blocked" ? "对方已将该角色拉黑，消息被拒收" : "对方已将该角色从联系人中删除，消息未送达"
                return
            }
            reply()
        } catch { err = "未能保存：\(error.localizedDescription)"; failed = "make" }
    }
}

/// 和你的那一段：真数据，在这台手机上只作查看
struct TheirsRealView: View {
    let chatId: String

    var body: some View {
        let msgs = ((try? Repo.messages(chatId: chatId)) ?? []).filter { $0.kind != "notice" && !$0.isRecalled }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.sp2) {
                    if msgs.isEmpty { EmptyState(title: "还没有消息") }
                    ForEach(msgs) { m in
                        let mine = m.role == .char
                        HStack {
                            if mine { Spacer(minLength: 40) }
                            Text(MsgPreview.text(m)).font(.system(size: 15))
                                .padding(.horizontal, Theme.bubblePadX).padding(.vertical, Theme.bubblePadY)
                                .background(mine ? Theme.surface3 : Theme.surface2,
                                            in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
                            if !mine { Spacer(minLength: 40) }
                        }
                        .id(m.id)
                    }
                }
                .padding(Theme.pad)
            }
            .onAppear { if let last = msgs.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
        .navigationTitle("与你")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 相册

struct TheirsAlbumView: View {
    let charId: String
    @State private var tick = 0
    @State private var at = ""
    @State private var code = ""
    @State private var making: (id: String, name: String, code: String)?
    @State private var editing: String?
    @State private var problem: String?
    @State private var dropAlbum = false

    var body: some View {
        let _ = tick
        let albums = Theirs.albums(charId)
        let book = albums.first(where: { $0.id == at })
        let locked = !at.isEmpty && !Theirs.albumOpen(charId, at)
        let photos = Theirs.inAlbum(charId, at)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sp3) {
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal, Theme.pad) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.sp2) {
                        chip("未归类 \(Theirs.inAlbum(charId, "").count)", on: at.isEmpty) { at = "" }
                        ForEach(albums) { a in
                            chip("\(a.code.isEmpty ? "" : "· ")\(a.name) \(Theirs.inAlbum(charId, a.id).count)", on: at == a.id) { at = a.id; code = "" }
                        }
                        chip("新建", on: false) { making = ("", "", "") }
                    }
                    .padding(.horizontal, Theme.pad)
                }
                if let book {
                    HStack {
                        Image(systemName: book.code.isEmpty ? "folder" : "lock").foregroundStyle(Theme.text3)
                        Text(book.name)
                        Spacer()
                        Button("设置") { making = (book.id, book.name, book.code) }
                        Button("删除", role: .destructive) { dropAlbum = true }.foregroundStyle(Theme.dangerText)
                    }
                    .font(.footnote)
                    .padding(.horizontal, Theme.pad)
                }
                if locked {
                    VStack(spacing: Theme.sp2) {
                        Text("这一本设了密码。输入密码后可以查看。").font(.footnote).foregroundStyle(Theme.text2)
                        SecureField("输入这一本的密码", text: $code).textFieldStyle(.roundedBorder)
                        Button("打开") {
                            if Theirs.openAlbum(charId, at, code: code) { problem = nil } else { problem = "密码不对" }
                            code = ""; tick += 1
                        }
                    }
                    .padding(.horizontal, Theme.pad)
                } else if photos.isEmpty {
                    EmptyState(title: at.isEmpty ? "还没有照片" : "这一本还是空的",
                               desc: at.isEmpty ? "在「生成」中依据该角色的设定生成这台手机里的照片。" : "把未归类里的照片移进来，或者重新生成。")
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.sp2), count: 2), spacing: Theme.sp2) {
                        ForEach(photos) { p in
                            Button { editing = p.id } label: { shot(p) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.pad)
                }
                Toggle("允许该角色在对话中存照片", isOn: Binding(get: { Theirs.keepOn(charId) }, set: { v in
                    do { try Theirs.setKeepOn(charId, v); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                    tick += 1
                }))
                .padding(.horizontal, Theme.pad)
                Text("开启会在每轮提示词中增加一条说明，因此默认关闭。").font(.caption).foregroundStyle(Theme.text3)
                    .padding(.horizontal, Theme.pad)
                HelpNote("生成的照片只有一句描述，可以为某一张挂上真实图片。标有「你发的」的是该角色从对话中存下的照片。相册密码以明文保存在本机，只用于不直接显示内容，不是加密。", title: "角色手机的相册")
            }
            .padding(.vertical, Theme.sp3)
        }
        .background(Theme.background)
        .navigationTitle("相册")
        .toolbar { ToolbarItem(placement: .primaryAction) { MakeLink(charId: charId) } }
        .onAppear { tick += 1 }
        .sheet(isPresented: Binding(get: { making != nil }, set: { if !$0 { making = nil } })) {
            AlbumBookEditor(initial: making ?? ("", "", "")) { name, c in
                do {
                    if let id = making?.id, !id.isEmpty { try Theirs.updateAlbum(charId, id, name: name, code: c) }
                    else { try Theirs.addAlbum(charId, name: name, code: c) }
                    problem = nil
                    making = nil
                } catch { problem = error.localizedDescription }
                tick += 1
            }
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil; tick += 1 } })) {
            if let editing { TheirsPhotoEditor(charId: charId, photoId: editing) }
        }
        .confirmationDialog("删除这本相册。里面的照片不会删除，会退回未归类。", isPresented: $dropAlbum, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Theirs.removeAlbum(charId, at); at = ""; problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                tick += 1
            }
        }
    }

    private func chip(_ label: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label).font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(on ? Theme.onAccent : Theme.text)
                .background(on ? Theme.accent : Theme.surface2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func shot(_ p: Theirs.Photo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if p.imageId.isEmpty {
                    ZStack { Theme.surface2; Image(systemName: "photo").foregroundStyle(Theme.text3) }
                } else {
                    LocalImage(id: p.imageId, maxPixel: 400)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity).aspectRatio(1, contentMode: .fill).clipped()
            .clipShape(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
            Text(p.note.isEmpty ? "没有描述" : p.note).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(2)
            if !p.noteTrans.isEmpty { Text(p.noteTrans).font(.caption2).foregroundStyle(Theme.text3).lineLimit(2) }
            if p.from == "you" { Text(p.cropped ? "你发的 · 已裁" : "你发的").font(.caption2).foregroundStyle(Theme.text3) }
        }
    }
}

private struct AlbumBookEditor: View {
    let initial: (id: String, name: String, code: String)
    var save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
                Section {
                    TextField("密码，可留空", text: $code)
                } footer: {
                    HelpNote("留空表示不设密码。密码以明文保存在本机，只用于不直接显示内容，不是加密。", title: "角色手机：相册密码")
                }
            }
            .navigationTitle(initial.id.isEmpty ? "新建相册" : "相册设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save(name, code) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onAppear { name = initial.name; code = initial.code }
        }
    }
}

private struct TheirsPhotoEditor: View {
    let charId: String
    let photoId: String
    @Environment(\.dismiss) private var dismiss
    @State private var tick = 0
    @State private var note = ""
    @State private var problem: String?
    @State private var picking = false
    @State private var picked: PhotosPickerItem?
    @State private var viewing = false
    @State private var dropping = false

    var body: some View {
        let _ = tick
        NavigationStack {
            Form {
                if let p = Theirs.photos(charId).first(where: { $0.id == photoId }) {
                    if let problem { Text(problem).foregroundStyle(Theme.danger) }
                    if !p.imageId.isEmpty {
                        LocalImage(id: p.imageId, maxPixel: 900, fit: true).frame(maxWidth: .infinity, maxHeight: 300)
                            .onTapGesture { viewing = true }
                            .listRowBackground(Color.clear)
                    }
                    Section("描述") {
                        TextField("描述", text: $note, axis: .vertical)
                            .onChange(of: note) { _, v in act { try Theirs.updatePhoto(charId, photoId, ["note": .string(v)]) } }
                    }
                    Section {
                        Picker("放进哪一本", selection: Binding(get: { p.albumId }, set: { v in act { try Theirs.updatePhoto(charId, photoId, ["albumId": .string(v)]) } })) {
                            Text("未归类").tag("")
                            ForEach(Theirs.albums(charId)) { a in Text(a.name).tag(a.id) }
                        }
                        Button(p.imageId.isEmpty ? "挂上图片" : "换一张图片") { picking = true }
                        if !p.imageId.isEmpty {
                            Button("取下图片") { act { try Theirs.updatePhoto(charId, photoId, ["imageId": .null, "cropped": .bool(false)]) } }
                        }
                    }
                    Section {
                        Button("删除这一张", role: .destructive) { dropping = true }.foregroundStyle(Theme.dangerText)
                    }
                } else {
                    Text("这一张已经不在了").foregroundStyle(Theme.text3)
                }
            }
            .navigationTitle("这一张")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { note = Theirs.photos(charId).first(where: { $0.id == photoId })?.note ?? "" }
            .photosPicker(isPresented: $picking, selection: $picked, matching: .images)
            .onChange(of: picked) { _, item in
                guard let item else { return }
                picked = nil
                Task { @MainActor in
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw StoreError(message: "读不到这张图片") }
                        let id = try Images.save(data)
                        try Theirs.updatePhoto(charId, photoId, ["imageId": .string(id), "cropped": .bool(false)])
                        problem = nil
                    } catch { problem = "未能保存：\(error.localizedDescription)" }
                    tick += 1
                }
            }
            .fullScreenCover(isPresented: $viewing) {
                if let p = Theirs.photos(charId).first(where: { $0.id == photoId }) { ImageViewer(imageId: p.imageId) }
            }
            .confirmationDialog("删除这一张。删除后无法恢复，可以重新生成。", isPresented: $dropping, titleVisibility: .visible) {
                Button("删除", role: .destructive) { act { try Theirs.removePhoto(charId, photoId) }; dismiss() }
            }
        }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }
}

// MARK: - 只读的那两页

struct TheirsBodyView: View {
    let charId: String

    var body: some View {
        let d = Health.day(charId)
        Form {
            if !d.filled {
                Text("今天还没有记录").foregroundStyle(Theme.text3)
            } else {
                Section {
                    if !d.energy.isEmpty { LabeledContent("精力", value: Health.label(Health.energy, d.energy)) }
                    if !d.mood.isEmpty { LabeledContent("心情", value: Health.label(Health.moods, d.mood)) }
                    if !d.symptoms.isEmpty { LabeledContent("不适", value: d.symptoms.map { Health.label(Health.symptoms, $0) }.joined(separator: "、")) }
                    if d.sleepMin > 0 { LabeledContent("睡眠", value: Health.fmtSleep(d.sleepMin)) }
                    if !d.poops.isEmpty { LabeledContent("排便", value: "\(d.poops.count) 次") }
                    if !d.note.isEmpty { Text(d.note).foregroundStyle(Theme.text2) }
                }
            }
            Section {
                NavigationLink("前往设定页") { HealthCharView(charId: charId) }
            } footer: {
                HelpNote("本页只作查看。角色的身体状态在「健康 - 角色的身体状态」中填写。", title: "角色手机：身体状态")
            }
        }
        .navigationTitle("身体状态")
    }
}

struct TheirsDayView: View {
    let charId: String

    var body: some View {
        let char = (try? Repo.character(charId)) ?? nil
        let d = char.flatMap { (try? DayPlan.today($0)) ?? nil }
        let items = (d?["items"]?.array ?? []).compactMap(\.object)
        let now = DayPlan.slotNow(char).id
        Form {
            if items.isEmpty {
                Text("今天还没有安排").foregroundStyle(Theme.text3)
            } else {
                Section {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                        let slot = it["slot"]?.string ?? ""
                        let state = it["state"]?.string ?? ""
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it["text"]?.string ?? "")
                            Text([DayPlan.slots.first(where: { $0.id == slot })?.label ?? "", slot == now ? "正是此刻" : "",
                                  state.isEmpty ? "" : DayPlan.stateLabel(state)].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Theme.text3)
                        }
                    }
                } header: { Text("\(d?.string("date") ?? "")　\(DayPlan.weekday(char))") }
            }
            if let ev = d?["event"]?["text"]?.string, !ev.isEmpty {
                Section("今天遇上的事") { Text(ev) }
            }
            Section {
                EmptyView()
            } footer: {
                HelpNote("本页只作查看。安排与调整都在「日常」中处理。", title: "角色手机：今天")
            }
        }
        .navigationTitle("今天")
    }
}

// MARK: - 生成与外观

struct TheirsMakeView: View {
    let charId: String
    @State private var counts: [String: Int] = Dictionary(uniqueKeysWithValues: Theirs.makers.map { ($0.id, $0.def) })
    @State private var busy = ""
    @State private var notice: String?
    @State private var tick = 0

    var body: some View {
        let _ = tick
        Form {
            if let notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
            Section {
                ForEach(Theirs.makers) { m in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.label)
                            Text(Theirs.state(m.id, charId)).font(.caption).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        Button(busy == m.id ? "正在生成" : "生成") { runOne(m) }
                            .disabled(!busy.isEmpty)
                    }
                }
            } header: { Text("逐项生成") } footer: {
                Text("每一项一次请求，使用副用接口，与聊天分开计费。只发送该角色的设定，不发送对话历史。")
            }
            Section("数量") {
                ForEach(Theirs.makers) { m in
                    if m.solo {
                        Picker("\(m.label)的位数", selection: binding(m.id)) {
                            Text("四位").tag(4)
                            Text("六位").tag(6)
                        }
                    } else {
                        HStack {
                            Text("\(m.label)每次")
                            Spacer()
                            TextField("数量", value: binding(m.id), format: .number)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                        }
                    }
                }
            }
            Section {
                Button(busy.isEmpty ? "全部生成" : "正在生成") { runAll() }.disabled(!busy.isEmpty)
            } footer: {
                HelpNote("一个应用一次请求：某一项失败只需重试那一项，已经生成的内容不受影响。除锁屏密码外，再次生成为追加，不会覆盖已有内容。「全部生成」同样是一项一项发送，其中不包含锁屏密码；重新设定锁屏密码后不会显示密码，正在使用的密码被替换。数量不设上限，数量越多，这一次请求越长，也越可能写不完。", title: "角色手机：生成内容")
            }
        }
        .navigationTitle("生成内容")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ id: String) -> Binding<Int> {
        Binding(get: { counts[id] ?? 1 }, set: { counts[id] = max(1, $0) })
    }

    private func runOne(_ m: Theirs.Maker) {
        busy = m.id
        Task { @MainActor in
            do { let r = try await Theirs.run(m.id, charId, counts[m.id] ?? m.def); notice = "\(m.label)：\(r)" }
            catch { notice = "\(m.label)未能完成：\(error.localizedDescription)" }
            busy = ""; tick += 1
        }
    }

    private func runAll() {
        Task { @MainActor in
            var ok = 0
            var failed: [String] = []
            for m in Theirs.makers where !m.solo {
                busy = m.id
                do { _ = try await Theirs.run(m.id, charId, counts[m.id] ?? m.def); ok += 1 } catch { failed.append(m.label) }
            }
            busy = ""
            notice = failed.isEmpty ? "\(ok) 项全部完成" : "\(ok) 项完成，\(failed.joined(separator: "、"))未能完成，可单独重试"
            tick += 1
        }
    }
}

struct TheirsLookView: View {
    let charId: String
    @State private var tick = 0
    @State private var problem: String?
    @State private var picking = false
    @State private var picked: PhotosPickerItem?
    @State private var target = ""      // 空为壁纸，其余为应用 id
    @State private var renaming: TheirsHomeView.Tile?
    @State private var newName = ""

    var body: some View {
        let _ = tick
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Button(Theirs.wallpaper(charId).isEmpty ? "选择壁纸" : "更换壁纸") { target = ""; picking = true }
                if !Theirs.wallpaper(charId).isEmpty {
                    Button("恢复为角色封面") { act { try Theirs.setWallpaper(charId, nil) } }
                }
            } header: { Text("壁纸") } footer: {
                HelpNote("没有设定壁纸时，使用角色卡的封面。", title: "角色手机：外观")
            }
            Section("应用") {
                ForEach(TheirsHomeView.apps) { app in
                    let cur = Theirs.icon(charId, app.id)
                    Menu {
                        Button("改名") { newName = cur.name.isEmpty ? app.label : cur.name; renaming = app }
                        Button("换成图片") { target = app.id; picking = true }
                        if !cur.name.isEmpty || !cur.imageId.isEmpty || !cur.icon.isEmpty {
                            Button("恢复默认") { act { try Theirs.resetIcon(charId, app.id) } }
                        }
                    } label: {
                        HStack(spacing: Theme.sp3) {
                            Group {
                                if !cur.imageId.isEmpty { LocalImage(id: cur.imageId, maxPixel: 90) }
                                else { Image(systemName: cur.icon.isEmpty ? app.icon : cur.icon).foregroundStyle(Theme.text) }
                            }
                            .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cur.name.isEmpty ? app.label : cur.name).foregroundStyle(Theme.text)
                                Text([cur.name.isEmpty || cur.name == app.label ? "" : "原名 \(app.label)", cur.imageId.isEmpty ? "默认" : "使用图片"]
                                    .filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(isPresented: $picking, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            let to = target
            Task { @MainActor in
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw StoreError(message: "读不到这张图片") }
                    if to.isEmpty {
                        try Theirs.setWallpaper(charId, try Images.save(data))
                    } else {
                        try Theirs.setIcon(charId, to, ["imageId": .string(try Images.save(data, maxPixel: 360))])
                    }
                    problem = nil
                } catch { problem = "未能保存：\(error.localizedDescription)" }
                tick += 1
            }
        }
        .alert("改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let app = renaming {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    act { try Theirs.setIcon(charId, app.id, ["name": .string(n == app.label ? "" : String(n.prefix(12)))]) }
                }
            }
        }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }
}
