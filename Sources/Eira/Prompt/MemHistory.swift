import Foundation

/// 记忆的历史版本（网页版 system/memhistory.js，ARCHITECTURE 4.560）。
///
/// 每次自动总结、关系底色重压之前，把这个角色当时的全部记忆、现状块、关系底色存一份（memsnaps，按 charId 查）。
/// 存整份不存差分；和上一份一样就不存；每个角色留几份由 settings.memSnapKeep 定（默认 30，0 不限）；
/// 恢复之前先存一份「恢复之前」。不进提示词，不调接口。向量与召回次数是程序自己记的账，不进快照。
enum MemHistory {
    static let collection = "memsnaps"
    static let defaultKeep = 30
    private static let noise = ["vec", "vecModel", "useCount", "lastUsedAt"]

    static func keep(_ s: AppSettings = .load()) -> Int { max(0, Int(s.num("memSnapKeep", Double(defaultKeep)))) }

    private static func strip(_ r: Row) -> JSONValue {
        var f = r.fields
        for k in noise { f[k] = nil }
        return .object(f)
    }

    private static func current(_ charId: String) -> (memories: [JSONValue], states: JSONValue, bonds: JSONValue) {
        let c = (try? Repo.character(charId)) ?? nil
        let mems = ((try? Database.shared.all(Collections.memories, where: charId)) ?? []).sorted { $0.id < $1.id }.map(strip)
        return (mems, c?.row["states"] ?? .object([:]), c?.row["bonds"] ?? .object([:]))
    }

    static func list(_ charId: String) -> [Row] {
        ((try? Database.shared.all(collection, where: charId)) ?? []).sorted { ($0.number("at") ?? 0) > ($1.number("at") ?? 0) }
    }

    /// 存一份。why 写给人看：「总结记忆」「关系底色」「恢复之前」。和上一份相同、或者什么都没有时不存
    @discardableResult
    static func take(_ charId: String, why: String, now: Date = Date()) throws -> Row? {
        guard !charId.isEmpty, ((try? Repo.character(charId)) ?? nil) != nil else { return nil }
        let snap = current(charId)
        if let last = list(charId).first {
            if (last["memories"]?.array ?? []) == snap.memories && (last["states"] ?? .object([:])) == snap.states
                && (last["bonds"] ?? .object([:])) == snap.bonds { return nil }
        } else if snap.memories.isEmpty && (snap.states.object ?? [:]).isEmpty && (snap.bonds.object ?? [:]).isEmpty {
            return nil
        }
        let row = Row.new(prefix: "ms", ["charId": .string(charId), "why": .string(why), "at": .number(now.millis),
                                         "memories": .array(snap.memories), "states": snap.states, "bonds": snap.bonds])
        try Database.shared.put(collection, row)
        let k = keep()
        if k > 0 { for old in list(charId).dropFirst(k) { try Database.shared.delete(collection, id: old.id) } }
        return row
    }

    struct Diff {
        var snap: Row
        var added: [JSONValue] = []      // 现在有、那时没有：恢复会去掉
        var removed: [JSONValue] = []    // 那时有、现在没有：恢复会放回
        var changed: [(then: JSONValue, now: JSONValue)] = []
        var blocks: [(root: String, id: String, then: String, now: String)] = []
        var bond = false
        var same: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty && blocks.isEmpty && !bond }
    }

    private static func text(_ m: JSONValue?) -> String { (m?["content"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    static func diff(_ snapId: String) -> Diff? {
        guard let snap = (try? Database.shared.get(collection, id: snapId)) ?? nil else { return nil }
        let now = current(snap.string("charId"))
        let thenList = snap["memories"]?.array ?? []
        let then = Dictionary(thenList.map { ($0["id"]?.string ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        let cur = Dictionary(now.memories.map { ($0["id"]?.string ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        var d = Diff(snap: snap)
        d.added = now.memories.filter { then[$0["id"]?.string ?? ""] == nil }
        d.removed = thenList.filter { cur[$0["id"]?.string ?? ""] == nil }
        for m in thenList {
            guard let c = cur[m["id"]?.string ?? ""] else { continue }
            let sup = { (x: JSONValue) in !(x["supersededBy"]?.string ?? "").isEmpty }
            if text(m) != text(c) || sup(m) != sup(c) || (m["status"]?.string ?? "") != (c["status"]?.string ?? "") {
                d.changed.append((m, c))
            }
        }
        let a = snap["states"]?.object ?? [:], b = now.states.object ?? [:]
        for k in Set(a.keys).union(b.keys).sorted() {
            let x = a[k]?["blocks"]?.object ?? [:], y = b[k]?["blocks"]?.object ?? [:]
            for id in Set(x.keys).union(y.keys).sorted() {
                let t = (x[id]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let n = (y[id]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if t != n { d.blocks.append((k, id, x[id]?.string ?? "", y[id]?.string ?? "")) }
            }
        }
        d.bond = (snap["bonds"] ?? .object([:])) != now.bonds
        return d
    }

    /// 整份放回去。先存一份「恢复之前」。返回放回的记忆条数
    @discardableResult
    static func restore(_ snapId: String) throws -> Int {
        guard let snap = try Database.shared.get(collection, id: snapId), var char = try Repo.character(snap.string("charId")) else {
            throw StoreError(message: "这一份已不存在")
        }
        try take(char.id, why: "恢复之前")
        let old = Dictionary(((try? Database.shared.all(Collections.memories, where: char.id)) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in old.values { try Database.shared.delete(Collections.memories, id: r.id) }
        let mems = snap["memories"]?.array ?? []
        for m in mems {
            guard var f = m.object else { continue }
            // 向量那几项不在快照里：同一条还在的话照抄回去，下次召回不用重算
            if let id = f["id"]?.string, let o = old[id] { for k in noise where o[k] != nil { f[k] = o[k] } }
            try Database.shared.put(Collections.memories, Row(fields: f))
        }
        char.row["states"] = snap["states"] ?? .object([:])
        char.row["bonds"] = snap["bonds"] ?? .object([:])
        char.row.touch()
        try Database.shared.put(Collections.characters, char.row)
        return mems.count
    }
}
