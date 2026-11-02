import Foundation
import SQLite3

/// 写库或读库失败。界面上要把 `message` 原样摆出来（网页版第 20 条：任何写入失败都不许只记在日志里）。
struct StoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 本地数据库。
///
/// 一张 `records` 表装下所有数据域：一行是网页版里的一条记录，`json` 是它的全文。
/// 和网页版的 IndexedDB 一一对应 —— 网页版有八十多个数据域，原生版暂时只认其中几个，
/// 但导入时全部原样存下，以后支持哪一个都不用再导一次。
///
/// `idx` 是按数据域选定的那个查询字段（消息按 chatId、记忆按 charId……），见 `Collections.indexField`。
/// `created` 取记录的 createdAt，用来排序。
///
/// 所有读写走同一条串行队列，一条连接。
///
/// `msgtext` 是消息的搜索索引（「查询消息记录」用）：每条消息一行，存正文与译文折叠大小写之后的那一份，
/// 搜索时先在这里用 instr 筛出候选，再把候选按原来的规则逐条核对，不必把每一条消息的 JSON 都解析一遍。
/// 它只是索引，丢了、旧了都能从 `records` 重建；搜索时 JOIN 回 `records`，索引里多出来的行不会冒出来。
/// 老库第一次打开时没有这份索引，在后台分批补（`maintainSearchIndex`），补完之前搜索照旧逐条读。
final class Database: @unchecked Sendable {
    /// 测试里会换成临时目录里的一份，见 Tests/Support.swift。
    nonisolated(unsafe) static var shared: Database = {
        do { return try Database(url: Database.defaultURL) }
        catch { fatalError("打不开本地数据库：\(error.localizedDescription)") }
    }()

    static var defaultURL: URL {
        let dir = AppPaths.root
        return dir.appendingPathComponent("eira.sqlite")
    }

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "eira.database")
    /// kv 与媒体登记的内存副本，只在 queue 上读写。设置每画一次界面要读好几次，每次都查库、解析整份 JSON 太慢；
    /// 所有写 kv 与 media 的路径都在本文件里，写的时候一并更新或清掉
    private var kvCache: [String: JSONValue?] = [:]
    private var mediaCache: [String: String?] = [:]
    /// msgtext 是否已经盖住了全部消息。只在 queue 上读写。false 时搜索走逐条读的老路
    private var msgtextReady = false
    /// 后台补索引每一批多少条。一批在 queue 上做完，期间别的读写排队，所以不要太大
    private static let fillChunk = 2000

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知原因"
            throw StoreError(message: "打不开本地数据库：\(msg)")
        }
        try queue.sync {
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA foreign_keys=OFF")
            try exec("""
                CREATE TABLE IF NOT EXISTS records (
                  collection TEXT NOT NULL,
                  id TEXT NOT NULL,
                  idx TEXT,
                  created REAL,
                  json BLOB NOT NULL,
                  PRIMARY KEY (collection, id)
                )
                """)
            try exec("CREATE INDEX IF NOT EXISTS records_idx ON records (collection, idx, created)")
            try exec("CREATE INDEX IF NOT EXISTS records_created ON records (collection, created)")
            try exec("CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v BLOB NOT NULL)")
            try exec("""
                CREATE TABLE IF NOT EXISTS media (
                  kind TEXT NOT NULL,
                  id TEXT NOT NULL,
                  ext TEXT NOT NULL,
                  bytes INTEGER NOT NULL,
                  PRIMARY KEY (kind, id)
                )
                """)
            try exec("""
                CREATE TABLE IF NOT EXISTS msgtext (
                  id TEXT PRIMARY KEY,
                  chat TEXT,
                  created REAL,
                  skip INTEGER NOT NULL DEFAULT 0,
                  fold TEXT NOT NULL
                )
                """)
            try exec("CREATE INDEX IF NOT EXISTS msgtext_chat ON msgtext (chat, created)")
            // 原生版自己的记号（不进备份，不和网页版的 kv 混在一起）
            try exec("CREATE TABLE IF NOT EXISTS native_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
            if try metaGet("msgtext") == "1" {
                msgtextReady = true
            } else if try countLocked(Collections.messages) == 0 {
                // 新库，或者库里还没有消息：索引从第一条起跟着写，现在就算齐
                try exec("DELETE FROM msgtext")
                try metaSet("msgtext", "1")
                msgtextReady = true
            }
        }
        // 核对与补齐在后台做，不挡开机
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.maintainSearchIndex() }
    }

    deinit { sqlite3_close_v2(handle) }

    /// 关掉连接。测试删临时目录之前用；之后这个对象不能再用。
    func close() {
        queue.sync {
            sqlite3_close_v2(handle)
            handle = nil
        }
    }

    // MARK: - 记录

    func put(_ collection: String, _ row: Row) throws {
        try queue.sync { try putLocked(collection, row) }
    }

    func get(_ collection: String, id: String) throws -> Row? {
        try queue.sync {
            try query("SELECT json FROM records WHERE collection = ? AND id = ?", [collection, id]) { stmt in
                try Row(data: Self.blob(stmt, 0))
            }.first
        }
    }

    /// 一个数据域的全部记录，按创建时间排。
    func all(_ collection: String) throws -> [Row] {
        try queue.sync {
            try query("SELECT json FROM records WHERE collection = ? ORDER BY created, id", [collection]) { stmt in
                try Row(data: Self.blob(stmt, 0))
            }
        }
    }

    /// 按查询字段取，比如某段会话的全部消息。
    func all(_ collection: String, where value: String) throws -> [Row] {
        try queue.sync {
            try query("SELECT json FROM records WHERE collection = ? AND idx = ? ORDER BY created, id",
                      [collection, value]) { stmt in
                try Row(data: Self.blob(stmt, 0))
            }
        }
    }

    /// 按查询字段取最后几条（按创建时间）。聊天页只画最近一段时用。
    func last(_ collection: String, where value: String, limit: Int) throws -> [Row] {
        try queue.sync {
            try query("""
                SELECT json FROM (
                  SELECT json, created, id FROM records WHERE collection = ? AND idx = ?
                  ORDER BY created DESC, id DESC LIMIT ?
                ) ORDER BY created, id
                """, [collection, value, limit]) { stmt in
                try Row(data: Self.blob(stmt, 0))
            }
        }
    }

    func count(_ collection: String) throws -> Int {
        try queue.sync { try countLocked(collection) }
    }

    /// 按查询字段取 createdAt 不早于 since 的那些，按创建时间排。积压只在水位线之后，不必读整段。
    func all(_ collection: String, where value: String, since: Double) throws -> [Row] {
        try queue.sync {
            try query("SELECT json FROM records WHERE collection = ? AND idx = ? AND created >= ? ORDER BY created, id",
                      [collection, value, since]) { stmt in
                try Row(data: Self.blob(stmt, 0))
            }
        }
    }

    /// 从 id 那一条到末尾一共几条（含它自己），顺序同 `all(_:where:)`。跳到很早的一条时用来算要画多少条，
    /// 不必把整段读出来找下标。那一条不在这里（不存在，或者不属于 value）时为 nil。
    func countFrom(_ collection: String, where value: String, id: String) throws -> Int? {
        try queue.sync {
            let at = try query("SELECT created FROM records WHERE collection = ? AND id = ? AND idx = ?",
                               [collection, id, value]) { stmt -> Double? in
                sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 0)
            }
            guard let found = at.first else { return nil }
            let sql: String
            let args: [Any?]
            if let t = found {
                sql = "SELECT COUNT(*) FROM records WHERE collection = ? AND idx = ? AND (created > ? OR (created = ? AND id >= ?))"
                args = [collection, value, t, t, id]
            } else {
                // 没有 createdAt 的排在最前面
                sql = "SELECT COUNT(*) FROM records WHERE collection = ? AND idx = ? AND (created IS NOT NULL OR id >= ?)"
                args = [collection, value, id]
            }
            return try query(sql, args) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        }
    }

    /// 按查询字段数一数有几条（「还有 N 条更早的消息」）
    func count(_ collection: String, where value: String) throws -> Int {
        try queue.sync {
            try query("SELECT COUNT(*) FROM records WHERE collection = ? AND idx = ?", [collection, value]) { stmt in
                Int(sqlite3_column_int64(stmt, 0))
            }.first ?? 0
        }
    }

    /// 每个数据域各有多少条。导入完摆给用户看。
    func counts() throws -> [String: Int] {
        try queue.sync {
            var out: [String: Int] = [:]
            _ = try query("SELECT collection, COUNT(*) FROM records GROUP BY collection", []) { stmt in
                out[Self.text(stmt, 0)] = Int(sqlite3_column_int64(stmt, 1))
            }
            return out
        }
    }

    func delete(_ collection: String, id: String) throws {
        try queue.sync {
            try run("DELETE FROM records WHERE collection = ? AND id = ?", [collection, id])
            // 索引里留下的行搜索时 JOIN 不回记录，不会冒出来；删不掉只记着下次开机重建
            if collection == Collections.messages {
                do { try run("DELETE FROM msgtext WHERE id = ?", [id]) } catch { searchIndexBroke() }
            }
        }
    }

    /// 删掉一个数据域里查询字段等于 value 的全部记录（比如某段会话的全部消息）。
    func deleteAll(_ collection: String, where value: String) throws {
        try queue.sync {
            try run("DELETE FROM records WHERE collection = ? AND idx = ?", [collection, value])
            if collection == Collections.messages {
                do { try run("DELETE FROM msgtext WHERE chat = ?", [value]) } catch { searchIndexBroke() }
            }
        }
    }

    /// 库里有记录的全部数据域。导出时一个不落。
    func collections() throws -> [String] {
        try queue.sync {
            try query("SELECT DISTINCT collection FROM records ORDER BY collection", []) { Self.text($0, 0) }
        }
    }

    /// 一个数据域的全部记录的原文，不解析。导出时用。
    func rawRows(_ collection: String) throws -> [Data] {
        try queue.sync {
            try query("SELECT json FROM records WHERE collection = ? ORDER BY created, id", [collection]) { Self.blob($0, 0) }
        }
    }

    /// 同上，一批一批交出来（顺序同样是 created、id）。几十万条消息时不必整份握在内存里，
    /// 每一批读完就放开队列，导出期间界面上的读写不必等到整个数据域读完。body 在队列外调用，可以再读库。
    func rawRows(_ collection: String, chunk: Int, _ body: ([Data]) throws -> Void) throws {
        let n = max(1, chunk)
        // 先是没有 createdAt 的（ORDER BY created 时它们排在最前面），按 id 接着取。
        // INDEXED BY：不写的话查询计划为了省掉排序会沿主键把这个数据域整个扫一遍（这种行通常一条都没有）
        var lastId: String?
        while true {
            let sql: String
            let args: [Any?]
            if let lastId {
                sql = "SELECT id, json FROM records INDEXED BY records_created WHERE collection = ? AND created IS NULL AND id > ? ORDER BY id LIMIT ?"
                args = [collection, lastId, n]
            } else {
                sql = "SELECT id, json FROM records INDEXED BY records_created WHERE collection = ? AND created IS NULL ORDER BY id LIMIT ?"
                args = [collection, n]
            }
            let page: [(id: String, json: Data)] = try queue.sync {
                try query(sql, args) { (id: Self.text($0, 0), json: Self.blob($0, 1)) }
            }
            if !page.isEmpty { try body(page.map(\.json)) }
            if page.count < n { break }
            lastId = page.last?.id
        }
        // 再是有 createdAt 的，按 (created, id) 接着取
        var lastKey: (created: Double, id: String)?
        while true {
            let page: [(created: Double, id: String, json: Data)] = try queue.sync {
                let map: (OpaquePointer) -> (created: Double, id: String, json: Data) = {
                    (created: sqlite3_column_double($0, 0), id: Self.text($0, 1), json: Self.blob($0, 2))
                }
                if let k = lastKey {
                    return try query("""
                        SELECT created, id, json FROM records WHERE collection = ? AND created >= ? AND (created > ? OR id > ?)
                        ORDER BY created, id LIMIT ?
                        """, [collection, k.created, k.created, k.id, n], map)
                }
                return try query("SELECT created, id, json FROM records WHERE collection = ? AND created IS NOT NULL ORDER BY created, id LIMIT ?",
                                 [collection, n], map)
            }
            if !page.isEmpty { try body(page.map(\.json)) }
            if page.count < n { break }
            if let last = page.last { lastKey = (last.created, last.id) }
        }
    }

    /// 登记过的全部图片与文件。
    func allMedia() throws -> [(kind: String, id: String, ext: String)] {
        try queue.sync {
            try query("SELECT kind, id, ext FROM media ORDER BY kind, id", []) {
                (Self.text($0, 0), Self.text($0, 1), Self.text($0, 2))
            }
        }
    }

    /// 登记过的图片与文件一共多大，字节。
    func mediaBytes() throws -> Int {
        try queue.sync {
            try query("SELECT COALESCE(SUM(bytes), 0) FROM media", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        }
    }

    /// 清空全部数据（网页版 backup.js 的 wipeAll）：全部记录、图片与文件的登记、我的人设与主屏布局。
    /// 设置（接口配置与密钥）留着。图片与文件本身由调用方在这之后删掉。
    func wipe() throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE")
            do {
                try exec("DELETE FROM records")
                try exec("DELETE FROM msgtext")
                try exec("DELETE FROM media")
                try run("DELETE FROM kv WHERE k IN (?, ?)", [KVKey.persona, KVKey.layout])
                try exec("COMMIT")
                kvCache = [:]; mediaCache = [:]
                // 消息一条都不剩，索引也是空的：算齐
                msgtextReady = true
                try? metaSet("msgtext", "1")
            } catch {
                try? exec("ROLLBACK")
                kvCache = [:]; mediaCache = [:]
                throw error
            }
        }
    }

    // MARK: - kv

    func kv(_ key: String) throws -> JSONValue? {
        try queue.sync {
            if let hit = kvCache[key] { return hit }
            let v = try query("SELECT v FROM kv WHERE k = ?", [key]) { stmt in
                try JSONValue.parse(Self.blob(stmt, 0))
            }.first
            kvCache[key] = .some(v)
            return v
        }
    }

    func setKV(_ key: String, _ value: JSONValue) throws {
        let data = try value.encoded()
        try queue.sync {
            do { try run("INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)", [key, data]); kvCache[key] = .some(value) }
            catch { kvCache[key] = nil; throw error }
        }
    }

    // MARK: - 图片与文件的登记（内容在 MediaStore 管的目录里）

    func mediaExt(kind: String, id: String) throws -> String? {
        try queue.sync {
            let key = kind + "/" + id
            if let hit = mediaCache[key] { return hit }
            let v = try query("SELECT ext FROM media WHERE kind = ? AND id = ?", [kind, id]) { stmt in
                Self.text(stmt, 0)
            }.first
            // 没登记的不记：图片可能下一刻就存进来
            if let v { mediaCache[key] = .some(v) }
            return v
        }
    }

    /// 新存一张图或一个文件之后登记。内容已经由调用方写进 MediaStore 的目录。
    func registerMedia(kind: String, id: String, ext: String, bytes: Int) throws {
        try queue.sync {
            try run("INSERT OR REPLACE INTO media (kind, id, ext, bytes) VALUES (?, ?, ?, ?)", [kind, id, ext, bytes])
            mediaCache[kind + "/" + id] = .some(ext)
        }
    }

    // MARK: - 整批替换

    /// 导入备份用：在一个事务里清空全部记录与媒体登记，再写入新的。
    /// 中途任何一步失败都整体回滚，库保持导入之前的样子。
    func replaceAll(_ body: (Batch) throws -> Void) throws {
        try queue.sync {
            let wasReady = msgtextReady
            try exec("BEGIN IMMEDIATE")
            do {
                try exec("DELETE FROM records")
                try exec("DELETE FROM msgtext")
                try exec("DELETE FROM media")
                kvCache = [:]; mediaCache = [:]
                // 导进来的每一条消息都由 Batch.put 写上索引，导完就是齐的；中途哪一条索引没写上，indexMessageLocked 会把它改回 false
                msgtextReady = true
                try body(Batch(db: self))
                try exec("COMMIT")
                kvCache = [:]; mediaCache = [:]
                if msgtextReady { try? metaSet("msgtext", "1") }
            } catch {
                try? exec("ROLLBACK")
                kvCache = [:]; mediaCache = [:]
                // 回滚之后库与索引都回到导入之前的样子
                msgtextReady = wasReady
                throw error
            }
        }
    }

    /// `replaceAll` 里交出来的写入口。只在那个事务里有效。
    struct Batch {
        fileprivate let db: Database
        func put(_ collection: String, id: String, json: Data, idx: String?, created: Double?) throws {
            try db.run("INSERT OR REPLACE INTO records (collection, id, idx, created, json) VALUES (?, ?, ?, ?, ?)",
                       [collection, id, idx, created, json])
            if collection == Collections.messages {
                let fields = ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any]) ?? [:]
                db.indexMessageLocked(id: id, chat: idx, created: created, Database.searchParts(any: fields))
            }
        }
        func setKV(_ key: String, _ value: JSONValue) throws {
            try db.run("INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)", [key, try value.encoded()])
        }
        func registerMedia(kind: String, id: String, ext: String, bytes: Int) throws {
            try db.run("INSERT OR REPLACE INTO media (kind, id, ext, bytes) VALUES (?, ?, ?, ?)",
                       [kind, id, ext, bytes])
        }
    }

    // MARK: - 底层

    private func putLocked(_ collection: String, _ row: Row) throws {
        let json = try row.encoded()
        let idx = Collections.indexValue(collection, row.fields)
        try run("INSERT OR REPLACE INTO records (collection, id, idx, created, json) VALUES (?, ?, ?, ?, ?)",
                [collection, row.id, idx, row.created, json])
        if collection == Collections.messages {
            indexMessageLocked(id: row.id, chat: idx, created: row.created, Self.searchParts(row.fields))
        }
    }

    private func countLocked(_ collection: String) throws -> Int {
        try query("SELECT COUNT(*) FROM records WHERE collection = ?", [collection]) { stmt in
            Int(sqlite3_column_int64(stmt, 0))
        }.first ?? 0
    }

    // MARK: - 消息搜索索引

    /// 一条消息里搜索要看的几项。和 ChatSearch 的 searchable 与过滤条件一一对应
    struct SearchParts {
        var content = ""
        var translation = ""
        var status = ""
        var kind = ""
        /// 正文与译文：译文为空时只有正文，否则中间隔一个换行（同 ChatSearch.searchable）
        var text: String { translation.isEmpty ? content : "\(content)\n\(translation)" }
        /// 失败的与「正在输入」的永远搜不到
        var skip: Bool { status == "error" || kind == "typing" }
    }

    static func searchParts(_ f: [String: JSONValue]) -> SearchParts {
        SearchParts(content: f["content"]?.string ?? "", translation: f["translation"]?.string ?? "",
                    status: f["status"]?.string ?? "", kind: f["kind"]?.string ?? "")
    }

    static func searchParts(any f: [String: Any]) -> SearchParts {
        SearchParts(content: f["content"] as? String ?? "", translation: f["translation"] as? String ?? "",
                    status: f["status"] as? String ?? "", kind: f["kind"] as? String ?? "")
    }

    /// 存进索引、拿来比的那一份：折叠大小写，再拆成标准分解形式。正文和搜索词都这样处理，
    /// 「不分大小写地包含」就变成了逐字节的包含。只用来筛候选，最后仍按 range(of:options: .caseInsensitive) 核对
    static func searchFold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive], locale: nil).decomposedStringWithCanonicalMapping
    }

    /// 写一条消息的索引。失败不连累消息本身的写入：索引记成不完整，搜索退回逐条读，下次开机重建
    fileprivate func indexMessageLocked(id: String, chat: String?, created: Double?, _ p: SearchParts) {
        do {
            try run("INSERT OR REPLACE INTO msgtext (id, chat, created, skip, fold) VALUES (?, ?, ?, ?, ?)",
                    [id, chat, created, p.skip ? 1 : 0, Self.searchFold(p.text)])
        } catch {
            searchIndexBroke()
        }
    }

    /// 索引不再可信：这次运行里搜索退回逐条读；记号写不进去也不要紧，下次开机核对条数时会发现对不上
    private func searchIndexBroke() {
        msgtextReady = false
        try? metaSet("msgtext", "0")
    }

    /// 在一段会话里用索引筛：正文或译文折叠后包含 needle（已经过 searchFold）的、不是失败也不是「正在输入」的，
    /// 按 created、id 升序（同 `all(_:where:)`）。索引还没补齐时为 nil，调用方照旧逐条读。
    /// CROSS JOIN 让 SQLite 从索引这一边走：先在 msgtext 里筛，命中的才回 records 取原文（不写的话它会先把这段会话的每一条记录读出来）
    func searchMessages(chatId: String, folded needle: String) throws -> [Row]? {
        try queue.sync {
            guard msgtextReady else { return nil }
            return try query("""
                SELECT r.json FROM msgtext t
                CROSS JOIN records r ON r.collection = 'messages' AND r.id = t.id AND r.idx = t.chat
                WHERE t.chat = ? AND t.skip = 0 AND instr(t.fold, ?) > 0
                ORDER BY r.created, r.id
                """, [chatId, needle]) { stmt in
                try Row(data: Self.blob(stmt, 0))
            }
        }
    }

    /// 索引是否已经补齐。测试与诊断用
    var searchIndexReady: Bool { queue.sync { msgtextReady } }

    /// 开机后在后台跑：核对索引与消息的条数，对不上（比如装过旧版本、在旧版本里写过消息）就清掉重建；
    /// 没补齐的一批一批补，每批之间放开队列。中途关掉 app 也不要紧，下次从记下的位置接着补。
    /// 只读 records、只写 msgtext 与 native_meta，消息本身一条都不动。
    func maintainSearchIndex() {
        let needFill: Bool = (try? queue.sync { () throws -> Bool in
            guard handle != nil else { return false }
            guard msgtextReady else { return true }
            let a = try countLocked(Collections.messages)
            let b = try query("SELECT COUNT(*) FROM msgtext", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
            guard a != b else { return false }
            msgtextReady = false
            try metaSet("msgtext", "0")
            try metaSet("msgtextAt", "0")
            try exec("DELETE FROM msgtext")
            return true
        }) ?? false
        guard needFill else { return }
        while true {
            // 出错就停在这里：搜索继续走逐条读的老路，下次开机再补
            guard let done = try? queue.sync(execute: { try fillSearchIndexChunk() }), !done else { return }
        }
    }

    /// 补一批。返回 true 表示补齐了（或者库已经关了）
    private func fillSearchIndexChunk() throws -> Bool {
        guard handle != nil else { return true }
        if msgtextReady { return true }
        let saved = try metaGet("msgtextAt") ?? "0"
        var cursor = Int(saved) ?? 0
        // 按 rowid 往后走：老记录的 rowid 不会变；这之后新写、改写的消息都已经由 putLocked 带上了索引。
        // `+collection` 不让查询计划去用以 collection 打头的索引（那样每一批都要把全部消息按 rowid 排一遍），只沿 rowid 往后扫
        let rows: [(rowid: Int, id: String, idx: String?, created: Double?, json: Data)] = try query(
            "SELECT rowid, id, idx, created, json FROM records WHERE +collection = ? AND rowid > ? ORDER BY rowid LIMIT ?",
            [Collections.messages, cursor, Self.fillChunk]) { stmt in
            (rowid: Int(sqlite3_column_int64(stmt, 0)), id: Self.text(stmt, 1),
             idx: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Self.text(stmt, 2),
             created: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3),
             json: Self.blob(stmt, 4))
        }
        let finished = rows.count < Self.fillChunk
        try exec("SAVEPOINT msgtext_fill")
        do {
            for r in rows {
                let fields = ((try? JSONSerialization.jsonObject(with: r.json)) as? [String: Any]) ?? [:]
                let p = Self.searchParts(any: fields)
                try run("INSERT OR REPLACE INTO msgtext (id, chat, created, skip, fold) VALUES (?, ?, ?, ?, ?)",
                        [r.id, r.idx, r.created, p.skip ? 1 : 0, Self.searchFold(p.text)])
                cursor = r.rowid
            }
            try metaSet("msgtextAt", String(cursor))
            if finished { try metaSet("msgtext", "1") }
            try exec("RELEASE msgtext_fill")
        } catch {
            try? exec("ROLLBACK TO msgtext_fill")
            try? exec("RELEASE msgtext_fill")
            throw error
        }
        if finished { msgtextReady = true }
        return finished
    }

    private func metaGet(_ k: String) throws -> String? {
        try query("SELECT v FROM native_meta WHERE k = ?", [k]) { Self.text($0, 0) }.first
    }

    private func metaSet(_ k: String, _ v: String) throws {
        try run("INSERT OR REPLACE INTO native_meta (k, v) VALUES (?, ?)", [k, v])
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "未知原因"
            sqlite3_free(err)
            throw StoreError(message: "本地数据库出错：\(msg)")
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError(message: "本地数据库出错：\(String(cString: sqlite3_errmsg(handle)))")
        }
        for (i, arg) in args.enumerated() {
            let at = Int32(i + 1)
            switch arg {
            case nil:
                sqlite3_bind_null(stmt, at)
            case let s as String:
                sqlite3_bind_text(stmt, at, s, -1, SQLITE_TRANSIENT)
            case let d as Data:
                _ = d.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, at, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                }
            case let n as Int:
                sqlite3_bind_int64(stmt, at, Int64(n))
            case let n as Double:
                sqlite3_bind_double(stmt, at, n)
            default:
                sqlite3_bind_null(stmt, at)
            }
        }
        return stmt
    }

    fileprivate func run(_ sql: String, _ args: [Any?]) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError(message: "写入本地数据库失败：\(String(cString: sqlite3_errmsg(handle)))")
        }
    }

    private func query<T>(_ sql: String, _ args: [Any?], _ map: (OpaquePointer) throws -> T) throws -> [T] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(try map(stmt)) }
            else if rc == SQLITE_DONE { break }
            else { throw StoreError(message: "读取本地数据库失败：\(String(cString: sqlite3_errmsg(handle)))") }
        }
        return out
    }

    private static func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(stmt, col))
        guard n > 0, let p = sqlite3_column_blob(stmt, col) else { return Data() }
        return Data(bytes: p, count: n)
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: p)
    }
}
