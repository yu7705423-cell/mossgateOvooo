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
                Text("当前那一套填全了密钥与模型后，角色可以在回复里发图片：每张图调用一次生图接口，失败不自动重试，可在消息上手动重新生成。")
            }
            Section {
                TextEditor(text: model.textBinding("imagePrompt"))
                    .frame(minHeight: 90)
            } header: {
                Text("全局生图提示词")
            } footer: {
                Text("接在每一张图的提示词末尾。其中单独成行的「Negative」之后的部分作为负面提示词处理，不会当作画面内容发送。")
            }
            Section {
                ForEach(ImageGen.styles) { st in
                    Toggle(st.label, isOn: styleBinding(st.id))
                }
            } header: {
                Text("画风预设")
            } footer: {
                Text("开启后，角色写图片描述时须写明场景、构图、光线与人物穿着，最终提示词末尾接上相应的画风。不增加调用次数。")
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
                    Text(kindNote(p.kind))
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
                    Text(paramNote(p))
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
                        Text(p.kind == "openai"
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
                    Text("用这一套接口实际生成一张图，会按一张图计费。")
                }
                Section {
                    Button("删除这套接口", role: .destructive) { confirmDelete = true }
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
