import Foundation

/// 长篇的大纲（网页版 system/novel.js，ARCHITECTURE 4.263）。分三层：
///
///   总纲   主线、暗线、结局、关键转折、人物弧光      开书时一次请求（和卷纲一起）
///   卷纲   每卷的目标、起止章、这一卷揭晓什么
///   章纲   每章一行                                  按卷补：写到哪一卷生成哪一卷
///
/// 三档：可见 / 隐藏 / 无。隐藏只是界面上不显示，写作时照样注入；「揭晓到目前为止」只露已经写到的章。
/// 存在作品的 outline 字段上，结构与网页版一致。
enum Novel {
    static let VISIBLE = "visible", HIDDEN = "hidden", NONE = "none"
    static let modes: [(id: String, label: String, desc: String)] = [
        (VISIBLE, "可见", "生成后可以查看和修改"),
        (HIDDEN, "隐藏", "生成后存着、写作时使用，但不显示。可随时揭晓"),
        (NONE, "无大纲", "自由创作，每章只带前情"),
    ]

    struct Master: Equatable {
        var mainline = "", subline = "", ending = ""
        var twists: [String] = []
        var arcs: [String] = []
    }

    struct Volume: Equatable, Identifiable {
        var no: Int
        var title = "", goal = ""
        var from: Int, to: Int
        var reveal = ""
        var id: Int { no }
    }

    struct Line: Equatable, Identifiable {
        var no: Int
        var title = "", line = ""
        var id: Int { no }
    }

    struct Outline: Equatable {
        var mode = NONE
        var master: Master?
        var volumes: [Volume] = []
        var chapters: [Int: [Line]] = [:]
        var revealed = "none"
        var drift = false
        var madeAt: Double = 0
    }

    private static func str(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s)?: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let n)?: return n == n.rounded() ? String(Int(n)) : String(n)
        default: return ""
        }
    }

    private static func num(_ v: JSONValue?, _ d: Int = 0) -> Int {
        switch v {
        case .number(let n)?: return n.isFinite ? Int(n.rounded()) : d
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces)).map { Int($0.rounded()) } ?? d
        default: return d
        }
    }

    static func master(_ v: JSONValue?) -> Master? {
        guard let o = v?.object else { return nil }
        return Master(mainline: str(o["mainline"]), subline: str(o["subline"]), ending: str(o["ending"]),
                      twists: (o["twists"]?.array ?? []).map { str($0) }.filter { !$0.isEmpty },
                      arcs: (o["arcs"]?.array ?? []).map { str($0) }.filter { !$0.isEmpty })
    }

    static func volumes(_ v: JSONValue?) -> [Volume] {
        (v?.array ?? []).enumerated().compactMap { i, x in
            guard let o = x.object else { return nil }
            let vol = Volume(no: num(o["no"], i + 1), title: str(o["title"]), goal: str(o["goal"]), from: num(o["from"], 1), to: num(o["to"], 1), reveal: str(o["reveal"]))
            return vol.to >= vol.from ? vol : nil
        }
    }

    static func lines(_ v: JSONValue?) -> [Line] {
        (v?.array ?? []).compactMap { x in
            guard let o = x.object else { return nil }
            let l = Line(no: num(o["no"]), title: str(o["title"]), line: str(o["line"]))
            return l.no > 0 ? l : nil
        }
    }

    /// 读出一份干净的大纲：坏值一律补齐
    static func outlineOf(_ w: Row?) -> Outline {
        let o = w?["outline"]?.object ?? [:]
        var out = Outline()
        let mode = o["mode"]?.string ?? NONE
        out.mode = [VISIBLE, HIDDEN, NONE].contains(mode) ? mode : NONE
        out.master = master(o["master"])
        out.volumes = volumes(o["volumes"])
        for (k, list) in o["chapters"]?.object ?? [:] {
            guard list.array != nil, let n = Int(k) else { continue }
            out.chapters[n] = lines(list)
        }
        let r = o["revealed"]?.string ?? "none"
        out.revealed = ["none", "written", "all"].contains(r) ? r : "none"
        out.drift = o["drift"]?.bool == true
        out.madeAt = Double(num(o["madeAt"]))
        return out
    }

    static func json(_ m: Master?) -> JSONValue {
        guard let m else { return .null }
        return .object(["mainline": .string(m.mainline), "subline": .string(m.subline), "ending": .string(m.ending),
                        "twists": .array(m.twists.map { .string($0) }), "arcs": .array(m.arcs.map { .string($0) })])
    }

    static func json(_ v: Volume) -> JSONValue {
        .object(["no": .number(Double(v.no)), "title": .string(v.title), "goal": .string(v.goal),
                 "from": .number(Double(v.from)), "to": .number(Double(v.to)), "reveal": .string(v.reveal)])
    }

    static func json(_ l: Line) -> JSONValue {
        .object(["no": .number(Double(l.no)), "title": .string(l.title), "line": .string(l.line)])
    }

    static func json(_ o: Outline) -> JSONValue {
        var chs: [String: JSONValue] = [:]
        for (k, list) in o.chapters { chs[String(k)] = .array(list.map { json($0) }) }
        return .object(["mode": .string(o.mode), "master": json(o.master), "volumes": .array(o.volumes.map { json($0) }),
                        "chapters": .object(chs), "revealed": .string(o.revealed), "drift": .bool(o.drift), "madeAt": .number(o.madeAt)])
    }

    static func blank(_ mode: String = NONE) -> JSONValue {
        var o = Outline()
        o.mode = [VISIBLE, HIDDEN, NONE].contains(mode) ? mode : NONE
        return json(o)
    }

    static func hasOutline(_ w: Row?) -> Bool { let o = outlineOf(w); return o.mode != NONE && o.master != nil }

    /// 改大纲：读出干净的一份、改、整份写回（网页版 setOutline 的 { ...outlineOf(w), ...patch }）
    @discardableResult
    static func setOutline(_ workId: String, _ change: (inout Outline) -> Void) throws -> Row? {
        guard let w = Works.get(workId) else { return nil }
        var o = outlineOf(w)
        change(&o)
        return try Works.update(workId, ["outline": json(o)])
    }

    /// 模型给回来的总纲与卷纲：卷里带着章纲的（章数少的那种）一并拆出来
    struct Made: Equatable {
        var master: Master?
        var volumes: [Volume]
        var chapters: [Int: [Line]]
    }

    static func made(_ v: JSONValue?) -> Made {
        let vols = (v?["volumes"]?.array ?? []).enumerated().compactMap { i, x -> (Volume, [Line])? in
            guard let o = x.object else { return nil }
            let vol = Volume(no: num(o["no"], i + 1), title: str(o["title"]), goal: str(o["goal"]), from: num(o["from"], 1), to: num(o["to"], 1), reveal: str(o["reveal"]))
            return (vol, lines(o["chapters"]))
        }
        var chs: [Int: [Line]] = [:]
        for (vol, list) in vols where !list.isEmpty { chs[vol.no] = list }
        return Made(master: master(v?["master"]), volumes: vols.map(\.0).filter { $0.to >= $0.from }, chapters: chs)
    }

    @discardableResult
    static func applyOutline(_ workId: String, _ m: Made) throws -> Row? {
        try setOutline(workId) { o in
            o.master = m.master
            o.volumes = m.volumes
            o.chapters = m.chapters
            o.drift = false
            o.madeAt = Date().millis
        }
    }

    @discardableResult
    static func applyVolume(_ workId: String, _ volNo: Int, _ list: [Line]) throws -> Row? {
        try setOutline(workId) { $0.chapters[volNo] = list }
    }

    /// 第 no 章落在哪一卷
    static func volumeOf(_ o: Outline, _ no: Int) -> Volume? { o.volumes.first { no >= $0.from && no <= $0.to } }

    /// 第 no 章的章纲那一行
    static func lineOf(_ o: Outline, _ no: Int) -> Line? {
        let list = volumeOf(o, no).map { o.chapters[$0.no] ?? [] } ?? o.chapters.keys.sorted().flatMap { o.chapters[$0] ?? [] }
        return list.first { $0.no == no }
    }

    /// 写到这一卷时章纲还没补
    static func volumeMissing(_ o: Outline, _ no: Int) -> Volume? {
        guard let v = volumeOf(o, no), (o.chapters[v.no] ?? []).isEmpty else { return nil }
        return v
    }

    /// 写了几章、预计几章
    static func progressOf(_ w: Row) -> (written: Int, started: Int, total: Int) {
        let list = Works.chaptersOf(w.id)
        let written = list.filter { c in Scenes.beatsOf(c.id).contains { $0.string("role") != Scenes.DIRECTOR && !$0.string("text").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }.count
        return (written, list.count, num(w["length"]?["chapters"]))
    }

    /// 总纲写成几行（给提示词与界面共用；只陈述）
    static func masterLines(_ m: Master?) -> [String] {
        guard let m else { return [] }
        var out: [String] = []
        if !m.mainline.isEmpty { out.append("主线：\(m.mainline)") }
        if !m.subline.isEmpty { out.append("暗线：\(m.subline)") }
        if !m.ending.isEmpty { out.append("结局：\(m.ending)") }
        if !m.twists.isEmpty { out.append("关键转折：\(m.twists.joined(separator: "；"))") }
        if !m.arcs.isEmpty { out.append("人物弧光：\(m.arcs.joined(separator: "；"))") }
        return out
    }

    /// 写这一章时带进提示词的那一块。隐藏大纲照样带：隐藏的是界面，不是模型
    static func promptLines(_ w: Row, _ ch: Row) -> [String] {
        let o = outlineOf(w)
        var lines: [String] = []
        let p = progressOf(w)
        let no = num(ch["no"])
        if p.total > 0 { lines.append("Progress: chapter \(no) of \(p.total) planned (\(Int((Double(no) / Double(p.total) * 100).rounded()))%).") }
        guard o.mode != NONE, let m = o.master else { return lines }
        lines += masterLines(m)
        if let v = volumeOf(o, no) {
            lines.append("当前卷：第 \(v.no) 卷\(v.title.isEmpty ? "" : "　\(v.title)")（第 \(v.from) 到 \(v.to) 章）：\(v.goal)\(v.reveal.isEmpty ? "" : "；本卷揭晓：\(v.reveal)")")
        }
        if let l = lineOf(o, no) { lines.append("本章：\(l.title.isEmpty ? "" : "\(l.title)　")\(l.line)") }
        let plan = ch.string("plan").trimmingCharacters(in: .whitespacesAndNewlines)
        if !plan.isEmpty && ch.string("planFrom") != "end" { lines.append("本章走向（已选定）：\(plan)") }
        if o.drift { lines.append("The story has left the outline; the chosen direction takes precedence where they differ.") }
        return lines
    }

    /// 隐藏大纲时界面上能看的那一部分：nil 不限；0 什么都不给；n 只给写到的章
    static func visibleChapters(_ w: Row) -> Int? {
        let o = outlineOf(w)
        if o.mode == VISIBLE || o.revealed == "all" { return nil }
        if o.revealed == "written" { return progressOf(w).started }
        return 0
    }

    // MARK: - 体裁标签与篇幅（网页版 novel-tags.js）。这里的词是被选的内容，不是界面文案

    static let tags: [(id: String, label: String, tags: [String])] = [
        ("genre", "大类", ["言情", "纯爱", "悬疑", "灵异", "科幻", "奇幻", "仙侠", "武侠", "都市", "历史", "校园",
                         "职场", "末世", "无限流", "穿越", "重生", "系统", "宫斗", "宅斗", "种田", "治愈", "群像", "轻小说", "同人"]),
        ("trope", "题材", ["破镜重圆", "救赎", "双向奔赴", "先婚后爱", "替身", "年下", "年上", "青梅竹马", "天降",
                         "竹马竹马", "强强", "追妻火葬场", "伪骨科", "契约关系", "暗恋成真", "相爱相杀", "师徒", "主仆", "身份错位", "失忆",
                         "重逢", "囚禁", "克苏鲁", "规则怪谈", "本格推理", "密室", "时间循环", "多重人格", "末日求生", "基建", "经营", "升级流",
                         "权谋", "复仇", "成长", "公路", "日常"]),
        ("mood", "基调", ["甜", "虐", "先虐后甜", "先甜后虐", "轻松", "沉重", "温馨", "压抑", "热血", "致郁",
                        "幽默", "黑暗", "HE", "BE", "开放式结局", "双结局"]),
        ("view", "视角", ["第一人称", "第三人称", "双视角", "多视角", "角色视角", "我的视角"]),
    ]

    /// 自己加的标签：settings.novelTags（{ 类: [标签] }）
    static func customTags(_ s: AppSettings = .load()) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (k, v) in s.raw["novelTags"]?.object ?? [:] { out[k] = (v.array ?? []).compactMap(\.string) }
        return out
    }

    /// 篇幅档。只是填默认值，章数与每章字数都能改（第 13 条）
    static let lengths: [(id: String, label: String, desc: String, chapters: Int, perChapter: Int)] = [
        ("short", "短篇", "一到三万字", 8, 3000),
        ("mid", "中篇", "五到十万字", 24, 3500),
        ("long", "长篇", "二十到五十万字", 100, 4000),
        ("epic", "超长", "一百万字以上", 300, 4000),
    ]

    /// 章数推出该分几卷：每卷十二章上下，至少一卷，最多二十卷
    static func volumesFor(_ chapters: Int) -> Int {
        let r = Int((Double(chapters) / 12).rounded())
        return max(1, min(20, r == 0 ? 1 : r))
    }

    /// 章数少的时候一次请求连章纲一起要，不必分卷再要一次
    static let oneShotChapters = 15
}
