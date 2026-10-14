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
    /// 站点与充值链接（网页版 siteUrl / topupUrl）。回复失败时给「打开站点」或「去充值」
    var siteUrl: String
    var topupUrl: String

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
        siteUrl = json["siteUrl"]?.string ?? ""
        topupUrl = json["topupUrl"]?.string ?? ""
    }

    /// 补上协议头再认（网页版 services.linkOf）。认不出回 nil
    static func link(_ raw: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let u = t.range(of: "^[a-z][a-z0-9+.-]*:", options: [.regularExpression, .caseInsensitive]) != nil ? t : "https://\(t)"
        guard let url = URL(string: u), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }
    var site: URL? { Self.link(siteUrl) }
    /// 没填充值链接时退回站点
    var topup: URL? { Self.link(topupUrl) ?? site }
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

    /// 要改了再写回去的地方用这个：读失败时抛出，而不是拿空的设置顶上 —— 拿空的写回去会把接口与密钥全部抹掉
    /// （网页版第 20 条：开机不许拿读失败时的默认值回写）。
    static func loadForWrite() throws -> AppSettings {
        AppSettings(raw: try Database.shared.kv(KVKey.settings)?.object ?? [:])
    }

    func save() throws {
        try Database.shared.setKV(KVKey.settings, .object(raw))
    }

    var services: [String: JSONValue] { raw["services"]?.object ?? [:] }
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

    /// 自建的接口来源与聊天预设共用一个 id 空间：服务记着 endpointId 时，地址与密钥从那一条上取，模型仍是服务自己的
    /// （网页版 services.js 的 resolved / sourceOf）。指向的那条删掉了就用服务自己填的。
    func service(_ name: String) -> [String: JSONValue] {
        var cfg = services[name]?.object ?? [:]
        guard let id = cfg["endpointId"]?.string, !id.isEmpty else { return cfg }
        let own = services["endpoints"]?.array?.first { $0["id"]?.string == id }?.object
        let src = own ?? (chat["presets"]?.array?.first { $0["id"]?.string == id }?.object)
        if let src {
            cfg["baseUrl"] = src["baseUrl"] ?? .string("")
            cfg["apiKey"] = src["apiKey"] ?? .string("")
        }
        return cfg
    }

    /// 改 services 里的一项，只动给出的几个字段。
    mutating func setService(_ name: String, _ patch: [String: JSONValue]) {
        var all = services
        var cfg = all[name]?.object ?? [:]
        cfg.merge(patch) { _, new in new }
        all[name] = .object(cfg)
        raw["services"] = .object(all)
    }

    struct Source: Identifiable, Sendable {
        let id: String
        let name: String
    }

    /// 可以指过去的来源：自建的接口在前，聊天预设在后。
    var endpointSources: [Source] {
        let own = (services["endpoints"]?.array ?? []).compactMap { e -> Source? in
            guard let id = e["id"]?.string else { return nil }
            return Source(id: id, name: e["name"]?.string ?? "未命名")
        }
        return own + chatPresets.map { Source(id: $0.id, name: $0.name.isEmpty ? "未命名接口" : $0.name) }
    }

    /// 记忆接口：mode 是 'api' 且填全了才用，否则跟副用。
    var memoryPreset: ChatPreset? {
        let m = service("memory")
        guard m["mode"]?.string == "api" else { return nil }
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
    var visionMode: String {
        let m = services["vision"]?.object?["mode"]?.string
        return m == "chat" || m == "api" ? m! : "off"
    }

    /// 单独的识图接口。OpenAI 兼容，填全了密钥与模型才有。
    var visionPreset: ChatPreset? {
        var json = service("vision")
        json["id"] = .string("vision")
        json["name"] = .string("识图接口")
        json["provider"] = .string("openai")
        json["temperature"] = .null
        let p = ChatPreset(json: json)
        return p.usable ? p : nil
    }

    /// 图片到底能不能被看见。
    var visionActive: Bool { visionMode == "chat" || (visionMode == "api" && visionPreset != nil) }

    /// 深色或浅色（网页版 settings.theme，light | dark）。
    var theme: String { raw["theme"]?.string == "dark" ? "dark" : "light" }
    /// 跟随系统是原生版自己的一项，另存一个键，不往 theme 里写网页版不认得的值。
    /// 没存过 theme 的（新装、从空白开始）默认跟随系统；导入的备份里有 theme 就照它。
    var themeFollowsSystem: Bool { raw["themeFollowSystem"]?.bool ?? (raw["theme"] == nil) }

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
