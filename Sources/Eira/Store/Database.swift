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
        }
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
        try queue.sync {
            try query("SELECT COUNT(*) FROM records WHERE collection = ?", [collection]) { stmt in
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
        }
    }

    /// 删掉一个数据域里查询字段等于 value 的全部记录（比如某段会话的全部消息）。
    func deleteAll(_ collection: String, where value: String) throws {
        try queue.sync {
            try run("DELETE FROM records WHERE collection = ? AND idx = ?", [collection, value])
        }
    }

    // MARK: - kv

    func kv(_ key: String) throws -> JSONValue? {
        try queue.sync {
            try query("SELECT v FROM kv WHERE k = ?", [key]) { stmt in
                try JSONValue.parse(Self.blob(stmt, 0))
            }.first
        }
    }

    func setKV(_ key: String, _ value: JSONValue) throws {
        let data = try value.encoded()
        try queue.sync {
            try run("INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)", [key, data])
        }
    }

    // MARK: - 图片与文件的登记（内容在 MediaStore 管的目录里）

    func mediaExt(kind: String, id: String) throws -> String? {
        try queue.sync {
            try query("SELECT ext FROM media WHERE kind = ? AND id = ?", [kind, id]) { stmt in
                Self.text(stmt, 0)
            }.first
        }
    }

    /// 新存一张图或一个文件之后登记。内容已经由调用方写进 MediaStore 的目录。
    func registerMedia(kind: String, id: String, ext: String, bytes: Int) throws {
        try queue.sync {
            try run("INSERT OR REPLACE INTO media (kind, id, ext, bytes) VALUES (?, ?, ?, ?)", [kind, id, ext, bytes])
        }
    }

    // MARK: - 整批替换

    /// 导入备份用：在一个事务里清空全部记录与媒体登记，再写入新的。
    /// 中途任何一步失败都整体回滚，库保持导入之前的样子。
    func replaceAll(_ body: (Batch) throws -> Void) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE")
            do {
                try exec("DELETE FROM records")
                try exec("DELETE FROM media")
                try body(Batch(db: self))
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
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
        try run("INSERT OR REPLACE INTO records (collection, id, idx, created, json) VALUES (?, ?, ?, ?, ?)",
                [collection, row.id, Collections.indexValue(collection, row.fields), row.created, json])
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
