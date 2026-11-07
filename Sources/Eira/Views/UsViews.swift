import SwiftUI
import PhotosUI
import UIKit

/// 「我们」（网页版 apps/us，ARCHITECTURE 4.117）。长篇与番外，正文那一套整个复用线下的（beats）。
/// 页面：首页（长篇、番外两组）、新建、长篇向导（4.263）、作品页（扉页、简介、大纲、目录）、这一部的设定、这一篇的设定、正文页。
final class UsNav: ObservableObject {
    enum Route: Hashable { case work(String), edit(String), chapter(String), read(String), saga(String), chat(String) }
    @Published var path: [Route] = []

    func push(_ r: Route) { path.append(r) }

    /// 目录：栈里已经有这一部的作品页就退回去，没有就推进去
    func openWork(_ id: String) {
        if let i = path.lastIndex(of: .work(id)) { path = Array(path[...i]) } else { path.append(.work(id)) }
    }

    /// 向导建完：换掉向导那一页，进作品页
    func replaceTop(_ r: Route) {
        if !path.isEmpty { path.removeLast() }
        path.append(r)
    }
}

struct UsAppView: View {
    @StateObject private var nav = UsNav()

    var body: some View {
        NavigationStack(path: $nav.path) {
            UsHomeView(chatId: "")
                .navigationDestination(for: UsNav.Route.self) { r in
                    switch r {
                    case .work(let id): UsWorkView(workId: id)
                    case .edit(let id): UsWorkEditView(workId: id)
                    case .chapter(let id): UsChapterEditView(chapterId: id)
                    case .read(let id): UsReadView(chapterId: id).id(id)
                    case .saga(let chatId): UsSagaView(chatId: chatId)
                    case .chat(let chatId): UsHomeView(chatId: chatId)
                    }
                }
        }
        .environmentObject(nav)
    }
}

enum UsText {
    static func date(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let c = Calendar.current.dateComponents([.month, .day], from: Date(millis: ms))
        return "\(c.month ?? 1)月\(c.day ?? 1)日"
    }

    static func unit(_ w: Row) -> String { w.string("kind") == Works.SAGA ? "章" : "则" }
}

// MARK: - 首页

struct UsHomeView: View {
    let chatId: String
    @EnvironmentObject private var nav: UsNav
    @State private var sagas: [Row] = []
    @State private var extras: [Row] = []
    @State private var creating = false

    var body: some View {
        List {
            if sagas.isEmpty && extras.isEmpty {
                Section {
                    EmptyState(title: "还没有作品", desc: chatId.isEmpty
                               ? "长篇有一条主线，一章一章往下写，可以换一套身份重新开始。番外是一则小剧场，沿用现在的身份与记忆。两种都以成段的文字推进。"
                               : "这段关系下还没有作品。长篇有一条主线，一章一章往下写；番外是一则小剧场。")
                    Button("新建一部") { creating = true }.buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                }
                .listRowBackground(Color.clear)
            }
            if !sagas.isEmpty {
                Section("长篇 · \(sagas.count)") { ForEach(sagas, id: \.id) { row($0) } }
            }
            if !extras.isEmpty {
                Section("番外 · \(extras.count)") { ForEach(extras, id: \.id) { row($0) } }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { SvgIcon(name: "plus", size: 20) }.accessibilityLabel("新建")
            }
        }
        .sheet(isPresented: $creating, onDismiss: reload) {
            NavigationStack { UsNewView(chatId: chatId) { r in creating = false; nav.push(r) } }
        }
        .onAppear(perform: reload)
    }

    private var title: String {
        guard !chatId.isEmpty, let chat = (try? Repo.chat(chatId)) ?? nil else { return "我们" }
        let who = chat.characterIds.compactMap { (try? Repo.character($0)) ?? nil }.map(\.name).joined(separator: "、")
        return who.isEmpty ? "我们" : who
    }

    private func row(_ w: Row) -> some View {
        let names = Works.castOf(w).map(\.displayName).joined(separator: "、")
        let st = Works.statsOf(w.id)
        let meta = [names, st.chapters > 0 ? "\(st.chapters) \(UsText.unit(w)) · \(st.chars) 字" : "还没有正文",
                    UsText.date(w.number("updatedAt") ?? w.created ?? 0)].filter { !$0.isEmpty }.joined(separator: " · ")
        return NavigationLink(value: UsNav.Route.work(w.id)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(w.string("title").isEmpty ? "未命名" : w.string("title")).foregroundStyle(Theme.text)
                Text(meta).font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
        }
    }

    private func reload() {
        let all = chatId.isEmpty ? Works.all() : Works.ofChat(chatId)
        sagas = all.filter { $0.string("kind") == Works.SAGA }
        extras = all.filter { $0.string("kind") != Works.SAGA }
    }
}

// MARK: - 新建与编辑共用的那几组

/// 一部作品的表单。新建、向导、编辑共用
struct WorkForm {
    var kind = Works.EXTRA
    var from = "chat"
    var chatId = ""
    var castIds: [String] = []
    var title = "", premise = ""
    var charName = "", charPersona = "", meName = "", mePersona = ""
    var carry = false, solo = false, endNext = false
    var opening = "char"
    var carryChat = false, carryMemory = true, carryOther = false
    var tones: [String] = []
    var toneText = ""
    // 向导多出来的
    var genres: [String] = []
    var lengthId = "mid"
    var chapters = 24, perChapter = 3500
    var lorebookIds: [String] = []
    var inspiration = "", secret = ""
    var outlineMode = Novel.NONE
    var made: Novel.Made?

    var alone: Bool { kind == Works.SAGA && from == "cast" }

    static func fresh(chatId: String) -> WorkForm {
        var f = WorkForm()
        f.chatId = chatId
        let s = AppSettings.load()
        let known = Set(Tone.list(s).map(\.id))
        f.tones = (s.raw["workToneLast"]?.array ?? []).compactMap(\.string).filter { $0 == "custom" || known.contains($0) }
        return f
    }

    /// 表单先当成一部作品用：生成简介、大纲、身份的那几次请求读的就是作品上的字段
    func draftRow(id: String = "draft") -> Row {
        let cast = alone ? castIds : (((try? Repo.chat(chatId)) ?? nil)?.characterIds ?? [])
        var outline: JSONValue = .null
        if let made {
            var o = Novel.Outline()
            o.mode = outlineMode
            o.master = made.master
            o.volumes = made.volumes
            o.chapters = made.chapters
            outline = Novel.json(o)
        }
        return Row(fields: [
            "id": .string(id), "kind": .string(Works.SAGA), "title": .string(title), "premise": .string(premise),
            "secret": .string(secret), "inspiration": .string(inspiration), "chatId": .string(alone ? "" : chatId),
            "castIds": .array(cast.map { .string($0) }), "charAs": .null, "meAs": .null, "solo": .bool(solo),
            "genres": .array(genres.map { .string($0) }),
            "length": .object(["chapters": .number(Double(chapters)), "perChapter": .number(Double(perChapter))]),
            "lorebookIds": .array(lorebookIds.map { .string($0) }), "outline": outline,
        ])
    }

    func draft() -> Works.Draft {
        var d = Works.Draft()
        d.chatId = alone ? "" : chatId
        d.castIds = alone ? castIds : []
        d.kind = kind
        d.title = title
        d.premise = premise
        if !charName.isEmpty || !charPersona.isEmpty { d.charAs = (name: charName, persona: charPersona) }
        if !meName.isEmpty || !mePersona.isEmpty { d.meAs = (name: meName, persona: mePersona) }
        d.carry = alone ? false : carry
        d.solo = solo
        d.endNext = endNext
        d.carryChat = carryChat
        d.carryMemory = carryMemory
        d.carryOther = carryOther
        d.opening = opening
        d.tones = tones
        d.toneText = toneText
        return d
    }

    func ready() -> String? {
        if alone ? castIds.isEmpty : chatId.isEmpty { return alone ? "请先选择人物" : "请先选择和谁" }
        return nil
    }
}

struct WorkSwitchesSection: View {
    @Binding var v: WorkForm

    var body: some View {
        Section("新篇开场角色") {
            Picker("新篇开场角色", selection: $v.opening) {
                Text("让它开场").tag("char")
                Text("我自己写").tag("me")
            }
            .pickerStyle(.segmented)
            Text("选择「让它开场」时，新建一篇后立即生成第一段，这会调用一次接口。").font(.footnote).foregroundStyle(Theme.text2)
        }
        Section("本部写法") {
            if v.kind == Works.SAGA && !v.alone {
                Toggle("带上原来的关系", isOn: $v.carry)
                Text(v.carry ? "角色沿用原来的人设、世界书与你的资料。另外带哪些内容，由下面三项决定。"
                     : "角色只按这一部的设定写，不知道聊天里发生过什么，也读不到记忆与关系底色。")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            if v.kind != Works.SAGA || (!v.alone && v.carry) {
                Toggle(Works.carry[0].label, isOn: $v.carryChat)
                HelpNote("带上手机上最近的几条消息。关闭后，正文不接手机上刚聊过的话题。", title: "我们：携带近期聊天记录")
                Toggle(Works.carry[1].label, isOn: $v.carryMemory)
                HelpNote("带上关系底色、一直记着的与相关的记忆。关闭后，角色不记得聊天里发生过的事。", title: "我们：携带记忆")
                Toggle(Works.carry[2].label, isOn: $v.carryOther)
                HelpNote("带上此刻的时间、日程、天气、身体状况等每轮注入的内容。关闭后，正文不受当下这些状态影响。", title: "我们：携带其他每轮注入的内容")
            }
            Toggle("整篇由它写", isOn: $v.solo)
            Text(v.solo ? "它连「我」这个角色的言行一起写，读起来是小说。你仍然可以自己写一段插进去。" : "它只写对方与周围，「我」那一段由你自己写。")
                .font(.footnote).foregroundStyle(Theme.text2)
            Toggle("结尾给出后续走向", isOn: $v.endNext)
            Text("与正文为同一次请求，不多调用接口；输出约多一百字。").font(.footnote).foregroundStyle(Theme.text2)
            HelpNote("开启后，每一段末尾附带三个后续走向，可选其一或自行填写一个，作为下一篇的走向写入提示词。关闭后正文照旧，不再附带。", title: "我们：结尾给出后续走向")
        }
    }
}

/// 文风：和线下同一份预设库（Tone）
struct WorkToneSection: View {
    @Binding var tones: [String]
    @Binding var text: String
    @State private var list: [Tone.Preset] = []

    var body: some View {
        Section {
            Button { tones = []; text = "" } label: {
                HStack { Text("不设定").foregroundStyle(Theme.text); Spacer(); if tones.isEmpty { Image(systemName: "checkmark") } }
            }
            ForEach(list) { t in
                Button { flip(t.id) } label: {
                    HStack { Text(t.name).foregroundStyle(Theme.text); Spacer(); if tones.contains(t.id) { Image(systemName: "checkmark") } }
                }
            }
            Button { flip("custom") } label: {
                HStack { Text("这一部自己写").foregroundStyle(Theme.text); Spacer(); if tones.contains("custom") { Image(systemName: "checkmark") } }
            }
            if tones.contains("custom") {
                TextField("这一部的文风。写给模型看，用英文写", text: $text, axis: .vertical).lineLimit(3...10)
            }
            HelpNote("可以选多份，按选中的顺序依次写入提示词。「这一部自己写」只作用于这一部，不进预设库；一律用英文写，中文写的指令会把措辞漏进正文。", title: "我们：文风")
        } header: { Text("文风") }
        .onAppear { list = Tone.list() }
    }

    private func flip(_ id: String) {
        if tones.contains(id) { tones.removeAll { $0 == id } } else { tones.append(id) }
    }
}

/// 挑一段会话。作品挂在关系上
struct WorkChatPick: View {
    @Binding var chatId: String
    @State private var chats: [Chat] = []

    var body: some View {
        Section("参与角色") {
            ForEach(chats, id: \.id) { c in
                let names = c.characterIds.compactMap { (try? Repo.character($0)) ?? nil }.map(\.name).joined(separator: "、")
                Button { chatId = c.id } label: {
                    HStack {
                        Text(names.isEmpty ? "已删除的角色" : names).foregroundStyle(Theme.text)
                        Spacer()
                        if chatId == c.id { Image(systemName: "checkmark") }
                    }
                }
            }
            if chats.isEmpty { Text("还没有会话").foregroundStyle(Theme.text2) }
        }
        .onAppear { chats = ((try? Repo.chats()) ?? []).filter { !$0.characterIds.isEmpty }.sorted { $0.lastMessageAt > $1.lastMessageAt } }
    }
}

/// 直接从联系里选人物，不经过会话（4.262）。长篇才有这条路；NPC 排在后面
struct WorkCastPick: View {
    @Binding var castIds: [String]
    @State private var list: [Character] = []

    var body: some View {
        Section("人物") {
            ForEach(list, id: \.id) { c in
                Toggle(isOn: Binding(get: { castIds.contains(c.id) }, set: { on in
                    if on { if !castIds.contains(c.id) { castIds.append(c.id) } } else { castIds.removeAll { $0 == c.id } }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.displayName)
                        if !c.signature.isEmpty { Text(c.signature).font(.footnote).foregroundStyle(Theme.text2).lineLimit(1) }
                    }
                }
            }
            if list.isEmpty { Text("还没有角色。先在「联系」中创建角色").foregroundStyle(Theme.text2) }
        }
        .onAppear {
            let all = ((try? Repo.characters()) ?? []).filter { ($0.parentId ?? "").isEmpty }.sorted { $0.name < $1.name }
            list = all.filter { !$0.isNpc } + all.filter(\.isNpc)
        }
    }
}

/// 这个世界里的身份（4.283）：留空沿用角色卡与账号资料。「按这个世界改写」调一次接口，改写的结果先填进框里
struct WorkIdentitySection: View {
    let who: String
    @Binding var name: String
    @Binding var persona: String
    var generate: (() async throws -> (name: String, persona: String))?
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        Section(who == "me" ? "我在这部作品里" : "角色在这部作品里") {
            TextField(who == "me" ? "名字，留空沿用账号资料" : "名字，留空沿用角色卡", text: $name)
            TextField("人设，留空沿用原来的", text: $persona, axis: .vertical).lineLimit(3...12)
            if let generate {
                Button(busy ? "正在改写" : "按这个世界改写") {
                    busy = true
                    problem = nil
                    Task { @MainActor in
                        do { let r = try await generate(); name = r.name; persona = r.persona } catch { problem = error.localizedDescription }
                        busy = false
                    }
                }
                .disabled(busy)
                Text("按这部作品的标题、简介、体裁与世界观改写原来的人设，调用一次接口。改写后可以修改，保存后才生效。").font(.footnote).foregroundStyle(Theme.text2)
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        }
    }
}

// MARK: - 新建

struct UsNewView: View {
    let chatId: String
    var done: (UsNav.Route) -> Void
    @State private var v = WorkForm()
    @State private var problem: String?
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Picker("体裁", selection: $v.kind) { ForEach(Works.kinds.indices, id: \.self) { i in Text(Works.kinds[i].label).tag(Works.kinds[i].id) } }
                    .pickerStyle(.segmented)
                Text(Works.kinds.first { $0.id == v.kind }?.desc ?? "").font(.footnote).foregroundStyle(Theme.text2)
                if v.kind == Works.SAGA {
                    Button("使用长篇向导") { done(.saga(chatId)) }
                    Text("向导里可以选体裁标签与篇幅、挂世界观、生成简介与分层大纲。下面是快速新建。").font(.footnote).foregroundStyle(Theme.text2)
                }
            }
            Section {
                TextField(v.kind == Works.SAGA ? "这部作品叫什么" : "这一则小剧场叫什么", text: $v.title)
                TextField(v.kind == Works.SAGA ? "主线" : "设定", text: $v.premise, axis: .vertical).lineLimit(4...12)
                Text(v.kind == Works.SAGA ? "这部作品讲的是什么、在什么世界、两个人是什么关系。每一章都会带上它。"
                     : "这一则的前提。例如另一种可能的走向，或者某一天发生的一件小事。").font(.footnote).foregroundStyle(Theme.text2)
            }
            if v.kind == Works.SAGA {
                WorkIdentitySection(who: "char", name: $v.charName, persona: $v.charPersona)
                WorkIdentitySection(who: "me", name: $v.meName, persona: $v.mePersona)
            }
            WorkToneSection(tones: $v.tones, text: $v.toneText)
            if chatId.isEmpty {
                if v.kind == Works.SAGA {
                    Section("人物来源") {
                        Picker("人物来源", selection: $v.from) {
                            Text("一段会话").tag("chat")
                            Text("直接选人物").tag("cast")
                        }
                        .pickerStyle(.segmented)
                        Text(v.from == "cast" ? "直接从联系里选人物，不挂在任何会话上，因此没有「带上原来的记忆」。" : "挂在一段会话上，可以带上那段关系的记忆。")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
                if v.alone { WorkCastPick(castIds: $v.castIds) } else { WorkChatPick(chatId: $v.chatId) }
            }
            WorkSwitchesSection(v: $v)
            ProblemSection(text: problem)
        }
        .navigationTitle("新建")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("建立", action: create) }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            v = WorkForm.fresh(chatId: chatId)
        }
    }

    private func create() {
        if let msg = v.ready() { problem = msg; return }
        do {
            let row = try Works.create(v.draft())
            // 番外只有一则，建完直接开写；长篇先进目录，第一章由用户自己起
            if v.kind == Works.EXTRA, let first = try Works.addChapter(row.id) { done(.read(first.id)) } else { done(.work(row.id)) }
        } catch { problem = "建立失败：\(error.localizedDescription)" }
    }
}

// MARK: - 长篇向导（4.263）

struct UsSagaView: View {
    let chatId: String
    @EnvironmentObject private var nav: UsNav
    @State private var v = WorkForm()
    @State private var loaded = false
    @State private var busy = ""
    @State private var problem: String?
    @State private var notice: String?
    @State private var books: [Lorebook] = []
    @State private var adding: [String: String] = [:]
    @State private var custom: [String: [String]] = [:]

    var body: some View {
        Form {
            Section {
                TextField("标题，可以先空着，生成简介时一并给出", text: $v.title)
                if chatId.isEmpty {
                    Picker("人物来源", selection: $v.from) {
                        Text("一段会话").tag("chat")
                        Text("直接选人物").tag("cast")
                    }
                    .pickerStyle(.segmented)
                    HelpNote("「直接选人物」从联系里选人物，不挂在任何会话上，因此没有「带上原来的记忆」；「一段会话」挂在那段会话上，可以带上那段关系的记忆。", title: "长篇向导：人物来源")
                }
            }
            if chatId.isEmpty {
                if v.alone { WorkCastPick(castIds: $v.castIds) } else { WorkChatPick(chatId: $v.chatId) }
            }
            tagSections
            lengthSection
            booksSection
            synopsisSection
            outlineSection
            WorkIdentitySection(who: "char", name: $v.charName, persona: $v.charPersona,
                                generate: { try await WorkTasks.identity(v.draftRow(), who: "char") })
            WorkIdentitySection(who: "me", name: $v.meName, persona: $v.mePersona,
                                generate: { try await WorkTasks.identity(v.draftRow(), who: "me") })
            WorkSwitchesSection(v: $v)
            WorkToneSection(tones: $v.tones, text: $v.toneText)
            Section { Text("建立后仍可在作品页修改简介、大纲与写法。").font(.footnote).foregroundStyle(Theme.text2) }
            ProblemSection(text: problem)
        }
        .navigationTitle("新建长篇")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("建立", action: create) } }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好") { notice = nil } }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            v = WorkForm.fresh(chatId: chatId)
            v.kind = Works.SAGA
            books = ((try? Repo.lorebooks()) ?? []).filter { $0.purpose != "forum" && $0.entries.contains { !$0.isCard } }
            custom = Novel.customTags()
        }
    }

    // MARK: 体裁与标签

    private var tagSections: some View {
        ForEach(Novel.tags.indices, id: \.self) { i in
            let c = Novel.tags[i]
            Section(c.label) {
                let all = c.tags + (custom[c.id] ?? []).filter { !c.tags.contains($0) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.sp2) {
                        ForEach(all, id: \.self) { t in
                            Button(t) { flip(t) }
                                .font(.system(size: 13))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .foregroundStyle(v.genres.contains(t) ? Theme.onAccent : Theme.text)
                                .background(v.genres.contains(t) ? Theme.accent : Theme.surface2, in: Capsule())
                                .buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    TextField("添加标签", text: Binding(get: { adding[c.id] ?? "" }, set: { adding[c.id] = $0 }))
                    Button("添加") { addTag(c.id) }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func flip(_ t: String) {
        if v.genres.contains(t) { v.genres.removeAll { $0 == t } } else { v.genres.append(t) }
    }

    private func addTag(_ cat: String) {
        let t = (adding[cat] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var cur = Novel.customTags()
        if !(cur[cat] ?? []).contains(t) {
            cur[cat, default: []].append(t)
            var obj: [String: JSONValue] = [:]
            for (k, list) in cur { obj[k] = .array(list.map { .string($0) }) }
            SettingsModel.shared.set("novelTags", .object(obj))
            custom = cur
        }
        if !v.genres.contains(t) { v.genres.append(t) }
        adding[cat] = ""
    }

    // MARK: 篇幅

    private var lengthSection: some View {
        Section {
            Picker("篇幅", selection: Binding(get: { v.lengthId }, set: { id in
                v.lengthId = id
                if let l = Novel.lengths.first(where: { $0.id == id }) { v.chapters = l.chapters; v.perChapter = l.perChapter }
            })) { ForEach(Novel.lengths.indices, id: \.self) { i in Text(Novel.lengths[i].label).tag(Novel.lengths[i].id) } }
                .pickerStyle(.segmented)
            NumberRow(title: "预计章数", value: Binding(get: { Double(v.chapters) }, set: { v.chapters = max(0, Int($0)) }), unit: "章", placeholder: "不固定")
            NumberRow(title: "每章字数", value: Binding(get: { Double(v.perChapter) }, set: { v.perChapter = max(0, Int($0)) }), unit: "字", placeholder: "不固定")
            HelpNote("选档只是填入默认值，章数与每章字数都可以改。填 0 表示不固定。", title: "长篇向导：篇幅")
        } header: { Text("篇幅") }
    }

    // MARK: 世界观

    private var booksSection: some View {
        Section("世界观") {
            ForEach(books, id: \.id) { b in
                Toggle(isOn: Binding(get: { v.lorebookIds.contains(b.id) }, set: { on in
                    if on { if !v.lorebookIds.contains(b.id) { v.lorebookIds.append(b.id) } } else { v.lorebookIds.removeAll { $0 == b.id } }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.name.isEmpty ? "未命名" : b.name)
                        Text("\(b.entries.count) 个条目").font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
            }
            if books.isEmpty { Text("还没有世界书。可在「设定集 - 世界书」中新建").foregroundStyle(Theme.text2) }
        }
    }

    // MARK: 灵感与简介

    private var synopsisSection: some View {
        Section {
            TextField("灵感：一个场景、一句话、一个关系", text: $v.inspiration, axis: .vertical).lineLimit(2...8)
            HelpNote("想写什么都可以记在这里。生成简介与大纲时会参考。", title: "长篇向导：灵感")
            TextField("简介", text: $v.premise, axis: .vertical).lineLimit(4...16)
            HelpNote("读者看到的那一段：世界、人物、开局与悬念。每一章都会带上它。", title: "长篇向导：简介")
            Button(busy == "synopsis" ? "正在生成" : "生成简介") { makeSynopsis() }.disabled(!busy.isEmpty)
            Text("按人设、世界观、体裁、篇幅与灵感生成标题与简介，调用一次接口。生成后可以修改。\(v.outlineMode == Novel.HIDDEN ? "大纲设为隐藏时，一并生成一份含谜底的作者私纲，不显示。" : "")")
                .font(.footnote).foregroundStyle(Theme.text2)
        } header: { Text("灵感与简介") }
    }

    // MARK: 大纲

    private var outlineSection: some View {
        Section {
            Picker("大纲", selection: $v.outlineMode) { ForEach(Novel.modes.indices, id: \.self) { i in Text(Novel.modes[i].label).tag(Novel.modes[i].id) } }
                .pickerStyle(.segmented)
            Text(Novel.modes.first { $0.id == v.outlineMode }?.desc ?? "").font(.footnote).foregroundStyle(Theme.text2)
            if v.outlineMode != Novel.NONE {
                Button(busy == "outline" ? "正在生成" : (v.made == nil ? "生成大纲" : "重新生成大纲")) { makeOutline() }.disabled(!busy.isEmpty)
                Text((v.chapters > 0 && v.chapters <= Novel.oneShotChapters ? "调用一次接口" : "调用一次接口生成总纲与卷纲；各卷的章纲在写到那一卷时再生成，每卷调用一次") + "。也可以先建立，之后在作品页生成。")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if let made = v.made {
                    Text("大纲已生成：\(made.volumes.count) 卷。\(v.outlineMode == Novel.HIDDEN ? "按设置不显示内容，写作时使用。" : "建立后在作品页查看。")")
                        .font(.footnote).foregroundStyle(Theme.text)
                }
            }
        } header: { Text("大纲") }
    }

    private func run(_ what: String, _ f: @escaping () async throws -> Void) {
        if let msg = v.ready() { problem = msg; return }
        busy = what
        problem = nil
        Task { @MainActor in
            do { try await f() } catch { problem = error.localizedDescription }
            busy = ""
        }
    }

    private func makeSynopsis() {
        let draft = v.draftRow()
        let hidden = v.outlineMode == Novel.HIDDEN
        run("synopsis") {
            let r = try await WorkTasks.synopsis(draft, hidden: hidden)
            if !r.synopsis.isEmpty { v.premise = r.synopsis }
            if v.title.isEmpty { v.title = r.title }
            if !r.secret.isEmpty { v.secret = r.secret }
            notice = "简介已生成，可以修改"
        }
    }

    private func makeOutline() {
        let draft = v.draftRow()
        run("outline") {
            if v.premise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw StoreError(message: "请先写一段简介，或先生成简介") }
            v.made = try await WorkTasks.outline(draft)
            notice = "大纲已生成"
        }
    }

    private func create() {
        if let msg = v.ready() { problem = msg; return }
        do {
            var d = v.draft()
            d.kind = Works.SAGA
            d.genres = v.genres
            d.length = (chapters: v.chapters, perChapter: v.perChapter)
            d.lorebookIds = v.lorebookIds
            d.inspiration = v.inspiration
            d.secret = v.secret
            if v.outlineMode == Novel.NONE { d.outline = Novel.blank(Novel.NONE) }
            let row = try Works.create(d)
            if v.outlineMode != Novel.NONE {
                try Novel.setOutline(row.id) { $0.mode = v.outlineMode }
                if let made = v.made { try Novel.applyOutline(row.id, made) }
            }
            nav.replaceTop(.work(row.id))
        } catch { problem = "建立失败：\(error.localizedDescription)" }
    }
}

// MARK: - 作品页

struct UsHero: View {
    let work: Row

    var body: some View {
        let c = Works.charOf(work), m = Works.meOf(work)
        let st = Works.statsOf(work.id)
        let look = Stage.look(Works.stageOf(work, nil))
        let meta = [Works.kindLabel(work.string("kind")), st.chapters > 0 ? "\(st.chapters) \(UsText.unit(work))" : "还没有正文",
                    st.chars > 0 ? "\(st.chars) 字" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let title = work.string("title").isEmpty ? "未命名" : work.string("title")
        VStack(spacing: Theme.sp2) {
            ZStack {
                look.line
                if !work.string("cover").isEmpty {
                    LocalImage(id: work.string("cover"), maxPixel: 480)
                } else {
                    Text(String((work.string("title").isEmpty ? c.name : work.string("title")).prefix(1)))
                        .font(look.font(44)).foregroundStyle(look.ink)
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
            Text(title).font(look.font(22)).foregroundStyle(look.ink)
            Text([c.name, m.name].filter { !$0.isEmpty }.joined(separator: "　")).font(.system(size: 13)).foregroundStyle(look.dim)
            Text(meta).font(.system(size: 12)).foregroundStyle(look.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.sp5)
        .background(look.bg, in: RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
    }
}

struct UsWorkView: View {
    let workId: String
    @EnvironmentObject private var nav: UsNav
    @State private var work: Row?
    @State private var chapters: [Row] = []
    @State private var nextOpen = false
    @State private var dropping: Row?
    @State private var dropWork = false
    @State private var problem: String?

    var body: some View {
        Group {
            if let w = work { page(w) } else { ScrollView { EmptyState(title: "这一部已经不在了") } }
        }
        .navigationTitle(work.map { $0.string("title").isEmpty ? "未命名" : $0.string("title") } ?? "我们")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func page(_ w: Row) -> some View {
        let saga = w.string("kind") == Works.SAGA
        let unit = UsText.unit(w)
        return List {
            Section { UsHero(work: w) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            if !w.string("premise").isEmpty {
                Section(saga ? "简介" : "设定") { Text(w.string("premise")).font(.system(size: 14)) }
            }
            if saga && !w.strings("genres").isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.sp2) {
                            ForEach(w.strings("genres"), id: \.self) { t in
                                Text(t).font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 4).background(Theme.surface2, in: Capsule())
                            }
                        }
                    }
                }
            }
            if saga { UsOutlinePanel(work: w) { reload() } }
            if chapters.isEmpty {
                Section {
                    EmptyState(title: "还没有第一\(unit)", desc: "新的一篇建立之后即可开始写。")
                    Button("新的一\(unit)") { add(w) }.buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                }
                .listRowBackground(Color.clear)
            } else {
                Section("目录 · \(chapters.count) \(unit)") {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { i, c in chapterRow(w, c, i) }
                }
            }
            Section {
                NavigationLink(value: UsNav.Route.edit(w.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("这一部的设定")
                        Text(["标题、封面、主线、身份、文风", w.bool("carry") ? "" : "当前不带原来的记忆", w.bool("solo") ? "当前整篇由它写" : ""]
                            .filter { !$0.isEmpty }.joined(separator: "。")).font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
                Button("删除这一部", role: .destructive) { dropWork = true }
            }
            ProblemSection(text: problem)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { add(w) } label: { SvgIcon(name: "plus", size: 20) }.accessibilityLabel("新的一\(unit)")
            }
        }
        .sheet(isPresented: $nextOpen, onDismiss: reload) {
            NavigationStack { UsNextChapterView(workId: w.id) { id in nextOpen = false; nav.push(.read(id)) } }
        }
        .confirmationDialog("这一篇的全部正文将一并删除，无法恢复。", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
                            titleVisibility: .visible, presenting: dropping) { c in
            Button("删除", role: .destructive) {
                do { try Works.removeChapter(c.id); reload() } catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        }
        .confirmationDialog(dropWorkText(w), isPresented: $dropWork, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Works.remove(w.id); if !nav.path.isEmpty { nav.path.removeLast() } } catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        }
    }

    private func dropWorkText(_ w: Row) -> String {
        let st = Works.statsOf(w.id)
        return "将删除这一部与它的 \(st.chapters) \(UsText.unit(w))、共 \(st.chars) 字正文。此操作无法撤销。"
    }

    private func chapterRow(_ w: Row, _ c: Row, _ i: Int) -> some View {
        let told = Scenes.told(c.id)
        let chars = told.reduce(0) { $0 + $1.string("text").count }
        let meta = [c.string("place"), told.isEmpty ? "还没有正文" : "\(told.count) 段 · \(chars) 字",
                    c.string("summary").isEmpty ? "" : "已收篇", UsText.date(c.number("updatedAt") ?? c.created ?? 0)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let saga = w.string("kind") == Works.SAGA
        return NavigationLink(value: UsNav.Route.read(c.id)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Works.chapterTitle(w, c)).foregroundStyle(Theme.text)
                Text(meta).font(.footnote).foregroundStyle(Theme.text2)
            }
        }
        .swipeActions {
            Button("删除", role: .destructive) { dropping = c }
            if saga && i < chapters.count - 1 { Button("下移") { move(c, 1) } }
            if saga && i > 0 { Button("上移") { move(c, -1) } }
        }
    }

    private func move(_ c: Row, _ dir: Int) {
        do { try Works.moveChapter(c.id, dir); reload() } catch { problem = "调整失败：\(error.localizedDescription)" }
    }

    /// 长篇的新一章走章末分支那张表（4.264）；番外直接加一则
    private func add(_ w: Row) {
        if w.string("kind") == Works.SAGA { nextOpen = true; return }
        do { if let row = try Works.addChapter(w.id) { nav.push(.read(row.id)) } } catch { problem = "新建失败：\(error.localizedDescription)" }
    }

    private func reload() {
        work = Works.get(workId)
        chapters = Works.chaptersOf(workId)
    }
}

/// 大纲那一节（4.263）。可见：总纲、各卷、章纲（缺的卷可以补）；隐藏：只说有几卷、写到哪，可揭晓；无：可以生成。
/// 剧情偏离大纲之后（4.264）多一条「重排后续大纲」。每个按钮点一次调一次接口
struct UsOutlinePanel: View {
    let work: Row
    var changed: () -> Void
    @State private var busy = ""
    @State private var problem: String?

    var body: some View {
        let o = Novel.outlineOf(work)
        let p = Novel.progressOf(work)
        let total = Int(work["length"]?["chapters"]?.number ?? 0)
        let calls = total > 0 && total <= Novel.oneShotChapters ? "调用一次接口" : "调用一次接口生成总纲与卷纲，各卷章纲写到时再生成"
        if o.mode == Novel.NONE || o.master == nil {
            Section("大纲") {
                Text(o.mode == Novel.NONE ? "无大纲，自由创作" : "大纲尚未生成")
                HelpNote("每章只带前情与简介。", title: "我们：无大纲")
                Button(busy == "outline" ? "正在生成" : "生成大纲（可见）") { make(Novel.VISIBLE) }.disabled(!busy.isEmpty)
                Button("生成大纲（隐藏）") { make(Novel.HIDDEN) }.disabled(!busy.isEmpty)
                HelpNote("隐藏的大纲生成后不显示内容，写作时使用；可随时揭晓。", title: "我们：隐藏大纲")
                Text("\(calls)。").font(.footnote).foregroundStyle(Theme.text2)
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            }
        } else {
            let hidden = o.mode == Novel.HIDDEN
            let limit = Novel.visibleChapters(work)
            Section("大纲") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hidden ? "大纲已隐藏" : "大纲")
                    Text("\(o.volumes.count) 卷 · 已写 \(p.started) 章\(p.total > 0 ? " / 预计 \(p.total) 章" : "")\(o.drift ? " · 剧情已偏离大纲" : "")")
                        .font(.footnote).foregroundStyle(Theme.text2)
                }
                if hidden {
                    Button(o.revealed == "written" ? "已揭晓到目前为止" : "揭晓到目前为止") {
                        save { $0.revealed = $0.revealed == "written" ? "none" : "written" }
                    }
                    Button(o.revealed == "all" ? "重新隐藏" : "全部揭晓") { save { $0.revealed = $0.revealed == "all" ? "none" : "all" } }
                }
                if o.drift {
                    Button(busy == "replan" ? "正在重排" : "按现在的走向重排后续大纲") { replan(p.started + 1) }.disabled(!busy.isEmpty)
                    Text("从下一章起重排，已写的章不动。调用一次接口").font(.footnote).foregroundStyle(Theme.text2)
                }
                Button(busy == "outline" ? "正在生成" : "重新生成大纲") { make(o.mode) }.disabled(!busy.isEmpty)
                Text(calls).font(.footnote).foregroundStyle(Theme.text2)
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            }
            if !hidden || o.revealed != "none" {
                if limit == nil || (limit ?? 0) > 0 {
                    Section("总纲") { ForEach(Array(Novel.masterLines(o.master).enumerated()), id: \.offset) { Text($0.element).font(.system(size: 14)) } }
                    ForEach(o.volumes.filter { limit == nil || $0.from <= (limit ?? 0) }) { v in volume(o, v, limit) }
                } else {
                    Section { Text("还没有写到任何一章，没有可揭晓的内容。").foregroundStyle(Theme.text2) }
                }
            }
        }
    }

    private func volume(_ o: Novel.Outline, _ v: Novel.Volume, _ limit: Int?) -> some View {
        let lines = (o.chapters[v.no] ?? []).filter { limit == nil || $0.no <= (limit ?? 0) }
        return Section("第 \(v.no) 卷\(v.title.isEmpty ? "" : "　\(v.title)")") {
            Text("第 \(v.from) 到 \(v.to) 章 · \(v.goal)\(v.reveal.isEmpty ? "" : " · 揭晓：\(v.reveal)")").font(.footnote).foregroundStyle(Theme.text2)
            if (o.chapters[v.no] ?? []).isEmpty {
                Button(busy == "vol\(v.no)" ? "正在生成" : "生成这一卷的章纲") { fill(v) }.disabled(!busy.isEmpty)
                Text("每章一行。调用一次接口").font(.footnote).foregroundStyle(Theme.text2)
            } else {
                ForEach(lines) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("第 \(c.no) 章\(c.title.isEmpty ? "" : "　\(c.title)")")
                        Text(c.line).font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
            }
        }
    }

    private func save(_ change: (inout Novel.Outline) -> Void) {
        do { try Novel.setOutline(work.id, change); changed() } catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    private func run(_ what: String, _ f: @escaping () async throws -> Void) {
        busy = what
        problem = nil
        Task { @MainActor in
            do { try await f(); changed() } catch { problem = error.localizedDescription }
            busy = ""
        }
    }

    private func make(_ mode: String) {
        let id = work.id
        run("outline") {
            guard let w = Works.get(id) else { return }
            if w.string("premise").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw StoreError(message: "请先在「这一部的设定」里写一段简介") }
            let made = try await WorkTasks.outline(w)
            try Novel.setOutline(id) { $0.mode = mode }
            try Novel.applyOutline(id, made)
        }
    }

    private func fill(_ v: Novel.Volume) {
        let id = work.id
        run("vol\(v.no)") {
            guard let w = Works.get(id) else { return }
            try Novel.applyVolume(id, v.no, try await WorkTasks.volume(w, v))
        }
    }

    private func replan(_ from: Int) {
        let id = work.id
        run("replan") {
            guard let w = Works.get(id) else { return }
            try WorkTasks.applyReplan(id, from: from, try await WorkTasks.replan(w, from: from))
        }
    }
}

// MARK: - 下一章（章末分支，4.264）

/// 一章写完，下一章三选一：自己写、让它接着写、给几个走向再挑。「给几个走向」一次请求，候选数由用户填（novelBranchCount，默认 3）。
/// 选了偏离大纲的走向，作品上记一笔 drift，作品页多一条「重排后续大纲」（不自动）
struct UsNextChapterView: View {
    let workId: String
    var opened: (String) -> Void
    @ObservedObject private var model = SettingsModel.shared
    @State private var options: [WorkTasks.Branch]?
    @State private var busy = false
    @State private var problem: String?
    @State private var asking: StartArgs?
    @Environment(\.dismiss) private var dismiss

    struct StartArgs: Identifiable {
        var title = "", plan = "", opening = "", planFrom = "", fromChapterId = ""
        var id: String { title + plan + opening }
    }

    var body: some View {
        let w = Works.get(workId)
        let next = Works.nextNo(workId)
        let o = Novel.outlineOf(w)
        let planned = Novel.lineOf(o, next)
        return Form {
            if let options {
                Section("选一个走向") {
                    ForEach(options) { opt in
                        Button { pick(opt) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(opt.title.isEmpty ? "走向" : opt.title).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(opt.follows ? "沿大纲" : "偏离大纲").font(.system(size: 12)).foregroundStyle(Theme.text2)
                                }
                                Text(opt.line).font(.footnote).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                    Text("选择偏离大纲的走向后，作品页会提示「按现在的走向重排后续大纲」，不会自动重排。").font(.footnote).foregroundStyle(Theme.text2)
                }
                Section { Button(busy ? "正在想" : "换一批") { ask() }.disabled(busy) }
            } else {
                Section {
                    if let planned, w.map({ Novel.visibleChapters($0) != 0 }) ?? false {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("大纲里这一章")
                            Text("\(planned.title.isEmpty ? "" : "\(planned.title)　")\(planned.line)").font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                    Button { start(StartArgs(opening: "me")) } label: { option("自己写下一章", "新建一章，由我先写") }
                    Button { start(StartArgs(opening: "char")) } label: { option("让它接着写", "新建一章，立即生成第一段，调用一次接口") }
                    Button { ask() } label: { option(busy ? "正在想" : "给我几个走向", "列出几个可能的走向再挑，调用一次接口；选定后再开写") }.disabled(busy)
                }
                Section {
                    NumberRow(title: "给几个走向", value: model.number("novelBranchCount", 3), unit: "个", placeholder: "3")
                    HelpNote("每次请求返回这么多个候选。", title: "我们：给几个走向")
                }
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("第 \(next) 章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .confirmationDialog(asking.map { _ in "这一卷的章纲还没有生成。先生成这一卷的章纲（调用一次接口），还是直接开始写这一章。" } ?? "",
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible, presenting: asking) { a in
            Button("先生成") { begin(a, volumeFirst: true) }
            Button("直接写") { begin(a, volumeFirst: false) }
        }
    }

    private func option(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).foregroundStyle(Theme.text)
            Text(sub).font(.footnote).foregroundStyle(Theme.text2)
        }
    }

    private func ask() {
        guard let w = Works.get(workId) else { return }
        busy = true
        problem = nil
        let last = Works.chaptersOf(workId).last
        // 填 0 或没填按 3 个（网页版 countOf）
        let n = Int(model.s.num("novelBranchCount", 3).rounded())
        let count = n > 0 ? n : 3
        Task { @MainActor in
            do { options = try await WorkTasks.branches(w, after: last, count: count) } catch { problem = error.localizedDescription }
            busy = false
        }
    }

    private func pick(_ opt: WorkTasks.Branch) {
        if !opt.follows && Novel.hasOutline(Works.get(workId)) {
            do { try Novel.setOutline(workId) { $0.drift = true } } catch { problem = "保存失败：\(error.localizedDescription)"; return }
        }
        start(StartArgs(title: opt.title, plan: opt.line))
    }

    /// 开下一章。落在没章纲的卷上先问一声；有章纲就把题目带上（走向选了的以走向为准）
    private func start(_ a: StartArgs) {
        let w = Works.get(workId)
        if Novel.hasOutline(w), Novel.volumeMissing(Novel.outlineOf(w), Works.nextNo(workId)) != nil { asking = a; return }
        begin(a, volumeFirst: false)
    }

    private func begin(_ a: StartArgs, volumeFirst: Bool) {
        let id = workId
        Task { @MainActor in
            if volumeFirst, let w = Works.get(id), let miss = Novel.volumeMissing(Novel.outlineOf(w), Works.nextNo(id)) {
                busy = true
                do { try Novel.applyVolume(id, miss.no, try await WorkTasks.volume(w, miss)) } catch { problem = error.localizedDescription }
                busy = false
            }
            do {
                let line = Novel.lineOf(Novel.outlineOf(Works.get(id)), Works.nextNo(id))
                let title = a.title.isEmpty ? (line?.title ?? "") : a.title
                if let row = try Works.addChapter(id, title: title, plan: a.plan, opening: a.opening, planFrom: a.planFrom, fromChapterId: a.fromChapterId) {
                    opened(row.id)
                }
            } catch { problem = "新建失败：\(error.localizedDescription)" }
        }
    }
}

// MARK: - 这一部的设定（只有这一个入口，第 5 条）

struct UsWorkEditView: View {
    let workId: String
    @State private var v = WorkForm()
    @State private var words = 0.0
    @State private var apiId = ""
    @State private var withTrans = false
    @State private var cover = ""
    @State private var picked: PhotosPickerItem?
    @State private var loaded = false
    @State private var problem: String?
    @State private var showLook = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let w = Works.get(workId)
        let saga = w?.string("kind") == Works.SAGA
        let presets = AppSettings.load().chatPresets
        let global = Int(AppSettings.load().num("sceneWords", 0))
        return Form {
            Section {
                TextField(saga ? "这部作品叫什么" : "这一则小剧场叫什么", text: $v.title)
                TextField(saga ? "主线" : "设定", text: $v.premise, axis: .vertical).lineLimit(4...16)
            }
            if saga, let w {
                WorkIdentitySection(who: "char", name: $v.charName, persona: $v.charPersona,
                                    generate: { try await WorkTasks.identity(w, who: "char") })
                WorkIdentitySection(who: "me", name: $v.meName, persona: $v.mePersona,
                                    generate: { try await WorkTasks.identity(w, who: "me") })
            }
            Section {
                HStack {
                    if !cover.isEmpty {
                        LocalImage(id: cover, maxPixel: 240).frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                    }
                    PhotosPicker(selection: $picked, matching: .images) { Text(cover.isEmpty ? "选择图片" : "更换图片") }
                    Spacer()
                    if !cover.isEmpty { Button("移除") { cover = "" }.buttonStyle(.borderless) }
                }
                HelpNote("显示在作品页的扉页上。留空时用标题的第一个字排一张。", title: "我们：封面")
            } header: { Text("封面") }
            WorkSwitchesSection(v: $v)
            Section {
                NumberRow(title: "篇幅", value: $words, unit: "字", placeholder: global > 0 ? "默认 \(global)" : "不写")
                HelpNote("写入提示词的目标字数，只对这一部生效。未填写时使用「设置 - 用量与上限」中的线下目标篇幅。这是目标而非上限，实际长度由模型决定。", title: "我们：篇幅")
                Picker("正文用的接口", selection: $apiId) {
                    Text("跟随全局").tag("")
                    ForEach(presets, id: \.id) { p in Text(p.name.isEmpty ? "未命名接口" : p.name).tag(p.id) }
                }
                HelpNote("这一部的正文使用这一套接口；简介、大纲与走向照旧按「任务用哪套接口」。选择的接口被删除或没有填全时，改用「任务用哪套接口」中长篇与番外的正文那一项。", title: "我们：正文用的接口")
                Toggle("附带译文", isOn: $withTrans)
                HelpNote("开启后，角色说的话后面附上译文，目标语言与这个角色私聊的翻译设置相同；私聊未开启翻译时不生效。不另外调用接口，回复会长一些。", title: "我们：附带译文")
            }
            WorkToneSection(tones: $v.tones, text: $v.toneText)
            Section {
                Button("外观") { showLook = true }
                HelpNote("字体、纸色、字号与版式。线下、长篇与番外共用这一套。", title: "我们：外观")
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("这一部")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) } }
        .navigationDestination(isPresented: $showLook) { StageLookView(sceneId: nil) }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task { @MainActor in
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw StoreError(message: "无法读取所选图片") }
                    cover = try Images.save(data, maxPixel: 640)
                } catch { problem = "图片处理失败：\(error.localizedDescription)" }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded, let w = Works.get(workId) else { return }
        loaded = true
        var f = WorkForm()
        f.kind = w.string("kind") == Works.SAGA ? Works.SAGA : Works.EXTRA
        f.chatId = w.string("chatId")
        f.from = w.string("chatId").isEmpty ? "cast" : "chat"
        f.title = w.string("title"); f.premise = w.string("premise")
        f.charName = w["charAs"]?["name"]?.string ?? ""; f.charPersona = w["charAs"]?["persona"]?.string ?? ""
        f.meName = w["meAs"]?["name"]?.string ?? ""; f.mePersona = w["meAs"]?["persona"]?.string ?? ""
        f.carry = w.bool("carry"); f.solo = w.bool("solo"); f.endNext = w.bool("endNext")
        f.opening = w.string("opening") == "me" ? "me" : "char"
        let take = Works.carryOf(w)
        f.carryChat = take["chat"] ?? false; f.carryMemory = take["memory"] ?? true; f.carryOther = take["other"] ?? false
        f.tones = Tone.ids(w); f.toneText = w.string("toneText")
        v = f
        words = max(0, w.number("words") ?? 0)
        apiId = w.string("apiId")
        withTrans = w.bool("withTrans")
        cover = w.string("cover")
    }

    private func save() {
        var patch: [String: JSONValue] = [
            "title": .string(v.title.trimmingCharacters(in: .whitespacesAndNewlines)),
            "premise": .string(v.premise.trimmingCharacters(in: .whitespacesAndNewlines)),
            "solo": .bool(v.solo), "endNext": .bool(v.endNext), "opening": .string(v.opening),
            "carryChat": .bool(v.carryChat), "carryMemory": .bool(v.carryMemory), "carryOther": .bool(v.carryOther),
            "tones": .array(v.tones.map { .string($0) }), "toneText": .string(v.toneText),
            "words": .number(words), "apiId": .string(apiId), "withTrans": .bool(withTrans),
            "cover": cover.isEmpty ? .null : .string(cover),
        ]
        if v.kind == Works.SAGA {
            patch["carry"] = .bool(!v.chatId.isEmpty && v.carry)
            patch["charAs"] = Works.identity((name: v.charName, persona: v.charPersona))
            patch["meAs"] = Works.identity((name: v.meName, persona: v.mePersona))
        }
        do { try Works.update(workId, patch); dismiss() } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}

/// 一篇自己的设定：题目、地点、时刻、情境、摘要
struct UsChapterEditView: View {
    let chapterId: String
    @State private var title = "", place = "", at = "", note = "", summary = ""
    @State private var loaded = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("题目", text: $title)
                TextField("地点", text: $place)
                TextField("时刻，例如 2026-01-01 周三 14:30", text: $at)
                HelpNote("留空表示不写。之后由正文里的时间标记继续推进。", title: "我们：时刻")
            }
            Section("情境") {
                TextField("这一篇开始时的处境", text: $note, axis: .vertical).lineLimit(3...10)
                HelpNote("是事实，不是指令。", title: "我们：情境")
            }
            if !summary.isEmpty {
                Section("摘要") {
                    TextField("摘要", text: $summary, axis: .vertical).lineLimit(4...16)
                    HelpNote("收篇时生成。后面几篇的设定区里带的就是它。", title: "我们：摘要")
                }
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("这一篇")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do {
                        try Works.updateChapter(chapterId, ["title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)),
                                                            "place": .string(place.trimmingCharacters(in: .whitespacesAndNewlines)),
                                                            "at": .string(at.trimmingCharacters(in: .whitespacesAndNewlines)),
                                                            "note": .string(note.trimmingCharacters(in: .whitespacesAndNewlines)),
                                                            "summary": .string(summary)])
                        dismiss()
                    } catch { problem = "保存失败：\(error.localizedDescription)" }
                }
            }
        }
        .onAppear {
            guard !loaded, let c = Works.getChapter(chapterId) else { return }
            loaded = true
            title = c.string("title"); place = c.string("place"); at = c.string("at"); note = c.string("note"); summary = c.string("summary")
        }
    }
}

// MARK: - 翻页时让出左缘

/// 翻页那一档里，左缘往右滑留给翻页（网页版 data-edge="off"）：这一页显示时关掉导航栏的左缘返回，离开时还原。
/// 返回照旧有导航栏上的返回键
struct PopGestureOff: UIViewControllerRepresentable {
    var on: Bool

    func makeUIViewController(context: Context) -> Holder { Holder() }

    func updateUIViewController(_ vc: Holder, context: Context) {
        vc.on = on
        vc.apply()
    }

    final class Holder: UIViewController {
        var on = false
        private weak var nav: UINavigationController?
        private var saved = true
        private var savedContent = true
        private var applied = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restore()
        }

        func apply() {
            guard on else { restore(); return }
            guard let nc = nav ?? navigationController, let g = nc.interactivePopGestureRecognizer else { return }
            if !applied {
                nav = nc
                saved = g.isEnabled
                if #available(iOS 26.0, *) { savedContent = nc.interactiveContentPopGestureRecognizer?.isEnabled ?? true }
                applied = true
            }
            g.isEnabled = false
            if #available(iOS 26.0, *) { nc.interactiveContentPopGestureRecognizer?.isEnabled = false }
        }

        func restore() {
            guard applied else { return }
            applied = false
            nav?.interactivePopGestureRecognizer?.isEnabled = saved
            if #available(iOS 26.0, *) { nav?.interactiveContentPopGestureRecognizer?.isEnabled = savedContent }
        }
    }
}
