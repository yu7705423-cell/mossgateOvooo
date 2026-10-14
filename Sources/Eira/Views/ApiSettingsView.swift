import SwiftUI

/// 「设置 - 接口」：对话接口的几套配置，以及哪套是主用、哪套是副用。
/// 存在 settings.services.chat 里，和网页版同一形状，导入的备份里带了接口就直接能用。
struct ApiSettingsView: View {
    @State private var settings = AppSettings.load()
    @State private var editing: EditTarget?
    @State private var problem: String?

    struct EditTarget: Identifiable {
        let id: String
        let isNew: Bool
    }

    var body: some View {
        Form {
            Section {
                ForEach(settings.chatPresets) { p in
                    Button { editing = EditTarget(id: p.id, isNew: false) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p.name.isEmpty ? "未命名" : p.name).foregroundStyle(Theme.bubbleTheirsText)
                                Spacer()
                                if p.id == settings.mainPreset?.id { tag("主用") }
                                if p.id == settings.fallbackPreset?.id { tag("副用") }
                            }
                            Text(p.usable ? "\(p.provider == .anthropic ? "Anthropic" : "OpenAI 兼容") \u{00B7} \(p.model)" : "密钥或模型未填写，不可用")
                                .font(.footnote).foregroundStyle(p.usable ? Theme.secondaryText : Theme.danger)
                        }
                    }
                }
                Button("添加一套接口") { addPreset() }
            } header: {
                Text("对话接口")
            } footer: {
                Text("聊天回复使用主用；其余后台任务使用副用，未设副用时使用主用。")
            }

            if let problem {
                Section { Text(problem).foregroundStyle(Theme.danger) }
            }
        }
        .navigationTitle("接口")
        .sheet(item: $editing, onDismiss: { settings = AppSettings.load(); SettingsModel.shared.reload() }) { target in
            NavigationStack {
                PresetEditor(presetId: target.id, isNew: target.isNew)
            }
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.tertiaryText))
    }

    private func addPreset() {
        editing = EditTarget(id: Ids.make("svc"), isNew: true)
    }
}

/// 编辑一套对话接口。改的是 presets 里那一项的几个字段，其余字段（网页版另存的 siteUrl、recentModels……）原样留着。
struct PresetEditor: View {
    let presetId: String
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var provider = "anthropic"
    @State private var baseUrl = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var siteUrl = ""
    @State private var topupUrl = ""
    @State private var isMain = false
    @State private var isFallback = false
    @State private var confirmDelete = false
    @State private var problem: String?
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOk = false

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name)
                Picker("格式", selection: $provider) {
                    Text("Anthropic").tag("anthropic")
                    Text("OpenAI 兼容").tag("openai")
                }
            }
            Section {
                TextField(provider == "anthropic" ? "https://api.anthropic.com" : "https://api.openai.com/v1", text: $baseUrl)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("密钥", text: $apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("模型", text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("地址、密钥与模型")
            } footer: {
                Text("地址留空时使用该格式的官方地址。密钥只保存在本机。")
            }
            Section {
                TextField("站点链接", text: $siteUrl)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("充值链接", text: $topupUrl)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            } header: {
                Text("站点与充值")
            } footer: {
                Text("回复失败时，失败的那一条下方给出「打开站点」；余额不足时给出「去充值」。充值链接未填写时使用站点链接。")
            }
            Section {
                Button(testing ? "连接中" : "测试连接", action: test).disabled(testing)
                if let testResult {
                    Text(testResult).font(.footnote).foregroundStyle(testOk ? Theme.secondaryText : Theme.danger)
                }
            } footer: {
                Text("用当前填写的内容发送一次极短的请求，确认地址、密钥与模型可用。计入当天的请求次数。")
            }
            Section {
                Toggle("设为主用", isOn: $isMain)
                Toggle("设为副用", isOn: $isFallback)
            }
            if !isNew {
                Section {
                    Button("删除这套接口", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText)
                }
            }
            if let problem {
                Section { Text(problem).foregroundStyle(Theme.danger) }
            }
        }
        .navigationTitle(isNew ? "添加接口" : "编辑接口")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .confirmationDialog("删除后无法恢复。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: remove)
        }
        .onAppear(perform: load)
    }

    private func test() {
        let p = ChatPreset(json: [
            "id": .string(presetId), "name": .string(name), "provider": .string(provider),
            "baseUrl": .string(baseUrl.trimmingCharacters(in: .whitespaces)),
            "apiKey": .string(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)),
            "model": .string(model.trimmingCharacters(in: .whitespaces)),
        ])
        guard p.usable else { testResult = "密钥或模型未填写。"; testOk = false; return }
        testing = true
        testResult = nil
        Task {
            let (text, ok) = await ConnTest.run(p)
            await MainActor.run { testResult = text; testOk = ok; testing = false }
        }
    }

    private var chatJSON: [String: JSONValue] {
        AppSettings.load().raw["services"]?.object?["chat"]?.object ?? [:]
    }

    private func load() {
        let s = AppSettings.load()
        isMain = s.mainPreset?.id == presetId || (isNew && s.chatPresets.isEmpty)
        isFallback = s.fallbackPreset?.id == presetId
        guard let p = s.chatPresets.first(where: { $0.id == presetId }) else { return }
        name = p.name; provider = p.provider.rawValue; baseUrl = p.baseUrl; apiKey = p.apiKey; model = p.model
        siteUrl = p.siteUrl; topupUrl = p.topupUrl
    }

    private func save() {
        guard var s = try? AppSettings.loadForWrite() else { problem = "设置读取失败，未保存。"; return }
        var services = s.raw["services"]?.object ?? [:]
        var chat = services["chat"]?.object ?? [:]
        var list = chat["presets"]?.array ?? []
        let fields: [String: JSONValue] = [
            "id": .string(presetId),
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "provider": .string(provider),
            "baseUrl": .string(baseUrl.trimmingCharacters(in: .whitespaces)),
            "apiKey": .string(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)),
            "model": .string(model.trimmingCharacters(in: .whitespaces)),
            "siteUrl": .string(siteUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
            "topupUrl": .string(topupUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        if let i = list.firstIndex(where: { $0["id"]?.string == presetId }), case .object(var old) = list[i] {
            old.merge(fields) { _, new in new }
            list[i] = .object(old)
        } else {
            var fresh = fields
            fresh["effort"] = .string("")
            fresh["temperature"] = .number(0.9)
            list.append(.object(fresh))
        }
        chat["presets"] = .array(list)
        if isMain { chat["activeId"] = .string(presetId) }
        else if chat["activeId"]?.string == presetId { chat["activeId"] = .null }
        if isFallback { chat["fallbackId"] = .string(presetId) }
        else if chat["fallbackId"]?.string == presetId { chat["fallbackId"] = .null }
        services["chat"] = .object(chat)
        s.raw["services"] = .object(services)
        do { try s.save(); dismiss() }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    private func remove() {
        guard var s = try? AppSettings.loadForWrite() else { problem = "设置读取失败，未删除。"; return }
        var services = s.raw["services"]?.object ?? [:]
        var chat = chatJSON
        chat["presets"] = .array((chat["presets"]?.array ?? []).filter { $0["id"]?.string != presetId })
        if chat["activeId"]?.string == presetId { chat["activeId"] = .null }
        if chat["fallbackId"]?.string == presetId { chat["fallbackId"] = .null }
        services["chat"] = .object(chat)
        s.raw["services"] = .object(services)
        do { try s.save(); dismiss() }
        catch { problem = "删除失败：\(error.localizedDescription)" }
    }
}
