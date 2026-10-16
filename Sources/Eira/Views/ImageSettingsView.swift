import SwiftUI
import UIKit

/// 「设置 - 接口与服务 - 生图」：几套生图接口、当前用哪一套，以及全局提示词与画风预设（网页版 settings/ImagePage.js）。
struct ImageSettingsView: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                ForEach(model.s.imagePresets) { p in
                    NavigationLink { ImagePresetEditView(id: p.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text(kindLabel(p.kind) + (p.model.isEmpty ? " · 未填模型" : " · \(p.model)"))
                                    .font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            if p.id == model.s.activeImage?.id { Text("当前").foregroundStyle(Theme.secondaryText) }
                        }
                    }
                }
                Button("新建生图接口") { model.update { $0.addImagePreset() } }
            } header: {
                Text("生图接口")
            } footer: {
                Text("每张图调用一次生图接口。")
                HelpNote("当前那一套填全了密钥与模型后，角色可以在回复里发图片：每张图调用一次生图接口，失败不自动重试，可在消息上手动重新生成。")
            }
            Section {
                TextEditor(text: model.textBinding("imagePrompt"))
                    .frame(minHeight: 90)
                ImgPromptPresetRows(scope: .global, state: ImgPrompts.state { model.s.raw[$0] })
            } header: {
                Text("全局生图提示词")
            } footer: {
                HelpNote("接在每一张图的提示词末尾。其中单独成行的「Negative」之后的部分作为负面提示词处理，不会当作画面内容发送。")
                HelpNote("可以把几段提示词存为预设，点选一份即把上面这一栏换成它。当前那份改过之后，可以存回或另存一份。删除预设不影响这一栏里正在用的文字。", title: "生图提示词预设")
            }
            Section {
                Toggle("生图前先写一遍提示词", isOn: model.bool("writeImagePrompt", false))
            } footer: {
                Text("开启后每张图多调用一次接口。")
                HelpNote("角色每写一个 [图片：…]，先调用一次文字接口，参考最近的对话把它改写成一份自带全部信息的画面描述，再交给生图接口（走副用接口）。改写失败时用原话生成。关闭后直接用角色写的那一句。", title: "生图前先写一遍提示词")
            }
            Section {
                ForEach(ImageGen.styles) { st in
                    Toggle(st.label, isOn: styleBinding(st.id))
                }
            } header: {
                Text("画风预设")
            } footer: {
                HelpNote("开启后，角色写图片描述时须写明场景、构图、光线与人物穿着，最终提示词末尾接上相应的画风。不增加调用次数。")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("生图")
        .onAppear { model.reload() }
    }

    private func kindLabel(_ k: String) -> String { ImagePreset.kinds.first { $0.id == k }?.label ?? k }

    private func styleBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { (model.s.raw["imageStyles"]?.array ?? []).contains { $0.string == id } },
                set: { on in
                    model.update { s in
                        var list = (s.raw["imageStyles"]?.array ?? []).compactMap(\.string).filter { $0 != id }
                        if on { list.append(id) }
                        s.raw["imageStyles"] = .array(list.map { .string($0) })
                    }
                })
    }
}

/// 一套生图接口的各项。
struct ImagePresetEditView: View {
    let id: String
    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var testing = false
    @State private var testImage: UIImage?
    @State private var testError: String?
    @State private var confirmDelete = false

    private var preset: ImagePreset? { model.s.imagePresets.first { $0.id == id } }

    var body: some View {
        Form {
            if let p = preset {
                Section {
                    TextField("名称", text: field("name"))
                    Picker("类型", selection: field("kind", def: "openai")) {
                        ForEach(ImagePreset.kinds) { Text($0.label).tag($0.id) }
                    }
                    if p.id != model.s.activeImage?.id {
                        Button("设为当前") { model.update { $0.setActiveImage(id) } }
                    }
                } footer: {
                    HelpNote(kindNote(p.kind))
                }
                Section("连接") {
                    TextField(ImagePreset.kinds.first { $0.id == p.kind }?.base ?? "接口地址", text: field("baseUrl"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField(p.kind == "nai" ? "持久 token" : "API Key", text: field("apiKey"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(p.kind == "nai" ? "模型，如 nai-diffusion-3" : "模型，如 gpt-image-1", text: field("model"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    if p.kind != "chat" {
                        TextField("尺寸，如 1024x1024", text: field("size", def: "1024x1024"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if p.kind == "openai" {
                        Picker("返回格式", selection: field("respFormat")) {
                            ForEach(ImagePreset.formats) { Text($0.label).tag($0.id) }
                        }
                    }
                    Picker("提示词语言", selection: field("promptLang")) {
                        ForEach(ImagePreset.langs) { Text($0.label).tag($0.id) }
                    }
                    NumberRow(title: "等待上限", value: timeoutBinding, unit: "秒", placeholder: "300")
                } header: {
                    Text("参数")
                } footer: {
                    HelpNote(paramNote(p))
                }
                if p.kind != "nai" {
                    Section {
                        if p.kind == "openai" {
                            Picker("锁脸参考图", selection: field("ref")) {
                                Text("不传").tag("")
                                Text("传照片（images/edits）").tag("edits")
                            }
                        }
                        Toggle("只传一张", isOn: boolField("refOne"))
                    } header: {
                        Text("锁脸")
                    } footer: {
                        HelpNote(p.kind == "chat"
                             ? "对话接口把锁脸照片和描述放在同一条消息里发出。只传一张：接口不接受多张时开启，每人只传选定的那一张（在锁脸页里选）。"
                             : "传照片：锁脸时把照片随请求发到 images/edits，接口支持时比外貌描述更像；接口不支持参考图时退回外貌描述，不额外调用。只传一张：接口不接受多张时开启，每人只传选定的那一张（在锁脸页里选）。", title: "生图接口的锁脸")
                    }
                }
                if p.kind != "chat" {
                    Section {
                        TextEditor(text: field("negative")).frame(minHeight: 70)
                        if p.kind == "openai" {
                            Toggle("随请求发送负面提示词", isOn: boolField("negOn"))
                        }
                    } header: {
                        Text("负面提示词")
                    } footer: {
                        HelpNote(p.kind == "openai"
                             ? "OpenAI 兼容接口的标准中没有负面提示词字段，默认不发送；接口支持时再开启，不支持的接口收到后会报错。"
                             : "随每次请求发送。")
                    }
                }
                Section {
                    Button(testing ? "正在生成" : "生成一张测试图") { runTest(p) }
                        .disabled(testing || !p.ready)
                    if let testImage {
                        Image(uiImage: testImage).resizable().scaledToFit().frame(maxHeight: 220)
                    }
                    if let testError { Text(testError).font(.footnote).foregroundStyle(Theme.danger) }
                } footer: {
                    Text("按一张图计费。")
                    HelpNote("用这一套接口实际生成一张图，会按一张图计费。", title: "测试生图")
                }
                Section {
                    Button("删除这套接口", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText)
                }
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle(preset?.name ?? "生图接口")
        .confirmationDialog("删除这套生图接口？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                model.update { $0.removeImagePreset(id) }
                dismiss()
            }
        }
    }

    private func kindNote(_ k: String) -> String {
        switch k {
        case "nai": return "NovelAI 自己的接口。密钥填网站用户设置里生成的持久 token。"
        case "chat": return "走 /v1/chat/completions，描述作为一条消息发出，从回复里取图。Gemini 生图、gpt-4o 生图一类在对话里出图的模型用这一种。"
        default: return "OpenAI 本身与绝大多数中转站。走 /v1/images/generations。"
        }
    }

    private func paramNote(_ p: ImagePreset) -> String {
        var out: [String] = []
        switch p.promptLang {
        case "en": out.append("角色写英文：图片描述要求用英文书写，不增加调用次数。")
        case "translate": out.append("生图前翻译：含中日韩文字的提示词先经文字接口译成英文，每张图多调用一次（走副用接口）；译失败时照原文生成。")
        default: out.append("跟随对话：描述是什么语言就原样发送。")
        }
        out.append("等待上限填 0 表示一直等待。生图较慢，一张一两分钟属于常见情况。")
        return out.joined(separator: "\n")
    }

    private func field(_ key: String, def: String = "") -> Binding<String> {
        Binding(get: { preset?.json[key]?.string ?? def },
                set: { v in model.update { $0.patchImagePreset(id, [key: .string(v)]) } })
    }

    private func boolField(_ key: String) -> Binding<Bool> {
        Binding(get: { preset?.json[key]?.bool ?? false },
                set: { v in model.update { $0.patchImagePreset(id, [key: .bool(v)]) } })
    }

    private var timeoutBinding: Binding<Double> {
        Binding(get: { preset?.timeout ?? 300 },
                set: { v in model.update { $0.patchImagePreset(id, ["timeout": .number(v)]) } })
    }

    private func runTest(_ p: ImagePreset) {
        testing = true
        testImage = nil
        testError = nil
        Task {
            do {
                let data = try await ImageGen.generate(prompt: "a small black circle on a plain white background", preset: p)
                await MainActor.run { testImage = UIImage(data: data); if testImage == nil { testError = "接口返回的数据无法解码为图片" } }
            } catch {
                await MainActor.run { testError = error.localizedDescription }
            }
            await MainActor.run { testing = false }
        }
    }
}

// MARK: - 生图提示词预设（网页版 ui/imgpresets.js，ARCHITECTURE 4.522）

/// 预设存在哪儿：全局那一份在设置里，角色那一份在角色卡上。字段名两边相同（ImgPrompts）
enum ImgPromptScope: Hashable {
    case global
    case char(String)
}

/// 两处的读写。写不进去抛出，由界面写在屏幕上（第 20 条）
@MainActor
enum ImgPromptStore {
    static func read(_ scope: ImgPromptScope) throws -> ImgPrompts.State {
        switch scope {
        case .global:
            let raw = SettingsModel.shared.s.raw
            return ImgPrompts.state { raw[$0] }
        case .char(let id):
            guard let c = try Repo.character(id) else { throw StoreError(message: "该角色已不存在") }
            return ImgPrompts.state { c.row[$0] }
        }
    }

    static func write(_ scope: ImgPromptScope, _ patch: [String: JSONValue]) throws {
        switch scope {
        case .global:
            let model = SettingsModel.shared
            model.update { s in for (k, v) in patch { s.raw[k] = v } }
            if let p = model.problem { throw StoreError(message: p) }
        case .char(let id):
            guard let c = try Repo.character(id) else { throw StoreError(message: "该角色已不存在") }
            _ = try People.update(c, patch)
        }
    }
}

/// 提示词那一栏下面的几行：选用哪一份、存为预设、改过之后存回、管理。全局与角色卡共用。
/// state 由调用方按自己手上的那份记录算好传进来；写完调 onWrite，调用方重读
struct ImgPromptPresetRows: View {
    let scope: ImgPromptScope
    let state: ImgPrompts.State
    var onWrite: () -> Void = {}

    @State private var naming = false
    @State private var nameText = ""
    @State private var switching: ImgPrompts.Preset?
    @State private var done: String?
    @State private var problem: String?

    var body: some View {
        Menu {
            ForEach(state.rows) { r in
                Button { pick(r) } label: {
                    if state.current?.id == r.id { Label(r.name, systemImage: "checkmark") } else { Text(r.name) }
                }
            }
            if !state.rows.isEmpty { Divider() }
            Button("将当前内容存为预设") { saveAsTapped() }
        } label: {
            LabeledContent("预设", value: state.current?.name ?? (state.rows.isEmpty ? "尚无预设" : "未选用"))
        }
        .alert("存为预设", isPresented: $naming) {
            TextField("名称", text: $nameText)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let made = ImgPrompts.saveAs(state, name: nameText)
                run("已存为预设「\(made.row.name)」。") { made.patch }
            }
        } message: {
            Text("保存当前填写的提示词。")
        }
        .confirmationDialog("当前填写的提示词没有存为预设，切换后将被替换。",
                            isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }),
                            titleVisibility: .visible, presenting: switching) { r in
            Button("切换到「\(r.name)」") { run(nil) { ImgPrompts.apply(state, id: r.id) } }
        }
        if state.dirty, let cur = state.current {
            HStack {
                Text("当前内容与预设「\(cur.name)」不同，尚未存回。").font(.footnote).foregroundStyle(Theme.text2)
                Spacer()
                Button("存回") { run("已存回「\(cur.name)」。") { ImgPrompts.overwrite(state) } }
                    .buttonStyle(.borderless)
            }
        }
        if !state.rows.isEmpty {
            NavigationLink("管理预设") { ImgPromptPresetsPage(scope: scope, onWrite: onWrite) }
        }
        if let done { Text(done).font(.footnote).foregroundStyle(Theme.text2) }
        if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
    }

    private func pick(_ r: ImgPrompts.Preset) {
        if r.id == state.current?.id && !state.dirty { return }
        // 那一栏里有没存进任何一份的文字，换掉之前说一声
        if ImgPrompts.needsConfirm(state, to: r) { switching = r; return }
        run(nil) { ImgPrompts.apply(state, id: r.id) }
    }

    private func saveAsTapped() {
        guard !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = "提示词为空，无法存为预设。"; done = nil; return
        }
        nameText = ""
        naming = true
    }

    private func run(_ ok: String?, _ make: () -> [String: JSONValue]?) {
        guard let patch = make() else { return }
        do {
            try ImgPromptStore.write(scope, patch)
            done = ok
            problem = nil
            onWrite()
        } catch {
            problem = "未能保存：\(error.localizedDescription)"
            done = nil
        }
    }
}

/// 管理预设（整页）：套用、重命名、删除
struct ImgPromptPresetsPage: View {
    let scope: ImgPromptScope
    var onWrite: () -> Void = {}

    @State private var state = ImgPrompts.State(rows: [], current: nil, text: "")
    @State private var renaming: ImgPrompts.Preset?
    @State private var nameText = ""
    @State private var deleting: ImgPrompts.Preset?
    @State private var done: String?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                if state.rows.isEmpty { Text("没有已存的预设。").foregroundStyle(Theme.text2) }
                ForEach(state.rows) { r in
                    HStack(spacing: Theme.gap) {
                        Button { run("已套用「\(r.name)」。") { ImgPrompts.apply(state, id: r.id) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.current?.id == r.id ? "\(r.name)（当前）" : r.name).foregroundStyle(Theme.text)
                                Text(r.text.isEmpty ? "（空）" : (r.text.count > 120 ? String(r.text.prefix(120)) + "…" : r.text))
                                    .font(.footnote).foregroundStyle(Theme.text2).lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        Menu {
                            Button("重命名") { nameText = r.name; renaming = r }
                            Button("删除", role: .destructive) { deleting = r }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("更多")
                    }
                }
            } header: {
                Text("点按一份即套用到提示词栏")
            }
            if let done { Section { Text(done).foregroundStyle(Theme.text2) } }
            ProblemSection(text: problem)
        }
        .navigationTitle(scope == .global ? "全局生图提示词预设" : "这个角色的生图提示词预设")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .alert("重命名预设", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $nameText)
            Button("取消", role: .cancel) {}
            Button("保存") { if let r = renaming { run(nil) { ImgPrompts.rename(state, id: r.id, name: nameText) } } }
        }
        .confirmationDialog("只删除这份预设，当前填写的提示词不受影响。",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { r in
            Button("删除预设「\(r.name)」", role: .destructive) { run(nil) { ImgPrompts.remove(state, id: r.id) } }
        }
    }

    private func load() {
        do { state = try ImgPromptStore.read(scope) } catch { problem = "读取失败：\(error.localizedDescription)" }
    }

    private func run(_ ok: String?, _ make: () -> [String: JSONValue]?) {
        guard let patch = make() else { return }
        do {
            try ImgPromptStore.write(scope, patch)
            done = ok
            problem = nil
            load()
            onWrite()
        } catch {
            problem = "未能保存：\(error.localizedDescription)"
            done = nil
        }
    }
}
