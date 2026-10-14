import Foundation

/// 状态栏（网页版 system/statusbar.js，ARCHITECTURE 4.399）。设置存在会话上（chat.statusBar.online），与网页版同一格式。
/// 原生版暂无线下，只读写线上那一套；线下那一套原样留着。
///
/// 三种栏目：
///     record  有记录的：程序读现有记录显示，模型不写（时间；天气、身体状况、今天穿的原生版尚无记录，留空）
///     var     现成的变量：模型每轮写（所在地、心情、正在做的事）
///     custom  自己加的：名称、说明、初始值、变化规则，模型每轮写；可以显示成进度条
///
/// 写法：回复末尾一段 [状态栏] … [/状态栏]，每行「名称：值」。和回复同一次调用，不多调接口。
/// 状态块不落成气泡；这一轮存完后把当时的值存在最后一条消息的 sbar 上（不叫 status：消息本来有 status）。
/// 一律默认关，总开关也默认关。注入给模型的只有格式与用户自己写的说明、规则，不写「该怎么变」。
enum StatusBar {
    static let mode = "online"

    static let places: [(id: String, label: String)] = [
        ("first-top", "第一条上方"), ("first-bottom", "第一条下方"), ("last-top", "最后一条上方"), ("last-bottom", "最后一条下方"),
    ]

    struct Item: Identifiable, Equatable {
        var id: String
        var kind: String          // record / var / custom
        var on: Bool
        var label: String
        var desc = ""
        var ask = ""
        var initial = ""
        var rule = ""
        var show = "text"         // text / bar
        var min: Double = 0
        var max: Double = 100

        var custom: Bool { kind == "custom" }
        var writtenByModel: Bool { kind == "var" || kind == "custom" }
        /// 原生版读得出值的：时间与所有要模型写的
        var supported: Bool { kind != "record" || id == "time" }
    }

    static let builtin: [Item] = [
        Item(id: "time", kind: "record", on: false, label: "时间", desc: "读取这段会话的时间设置"),
        Item(id: "weather", kind: "record", on: false, label: "天气", desc: "读取该角色当天的天气预报"),
        Item(id: "health", kind: "record", on: false, label: "身体状况", desc: "读取该角色当天的身体状况记录"),
        Item(id: "outfit", kind: "record", on: false, label: "今天穿的", desc: "读取衣帽间里该角色今天穿着的衣物"),
        Item(id: "place", kind: "var", on: false, label: "所在地", desc: "每轮由模型填写", ask: "where you are at this moment"),
        Item(id: "mood", kind: "var", on: false, label: "心情", desc: "每轮由模型填写", ask: "your mood at this moment"),
        Item(id: "doing", kind: "var", on: false, label: "正在做的事", desc: "每轮由模型填写", ask: "what you are doing at this moment"),
    ]

    struct Config: Equatable {
        var on = false
        var carry = true
        var at = "last-bottom"
        var items: [Item] = []
    }

    private static func item(_ raw: JSONValue) -> Item? {
        guard let o = raw.object else { return nil }
        let id = o["id"]?.string ?? ""
        if var b = builtin.first(where: { $0.id == id }) {
            b.on = o["on"]?.bool == true
            return b
        }
        let label = (o["label"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard o["kind"]?.string == "custom", !label.isEmpty else { return nil }
        let mn = o["min"]?.number ?? 0
        let mx = o["max"]?.number ?? 100
        return Item(id: id, kind: "custom", on: o["on"]?.bool != false, label: String(label.prefix(20)),
                    desc: (o["desc"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    initial: (o["init"]?.string ?? o["init"]?.number.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    rule: (o["rule"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    show: o["show"]?.string == "bar" ? "bar" : "text", min: mn, max: mx != mn ? mx : 100)
    }

    /// 这段会话的设置。存着的顺序为准，没有的现成栏目补在后面（关着）
    static func config(_ chat: Chat) -> Config {
        let raw = chat.row["statusBar"]?.object?[mode]?.object ?? [:]
        let stored = (raw["items"]?.array ?? []).compactMap(item)
        let seen = Set(stored.map(\.id))
        var c = Config()
        c.on = raw["on"]?.bool == true
        c.carry = raw["carry"]?.bool != false
        let at = ["before": "first-top", "after": "last-bottom"][raw["at"]?.string ?? ""] ?? (raw["at"]?.string ?? "")
        c.at = places.contains(where: { $0.id == at }) ? at : "last-bottom"
        c.items = stored + builtin.filter { !seen.contains($0.id) }
        return c
    }

    private static func plain(_ it: Item) -> JSONValue {
        guard it.custom else { return .object(["id": .string(it.id), "on": .bool(it.on)]) }
        return .object(["id": .string(it.id), "kind": .string("custom"), "on": .bool(it.on), "label": .string(it.label),
                        "desc": .string(it.desc), "init": .string(it.initial), "rule": .string(it.rule),
                        "show": .string(it.show), "min": .number(it.min), "max": .number(it.max)])
    }

    static func save(_ chatId: String, _ cfg: Config) throws {
        guard var chat = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
        var all = chat.row["statusBar"]?.object ?? [:]
        all[mode] = .object(["on": .bool(cfg.on), "carry": .bool(cfg.carry), "at": .string(cfg.at), "items": .array(cfg.items.map(plain))])
        chat.row["statusBar"] = .object(all)
        chat.row.touch()
        try Repo.save(chat)
    }

    static func newCustomId() -> String { "c_" + String(Int(Date().millis), radix: 36) + String(Int.random(in: 0..<46656), radix: 36) }

    /// 开着、并且至少有一个开着的栏目
    static func active(_ chat: Chat) -> Bool {
        let c = config(chat)
        return c.on && c.items.contains { $0.on }
    }

    // MARK: - 提示词那一段

    /// 上一轮存下的状态：这段会话里最后一条带 sbar 的消息
    static func last(_ msgs: [Message]) -> [(id: String, label: String, value: String)] {
        guard let m = msgs.last(where: { $0.row["sbar"]?.object != nil }) else { return [] }
        return values(m)
    }

    static func values(_ m: Message) -> [(id: String, label: String, value: String)] {
        (m.row["sbar"]?.object?["items"]?.array ?? []).compactMap { v in
            guard let o = v.object else { return nil }
            return (o["id"]?.string ?? "", o["label"]?.string ?? "", o["value"]?.string ?? "")
        }
    }

    /// 交给模型的那一段。没有要模型写的栏目就不出现
    static func piece(_ chat: Chat, msgs: [Message], names: [String: String], settings s: AppSettings) -> String {
        let cfg = config(chat)
        guard cfg.on else { return "" }
        let asked = cfg.items.filter { $0.on && $0.writtenByModel }
        guard !asked.isEmpty else { return "" }
        let lines = asked.map { "\($0.label)：…" }.joined(separator: "\n")
        let items = asked.map { it -> String in
            guard it.custom else { return "- \(it.label): \(Templates.fill(it.ask, names))" }
            var bits = ["- \(it.label): \(it.desc.isEmpty ? "(no description)" : it.desc)"]
            if !it.rule.isEmpty { bits.append("  Rule: \(it.rule)") }
            return bits.joined(separator: "\n")
        }.joined(separator: "\n")
        let prevVals = last(msgs)
        let prev: [String] = cfg.carry && !prevVals.isEmpty ? asked.compactMap { it in
            if let hit = prevVals.first(where: { $0.id == it.id || $0.label == it.label }), !hit.value.isEmpty { return "\(it.label)：\(hit.value)" }
            return it.custom && !it.initial.isEmpty ? "\(it.label)：\(it.initial)" : nil
        } : []
        let starts = asked.filter { $0.custom && !$0.initial.isEmpty }.map { "\($0.label)：\($0.initial)" }
        let current = !prev.isEmpty ? Templates.render("skeleton.status-current", ["lines": prev.joined(separator: "\n")], settings: s)
            : !starts.isEmpty ? Templates.render("skeleton.status-start", ["lines": starts.joined(separator: "\n")], settings: s) : ""
        let lang = chat.row.string("translateTo")
        let tail = lang.isEmpty ? "" : "\n\n" + Templates.render("skeleton.status-lang", ["lang": lang], settings: s)
        return Templates.render("skeleton.status", ["lines": lines, "items": items, "current": current.isEmpty ? "" : "\n\n\(current)"], settings: s) + tail
    }

    // MARK: - 读回来

    /// 把状态块从回复里拿出来。没有就 vals 为 nil
    static func lift(_ raw: String) -> (text: String, vals: [String: String]?) {
        guard let re = try? NSRegularExpression(pattern: #"\n?[ \t]*\[状态栏\][ \t]*\n?([\s\S]*?)(?:\[/状态栏\]|$)"#),
              let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let whole = Range(m.range, in: raw), let body = Range(m.range(at: 1), in: raw) else { return (raw, nil) }
        var vals: [String: String] = [:]
        let lineRe = try? NSRegularExpression(pattern: #"^\s*[-·•]?\s*([^:：\n]{1,20})\s*[:：]\s*(.*?)\s*$"#)
        for line in raw[body].split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            guard let lm = lineRe?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let k = Range(lm.range(at: 1), in: line), let v = Range(lm.range(at: 2), in: line), !line[v].isEmpty else { continue }
            vals[line[k].trimmingCharacters(in: .whitespaces)] = String(line[v])
        }
        let text = (String(raw[..<whole.lowerBound]) + String(raw[whole.upperBound...]))
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, vals)
    }

    /// 时间那一栏：这段会话的时间设置（虚拟、固定），角色那边的时区
    static func timeText(_ char: Character?, settings s: AppSettings, now real: Date = Date()) -> String {
        let n = Clock.now(s, real: real)
        let full = TimeText.format(n, zone: Clock.zone(Clock.charZone(char, s)))
        // 2026-09-17 周三 14:30 → 09-17 周三 14:30
        return String(full.dropFirst(5))
    }

    /// 这一轮要存下的状态：开着的栏目，按设置里的先后。模型写的按名称认，记录的当场读
    static func snapshot(_ chat: Chat, vals: [String: String]?, char: Character?, settings s: AppSettings, now: Date = Date()) -> JSONValue? {
        let cfg = config(chat)
        guard cfg.on else { return nil }
        var items: [JSONValue] = []
        for it in cfg.items where it.on {
            let value: String
            if it.kind == "record" { value = it.id == "time" ? timeText(char, settings: s, now: now) : "" }
            else { value = (vals?[it.label] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            if !value.isEmpty { items.append(.object(["id": .string(it.id), "label": .string(it.label), "value": .string(value)])) }
        }
        return items.isEmpty ? nil : .object(["at": .number(now.millis), "items": .array(items)])
    }

    /// 进度条那一格占多少（0 到 100）。认不出数字就不画
    static func percent(_ it: Item, _ value: String) -> Int? {
        let digits = value.filter { "0123456789.+-".contains($0) }
        guard let n = Double(digits), it.max != it.min else { return nil }
        return Swift.max(0, Swift.min(100, Int(((n - it.min) / (it.max - it.min) * 100).rounded())))
    }
}
