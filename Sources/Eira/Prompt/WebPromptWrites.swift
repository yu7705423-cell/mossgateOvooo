import Foundation

/// 网页版拼提示词途中的写，写回原生库（docs/jscore-prompt.md 的「写回」）。
///
/// 网页版在拼装途中会写几处：`avatar.markSeen` 把 `chats.seenAvatar` 记成这一轮注入时的头像（「对方换了头像」只说一次），
/// 以后开了更多功能还会有别的。JS 那边（prompt-host.js）在第一次碰一行之前记下它原来的样子，拼完算出改了哪几个字段：
///
/// - `patch`：改了 `set` 里的字段、去掉了 `unset` 里的。写回时读原生库里**此刻**的那一行，只盖这几个字段，
///   别的字段（原生自己的、不认得的、拼装期间原生刚写的）一个不动。`whole` 为 true 时网页版是原地改的、看不出改了哪几个，
///   `set` 是整行：同样逐个字段盖上，原生多出来的字段照样留着
/// - `insert`：新建一行（库里已经有了就当 patch，逐个字段盖上）
/// - `delete`：删一行
/// - `kv`：settings / persona / layout 的几项，同 patch（网页版存的是叠了默认值的整份，JS 那边只交和原来不同的几项）
/// - `mem`：只改内存、网页版本来就不落盘的（`persist: false`）；`other`：写到网页版的图片、文件这类原生另有一套的地方；
///   `clear`：清空整个数据域。这三种都不写回，常驻表下一次照原生库重灌
///
/// 和网页版一样：拼装途中就写，不等这一轮的请求成功（网页版 engine.js 也是在 buildChatSystem 里直接 markSeen）。
extension WebPrompt {
    struct Write: Sendable, Equatable {
        var op: String
        var store: String
        var id: String
        var set: [String: JSONValue] = [:]
        var unset: [String] = []
        var row: [String: JSONValue]?
        var whole = false
        var what = ""

        init(op: String, store: String, id: String, set: [String: JSONValue] = [:], unset: [String] = [],
             row: [String: JSONValue]? = nil, whole: Bool = false) {
            self.op = op; self.store = store; self.id = id; self.set = set; self.unset = unset; self.row = row; self.whole = whole
        }

        init(json o: [String: Any]) {
            op = o["op"] as? String ?? ""
            store = o["store"] as? String ?? ""
            id = o["id"] as? String ?? ""
            set = (o["set"] as? [String: Any] ?? [:]).mapValues(JSONValue.init(any:))
            unset = o["unset"] as? [String] ?? []
            row = (o["row"] as? [String: Any]).map { $0.mapValues(JSONValue.init(any:)) }
            whole = o["whole"] as? Bool ?? false
            what = o["what"] as? String ?? ""
        }
    }

    /// 写回原生库。返回写不进去的那几条的说明（空表示全部写好了）；调用方摆到屏幕上
    @discardableResult
    static func apply(_ writes: [Write]) -> [String] {
        let db = Database.shared
        var problems: [String] = []
        for w in writes {
            do {
                switch w.op {
                case "patch":
                    // 原生库里已经没有这一行（拼装期间删了）：不复活它
                    guard var row = try db.get(w.store, id: w.id) else {
                        Diagnostics.shared.record("webprompt-write-skipped", ["op": w.op, "store": w.store, "id": w.id])
                        continue
                    }
                    for (k, v) in w.set { row.fields[k] = v }
                    for k in w.unset { row.fields[k] = nil }
                    try db.put(w.store, row)
                case "insert":
                    guard let fields = w.row, fields["id"]?.string == w.id else {
                        problems.append("\(w.store) 的一行没有 id")
                        continue
                    }
                    var row = try db.get(w.store, id: w.id) ?? Row(fields: [:])
                    for (k, v) in fields { row.fields[k] = v }
                    try db.put(w.store, row)
                case "delete":
                    try db.delete(w.store, id: w.id)
                case "kv":
                    guard [KVKey.settings, KVKey.persona, KVKey.layout].contains(w.id) else {
                        Diagnostics.shared.record("webprompt-write-skipped", ["op": w.op, "key": w.id])
                        continue
                    }
                    var obj = try db.kv(w.id)?.object ?? [:]
                    for (k, v) in w.set { obj[k] = v }
                    for k in w.unset { obj[k] = nil }
                    try db.setKV(w.id, .object(obj))
                default:
                    Diagnostics.shared.record("webprompt-write-skipped", ["op": w.op, "store": w.store, "id": w.id, "what": w.what])
                }
            } catch {
                problems.append("\(w.store) \(w.id)：\(error.localizedDescription)")
            }
        }
        return problems
    }
}
