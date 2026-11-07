import PhotosUI
import SwiftUI

/// 衣帽间（网页版 apps/closet，ARCHITECTURE 4.213、4.214、4.216、4.237、4.344）。
///
/// 层次：总览（大类）、大类（小类、筛选）、单品三层。第一屏只有十来行大类，东西再多也不会一上来铺满。
/// 看谁的衣帽间与看衣橱还是妆台记在 settings.closetOwner / closetSide（与网页版同一份）。
/// 每日穿搭的开关挂在那个角色的衣帽间上（第 5 条），默认关，每天一次模型调用。
enum ClosetUI {
    static func ownerNow(_ s: AppSettings) -> String {
        let o = s.raw["closetOwner"]?.string ?? Closet.me
        return o == Closet.me || ((try? Repo.character(o)) ?? nil) != nil ? o : Closet.me
    }

    static func sideNow(_ s: AppSettings) -> String { s.raw["closetSide"]?.string == "beauty" ? "beauty" : "wear" }

    static func ownerName(_ o: String) -> String {
        if o == Closet.me { return ((try? Repo.activePersona()) ?? nil)?.name ?? "我" }
        return ((try? Repo.character(o)) ?? nil)?.displayName ?? "角色"
    }

    /// 只列主角色，小号不单独列
    static func owners() -> [Character] {
        ((try? Repo.characters()) ?? []).filter { ($0.parentId ?? "").isEmpty }
    }

    /// 一件东西的几个记号：分类、今天穿着、礼物、已借出、快用完、状态
    static func marks(_ item: Row) -> [String] {
        var out: [String] = [Closet.categoryOf(item)]
        if item.string("wornOn") == Closet.today() { out.append("今天穿着") }
        if item.string("source") == "gift" { out.append("礼物") }
        if Closet.lentOut(item) { out.append("已借出") }
        if Closet.flagsOf(item) != nil { out.append("快用完或快过期") }
        if !Closet.live(item) { out.append(ClosetKinds.label(ClosetKinds.states, item.string("state"))) }
        return out.filter { !$0.isEmpty }
    }

    static func flagText(_ f: Closet.Flags) -> String {
        [f.low.map { "约剩 \($0.pct)%，约 \($0.daysLeft) 天用完" } ?? "",
         f.exp.map { $0.daysLeft < 0 ? "已过期" : "\($0.daysLeft) 天后过期" } ?? ""].filter { !$0.isEmpty }.joined(separator: "，")
    }
}

/// 一件东西的小图：有图画图，没有图画那只猫（网页版新版的 cat-full）
struct ClosetThumb: View {
    let item: Row
    var size: CGFloat = 56

    var body: some View {
        Group {
            if !item.string("imageId").isEmpty, MediaStore.url(.images, id: item.string("imageId")) != nil {
                LocalImage(id: item.string("imageId"), maxPixel: size * 3)
            } else {
                CatFill(full: true)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
    }
}

/// 一行单品：图、名字、分类与几个记号
struct ClosetRow: View {
    let item: Row

    var body: some View {
        HStack(spacing: Theme.sp3) {
            ClosetThumb(item: item, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.string("name")).lineLimit(1).foregroundStyle(Closet.live(item) ? Theme.text : Theme.text3)
                let bits = ClosetUI.marks(item)
                if !bits.isEmpty { Text(bits.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(1) }
            }
        }
    }
}

struct ClosetHomeView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var hero = true
    @State private var tick = 0
    @State private var adding = false
    @State private var picking: Bool?
    @State private var naming = false
    @State private var outfitName = ""
    @State private var busy = false
    @State private var note: String?
    @State private var problem: String?

    var body: some View {
        let _ = tick
        let s = model.s
        let owner = ClosetUI.ownerNow(s)
        let side = ClosetUI.sideNow(s)
        let all = Closet.itemsOf(owner).filter { $0.string("side") == side }
        let live = all.filter { Closet.live($0) }
        let unsorted = live.filter { $0.string("group").isEmpty }
        let worn = side == "wear" ? Closet.wornToday(owner) : []
        let today = worn.filter { !Closet.isCarry($0) }
        let bag = worn.filter { Closet.isCarry($0) }
        let who = ClosetUI.ownerName(owner)
        List {
            HeroHeader(eyebrow: "WARDROBE", title: "衣帽间", shown: $hero)
            ownerBar(owner)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            Picker("", selection: Binding(get: { side }, set: { model.set("closetSide", .string($0)) })) {
                ForEach(ClosetKinds.sides) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if side == "wear" { wearSections(owner: owner, who: who, today: today, bag: bag, settings: s) }
            alertSections(owner: owner, side: side)
            linkSection(owner: owner, side: side, unsorted: unsorted.count)
            groupSection(owner: owner, side: side, live: live)
            if all.isEmpty {
                EmptyState(title: "\(ClosetKinds.side(side).label)还是空的",
                           desc: side == "beauty" ? "可拍照或手动添加护肤品、彩妆、香水与工具。填写容量与用量后，自动估算余量与保质期。"
                               : "可拍照或手动添加衣物、鞋包与首饰。识图可自动填写分类、颜色与季节。")
                    .listRowBackground(Color.clear)
                Button("添加") { adding = true }
            } else {
                Section {
                    NavigationLink { ClosetListView(owner: owner, side: side, mode: .all) } label: { LabeledContent("全部", value: "\(live.count) 件") }
                    NavigationLink { ClosetStatsView(owner: owner, side: side) } label: { Text("统计") }
                }
            }
            if let note { Section { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) } }
            ProblemSection(text: problem ?? model.problem)
        }
        .listStyle(.insetGrouped)
        .heroTitle("衣帽间", heroShown: hero)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { NavIcon("plus") }.accessibilityLabel("添加")
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { ClosetSettingsView() } label: { NavIcon("more") }.accessibilityLabel("衣帽间设置")
            }
        }
        .sheet(isPresented: $adding, onDismiss: { tick += 1 }) {
            NavigationStack { ClosetAddView(owner: owner, side: side) }
        }
        .sheet(item: Binding(get: { picking.map { ClosetTodayPick(carry: $0) } }, set: { picking = $0?.carry }), onDismiss: { tick += 1 }) { p in
            NavigationStack { ClosetTodayView(owner: owner, carry: p.carry) }
        }
        .alert("存为套装", isPresented: $naming) {
            TextField("例如 周末出门", text: $outfitName)
            Button("取消", role: .cancel) {}
            Button("存") {
                do {
                    if let o = try Closet.outfitFromToday(owner, name: outfitName) { note = "已存为套装「\(o.string("name"))」"; problem = nil }
                } catch { problem = "未能保存：\(error.localizedDescription)" }
                tick += 1
            }
        }
        .onAppear { model.reload(); tick += 1 }
    }

    @ViewBuilder private func wearSections(owner: String, who: String, today: [Row], bag: [Row], settings s: AppSettings) -> some View {
            Section {
                if today.isEmpty {
                    Text("尚未选择。点「选择」从衣橱里勾选今天穿着的几件。").font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                ForEach(today, id: \.id) { r in NavigationLink { ClosetItemView(id: r.id) } label: { ClosetRow(item: r) } }
                Button("选择") { picking = false }
                if !today.isEmpty { Button("存为套装") { outfitName = ""; naming = true } }
            } header: { GroupTitle(owner == Closet.me ? "今天穿的" : "\(who)今天穿的") }
            if !Closet.hiddenGroups(s).contains(Closet.carry) {
                Section {
                    if bag.isEmpty {
                        Text("包里带着的伞、耳机、相机这类小物，放在「随身」里，在这里勾选。").font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(bag, id: \.id) { r in NavigationLink { ClosetItemView(id: r.id) } label: { ClosetRow(item: r) } }
                    Button("选择") { picking = true }
                } header: { GroupTitle(owner == Closet.me ? "今天带着" : "\(who)今天带着") }
            }
            if owner != Closet.me { dailySection(owner) }
            let borrowed = Closet.borrowedBy(owner)
            if !borrowed.isEmpty {
                Section {
                    ForEach(borrowed, id: \.id) { r in
                        NavigationLink { ClosetItemView(id: r.id) } label: {
                            HStack { ClosetThumb(item: r, size: 36); Text("\(ClosetUI.ownerName(r.string("owner")))的\(r.string("name"))").lineLimit(1) }
                        }
                    }
                } header: { GroupTitle("借来的") }
            }
    }

    @ViewBuilder private func alertSections(owner: String, side: String) -> some View {
        let alerts = side == "beauty" ? Closet.alertsOf(owner).map { $0.item } : []
        if !alerts.isEmpty {
            Section {
                ForEach(alerts, id: \.id) { r in
                    NavigationLink { ClosetItemView(id: r.id) } label: {
                        LabeledContent(r.string("name"), value: Closet.flagsOf(r).map { ClosetUI.flagText($0) } ?? "")
                    }
                }
            } header: { GroupTitle("快用完或快过期") }
        }
        let cares = Closet.careAlertsOf(owner).map { $0.item }.filter { $0.string("side") == side }
        if !cares.isEmpty {
            Section {
                ForEach(cares, id: \.id) { r in
                    NavigationLink { ClosetItemView(id: r.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.string("name"))
                            Text(Closet.careText(Closet.careOf(r))).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            } header: { GroupTitle("该清洗或保养") }
        }
    }

    @ViewBuilder private func linkSection(owner: String, side: String, unsorted: Int) -> some View {
        Section {
            if side == "wear" {
                let n = Closet.outfitsOf(owner).count
                NavigationLink { ClosetOutfitsView(owner: owner) } label: { LabeledContent("套装", value: n > 0 ? "\(n) 套" : "把几件单品存成一套") }
            }
            if owner != Closet.me {
                NavigationLink { ClosetGenerateView(charId: owner, side: side) } label: { LabeledContent("按角色设定生成", value: "调用 1 次接口") }
            }
            if unsorted > 0 {
                NavigationLink { ClosetListView(owner: owner, side: side, mode: .unsorted) } label: { LabeledContent("未整理", value: "\(unsorted) 件") }
            }
        }
    }

    @ViewBuilder private func groupSection(owner: String, side: String, live: [Row]) -> some View {
        Section {
            ForEach(Closet.groupsOf(side)) { g in
                let n = live.filter { $0.string("group") == g.id }.count
                NavigationLink { ClosetListView(owner: owner, side: side, mode: .group(g.id)) } label: { LabeledContent(g.label, value: "\(n)") }
            }
        } header: { GroupTitle(ClosetKinds.side(side).label) }
    }

    private func ownerBar(_ now: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.sp2) {
                chip(id: Closet.me, name: "我", avatar: ((try? Repo.activePersona()) ?? nil)?.avatar ?? "", on: now == Closet.me)
                ForEach(ClosetUI.owners()) { c in chip(id: c.id, name: c.displayName, avatar: c.avatar, on: now == c.id) }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(id: String, name: String, avatar: String, on: Bool) -> some View {
        Button { model.set("closetOwner", .string(id)) } label: {
            HStack(spacing: 6) {
                Avatar(imageId: avatar, name: name, size: 22)
                Text(name).font(.system(size: 13)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(on ? Theme.surface3 : Theme.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Theme.text : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func dailySection(_ owner: String) -> some View {
        let char = (try? Repo.character(owner)) ?? nil
        let on = ClosetAI.isDaily(char)
        let failed = on && !(char?.row.string("closetDailyError") ?? "").isEmpty && char?.row.string("closetDailyAt") == Closet.today()
        Section {
            Toggle("每日自动穿搭", isOn: Binding(get: { on }, set: { v in
                do { try Diary.patchChar(owner, ["closetDaily": .bool(v)]); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                tick += 1
            }))
            Button(busy ? "正在选择" : "现在选一次") { pickNow(owner) }.disabled(busy)
            if failed {
                Text("今天的自动选择失败：\(char?.row.string("closetDailyError") ?? "")。今天不再自动重试，明天自动选择一次；可点「现在选一次」手动重试。")
                    .font(.footnote).foregroundStyle(Theme.danger)
            }
        } footer: {
            Text(on ? "每天从该角色衣帽间已有的衣物与随身物品里选一次今天穿什么、带什么，调用一次接口。"
                 : "关闭。开启后每天调用一次接口，从该角色衣帽间已有的东西里选出今天穿什么、带什么；所用接口可在「设置 - 任务用哪套接口」中选择。")
            HelpNote("已配置和风天气且角色卡填写了所在地区时，严格按当天预报选择，不合气温的衣物不参与挑选。当天已经穿着东西的不再生成。关闭后不再自动选择。「现在选一次」调用一次接口，今天已选的几件保留，另外勾上选出的。", title: "每日自动穿搭")
        }
    }

    private func pickNow(_ owner: String) {
        busy = true
        note = nil
        Task {
            do { let n = try await ClosetAI.pickToday(owner); note = "已选好今天的 \(n) 件"; problem = nil }
            catch { problem = error.localizedDescription }
            busy = false
            tick += 1
        }
    }
}

struct ClosetTodayPick: Identifiable { var carry: Bool; var id: Bool { carry } }

/// 今天穿的 / 今天带着：按大类列出这个人的东西，勾上就是今天穿着（带着）。借来的另列一组
struct ClosetTodayView: View {
    let owner: String
    let carry: Bool
    @State private var tick = 0
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = tick
        let d = Closet.today()
        let mine = Closet.itemsOf(owner).filter { $0.string("side") == "wear" && Closet.live($0) && !$0.string("group").isEmpty && !Closet.lentOut($0) }
            .filter { Closet.isCarry($0) == carry }
        let borrowed = carry ? [] : Closet.borrowedBy(owner).filter { !Closet.isCarry($0) }
        List {
            ForEach(Closet.groupsOf("wear").filter { g in mine.contains { $0.string("group") == g.id } }) { g in
                Section { ForEach(mine.filter { $0.string("group") == g.id }, id: \.id) { r in row(r, d) } } header: { GroupTitle(g.label) }
            }
            if !borrowed.isEmpty { Section { ForEach(borrowed, id: \.id) { r in row(r, d) } } header: { GroupTitle("借来的") } }
            if mine.isEmpty && borrowed.isEmpty {
                EmptyState(title: carry ? "随身里还没有东西" : "衣橱里还没有分好类的衣物").listRowBackground(Color.clear)
            }
            ProblemSection(text: problem)
        }
        .navigationTitle(carry ? "今天带着" : "今天穿的")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }

    private func row(_ r: Row, _ d: String) -> some View {
        Toggle(isOn: Binding(get: { r.string("wornOn") == d }, set: { v in
            do { try Closet.wear(r.id, v); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
            tick += 1
        })) { ClosetRow(item: r) }
    }
}

/// 一个大类、全部、未整理
struct ClosetListView: View {
    enum Mode: Hashable { case group(String), all, unsorted }
    let owner: String
    let side: String
    let mode: Mode
    @State private var sub = ""
    @State private var query = ""
    @State private var showGone = false
    @State private var adding = false
    @State private var busy = false
    @State private var note: String?
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let base = Closet.itemsOf(owner).filter { $0.string("side") == side }
        let rows: [Row] = {
            var list = base
            switch mode {
            case .group(let g): list = list.filter { $0.string("group") == g }
            case .unsorted: list = list.filter { $0.string("group").isEmpty }
            case .all: break
            }
            if !sub.isEmpty { list = list.filter { $0.string("sub") == sub } }
            if !showGone { list = list.filter { Closet.live($0) } }
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            if !q.isEmpty {
                list = list.filter { r in
                    ["name", "desc", "sub", "shade", "note"].map { r.string($0) }.joined(separator: " ").lowercased().contains(q)
                }
            }
            return list.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        }()
        let groupId: String? = { if case .group(let g) = mode { return g }; return nil }()
        let unsortedMode: Bool = { if case .unsorted = mode { return true }; return false }()
        List {
            if let g = groupId {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.sp2) {
                        subChip("全部", on: sub.isEmpty) { sub = "" }
                        ForEach(Closet.subsOf(g), id: \.label) { s in subChip(s.label, on: sub == s.label) { sub = sub == s.label ? "" : s.label } }
                    }
                }
                .listRowBackground(Color.clear)
            }
            if unsortedMode && !rows.isEmpty {
                Section {
                    Button(busy ? "正在识图" : "识图整理这 \(rows.count) 件") { recognize(rows.map(\.id)) }.disabled(busy || !ClosetAI.visionReady())
                } footer: {
                    Text("将调用 \(rows.count) 次识图接口，自动填写分类、颜色、季节、场合与描述。已填写的内容不会被覆盖。")
                }
            }
            Section {
                ForEach(rows, id: \.id) { r in NavigationLink { ClosetItemView(id: r.id) } label: { ClosetRow(item: r) } }
                if rows.isEmpty { Text("没有符合条件的东西。").font(.footnote).foregroundStyle(Theme.secondaryText) }
            } header: { GroupTitle("共 \(rows.count) 件") }
            Section { Toggle("显示已用完、已送出的", isOn: $showGone) }
            if let note { Section { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) } }
        }
        .searchable(text: $query)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { NavIcon("plus") }.accessibilityLabel("添加") }
        }
        .sheet(isPresented: $adding, onDismiss: { tick += 1 }) {
            NavigationStack { ClosetAddView(owner: owner, side: side, group: groupId ?? "") }
        }
        .onAppear { tick += 1 }
    }

    private var title: String {
        switch mode {
        case .group(let g): return ClosetKinds.group(g)?.label ?? "衣帽间"
        case .all: return "全部"
        case .unsorted: return "未整理"
        }
    }

    private func subChip(_ label: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label).font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(on ? Theme.surface3 : Theme.surface2, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Theme.text : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func recognize(_ ids: [String]) {
        busy = true
        Task {
            let r = await ClosetAI.recognizeMany(ids)
            note = r.failed.isEmpty ? "已识别 \(r.done) 件" : "已识别 \(r.done) 件，\(r.failed.count) 件失败：\(r.failed[0])"
            busy = false
            tick += 1
        }
    }
}

/// 往衣帽间里放东西：拍照或选图（一次几张，每张一件），或者手动添加
struct ClosetAddView: View {
    let owner: String
    let side: String
    var group = ""
    @State private var g = ""
    @State private var sub = ""
    @State private var name = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var made: [String] = []
    @State private var busy = false
    @State private var note: String?
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                PhotosPicker(selection: $picked, maxSelectionCount: 30, matching: .images) { Label("拍照或选图", systemImage: "photo") }
                if !made.isEmpty {
                    Button(busy ? "正在识图" : "识图整理这 \(made.count) 件") { recognize() }.disabled(busy || !ClosetAI.visionReady())
                }
            } footer: {
                Text(made.isEmpty ? "可一次选择多张，每张一件，先放进「未整理」或所选的分类。"
                     : "已放入 \(made.count) 件。识图将调用 \(made.count) 次识图接口，已填写的内容不会被覆盖。")
            }
            Section {
                Picker("大类", selection: $g) {
                    Text("不选").tag("")
                    ForEach(Closet.groupsOf(side)) { Text($0.label).tag($0.id) }
                }
                if !g.isEmpty {
                    Picker("小类", selection: $sub) {
                        Text("不选").tag("")
                        ForEach(Closet.subsOf(g), id: \.label) { Text($0.label).tag($0.label) }
                    }
                }
                TextField(side == "beauty" ? "例如 某品牌粉底液" : "例如 白色针织衫", text: $name)
                Button("手动添加") { manual() }
            } header: { GroupTitle("手动添加") }
            if let note { Section { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) } }
            ProblemSection(text: problem)
        }
        .navigationTitle("放进\(ClosetKinds.side(side).label)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .onAppear { if g.isEmpty { g = group } }
        .onChange(of: g) { _, _ in sub = "" }
        .onChange(of: picked) { _, list in
            guard !list.isEmpty else { return }
            Task {
                var ids: [String] = []
                for it in list {
                    do {
                        guard let data = try await it.loadTransferable(type: Data.self) else { throw StoreError(message: "无法读取所选图片") }
                        ids.append(try Images.save(data))
                    } catch { problem = "图片处理失败：\(error.localizedDescription)" }
                }
                do { made += try Closet.addPhotos(ids, owner: owner, side: side, group: g, sub: sub).map(\.id) }
                catch { problem = "未能保存：\(error.localizedDescription)" }
                picked = []
            }
        }
    }

    private func manual() {
        guard !g.isEmpty else { problem = "请选择大类"; return }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { problem = "请填写名称"; return }
        do {
            try Closet.create(["owner": .string(owner), "side": .string(side), "group": .string(g), "sub": .string(sub), "name": .string(name)])
            note = "已放入「\(name.trimmingCharacters(in: .whitespaces))」"
            name = ""
            problem = nil
        } catch { problem = "未能保存：\(error.localizedDescription)" }
    }

    private func recognize() {
        busy = true
        let ids = made
        Task {
            let r = await ClosetAI.recognizeMany(ids)
            note = r.failed.isEmpty ? "已识别 \(r.done) 件" : "已识别 \(r.done) 件，\(r.failed.count) 件失败：\(r.failed[0])"
            busy = false
        }
    }
}

/// 衣帽间设置：各大类显示与否、自己加的小类、提醒的几道门、生图时参考今天穿的
struct ClosetSettingsView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var adding: String?
    @State private var newSub = ""
    @State private var problem: String?

    var body: some View {
        let s = model.s
        let hidden = Closet.hiddenGroups(s)
        Form {
            ForEach(ClosetKinds.sides) { side in
                Section {
                    ForEach(ClosetKinds.groups.filter { $0.side == side.id }) { g in
                        DisclosureGroup {
                            Toggle("显示这一类", isOn: Binding(get: { !hidden.contains(g.id) }, set: { v in
                                do { try Closet.setGroupHidden(g.id, !v); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                                model.reload()
                            }))
                            ForEach(Closet.subsOf(g.id, s), id: \.label) { sub in
                                HStack {
                                    Text(sub.label)
                                    Spacer()
                                    if sub.custom {
                                        Button("移除", role: .destructive) {
                                            do { try Closet.dropSub(g.id, sub.label); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                                            model.reload()
                                        }.buttonStyle(.borderless)
                                    }
                                }
                            }
                            Button("添加小类") { newSub = ""; adding = g.id }
                        } label: {
                            LabeledContent(g.label, value: hidden.contains(g.id) ? "已隐藏" : "\(Closet.subsOf(g.id, s).count) 个小类")
                        }
                    }
                } header: { GroupTitle(side.label) }
            }
            Section {
                NumberRow(title: "余量低于", value: model.number("closetLowPct", 15), unit: "%", range: 0...100)
                NumberRow(title: "离过期不足", value: model.number("closetExpireWarn", 30), unit: "天")
                NumberRow(title: "同一件两次告诉角色至少隔", value: model.number("closetAlertCooldown", 30), unit: "天")
            } header: { GroupTitle("快用完与快过期") } footer: {
                HelpNote("估算的余量低于这个比例，或按当前用量不足 14 天时，算作快用完。离估算的过期日不足设定天数时，算作快过期。快用完、快过期的东西只在第一次满足条件的那一天告诉角色，之后要过了设定的天数才会再告诉一次。衣帽间里「快用完或快过期」那一栏不受此限。", title: "快用完与快过期")
            }
            Section {
                NumberRow(title: "上次穿着距今超过", value: model.number("closetIdleDays", 60), unit: "天", placeholder: "不告诉角色")
                NumberRow(title: "两次告诉角色至少隔", value: model.number("closetIdleGap", 7), unit: "天")
            } header: { GroupTitle("好久没穿") } footer: {
                HelpNote("穿过至少一次、上次穿着距今超过设定天数的衣物，算作好久没穿。填 0 表示不告诉角色。每次只告诉角色一件，只在当天出现。同一件东西再穿一次之后才会重新计算。", title: "好久没穿")
            }
            Section {
                Toggle("生图时参考今天穿的", isOn: model.bool("closetInImage", false))
            } header: { GroupTitle("生图") } footer: {
                Text("不额外调用接口，会改变画出来的衣服。")
                HelpNote("开启后，画面描述中出现角色或你的名字，或写着合照、我们、一起时，将此人今天穿着的名称与描述接在生图提示词后面。衣物照片不会作为参考图发送。", title: "生图时参考今天穿的")
            }
            ProblemSection(text: problem ?? model.problem)
        }
        .navigationTitle("衣帽间设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("添加小类", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
            TextField("名称", text: $newSub)
            Button("取消", role: .cancel) {}
            Button("添加") {
                if let g = adding {
                    do {
                        let ok = try Closet.addSub(g, newSub)
                        problem = ok ? nil : "这个小类已经有了，或名称为空"
                    } catch { problem = "未能保存：\(error.localizedDescription)" }
                    model.reload()
                }
            }
        }
    }
}

/// 统计（4.344 第二步）：花费、渠道、每穿一次合多少钱。只给自己看
struct ClosetStatsView: View {
    let owner: String
    let side: String

    var body: some View {
        let st = Closet.statsOf(owner, nil, side: side)
        List {
            Section {
                LabeledContent("件数", value: "\(st.total)（在用 \(st.live)）")
                LabeledContent("填了价格的", value: "\(st.priced) 件")
                LabeledContent("一共花了", value: Closet.priceText(st.spent))
                if side == "wear" { LabeledContent("近 30 天穿了", value: "\(st.month) 次") }
            }
            if !st.channels.isEmpty {
                Section {
                    ForEach(st.channels, id: \.name) { c in LabeledContent(c.name, value: "\(c.count) 件 · \(Closet.priceText(c.spent))") }
                } header: { GroupTitle("按渠道") }
            }
            if side == "wear" {
                list("每穿一次最便宜", st.cheap.map { ($0.item, "每次 \(Closet.priceText(($0.per * 100).rounded() / 100))") })
                list("每穿一次最贵", st.dear.map { ($0.item, "每次 \(Closet.priceText(($0.per * 100).rounded() / 100))") })
                list("买了还没穿过", st.unworn.map { ($0, Closet.priceText(Closet.num($0["price"]))) })
                list("最常穿", st.most.map { ($0, "\(Int(Closet.num($0["wornCount"]))) 次") })
                list("超过 \(st.idleDays) 天没穿", st.idle.map { ($0, "上次 \(Closet.dateKey(Closet.num($0["lastWorn"])))") })
            }
        }
        .navigationTitle("统计")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func list(_ title: String, _ rows: [(Row, String)]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows.indices, id: \.self) { i in
                    NavigationLink { ClosetItemView(id: rows[i].0.id) } label: { LabeledContent(rows[i].0.string("name"), value: rows[i].1) }
                }
            } header: { GroupTitle(title) }
        }
    }
}

/// 按角色设定生成一批（一次调用，只有文字）。先列出来看一眼，勾选的再放进去（第 6 条的例外：确认页）
struct ClosetGenerateView: View {
    let charId: String
    @State var side: String
    @State private var count = 20.0
    @State private var busy = false
    @State private var drafts: [[String: JSONValue]] = []
    @State private var keep: Set<Int> = []
    @State private var note: String?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Picker("放进", selection: $side) { ForEach(ClosetKinds.sides) { Text($0.label).tag($0.id) } }
                NumberRow(title: "生成几件", value: $count, unit: "件", placeholder: "20", range: 1...Double(Int32.max))
                Button(busy ? "正在生成" : "生成") { run() }.disabled(busy)
            } footer: {
                Text("调用 1 次接口，只生成文字；需要图片时在单品页逐件生成。")
                HelpNote("按该角色的角色卡生成衣帽间里的一批东西，已经有的同名的不再给。结果先列出来，勾选的才放进该角色的衣帽间。件数不设上限，件数越多回复越长。", title: "按角色设定生成")
            }
            if !drafts.isEmpty {
                Section {
                    ForEach(drafts.indices, id: \.self) { i in
                        let d = drafts[i]
                        Toggle(isOn: Binding(get: { keep.contains(i) }, set: { if $0 { keep.insert(i) } else { keep.remove(i) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d["name"]?.string ?? "")
                                let cat = [ClosetKinds.group(d["group"]?.string ?? "")?.label ?? "", d["sub"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                                Text([cat, d["desc"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: "：")).font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    Button("放进衣帽间（\(keep.count) 件）") { save() }.disabled(keep.isEmpty)
                } header: { GroupTitle("生成结果") }
            }
            if let note { Section { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) } }
            ProblemSection(text: problem)
        }
        .navigationTitle("按角色设定生成")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() {
        busy = true
        problem = nil
        note = nil
        Task {
            do {
                drafts = try await ClosetAI.wardrobe(charId, count: Int(count.rounded()), side: side)
                keep = Set(drafts.indices)
                if drafts.isEmpty { note = "没有生成可放入的新东西。" }
            } catch { problem = "生成失败：\(error.localizedDescription)" }
            busy = false
        }
    }

    private func save() {
        do {
            let n = try ClosetAI.keepWardrobe(charId, keep.sorted().map { drafts[$0] }).count
            note = "已放入 \(n) 件"
            drafts = []
            keep = []
            problem = nil
        } catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}
