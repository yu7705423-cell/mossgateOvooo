import SwiftUI

/// 美化编辑器（网页版 apps/skin/EditPage.js，ARCHITECTURE 4.836 起）。旋钮的定义与编成 CSS 都是网页版 skin-gen.js 原样跑的（SkinGen），
/// 编出来的 CSS 交给 CssSkin.compile，预览与会话页同一条路（ThemePreview ← ChatTheme.resolve ← Skins.effectiveCss）。
///
/// 改的都是这一页手里的一份草稿：拖滑杆时不写库，预览稍候换一次样式，停手 0.7 秒才存进库；离开这一页时没存的立刻存上。
/// 顶上撤销与重做（0.8 秒内的连续改动算一次）；每次打开时留一份打开前的样子（最近 5 份），「旧版本」里退得回去。
/// 每一块可以恢复默认；按住预览左上角看打开时的样子；顶上搜设置项的名字，直接跳到那一项。
/// 预览可以双指放大、拖动查看；放大之后左缘右滑一律不离开这一页（网页版 4.1024，用户定的）。
struct SkinEditorView: View {
    let id: String

    @State private var draft: JSONValue = .object([:])
    @State private var loaded = false
    @State private var state: SkinGen.State?
    @State private var theme = ChatTheme.Resolved()
    @State private var openTheme = ChatTheme.Resolved()
    @State private var holding = false
    @State private var open = "nav"
    @State private var more = false
    @State private var undo: [JSONValue] = []
    @State private var redo: [JSONValue] = []
    @State private var lastAt = Date.distantPast
    @State private var saveTask: Task<Void, Never>?
    @State private var paintTask: Task<Void, Never>?
    @State private var finding = false
    @State private var query = ""
    @State private var showVersions = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var zoom: CGFloat = 1
    @State private var pinchFrom: CGFloat?
    @State private var pan: CGSize = .zero
    @State private var panFrom: CGSize?
    @State private var seek: String?
    @Environment(\.colorScheme) private var env

    static let saveDelay: UInt64 = 700_000_000
    static let mergeWindow: TimeInterval = 0.8
    static let shown = 6
    static let keep = 5
    static let zoomMax: CGFloat = 5

    private var groups: [SkinGen.Group] { SkinGen.shared.groups() ?? [] }
    private var row: Row? { Skins.get(id) }

    var body: some View {
        Group {
            if SkinGen.shared.groups() == nil {
                missing
            } else if row == nil {
                EmptyState(title: "该美化已删除")
            } else {
                editor
            }
        }
        .navigationTitle(row.map { $0.string("name").isEmpty ? "未命名" : $0.string("name") } ?? "编辑")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: start)
        .onDisappear(perform: flushNow)
    }

    // MARK: - 包不在

    private var missing: some View {
        Form {
            Section {
                Text("这个版本没有带上美化编辑器。可以调整尺寸、气泡颜色与头像大小；编辑器里的其余设置照常保存，网页版照常使用。")
                    .foregroundStyle(Theme.text2)
                NavigationLink { SkinEditView(id: id) } label: { Text("尺寸与颜色") }
            } footer: {
                HelpNote("美化编辑器的设置清单与编成 CSS 的部分使用网页版自己的代码，在编译时打包进应用。没有打包进来时，编辑器只提供原生版自己读取的几项。", title: "美化编辑器：没有打包时")
            }
        }
    }

    // MARK: - 编辑器

    private var editor: some View {
        VStack(spacing: 0) {
            stage
                .frame(height: open.isEmpty ? 460 : 300)
                .clipped()
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            rail
            if let g = groups.first(where: { $0.id == open }) {
                panel(g)
            } else {
                Spacer(minLength: 0)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { finding = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索设置项")
                Button { step(back: true) } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(undo.isEmpty).accessibilityLabel("撤销")
                Button { step(back: false) } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(redo.isEmpty).accessibilityLabel("重做")
                Button { showVersions = true } label: { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("旧版本")
            }
        }
        .sheet(isPresented: $finding) { NavigationStack { searchPage } }
        .sheet(isPresented: $showVersions) { NavigationStack { versionsPage } }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        }
    }

    /// 预览。双指放大、放大后单指拖动、双击放大或还原；按住左上角看打开时的样子
    private var stage: some View {
        GeometryReader { geo in
            let shown = holding ? openTheme : theme
            let dark = shown.scheme == "dark" ? true : shown.scheme == "light" ? false : env == .dark
            ThemePreview(theme: shown, dark: dark)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(pan)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(MagnificationGesture()
                    .onChanged { v in
                        let from = pinchFrom ?? zoom
                        pinchFrom = from
                        setZoom(from * v, in: geo.size)
                    }
                    .onEnded { _ in pinchFrom = nil })
                .simultaneousGesture(DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        guard zoom > 1.01 else { return }
                        let from = panFrom ?? pan
                        panFrom = from
                        pan = clampPan(CGSize(width: from.width + v.translation.width, height: from.height + v.translation.height), in: geo.size)
                    }
                    .onEnded { _ in panFrom = nil })
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if zoom > 1.05 { zoom = 1; pan = .zero } else { setZoom(2.5, in: geo.size) }
                    }
                }
                .overlay(alignment: .topLeading) { compareButton }
                .overlay(alignment: .bottomTrailing) { zoomBar(geo.size) }
        }
        // 放大之后：左缘右滑不离开这一页
        .background(RefuseEdgeBack(active: zoom > 1.01))
        .background(Theme.surface2)
    }

    private var compareButton: some View {
        Text("按住对比")
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, Theme.sp2).padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .padding(Theme.sp2)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !holding { holding = true } }
                .onEnded { _ in holding = false })
            .accessibilityLabel("按住查看打开编辑器时的样子")
    }

    private func zoomBar(_ size: CGSize) -> some View {
        HStack(spacing: Theme.sp2) {
            Button { setZoom(zoom / 1.5, in: size) } label: { Image(systemName: "minus") }.disabled(zoom <= 1.01).accessibilityLabel("缩小")
            if zoom > 1.01 {
                Button { withAnimation(.easeOut(duration: 0.2)) { zoom = 1; pan = .zero } } label: {
                    Text(String(format: "%.1f×", zoom)).font(.system(size: 12).monospacedDigit())
                }
                .accessibilityLabel("还原")
            }
            Button { setZoom(zoom * 1.5, in: size) } label: { Image(systemName: "plus") }.disabled(zoom >= Self.zoomMax).accessibilityLabel("放大")
        }
        .font(.system(size: 14, weight: .medium))
        .buttonStyle(.borderless)
        .padding(.horizontal, Theme.sp3).padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .padding(Theme.sp2)
    }

    private func setZoom(_ z: CGFloat, in size: CGSize) {
        zoom = min(Self.zoomMax, max(1, z))
        if zoom <= 1.01 { pan = .zero } else { pan = clampPan(pan, in: size) }
    }

    /// 不许拖出边：放大之后四边都还盖得住这一块
    private func clampPan(_ p: CGSize, in size: CGSize) -> CGSize {
        CGSize(width: min(0, max(size.width * (1 - zoom), p.width)), height: min(0, max(size.height * (1 - zoom), p.height)))
    }

    private var rail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.sp1) {
                    ForEach(groups) { g in
                        Button { open = open == g.id ? "" : g.id; more = false } label: {
                            VStack(spacing: 2) {
                                Text(g.short).font(.system(size: 13, weight: open == g.id ? .semibold : .regular))
                                Circle().fill((state?.changed[g.id] ?? 0) > 0 ? Theme.text : Color.clear).frame(width: 4, height: 4)
                            }
                            .foregroundStyle(open == g.id ? Theme.text : Theme.text2)
                            .padding(.horizontal, Theme.sp3).padding(.vertical, 6)
                            .background(open == g.id ? Theme.surface2 : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(g.id)
                    }
                }
                .padding(.horizontal, Theme.sp3).padding(.vertical, Theme.sp2)
            }
            .mask(HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
            })
            .onChange(of: open) { _, v in if !v.isEmpty { withAnimation { proxy.scrollTo(v, anchor: .center) } } }
        }
    }

    @ViewBuilder private func panel(_ g: SkinGen.Group) -> some View {
        let vals = state?.values[g.id] ?? [:]
        let vis = g.items.filter { state?.shows(g.id, $0.id) ?? !$0.cond }
        let main = Array(vis.filter { !$0.more }.prefix(Self.shown))
        let rest = vis.filter { it in !main.contains(where: { $0.id == it.id }) }
        ScrollViewReader { proxy in
            Form {
                if let problem { Text(problem).foregroundStyle(Theme.danger) }
                Section {
                    ForEach(main, id: \.id) { it in control(g, it, vals).id(it.id) }
                    if !rest.isEmpty {
                        Button(more ? "收起更多" : "更多（\(rest.count)）") { more.toggle() }.foregroundStyle(Theme.text2)
                        if more { ForEach(rest, id: \.id) { it in control(g, it, vals).id(it.id) } }
                    }
                } header: {
                    HStack {
                        GroupTitle(g.label)
                        Spacer()
                        if (state?.changed[g.id] ?? 0) > 0 {
                            Button("恢复默认") { reset(g.id) }.font(.system(size: 12)).buttonStyle(.borderless)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !g.desc.isEmpty { Text(g.desc) }
                        if !(row?.string("css") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("这份美化有手写 CSS。两边改了同一处时，以最后改动的一边为准：在这里改过之后以编辑器为准，再改手写 CSS 之后以手写 CSS 为准。")
                        }
                    }
                }
                let clash = (state?.conflicts ?? []).filter { !$0.who.isEmpty }
                if !clash.isEmpty {
                    Section {
                        ForEach(Array(clash.enumerated()), id: \.offset) { _, c in
                            Text("「\(c.who.joined(separator: "」「"))」挂在同一个位置（\(c.at.replacingOccurrences(of: "::", with: " 的 ")) ），只有一样生效。")
                                .font(.footnote).foregroundStyle(Theme.danger)
                        }
                    }
                }
                Section { EmptyView() } footer: {
                    HelpNote("数字框可以填写超出滑杆范围的值。按住预览左上角的「按住对比」查看打开编辑器时的样式；双指或双击放大预览，放大后左缘右滑不离开这一页。多色渐变与叠加在网页版中编辑。", title: "美化编辑器")
                }
            }
            .onChange(of: seek) { _, s in
                guard let s else { return }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(s, anchor: .center) }; seek = nil }
            }
        }
    }

    private func control(_ g: SkinGen.Group, _ it: SkinGen.Item, _ vals: [String: JSONValue]) -> some View {
        SkinControl(item: it, value: vals[it.id] ?? it.def, paintSummary: state?.paints["\(g.id).\(it.id)"] ?? "") { v in
            set(g.id, it.id, v)
        }
    }

    // MARK: - 搜索与旧版本

    private var searchPage: some View {
        let t = query.trimmingCharacters(in: .whitespaces).lowercased()
        let found: [Found] = t.isEmpty ? [] : groups.flatMap { g in
            g.items.filter { "\($0.label) \($0.desc) \(g.label)".lowercased().contains(t) }.map { Found(g: g, it: $0) }
        }
        return Form {
            Section { TextField("例如：圆角、投影、字体", text: $query) }
            if t.isEmpty {
                Text("输入设置项的名称，选中后跳转至该项。").foregroundStyle(Theme.text3)
            } else if found.isEmpty {
                Text("没有找到。换一个词再试。").foregroundStyle(Theme.text3)
            } else {
                Section {
                    ForEach(found) { f in
                        let g = f.g, it = f.it
                        Button { jump(g, it) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.label).foregroundStyle(Theme.text)
                                Text((state?.shows(g.id, it.id) ?? true) ? g.label : "\(g.label)（设置前面的项之后出现）")
                                    .font(.caption).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("搜索设置项")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { finding = false; query = "" } } }
    }

    private var versionsPage: some View {
        let list = row?["versions"]?.array ?? []
        return Form {
            if list.isEmpty {
                Text("暂无旧版本。打开编辑器时自动保存一份打开前的样式。").foregroundStyle(Theme.text3)
            } else {
                Section {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, v in
                        Button { restore(v) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.when(v["at"]?.number ?? 0)).foregroundStyle(Theme.text)
                                let n = SkinGen.shared.state(v["gen"])?.changed.values.filter { $0 > 0 }.count ?? 0
                                Text("改过 \(n) 块").font(.caption).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                } footer: {
                    Text("每次打开编辑器时保存一份打开前的样式，最多保存 \(Self.keep) 份。退回时当前的样子先留作一份旧版本。")
                }
            }
        }
        .navigationTitle("旧版本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showVersions = false } } }
    }

    struct Found: Identifiable {
        let g: SkinGen.Group
        let it: SkinGen.Item
        var id: String { "\(g.id).\(it.id)" }
    }

    static func when(_ ms: Double) -> String {
        let d = Date(millis: ms)
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: d)
        return String(format: "%d月%d日 %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: - 草稿

    private func start() {
        guard !loaded, let r = row, SkinGen.shared.groups() != nil else { return }
        loaded = true
        let gen = r["gen"]?.object != nil ? r["gen"]! : JSONValue.object([:])
        draft = gen
        // 打开时留一份打开前的样子。和最近那一份一样就不再留
        let list = r["versions"]?.array ?? []
        if !(gen.object ?? [:]).isEmpty, list.first?["gen"] != gen {
            run {
                try Skins.update(id) { row in
                    row["versions"] = .array(Array(([JSONValue.object(["at": .number(Date().millis), "gen": gen])] + list).prefix(Self.keep)))
                }
            }
        }
        state = SkinGen.shared.state(draft)
        theme = Self.resolve(r, draft)
        openTheme = theme
    }

    /// 草稿下的样子：按存下去之后的 late 算（网页版 draftOf）
    static func resolve(_ r: Row, _ gen: JSONValue) -> ChatTheme.Resolved {
        var copy = r
        let changed = (r["gen"] ?? .object([:])) != gen
        if changed && !r.string("css").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { copy["late"] = .bool(true) }
        copy["gen"] = gen
        return ChatTheme.resolve(row: copy)
    }

    private func apply(_ next: JSONValue, record: Bool = true) {
        guard next != draft else { return }
        let now = Date()
        if record && now.timeIntervalSince(lastAt) > Self.mergeWindow { undo.append(draft); redo = [] }
        lastAt = now
        draft = next
        state = SkinGen.shared.state(next)
        // 预览稍候换一次，不跟着每一格滑杆重读
        paintTask?.cancel()
        paintTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled, let r = row else { return }
            theme = Self.resolve(r, next)
        }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.saveDelay)
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func set(_ group: String, _ item: String, _ v: JSONValue) {
        var g = draft.object ?? [:]
        var grp = state?.values[group] ?? (g[group]?.object ?? [:])
        grp[item] = v
        g[group] = .object(grp)
        apply(.object(g))
    }

    private func reset(_ group: String) {
        var g = draft.object ?? [:]
        g.removeValue(forKey: group)
        lastAt = .distantPast
        apply(.object(g))
        notice = "这一块已恢复默认，可以撤销。"
    }

    private func step(back: Bool) {
        if back {
            guard let prev = undo.popLast() else { return }
            redo.append(draft)
            lastAt = .distantPast
            apply(prev, record: false)
        } else {
            guard let next = redo.popLast() else { return }
            undo.append(draft)
            lastAt = .distantPast
            apply(next, record: false)
        }
    }

    private func restore(_ v: JSONValue) {
        let list = row?["versions"]?.array ?? []
        let cur = draft
        run {
            try Skins.update(id) { r in
                r["versions"] = .array(Array(([JSONValue.object(["at": .number(Date().millis), "gen": cur])] + list.filter { $0 != v }).prefix(Self.keep)))
            }
        }
        lastAt = .distantPast
        apply(v["gen"] ?? .object([:]))
        showVersions = false
        notice = "已退回。"
    }

    private func jump(_ g: SkinGen.Group, _ it: SkinGen.Item) {
        let vis = g.items.filter { state?.shows(g.id, $0.id) ?? true }
        let first = vis.filter { !$0.more }.prefix(Self.shown)
        more = vis.contains(where: { $0.id == it.id }) && !first.contains(where: { $0.id == it.id })
        open = g.id
        finding = false
        query = ""
        seek = it.id
    }

    private func flush() {
        saveTask = nil
        guard let cur = Skins.get(id), (cur["gen"] ?? .object([:])) != draft else { return }
        let next = draft
        run {
            try Skins.update(id) { r in
                r["gen"] = next
                Skins.markLate(&r)
            }
        }
    }

    private func flushNow() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        flush()
    }

    private func run(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "无法保存美化：\(error.localizedDescription)" }
    }
}
