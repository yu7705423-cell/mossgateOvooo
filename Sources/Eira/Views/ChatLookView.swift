import PhotosUI
import SwiftUI

/// 聊天背景与上下栏的那几个旋钮（网页版 ChatLook.js）。数据与规则在 Prompt/ChatLook.swift。
/// 面板只占下半屏，会话就在上面，每拧一下都看得见结果。
struct ChatLookView: View {
    let chatId: String
    @State private var look = ChatLook.Look()
    @State private var picked: PhotosPickerItem?
    @State private var problem: String?
    @State private var confirmAll = false
    @State private var confirmReset = false
    @State private var notice: String?

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                HStack(spacing: Theme.sp3) {
                    Group {
                        if look.bg.isEmpty { SvgIcon(name: "image", size: 18, color: Theme.text3) }
                        else { LocalImage(id: look.bg, maxPixel: 200) }
                    }
                    .frame(width: 56, height: 56)
                    .background(Theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
                    VStack(alignment: .leading, spacing: Theme.sp2) {
                        PhotosPicker(selection: $picked, matching: .images) { Text("从相册选择") }
                        if !look.bg.isEmpty {
                            Button("清除", role: .destructive) { apply(["bg": .string("")]) }
                        }
                    }
                }
                if !look.bg.isEmpty {
                    VStack(alignment: .leading) {
                        Text("遮罩 \(look.veil)%")
                        Slider(value: Binding(get: { Double(look.veil) }, set: { look.veil = Int($0) }), in: 0...90, step: 5) { editing in
                            if !editing { apply(["veil": .number(Double(look.veil))]) }
                        }
                    }
                }
            } header: {
                Text("背景")
            } footer: {
                Text("背景铺满整个会话页，只对这段会话生效。遮罩使背景朝当前主题的底色变淡，数值越大，气泡外的文字越清晰。")
            }

            Section {
                Swatches(value: look.narr) { apply(["narr": .string($0)]) }
            } header: {
                Text("旁白文字颜色")
            } footer: {
                Text("旁白是消息之间居中的那一行小字。选「跟随主题」为默认的灰色；背景较深或较花时，可以换成更醒目的颜色。")
            }

            Section {
                Toggle("上下栏分开设置", isOn: Binding(get: { look.split }, set: { apply(["split": .bool($0)]) }))
            } footer: {
                Text(look.split ? "顶栏与输入栏各自设置。" : "顶栏与输入栏使用同一套样式。")
            }
            if look.split {
                barSection("顶栏", look.top, key: "top")
                barSection("输入栏", look.bottom, key: "bottom")
            } else {
                barSection("顶栏与输入栏", look.top, key: "top")
            }

            Section {
                Button("应用到全部会话") { confirmAll = true }
                if look.isSet {
                    Button("恢复默认", role: .destructive) { confirmReset = true }
                }
            } footer: {
                Text("实色为应用默认样式。半透明与毛玻璃时，消息从栏下经过。输入栏包括其上方的引用条与展开的面板。")
            }
        }
        .navigationTitle("聊天背景")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    let id = try Images.save(data)
                    await MainActor.run { apply(["bg": .string(id)]) }
                } catch {
                    await MainActor.run { problem = "图片未能保存：\(error.localizedDescription)" }
                }
            }
        }
        .confirmationDialog("其余全部会话（含群聊）的聊天背景与上下栏样式将替换为当前这一套。", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("应用") {
                do { notice = "已应用到 \(try ChatLook.applyToAll(chatId)) 段会话。" }
                catch { problem = "未能应用：\(error.localizedDescription)" }
            }
        }
        .confirmationDialog("清除这段会话的背景图，上下栏恢复为应用默认样式。", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("恢复", role: .destructive) {
                do { try ChatLook.reset(chatId); load(); changed() }
                catch { problem = "未能恢复：\(error.localizedDescription)" }
            }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        }
    }

    @ViewBuilder
    private func barSection(_ title: String, _ bar: ChatLook.Bar, key: String) -> some View {
        Section {
            Picker("样式", selection: Binding(get: { bar.style }, set: { apply([key: .object(["style": .string($0)])]) })) {
                ForEach(ChatLook.styles, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.segmented)
            Swatches(value: bar.color) { apply([key: .object(["color": .string($0)])]) }
            if bar.style != "solid" {
                VStack(alignment: .leading) {
                    Text("透明度 \(100 - bar.alpha)%")
                    Slider(value: Binding(get: { Double(100 - bar.alpha) }, set: { localAlpha(key, 100 - Int($0)) }),
                           in: 0...100, step: 5) { editing in
                        if !editing { apply([key: .object(["alpha": .number(Double(currentBar(key).alpha))])]) }
                    }
                }
            }
            if bar.style == "glass" {
                VStack(alignment: .leading) {
                    Text("模糊程度 \(bar.blur)")
                    Slider(value: Binding(get: { Double(bar.blur) }, set: { localBlur(key, Int($0)) }), in: 0...40, step: 2) { editing in
                        if !editing { apply([key: .object(["blur": .number(Double(currentBar(key).blur))])]) }
                    }
                }
            }
            Picker("文字颜色", selection: Binding(get: { bar.fg }, set: { apply([key: .object(["fg": .string($0)])]) })) {
                ForEach(ChatLook.fgs, id: \.id) { Text($0.label).tag($0.id) }
            }
        } header: { Text(title) }
    }

    private func currentBar(_ key: String) -> ChatLook.Bar { key == "bottom" ? look.bottom : look.top }

    /// 拖动滑块时只改本页，松手才写库
    private func localAlpha(_ key: String, _ v: Int) {
        if key == "bottom" { look.bottom.alpha = v } else { look.top.alpha = v; if !look.split { look.bottom.alpha = v } }
    }

    private func localBlur(_ key: String, _ v: Int) {
        if key == "bottom" { look.bottom.blur = v } else { look.top.blur = v; if !look.split { look.bottom.blur = v } }
    }

    private func load() {
        guard let c = try? Repo.chat(chatId) else { return }
        look = ChatLook.of(c)
    }

    private func apply(_ patch: [String: JSONValue]) {
        do {
            try ChatLook.set(chatId, patch)
            problem = nil
            load()
            changed()
        } catch {
            problem = "未能保存：\(error.localizedDescription)"
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .eiraChatLookChanged, object: chatId)
    }
}

extension Notification.Name {
    /// 一段会话的背景与上下栏改了：会话页重读
    static let eiraChatLookChanged = Notification.Name("eira.chatLookChanged")
}

/// 一排色块：跟随主题、几种预设、自选
struct Swatches: View {
    let value: String
    var onPick: (String) -> Void

    var body: some View {
        let custom = !value.isEmpty && !ChatLook.colors.contains(value)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.sp2) {
                ForEach(ChatLook.colors, id: \.self) { c in
                    Button { onPick(c) } label: { swatch(c, on: value == c) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.isEmpty ? "跟随主题" : c)
                }
                ColorPicker("自选颜色", selection: Binding(
                    get: { Color(hex: custom ? value : "#888888") ?? .gray },
                    set: { onPick(Self.hex($0)) }), supportsOpacity: false)
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
                Circle().fill(Color(hex: c) ?? .clear)
            }
            Circle().strokeBorder(on ? Theme.text : Theme.border, lineWidth: on ? 2 : 1)
        }
        .frame(width: 28, height: 28)
    }

    static func hex(_ c: Color) -> String {
        let u = UIColor(c)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        u.getRed(&r, green: &g, blue: &b, alpha: &a)
        let to = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", to(r), to(g), to(b))
    }
}

// MARK: - 落到会话页上

extension ChatLook {
    /// 一栏的底：实色照主题底色或选的颜色；半透明按不透明度；毛玻璃用系统的模糊材质，选了颜色再叠一层
    static func fill(_ b: Bar) -> AnyShapeStyle {
        let base = Color(hex: b.color) ?? Theme.bg
        switch b.style {
        case "clear": return AnyShapeStyle(base.opacity(Double(b.alpha) / 100))
        case "glass":
            return b.color.isEmpty ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(base.opacity(Double(b.alpha) / 100))
        default: return AnyShapeStyle(base)
        }
    }

    /// 栏里的字：浅色字用深色外观，深色字用浅色外观；跟随主题为 nil
    static func scheme(_ b: Bar) -> ColorScheme? {
        b.fg == "light" ? .dark : b.fg == "dark" ? .light : nil
    }
}

/// 会话页的背景：图铺满，遮罩朝主题底色淡过去
struct ChatBackdrop: View {
    let look: ChatLook.Look

    var body: some View {
        GeometryReader { g in
            ZStack {
                Theme.bg
                if !look.bg.isEmpty {
                    LocalImage(id: look.bg, maxPixel: max(g.size.width, g.size.height) * 3)
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                    Theme.bg.opacity(Double(look.veil) / 100)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// 输入栏那一组（引用条、输入框、面板、多选栏）的底与字色
struct BottomBarLook: ViewModifier {
    let bar: ChatLook.Bar

    func body(content: Content) -> some View {
        if let s = ChatLook.scheme(bar) {
            content.background(ChatLook.fill(bar)).environment(\.colorScheme, s)
        } else {
            content.background(ChatLook.fill(bar))
        }
    }
}

/// 顶栏的底与字色。没设过就是应用本来的样子
struct TopBarLook: ViewModifier {
    let bar: ChatLook.Bar

    func body(content: Content) -> some View {
        if bar.isSet {
            content
                .toolbarBackground(ChatLook.fill(bar), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(ChatLook.scheme(bar), for: .navigationBar)
        } else {
            content
        }
    }
}
