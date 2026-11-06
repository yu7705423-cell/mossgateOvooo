import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// 聊天主题的几页（数据与层叠在 Prompt/ChatTheme.swift）。
//
// 入口两处（第 5 条：开关放在起作用的地方）：会话右上角菜单「主题」管这一段会话（ThemeGalleryView(chatId:)），
// 「设置 - 主题 - 聊天主题」管全部会话的默认（chatId 为 nil）。两处是同一页，只是改的那一格不同；
// 主题本身（skins 这一域的一行）只存一份，两处看到的永远一致。

extension ChatTheme {
    /// look.scheme 换成 SwiftUI 的外观：空为跟随系统
    static func colorScheme(_ s: String) -> ColorScheme? {
        switch s {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}

/// 主题写了始终浅色或始终深色：这一块按它画。不分支，换主题时不换视图（输入框不丢焦点、滚动位置不丢）
struct ForcedScheme: ViewModifier {
    let scheme: ColorScheme?
    @Environment(\.colorScheme) private var current

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, scheme ?? current)
    }
}

// MARK: - 挑一套

struct ThemeGalleryView: View {
    /// nil：全部会话的默认
    let chatId: String?
    @State private var tick = 0
    @State private var problem: String?
    @State private var notice: String?
    @State private var naming = false
    @State private var newName = ""
    @State private var copyFrom: Row?
    @State private var deleting: Row?
    @State private var importing: Skins.Pack?
    @State private var picking = false
    @State private var exported: URL?
    @State private var confirmAll = false
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable, Hashable { let id: String }

    private var settings: AppSettings { _ = tick; return AppSettings.load() }
    private var chat: Chat? {
        _ = tick
        guard let chatId else { return nil }
        return try? Repo.chat(chatId)
    }
    private var globalId: String { settings.raw["globalSkinId"]?.string ?? "" }
    /// 这一页改的那一格此刻挂的那一份
    private var currentId: String { chatId == nil ? globalId : (chat?.row.string("skinId") ?? "") }

    static func name(_ r: Row) -> String { r.string("name").isEmpty ? "未命名" : r.string("name") }

    /// 「设置 - 主题」那一行右边的状态
    static func globalLabel(_ s: AppSettings) -> String {
        if s.raw["skinOff"]?.bool == true { return "已关闭" }
        guard let r = ChatTheme.row(s.raw["globalSkinId"]?.string ?? "") else { return "未使用" }
        return name(r)
    }

    var body: some View {
        let mine = { _ = tick; return Skins.all() }()
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if settings.raw["skinOff"]?.bool == true { offSection }
            currentSection
            builtinSection
            if let exported {
                Section {
                    ShareLink(item: exported) { Label("存储或发送导出的主题", systemImage: "square.and.arrow.up") }
                }
            }
            importSection
            if chatId != nil { ShowSection() }
            mineSection(mine)
        }
        .navigationTitle(chatId == nil ? "聊天主题" : "主题")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .eiraSkinChanged)) { _ in tick += 1 }
        .documentPicker(isPresented: $picking, types: [UTType.json, UTType.plainText, UTType(filenameExtension: "docx")].compactMap { $0 }) { urls in
            guard let url = urls.first else { return }
            do { importing = try Skins.parsePack(DocText.read(url)); problem = nil }
            catch { problem = "无法导入：\(error.localizedDescription)" }
        }
        .navigationDestination(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } })) {
            if let importing { SkinImportView(chatId: chatId ?? "", pack: importing) { tick += 1 } }
        }
        .navigationDestination(item: $editing) { t in ThemeEditView(id: t.id) }
        .alert(copyFrom == nil ? "新建主题" : "复制主题", isPresented: $naming) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) { copyFrom = nil }
            Button(copyFrom == nil ? "新建" : "复制") { create() }
        }
        .confirmationDialog("删除这份主题", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { r in
            Button("删除", role: .destructive) { run { try Skins.remove(r.id) } }
        } message: { r in
            Text("「\(Self.name(r))」挂在 \(ChatTheme.usedBy(r.id)) 段会话上\(globalId == r.id ? "，并且是全部会话的默认" : "")。删除后这些会话一并取下。此操作不能撤销。")
        }
        .confirmationDialog("应用到全部会话", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("设为默认，保留各段会话单独挂的主题") { applyAll(clear: false) }
            Button("设为默认，并取下各段会话单独挂的主题", role: .destructive) { applyAll(clear: true) }
        } message: {
            Text("这份主题将成为全部会话的默认。取下之后，各段会话改用这份默认主题；取下的主题本身保留。")
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        }
    }

    private var offSection: some View {
        Section {
            Button("开启聊天主题与美化") {
                run {
                    var st = try AppSettings.loadForWrite()
                    st.raw["skinOff"] = .bool(false)
                    try st.save()
                    NotificationCenter.default.post(name: .eiraSkinChanged, object: nil)
                }
            }
        } footer: {
            Text("总开关已在「设置 - 主题」中关闭，所有会话均不显示主题与美化。开启后恢复显示。")
        }
    }

    @ViewBuilder private var currentSection: some View {
        let cur = ChatTheme.row(currentId)
        Section {
            if let chatId {
                LabeledContent("这段会话", value: cur.map(Self.name) ?? followLabel)
                if cur != nil {
                    Button { run { try Skins.attach(chatId, "") } } label: { Text("取下，跟随全部会话的默认").foregroundStyle(Theme.text) }
                }
            } else {
                LabeledContent("全部会话的默认", value: cur.map(Self.name) ?? "未使用")
                if cur != nil {
                    Button { run { try ChatTheme.setGlobal("") } } label: { Text("不使用默认主题").foregroundStyle(Theme.text) }
                }
            }
            if let cur {
                if ChatTheme.isBuiltin(cur.id) {
                    Button { startCopy(cur) } label: { Text("复制一份后修改").foregroundStyle(Theme.text) }
                } else {
                    Button { editing = EditTarget(id: cur.id) } label: { Text("修改这份主题").foregroundStyle(Theme.text) }
                }
                if chatId != nil {
                    Button { confirmAll = true } label: { Text("应用到全部会话").foregroundStyle(Theme.text) }
                }
            }
        } header: { GroupTitle("当前") } footer: {
            if chatId != nil {
                HelpNote("主题按会话生效：挂在这段会话上的主题优先；没有挂时使用「设置 - 主题 - 聊天主题」中的默认主题。这段会话自己在「聊天背景」中设过的背景图、上下栏与旁白颜色优先于主题。修改一份主题时，挂着它的每段会话一并改变。", title: "主题：按会话生效")
            } else {
                HelpNote("默认主题用于没有单独挂主题的会话。某段会话自己的主题在会话右上角菜单的「主题」中设置，优先于默认主题。", title: "聊天主题：全部会话的默认")
            }
        }
    }

    private var followLabel: String {
        guard settings.raw["skinOff"]?.bool != true, let g = ChatTheme.row(globalId) else { return "应用默认样式" }
        return "跟随默认（\(Self.name(g))）"
    }

    private var builtinSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.sp3) {
                    ForEach(ChatTheme.builtins, id: \.id) { r in
                        Button { apply(r.id) } label: { ThemeCard(row: r, on: currentId == r.id) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("复制一份后修改") { startCopy(r) }
                            }
                    }
                }
                .padding(.vertical, Theme.sp2)
            }
            .mask(HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
            })
        } header: { GroupTitle("内置主题（\(ChatTheme.builtins.count)）") } footer: {
            HelpNote("内置主题只用黑白灰，深色模式下各有一套对应的颜色。点一下即挂上；内置主题不能修改，长按选择「复制一份后修改」。", title: "内置主题")
        }
    }

    private var importSection: some View {
        Section {
            Button { picking = true } label: { Label("从文件导入", systemImage: "doc") }
            NavigationLink { SkinImportView(chatId: chatId ?? "") } label: { Label("粘贴导入", systemImage: "doc.on.clipboard") }
            NavigationLink { SkinImportView(chatId: chatId ?? "", mode: .css) } label: {
                Label("粘贴 CSS", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        } header: { GroupTitle("导入") } footer: {
            HelpNote("读取本应用导出的主题或美化包：JSON、TXT、DOCX 文件，或复制的一段文字（连同 BEGIN 与 END 两行标记）。也可以直接粘贴一段 CSS，作为一份只含自定义 CSS 的美化。导入后新建一份，不覆盖现有的主题；从会话菜单进来时一并挂在这段会话上。只认本应用自己的格式。", title: "导入主题与美化包")
        }
    }

    private func mineSection(_ list: [Row]) -> some View {
        Section {
            Button { copyFrom = nil; newName = ""; naming = true } label: { Label("新建主题", systemImage: "plus") }
            if list.isEmpty {
                Text("尚无自己的主题").foregroundStyle(Theme.text3)
            }
            ForEach(list, id: \.id) { r in
                Button { apply(r.id) } label: {
                    HStack(spacing: Theme.sp3) {
                        ThemeCard(row: r, on: false, small: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.name(r)).foregroundStyle(Theme.text)
                            Text(usage(r)).font(.caption).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        if currentId == r.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) { deleting = r }
                    Button("修改") { editing = EditTarget(id: r.id) }
                }
                .contextMenu {
                    Button("修改") { editing = EditTarget(id: r.id) }
                    Button("复制") { startCopy(r) }
                    Button("导出") { export(r) }
                    if chatId != nil { Button("设为全部会话的默认") { run { try ChatTheme.setGlobal(r.id) } } }
                    Button("删除", role: .destructive) { deleting = r }
                }
            }
        } header: { GroupTitle("我的主题（\(list.count)）") } footer: {
            HelpNote("我的主题包括在原生版中新建的主题，以及导入的主题与美化包。点一下即挂上；左滑修改或删除，长按可复制、导出。导出为本应用自己的格式，网页版读取其中的网页版美化部分，原生主题的设置只在原生版中显示。", title: "我的主题")
        }
    }

    private func usage(_ r: Row) -> String {
        var parts = ["已用于 \(ChatTheme.usedBy(r.id)) 段会话"]
        if globalId == r.id { parts.append("全部会话的默认") }
        if r[ChatTheme.field] == nil { parts.append("网页版美化") }
        return parts.joined(separator: " · ")
    }

    private func apply(_ id: String) {
        run {
            if let chatId { try Skins.attach(chatId, id) } else { try ChatTheme.setGlobal(id) }
        }
    }

    private func applyAll(clear: Bool) {
        let id = currentId
        do {
            let n = try ChatTheme.applyToAll(id, clearChats: clear)
            notice = clear ? "已设为默认，取下了 \(n) 段会话单独挂的主题。" : "已设为全部会话的默认。"
            problem = nil
        } catch {
            problem = "未能应用：\(error.localizedDescription)"
        }
        tick += 1
    }

    private func startCopy(_ r: Row) {
        copyFrom = r
        newName = "\(Self.name(r)) 副本"
        naming = true
    }

    private func create() {
        let from = copyFrom
        copyFrom = nil
        do {
            let r = try ChatTheme.create(name: newName, from: from)
            if let chatId { try Skins.attach(chatId, r.id) } else { try ChatTheme.setGlobal(r.id) }
            problem = nil
            tick += 1
            editing = EditTarget(id: r.id)
        } catch {
            problem = "未能新建：\(error.localizedDescription)"
        }
    }

    private func export(_ r: Row) {
        do { exported = try ChatTheme.exportFile(r); problem = nil }
        catch { problem = "未能导出：\(error.localizedDescription)" }
    }

    private func run(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "无法保存主题：\(error.localizedDescription)" }
        tick += 1
    }
}

/// 主题的小样：底色与两个气泡，下面一行名字
struct ThemeCard: View {
    let row: Row
    var on = false
    var small = false
    @Environment(\.colorScheme) private var env

    var body: some View {
        let t = ChatTheme.resolve(row: row)
        let dark = t.scheme == "dark" ? true : t.scheme == "light" ? false : env == .dark
        let w: CGFloat = small ? 44 : 96
        let h: CGFloat = small ? 56 : 120
        VStack(spacing: 6) {
            ThemePreview(theme: t, dark: dark, compact: true)
                .frame(width: 220, height: 275)
                .scaleEffect(w / 220, anchor: .topLeading)
                .frame(width: w, height: h, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: small ? Theme.rXs : Theme.rSm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: small ? Theme.rXs : Theme.rSm, style: .continuous)
                    .strokeBorder(on ? Theme.text : Theme.border, lineWidth: on ? 2 : 1))
                .allowsHitTesting(false)
            if !small {
                Text(ThemeGalleryView.name(row)).font(.system(size: 12)).foregroundStyle(on ? Theme.text : Theme.text2).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ThemeGalleryView.name(row))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 改一套

struct ThemeEditView: View {
    let id: String
    @State private var tick = 0
    @State private var problem: String?
    /// 改深色那一层
    @State private var dark = false
    @State private var part = "palette"
    @State private var name = ""
    /// 拖着的滑块：松手才写库
    @State private var drafts: [String: Double] = [:]
    @State private var wallPick: PhotosPickerItem?
    @State private var exported: URL?
    @State private var deleting = false
    @State private var copying = false
    @State private var copyName = ""
    @State private var copied: ThemeGalleryView.EditTarget?
    @Environment(\.colorScheme) private var env
    @Environment(\.dismiss) private var dismiss

    private var row: Row? { _ = tick; return ChatTheme.row(id) }
    private var builtin: Bool { ChatTheme.isBuiltin(id) }

    static let parts: [(id: String, label: String)] = [
        ("palette", "配色"), ("wall", "背景"), ("bubble", "气泡"), ("avatar", "头像"), ("bars", "上下栏"),
        ("font", "字体"), ("stamp", "时间"), ("status", "状态栏"), ("more", "其他"),
    ]

    var body: some View {
        let r = row
        let t = ChatTheme.resolve(row: r)
        let forced = t.scheme
        let previewDark = forced == "dark" ? true : forced == "light" ? false : dark
        VStack(spacing: 0) {
            ThemePreview(theme: t, dark: previewDark)
                .frame(height: 280)
                .clipped()
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            if let r {
                Form {
                    if let problem { Text(problem).foregroundStyle(Theme.danger) }
                    if builtin {
                        builtinNote
                    } else {
                        header
                        sections(r)
                    }
                }
            } else {
                EmptyState(title: "这份主题已不存在")
            }
        }
        .navigationTitle(r.map(ThemeGalleryView.name) ?? "主题")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = r.map(ThemeGalleryView.name) ?? "" }
        .onDisappear(perform: rename)
        .onReceive(NotificationCenter.default.publisher(for: .eiraSkinChanged)) { _ in tick += 1 }
        .onChange(of: wallPick) { _, item in
            guard let item else { return }
            wallPick = nil
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    let img = try Images.save(data)
                    await MainActor.run { write("wall.image", .string(img), base: true) }
                } catch {
                    await MainActor.run { problem = "图片未能保存：\(error.localizedDescription)" }
                }
            }
        }
        .confirmationDialog("删除这份主题", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Skins.remove(id); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
        } message: {
            Text("挂着它的 \(ChatTheme.usedBy(id)) 段会话一并取下。此操作不能撤销。")
        }
        .alert("复制主题", isPresented: $copying) {
            TextField("名称", text: $copyName)
            Button("取消", role: .cancel) {}
            Button("复制") {
                do {
                    guard let r = row else { return }
                    let n = try ChatTheme.create(name: copyName, from: r)
                    copied = ThemeGalleryView.EditTarget(id: n.id)
                } catch { problem = "未能复制：\(error.localizedDescription)" }
            }
        }
        .navigationDestination(item: $copied) { t in ThemeEditView(id: t.id) }
    }

    private var builtinNote: some View {
        Section {
            Text("内置主题不能修改。复制一份后可以逐项调整，复制出的那一份在「我的主题」中。").foregroundStyle(Theme.text2)
            Button("复制一份") { copyName = "\(row.map(ThemeGalleryView.name) ?? "主题") 副本"; copying = true }
        }
    }

    /// 深浅两层与分类：一直在最上面
    private var header: some View {
        Section {
            Picker("改哪一种外观", selection: $dark) {
                Text("浅色时").tag(false)
                Text("深色时").tag(true)
            }
            .pickerStyle(.segmented)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.sp2) {
                    ForEach(Self.parts, id: \.id) { p in
                        Button { part = p.id } label: {
                            Text(p.label).font(.system(size: 13, weight: part == p.id ? .semibold : .regular))
                                .foregroundStyle(part == p.id ? Theme.text : Theme.text2)
                                .padding(.horizontal, Theme.sp3).padding(.vertical, 6)
                                .background(part == p.id ? Theme.surface3 : Theme.surface2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } footer: {
            HelpNote("浅色时的设置是这份主题的基础；深色时只记下单独改过的几项，其余沿用浅色时的设置。主题设为始终浅色或始终深色时，预览与会话页只按那一种外观显示。", title: "主题：浅色时与深色时")
        }
    }

    @ViewBuilder private func sections(_ r: Row) -> some View {
        let s = ChatTheme.slots(r, dark: dark)
        switch part {
        case "palette":
            Section {
                choiceRow("外观", "look.scheme", s, [("", "跟随系统"), ("light", "始终浅色"), ("dark", "始终深色")], base: true)
                colorRow("底色", "palette.bg", s, alpha: false)
                colorRow("浮层（角色气泡、输入框）", "palette.surface", s)
                colorRow("文字", "palette.text", s)
                colorRow("次要文字（时刻、时间分隔）", "palette.text2", s)
                colorRow("主色（我的气泡）", "palette.accent", s)
            } header: { GroupTitle("配色") } footer: {
                HelpNote("底色铺在会话页与上下栏；浮层用于角色的气泡与输入框；主色用于自己的气泡，气泡上的字按主色的明暗自动取黑或白。下面各组单独设过的颜色优先于这里。", title: "主题：配色")
            }
        case "wall":
            let base = ChatTheme.slots(r, dark: false)
            Section {
                HStack(spacing: Theme.sp3) {
                    Group {
                        if let img = base.color("wall.image") { LocalImage(id: img, maxPixel: 200) }
                        else { SvgIcon(name: "image", size: 18, color: Theme.text3) }
                    }
                    .frame(width: 56, height: 56)
                    .background(Theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
                    VStack(alignment: .leading, spacing: Theme.sp2) {
                        PhotosPicker(selection: $wallPick, matching: .images) { Text(base.color("wall.image") == nil ? "从相册选择" : "更换图片") }
                        if base.color("wall.image") != nil {
                            Button("清除", role: .destructive) { write("wall.image", nil, base: true) }
                        }
                    }
                }
                if base.color("wall.image") != nil {
                    numRow("模糊", "wall.blur", base, def: 0, range: 0...40, step: 2, base: true)
                    numRow("遮罩", "wall.dim", base, def: 0, range: 0...90, step: 5, unit: "%", base: true)
                }
            } header: { GroupTitle("聊天背景") } footer: {
                HelpNote("背景图铺满整个会话页，浅色与深色共用一张。遮罩使背景朝底色变淡。某段会话自己在「聊天背景」中设了背景图时，以那一张为准。", title: "主题：聊天背景")
            }
        case "bubble":
            bubbleSection("我的气泡", "mine", s)
            bubbleSection("角色的气泡", "theirs", s)
            Section {
                numRow("消息间距", "spacing.gap", s, def: Double(Theme.sp4), range: 0...48, step: 1)
                numRow("同一轮内间距", "spacing.gapIn", s, def: 5, range: 0...24, step: 1)
            } header: { GroupTitle("间距") }
        case "avatar":
            Section {
                choiceRow("形状", "avatar.shape", s, [("", "跟随默认"), ("round", "圆形"), ("square", "方形"), ("soft", "圆角方形")])
                numRow("大小", "avatar.size", s, def: Double(Theme.avatarSize), range: 24...64, step: 1)
                choiceRow("显示头像", "avatar.show", s, [("", "跟随默认"), ("both", "双方"), ("theirs", "仅角色"), ("mine", "仅自己"), ("none", "都不显示")])
            } header: { GroupTitle("头像") } footer: {
                HelpNote("不显示的那一边连位置一起收起，气泡贴着屏幕边缘。隐藏角色头像后，点头像查看心声随之不可用。", title: "主题：显示头像")
            }
        case "bars":
            barSection("顶栏", "nav", s)
            barSection("输入栏", "composer", s)
            Section {
                colorRow("输入框底色", "composer.input", s)
            } footer: {
                HelpNote("上下栏默认为实色，颜色跟随底色。半透明与毛玻璃时，消息从栏下经过。某段会话自己在「聊天背景」中设过上下栏时，以那一套为准。", title: "主题：上下栏")
            }
        case "font":
            Section {
                choiceRow("字体", "font.family", s, [("", "跟随默认"), ("system", "系统"), ("serif", "衬线"), ("rounded", "圆体")])
                numRow("气泡字号", "font.size", s, def: Double(Theme.bubbleFont), range: 11...24, step: 1)
                numRow("整体缩放", "font.scale", s, def: 1, range: 0.8...1.4, step: 0.05, fmt: { "\(Int(($0 * 100).rounded()))%" })
            } header: { GroupTitle("字体") } footer: {
                HelpNote("字体用于气泡、时间、输入框与顶栏标题。整体缩放同时作用于气泡字号、消息时刻与时间分隔行。", title: "主题：字体")
            }
        case "stamp":
            Section {
                colorRow("消息时刻与已读", "stamp.color", s)
                numRow("消息时刻字号", "stamp.size", s, def: 11, range: 9...16, step: 1)
                colorRow("时间分隔行与旁白的文字", "sys.color", s)
                colorRow("时间分隔行的底", "sys.fill", s)
            } header: { GroupTitle("时间与旁白") } footer: {
                HelpNote("时间分隔行设了底色时显示为一枚胶囊。旁白文字颜色在某段会话的「聊天背景」中单独设过时，以那一项为准。", title: "主题：时间与旁白")
            }
        case "status":
            Section {
                colorRow("底色", "status.fill", s)
                colorRow("文字", "status.text", s)
                numRow("圆角", "status.radius", s, def: Double(Theme.rMd), range: 0...24, step: 1)
                colorRow("描边", "status.border", s)
            } header: { GroupTitle("状态栏") } footer: {
                HelpNote("状态栏是会话中显示角色数值的那一块，在会话右上角菜单的「状态栏」中开启。", title: "主题：状态栏")
            }
        default:
            moreSections(r)
        }
    }

    @ViewBuilder private func bubbleSection(_ title: String, _ side: String, _ s: ChatTheme.Slots) -> some View {
        Section {
            colorRow("底色", "\(side).fill", s)
            colorRow("文字", "\(side).text", s)
            numRow("圆角", "\(side).radius", s, def: Double(Theme.bubbleRadius), range: 0...40, step: 1)
            flagRow("小尾巴", "\(side).tail", s)
            colorRow("描边", "\(side).border", s)
            if s.color("\(side).border") != nil {
                numRow("描边粗细", "\(side).borderWidth", s, def: 1, range: 0...4, step: 0.5, fmt: { String(format: "%.1f", $0) })
            }
            numRow("左右内距", "\(side).padX", s, def: Double(Theme.bubblePadX), range: 2...32, step: 1)
            numRow("上下内距", "\(side).padY", s, def: Double(Theme.bubblePadY), range: 2...28, step: 1)
        } header: { GroupTitle(title) } footer: {
            if side == "mine" {
                HelpNote("底色不设时，自己的气泡用配色中的主色，角色的气泡用浮层色。小尾巴画在同一条消息最后一个气泡靠外的下角。", title: "主题：气泡")
            }
        }
    }

    @ViewBuilder private func barSection(_ title: String, _ group: String, _ s: ChatTheme.Slots) -> some View {
        Section {
            choiceRow("样式", "\(group).style", s, [("", "跟随默认"), ("solid", "实色"), ("clear", "半透明"), ("glass", "毛玻璃")])
            colorRow("颜色", "\(group).color", s, alpha: false)
            if ["clear", "glass"].contains(s.choice("\(group).style")) {
                numRow("不透明度", "\(group).alpha", s, def: 70, range: 0...100, step: 5, unit: "%")
            }
            choiceRow("文字颜色", "\(group).fg", s, [("", "跟随主题"), ("light", "浅色"), ("dark", "深色")])
        } header: { GroupTitle(title) }
    }

    @ViewBuilder private func moreSections(_ r: Row) -> some View {
        Section {
            TextField("名称", text: $name).onSubmit(rename)
        } header: { GroupTitle("名称") }
        if hasWeb(r) {
            Section {
                NavigationLink { SkinEditView(id: id) } label: { Text("网页版美化的尺寸与颜色") }
                if !r.string("css").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    NavigationLink { SkinCssReportView(id: id) } label: { Text("查看自定义 CSS 的还原情况") }
                }
            } header: { GroupTitle("网页版美化") } footer: {
                HelpNote("这份主题带着网页版美化的部分（令牌、生成器或自定义 CSS），网页版照常读取。原生版中，这里调过的各项优先于网页版美化中的同一项。", title: "主题：网页版美化")
            }
        }
        Section {
            Button("复制一份") { copyName = "\(ThemeGalleryView.name(r)) 副本"; copying = true }
            Button("导出主题") {
                do { exported = try ChatTheme.exportFile(r); problem = nil }
                catch { problem = "未能导出：\(error.localizedDescription)" }
            }
            if let exported {
                ShareLink(item: exported) { Label("存储或发送导出的主题", systemImage: "square.and.arrow.up") }
            }
        } footer: {
            HelpNote("导出为本应用自己的格式（JSON），背景图一并装在文件里。别人导入后新建一份，不覆盖已有的主题。", title: "主题：导出")
        }
        Section {
            Button("删除这份主题", role: .destructive) { deleting = true }
        }
    }

    private func hasWeb(_ r: Row) -> Bool {
        !r.string("css").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(r["tokens"]?.object ?? [:]).isEmpty
            || !(r["gen"]?.object ?? [:]).isEmpty || !r.string("shape").isEmpty
    }

    // MARK: 一行

    /// 这一层写过这一格（深色那一层只认单独写过的）
    private func isSet(_ path: String, base: Bool = false) -> Bool {
        guard let r = row else { return false }
        if dark && !base { return ChatTheme.darkSet(r, path) }
        return ChatTheme.slots(r, dark: false).v[path] != nil
    }

    private func resetButton(_ path: String, base: Bool = false) -> some View {
        Button("默认") { write(path, nil, base: base) }
            .font(.footnote).buttonStyle(.borderless)
            .opacity(isSet(path, base: base) ? 1 : 0)
            .disabled(!isSet(path, base: base))
    }

    private func colorRow(_ label: String, _ path: String, _ s: ChatTheme.Slots, alpha: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                resetButton(path)
            }
            GreySwatches(value: s.color(path) ?? "", alpha: alpha) { v in write(path, v.isEmpty ? nil : JSONValue.string(v)) }
        }
    }

    private func numRow(_ label: String, _ path: String, _ s: ChatTheme.Slots, def: Double, range: ClosedRange<Double>, step: Double,
                        unit: String = "", base: Bool = false, fmt: ((Double) -> String)? = nil) -> some View {
        let cur = drafts[path] ?? s.num(path) ?? def
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text((fmt?(cur) ?? "\(Int(cur.rounded()))") + unit).font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.text3)
                resetButton(path, base: base)
            }
            Slider(value: Binding(get: { drafts[path] ?? s.num(path) ?? def }, set: { drafts[path] = $0 }), in: range, step: step) { editing in
                if !editing, let v = drafts[path] {
                    write(path, .number(v), base: base)
                    drafts[path] = nil
                }
            }
        }
    }

    private func flagRow(_ label: String, _ path: String, _ s: ChatTheme.Slots) -> some View {
        Toggle(label, isOn: Binding(get: { s.flag(path) ?? false }, set: { write(path, .bool($0)) }))
    }

    private func choiceRow(_ label: String, _ path: String, _ s: ChatTheme.Slots, _ options: [(String, String)], base: Bool = false) -> some View {
        Picker(label, selection: Binding(get: { s.choice(path) }, set: { v in write(path, v.isEmpty ? nil : JSONValue.string(v), base: base) })) {
            ForEach(options, id: \.0) { o in Text(o.1).tag(o.0) }
        }
    }

    private func write(_ path: String, _ value: JSONValue?, base: Bool = false) {
        do {
            try ChatTheme.set(id, path, value, dark: dark && !base)
            problem = nil
        } catch {
            problem = "无法保存主题：\(error.localizedDescription)"
        }
        tick += 1
    }

    private func rename() {
        guard !builtin, let r = row else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != r.string("name") else { return }
        do { try Skins.update(id) { $0["name"] = .string(n) } } catch { problem = "未能改名：\(error.localizedDescription)" }
        tick += 1
    }
}

/// 一排灰色色块：默认、几档灰、自选（自选的颜色是用户自己的内容，不限于灰）
struct GreySwatches: View {
    let value: String
    var alpha = true
    var onPick: (String) -> Void

    static let greys = ["#FFFFFF", "#F5F5F5", "#E9E9E9", "#D6D6D6", "#B0B0B0", "#8A8A8A", "#5C5C5C", "#3A3A3A", "#262626", "#1A1A1A", "#000000"]

    var body: some View {
        let custom = !value.isEmpty && !Self.greys.contains(value)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.sp2) {
                Button { onPick("") } label: { swatch("", on: value.isEmpty) }
                    .buttonStyle(.plain).accessibilityLabel("默认")
                ForEach(Self.greys, id: \.self) { c in
                    Button { onPick(c) } label: { swatch(c, on: value == c) }
                        .buttonStyle(.plain).accessibilityLabel(c)
                }
                ColorPicker("自选颜色", selection: Binding(
                    get: { Skins.color(custom ? value : "#888888") ?? .gray },
                    set: { onPick(Self.hex($0, alpha: alpha)) }), supportsOpacity: alpha)
                    .labelsHidden()
                    .overlay { if custom { Circle().strokeBorder(Theme.text, lineWidth: 2).allowsHitTesting(false) } }
            }
            .padding(.vertical, 2)
        }
    }

    private func swatch(_ c: String, on: Bool) -> some View {
        ZStack {
            if c.isEmpty {
                Circle().fill(Theme.surface2)
                Path { p in p.move(to: CGPoint(x: 6, y: 22)); p.addLine(to: CGPoint(x: 22, y: 6)) }
                    .stroke(Theme.text3, lineWidth: 1)
            } else {
                Circle().fill(Skins.color(c) ?? .clear)
            }
            Circle().strokeBorder(on ? Theme.text : Theme.border, lineWidth: on ? 2 : 1)
        }
        .frame(width: 28, height: 28)
    }

    static func hex(_ c: Color, alpha: Bool) -> String {
        let u = UIColor(c)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        u.getRed(&r, green: &g, blue: &b, alpha: &a)
        let to = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        let base = String(format: "#%02X%02X%02X", to(r), to(g), to(b))
        return alpha && a < 0.999 ? base + String(format: "%02X", to(a)) : base
    }
}

// MARK: - 预览：一页示例会话

/// 一页示例会话，与会话页走同一套：Skins.Look 定气泡与头像，样式经 \.phSkin 交给 PhBox，背景与上下栏照 ChatLook 画
struct ThemePreview: View {
    let theme: ChatTheme.Resolved
    let dark: Bool
    /// 主题列表里的小样：不画顶栏与输入栏
    var compact = false

    var body: some View {
        let f = theme.face(dark: dark)
        ThemePreviewPage(face: f, structUse: theme.structUse, compact: compact)
            .environment(\.phSkin, f.css)
            .environment(\.phRaster, nil)
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}

private struct ThemePreviewPage: View {
    let face: ChatTheme.Face
    let structUse: Set<String>
    let compact: Bool
    @Environment(\.phSkin) private var css

    var body: some View {
        VStack(spacing: 0) {
            if !compact { nav }
            VStack(alignment: .leading, spacing: 0) {
                timeSep("昨天 21:30")
                turn(false, ["今天的工作结束了吗？"], meta: false)
                turn(true, ["刚刚结束。", "正在回家的路上。"], meta: !compact)
                if !compact { status }
            }
            .padding(.horizontal, Theme.pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .modifier(PhBodyBackground(style: face.look.bg.isEmpty ? css?.resolve(["chat-body"]) : nil))
            .clipped()
            if !compact { composer }
        }
        .background { ChatBackdrop(look: face.look) }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var nav: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.left").font(.system(size: 17, weight: .medium)).frame(width: 36, alignment: .leading)
            Spacer()
            if let st = css?.resolve(["nav-title"]) {
                Text("示例角色").font(CssFonts.font(st, size: 16, weight: .semibold))
            } else {
                Text("示例角色").font(.system(size: 16, weight: .semibold))
            }
            Spacer()
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .medium)).frame(width: 36, alignment: .trailing)
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, Theme.sp3)
        .frame(height: 44)
        .background(face.look.top.isSet ? ChatLook.fill(face.look.top) : AnyShapeStyle(Color.clear))
        .modifier(ForcedScheme(scheme: ChatLook.scheme(face.look.top)))
    }

    @ViewBuilder private func timeSep(_ t: String) -> some View {
        Group {
            if let css, let st = css.resolve(["time-sep"]) {
                Text(t).font(CssFonts.font(st, size: 12))
                    .modifier(PhBox(style: st, fallback: PhFallback(fg: Theme.text3, fontSize: 12)))
            } else {
                Text(t).font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.sp3)
    }

    private func turn(_ mine: Bool, _ texts: [String], meta: Bool) -> some View {
        let skin = face.skin
        return HStack(alignment: .top, spacing: Theme.gap) {
            if mine { Spacer(minLength: 40) }
            if !mine && skin.showFace(false) { avatar(false) }
            VStack(alignment: mine ? .trailing : .leading, spacing: skin.gapIn) {
                ForEach(Array(texts.enumerated()), id: \.offset) { i, t in bubble(t, mine: mine, at: i, of: texts.count) }
                if meta { metaLine }
            }
            if mine && skin.showFace(true) { avatar(true) }
            if !mine { Spacer(minLength: 40) }
        }
        .padding(.top, skin.gap)
    }

    private func avatar(_ mine: Bool) -> some View {
        Avatar(imageId: "", name: mine ? "我" : "示例角色", size: face.skin.avatarSize, radius: face.skin.radius(face.skin.avatarSize))
    }

    /// 与会话页的气泡同一个画法（ConversationView 的 bubble）
    @ViewBuilder private func bubble(_ text: String, mine: Bool, at i: Int, of n: Int) -> some View {
        let b = face.skin.bubble(mine)
        let hooks = CssStructural.hooks(["bubble", mine ? "bubble-mine" : "bubble-theirs"],
                                        CssStructural.bubble(CssStructCtx(), at: i, of: n, used: structUse))
        if let css, let raw = css.resolve(hooks) {
            let st = b.overriding(raw)
            let size = CGFloat(st.fontSize ?? Double(b.font))
            Text(text)
                .font(CssFonts.font(st, size: size))
                .lineSpacing(CssPaint.lineSpacing(st, fontSize: size) ?? size * 0.4)
                .modifier(PhBox(style: st, fallback: PhFallback(
                    fill: b.fill ?? (mine ? Theme.bubbleMine : Theme.bubbleTheirs), radius: b.radius, continuous: true,
                    padH: b.padX, padV: b.padY, fg: b.text ?? (mine ? Theme.bubbleMineText : Theme.bubbleTheirsText),
                    shadow: mine ? nil : PhShadow(color: .black.opacity(0.06), radius: 1, y: 1), fontSize: size),
                    hooks: hooks, rasterBox: false))
        } else {
            Text(text)
                .font(.system(size: b.font))
                .lineSpacing(b.font * 0.4)
                .padding(.horizontal, b.padX).padding(.vertical, b.padY)
                .foregroundStyle(b.text ?? (mine ? Theme.bubbleMineText : Theme.bubbleTheirsText))
                .background(b.fill ?? (mine ? Theme.bubbleMine : Theme.bubbleTheirs), in: RoundedRectangle(cornerRadius: b.radius, style: .continuous))
                .shadow(color: .black.opacity(mine ? 0 : 0.06), radius: 1, y: 1)
        }
    }

    @ViewBuilder private var metaLine: some View {
        if let css, css.has(["meta"]) || css.has(["stamp"]) || css.has(["read"]) {
            HStack(spacing: 4) {
                Text("21:36").phStyle("stamp", fallback: PhFallback(fontSize: 11))
                Text("已读").phStyle("read", fallback: PhFallback(fontSize: 11))
            }
            .font(.system(size: 11)).foregroundStyle(Theme.text3)
        } else {
            HStack(spacing: 4) { Text("21:36"); Text("已读") }
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("状态栏").font(.system(size: 12, weight: .semibold))
            HStack(spacing: Theme.sp2) {
                Text("心情").font(.system(size: 11)).foregroundStyle(Theme.text3)
                Text("平静").font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PhSurface(hooks: ["status"], fallback: PhFallback(fill: Theme.groupFill, radius: Theme.rMd,
                                                                 padH: Theme.sp3, padV: Theme.sp2, alignment: .leading)))
        .padding(.top, Theme.sp3)
    }

    private var composer: some View {
        HStack(spacing: Theme.sp2) {
            Image(systemName: "plus").font(.system(size: 18)).foregroundStyle(Theme.text2).frame(width: 32, height: 32)
            Group {
                if let css, css.has(["composer-input"]), let st = css.resolve(["composer-input"]) {
                    Text("Aa…").font(CssFonts.font(st, size: 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(PhBox(style: st, fallback: PhFallback(fill: Theme.surface2, radius: Theme.rLg, continuous: true,
                                                                         padH: Theme.sp3, padV: Theme.sp2, fg: Theme.text3, stroke: Theme.border,
                                                                         minHeight: Theme.composerH, alignment: .leading, fontSize: 15)))
                } else {
                    Text("Aa…").font(.system(size: 15)).foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity, minHeight: Theme.composerH, alignment: .leading)
                        .padding(.horizontal, Theme.sp3)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                }
            }
            Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.onAccent)
                .frame(width: 32, height: 32).background(Circle().fill(Theme.accent))
        }
        .padding(.horizontal, Theme.sp3).padding(.vertical, Theme.sp2)
        .modifier(BottomBarLook(bar: face.look.bottom))
    }
}
