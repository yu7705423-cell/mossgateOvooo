import Foundation

/// 关系底色（网页版 system/bond.js）：关系转折级（S 级）记忆压成几句现状，常驻在「你们之间」。
///
/// 按根账号分开存在 characters.bonds[根账号] 里。自动重压默认关（bondAuto），开着时在 S 级记忆有增删改之后的
/// 下一次回复前压一次，不等它压完：这一轮用旧的，下一轮是新的。
/// **发请求之前就把这一次的签名记下，成功失败都记**：不记的话，压失败之后每条消息都再压一次（网页版第 15 条）。
enum Bond {
    /// 这一份底色照着哪些 S 级记忆压：这个角色的（或不分角色的）、不只留在某个群里的、同一个根账号的。
    static func sources(charId: String, personaId: String) throws -> [Memory] {
        let personas = try Repo.personas()
        let root = Repo.rootId(of: personaId, in: personas)
        return try Database.shared.all(Collections.memories).map(Memory.init(row:)).filter { m in
            guard m.rank == "S", m.charId.isEmpty || m.charId == charId, m.scopeChat.isEmpty else { return false }
            if root.isEmpty || m.personaId.isEmpty { return true }
            return Repo.rootId(of: m.personaId, in: personas) == root
        }.sorted { ($0.row.number("createdAt") ?? 0) < ($1.row.number("createdAt") ?? 0) }
    }

    static func signature(_ rows: [Memory]) -> String {
        rows.map { "\($0.id):\(Int($0.row.number("updatedAt") ?? 0))" }.joined(separator: "|")
    }

    /// 该不该重压：有 S 级记忆、没被手写锁住、签名和上次不一样。
    static func stale(charId: String, personaId: String) throws -> Bool {
        guard let char = try Repo.character(charId) else { return false }
        let key = try MemorySummary.stateKey(personaId)
        let cur = char.row["bonds"]?[key]
        if cur?["manual"]?.bool == true { return false }
        let sig = signature(try sources(charId: charId, personaId: personaId))
        return !sig.isEmpty && sig != (cur?["sig"]?.string ?? "")
    }

    /// 自动那一档：开着、该压、有接口可用才压。返回是否发出了请求。
    @discardableResult
    static func autoRun(charId: String, personaId: String) async -> Bool {
        let s = AppSettings.load()
        guard s.raw["bondAuto"]?.bool == true, (try? stale(charId: charId, personaId: personaId)) == true else { return false }
        do { try await refresh(charId: charId, personaId: personaId) }
        catch { Diagnostics.shared.record("bond-failed", ["error": error.localizedDescription]) }
        return true
    }

    /// 重压一遍。没配接口不算试过（一个请求都没发出去）。失败时只记签名与原因，上一份底色留着。
    static func refresh(charId: String, personaId: String) async throws {
        let rows = try sources(charId: charId, personaId: personaId)
        guard !rows.isEmpty else { return }
        guard !AIService.chain(task: "memory.bond", group: RouteGroup.of(task: "memory.bond"), settings: .load()).isEmpty else { return }
        let key = try MemorySummary.stateKey(personaId)
        let sig = signature(rows)
        try write(charId: charId, key: key, ["at": .number(Date().millis), "sig": .string(sig)])
        let system = Templates.render("task.bond", ["events": rows.map { "- \($0.content)" }.joined(separator: "\n")], settings: .load())
        let text: String
        do {
            text = try await AIService.shared.send(task: "memory.bond", system: system,
                                                  messages: [AIMessage(role: .user, content: "Produce the output as instructed.")],
                                                  maxTokens: 400, retries: 1).text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            try? write(charId: charId, key: key, ["failed": .string(error.localizedDescription)])
            throw error
        }
        guard !text.isEmpty else {
            try write(charId: charId, key: key, ["failed": .string("模型返回了空内容")])
            return
        }
        let clipped = String(text.prefix(600))
        // 底色改写之前存一份（网页版 4.560）
        do { try MemHistory.take(charId, why: "关系底色") } catch { Diagnostics.shared.record("memhistory-failed", ["error": error.localizedDescription]) }
        try write(charId: charId, key: key, ["text": .string(clipped), "manual": .bool(false), "at": .number(Date().millis), "failed": .string("")])
        // 压出来的写进现状块的「你们之间」：注入读的是那一块。手写锁住的不动
        guard var char = try Repo.character(charId) else { return }
        var states = char.row["states"]?.object ?? [:]
        var cur = states[key]?.object ?? ["blocks": .object([:]), "locks": .object([:])]
        guard cur["locks"]?["us"]?.bool != true else { return }
        var blocks = cur["blocks"]?.object ?? [:]
        blocks["us"] = .string(clipped)
        cur["blocks"] = .object(blocks)
        cur["at"] = .number(Date().millis)
        states[key] = .object(cur)
        char.row["states"] = .object(states)
        char.row.touch()
        try Database.shared.put(Collections.characters, char.row)
    }

    /// 解锁：手写的那一份不再算手写，S 级记忆变动时重新生成
    static func unlock(charId: String, key: String) throws {
        try write(charId: charId, key: key, ["manual": .bool(false), "sig": .string("")])
    }

    private static func write(charId: String, key: String, _ patch: [String: JSONValue]) throws {
        guard var char = try Repo.character(charId) else { return }
        var bonds = char.row["bonds"]?.object ?? [:]
        var cur = bonds[key]?.object ?? [:]
        cur.merge(patch) { _, new in new }
        bonds[key] = .object(cur)
        char.row["bonds"] = .object(bonds)
        char.row.touch()
        do { try Database.shared.put(Collections.characters, char.row) }
        catch {
            Problems.report("关系底色未能保存：\(error.localizedDescription)")
            throw error
        }
    }
}
