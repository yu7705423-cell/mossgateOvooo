import Foundation

/// 记忆体检（网页版 system/memcheck.js、textsim.js）。同一件事的两个版本并排躺着时，召回可能把两个都送进去。
/// 这里列出像到一定程度（DOUBT 以上）的成对条目，由人决定保留哪一条；另一条标 supersededBy 让位，不删，可以撤回。
/// 不调接口。
enum MemCheck {
    static let doubt = 0.5
    static let maxScan = 800

    /// 切成词、二元组与单字：拉丁与数字按词，中日韩按字（网页版 grams）
    static func grams(_ text: String) -> Set<String> {
        let s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }
        var out = Set<String>()
        if let re = try? NSRegularExpression(pattern: #"[a-z0-9][a-z0-9'’-]*"#) {
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let w = ns.substring(with: m.range)
                if w.count > 1 { out.insert(w) }
            }
        }
        func cjk(_ c: Swift.Character) -> Bool {
            guard let u = c.unicodeScalars.first?.value else { return false }
            return (0x4E00...0x9FFF).contains(u) || (0x3040...0x30FF).contains(u) || (0xAC00...0xD7AF).contains(u)
        }
        var run: [Swift.Character] = []
        func flush() {
            for i in run.indices {
                out.insert(String(run[i]))
                if i + 1 < run.count { out.insert(String(run[i...i + 1])) }
            }
            run.removeAll()
        }
        for c in s { if cjk(c) { run.append(c) } else { flush() } }
        flush()
        return out
    }

    /// 两段有多像，0 到 1：较短那一边有多少落在另一边里，单字只算三成半
    static func sim(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let (small, big) = a.count <= b.count ? (a, b) : (b, a)
        var hit = 0.0, all = 0.0
        for g in small {
            let w = g.count == 1 ? 0.35 : 1
            all += w
            if big.contains(g) { hit += w }
        }
        return all > 0 ? hit / all : 0
    }

    struct Pair: Identifiable { var a: Memory; var b: Memory; var score: Double; var id: String { a.id + "-" + b.id } }

    /// 还在生效的那些里，疑似同一件事的成对条目。只在同一个角色里比；同一件事给群里各成员各存一份的（twin）不算
    static func pairs(charId: String, personaId: String, limit: Int = 50) -> [Pair] {
        var all = ((try? Knowledge.memories(charId: charId, personaId: personaId)) ?? []).filter { $0.supersededBy.isEmpty }
        if all.count > maxScan {
            all = Array(all.sorted { ($0.row.number("updatedAt") ?? 0) > ($1.row.number("updatedAt") ?? 0) }.prefix(maxScan))
        }
        let g = all.map { grams($0.content) }
        var out: [Pair] = []
        for i in all.indices {
            for j in (i + 1)..<all.count {
                let t = all[i].row.string("twin")
                if !t.isEmpty && t == all[j].row.string("twin") { continue }
                let s = sim(g[i], g[j])
                if s >= doubt { out.append(Pair(a: all[i], b: all[j], score: s)) }
            }
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(limit))
    }

    static func superseded(charId: String, personaId: String) -> [Memory] {
        ((try? Knowledge.memories(charId: charId, personaId: personaId)) ?? []).filter { !$0.supersededBy.isEmpty }
    }

    /// 旧的让位给新的（不删）
    static func supersede(_ dropId: String, by keepId: String) throws {
        guard dropId != keepId, var r = try Database.shared.get(Collections.memories, id: dropId) else { return }
        r["supersededBy"] = .string(keepId)
        r.touch()
        try Database.shared.put(Collections.memories, r)
    }

    /// 撤回一次让位
    static func restore(_ id: String) throws {
        guard var r = try Database.shared.get(Collections.memories, id: id) else { return }
        r["supersededBy"] = .string("")
        r.touch()
        try Database.shared.put(Collections.memories, r)
    }
}
