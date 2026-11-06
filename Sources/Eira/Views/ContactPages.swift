import SwiftUI
import UniformTypeIdentifiers

// 「联系」里资料页往下的几页（网页版 apps/contact 的 NpcPage、NetPage、AltsPage、NowPage 与 ImportPage 的角色包那一半）。
// 人设正文一个字都不露（网页版第 6 条）；唯一的例外是批量生成 NPC 的确认页：东西还没入库，不看内容没法决定存不存。

/// 选一个圈子（4.593）：已有的圈子是一排可点的名字，新的直接填
struct CirclePick: View {
    let circles: [String]
    @Binding var value: String
    var label = "圈子"

    var body: some View {
        TextField("\(label)（留空为未分组）", text: $value)
        if !circles.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.sp2) {
                    ForEach(circles, id: \.self) { c in
                        Button(c) { value = value == c ? "" : c }
                            .font(.system(size: 13))
                            .padding(.horizontal, Theme.sp3).padding(.vertical, 6)
                            .background(value == c ? Theme.surface3 : Theme.surface2, in: Capsule())
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private func charName(_ id: String) -> String {
    let n = (try? Repo.character(id))?.row.string("name") ?? ""
    return n.isEmpty ? "已删除" : n
}

// MARK: - 关联角色（NpcPage）

struct NpcPageView: View {
    let charId: String
    @State private var char: Character?
    @State private var groups: [Relations.Group] = []
    @State private var rels: [Relations.Rel] = []
    @State private var circles: [String] = []
    @State private var others: [Character] = []
    @State private var only = true
    @State private var count = 4
    @State private var circle = ""
    @State private var mutual = false
    @State private var busy = false
    @State private var rows: [NpcGen.Draft]?
    @State private var off = Set<Int>()
    @State private var problem: String?
    @State private var note: String?
    @State private var sheet: Sheet?
    @Environment(\.dismiss) private var dismiss

    enum Sheet: Identifiable {
        case typed, pick, sort, rel(String)
        var id: String {
            switch self {
            case .typed: return "typed"
            case .pick: return "pick"
            case .sort: return "sort"
            case .rel(let c): return "rel-\(c)"
            }
        }
    }

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let note { Text(note).font(.footnote).foregroundStyle(Theme.text2) }
            if let rows { draftList(rows) } else { mainList }
        }
        .navigationTitle("关联角色")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(item: $sheet, onDismiss: reload) { s in
            NavigationStack {
                switch s {
                case .typed: NpcTypedSheet(charId: charId, circles: circles) { sheet = nil; note = $0.isEmpty ? nil : $0 }
                case .pick: NpcPickSheet(charId: charId, others: others) { sheet = nil; note = $0.isEmpty ? nil : $0 }
                case .sort: CircleSortSheet(charId: charId, rels: rels, circles: circles) { sheet = nil }
                case .rel(let other): RelationEditSheet(charId: charId, otherId: other, circles: circles) { sheet = nil }
                }
            }
        }
    }

    @ViewBuilder private var mainList: some View {
        if groups.count > 1 || !(groups.first?.circle.isEmpty ?? true) {
            ForEach(groups) { g in
                Section { ForEach(g.items) { relRow($0) } } header: { GroupTitle("\(g.circle.isEmpty ? "未分圈子" : g.circle) · \(g.items.count)") }
            }
        } else if !rels.isEmpty {
            Section { ForEach(rels) { relRow($0) } } header: { GroupTitle("已经连上 · \(rels.count)") }
        }
        Section {
            if rels.count >= 2 {
                Button { sheet = .sort } label: { IconRow(title: "按圈子整理", icon: "layers") }
                HelpNote("选择几条关系，一并归入某个圈子。圈子只是该角色自己的分法，资料页与关系网按圈子分段显示", title: "按圈子整理")
            }
            Button { sheet = .typed } label: { IconRow(title: "直接新建一个人", icon: "plus") }
            HelpNote("在此处填写姓名与关系即可，无需先到「联系」中新建再回来关联", title: "直接新建一个人")
            Button { if others.isEmpty { note = "没有可关联的其他角色" } else { sheet = .pick } } label: {
                IconRow(title: "关联已有的角色", icon: "users", value: "从已有的 \(others.count) 个角色中选择")
            }
        } header: { if rels.isEmpty { GroupTitle("已经连上 · 0") } }
        Section {
            Toggle("只提取设定里写到的人", isOn: $only)
            HelpNote("开启后，只把人设、核心设定、情境以及该角色挂着的世界书里已经写到的人物建成 NPC，不另编新人，也不凑数量；设定里没写到的人不会出现。关闭后，先写设定里写到的人，再另编新人补足填写的数量。两种都只调用一次接口", title: "只提取设定里写到的人")
            if !only {
                LabeledContent("生成几个") {
                    TextField("个数", value: $count, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                Text("没有上限，填多少生成多少。数量越多，这一次请求也越长。").font(.footnote).foregroundStyle(Theme.text2)
            }
            CirclePick(circles: circles, value: $circle, label: "这一批的圈子")
            HelpNote("填了圈子，这一批都生成为该圈子里的人，并归入该圈子。留空则各自生成，不分圈子。", title: "这一批的圈子")
            Toggle("这一圈的人彼此认识", isOn: $mutual)
            HelpNote("开启后，这一批生成的人之间、以及与该圈子里已有的人之间也建立关联，关系写作「圈子名成员」。已经认识的不改。不多调用接口。", title: "这一圈的人彼此认识")
            Button(action: generate) {
                Text(busy ? "正在写" : only ? "从设定中提取" : "生成 \(count) 个").frame(maxWidth: .infinity)
            }
            .buttonStyle(EiraButtonStyle(kind: .primary, full: true))
            .disabled(busy)
        } header: { GroupTitle("批量生成") } footer: {
            Text("调用一次接口（副用），读取该角色的人设、核心设定、情境与挂着的世界书。生成结果先行展示，取消勾选后再保存。")
        }
    }

    @ViewBuilder private func draftList(_ rows: [NpcGen.Draft]) -> some View {
        Section {
            ForEach(rows.indices, id: \.self) { i in
                let n = rows[i]
                Button {
                    if off.contains(i) { off.remove(i) } else { off.insert(i) }
                } label: {
                    HStack(alignment: .top, spacing: Theme.sp3) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(n.name)　\(n.relation)").font(.system(size: 15, weight: .medium))
                            let bits = [n.age, n.gender, n.birthday].filter { !$0.isEmpty }.joined(separator: " · ")
                            if !bits.isEmpty { Text(bits).font(.system(size: 12)).foregroundStyle(Theme.text3) }
                            if !n.signature.isEmpty { Text(n.signature).font(.system(size: 13)).foregroundStyle(Theme.text2) }
                            Text(n.persona).font(.system(size: 13)).foregroundStyle(Theme.text2)
                        }
                        Spacer(minLength: 0)
                        SvgIcon(name: off.contains(i) ? "close" : "check", size: 17, color: Theme.text2)
                    }
                    .opacity(off.contains(i) ? 0.45 : 1)
                }
                .buttonStyle(.plain)
            }
        } header: {
            GroupTitle("写出 \(rows.count) 个")
        } footer: {
            Text("勾掉不要的再存。存入后它们是独立的角色，也能单独聊天。")
        }
        Section {
            Button("存入 \(rows.count - off.count) 个", action: saveDraft).buttonStyle(EiraButtonStyle(kind: .primary, full: true))
            Button("重来") { self.rows = nil; off = [] }.buttonStyle(EiraButtonStyle(kind: .ghost, full: true))
        }
        .listRowBackground(Color.clear)
    }

    private func relRow(_ r: Relations.Rel) -> some View {
        HStack {
            Button { sheet = .rel(r.charId) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(charName(r.charId)).font(.system(size: 15, weight: .medium))
                    if !r.label.isEmpty { Text(r.label).font(.system(size: 12)).foregroundStyle(Theme.text3) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { cut(r) } label: { SvgIcon(name: "close", size: 15, color: Theme.text3) }
                .buttonStyle(.borderless)
                .accessibilityLabel("解除与\(charName(r.charId))的关联")
        }
    }

    private func reload() {
        do {
            char = try Repo.character(charId)
            rels = Relations.of(charId)
            groups = Relations.grouped(charId)
            circles = Relations.circles(charId)
            let linked = Set(rels.map(\.charId))
            others = try Repo.characters().filter { $0.id != charId && !linked.contains($0.id) }
                .sorted { ($0.isNpc ? 1 : 0, $0.displayName) < ($1.isNpc ? 1 : 0, $1.displayName) }
            if char == nil { problem = "该角色已被删除" }
        } catch { problem = error.localizedDescription }
    }

    private func cut(_ r: Relations.Rel) {
        do { try Relations.unlink(charId, r.charId); note = "已解除关联"; reload() }
        catch { problem = "解除失败：\(error.localizedDescription)" }
    }

    private func generate() {
        busy = true; problem = nil; note = nil; off = []
        let (n, c, o) = (max(1, count), circle, only)
        Task {
            do {
                let got = try await NpcGen.generate(charId: charId, count: n, circle: c, only: o)
                await MainActor.run { rows = got; note = "已生成 \(got.count) 个" }
            } catch {
                await MainActor.run { problem = error.localizedDescription }
            }
            await MainActor.run { busy = false }
        }
    }

    private func saveDraft() {
        guard let rows else { return }
        let keep = rows.indices.filter { !off.contains($0) }.map { rows[$0] }
        guard !keep.isEmpty else { note = "尚未勾选任何角色"; return }
        do {
            let made = try NpcGen.commit(charId: charId, keep, circle: circle, mutual: mutual)
            self.rows = nil
            note = "已添加 \(made.count) 个"
            reload()
        } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}

/// 直接打字建一个人，建完当场关联（网页版 addTyped）
struct NpcTypedSheet: View {
    let charId: String
    let circles: [String]
    var done: (String) -> Void
    @State private var name = ""
    @State private var mine = ""
    @State private var theirs = ""
    @State private var circle = ""
    @State private var signature = ""
    @State private var persona = ""
    @State private var problem: String?

    var body: some View {
        let who = charName(charId)
        Form {
            Section { TextField("姓名（必填）", text: $name) }
            Section("在 \(who) 看来，这个人是") { TextField("例如 妈妈 / 室友 / 前男友", text: $mine) }
            Section {
                TextField("例如 女儿 / 室友 / 前女友", text: $theirs)
            } header: { Text("反过来，在这个人看来，\(who) 是") } footer: {
                HelpNote("留空则与上一栏相同。同事、邻居一类的关系本就对称。", title: "反过来的关系")
            }
            Section("圈子") { CirclePick(circles: circles, value: $circle) }
            Section {
                TextField("一句话签名（可留空）", text: $signature)
            } footer: { HelpNote("列表中显示的就是这一句。", title: "一句话签名") }
            Section {
                TextField("人设（可留空）", text: $persona, axis: .vertical).lineLimit(4...20)
            } footer: { HelpNote("可留空，之后仍可在该角色的编辑页中补写。", title: "人设") }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("新建一个人")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { done("") } }
            ToolbarItem(placement: .confirmationAction) { Button("建好并关联", action: save) }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { problem = "请填写姓名"; return }
        let m = mine.trimmingCharacters(in: .whitespacesAndNewlines), t = theirs.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // 反向没填就沿用正向
            let made = try NpcGen.commit(charId: charId, [NpcGen.Draft(name: n, signature: signature.trimmingCharacters(in: .whitespacesAndNewlines),
                persona: persona.trimmingCharacters(in: .whitespacesAndNewlines), relation: t.isEmpty ? m : t, reverse: m.isEmpty ? t : m)],
                circle: circle)
            done("已添加 \(made.first?.row.string("name") ?? n)")
        } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}

/// 从已有角色里挑一个连上：先问两个方向各是什么关系
struct NpcPickSheet: View {
    let charId: String
    let others: [Character]
    var done: (String) -> Void
    @State private var chosen: Character?
    @State private var label = ""
    @State private var back = ""
    @State private var problem: String?

    var body: some View {
        let who = charName(charId)
        List {
            if let c = chosen {
                Section("在 \(who) 看来，\(c.row.string("name")) 是什么关系") { TextField("例如 妈妈 / 室友 / 前男友", text: $label) }
                Section("反过来，在 \(c.row.string("name")) 看来，\(who) 是什么关系") { TextField("例如 女儿 / 室友 / 前女友", text: $back) }
                Section {
                    Button("建立关联") {
                        let l = label.trimmingCharacters(in: .whitespacesAndNewlines), b = back.trimmingCharacters(in: .whitespacesAndNewlines)
                        do { try Relations.link(charId, c.id, labelForA: l, labelForB: b.isEmpty ? l : b); done("已建立关联") }
                        catch { problem = "保存失败：\(error.localizedDescription)" }
                    }
                    .buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(others) { c in
                    Button { chosen = c } label: {
                        HStack(spacing: Theme.pad) {
                            Avatar(imageId: c.avatar, name: c.displayName, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.displayName)
                                if !c.signature.isEmpty { Text(c.signature).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
        }
        .navigationTitle("选择要关联的角色")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { done("") } } }
    }
}

/// 改某一条关系：两个方向的标签与这一方的圈子
struct RelationEditSheet: View {
    let charId: String
    let otherId: String
    let circles: [String]
    var done: () -> Void
    @State private var label = ""
    @State private var back = ""
    @State private var circle = ""
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        let a = charName(charId), b = charName(otherId)
        Form {
            Section("在 \(a) 看来，\(b) 是") { TextField("关系", text: $label) }
            Section("反过来，在 \(b) 看来，\(a) 是") { TextField("关系", text: $back) }
            Section("圈子") { CirclePick(circles: circles, value: $circle) }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("\(a) 与 \(b)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", action: done) }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do {
                        try Relations.set(charId, otherId, label: label, circle: circle)
                        try Relations.set(otherId, charId, label: back)
                        done()
                    } catch { problem = "保存失败：\(error.localizedDescription)" }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let r = Relations.of(charId).first { $0.charId == otherId }
            label = r?.label ?? ""; circle = r?.circle ?? ""
            back = Relations.of(otherId).first { $0.charId == charId }?.label ?? ""
        }
    }
}

/// 按圈子整理：选几条关系一并归入某个圈子；圈子改名
struct CircleSortSheet: View {
    let charId: String
    let rels: [Relations.Rel]
    let circles: [String]
    var done: () -> Void
    @State private var picked = Set<String>()
    @State private var circle = ""
    @State private var renaming: String?
    @State private var newName = ""
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                CirclePick(circles: circles, value: $circle, label: "所属圈子")
            } footer: { HelpNote("选一个已有的圈子，或填一个新的。留空表示设为未分组。", title: "所属圈子") }
            Section {
                ForEach(rels) { r in
                    Button {
                        if picked.contains(r.charId) { picked.remove(r.charId) } else { picked.insert(r.charId) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(charName(r.charId))
                                let sub = [r.label, r.circle.isEmpty ? "" : "现在在「\(r.circle)」"].filter { !$0.isEmpty }.joined(separator: " · ")
                                if !sub.isEmpty { Text(sub).font(.system(size: 12)).foregroundStyle(Theme.text3) }
                            }
                            Spacer()
                            if picked.contains(r.charId) { SvgIcon(name: "check", size: 17, color: Theme.text) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: { GroupTitle("选择关系 · 已选 \(picked.count)") }
            Section {
                let c = circle.trimmingCharacters(in: .whitespacesAndNewlines)
                Button(c.isEmpty ? "设为未分组" : "归入「\(c)」") {
                    do { try Relations.setCircle(charId, Array(picked), c); done() }
                    catch { problem = "保存失败：\(error.localizedDescription)" }
                }
                .buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                .disabled(picked.isEmpty)
            }
            .listRowBackground(Color.clear)
            if !circles.isEmpty {
                Section {
                    ForEach(circles, id: \.self) { c in
                        Button { renaming = c; newName = c } label: { IconRow(title: c, icon: "edit") }
                    }
                } header: { GroupTitle("圈子改名") }
            }
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
        }
        .navigationTitle("按圈子整理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭", action: done) } }
        .alert("圈子改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("圈子名", text: $newName)
            Button("取消", role: .cancel) { renaming = nil }
            Button("改名") {
                let to = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let from = renaming, !to.isEmpty, to != from {
                    do { try Relations.renameCircle(charId, from: from, to: to); if circle == from { circle = to }; done() }
                    catch { problem = "改名失败：\(error.localizedDescription)" }
                }
                renaming = nil
            }
        }
    }
}

// MARK: - 关系网（NetPage）

/// 中心是当前角色，第一圈是直接关系，第二圈是关系的关系。手画，不引图库：节点数就这么点
struct NetPageView: View {
    let charId: String
    @Binding var path: NavigationPath
    @State private var nodes: [Relations.Node] = []
    @State private var edges: [Relations.Edge] = []
    @State private var order: [String] = []
    @State private var circleOf: [String: String] = [:]
    @State private var name = ""

    private let W: CGFloat = 380, R1: CGFloat = 116, R2: CGFloat = 170

    var body: some View {
        List {
            if nodes.count <= 1 {
                EmptyState(title: "暂无关联角色", desc: "\(name) 目前没有任何关联。添加关联角色后，此处会绘制关系网。")
                    .listRowBackground(Color.clear)
            } else {
                graph
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                Section {} footer: {
                    Text("共 \(nodes.count) 人，\(edges.count) 条关系。点击圆圈可打开该角色的资料。连线上的文字表示：在\(name)眼中，对方是什么身份。\(order.isEmpty ? "" : "同一圈子的人排在一起，圈子名写在外侧。")")
                }
            }
            Section {
                NavigationLink { NpcPageView(charId: charId) } label: { IconRow(title: "关联角色", icon: "plus") }
            }
        }
        .navigationTitle("关系网")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func reload() {
        let g = Relations.graph(around: charId)
        nodes = g.nodes; edges = g.edges
        order = Relations.circles(charId)
        circleOf = Dictionary(Relations.of(charId).map { ($0.charId, $0.circle) }, uniquingKeysWith: { a, _ in a })
        name = (try? Repo.character(charId))?.row.string("name") ?? ""
    }

    /// 各节点的位置（视图坐标系 W×W）与第一圈各圈子占的那一段弧
    private func layout() -> (pos: [String: CGPoint], sectors: [(circle: String, s: Double, e: Double, full: Bool)]) {
        let c = CGPoint(x: W / 2, y: W / 2)
        var pos: [String: CGPoint] = [charId: c]
        var angles: [String: Double] = [:]
        func rank(_ id: String) -> Int { order.firstIndex(of: circleOf[id] ?? "") ?? order.count }
        let r1 = nodes.filter { $0.depth == 1 }.enumerated().sorted { (rank($0.element.id), $0.offset) < (rank($1.element.id), $1.offset) }.map(\.element)
        let r2 = nodes.filter { $0.depth == 2 }
        for (d, list, r) in [(1, r1, R1), (2, r2, R2)] {
            let n = Double(max(1, list.count))
            for (i, node) in list.enumerated() {
                let a = Double(i) / n * .pi * 2 - .pi / 2 + (d == 2 ? .pi / n : 0)
                angles[node.id] = a
                pos[node.id] = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            }
        }
        let half = Double.pi / Double(max(1, r1.count))
        let sectors = order.compactMap { circ -> (String, Double, Double, Bool)? in
            let idx = r1.indices.filter { circleOf[r1[$0].id] == circ }
            guard let f = idx.first, let l = idx.last, let s = angles[r1[f].id], let e = angles[r1[l].id] else { return nil }
            return (circ, s - half, e + half, idx.count == r1.count)
        }
        return (pos, sectors.map { (circle: $0.0, s: $0.1, e: $0.2, full: $0.3) })
    }

    private var graph: some View {
        GeometryReader { geo in
            let k = geo.size.width / W
            let lay = layout()
            let pos = lay.pos
            let sectors = lay.sectors
            let depth = Dictionary(nodes.map { ($0.id, $0.depth) }, uniquingKeysWith: { a, _ in a })
            ZStack {
                ForEach(Array(sectors.enumerated()), id: \.offset) { i, sc in
                    Path { p in
                        let c = CGPoint(x: W / 2 * k, y: W / 2 * k)
                        if sc.full {
                            p.addEllipse(in: CGRect(x: c.x - (R1 + 24) * k, y: c.y - (R1 + 24) * k, width: (R1 + 24) * 2 * k, height: (R1 + 24) * 2 * k))
                        } else {
                            p.move(to: c)
                            p.addArc(center: c, radius: (R1 + 24) * k, startAngle: .radians(sc.s), endAngle: .radians(sc.e), clockwise: false)
                            p.closeSubpath()
                        }
                    }
                    .fill(i % 2 == 0 ? Theme.surface2 : Theme.surface3)
                    let mid = (sc.s + sc.e) / 2
                    Text(sc.circle).font(.system(size: 10)).foregroundStyle(Theme.text2)
                        .position(x: (W / 2 + cos(mid) * (R1 + 34)) * k, y: (W / 2 + sin(mid) * (R1 + 34)) * k)
                }
                ForEach(edges) { e in
                    // a 永远是更靠中心的那一端，标签固定落在靠外的一侧
                    let inner = (depth[e.a] ?? 9) <= (depth[e.b] ?? 9)
                    if let a = pos[inner ? e.a : e.b], let b = pos[inner ? e.b : e.a] {
                        Path { p in p.move(to: CGPoint(x: a.x * k, y: a.y * k)); p.addLine(to: CGPoint(x: b.x * k, y: b.y * k)) }
                            .stroke(Theme.border2, lineWidth: 1)
                        if !e.label.isEmpty {
                            Text(e.label).font(.system(size: 9)).foregroundStyle(Theme.text3)
                                .position(x: (a.x + (b.x - a.x) * 0.45) * k, y: (a.y + (b.y - a.y) * 0.45 - 6) * k)
                        }
                    }
                }
                ForEach(nodes) { n in
                    if let p = pos[n.id] {
                        let r: CGFloat = n.depth == 0 ? 26 : n.depth == 1 ? 20 : 16
                        Button {
                            if n.id != charId { path.append(ContactsView.Route.profile(n.id)) }
                        } label: {
                            ZStack {
                                Circle().fill(n.depth == 0 ? Theme.accent : Theme.surface)
                                Circle().strokeBorder(Theme.border, lineWidth: 1)
                                Text(String(n.name.prefix(1))).font(.system(size: r * 0.62 * k))
                                    .foregroundStyle(n.depth == 0 ? Theme.onAccent : Theme.text)
                            }
                            .frame(width: r * 2 * k, height: r * 2 * k)
                        }
                        .buttonStyle(.plain)
                        .position(x: p.x * k, y: p.y * k)
                        Text(n.name).font(.system(size: 10)).foregroundStyle(Theme.text2).lineLimit(1)
                            .position(x: p.x * k, y: (p.y + r + 10) * k)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(name)的关系网，共 \(nodes.count) 个人")
        }
    }
}

// MARK: - 整理小号（AltsPage，4.305）

struct AltsPageView: View {
    @State private var alts: [Character] = []
    @State private var all: [String: Character] = [:]
    @State private var counts: [String: Int] = [:]
    @State private var picked = Set<String>()
    @State private var ask = false
    @State private var note: String?
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if let note { Text(note).font(.footnote).foregroundStyle(Theme.text2) }
            if alts.isEmpty {
                EmptyState(title: "没有小号", desc: "角色开设的小号会列在这里，可以选择多个一并删除。").listRowBackground(Color.clear)
            }
            ForEach(roots, id: \.self) { r in
                Section { ForEach(alts.filter { $0.parentId == r }) { row($0) } } header: { GroupTitle("\(all[r]?.row.string("name") ?? "") 的小号") }
            }
            let orphans = alts.filter { all[$0.parentId ?? ""] == nil }
            if !orphans.isEmpty { Section { ForEach(orphans) { row($0) } } header: { GroupTitle("本体已删除") } }
            if !alts.isEmpty {
                Section {
                    Button(picked.isEmpty ? "删除所选" : "删除所选的 \(picked.count) 个") { ask = true }
                        .buttonStyle(EiraButtonStyle(kind: .danger, full: true))
                        .disabled(picked.isEmpty)
                } footer: {
                    Text("选择多个小号后一并删除。删除后，小号的会话、消息与记忆一并清除，本体与本体的会话不受影响。不删除也不影响使用。")
                }
            }
        }
        .navigationTitle("整理小号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !alts.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    let every = picked.count == alts.count
                    Button(every ? "全不选" : "全选") { picked = every ? [] : Set(alts.map(\.id)) }
                }
            }
        }
        .confirmationDialog("删除 \(picked.count) 个小号", isPresented: $ask, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: drop)
        } message: {
            Text("连同这些小号的会话（共 \(picked.reduce(0) { $0 + (counts[$1] ?? 0) }) 条消息）与记忆一并删除，无法恢复。本体不受影响。")
        }
        .onAppear(perform: reload)
    }

    private var roots: [String] {
        var out: [String] = []
        for a in alts { if let p = a.parentId, all[p] != nil, !out.contains(p) { out.append(p) } }
        return out
    }

    private func row(_ a: Character) -> some View {
        Button {
            if picked.contains(a.id) { picked.remove(a.id) } else { picked.insert(a.id) }
        } label: {
            HStack(spacing: Theme.sp3) {
                Image(systemName: picked.contains(a.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.text)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.row.string("name"))
                    let opened = a.row.number("altOpenedAt") ?? 0
                    let sub = [a.row.bool("altDisclosed") ? "已承认" : "未承认", opened > 0 ? "开设于 \(Self.day(opened))" : "",
                               "\(counts[a.id] ?? 0) 条消息", a.row.string("altReason").isEmpty ? "" : "理由：\(a.row.string("altReason"))"]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                    Text(sub).font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func day(_ ms: Double) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(millis: ms))
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private func reload() {
        do {
            let chars = try Repo.characters()
            all = Dictionary(chars.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            alts = chars.filter { !($0.parentId ?? "").isEmpty }.sorted { ($0.row.number("altOpenedAt") ?? 0) < ($1.row.number("altOpenedAt") ?? 0) }
            let chats = try Repo.chats()
            var n: [String: Int] = [:]
            for a in alts {
                n[a.id] = try chats.filter { $0.characterIds.contains(a.id) }.reduce(0) { $0 + (try Database.shared.count(Collections.messages, where: $1.id)) }
            }
            counts = n
            picked = picked.filter { all[$0] != nil }
        } catch { problem = error.localizedDescription }
    }

    private func drop() {
        let ids = picked.filter { all[$0] != nil }
        do {
            for id in ids { try People.deleteCharacter(id) }
            note = "已删除 \(ids.count) 个小号"
            picked = []
            NotificationCenter.default.post(name: .eiraChatChanged, object: nil)
        } catch { problem = "删除失败：\(error.localizedDescription)" }
        reload()
    }
}

// MARK: - 近况（NowPage，4.381）

struct NowPageView: View {
    let charId: String
    @State private var snap: CharNow.Snapshot?
    @State private var name = ""

    var body: some View {
        List {
            if let s = snap {
                if s.isEmpty {
                    EmptyState(title: "暂无近况", desc: "开启每日日程、身体状态、朋友圈或日记后，这里汇总显示。本页只读取已有记录，不调用接口。")
                        .listRowBackground(Color.clear)
                }
                if let t = s.trip {
                    Section { IconRow(title: t, icon: "compass") } header: { GroupTitle("出行") } footer: { HelpNote("出行期间不显示日程", title: "出行") }
                }
                if let d = s.day {
                    Section {
                        line(d.slot.isEmpty ? "此刻" : "此刻：\(d.slot)", icon: "clock",
                             [d.now.joined(separator: "；"), d.meal, d.event.isEmpty ? "" : "今天发生的事：\(d.event)"].filter { !$0.isEmpty }.joined(separator: "　").ifEmpty("这一时段没有安排"))
                        if !d.summary.isEmpty {
                            line("今天的安排", icon: "calendar", d.summary.joined(separator: "\n"), right: d.total > 0 ? "\(d.done)/\(d.total)" : "")
                        }
                    } header: { GroupTitle("今天") }
                }
                if s.body != nil || s.worn != nil {
                    Section {
                        if let b = s.body { line("身体状态", icon: "heart", b.joined(separator: "　")) }
                        if let w = s.worn { line("今天穿的", icon: "hanger", w.joined(separator: "、")) }
                    } header: { GroupTitle("状态") }
                }
                if let m = s.music {
                    Section {
                        line(m.recent ? "最近播放" : "近来常听", icon: "music", m.songs.joined(separator: "\n"), right: m.at > 0 ? TimeText.day(Date(millis: m.at)) : "")
                    } header: { GroupTitle("在听的歌") }
                }
                if !s.moments.isEmpty {
                    Section {
                        ForEach(s.moments) { m in
                            line(m.text.isEmpty ? (m.repost ? "转发了一条动态" : "（没有文字）") : m.text, icon: "image",
                                 [TimeText.day(Date(millis: m.at)), m.pics > 0 ? "\(m.pics) 张图" : "", m.repost && !m.text.isEmpty ? "转发" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        }
                    } header: { GroupTitle("最近的朋友圈") }
                }
                if let d = s.diary {
                    Section {
                        line(d.title.isEmpty ? d.date : d.title, icon: "book",
                             d.locked ? "\(d.date) · 已上锁" : [d.title.isEmpty ? "" : d.date, d.text].filter { !$0.isEmpty }.joined(separator: " · "))
                    } header: { GroupTitle("最近的日记") }
                }
                Section {} footer: { Text("本页汇总已有的记录，只读取，不调用接口。") }
            } else {
                EmptyState(title: "该角色已被删除").listRowBackground(Color.clear)
            }
        }
        .navigationTitle("\(name)的近况")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let pid = (try? Repo.activePersona())?.id ?? ""
            snap = CharNow.snapshot(charId, personaId: pid)
            name = (try? Repo.character(charId))?.row.string("name") ?? ""
        }
    }

    private func line(_ title: String, icon: String, _ sub: String, right: String = "") -> some View {
        HStack(alignment: .top, spacing: Theme.sp3) {
            SvgIcon(name: icon, size: 18, color: Theme.text2).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !sub.isEmpty { Text(sub).font(.system(size: 12)).foregroundStyle(Theme.text3) }
            }
            Spacer(minLength: 0)
            if !right.isEmpty { Text(right).font(.system(size: 12)).foregroundStyle(Theme.text3) }
        }
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

// MARK: - 角色包

/// 导入角色包（网页版 ImportPage 的「选择角色包」）：先读出来看一眼，确认了再装。不经过模型，不调用接口
struct CharPackImportView: View {
    var onDone: (String) -> Void
    @State private var picking = false
    @State private var pack: CharPack.Pack?
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Button(busy ? "正在读取" : "选择角色包") { picking = true }.disabled(busy)
            } footer: {
                Text("原样装回去，不经过模型，也不消耗接口调用。")
                HelpNote("在网页版会话右上角的「导出这个角色」或本应用角色资料页的「导出这个角色」中导出的压缩包，只含一个角色及其相关数据。", title: "选择角色包")
            }
            if let p = pack {
                Section {
                    ForEach(lines(p), id: \.self) { Text($0).font(.system(size: 14)) }
                } header: { GroupTitle("导入「\(p.name)」") }
                Section {
                    Button("导入", action: install).buttonStyle(EiraButtonStyle(kind: .primary, full: true)).disabled(busy)
                    Button("换一份") { pack = nil }.buttonStyle(EiraButtonStyle(kind: .ghost, full: true))
                }
                .listRowBackground(Color.clear)
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("导入角色包")
        .navigationBarTitleDisplayMode(.inline)
        .documentPicker(isPresented: $picking, types: [.zip]) { urls in
            guard let url = urls.first else { return }
            do { pack = try CharPack.read(url); problem = nil } catch { pack = nil; problem = error.localizedDescription }
        }
    }

    private func lines(_ p: CharPack.Pack) -> [String] {
        [p.history ? "含 \(p.n("chats")) 段会话、\(p.n("messages")) 条消息、\(p.n("memories")) 条记忆" : "只含角色卡，不含聊天记录与记忆",
         p.n("scenes") > 0 ? "含 \(p.n("scenes")) 场线下" : "",
         p.n("works") > 0 ? "含 \(p.n("works")) 部「我们」里的作品" : "",
         p.n("skins") > 0 ? "含 \(p.n("skins")) 份美化，仅在带进来的会话里生效" : "",
         p.extras > 0 ? "含 \(p.extras) 条其余记录（出行、动态、日程、那台手机等）" : "",
         p.n("alts") > 0 ? "含 \(p.n("alts")) 个小号" : "",
         p.n("lorebooks") > 0 ? "含 \(p.n("lorebooks")) 本关联世界书，本机已有同名的保持不变" : "",
         p.exists ? "本机已有同一个角色，将另建一个副本，原有的不受影响" : "",
         p.history ? "会话与记忆将归入当前账号名下" : ""].filter { !$0.isEmpty }.map { $0 + "。" }
    }

    private func install() {
        guard let p = pack else { return }
        busy = true
        do {
            let got = try CharPack.install(p)
            NotificationCenter.default.post(name: .eiraChatChanged, object: nil)
            busy = false
            onDone(got.charId)
        } catch {
            busy = false
            problem = "导入未完成：\(error.localizedDescription)"
        }
    }
}

/// 资料页上「导出这个角色」：先把账摆出来，再打包
struct CharPackExportView: View {
    let charId: String
    @State private var est: CharPack.Estimate?
    @State private var history = true
    @State private var built: CharPack.Built?
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        Form {
            if let e = est {
                Section {
                    Toggle("带上聊天记录与记忆", isOn: $history)
                } footer: {
                    Text(history ? "共 \(e.chats) 段会话、\(e.messages) 条消息、\(e.memories) 条记忆、\(e.images) 张图片、\(e.files) 个文件\(e.alts > 0 ? "，含 \(e.alts) 个小号" : "")。群聊不带。"
                         : "只含角色卡、小号、关联的世界书与衣帽间这一类，不含聊天记录与记忆。")
                }
                Section {
                    Button(busy ? "正在打包" : "导出", action: build).buttonStyle(EiraButtonStyle(kind: .primary, full: true)).disabled(busy)
                    if let b = built {
                        ShareLink(item: b.file) { Label("存储或发送这份文件（\(ByteCountFormatter.string(fromByteCount: Int64(b.bytes), countStyle: .file))）", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("导出这个角色")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onChange(of: history) { _, _ in built = nil; reload() }
    }

    private func reload() {
        do { est = try CharPack.estimate(charId, history: history) } catch { problem = error.localizedDescription }
    }

    private func build() {
        busy = true; problem = nil
        let (h, id) = (history, charId)
        Task {
            do {
                let b = try await Task.detached(priority: .userInitiated) { try CharPack.build(id, history: h) }.value
                built = b
            } catch {
                problem = "导出失败：\(error.localizedDescription)"
            }
            busy = false
        }
    }
}
