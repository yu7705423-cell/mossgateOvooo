import Foundation

/// 整理对我的印象、对照几位角色的印象（网页版 ai/tasks/impress.js，ARCHITECTURE 4.346、4.347）。
///
/// 你点了才调，一次，走副用（「任务接口分配」里的 impress 一组）。不自动触发，不进 ExtraCalls。
/// 你发的每一句带编号，角色的话不带 —— 引用只能引编号，编号不存在、指着角色的话一律不收。
/// 交回来的不直接入库，存成一份整理结果，在确认页上勾选收下（Impress.accept）。
enum ImpressTask {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var inFlight = Set<String>()

    private static func claim(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.insert(key).inserted
    }
    private static func release(_ key: String) { lock.lock(); inFlight.remove(key); lock.unlock() }

    static func running(_ charId: String, _ personaId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.contains("\(charId):\(Impress.pid(personaId))")
    }

    private static func stamp(_ at: Double) -> String {
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: Date(millis: at))
        return "\(c.month ?? 0)-\(c.day ?? 0) " + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    @discardableResult
    static func organize(charId: String, personaId pidIn: String) async throws -> Row {
        let personaId = Impress.pid(pidIn)
        guard let char = try Repo.character(charId) else { throw StoreError(message: "角色不存在") }
        let key = "\(charId):\(personaId)"
        let persona = try Repo.personas().first { $0.id == personaId }
        let userName = persona?.row.string("name").isEmpty == false ? persona!.row.string("name") : "User"
        let charName = char.row.string("name")

        let lines = Impress.linesSince(charId, personaId)
        let notes = Impress.notes(charId, personaId)
        if !lines.contains(where: { $0.role == .user }) && notes.isEmpty { throw StoreError(message: "上次整理之后没有新的对话") }

        // 你发的那几句编号 #1、#2……；零散依据编号 n1、n2……
        var refs: [String: [String: JSONValue]] = [:]
        var k = 0
        var nameCache: [String: String] = [:]
        func nameOf(_ id: String) -> String {
            if let n = nameCache[id] { return n }
            let n = (try? Repo.character(id))?.row.string("name")
            let out = (n?.isEmpty == false ? n! : charName)
            nameCache[id] = out
            return out
        }
        let dialogue = lines.map { m -> String in
            if m.role == .user {
                k += 1
                refs["#\(k)"] = Impress.evidenceOf(m)
                return "[#\(k) \(stamp(m.createdAt))] \(userName)：\(m.content)"
            }
            return "[\(stamp(m.createdAt))] \(nameOf(m.authorId))：\(m.content)"
        }.joined(separator: "\n")
        let noteText = notes.enumerated().map { i, n -> String in
            let ev = Impress.evidence(n["evidence"]).first ?? [:]
            var e = ev
            e["note"] = .string(n.id)
            refs["n\(i + 1)"] = e
            return "[n\(i + 1) \(ev["day"]?.string ?? "")] \(n.string("text")) | \(userName)：「\(ev["quote"]?.string ?? "")」"
        }.joined(separator: "\n")

        let kept = Impress.list(charId, personaId)
        func orNone(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(none)" : s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let system = Templates.render("task.impress", [
            "charName": charName,
            "userName": userName,
            "card": orNone(char.persona),
            "selfText": orNone(persona?.row.string("description") ?? ""),
            "existing": kept.isEmpty ? "(none)" : kept.map { "(id:\($0.id)) \($0.string("text")) [\(Impress.days($0).count) days of evidence]" }.joined(separator: "\n"),
            "rejected": orNone(Impress.dropped(charId, personaId).map { "- \($0.string("text"))" }.joined(separator: "\n")),
            "notes": noteText.isEmpty ? "(none)" : noteText,
            "dialogue": dialogue.isEmpty ? "(no new conversation)" : dialogue,
        ], settings: AppSettings.load())

        guard claim(key) else { throw StoreError(message: "正在整理") }
        let r: AIService.Result
        do {
            r = try await AIService.shared.send(task: "impress.organize", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")], retries: 1)
            release(key)
        } catch { release(key); throw error }
        guard let json = JSONReply.parse(r.text) else { throw StoreError(message: JSONReply.failure(r.text)) }
        let got = digest(json, refs: refs, keptIds: Set(kept.map(\.id)))
        let upTo = lines.last?.createdAt ?? 0
        return try Impress.saveDraft(charId, personaId, fresh: got.fresh, support: got.support, against: got.against,
                                     noteIds: got.used, upTo: upTo)
    }

    /// 只认这次交出去的编号；零散依据与编号指着同一条消息时只留一份。引用了的零散依据算用上了
    static func digest(_ json: JSONValue, refs: [String: [String: JSONValue]], keptIds: Set<String>)
        -> (fresh: [Impress.Fresh], support: [Impress.Pick], against: [Impress.Pick], used: [String]) {
        var used: [String] = []
        func evOf(_ v: JSONValue?) -> [[String: JSONValue]] {
            var seen = Set<String>()
            var hit: [[String: JSONValue]] = []
            for x in v?.array ?? [] {
                var s: String
                switch x {
                case .string(let t): s = t
                case .number(let n): s = n == n.rounded() ? String(Int(n)) : String(n)
                case .object(let o): s = o["ref"]?.string ?? (o["ref"]?.number).map { String(Int($0)) } ?? ""
                default: s = ""
                }
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty && s.allSatisfy(\.isNumber) { s = "#" + s }
                guard let e = refs[s], !seen.contains(s) else { continue }
                seen.insert(s)
                hit.append(e)
            }
            for e in hit { if let n = e["note"]?.string, !used.contains(n) { used.append(n) } }
            var seenMsg = Set<String>()
            return hit.filter { e in
                let id = e["msgId"]?.string ?? ""
                return seenMsg.insert(id).inserted
            }.map { e in var o = e; o["note"] = nil; return o }
        }
        func str(_ v: JSONValue?) -> String { (v?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let fresh = (json["new"]?.array ?? []).map { x in
            Impress.Fresh(text: str(x["text"]), voice: str(x["voice"]), evidence: evOf(x["evidence"]))
        }.filter { !$0.text.isEmpty && !$0.evidence.isEmpty }
        func pick(_ v: JSONValue?) -> [Impress.Pick] {
            (v?.array ?? []).map { x in Impress.Pick(id: x["id"]?.string ?? "", evidence: evOf(x["evidence"])) }
                .filter { keptIds.contains($0.id) && !$0.evidence.isEmpty }
        }
        let support = pick(json["support"])
        let against = pick(json["against"])
        return (fresh, support, against, used)
    }

    /// 对照几位角色的印象：找出说的是同一件事的那几组。交出去的只有印象正文与是哪位角色的，不带依据原话
    static func compare(personaId pidIn: String) async throws {
        let personaId = Impress.pid(pidIn)
        let all = Impress.allKept(personaId)
        guard Set(all.map { $0.string("charId") }).count >= 2 else { throw StoreError(message: "至少要有两位角色的印象才能对照") }
        let persona = try Repo.personas().first { $0.id == personaId }
        let name = persona?.row.string("name") ?? ""
        let list = all.map { r -> String in
            let who = (try? Repo.character(r.string("charId")))?.row.string("name") ?? "?"
            return "(id:\(r.id)) [\(who)] \(r.string("text"))"
        }.joined(separator: "\n")
        let system = Templates.render("task.impress-compare", ["userName": name.isEmpty ? "User" : name, "list": list], settings: AppSettings.load())
        let key = "impress-compare:\(personaId)"
        guard claim(key) else { throw StoreError(message: "正在对照") }
        let r: AIService.Result
        do {
            r = try await AIService.shared.send(task: "impress.compare", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")], retries: 1)
            release(key)
        } catch { release(key); throw error }
        guard let json = JSONReply.parse(r.text) else { throw StoreError(message: JSONReply.failure(r.text)) }
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<String>()
        let groups = (json["groups"]?.array ?? []).map { g -> (ids: [String], text: String) in
            let ids = (g["ids"]?.array ?? []).compactMap { $0.string ?? $0.number.map { String(Int($0)) } }
                .filter { byId[$0] != nil && used.insert($0).inserted }
            return (ids, (g["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { Set($0.ids.compactMap { byId[$0]?.string("charId") }).count >= 2 }
        try Impress.saveGroups(personaId, groups, basis: all.map(\.id))
    }
}
