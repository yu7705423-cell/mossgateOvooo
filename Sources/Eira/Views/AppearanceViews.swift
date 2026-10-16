import SwiftUI
import UniformTypeIdentifiers

/// 「设置 - 主题」里的几组（网页版 AppearancePage 的配色、字号、图标、底栏与外观预设）。
/// 这些字段与网页版同名，导入的设置原样认得。

/// 配色：内置几套，或自定义主色、底色、文字色，深浅各一组
struct PaletteSection: View {
    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.colorScheme) private var scheme
    @State private var mode = "light"

    private var cur: [String: JSONValue] { model.s.raw["palette"]?.object ?? ["id": .string("mono")] }
    private var curId: String { cur["id"]?.string ?? "mono" }

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Palette.presets) { p in
                        swatch(p.light == nil ? Palette.monoShow.light : p.light!, p.light == nil ? Palette.monoShow.dark : p.dark!,
                               label: p.label, on: curId == p.id) { pick(p.id) }
                    }
                    let b = Palette.base(model.s.raw["palette"])
                    swatch(b.light ?? Palette.presets[1].light!, b.dark ?? Palette.presets[1].dark!, label: "自定义", on: curId == "custom") { pick("custom") }
                }
                .padding(.vertical, 6)
            }
            if curId == "custom" {
                Picker("改哪一组", selection: $mode) {
                    Text("浅色模式的颜色").tag("light")
                    Text("深色模式的颜色").tag("dark")
                }
                .pickerStyle(.segmented)
                colorRow("主色", "accent")
                colorRow("底色", "bg")
                colorRow("文字色", "text")
            }
        } header: {
            Text("配色")
        } footer: {
            HelpNote("深色模式与浅色模式各有一组颜色，切换深色模式时跟着换。自定义只挑三个颜色：主色用于主要按钮、开关、选中与自己的气泡；底色是页面的底；文字色是正文。卡片、分隔线、次要文字由底色与文字色按比例算出。主屏立即换上，已打开的应用在下次打开时换上。", title: "配色")
        }
        .onAppear { mode = scheme == .dark ? "dark" : "light" }
    }

    private func swatch(_ light: Palette.Base, _ dark: Palette.Base, label: String, on: Bool, tap: @escaping () -> Void) -> some View {
        let b = scheme == .dark ? dark : light
        return Button(action: tap) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: b.bg) ?? .white)
                    VStack(alignment: .leading, spacing: 4) {
                        Circle().fill(Color(hex: b.accent) ?? .black).frame(width: 12, height: 12)
                        Capsule().fill(Color(hex: b.text) ?? .black).frame(width: 26, height: 3)
                    }
                    .padding(8)
                }
                .frame(width: 52, height: 52)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Theme.text : Theme.border2, lineWidth: on ? 2 : 1))
                Text(label).font(.caption).foregroundStyle(on ? Theme.text : Theme.text2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func pick(_ id: String) {
        var next = cur
        if id == "custom" && next["custom"] == nil {
            // 第一次点自定义：从当前那一套起步
            let b = Palette.base(.object(["id": .string(curId == "mono" ? "mist" : curId)]))
            func obj(_ x: Palette.Base?) -> JSONValue {
                guard let x else { return .object([:]) }
                return .object(["accent": .string(x.accent), "bg": .string(x.bg), "text": .string(x.text)])
            }
            next["custom"] = .object(["light": obj(b.light), "dark": obj(b.dark)])
        }
        next["id"] = .string(id)
        model.set("palette", .object(next))
    }

    private func colorRow(_ title: String, _ key: String) -> some View {
        let b = Palette.base(model.s.raw["palette"])
        let base = (mode == "dark" ? b.dark : b.light) ?? Palette.presets[1].light!
        let value = key == "accent" ? base.accent : key == "bg" ? base.bg : base.text
        return ColorPicker(selection: Binding(get: { Color(hex: value) ?? .black }, set: { c in
            var next = cur
            var custom = next["custom"]?.object ?? [:]
            var group = custom[mode]?.object ?? ["accent": .string(base.accent), "bg": .string(base.bg), "text": .string(base.text)]
            group[key] = .string(c.hexString)
            custom[mode] = .object(group)
            next["custom"] = .object(custom)
            next["id"] = .string("custom")
            model.set("palette", .object(next))
        }), supportsOpacity: false) {
            HStack {
                Text(title)
                Spacer()
                Text(value).font(.footnote.monospaced()).foregroundStyle(Theme.text2)
            }
        }
    }
}

/// 字号（网页版 fontScale，80% 到 140%）
struct FontScaleSection: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var value: Double = 1

    var body: some View {
        Section {
            HStack {
                Text("字号")
                Spacer()
                Text("\(Int((value * 100).rounded()))%").foregroundStyle(Theme.text2).monospacedDigit()
            }
            Slider(value: $value, in: 0.8...1.4, step: 0.05) { editing in
                if !editing { model.set("fontScale", .number(value)) }
            }
            if abs(value - 1) > 0.001 {
                Button("恢复默认字号") { value = 1; model.set("fontScale", .number(1)) }
            }
        } header: {
            Text("字号")
        } footer: {
            HelpNote("整体放大或缩小界面文字。松手后主屏立即换上，已打开的应用在下次打开时换上。", title: "字号")
        }
        .onAppear { value = Palette.fontScale }
    }
}

/// 图标：阴影、名称、列数、大小、颜色、名称颜色、底板
struct IconLookSection: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var scale: Double = 1

    private var raw: [String: JSONValue] { model.s.raw }

    var body: some View {
        Section {
            Toggle("图标阴影", isOn: model.bool("iconShadow", true))
            Picker("图标名称", selection: Binding(get: { Shell.labelMode(raw) }, set: { model.set("iconLabelMode", .string($0)) })) {
                Text("都显示").tag("all")
                Text("底栏不显示").tag("nodock")
                Text("都不显示").tag("none")
            }
            Picker("主屏列数", selection: Binding(get: { Shell.cols(raw) }, set: { model.set("homeCols", .number(Double($0))) })) {
                Text("4").tag(4); Text("5").tag(5); Text("6").tag(6)
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading) {
                HStack {
                    Text("图标大小")
                    Spacer()
                    Text("\(Int((scale * 100).rounded()))%").foregroundStyle(Theme.text2).monospacedDigit()
                }
                Slider(value: $scale, in: 0.7...1.2, step: 0.05) { editing in
                    if !editing { model.set("iconScale", .number(scale)) }
                }
            }
            ColorPicker("图标颜色", selection: hexBinding("iconColor", def: "#000000"), supportsOpacity: false)
            HStack {
                ColorPicker("名称颜色", selection: hexBinding("iconLabelColor", def: "#8A8A8A"), supportsOpacity: false)
                if !(raw["iconLabelColor"]?.string ?? "").isEmpty {
                    Button("自动") { model.set("iconLabelColor", .string("")) }.buttonStyle(.borderless)
                }
            }
            PlateRows(title: "图标底板", key: "tilePlate")
        } header: {
            Text("图标")
        } footer: {
            HelpNote("图标名称：主界面与底栏是否显示应用名称，单个图标可在整理主屏幕时另设。主屏列数：一行放几个图标，列数越多图标越小。名称颜色与图标底板选「自动」时随壁纸与深浅色变化。", title: "图标")
        }
        .onAppear {
            let n = raw["iconScale"]?.number ?? 1
            scale = n > 0 ? max(0.7, min(1.2, n)) : 1
        }
    }

    private func hexBinding(_ key: String, def: String) -> Binding<Color> {
        Binding(get: { Color(hex: model.s.raw[key]?.string ?? def) ?? .black },
                set: { model.set(key, .string($0.hexString)) })
    }

}

/// 一种底板颜色（{color, alpha}）：取色、透明度、恢复自动
struct PlateRows: View {
    let title: String
    let key: String
    @ObservedObject private var model = SettingsModel.shared
    @State private var alpha: Double = 60
    @State private var loaded = false

    var body: some View {
        let cur = model.s.raw[key]?.object
        HStack {
            ColorPicker(title, selection: Binding(get: { Color(hex: cur?["color"]?.string ?? "#FFFFFF") ?? .white }, set: { c in
                model.set(key, .object(["color": .string(c.hexString), "alpha": .number(alpha)]))
            }), supportsOpacity: false)
            if cur != nil {
                Button("自动") { model.set(key, .null) }.buttonStyle(.borderless)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            alpha = cur?["alpha"]?.number ?? 60
        }
        if let color = cur?["color"]?.string {
            VStack(alignment: .leading) {
                HStack {
                    Text("\(title)不透明度")
                    Spacer()
                    Text("\(Int(alpha))%").foregroundStyle(Theme.text2).monospacedDigit()
                }
                Slider(value: $alpha, in: 0...100, step: 5) { editing in
                    if !editing { model.set(key, .object(["color": .string(color), "alpha": .number(alpha)])) }
                }
            }
        }
    }
}

/// 底栏：显示与否、颜色
struct DockLookSection: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var hidden = false
    @State private var problem: String?
    @State private var loaded = false

    var body: some View {
        Section {
            Toggle("显示底栏", isOn: Binding(get: { !hidden }, set: { setShown($0) }))
            if !hidden {
                PlateRows(title: "底栏颜色", key: "dockColor")
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("底栏")
        } footer: {
            HelpNote("关闭底栏后，原先在底栏的应用放入主屏的空位；重新打开时收回底栏。底栏颜色选「自动」时跟随图标底板。", title: "底栏")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            hidden = Shell.layout().dockHidden
        }
    }

    private func setShown(_ on: Bool) {
        do {
            var h = try HomeLayout.begin(settings: model.s.raw)
            h.setDockHidden(!on)
            try h.save()
            hidden = !on
            problem = nil
        } catch {
            problem = "未能保存：\(error.localizedDescription)"
        }
    }
}

/// 外观预设：整套装修拍个快照，随时切回去
struct LookPresetsSection: View {
    @State private var items: [Looks.Item] = []
    @State private var problem: String?
    @State private var naming = false
    @State private var nameText = ""
    @State private var renaming: Looks.Item?
    @State private var applying: Looks.Item?
    @State private var overwriting: Looks.Item?
    @State private var deleting: Looks.Item?
    @State private var done: String?

    var body: some View {
        Section {
            ForEach(items) { it in
                HStack(spacing: Theme.gap) {
                    Group {
                        if it.wallpaper.isEmpty {
                            RoundedRectangle(cornerRadius: 8).fill(Theme.catBg)
                        } else {
                            LocalImage(id: it.wallpaper, maxPixel: 120)
                        }
                    }
                    .frame(width: 34, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.name).lineLimit(1)
                        Text(Date(millis: it.updated), format: .dateTime.month().day()).font(.caption).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    Menu {
                        Button("换成这一套") { applying = it }
                        Button("以当前外观覆盖") { overwriting = it }
                        Button("重命名") { nameText = it.name; renaming = it }
                        Button("删除", role: .destructive) { deleting = it }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("更多")
                }
            }
            Button("将当前外观存为预设") { nameText = "装修 \(items.count + 1)"; naming = true }
            if let done { Text(done).font(.footnote).foregroundStyle(Theme.text2) }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("外观预设")
        } footer: {
            HelpNote("存下壁纸、图标、图标位置、小组件、配色、字号与主题参数，不包括角色、聊天记录与接口。换成一套时，这些全部被替换。", title: "外观预设")
        }
        .onAppear(perform: load)
        .alert("存为预设", isPresented: $naming) {
            TextField("名称", text: $nameText)
            Button("取消", role: .cancel) {}
            Button("保存") { run("已保存") { try Looks.save(name: nameText) } }
        }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $nameText)
            Button("取消", role: .cancel) {}
            Button("保存") { if let it = renaming { run(nil) { try Looks.rename(it.id, nameText) } } }
        }
        .confirmationDialog("壁纸、图标、图标位置、小组件与主题参数将全部被替换。当前外观若未存为预设将无法恢复。",
                            isPresented: Binding(get: { applying != nil }, set: { if !$0 { applying = nil } }), titleVisibility: .visible) {
            Button("换成「\(applying?.name ?? "")」") {
                guard let it = applying else { return }
                do {
                    let missing = try Looks.apply(it.id) { MediaStore.url(.images, id: $0) != nil }
                    SettingsModel.shared.reload()
                    done = missing > 0 ? "已换上，其中 \(missing) 张图片已不存在。" : "已换上。"
                    problem = nil
                } catch { problem = "未能换上：\(error.localizedDescription)" }
            }
        }
        .confirmationDialog("以当前外观覆盖该预设，原有内容将被替换。", isPresented: Binding(get: { overwriting != nil }, set: { if !$0 { overwriting = nil } }),
                            titleVisibility: .visible) {
            Button("覆盖") { if let it = overwriting { run("已覆盖") { try Looks.overwrite(it.id) } } }
        }
        .confirmationDialog("删除后无法恢复。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let it = deleting { run(nil) { try Looks.remove(it.id) } } }
        }
    }

    private func load() {
        do { items = try Looks.all() } catch { problem = "读取失败：\(error.localizedDescription)" }
    }

    private func run(_ message: String?, _ f: () throws -> Void) {
        do { try f(); problem = nil; done = message; load() }
        catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}

/// 锁屏：开关与锁屏壁纸
struct LockLookSection: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var lockOff = false

    /// 设了密码就算开着
    private var on: Bool { model.s.raw["showLockScreen"]?.bool != false || PinLock.hasPin(model.s) }

    var body: some View {
        Section {
            Toggle("锁屏", isOn: Binding(get: { on }, set: { v in
                if v { model.set("showLockScreen", .bool(true)) }
                else if PinLock.hasPin(model.s) { lockOff = true }
                else { model.set("showLockScreen", .bool(false)) }
            }))
            if on {
                WallpaperSection(slot: "lock", label: "锁屏壁纸", desc: "位于时钟与通知下层", bare: true)
                NavigationLink {
                    LockPinView()
                } label: {
                    HStack {
                        Text("锁屏密码")
                        Spacer()
                        Text(PinLock.hasPin(model.s) ? "\(PinLock.length(model.s)) 位" : "未设置").foregroundStyle(Theme.text2)
                    }
                }
            }
        } header: {
            Text("锁屏")
        } footer: {
            HelpNote("开启时，打开应用先显示锁屏：时间、日期与有未读消息的会话，上滑进入主界面，点一条会话直接进入。关闭时直接进入主界面。锁屏密码：设置后每次打开应用时需要输入，切到后台再回来不需要；关闭锁屏时先核对密码，密码一并清除。", title: "锁屏")
        }
        .sheet(isPresented: $lockOff) {
            NavigationStack { LockPinView(lockOff: true) }
        }
    }
}

/// 字体：正文与标题宋体各选一款，字体从本机文件或字体文件的网址添加（网页版 FontPicker）
struct FontSection: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var importing = false
    @State private var linking = false
    @State private var link = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var deleting: Fonts.Rec?

    private var fonts: [Fonts.Rec] { Fonts.list(model.s) }

    var body: some View {
        Section {
            slot("正文", key: "fontBody")
            slot("标题宋体", key: "fontSerif")
            ForEach(fonts) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(Fonts.psName(f).map { Font.custom($0, size: 16) } ?? .body)
                        Text(status(f)).font(.caption).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    if f.fileId.isEmpty && !f.url.isEmpty {
                        Button("存到本机") { Task { await keep(f) } }.buttonStyle(.borderless).disabled(busy)
                    }
                }
                .swipeActions { Button("删除", role: .destructive) { deleting = f } }
            }
            Button(busy ? "正在添加" : "从文件添加") { importing = true }.disabled(busy)
            Button("按网址添加") { link = ""; linking = true }.disabled(busy)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("字体")
        } footer: {
            HelpNote("正文与标题宋体可以各换一款。字体从本机的 ttf 或 otf 文件添加，或填写字体文件的网址下载一份到本机；样式表网址（例如 Google Fonts 的链接）原生版读不了。主屏立即换上，已打开的应用在下次打开时换上。左滑删除。", title: "字体")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.font], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try Fonts.add(data, name: url.lastPathComponent)
                model.reload()
                problem = nil
            } catch { problem = error.localizedDescription }
        }
        .alert("字体文件的网址", isPresented: $linking) {
            TextField("https://…/font.ttf", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("添加") { Task { await addLink() } }
        }
        .confirmationDialog("删除这款字体。正在使用它的地方回到默认字体。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let f = deleting else { return }
                do { try Fonts.remove(f.id); model.reload() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
        }
    }

    private func slot(_ title: String, key: String) -> some View {
        Picker(title, selection: Binding(get: { model.s.raw[key]?.string ?? "" }, set: { model.set(key, $0.isEmpty ? .null : .string($0)) })) {
            Text("系统默认").tag("")
            ForEach(fonts.filter { !$0.fileId.isEmpty }) { f in Text(f.name).tag(f.id) }
        }
    }

    private func status(_ f: Fonts.Rec) -> String {
        if !f.css.isEmpty { return "样式表网址，原生版不显示" }
        if f.fileId.isEmpty { return "只有网址，存到本机后可用" }
        return f.bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(f.bytes), countStyle: .file) : "本机"
    }

    private func addLink() async {
        busy = true
        defer { busy = false }
        do { try await Fonts.add(url: link); model.reload(); problem = nil }
        catch { problem = "未能添加：\(error.localizedDescription)" }
    }

    private func keep(_ f: Fonts.Rec) async {
        busy = true
        defer { busy = false }
        do { try await Fonts.keep(f); model.reload(); problem = nil }
        catch { problem = "未能存到本机：\(error.localizedDescription)" }
    }
}
