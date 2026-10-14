import PhotosUI
import SwiftUI

/// 主屏壁纸（网页版 AppearancePage 的 WallpaperRow）：在「设置 - 主题」里。
struct WallpaperSection: View {
    @State private var current = Shell.layout().wallpaperHome
    @State private var picking = false
    @State private var photo: PhotosPickerItem?
    @State private var problem: String?

    var body: some View {
        Section {
            HStack(spacing: Theme.sp3) {
                Group {
                    if current.isEmpty {
                        Image(systemName: "photo").foregroundStyle(Theme.text3)
                    } else {
                        LocalImage(id: current, maxPixel: 240)
                    }
                }
                .frame(width: 54, height: 96)
                .background(Theme.groupFill)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                VStack(alignment: .leading, spacing: Theme.sp2) {
                    Text("主界面")
                    Text("位于图标与小组件下层").font(.caption).foregroundStyle(Theme.text3)
                    HStack(spacing: Theme.sp3) {
                        Button(current.isEmpty ? "选择" : "更换") { picking = true }.buttonStyle(.borderless)
                        if !current.isEmpty {
                            Button("清除") { save(nil) }.buttonStyle(.borderless)
                        }
                    }
                    .font(.footnote)
                }
            }
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
        } header: { Text("壁纸") }
        .photosPicker(isPresented: $picking, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    let id = try Images.save(data)
                    await MainActor.run { save(id) }
                } catch {
                    await MainActor.run { problem = "壁纸未能保存：\(error.localizedDescription)" }
                }
            }
        }
    }

    private func save(_ id: String?) {
        do {
            try HomeEdit.setWallpaper(id)
            current = id ?? ""
            problem = nil
        } catch {
            problem = "壁纸未能保存：\(error.localizedDescription)"
        }
    }
}

/// 一个 app 的图标与名字（网页版 ui/IconPicker）：主屏长按那个图标进来，只此一处。
struct IconEditView: View {
    let appId: String
    var done: () -> Void

    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var picking = false
    @State private var photo: PhotosPickerItem?
    @State private var problem: String?

    private var look: Shell.Look? { Shell.look(appId, settings: model.s.raw) }
    private var custom: [String: JSONValue] { model.s.raw["appIcons"]?.object?[appId]?.object ?? [:] }
    private var defaultName: String { Shell.app(appId)?.name ?? appId }

    var body: some View {
        Form {
            if let look {
                Section {
                    HStack {
                        Spacer()
                        AppTileView(look: look, size: 72, home: HomeLook(wallpaper: false, dark: scheme == .dark, s: model.s.raw))
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField(defaultName, text: $name)
                        .onSubmit(saveName)
                    Picker("名称显示", selection: Binding(get: { look.label }, set: { v in patch(["label": .string(v)]) })) {
                        Text("跟随总设置").tag("")
                        Text("显示").tag("show")
                        Text("隐藏").tag("hide")
                    }
                } header: { Text("名称") } footer: {
                    HelpNote("留空时使用默认名称「\(defaultName)」。")
                }
                Section {
                    Button(look.imageId.isEmpty ? "选择图片" : "更换图片") { picking = true }
                    if !look.imageId.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("图片大小")
                                Spacer()
                                Text("\(Int(look.scale > 0 ? look.scale : HomeEdit.iconScale.def))%").foregroundStyle(Theme.text3).monospacedDigit()
                            }
                            Slider(value: Binding(get: { look.scale > 0 ? look.scale : HomeEdit.iconScale.def },
                                                  set: { v in patch(["scale": HomeEdit.scaleValue(v)]) }),
                                   in: HomeEdit.iconScale.min...HomeEdit.iconScale.max, step: 5)
                        }
                        Toggle("不要底板", isOn: Binding(get: { look.bare }, set: { v in patch(["bare": v ? .bool(true) : nil]) }))
                        Button("清除图片") { patch(["imageId": nil, "scale": nil, "bare": nil]) }
                    }
                } header: { Text("图片") } footer: {
                    HelpNote("设置图片后，图片替代线条图标。不要底板开启时只显示图片本身，适合异形图标。")
                }
                if look.imageId.isEmpty {
                    Section {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.sp2), count: 6), spacing: Theme.sp3) {
                            ForEach(Self.iconNames, id: \.self) { n in
                                SvgIcon(name: n, size: 24, color: n == look.icon ? Theme.accent : Theme.text)
                                    .frame(width: 40, height: 40)
                                    .background(n == look.icon ? Theme.groupFill : Color.clear,
                                                in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                                    .contentShape(Rectangle())
                                    .onTapGesture { patch(["icon": n == Shell.app(appId)?.icon ? nil : .string(n)]) }
                                    .accessibilityLabel(n)
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                        .padding(.vertical, Theme.sp2)
                    } header: { Text("线条图标") }
                }
                if !custom.isEmpty {
                    Section {
                        Button("恢复默认", role: .destructive) {
                            model.update { HomeEdit.resetIcon(&$0, appId) }
                            name = ""
                        }
                    }
                }
                ProblemSection(text: problem ?? model.problem)
            }
        }
        .navigationTitle("图标与名称")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { saveName(); done() } } }
        .onAppear { name = custom["name"]?.string ?? "" }
        .onDisappear(perform: saveName)
        .photosPicker(isPresented: $picking, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    let id = try Images.save(data, maxPixel: Images.iconMax * 2)
                    await MainActor.run { patch(["imageId": .string(id)]) }
                } catch {
                    await MainActor.run { problem = "图片未能保存：\(error.localizedDescription)" }
                }
            }
        }
    }

    static let iconNames: [String] = Shell.icons.keys.sorted()

    private func patch(_ p: [String: JSONValue?]) {
        model.update { HomeEdit.patchIcon(&$0, appId, p) }
    }

    private func saveName() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n != (custom["name"]?.string ?? "") else { return }
        patch(["name": n.isEmpty ? nil : .string(String(n.prefix(20)))])
    }
}
