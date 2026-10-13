import Foundation

/// 一套对话接口。和网页版 `ai/services.js` 的 newChatPreset 同一形状，存在 settings.services.chat.presets 里。
struct ChatPreset: Identifiable, Equatable, Sendable {
    enum Provider: String, Sendable { case anthropic, openai }

    var id: String
    var name: String
    var provider: Provider
    var baseUrl: String
    var apiKey: String
    var model: String
    /// 只有 anthropic 用
    var effort: String
    /// 只有 openai 发
    var temperature: Double?
    /// 只有 openai 用：'system' 时历史中段的系统消息原样发，否则改成用户消息（网页版 midsystem.js）
    var midSystem: String

    /// 填全了密钥与模型才算能用（网页版 engine.js 的 usable）。
    var usable: Bool { !apiKey.isEmpty && !model.isEmpty }

    init(json: [String: JSONValue]) {
        id = json["id"]?.string ?? ""
        name = json["name"]?.string ?? ""
        // 网页版认不出的一律按 anthropic（providers/index.js）
        provider = Provider(rawValue: json["provider"]?.string ?? "") ?? .anthropic
        baseUrl = json["baseUrl"]?.string ?? ""
        apiKey = json["apiKey"]?.string ?? ""
        model = json["model"]?.string ?? ""
        effort = json["effort"]?.string ?? ""
        temperature = json["temperature"]?.number ?? (json["temperature"]?.isNull == true ? nil : 0.9)
        midSystem = json["midSystem"]?.string ?? ""
    }
}

/// settings 这一份 kv 的视图。只读原生版用得到的那几项，其余原样留在库里。
///
/// 网页版读设置时是 `{...DEFAULT_SETTINGS, ...stored}`：没存的一律取默认值。
/// 这里每一项的默认值都照抄 `src/system/db/defaults.js`。
struct AppSettings: Sendable {
    var raw: [String: JSONValue]

    static func load() -> AppSettings {
        AppSettings(raw: (try? Database.shared.kv(KVKey.settings))?.object ?? [:])
    }

    func save() throws {
        try Database.shared.setKV(KVKey.settings, .object(raw))
    }

    private var services: [String: JSONValue] { raw["services"]?.object ?? [:] }
    private var chat: [String: JSONValue] { services["chat"]?.object ?? [:] }

    var chatPresets: [ChatPreset] {
        (chat["presets"]?.array ?? []).compactMap { $0.object.map(ChatPreset.init(json:)) }
    }

    /// 主用。activeId 是 null 表示用户关掉了主用；没写这一项取第一套（网页版 services.js）。
    var mainPreset: ChatPreset? {
        let list = chatPresets
        switch chat["activeId"] {
        case .some(.null): return nil
        case .some(.string(let id)): return list.first { $0.id == id }
        default: return list.first
        }
    }

    /// 副用。
    var fallbackPreset: ChatPreset? {
        guard let id = chat["fallbackId"]?.string else { return nil }
        return chatPresets.first { $0.id == id }
    }

    /// 记忆接口：mode 是 'api' 且填全了才用，否则跟副用。
    var memoryPreset: ChatPreset? {
        guard let m = services["memory"]?.object, m["mode"]?.string == "api" else { return nil }
        var json = m
        json["id"] = .string("memory")
        json["name"] = .string("记忆接口")
        if json["provider"] == nil { json["provider"] = .string("openai") }
        let p = ChatPreset(json: json)
        return p.usable ? p : nil
    }

    /// 任务组改用的那一套（settings.taskRoutes）。'' 或没填全按默认规则走。
    func routedPreset(group: String) -> ChatPreset? {
        guard let pick = raw["taskRoutes"]?.object?[group]?.string, !pick.isEmpty else { return nil }
        let p: ChatPreset?
        switch pick {
        case "main": p = mainPreset
        case "fallback": p = fallbackPreset
        case "memory": p = memoryPreset
        default: p = chatPresets.first { $0.id == pick }
        }
        return p?.usable == true ? p : nil
    }

    /// 识图：'chat' 是把图原样交给聊天模型，'api' 是另一套识图接口，其余是关（网页版 services.js 的 visionMode）。
    /// 原生版还没有单独的识图接口，'api' 按关处理。
    var visionMode: String {
        services["vision"]?.object?["mode"]?.string == "chat" ? "chat" : "off"
    }

    // MARK: - 预设（网页版 presets.js）

    /// 预设里存的那几个键。会话选了别的预设时，这几个键换成那一套的值，其余设置不变。
    static let presetKeys = ["promptLayout", "promptCustom", "promptTemplates", "injectOrder",
                             "msgMin", "msgMax", "smsMin", "smsMax", "narrationMin", "synopsisMin", "synopsisMax",
                             "historyMode", "historyLimit", "historyTurns", "scanWindow", "contextBudget", "promptLean"]

    struct Preset: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    /// settings.presets 里的几套。一套都没存时界面上当作只有「默认」（网页版第一次打开不往库里写）。
    var presets: [Preset] {
        (raw["presets"]?.array ?? []).compactMap { p in
            guard let id = p["id"]?.string else { return nil }
            return Preset(id: id, name: p["name"]?.string ?? "未命名预设")
        }
    }

    /// 这段会话用的设置：会话选的预设不是当前全局那一套时，把那一套的值叠上去；缺的键用出厂值（网页版 settingsFor）。
    func forChat(_ chat: Chat) -> AppSettings {
        let id = chat.presetId
        guard !id.isEmpty, id != raw["presetActive"]?.string,
              let p = raw["presets"]?.array?.first(where: { $0["id"]?.string == id }) else { return self }
        let data = p["data"]?.object ?? [:]
        var out = self
        for k in Self.presetKeys { out.raw[k] = data[k] }
        return out
    }

    // MARK: - 花钱的旋钮（网页版 cost.js，CLAUDE.md 第 15 条）

    /// 自动重试最多几次。钳在 0 到 3，默认 0。
    var retryMax: Int { min(3, max(0, Int(raw["retryMax"]?.number ?? 0))) }
    /// 失败后换一套接口再试。默认关。
    var chatFallback: Bool { raw["chatFallback"]?.bool ?? false }
    /// 换接口最多换几套。0 表示其余的全试；不合法的值按 1。
    var failoverMax: Int {
        guard let n = raw["failoverMax"]?.number, n >= 0, n == n.rounded() else { return 1 }
        return Int(n)
    }
    /// 流式时两段之间最多等几秒；非流式乘 4。0 表示不限。
    var streamIdleSec: Double { raw["streamIdleSec"]?.number ?? 120 }
    var streams: Bool { (raw["streamMode"]?.string ?? "stream") != "once" }
    var promptCache: Bool { raw["promptCache"]?.bool ?? true }
    /// 后台任务的输出上限，0 表示不发这个字段。
    var taskMaxTokens: Int { Int(raw["taskMaxTokens"]?.number ?? 0) }
}
