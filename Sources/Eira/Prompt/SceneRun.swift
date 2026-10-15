import Foundation

/// 线下写一轮（网页版 ai/scenerun.js 与 ai/ensemble.js，ARCHITECTURE 4.439）。
///
/// 只有一个角色在场：一次调用一段。
/// 不止一个人在场：
///   一次调用写整轮（默认）  一次请求，模型按「【名字】」写各人的段落，本机拆回各人各一段
///   每人单独调用            「用量与上限」里的开关 scenePerChar，默认关（第 15 条）。在场的角色各一次，后写的看得见先写的
/// 续写与重写只关乎那一段的作者。离场与进场的标记在这里落成状态（第 22 条：要不要离开是角色自己的事）。
enum SceneRun {
    static func perCharOn(_ s: AppSettings = .load()) -> Bool { s.raw["scenePerChar"]?.bool == true }

    // MARK: - 标记（协议，和网页版一字不差）

    private static func norm(_ s: String) -> String { s.components(separatedBy: .whitespacesAndNewlines).joined() }

    /// 名字对人：原名或这一场里改过的名字，先长后短，避免「阿岚」撞上「岚」
    static func matchChar(_ name: String, _ chars: [Character], alias: [String: String] = [:]) -> Character? {
        let q = norm(name)
        guard !q.isEmpty else { return nil }
        var rows: [(c: Character, n: String)] = []
        for c in chars {
            let a = norm(c.name), b = norm(alias[c.id] ?? "")
            if !a.isEmpty { rows.append((c, a)) }
            if !b.isEmpty { rows.append((c, b)) }
        }
        rows = rows.enumerated().sorted { x, y in
            x.element.n.count != y.element.n.count ? x.element.n.count > y.element.n.count : x.offset < y.offset
        }.map(\.element)
        return rows.first { $0.n == q }?.c ?? rows.first { q.contains($0.n) || $0.n.contains(q) }?.c
    }

    private static let head = ReplyParser.regex(#"^\s*(?:[*_]{1,2})?【([^】]{1,40})】(?:[*_]{1,2})?\s*(.*)$"#, [])
    private static let leaveRe = ReplyParser.regex(#"^\s*[\[【]\s*离场\s*[\]】]\s*$"#, [])
    private static let enterRe = ReplyParser.regex(#"^\s*[\[【]\s*进场\s*[:：]\s*([^\]】]+?)\s*[\]】]\s*$"#, [])

    /// 按「【名字】」把整段拆成各人的小节。开头没有标题的那些归第一个在场的人；认不出名字的标题照旧归上一节
    static func splitSections(_ text: String, _ chars: [Character], alias: [String: String] = [:]) -> [(char: Character, text: String)] {
        var out: [(char: Character?, lines: [String])] = []
        for line in text.components(separatedBy: "\n") {
            if let m = ReplyParser.match(head, line), let who = matchChar(m[1], chars, alias: alias) {
                out.append((who, m[2].trimmingCharacters(in: .whitespaces).isEmpty ? [] : [m[2]]))
                continue
            }
            if out.isEmpty { out.append((chars.first, [])) }
            out[out.count - 1].lines.append(line)
        }
        return out.compactMap { sg in
            let t = sg.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let c = sg.char, !t.isEmpty else { return nil }
            return (c, t)
        }
    }

    struct Exits {
        var text: String
        var leave = false
        var enter: [Character] = []
        var unknown: [String] = []
    }

    /// 摘掉一节里的离场与进场标记。进来的只认名单上的（可进场的与已离开的）
    static func takeExits(_ text: String, allowed: [Character], alias: [String: String] = [:]) -> Exits {
        var kept: [String] = []
        var ex = Exits(text: "")
        for line in text.components(separatedBy: "\n") {
            if ReplyParser.matches(leaveRe, line) { ex.leave = true; continue }
            if let m = ReplyParser.match(enterRe, line) {
                if let who = matchChar(m[1], allowed, alias: alias) {
                    if !ex.enter.contains(where: { $0.id == who.id }) { ex.enter.append(who) }
                } else { ex.unknown.append(m[1].trimmingCharacters(in: .whitespaces)) }
                continue
            }
            kept.append(line)
        }
        ex.text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ex
    }

    /// [时间：2026-01-01 周三 14:30] 只留里面的时刻
    static func stampInner(_ s: String?) -> String {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return "" }
        if let f = t.first, "[【(（".contains(f) { t.removeFirst() }
        if let l = t.last, "]】)）".contains(l) { t.removeLast() }
        return t.replacingOccurrences(of: #"^\s*(?:时间|時間|time)\s*[:：]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func alias(_ row: Row) -> [String: String] {
        var out: [String: String] = [:]
        for id in row.strings("castIds") { if let a = Scene.castAs(row, id), !a.name.isEmpty { out[id] = a.name } }
        return out
    }

    // MARK: - 落成一段

    /// 一段原文落成一段正文。rewrite 是重写的那一段（往后添一版）；more 接着最后那一段往下写。回提示语
    private static func settle(_ raw: String, sceneId: String, char: Character, more: Bool, rewrite: String) throws -> (beat: Row?, notes: [String]) {
        let (thought, think) = ReplyParser.stripThink(raw)
        let (stamped, stamp) = ReplyParser.stripStamps(thought)
        let at = stampInner(stamp)
        let body0 = StatusBar.lift(stamped).text
        guard let fresh = Scene.get(sceneId) else { throw StoreError(message: "这一场已经不在了") }
        let ex = takeExits(body0, allowed: Scene.enterable(fresh), alias: alias(fresh))
        if ex.text.isEmpty && !ex.leave && ex.enter.isEmpty { throw StoreError(message: "模型返回了空内容") }
        var notes: [String] = []
        var done: Row?
        if !ex.text.isEmpty {
            let last = Scene.told(sceneId).last
            if !rewrite.isEmpty {
                done = try Scene.addSwipe(rewrite, text: ex.text, raw: raw, think: think, at: at)
            } else if more, let last {
                done = try Scene.appendBeat(last.id, text: ex.text, raw: raw, at: at)
            } else {
                done = try Scene.addBeat(sceneId: sceneId, role: Scene.CHAR, authorId: char.id, text: ex.text, raw: raw, think: think, at: at)
            }
        }
        if let d = done, ex.leave || !ex.enter.isEmpty {
            done = try Scene.updateBeat(d.id, ["cast": .object([
                "left": .array(ex.leave ? [.string(char.id)] : []),
                "entered": .array(ex.enter.map { .string($0.id) }),
            ])]) ?? d
        }
        for c in ex.enter { try Scene.enter(sceneId, c.id); notes.append("\(c.name)进场") }
        if ex.leave { try Scene.leave(sceneId, char.id); notes.append("\(char.name)离场") }
        if !ex.unknown.isEmpty {
            Diagnostics.shared.record("scene-enter-unknown", ["names": ex.unknown.joined(separator: "、")])
        }
        return (done, notes)
    }

    // MARK: - 写一轮

    struct Round {
        var beats: [Row] = []
        var notes: [String] = []
    }

    /// 写一轮。onDraft 收到的是此刻写到哪儿的整段，直接显示。
    /// rewrite：重写那一段（只关乎那一段的作者）；more：续写最后那一段
    static func writeRound(sceneId: String, more: Bool = false, rewrite: String = "",
                           onDraft: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Round {
        guard let row = Scene.get(sceneId), let chat = try Repo.chat(row.string("chatId")) else {
            throw StoreError(message: "这一场已经不在了")
        }
        let present = Scene.presentOf(row)
        let all = Scene.beatsOf(sceneId)
        let told = all.filter { $0.string("role") != Scene.DIRECTOR }
        var round = Round()
        let buffer = Draft()

        func one(_ char: Character, more: Bool = false, omitFrom: String = "") async throws {
            guard let fresh = Scene.get(sceneId) else { throw StoreError(message: "这一场已经不在了") }
            var list = Scene.beatsOf(sceneId)
            if !omitFrom.isEmpty, let i = list.firstIndex(where: { $0.id == omitFrom }) { list = Array(list[..<i]) }
            let s = AppSettings.load()
            let built = try ChatPrompt.buildScene(scene: fresh, chat: chat, char: char, list: list, more: more, settings: s)
            let label = Scene.presentOf(fresh).count > 1 && !more && omitFrom.isEmpty ? "【\(Scene.nameIn(fresh, char))】\n" : ""
            let base = buffer.base
            let result = try await AIService.shared.send(task: "scene.write", system: built.system, messages: built.messages,
                                                         maxTokens: ChatPrompt.sceneMax(s), retries: 1) { d in
                onDraft(base + label + buffer.add(d))
            }
            buffer.reset()
            try? ChatEngine.markRecalled(built.recalled)
            let r = try settle(result.text, sceneId: sceneId, char: char, more: more, rewrite: omitFrom)
            if let b = r.beat { round.beats.append(b); buffer.base += label + b.string("text") + "\n\n" }
            round.notes += r.notes
        }

        if !rewrite.isEmpty {
            let author = all.first { $0.id == rewrite }.flatMap { (try? Repo.character($0.string("authorId"))) ?? nil }
            guard let char = author ?? present.first else { throw StoreError(message: "这一场里没有在场的角色") }
            try await one(char, omitFrom: rewrite)
            return round
        }
        if more {
            let author = told.last.flatMap { (try? Repo.character($0.string("authorId"))) ?? nil }
            guard let char = author ?? present.first else { throw StoreError(message: "这一场里没有在场的角色") }
            try await one(char, more: true)
            return round
        }
        guard !present.isEmpty else { throw StoreError(message: "这一场里没有在场的角色") }

        if present.count == 1 || perCharOn() {
            for char in present {
                // 这一轮里前面写了 [离场] 的，后面的人看得见；离开了的不再写
                if let v = Scene.get(sceneId).flatMap({ Scene.leftMap($0)[char.id] }), v != .null { continue }
                try await one(char)
            }
            return round
        }

        // 一次调用写整轮：拆回各人。可进场的人若直接有了自己的一节，视同进场
        let s = AppSettings.load()
        let built = try ChatPrompt.buildSceneEnsemble(scene: row, chat: chat, cast: present, list: all, settings: s)
        let result = try await AIService.shared.send(task: "scene.write", system: built.system, messages: built.messages,
                                                     maxTokens: ChatPrompt.sceneMax(s), retries: 1) { d in onDraft(buffer.add(d)) }
        try? ChatEngine.markRecalled(built.recalled)
        let text = ReplyParser.stripThink(result.text).0
        guard let fresh = Scene.get(sceneId) else { throw StoreError(message: "这一场已经不在了") }
        let pool = present + Scene.enterable(fresh).filter { c in !present.contains { $0.id == c.id } }
        let sections = splitSections(text, pool, alias: alias(fresh))
        guard !sections.isEmpty else { throw StoreError(message: "模型返回了空内容") }
        for sg in sections {
            let cur = Scene.get(sceneId)
            var away = false
            if let cur {
                let gone = Scene.leftMap(cur)[sg.char.id].map { v in v != .null } ?? false
                away = !cur.strings("castIds").contains(sg.char.id) || gone
            }
            if away { try Scene.enter(sceneId, sg.char.id); round.notes.append("\(sg.char.name)进场") }
            let r = try settle(sg.text, sceneId: sceneId, char: sg.char, more: false, rewrite: "")
            if let b = r.beat { round.beats.append(b) }
            round.notes += r.notes
        }
        return round
    }

    /// 流式收到的字攒在这里（回调在别的线程上）
    private final class Draft: @unchecked Sendable {
        private let lock = NSLock()
        private var buf = ""
        private var _base = ""
        var base: String {
            get { lock.lock(); defer { lock.unlock() }; return _base }
            set { lock.lock(); _base = newValue; lock.unlock() }
        }
        func add(_ d: String) -> String { lock.lock(); defer { lock.unlock() }; buf += d; return buf }
        func reset() { lock.lock(); buf = ""; lock.unlock() }
    }
}
