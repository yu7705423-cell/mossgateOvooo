import PhotosUI
import SwiftUI

/// 单品页（网页版 closet/ItemPage.js、ItemExtras.js）。改一项存一项；购买、次数、清洗与保养只给自己看（4.344）。
/// 识图、按描述生图是点了才调的，各一次请求，按钮下写着。
struct ClosetItemView: View {
    let id: String
    @State private var row: Row?
    @State private var picked: PhotosPickerItem?
    @State private var busy = ""
    @State private var note: String?
    @State private var problem: String?
    @State private var confirmDelete = false
    @State private var memo = ""
    @State private var viewing: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let r = row { form(r) } else { EmptyState(title: "这件东西已不存在") }
        }
        .navigationTitle(row?.string("name") ?? "衣帽间")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: picked) { _, it in
            guard let it else { return }
            Task {
                do {
                    guard let data = try await it.loadTransferable(type: Data.self) else { throw StoreError(message: "无法读取所选图片") }
                    let img = try Images.save(data)
                    try Closet.patch(id, ["imageId": .string(img)])
                    problem = nil
                } catch { problem = "图片未能保存：\(error.localizedDescription)" }
                picked = nil
                reload()
            }
        }
        .confirmationDialog("删除这件东西", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Closet.remove(id); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
        } message: { Text("删除后无法恢复。已经发出去的卡片不受影响。") }
        .fullScreenCover(item: Binding(get: { viewing.map { ViewingImage(id: $0) } }, set: { viewing = $0?.id })) { v in
            ZStack {
                Color.black.ignoresSafeArea()
                LocalImage(id: v.id, maxPixel: 2000, fit: true)
            }
            .onTapGesture { viewing = nil }
        }
    }

    private func reload() { row = Closet.get(id) }

    private func save(_ patch: [String: JSONValue]) {
        do { row = try Closet.update(id, patch); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { row?.string(key) ?? "" }, set: { save([key: .string($0)]) })
    }

    private func number(_ key: String) -> Binding<Double> {
        Binding(get: { row.map { Closet.num($0[key]) } ?? 0 }, set: { save([key: .number($0)]) })
    }

    private func tags(_ key: String, _ list: [ClosetKinds.Tag]) -> some View {
        let cur = row?.strings(key) ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.sp2) {
                ForEach(list) { t in
                    let on = cur.contains(t.id)
                    Button {
                        let next = on ? cur.filter { $0 != t.id } : cur + [t.id]
                        save([key: .array(list.map(\.id).filter { next.contains($0) }.map { .string($0) })])
                    } label: {
                        Text(t.label).font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(on ? Theme.surface3 : Theme.surface2, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Theme.text : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func form(_ r: Row) -> some View {
        let beauty = r.string("side") == "beauty"
        let owner = r.string("owner")
        Form {
            Section {
                if !r.string("imageId").isEmpty {
                    LocalImage(id: r.string("imageId"), maxPixel: 900, fit: true)
                        .frame(maxWidth: .infinity, maxHeight: 260)
                        .onTapGesture { viewing = r.string("imageId") }
                }
                PhotosPicker(selection: $picked, matching: .images) { Text(r.string("imageId").isEmpty ? "添加图片" : "换一张图") }
                Button(busy == "vision" ? "正在识图" : "识图填写") { run("vision") { try await ClosetAI.recognize(id) } }
                    .disabled(!busy.isEmpty || r.string("imageId").isEmpty || !ClosetAI.visionReady())
                Button(busy == "image" ? "正在生成" : "按描述生成图片") { run("image") { try await ClosetAI.draw(id) } }
                    .disabled(!busy.isEmpty || !ClosetAI.imageReady())
            } footer: {
                Text("识图与生成图片各调用一次接口。")
                HelpNote("识图读取这一件的照片，填写空着的分类、颜色、季节、场合、名称与描述，已填写的不覆盖；照片里有人时，提到人的句子不保存。按描述生成图片按描述（没有描述时按名称与小类）画一张，替换现有的图。", title: "识图与生成图片")
            }
            Section {
                TextField("名称", text: text("name"))
                Picker("大类", selection: Binding(get: { r.string("group") }, set: { save(["group": .string($0), "sub": .string("")]) })) {
                    Text("未整理").tag("")
                    ForEach(ClosetKinds.groups) { Text("\(ClosetKinds.side($0.side).label) · \($0.label)").tag($0.id) }
                }
                if !r.string("group").isEmpty {
                    Picker("小类", selection: Binding(get: { r.string("sub") }, set: { save(["sub": .string($0)]) })) {
                        Text("不选").tag("")
                        ForEach(Closet.subsOf(r.string("group")), id: \.label) { Text($0.label).tag($0.label) }
                    }
                }
                TextField("描述", text: text("desc"), axis: .vertical).lineLimit(2...6)
                if beauty { TextField("色号", text: text("shade")) }
            }
            Section {
                tags("colors", ClosetKinds.colors)
                if !beauty {
                    tags("seasons", ClosetKinds.seasons)
                    tags("occasions", ClosetKinds.occasions)
                }
            } header: { GroupTitle("颜色、季节与场合") }
            Section {
                Picker("状态", selection: Binding(get: { r.string("state") }, set: { save(["state": .string($0)]) })) {
                    ForEach(ClosetKinds.states) { Text($0.label).tag($0.id) }
                }
                Picker("来源", selection: Binding(get: { r.string("source").isEmpty ? "self" : r.string("source") }, set: { save(["source": .string($0)]) })) {
                    ForEach(ClosetKinds.sources) { Text($0.label).tag($0.id) }
                }
                let src = Closet.sourceText(r)
                if !src.isEmpty { LabeledContent("来自", value: src) }
                TextField("备注", text: text("note"), axis: .vertical)
            }
            if !beauty {
                Section {
                    Toggle(Closet.isCarry(r) ? "今天带着" : "今天穿着", isOn: Binding(get: { r.string("wornOn") == Closet.today() }, set: { v in
                        do { try Closet.wear(id, v); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                        reload()
                    }))
                    Stepper("\(Closet.isCarry(r) ? "用过" : "穿过") \(Int(Closet.num(r["wornCount"]))) 次", value: Binding(
                        get: { Int(Closet.num(r["wornCount"])) },
                        set: { n in do { try Closet.setCount(id, n); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }; reload() }),
                            in: Closet.wornDatesOf(r).count...Int(Int32.max))
                    let dates = Closet.wornDatesOf(r)
                    if !dates.isEmpty {
                        DisclosureGroup("穿着记录 \(dates.count) 天") {
                            ForEach(dates, id: \.self) { d in
                                HStack {
                                    Text(d).monospacedDigit()
                                    Spacer()
                                    Button("删去这一天", role: .destructive) {
                                        do { try Closet.dropWornDate(id, d); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                                        reload()
                                    }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    lendRow(r, owner)
                } header: { GroupTitle("穿着") } footer: {
                    if Closet.undatedWears(r) > 0 { Text("其中 \(Closet.undatedWears(r)) 次没有日期。") }
                }
            }
            Section {
                TextField("购买渠道，例如 \(ClosetKinds.channels.joined(separator: "、"))", text: text("channel"))
                NumberRow(title: "价格", value: number("price"), unit: "元")
                TextField("购入日期（年-月-日）", text: text("buyAt")).keyboardType(.numbersAndPunctuation)
                if Closet.perWear(r) > 0 { LabeledContent("每穿一次", value: Closet.priceText((Closet.perWear(r) * 100).rounded() / 100)) }
            } header: { GroupTitle("购买") } footer: { Text("只给自己看，不告诉角色。") }
            if beauty { beautySection(r) } else { careSection(r) }
            Section {
                let mems = Closet.memoriesOf(r)
                ForEach(mems.indices, id: \.self) { i in
                    let m = mems[i]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m["text"]?.string ?? "")
                        Text(Closet.dateKey(m["at"]?.number ?? 0)).font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            do { try Closet.dropMemory(id, m["id"]?.string ?? ""); problem = nil } catch { problem = "未能删除：\(error.localizedDescription)" }
                            reload()
                        }
                    }
                }
                HStack {
                    TextField("记下一件与它有关的事", text: $memo)
                    Button("记下") {
                        do { try Closet.addMemory(id, text: memo); memo = ""; problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                        reload()
                    }.disabled(memo.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { GroupTitle("回忆") } footer: {
                HelpNote("这件东西陪着经历过的事，只由你记下。穿着或带着它的那天，角色读得到最近几条（条数在「设置 - 用量与上限」中填写）。", title: "物品的回忆")
            }
            Section {
                NavigationLink { ClosetUseView(id: id) } label: { Text("在会话中使用") }
                NavigationLink { ClosetShareView(id: id) } label: { Text("发给角色看") }
            } footer: { Text("都不调用接口，角色在下一次回复时读到。") }
            if let note { Section { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) } }
            ProblemSection(text: problem)
            Section { Button("删除这件东西", role: .destructive) { confirmDelete = true } }
        }
    }

    @ViewBuilder private func lendRow(_ r: Row, _ owner: String) -> some View {
        if Closet.lentOut(r) {
            let to = r["lent"]?["to"]?.string ?? ""
            LabeledContent("借给了", value: "\(ClosetUI.ownerName(to)) · \(Closet.dateKey(r["lent"]?["at"]?.number ?? 0))")
            Button("还回来") {
                do { try Closet.giveBack(id); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                reload()
            }
        } else if owner == Closet.me {
            Menu("借给") {
                ForEach(ClosetUI.owners()) { c in
                    Button(c.displayName) {
                        do { try Closet.lend(id, to: c.id); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                        reload()
                    }
                }
            }
        } else {
            Button("借给我") {
                do { try Closet.lend(id, to: Closet.me); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                reload()
            }
        }
    }

    @ViewBuilder private func careSection(_ r: Row) -> some View {
        Section {
            Picker("清洗方式", selection: Binding(get: { r.string("washWay") }, set: { save(["washWay": .string($0)]) })) {
                Text("不填").tag("")
                ForEach(ClosetKinds.washWays) { Text($0.label).tag($0.id) }
            }
            Picker("提醒清洗", selection: Binding(get: { r.string("washRule") }, set: { save(["washRule": .string($0)]) })) {
                ForEach(ClosetKinds.washRules) { Text($0.label).tag($0.id) }
            }
            if !r.string("washRule").isEmpty {
                NumberRow(title: r.string("washRule") == "wears" ? "每穿几次" : "每隔几天", value: number("washN"), unit: r.string("washRule") == "wears" ? "次" : "天")
            }
            HStack {
                Text("上次清洗")
                Spacer()
                Text(r.string("washedAt").isEmpty ? "未记" : r.string("washedAt")).foregroundStyle(Theme.secondaryText)
                Button("今天洗过") {
                    do { try Closet.washed(id); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                    reload()
                }.buttonStyle(.borderless)
            }
            TextField("保养事项，例如 皮鞋上油", text: text("careNote"))
            if !r.string("careNote").isEmpty {
                NumberRow(title: "每隔几天保养", value: number("careEvery"), unit: "天")
                HStack {
                    Text("上次保养")
                    Spacer()
                    Text(r.string("caredAt").isEmpty ? "未记" : r.string("caredAt")).foregroundStyle(Theme.secondaryText)
                    Button("今天保养过") {
                        do { try Closet.cared(id); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                        reload()
                    }.buttonStyle(.borderless)
                }
            }
            if let c = Closet.careOf(r) { Text(Closet.careText(c)).font(.footnote).foregroundStyle(Theme.danger) }
        } header: { GroupTitle("清洗与保养") } footer: { Text("只在衣帽间里提醒，不告诉角色。") }
    }

    @ViewBuilder private func beautySection(_ r: Row) -> some View {
        Section {
            NumberRow(title: "容量", value: number("capacity"), unit: r.string("capUnit"))
            Picker("容量单位", selection: Binding(get: { r.string("capUnit").isEmpty ? "毫升" : r.string("capUnit") }, set: { save(["capUnit": .string($0)]) })) {
                ForEach(ClosetKinds.capUnits, id: \.self) { Text($0).tag($0) }
            }
            NumberRow(title: "每次用量", value: number("dose"), unit: r.string("doseUnit"))
            Picker("用量单位", selection: Binding(get: { r.string("doseUnit") }, set: { save(["doseUnit": .string($0)]) })) {
                Text("不填").tag("")
                ForEach(ClosetKinds.doseUnits, id: \.self) { Text($0).tag($0) }
            }
            NumberRow(title: "每天用几次", value: number("perDay"), unit: "次")
            NumberRow(title: "一次用量合多少毫升", value: number("mlPer"), unit: "毫升", placeholder: "按单位估算")
            if let rem = Closet.remaining(r) {
                LabeledContent("估算余量", value: "约 \(rem.pct)%，约 \(rem.daysLeft) 天")
                Menu("按实际剩余校准") {
                    ForEach([100, 75, 50, 25, 10, 0], id: \.self) { p in
                        Button("还剩约 \(p)%") {
                            do { try Closet.calibrate(id, Double(p)); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                            reload()
                        }
                    }
                }
            }
        } header: { GroupTitle("余量") } footer: {
            HelpNote("容量、每次用量、每天几次三样都填了才估算余量：从开封那天（没有就购入那天、再没有就放进来那天）起按天扣。用量单位换成毫升按常见用量估算，可在「一次用量合多少毫升」中改。实际剩余和估算不一致时校准一次，从那一刻重新扣。", title: "余量")
        }
        Section {
            TextField("开封日期（年-月-日）", text: text("openedAt")).keyboardType(.numbersAndPunctuation)
            NumberRow(title: "开封后可用", value: number("pao"), unit: "个月")
            NumberRow(title: "未开封保质期", value: number("shelf"), unit: "个月", placeholder: "36")
            TextField("保质日期（年-月-日）", text: text("expireAt")).keyboardType(.numbersAndPunctuation)
            if let e = Closet.expiry(r) {
                LabeledContent("估算过期", value: "\(Closet.dateKey(e.at)) · \(e.daysLeft < 0 ? "已过期" : "\(e.daysLeft) 天后")")
            }
        } header: { GroupTitle("保质期") } footer: {
            HelpNote("填了保质日期就按它算；否则按开封日期加开封后可用的月数；还没开封的按购入日期加未开封保质期（没填按 36 个月）。", title: "保质期")
        }
    }

    private func run(_ what: String, _ body: @escaping () async throws -> Row?) {
        busy = what
        note = nil
        Task {
            do { _ = try await body(); note = what == "vision" ? "已识图填写" : "已生成图片"; problem = nil }
            catch { problem = error.localizedDescription }
            busy = ""
            reload()
        }
    }
}

struct ViewingImage: Identifiable { var id: String }

/// 在会话里用一件东西：帮对方喷上香水、请对方帮我系领带。落一条我发的动作卡片，不调接口
struct ClosetUseView: View {
    let id: String
    @State private var chatId = ""
    @State private var action = ""
    @State private var note: String?
    @State private var problem: String?

    var body: some View {
        let r = Closet.get(id)
        let targets = Closet.useTargets(r)
        Form {
            Section {
                Picker("发到", selection: $chatId) {
                    ForEach(targets) { c in Text(c.characterIds.first.flatMap { (try? Repo.character($0)) ?? nil }?.displayName ?? c.title).tag(c.id) }
                }
            }
            Section {
                ForEach(r.map { Closet.actionsFor($0) } ?? [], id: \.self) { a in
                    Button { action = a } label: { HStack { Text(a); Spacer(); if action == a { Image(systemName: "checkmark") } } }
                        .foregroundStyle(Theme.text)
                }
                TextField("自己写一个动作", text: $action)
            } header: { GroupTitle("动作") }
            Section { Button("发送") { send() }.disabled(chatId.isEmpty || action.trimmingCharacters(in: .whitespaces).isEmpty) }
            if let note { Section { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) } }
            ProblemSection(text: problem)
        }
        .navigationTitle("在会话中使用")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if chatId.isEmpty { chatId = targets.first?.id ?? "" } }
    }

    private func send() {
        do { try Closet.useInChat(id, chatId: chatId, action: action); note = "已发送"; problem = nil }
        catch { problem = error.localizedDescription }
    }
}

/// 发给角色看（4.344 第三步）：勾选的几项做成一张卡片，角色读到的只有勾选的几项
struct ClosetShareView: View {
    let id: String
    @State private var chatId = ""
    @State private var picks: Set<String> = ["photo", "desc"]
    @State private var text = ""
    @State private var note: String?
    @State private var problem: String?

    var body: some View {
        let r = Closet.get(id)
        let parts = r.map { Closet.shareParts($0) } ?? [:]
        let targets = Closet.useTargets(r)
        Form {
            Section {
                Picker("发到", selection: $chatId) {
                    ForEach(targets) { c in Text(c.characterIds.first.flatMap { (try? Repo.character($0)) ?? nil }?.displayName ?? c.title).tag(c.id) }
                }
            }
            Section {
                ForEach(Closet.shareFields) { f in
                    Toggle(f.label, isOn: Binding(get: { picks.contains(f.id) && parts[f.id] != nil }, set: { if $0 { picks.insert(f.id) } else { picks.remove(f.id) } }))
                        .disabled(parts[f.id] == nil)
                }
            } header: { GroupTitle("给角色看哪几项") } footer: {
                Text("角色读到的只有勾选的几项。照片只画在卡片上，角色读不到照片本身。")
            }
            Section { TextField("附一句话", text: $text, axis: .vertical) }
            if let r, let chat = (try? Repo.chat(chatId)) ?? nil {
                Section { Text(Closet.shareOf(r, picks: Array(picks), note: text, chat: chat).content).font(.footnote).foregroundStyle(Theme.secondaryText) } header: { GroupTitle("角色读到的") }
            }
            Section { Button("发送") { send() }.disabled(chatId.isEmpty) }
            if let note { Section { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) } }
            ProblemSection(text: problem)
        }
        .navigationTitle("发给角色看")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if chatId.isEmpty { chatId = targets.first?.id ?? "" } }
    }

    private func send() {
        do { try Closet.shareToChat(id, chatId: chatId, picks: Array(picks), note: text); note = "已发送"; problem = nil }
        catch { problem = error.localizedDescription }
    }
}

/// 套装（4.214）：这个主人的几套。今天穿的可以存成一套
struct ClosetOutfitsView: View {
    let owner: String
    @State private var tick = 0
    @State private var naming = false
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        let _ = tick
        let list = Closet.outfitsOf(owner)
        List {
            Section {
                ForEach(list, id: \.id) { o in
                    NavigationLink { ClosetOutfitView(id: o.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.string("name"))
                            Text(Closet.outfitItems(o).map { $0.string("name") }.joined(separator: "、")).font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(2)
                        }
                    }
                }
                if list.isEmpty { Text("还没有套装。").font(.footnote).foregroundStyle(Theme.secondaryText) }
            } header: { GroupTitle("共 \(list.count) 套") }
            Section {
                Button("今天穿的存为一套") { name = ""; naming = true }.disabled(Closet.wornToday(owner).isEmpty)
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("套装")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tick += 1 }
        .alert("存为套装", isPresented: $naming) {
            TextField("例如 周末出门", text: $name)
            Button("取消", role: .cancel) {}
            Button("存") {
                do { _ = try Closet.outfitFromToday(owner, name: name); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                tick += 1
            }
        }
    }
}

struct ClosetOutfitView: View {
    let id: String
    @State private var tick = 0
    @State private var theme = ""
    @State private var note: String?
    @State private var problem: String?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = tick
        Group {
            if let o = Closet.get(id), Closet.isOutfit(o) { form(o) } else { EmptyState(title: "这一套已不存在") }
        }
        .navigationTitle(Closet.get(id)?.string("name") ?? "套装")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除这一套", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Closet.remove(id); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
        } message: { Text("只删除这一套，里面的单品照旧留着。") }
    }

    @ViewBuilder private func form(_ o: Row) -> some View {
        let owner = o.string("owner")
        let inside = Set(o.strings("items"))
        let pool = Closet.itemsOf(owner).filter { !Closet.isOutfit($0) && Closet.live($0) }
        Form {
            Section {
                TextField("名称", text: Binding(get: { o.string("name") }, set: { v in
                    do { try Closet.patch(id, ["name": .string(v)]); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                    tick += 1
                }))
                Button("今天穿这一套") {
                    do { try Closet.wearOutfit(id); note = "已换上这一套"; problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                    tick += 1
                }
                LabeledContent("穿过", value: "\(Int(Closet.num(o["wornCount"]))) 次")
            }
            Section {
                ForEach(pool, id: \.id) { r in
                    Toggle(isOn: Binding(get: { inside.contains(r.id) }, set: { v in
                        var ids = o.strings("items").filter { $0 != r.id }
                        if v { ids.append(r.id) }
                        do { try Closet.patch(id, ["items": .array(ids.map { .string($0) })]); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                        tick += 1
                    })) { ClosetRow(item: r) }
                }
            } header: { GroupTitle("这一套里有") }
            if owner != Closet.me {
                Section {
                    Button("发给\(ClosetUI.ownerName(owner))") {
                        do { try Closet.sendOutfit(id); note = "已发送"; problem = nil } catch { problem = error.localizedDescription }
                    }
                    TextField("穿搭盲盒的主题", text: $theme)
                    Button("作为穿搭盲盒发出") {
                        do { try Closet.startDresscode(id, theme: theme); note = "已发出，揭晓前角色只看到主题"; problem = nil } catch { problem = error.localizedDescription }
                    }
                } footer: {
                    Text("都不调用接口，角色在下一次回复时读到。")
                    HelpNote("穿搭盲盒：按一个主题替角色挑好一套，发出去时封着，卡片上与角色读到的都只有主题；角色在这之后写的搭配同样封着，你点揭晓时两边一起打开。", title: "穿搭盲盒")
                }
            }
            if let note { Section { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) } }
            ProblemSection(text: problem)
            Section { Button("删除这一套", role: .destructive) { confirmDelete = true } }
        }
    }
}
