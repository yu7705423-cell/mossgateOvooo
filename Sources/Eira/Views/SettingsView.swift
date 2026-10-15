import SwiftUI

/// 「设置」根页。只放全局的东西：接口与服务、用量、外观、存储（网页版第 5 条）。
/// 排法照网页版新版根页（4.528）：主用接口一张状态卡，其余分组；一行只写名字和当前状态。
struct SettingsView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var hero = true

    var body: some View {
        NavigationStack {
            List {
                HeroHeader(eyebrow: "SETTINGS", title: "设置", shown: $hero)
                Section {
                    NavigationLink { ServicesView() } label: { apiCard }
                        .listRowBackground(Theme.surface2)
                }
                Section {
                    NavigationLink { UsageLimitsView() } label: {
                        row("用量与上限", "filter", ExtraCalls.active(model.s).isEmpty ? "无额外调用" : "额外调用 \(ExtraCalls.active(model.s).count) 项")
                    }
                } header: { groupTitle("对话") }
                Section {
                    NavigationLink { AppearanceView() } label: {
                        row("主题", "grid", AppearanceView.label(model.s))
                    }
                    NavigationLink { NotifyView() } label: {
                        row("消息通知", "bell", Notifier.isOn(model.s) ? "开启" : "关闭")
                    }
                    NavigationLink { BgPushView() } label: {
                        row("后台消息", "cloud", BgPush.isOn(model.s) ? "开启" : "关闭")
                    }
                } header: { groupTitle("外观与提醒") }
                Section {
                    NavigationLink { StorageView() } label: { row("存储与备份", "database", "") }
                } header: { groupTitle("数据") }
                Section {
                    NavigationLink { HelpView() } label: { row("说明书", "notes", "") }
                    NavigationLink { FeedbackView() } label: { row("问题反馈", "alert", "") }
                } header: {
                    groupTitle("关于")
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.sp4) {
                        HelpNote("角色读到的世界书、记忆、预设、能力在「设定集」中。")
                            .foregroundStyle(Theme.text2)
                        Text("Eiraowo · 本地运行，数据只存在这台设备上\n版本 \(Self.version)")
                            .foregroundStyle(Theme.text3)
                    }
                    .font(.system(size: 12))
                    .lineSpacing(4)
                    .padding(.top, Theme.sp4)
                }
            }
            .heroTitle("设置", heroShown: hero)
            .onAppear { model.reload() }
        }
    }

    /// 主用接口那张状态卡（.stn-api）：浅灰块，宋体接口名，下面一条细线隔开副用与服务数
    private var apiCard: some View {
        let p = model.s.mainPreset
        let services = ServicesView.configuredCount(model.s)
        return VStack(alignment: .leading, spacing: 2) {
            Text("主用接口").font(.system(size: 12)).kerning(0.5).foregroundStyle(Theme.text2)
            Text(p.map { $0.name.isEmpty ? "未命名接口" : $0.name } ?? "尚未配置")
                .font(Theme.serif(20)).padding(.top, Theme.sp1)
            Text(p.map { $0.model.isEmpty ? "未选模型" : $0.model } ?? "配置后才能对话")
                .font(.system(size: 14)).foregroundStyle(Theme.text2)
            Divider().overlay(Theme.border).padding(.top, Theme.sp3)
            HStack {
                if p != nil {
                    Text([model.s.fallbackPreset.map { "副用 \($0.name.isEmpty ? "未命名接口" : $0.name)" }, "已配置 \(services) 项服务"]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                Spacer()
                Text(p == nil ? "去配置" : "全部服务").fontWeight(.medium).foregroundStyle(Theme.text)
            }
            .font(.system(size: 13)).foregroundStyle(Theme.text2)
            .padding(.top, Theme.sp2)
        }
        .padding(.vertical, Theme.sp2)
    }

    private func groupTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).kerning(0.5).foregroundStyle(Theme.text2).textCase(nil)
    }

    private func row(_ title: String, _ icon: String, _ value: String) -> some View {
        HStack(spacing: Theme.sp3) {
            SvgIcon(name: icon, size: 19, color: Theme.text2)
            Text(title)
            Spacer()
            if !value.isEmpty { Text(value).font(.system(size: 13)).foregroundStyle(Theme.text3).lineLimit(1) }
        }
        .frame(minHeight: 54 - 16)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?")（\(info["CFBundleVersion"] as? String ?? "?")）"
    }
}

// MARK: - 接口与服务

struct ServicesView: View {
    @ObservedObject private var model = SettingsModel.shared

    /// 设置根页那张卡上的「已配置几项服务」：这一页里填好了的几项
    static func configuredCount(_ s: AppSettings) -> Int {
        [s.mainPreset != nil, s.memoryPreset != nil, s.imageReady, !Netease.userCookie(s).isEmpty,
         s.voiceEnabled && s.voiceReady, s.visionMode == "api" && s.visionPreset != nil, s.asrReady, Weather.ready(s)].filter { $0 }.count
    }

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
            Section("角色发送的内容") {
                NavigationLink { ImageSettingsView() } label: {
                    status("生图", model.s.activeImage.map { "\($0.name) · \($0.model.isEmpty ? "未填模型" : $0.model)" }, model.s.imageReady ? "" : "未配置")
                }
                NavigationLink { MusicSettingsView() } label: {
                    status("音乐服务", nil, Netease.userCookie(model.s).isEmpty ? "未登录" : (Netease.config(model.s)["nickname"]?.string ?? "已登录"))
                }
                NavigationLink { VoiceSettingsView() } label: {
                    status("语音合成", model.s.voiceEnabled ? model.s.activeVoice?.name : nil,
                           !model.s.voiceEnabled ? "关闭" : model.s.voiceReady ? "" : "未填全")
                }
            }
            Section("识别你发送的内容") {
                NavigationLink { VisionSettingsView() } label: {
                    status("识图", model.s.visionMode == "api" ? model.s.visionPreset?.model : nil, visionValue)
                }
                NavigationLink { AsrSettingsView() } label: {
                    status("语音识别", model.s.asrReady ? model.s.asrConfig["model"]?.string : nil, model.s.asrReady ? "" : "系统识别")
                }
            }
            Section("翻译") {
                NavigationLink { TranslateSettingsView() } label: {
                    status("翻译", model.s.translateMode == "api" ? model.s.translatePreset?.model : nil,
                           model.s.translateMode == "api" ? "单独接口" : "随回复一起")
                }
            }
            Section("其他") {
                NavigationLink { WeatherSettingsView() } label: {
                    status("和风天气", nil, Weather.ready(model.s) ? "" : "未配置")
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
    /// 测试连接发的是一条对话请求。不是对话端点的（语音识别）不给这个按钮
    var showTest = true
    var endpointNote = "OpenAI 兼容的 chat/completions 端点。地址留空时使用 https://api.openai.com/v1，中转站填写至 /v1 为止。"

    init(name: String, modelHint: String, showTest: Bool = true, endpointNote: String? = nil, preset: @escaping () -> ChatPreset?) {
        self.name = name
        self.modelHint = modelHint
        self.showTest = showTest
        if let endpointNote { self.endpointNote = endpointNote }
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
            HelpNote("\(endpointNote)选择已有的接口时，地址与密钥从那一套读取，模型仍在这里填写。\(modelHint)")
        }
        if showTest {
        Section {
            Button(testing ? "连接中" : "测试连接", action: test).disabled(testing)
            if let result {
                Text(result).font(.footnote).foregroundStyle(resultIsError ? Theme.danger : Theme.secondaryText)
            }
        } footer: {
            Text("测试计入当天的请求次数。")
            HelpNote("发送一次极短的请求，确认地址、密钥与模型可用。计入当天的请求次数。", title: "测试连接")
        }
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
                HelpNote(isApi
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
                    HelpNote("图片随当前这一轮的请求直接发给聊天模型，看过一次后不再重复传图。要求聊天模型本身能看图，否则请求会报错。")
                case "api":
                    Text("每张图调用一次识图接口。")
                    HelpNote("图片发出后先交给下面这套接口读成一段描述，描述随消息一起进入上下文。每张图调用一次识图接口。聊天模型本身不能看图时用这一档。")
                default:
                    HelpNote("不识别。图片仍可正常发送与查看，角色只知道你发了一张图，不知道图上有什么。")
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

/// 译文怎么来（网页版 services.translate）：随回复一起写，或者单独的翻译接口另翻
struct TranslateSettingsView: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                Picker("译文怎么来", selection: modeBinding) {
                    Text("随回复一起").tag("inline")
                    Text("单独的接口").tag("api")
                }
                .pickerStyle(.segmented)
            } footer: {
                if model.s.service("translate")["mode"]?.string == "api" {
                    Text("每轮回复之后多调用一次翻译接口。")
                    HelpNote("设了翻译语言的会话，角色每说完一轮，把这一轮的文字、语音、旁白与心声一批交给下面这套接口翻译，只送要翻的句子与这段会话的翻译要求，人设、记忆与聊天记录不送。翻译失败不影响消息本身。下面这套没填全时，按「随回复一起」处理。消息上的「翻译」也走这套接口。", title: "单独的翻译接口")
                } else {
                    HelpNote("角色在同一次回复里给每条消息附上译文，不另调用接口。每段会话的翻译语言在会话设置的「翻译」里设置。", title: "随回复一起翻译")
                }
            }
            if model.s.service("translate")["mode"]?.string == "api" {
                ServiceConnSection(name: "translate", modelHint: "任意能对话的模型。") { model.s.translatePreset }
                Section {
                    Button("清空配置", role: .destructive) {
                        model.update { $0.setService("translate", ["apiKey": .string(""), "model": .string(""), "baseUrl": .string(""), "endpointId": .string("")]) }
                    }
                }
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("翻译")
    }

    private var modeBinding: Binding<String> {
        Binding(get: { model.s.service("translate")["mode"]?.string == "api" ? "api" : "inline" },
                set: { v in model.update { $0.setService("translate", ["mode": .string(v)]) } })
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
                HelpNote("为下面几项任务单独指定接口。只改变用哪一套，不增加调用次数。选定的接口缺少密钥或模型时，按默认方式选择。原生版尚未提供的功能也列在这里，设定在功能提供后生效。", title: "任务用哪套接口")
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
                HelpNote("跟随系统时，随手机的深色模式切换。")
            }
            WallpaperSection()
            Section {
                Text("在主界面长按一个图标，可以更换它的图片、线条图标与名称。").font(.footnote).foregroundStyle(Theme.text2)
            } header: { Text("图标") }
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

/// 和风天气（网页版 settings/WeatherPage.js）。配好之后，开了当日日程、又在角色卡上填了「所在地区」的角色，
/// 排日程时查那座城市当天的预报。查天气不调模型接口
struct WeatherSettingsView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var host = ""
    @State private var key = ""
    @State private var city = ""
    @State private var out: String?
    @State private var busy = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("API Host，形如 abc1234xyz.re.qweatherapi.com", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onSubmit(save)
                SecureField("API KEY", text: $key).onSubmit(save)
                Button("保存", action: save)
            } footer: {
                HelpNote("API Host 在和风天气控制台的「设置」中查看，每个账号一个；旧的公共域名已逐步停用。API KEY 在控制台的「项目管理」中创建凭据时选择 API KEY。只保存在本机。", title: "和风天气")
            }
            Section {
                TextField("城市名，留空查询北京", text: $city)
                Button(busy ? "正在查询" : "查询") { test() }.disabled(busy || !Weather.ready(model.s))
                if let out { Text(out).font(.footnote).foregroundStyle(out.hasPrefix("查询失败") ? Theme.danger : Theme.secondaryText) }
            } header: { Text("测试查询") }
            Section {
                Button("清空配置", role: .destructive) {
                    model.update { $0.setService("qweather", ["host": .string(""), "key": .string(""), "cities": .object([:])]) }
                    host = ""; key = ""
                }
                .foregroundStyle(Theme.dangerText)
            } footer: {
                Text("查询天气不调用模型接口，用量计入和风天气账号自身的额度。")
                HelpNote("配置后，开启了当日日程、并在角色卡上填写了「所在地区」的角色，每天安排日程时查询该地当天的天气预报，写入日程的生成请求，并在当天的对话中一并告知角色。按城市名查询，查到的城市编号会记住，不重复查询。「日常」里角色的今天页可以单独刷新天气。", title: "和风天气")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("和风天气")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let c = Weather.config(model.s)
            host = c["host"]?.string ?? ""; key = c["key"]?.string ?? ""
        }
    }

    private func save() {
        let h = host.trimmingCharacters(in: .whitespaces), k = key.trimmingCharacters(in: .whitespaces)
        let old = Weather.config(model.s)["host"]?.string ?? ""
        model.update {
            var patch: [String: JSONValue] = ["host": .string(h), "key": .string(k)]
            if h != old { patch["cities"] = .object([:]) }   // 换了账号，记下的城市编号作废
            $0.setService("qweather", patch)
        }
        out = model.problem == nil ? "已保存" : nil
    }

    private func test() {
        save()
        busy = true
        out = nil
        let name = city.trimmingCharacters(in: .whitespaces).isEmpty ? "北京" : city
        Task { @MainActor in
            do {
                let w = try await Weather.forecast(name)
                out = "\(Weather.label(w))（\(w.date)）"
            } catch { out = "查询失败：\(error.localizedDescription)" }
            model.reload()
            busy = false
        }
    }
}
