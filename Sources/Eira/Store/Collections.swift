import Foundation

/// 数据域的名字与查询字段。
///
/// 名字和网页版 `src/system/db/index.js` 一字不差：导入、以后导出回网页版，靠的都是它。
enum Collections {
    static let characters = "characters"
    static let chats = "chats"
    static let messages = "messages"
    static let personas = "personas"
    static let memories = "memories"
    static let lorebooks = "lorebooks"

    /// 每个数据域按哪个字段查。照抄网页版 makeCollection 的 indexBy，另外给记忆加了 charId：
    /// 网页版的记忆全在内存里随便筛，原生版要从库里按角色取。
    /// 改了这张表，已经存进库的行不会自动重算 idx，要另写一次迁移。
    static let indexField: [String: String] = [
        "messages": "chatId", "spaceItems": "chatId", "events": "cell", "days": "charId",
        "recipes": "region", "meals": "charId", "health": "who", "photos": "albumId",
        "entries": "bookId", "phones": "charId", "phoneChats": "charId", "trips": "chatId",
        "scenes": "chatId", "beats": "sceneId", "works": "chatId", "chapters": "workId",
        "closet": "owner", "toolRuns": "toolId", "fates": "charId", "fateLines": "fateId",
        "fitWorkouts": "date", "fitMeals": "date", "fitDays": "date", "userSched": "owner",
        "diaries": "owner", "dreams": "charId", "memsnaps": "charId", "dramas": "charId",
        "drafts": "chatId", "impressions": "charId", "collection": "owner", "mallThreads": "itemId",
        "slips": "boxId", "slipLog": "slipId", "forumUsers": "forumId", "forumPosts": "forumId",
        "forumReports": "forumId", "forumDms": "forumId", "linkMsgs": "groupId", "cams": "targetId",
        "camLogs": "targetId", "quizRuns": "quizId",
        "memories": "charId",
    ]

    static func indexValue(_ collection: String, _ fields: [String: JSONValue]) -> String? {
        guard let key = indexField[collection], let v = fields[key] else { return nil }
        switch v {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// 同上，给导入用：直接看 JSONSerialization 读出来的字典，不必先整条转成 JSONValue。
    static func indexValue(_ collection: String, any fields: [String: Any]) -> String? {
        guard let key = indexField[collection], let v = fields[key] else { return nil }
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            return d == d.rounded() ? String(Int64(d)) : String(d)
        default: return nil
        }
    }
}

/// kv 里的固定键。前三个和网页版 schema.js 的 KV 一致。
enum KVKey {
    static let settings = "settings"
    static let persona = "persona"
    static let layout = "layout"
    /// 导入的那份备份的数据结构版本（网页版的 DATA_VERSION）。
    static let dataVersion = "dataVersion"
    static let importedAt = "importedAt"
}

enum AppPaths {
    /// 全部本地数据都在这里：数据库与图片、文件。放在 Application Support，不进「文件」app，也不会被系统当缓存清掉。
    /// 测试用：设了就用这个目录，不碰 app 自己的数据。
    nonisolated(unsafe) static var overrideRoot: URL?

    static var root: URL {
        if let overrideRoot { return overrideRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Eira", isDirectory: true)
    }
    static var media: URL { root.appendingPathComponent("media", isDirectory: true) }
}
