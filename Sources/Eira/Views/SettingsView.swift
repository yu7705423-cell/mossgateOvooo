import SwiftUI

/// 「设置」根页。只放全局的东西：接口与服务、用量、外观、存储（网页版第 5 条）。
/// 排法照网页版新版根页（4.528）：主用接口一张状态卡，其余分组；一行只写名字和当前状态。
struct SettingsView: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ServicesView() } label: { apiCard }
                }
                Section("对话") {
                    NavigationLink { UsageLimitsView() } label: {
                        row("用量与上限", "slider.horizontal.3", ExtraCalls.active(model.s).isEmpty ? "无额外调用" : "额外调用 \(ExtraCalls.active(model.s).count) 项")
                    }
                }
                Section("外观") {
                    NavigationLink { AppearanceView() } label: {
                        row("主题", "circle.lefthalf.filled", AppearanceView.label(model.s))
                    }
                }
                Section("设定") {
                    NavigationLink { LorebookListView() } label: { row("世界书", "book.closed", "") }
                }
                Section("数据") {
                    NavigationLink { StorageView() } label: { row("存储与备份", "externaldrive", "") }
                }
                Section {
                    NavigationLink { FeedbackView() } label: { row("问题反馈", "exclamationmark.bubble", "") }
                } header: {
                    Text("关于")
                } footer: {
                    Text("Eiraowo · 本地运行，数据只存在这台设备上\n版本 \(Self.version)")
                }
            }
            .navigationTitle("设置")
            .onAppear { model.reload() }
        }
    }

    private var apiCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("主用接口").font(.caption).foregroundStyle(Theme.secondaryText)
            if let p = model.s.mainPreset {
                Text(p.name.isEmpty ? "未命名接口" : p.name).font(.title3)
                Text(p.model.isEmpty ? "未选模型" : p.model).font(.footnote).foregroundStyle(Theme.secondaryText)
                if let f = model.s.fallbackPreset {
                    Text("副用 \(f.name.isEmpty ? "未命名接口" : f.name)").font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            } else {
                Text("尚未配置").font(.title3)
                Text("配置后才能对话").font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ title: String, _ icon: String, _ value: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if !value.isEmpty { Text(value).foregroundStyle(Theme.secondaryText) }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?")（\(info["CFBundleVersion"] as? String ?? "?")）"
    }
}

// MARK: - 接口与服务

struct ServicesView: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        List {
            Section("对话") {
                NavigationLink { ApiSettingsView() } label: {
                    status("接口", model.s.mainPreset.map { "\($0.name) · \($0.model.isEmpty ? "未选模型" : $0.model)" }, model.s.mainPreset == nil ? "未配置" : "")
                }
                NavigationLink { MemoryApiView() } label: {
                    status("记忆接口", model.s.memoryPreset?.model, model.s.memoryPreset == nil ? "跟随副用" : "")
                }
                NavigationLink { RoutesView() } label: {
                    status("任务用哪套接口", nil, routedCount == 0 ? "全部默认" : "已指定 \(routedCount) 项")
                }
            }
            Section("识别你发送的内容") {
                NavigationLink { VisionSettingsView() } label: {
                    status("识图", model.s.visionMode == "api" ? model.s.visionPreset?.model : nil, visionValue)
                }
            }
        }
        .navigationTitle("接口与服务")
        .onAppear { model.reload() }
    }

    private var routedCount: Int {
        (model.s.raw["taskRoutes"]?.object ?? [:]).values.filter { !($0.string ?? "").isEmpty }.count
    }

    private var visionValue: String {
        switch model.s.visionMode {
        case "chat": return "交给聊天模型"
        case "api": return model.s.visionPreset == nil ? "未填全" : "单独接口"
        default: return "关闭"
        }
    }

    private func status(_ title: String, _ desc: String?, _ value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let desc, !desc.isEmpty { Text(desc).font(.footnote).foregroundStyle(Theme.secondaryText) }
            }
            Spacer()
            if !value.isEmpty { Text(value).foregroundStyle(Theme.secondaryText) }
        }
    }
}

/// 地址、密钥、模型三项，以及「用哪个来源」与「测试连接」。识图、记忆接口这几套形状相同（网页版 ApiSource 与各页）。
struct ServiceConnSection: View {
    let name: String
    let modelHint: String
    @ObservedObject private var model = SettingsModel.shared
    @State private var testing = false
    @State private var result: String?
    @State private var resultIsError = false

    let preset: () -> ChatPreset?

    init(name: String, modelHint: String, preset: @escaping () -> ChatPreset?) {
        self.name = name
        self.modelHint = modelHint
        self.preset = preset
    }

    var body: some View {
        let endpointId = model.service(name, "endpointId")
        Section {
            Picker("地址与密钥", selection: endpointId) {
                Text("在此填写").tag("")
                ForEach(model.s.endpointSources) { src in
                    Text("同「\(src.name)」").tag(src.id)
                }
            }
            if endpointId.wrappedValue.isEmpty {
                TextField("https://api.openai.com/v1", text: model.service(name, "baseUrl"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("密钥", text: model.service(name, "apiKey"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            TextField("模型", text: model.service(name, "model"))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: {
            Text("接口")
        } footer: {
            Text("OpenAI 兼容的 chat/completions 端点。地址留空时使用 https://api.openai.com/v1，中转站填写至 /v1 为止。选择已有的接口时，地址与密钥从那一套读取，模型仍在这里填写。\(modelHint)")
        }
        Section {
            Button(testing ? "连接中" : "测试连接", action: test).disabled(testing)
            if let result {
                Text(result).font(.footnote).foregroundStyle(resultIsError ? Theme.danger : Theme.secondaryText)
            }
        } footer: {
            Text("发送一次极短的请求，确认地址、密钥与模型可用。计入当天的请求次数。")
        }
    }

    private func test() {
        guard let p = preset() else {
            result = "密钥或模型未填写。"; resultIsError = true; return
        }
        testing = true
        result = nil
        Task {
            let (text, ok) = await ConnTest.run(p)
            await MainActor.run { result = text; resultIsError = !ok; testing = false }
        }
    }
}

/// 测试连接：发一次极短的请求。经 AIService 发，照样记账。
enum ConnTest {
    static func run(_ p: ChatPreset) async -> (String, Bool) {
        do {
            let r = try await AIService.shared.send(task: "api.test", preset: p, system: "Reply with the single word OK.",
                                                    messages: [AIMessage(role: .user, content: "ping")], maxTokens: 16)
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ("连接成功：" + (text.isEmpty ? "（接口返回了空内容）" : String(text.prefix(200))), true)
        } catch {
            return (error.localizedDescription, false)
        }
    }
}

struct MemoryApiView: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                Picker("记忆整理走哪套接口", selection: modeBinding) {
                    Text("跟随副用接口").tag("spare")
                    Text("单独的接口").tag("api")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(isApi
                     ? "自动总结记忆、压缩关系底色、从文本导入记忆、历史压缩这四项走下面这套接口，其余后台任务仍走副用接口。未填全时退回副用接口。"
                     : "与其余后台任务一同走副用接口。副用接口未配置时退回主用接口。")
            }
            if isApi {
                ServiceConnSection(name: "memory", modelHint: "这几项输入长、输出短，且无人等待结果，可以选用比对话接口更便宜的模型。须支持较长的上下文。") {
                    model.s.memoryPreset
                }
                Section {
                    Button("清空配置", role: .destructive) {
                        model.update { $0.setService("memory", ["apiKey": .string(""), "model": .string(""), "baseUrl": .string(""), "endpointId": .string("")]) }
                    }
                }
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("记忆接口")
    }

    private var isApi: Bool { model.s.raw["services"]?.object?["memory"]?.object?["mode"]?.string == "api" }

    private var modeBinding: Binding<String> {
        Binding(get: { isApi ? "api" : "spare" },
                set: { v in model.update { $0.setService("memory", ["mode": .string(v)]) } })
    }
}

struct VisionSettingsView: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                Picker("图片怎么让角色看见", selection: modeBinding) {
                    Text("关闭").tag("off")
                    Text("交给聊天模型").tag("chat")
                    Text("单独的接口").tag("api")
                }
                .pickerStyle(.segmented)
            } footer: {
                switch model.s.visionMode {
                case "chat":
                    Text("图片随当前这一轮的请求直接发给聊天模型，看过一次后不再重复传图。要求聊天模型本身能看图，否则请求会报错。")
                case "api":
                    Text("图片发出后先交给下面这套接口读成一段描述，描述随消息一起进入上下文。每张图调用一次识图接口。聊天模型本身不能看图时用这一档。")
                default:
                    Text("不识别。图片仍可正常发送与查看，角色只知道你发了一张图，不知道图上有什么。")
                }
            }
            if model.s.visionMode == "api" {
                ServiceConnSection(name: "vision", modelHint: "须为能看图的多模态模型。测试连接只发文字，不验证看图能力。") {
                    model.s.visionPreset
                }
                Section {
                    Button("清空配置", role: .destructive) {
                        model.update { $0.setService("vision", ["apiKey": .string(""), "model": .string(""), "baseUrl": .string(""), "endpointId": .string("")]) }
                    }
                }
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("识图")
    }

    private var modeBinding: Binding<String> {
        Binding(get: { model.s.visionMode },
                set: { v in model.update { $0.setService("vision", ["mode": .string(v)]) } })
    }
}

/// 几件事各自用哪套接口。只改变用哪一套，不增加调用次数。
struct RoutesView: View {
    @ObservedObject private var model = SettingsModel.shared

    private struct Option: Identifiable {
        let value: String
        let label: String
        var id: String { value }
    }

    var body: some View {
        Form {
            Section {
                ForEach(RouteGroup.all) { g in
                    Picker(selection: binding(g.id)) {
                        ForEach(options) { o in
                            Text(o.value.isEmpty ? "默认" : o.label).tag(o.value)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.label)
                            if current(g.id).isEmpty {
                                Text(g.def).font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
            } footer: {
                Text("为下面几项任务单独指定接口。只改变用哪一套，不增加调用次数。选定的接口缺少密钥或模型时，按默认方式选择。原生版尚未提供的功能也列在这里，设定在功能提供后生效。")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("任务用哪套接口")
    }

    private var options: [Option] {
        let s = model.s
        let name = { (p: ChatPreset?) in p.map { $0.name.isEmpty ? "未命名接口" : $0.name } }
        var out = [
            Option(value: "", label: "默认"),
            Option(value: "main", label: "主用" + (name(s.mainPreset).map { "（\($0)）" } ?? "")),
            Option(value: "fallback", label: "副用" + (name(s.fallbackPreset).map { "（\($0)）" } ?? "（未指定）")),
            Option(value: "memory", label: "记忆接口" + (s.memoryPreset == nil ? "（未单独配置）" : "")),
        ]
        out += s.chatPresets.map { Option(value: $0.id, label: $0.name.isEmpty ? "未命名接口" : $0.name) }
        // 选过的那一套已经删掉了：照样列出来，不让选择器落空
        for g in RouteGroup.all {
            let v = current(g.id)
            if !v.isEmpty, !out.contains(where: { $0.value == v }) { out.append(Option(value: v, label: "已删除的接口")) }
        }
        return out
    }

    private func current(_ group: String) -> String {
        model.s.raw["taskRoutes"]?.object?[group]?.string ?? ""
    }

    private func binding(_ group: String) -> Binding<String> {
        Binding(get: { current(group) },
                set: { v in model.update {
                    var routes = $0.raw["taskRoutes"]?.object ?? [:]
                    routes[group] = .string(v)
                    $0.raw["taskRoutes"] = .object(routes)
                } })
    }
}

// MARK: - 外观

struct AppearanceView: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                Picker("主题", selection: binding) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("跟随系统时，随手机的深色模式切换。")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("主题")
    }

    static func label(_ s: AppSettings) -> String {
        s.themeFollowsSystem ? "跟随系统" : (s.theme == "dark" ? "深色" : "浅色")
    }

    static func scheme(_ s: AppSettings) -> ColorScheme? {
        s.themeFollowsSystem ? nil : (s.theme == "dark" ? .dark : .light)
    }

    private var binding: Binding<String> {
        Binding(get: { model.s.themeFollowsSystem ? "system" : model.s.theme },
                set: { v in model.update {
                    if v == "system" {
                        $0.raw["themeFollowSystem"] = .bool(true)
                    } else {
                        $0.raw["themeFollowSystem"] = .bool(false)
                        $0.raw["theme"] = .string(v)
                    }
                } })
    }
}
