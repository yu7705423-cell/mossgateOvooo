import SwiftUI

/// 整理加号面板（网页版 PanelPage）：上下挪顺序，放在面板上还是收进「更多」
struct PanelEditView: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        let order = Panel.order(model.s)
        let more = Panel.more(model.s)
        List {
            Section {
                ForEach(order.indices, id: \.self) { i in
                    let id = order[i]
                    if let it = Panel.item(id) {
                        HStack(spacing: Theme.sp3) {
                            SvgIcon(name: it.icon, size: 18, color: Theme.text)
                            Text(it.label)
                            Spacer()
                            Button { model.update { Panel.move(&$0, id, -1) } } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless).disabled(i == 0).accessibilityLabel("上移")
                            Button { model.update { Panel.move(&$0, id, 1) } } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless).disabled(i == order.count - 1).accessibilityLabel("下移")
                        }
                        Toggle("收进「更多」", isOn: Binding(get: { more.contains(id) }, set: { v in model.update { Panel.setMore(&$0, id, v) } }))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text2)
                    }
                }
                HelpNote("加号面板里的格子按这里的顺序排列。收进「更多」的格子要先点「更多」才出现。群聊里只出现说得通的几格（图片、语音、骰子、分享音乐、线下）。", title: "整理面板")
            }
            Section {
                Button("恢复默认") { model.update { Panel.reset(&$0) } }
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("整理面板")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 加号面板里的「世界书」（网页版 LoreSheet 的世界书那一半）：这个角色用不用某本书，展开逐条开关。
/// 和「设定集 - 世界书」改的是同一份；全局生效的书在这里关掉，对所有角色停用
struct LoreQuickView: View {
    let charId: String
    @ObservedObject private var model = SettingsModel.shared
    @State private var char: Character?
    @State private var books: [Lorebook] = []
    @State private var open: Set<String> = []
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                ForEach(books, id: \.id) { b in
                    let on = b.global || (char?.lorebookIds.contains(b.id) ?? false)
                    Toggle(isOn: Binding(get: { on }, set: { flip(b, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.name.isEmpty ? "未命名" : b.name)
                            Text("\(b.entries.count) 个条目\(b.global ? " · 全局生效" : "")").font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                    if !b.entries.isEmpty {
                        Button(open.contains(b.id) ? "收起条目" : "展开条目") {
                            if open.contains(b.id) { open.remove(b.id) } else { open.insert(b.id) }
                        }
                        .font(.footnote)
                    }
                    if open.contains(b.id) {
                        ForEach(b.entries, id: \.id) { e in
                            Toggle(isOn: Binding(get: { e.enabled }, set: { setEntry(b, e, $0) })) {
                                Text(e.comment.isEmpty ? String(e.content.prefix(16)) : e.comment).font(.system(size: 14))
                            }
                            .padding(.leading, Theme.sp4)
                        }
                    }
                }
                if books.isEmpty { Text("还没有对话用途的世界书。在「设定集 - 世界书」中新建或导入。").foregroundStyle(Theme.text2) }
                HelpNote("开关表示该角色是否使用这本世界书。全局生效的书对所有角色生效，在此关闭后对所有角色停用。展开可以逐条开关。与「设定集 - 世界书」里的是同一份。", title: "会话里的世界书")
            } header: { Text(char.map { "「\($0.name)」用的世界书" } ?? "世界书") }
            builtinSection
            ProblemSection(text: problem)
        }
        .navigationTitle("世界书")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    /// 内置卡片（微博、小红书等帖子卡片）：和一本世界书一样挂在角色上或全局生效，逐张可停用（网页版 LoreSheet）
    @ViewBuilder private var builtinSection: some View {
        let st = HtmlCard.builtinState(model.s)
        let on = st.global || (char?.lorebookIds.contains(HtmlCard.builtinBookId) ?? false)
        Section {
            Toggle(isOn: Binding(get: { on }, set: { flipBuiltin($0, global: st.global) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("内置卡片")
                    Text("\(HtmlCard.builtinEntries.count) 张\(st.global ? " · 全局生效" : "")").font(.footnote).foregroundStyle(Theme.text2)
                }
            }
            Toggle("对全部角色生效", isOn: Binding(get: { st.global }, set: { v in model.update { HtmlCard.setBuiltin(&$0, global: v) } }))
            Button(open.contains(HtmlCard.builtinBookId) ? "收起卡片" : "展开卡片") {
                if open.contains(HtmlCard.builtinBookId) { open.remove(HtmlCard.builtinBookId) } else { open.insert(HtmlCard.builtinBookId) }
            }
            .font(.footnote)
            if open.contains(HtmlCard.builtinBookId) {
                ForEach(HtmlCard.builtinEntries.indices, id: \.self) { i in
                    let e = HtmlCard.builtinEntries[i]
                    let id = e["id"]?.string ?? ""
                    Toggle(isOn: Binding(get: { !st.off.contains(id) }, set: { v in model.update { HtmlCard.setBuiltin(&$0, card: id, on: v) } })) {
                        Text(e["comment"]?.string ?? id).font(.system(size: 14))
                    }
                    .padding(.leading, Theme.sp4)
                }
            }
            HelpNote("内置卡片是应用自带的一组帖子样式的 HTML 卡片。开启后，聊天中出现卡片的关键词时，角色可以按卡片的格式发一张卡片。卡片只显示文字与样式，不运行脚本、不联网。", title: "内置卡片")
        }
    }

    private func flipBuiltin(_ v: Bool, global: Bool) {
        if global { model.update { HtmlCard.setBuiltin(&$0, global: v) }; return }
        do { try Knowledge.setAttached(v, bookId: HtmlCard.builtinBookId, charId: charId); reload() }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    private func reload() {
        char = (try? Repo.character(charId)) ?? nil
        books = ((try? Repo.lorebooks()) ?? []).filter { $0.purpose == "chat" }
    }

    private func flip(_ b: Lorebook, _ on: Bool) {
        do {
            if b.global { _ = try Knowledge.updateBook(b.id, ["global": .bool(on)]) }
            else { try Knowledge.setAttached(on, bookId: b.id, charId: charId) }
            reload()
        } catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    private func setEntry(_ b: Lorebook, _ e: LoreEntry, _ on: Bool) {
        do { try Knowledge.updateEntry(bookId: b.id, entryId: e.id, ["enabled": .bool(on)]); reload() }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}

/// 共享位置（网页版 SharePage）：两端各填一个地方，距离本机算好告诉角色
struct GeoView: View {
    let chatId: String
    @State private var on = false
    @State private var me = Geo.Spot()
    @State private var char = Geo.Spot()
    @State private var charName = "角色"
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Toggle("共享位置", isOn: $on)
                HelpNote("开启并填好两端的位置后，双方所在地与直线距离写进提示词。距离由本机计算，角色照着说，不自己估。坐标由你填写，不读取手机定位。不另外调用接口。", title: "共享位置")
                if on, let km = Geo.distance(me, char) {
                    HStack { Text("直线距离"); Spacer(); Text(Geo.distanceText(km)).foregroundStyle(Theme.text2) }
                }
            }
            spotSection("我在", spot: $me, side: "me")
            spotSection("\(charName)在", spot: $char, side: "char")
            ProblemSection(text: problem)
        }
        .navigationTitle("共享位置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let chat = (try? Repo.chat(chatId)) ?? nil
            let st = Geo.state(chat)
            on = st.on
            me = st.me ?? Geo.Spot()
            char = st.char ?? Geo.Spot()
            if let id = chat?.characterIds.first, let c = (try? Repo.character(id)) ?? nil { charName = c.name }
            loaded = true
        }
        .onChange(of: on) { _, v in
            guard loaded else { return }
            do { try Geo.setOn(chatId, v) } catch { problem = "保存失败：\(error.localizedDescription)" }
        }
    }

    private func spotSection(_ title: String, spot: Binding<Geo.Spot>, side: String) -> some View {
        Section {
            Menu {
                ForEach(Geo.cities, id: \.name) { c in
                    Button(c.name) { spot.wrappedValue = Geo.Spot(place: c.name, lat: c.lat, lng: c.lng); save(side, spot.wrappedValue) }
                }
            } label: { Label("选一个常用城市", systemImage: "mappin.and.ellipse") }
            TextField("地点名称", text: Binding(get: { spot.wrappedValue.place }, set: { spot.wrappedValue.place = $0 }))
                .onSubmit { save(side, spot.wrappedValue) }
            HStack {
                TextField("纬度", text: coord(spot, \.lat)).keyboardType(.numbersAndPunctuation).onSubmit { save(side, spot.wrappedValue) }
                TextField("经度", text: coord(spot, \.lng)).keyboardType(.numbersAndPunctuation).onSubmit { save(side, spot.wrappedValue) }
            }
            HStack {
                Button("保存") { save(side, spot.wrappedValue) }
                Spacer()
                Button("清空", role: .destructive) { spot.wrappedValue = Geo.Spot(); save(side, nil) }
            }
            .buttonStyle(.borderless)
        } header: { Text(title) }
    }

    private func coord(_ spot: Binding<Geo.Spot>, _ key: WritableKeyPath<Geo.Spot, Double?>) -> Binding<String> {
        Binding(get: { spot.wrappedValue[keyPath: key].map { String($0) } ?? "" },
                set: { spot.wrappedValue[keyPath: key] = Double($0.trimmingCharacters(in: .whitespaces)) })
    }

    private func save(_ side: String, _ spot: Geo.Spot?) {
        do { try Geo.setSpot(chatId, side: side, spot) } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}
