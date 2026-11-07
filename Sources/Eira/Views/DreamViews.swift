import SwiftUI

/// 梦境（网页版 apps/dream，ARCHITECTURE 4.442、4.444）。第一屏是角色一栏：和当前身份有私聊的，外加做过梦的。
/// 进去是那个角色的开关与旋钮（第 5 条：想改「这个角色怎么做梦」时人就在这一页）与按夜列出的梦。
struct DreamHomeView: View {
    @State private var hero = true
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let list = Dream.choices()
        List {
            HeroHeader(eyebrow: "DREAMS", title: "梦境", shown: $hero)
            Section {
                Text("角色每晚一个梦，从它的记忆、进行中的事与心愿里抽取原料，按设定的怪诞程度拼成。每个角色各自开关，默认关闭；开启后每天醒来的时刻之后调用一次接口。")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            if list.isEmpty {
                EmptyState(title: "还没有可以做梦的角色", desc: "与角色建立私聊后，角色会出现在这里").listRowBackground(Color.clear)
            }
            Section {
                ForEach(list) { c in
                    NavigationLink { DreamCharView(charId: c.id) } label: {
                        HStack(spacing: Theme.pad) {
                            Avatar(imageId: c.avatar, name: c.displayName, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.displayName)
                                let last = Dream.last(c.id)
                                Text([last.map { "上一个梦：\(DreamText.date($0.string("date")))" } ?? "尚未做过梦", Dream.isAuto(c) ? "每晚自动" : ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .heroTitle("梦境", heroShown: hero)
        .onAppear { tick += 1 }
    }
}

enum DreamText {
    static func date(_ s: String) -> String {
        let p = s.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? "\(p[1]) 月 \(p[2]) 日" : ""
    }
}

struct DreamCharView: View {
    let charId: String
    @State private var tick = 0
    @State private var busy = false
    @State private var problem: String?
    @State private var opened: String?

    var body: some View {
        let _ = tick
        Group {
            if let c = (try? Repo.character(charId)) ?? nil { form(c) } else { EmptyState(title: "角色已不存在") }
        }
        .navigationTitle("\(((try? Repo.character(charId)) ?? nil)?.displayName ?? "")的梦")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: Binding(get: { opened.map { DreamOpen(id: $0) } }, set: { opened = $0?.id })) { d in DreamReadView(id: d.id) }
        .onAppear { tick += 1 }
    }

    private func set(_ patch: [String: JSONValue]) {
        do { try Diary.patchChar(charId, patch); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }

    private func num(_ key: String, _ value: Int) -> Binding<Double> {
        Binding(get: { Double(value) }, set: { set([key: .number($0)]) })
    }

    @ViewBuilder private func form(_ c: Character) -> some View {
        let auto = Dream.isAuto(c)
        let today = Dream.todayOf(c)
        let odds = Dream.oddsOf(c)
        let list = Dream.ofChar(charId)
        Form {
            Section {
                Toggle("每晚自动做梦", isOn: Binding(get: { auto }, set: { set(["dreamAuto": .bool($0)]) }))
                if auto && c.row.string("dreamAutoAt") == today && !c.row.string("dreamAutoError").isEmpty {
                    Text("今天没有做成：\(c.row.string("dreamAutoError"))。明天自动再试。").font(.footnote).foregroundStyle(Theme.danger)
                }
                NumberRow(title: "醒来的时刻", value: num("dreamHour", Dream.hourOf(c)), unit: "点", placeholder: "0", range: 0...23)
                Picker("怪诞程度", selection: Binding(get: { Dream.bizarreOf(c) }, set: { set(["dreamBizarre": .number(Double($0))]) })) {
                    ForEach(Dream.bizarre.indices, id: \.self) { i in Text("\(Dream.bizarre[i].label) · \(Dream.bizarre[i].desc)").tag(Dream.bizarre[i].value) }
                }
                NumberRow(title: "幕数", value: num("dreamActs", Int(c.row.number("dreamActs") ?? 0)), unit: "幕", placeholder: "3")
                NumberRow(title: "字数", value: num("dreamWords", Int(c.row.number("dreamWords") ?? 0)), unit: "字", placeholder: "3000")
            } footer: {
                Text(auto ? "已开启。每天 \(Dream.hourOf(c)) 点之后调用一次接口（应用打开时）。字数越多，一次调用的回复越长。"
                     : "已关闭。只有在下方手动请角色做梦时才调用接口。")
                HelpNote("醒来的时刻之后，当天的梦才会生成，按角色所在的时区计算。幕数为一个梦分几幕，填 0 按默认 3 幕。字数为全文大约多少字，填 0 按默认 3000 字。", title: "每晚自动做梦")
            }
            Section {
                ForEach(Dream.recall) { r in
                    NumberRow(title: r.label, value: Binding(get: { Double(odds[r.id] ?? 0) }, set: { v in
                        var o = odds.mapValues { JSONValue.number(Double($0)) }
                        o[r.id] = .number(v)
                        set(["dreamOdds": .object(o)])
                    }), unit: "%", placeholder: "0")
                }
                Toggle("随时间变淡", isOn: Binding(get: { Dream.fadeOn(c) }, set: { set(["dreamFade": .bool($0)]) }))
            } header: { GroupTitle("醒后记忆程度") } footer: {
                Text("每个梦醒来时在本机按上面的比例抽一次，不调用接口。")
                HelpNote("完整为记得整个梦；碎片为只剩两三个接不上的画面；只剩感觉为只记得情绪。三项按比例计算，加起来不必是 100，全部填 0 按默认。随时间变淡开启后，角色所在时区过了 12 点，记得的部分降一档：完整变为碎片，碎片变为只剩感觉；第二天起同样按降一档计。关闭后一直保持醒来时的样子。", title: "醒后记忆程度")
            }
            Section {
                Toggle("写进对话", isOn: Binding(get: { Dream.injectOn(c) }, set: { set(["dreamInject": .string($0 ? "on" : "off")]) }))
                Toggle("记成记忆", isOn: Binding(get: { Dream.memoryOn(c) }, set: { set(["dreamMemory": .bool($0)]) }))
            } header: { GroupTitle("梦之后") } footer: {
                HelpNote("写进对话开启后，当天的梦注入该角色的单聊，内容为角色此刻记得的部分，并可在回复中以卡片分享给你；是否分享由角色决定。关闭后对话中不提及梦。记成记忆为每个梦记成一条 C 级事件记忆，内容为醒来时记得的部分，忘掉的不进记忆；关闭后梦只保存在此处。", title: "梦之后")
            }
            Section {
                Button(busy ? "正在做梦" : "现在做一个梦") { now() }.disabled(busy)
            } footer: { Text("点击后调用一次接口，走副用接口。原料与拼法由应用抽取，模型只负责写成文字。") }
            ProblemSection(text: problem)
            Section {
                ForEach(list, id: \.id) { d in
                    NavigationLink { DreamReadView(id: d.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(DreamText.date(d.string("date")))\(d.string("title").isEmpty ? "" : " · \(d.string("title"))")")
                            Text([d.string("mood"), Dream.recallLabel(d.string("recallLevel")), "\(Dream.sceneTexts(d).count) 幕", d.string("source") == "now" ? "手动" : ""]
                                .filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                if list.isEmpty { Text("还没有做过梦。").font(.footnote).foregroundStyle(Theme.secondaryText) }
            } header: { GroupTitle("共 \(list.count) 个梦") }
        }
    }

    private func now() {
        busy = true
        problem = nil
        Task {
            do { let row = try await Dream.write(charId, source: "now"); opened = row.id }
            catch { problem = "没有做成：\(error.localizedDescription)" }
            busy = false
            tick += 1
        }
    }
}

struct DreamOpen: Identifiable, Hashable { var id: String }

/// 读一个梦：正文分幕；下面折叠「这个梦里有」：抽到的原料与每一幕的拼法。不做解梦
struct DreamReadView: View {
    let id: String
    @State private var open = false
    @State private var confirmDelete = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let d = Dream.get(id) { page(d) } else { EmptyState(title: "这个梦已不存在") }
        }
        .navigationTitle(Dream.get(id).flatMap { ((try? Repo.character($0.string("charId"))) ?? nil)?.displayName } ?? "梦境")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("删除") { confirmDelete = true } } }
        .confirmationDialog("删除这个梦", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Dream.remove(id); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
        } message: { Text("删除后不可恢复。记成的记忆不会一并删除。") }
    }

    @ViewBuilder private func page(_ d: Row) -> some View {
        let char = (try? Repo.character(d.string("charId"))) ?? nil
        let now = Dream.remembered(d, char)
        let level = d.string("recallLevel").isEmpty ? "full" : d.string("recallLevel")
        let materials = d["materials"]?.array ?? []
        let scenes = d["plan"]?["scenes"]?.array ?? []
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.sp2) {
                    Text(d.string("title").isEmpty ? "无题" : d.string("title")).font(Theme.serif(22))
                    Text([DreamText.date(d.string("date")), d.string("mood"), d.string("source") == "now" ? "手动" : "每晚自动"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                ForEach(Array((d["scenes"]?.array ?? []).enumerated()), id: \.offset) { _, s in
                    let shown = MessageActions.transPair(s["text"]?.string ?? "", s["textTrans"]?.string ?? "", mode: MomentText.transMode)
                    VStack(alignment: .leading, spacing: Theme.sp1) {
                        Text(shown.main).textSelection(.enabled)
                        if !shown.sub.isEmpty { Text(shown.sub).font(.subheadline).foregroundStyle(Theme.secondaryText) }
                    }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("醒来时：\(Dream.recallLabel(level))")
                    let lines = [
                        Dream.recallLabel(now.level) != Dream.recallLabel(level) ? "此刻：\(Dream.recallLabel(now.level))（随时间变淡）" : "",
                        level == "full" ? d.string("recall") : "",
                        level == "fragment" ? d.strings("kept").map { "· \($0)" }.joined(separator: "\n") : "",
                        level == "trace" ? "只记得「\(d.string("mood").isEmpty ? "一种说不清的感觉" : d.string("mood"))」" : "",
                        d.string("memoryId").isEmpty ? "" : "已记成一条记忆",
                    ].filter { !$0.isEmpty }
                    if !lines.isEmpty { Text(lines.joined(separator: "\n")).font(.footnote).foregroundStyle(Theme.secondaryText) }
                }
            } header: { GroupTitle("角色醒来记得的") }
            Section {
                Button { open.toggle() } label: {
                    LabeledContent("这个梦里有", value: "\(materials.count) 样原料，\(scenes.reduce(0) { $0 + ($1["twists"]?.array?.count ?? 0) }) 处扭曲")
                }
                .foregroundStyle(Theme.text)
            }
            if open {
                Section {
                    ForEach(Array(materials.enumerated()), id: \.offset) { _, m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m["text"]?.string ?? "")
                            Text("\(m["key"]?.string ?? "") · \(Dream.kinds[m["kind"]?.string ?? ""] ?? (m["kind"]?.string ?? ""))").font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if materials.isEmpty { Text("没有原料：该角色当时没有记忆、进行中的事或心愿。").font(.footnote).foregroundStyle(Theme.secondaryText) }
                } header: { GroupTitle("原料") }
                Section {
                    ForEach(Array(scenes.enumerated()), id: \.offset) { _, sc in
                        let keys = (sc["keys"]?.array ?? []).compactMap(\.string)
                        let tw = (sc["twists"]?.array ?? []).map { t -> String in
                            let ks = (t["keys"]?.array ?? []).compactMap(\.string)
                            return "\(Dream.twistLabel(t["op"]?.string ?? ""))\(ks.isEmpty ? "" : "（\(ks.joined(separator: "、"))）")"
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("第 \(Int(sc["n"]?.number ?? 0)) 幕")
                            Text(([keys.isEmpty ? "" : "原料 \(keys.joined(separator: "、"))"] + tw).filter { !$0.isEmpty }.joined(separator: "\n"))
                                .font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if let ret = d["plan"]?["returned"], ret.object != nil, let from = ret["fromId"]?.string {
                        NavigationLink { DreamReadView(id: from) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("回来的一幕")
                                Text("上一个梦里关于「\(ret["about"]?.string ?? "")」的一幕再次出现").font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    if scenes.isEmpty { Text("没有记录拼法。").font(.footnote).foregroundStyle(Theme.secondaryText) }
                } header: { GroupTitle("拼法") }
            }
            ProblemSection(text: problem)
        }
    }
}
