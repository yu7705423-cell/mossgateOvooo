import Foundation
import JavaScriptCore

/// 网页版提示词试点的常驻表（docs/jscore-prompt.md 的「常驻表」）。
///
/// JSContext 里网页版的内存镜像一直留着。第一次（以及导入、清空全部数据、换了一个库之后）整表灌一遍；
/// 之后每拼一次只问原生库的变更记录（`Database.changes`）上次之后改了哪些行，只交那几行。
///
/// 消息不整表灌（整段十万条太多）：这段会话最近 `WebPrompt.chatRows` 条、同一角色的别的会话各最近 `otherChatRows` 条，
/// 记在 `windows` 里。和从前每次现灌的那一份一样：这一次用不到的会话的消息从表里拿掉，新来的消息超出条数时去掉最早的。
/// 删了一条消息的会话整段重灌一次（窗口要往前补一条，只有库里知道是哪一条）。
///
/// 只在 WebPrompt 的串行队列上用。
final class WebPromptFeed {
    struct Stats {
        /// 这一次是不是整表灌的
        var full = false
        /// 交进去的行数与字节数
        var rows = 0
        var bytes = 0
        /// 读库（秒）与交进 JSContext（秒）
        var read: Double = 0
        var feed: Double = 0
    }

    private struct Key: Hashable { var store: String; var id: String }

    private var cursor: ChangeLog.Cursor?
    /// 表里放着哪几段会话的消息，各是最近几条
    private var windows: [String: Int] = [:]
    /// 会话 -> 角色（找「同一角色的别的会话」用，跟着 chats 的变更一起更新）
    private var chatChars: [String: [String]] = [:]
    /// 上一次拼装途中网页版写过、下一次要照原生库重灌的行与 kv（写回了就是同一份；没写回去，表里改过的那份要换回来）
    private var forced: Set<Key> = []
    private var forcedKV: Set<String> = []
    private var forceFull = false

    private static let kvKeys = [KVKey.settings, KVKey.persona, KVKey.layout]

    /// 下一次整表重灌
    func invalidate() { cursor = nil }

    /// 拼装途中网页版写了什么：那几行下一次照原生库重灌。整个数据域清空、或者写到原生不认的地方，下一次整表重灌
    func wrote(_ writes: [WebPrompt.Write]) {
        for w in writes {
            switch w.op {
            case "kv": forcedKV.insert(w.id)
            case "other", "clear": forceFull = true
            default: forced.insert(Key(store: w.store, id: w.id))
            }
        }
    }

    /// 把表同步到原生库此刻的样子，并备好这一次要的那几段会话的消息。
    /// failed：从这次同步开始，JS 里有没有抛过异常（WebPrompt 的 exceptionHandler 记着）。抛过就作废，下一次整表重灌
    func sync(api: JSValue, chat: Chat, char: Character, failed: () -> Bool) throws -> Stats {
        var stats = Stats()
        let db = Database.shared
        let (now, changes) = db.changes.since(forceFull ? nil : cursor)
        // 先作废，全部做完才记下读到哪儿：中途出错，下一次整表重灌
        cursor = nil
        var reload: Set<String> = []
        var appended: Set<String> = []
        if let changes {
            try apply(changes, api: api, db: db, stats: &stats, reload: &reload, appended: &appended)
        } else {
            try full(api: api, db: db, stats: &stats)
        }
        if failed() { throw StoreError(message: "往网页版的表里交数据时脚本出错") }
        try windowsFor(chat: chat, char: char, api: api, db: db, stats: &stats, reload: reload, appended: appended)
        if failed() { throw StoreError(message: "往网页版的表里交消息时脚本出错") }
        forced = []
        forcedKV = []
        forceFull = false
        cursor = now
        return stats
    }

    // MARK: - 整表

    private func full(api: JSValue, db: Database, stats: inout Stats) throws {
        stats.full = true
        var t = Date()
        api.invokeMethod("clearAll", withArguments: [])
        windows = [:]
        chatChars = [:]
        stats.feed += Date().timeIntervalSince(t)
        for name in try db.collections() where name != Collections.messages {
            t = Date()
            let rows = try db.rawRows(name)
            if name == Collections.chats { for r in rows { noteChat(r) } }
            let json = Self.array(rows)
            stats.read += Date().timeIntervalSince(t)
            t = Date()
            api.invokeMethod("replace", withArguments: [name, json])
            stats.feed += Date().timeIntervalSince(t)
            stats.rows += rows.count
            stats.bytes += json.utf8.count
        }
        for key in Self.kvKeys { try feedKV(key, api: api, db: db, stats: &stats) }
    }

    // MARK: - 只交变了的

    private func apply(_ changes: [ChangeLog.Change], api: JSValue, db: Database, stats: inout Stats,
                       reload: inout Set<String>, appended: inout Set<String>) throws {
        var rowIds: [String: Set<String>] = [:]
        var groups: [String: Set<String>] = [:]
        var kvs = forcedKV
        for c in changes {
            switch c {
            case .row(let s, let id): rowIds[s, default: []].insert(id)
            case .group(let s, let v): groups[s, default: []].insert(v)
            case .kv(let k): kvs.insert(k)
            }
        }
        for k in forced { rowIds[k.store, default: []].insert(k.id) }

        // 按查询字段整批删的：消息拿掉那段会话；别的数据域整个重灌（少见）
        for (store, values) in groups {
            if store == Collections.messages {
                for chatId in values {
                    api.invokeMethod("dropChat", withArguments: [chatId])
                    windows[chatId] = nil
                }
                continue
            }
            var t = Date()
            let rows = try db.rawRows(store)
            let json = Self.array(rows)
            stats.read += Date().timeIntervalSince(t)
            t = Date()
            api.invokeMethod("replace", withArguments: [store, json])
            stats.feed += Date().timeIntervalSince(t)
            stats.rows += rows.count
            stats.bytes += json.utf8.count
            if store == Collections.chats {
                chatChars = [:]
                for r in rows { noteChat(r) }
            }
            rowIds[store] = nil
        }

        for (store, idSet) in rowIds {
            let ids = Array(idSet)
            var t = Date()
            let found = try db.rawRows(store, ids: ids)
            stats.read += Date().timeIntervalSince(t)
            var put: [Data] = []
            var gone: [String] = ids.filter { found[$0] == nil }
            if store == Collections.messages {
                // 只放进表里正放着的那几段会话；别的会话的（或者挪到了别的会话的）从表里拿掉
                for (id, raw) in found {
                    let chatId = ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])?["chatId"] as? String
                    if let chatId, windows[chatId] != nil {
                        put.append(raw)
                        appended.insert(chatId)
                    } else {
                        gone.append(id)
                    }
                }
            } else {
                put = Array(found.values)
                if store == Collections.chats {
                    for raw in put { noteChat(raw) }
                    for id in gone { chatChars[id] = nil }
                }
            }
            t = Date()
            if !put.isEmpty {
                let json = Self.array(put)
                api.invokeMethod("upsert", withArguments: [store, json])
                stats.rows += put.count
                stats.bytes += json.utf8.count
            }
            if !gone.isEmpty, let data = try? JSONSerialization.data(withJSONObject: gone) {
                let out = api.invokeMethod("remove", withArguments: [store, String(decoding: data, as: UTF8.self)])
                if store == Collections.messages, let text = out?.toString(),
                   let chats = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String] {
                    // 删了一条：这段会话的窗口要往前补一条，整段重灌
                    for c in chats where windows[c] != nil { reload.insert(c) }
                }
            }
            stats.feed += Date().timeIntervalSince(t)
        }

        for key in kvs where Self.kvKeys.contains(key) { try feedKV(key, api: api, db: db, stats: &stats) }
    }

    // MARK: - 消息的窗口

    private func windowsFor(chat: Chat, char: Character, api: JSValue, db: Database, stats: inout Stats,
                            reload: Set<String>, appended: Set<String>) throws {
        var needed: [String: Int] = [chat.id: WebPrompt.chatRows]
        for (id, chars) in chatChars where id != chat.id && chars.contains(char.id) { needed[id] = WebPrompt.otherChatRows }
        for (chatId, limit) in needed {
            if windows[chatId] == limit && !reload.contains(chatId) {
                if appended.contains(chatId) {
                    let t = Date()
                    api.invokeMethod("trimChat", withArguments: [chatId, limit])
                    stats.feed += Date().timeIntervalSince(t)
                }
                continue
            }
            var t = Date()
            let rows = try db.rawLast(Collections.messages, where: chatId, limit: limit)
            let json = Self.array(rows)
            stats.read += Date().timeIntervalSince(t)
            t = Date()
            api.invokeMethod("dropChat", withArguments: [chatId])
            api.invokeMethod("upsert", withArguments: [Collections.messages, json])
            stats.feed += Date().timeIntervalSince(t)
            stats.rows += rows.count
            stats.bytes += json.utf8.count
            windows[chatId] = limit
        }
        // 这一次用不到的会话：从表里拿掉（和从前每次现灌的那一份一样，网页版的区块看不到它们）
        for chatId in Array(windows.keys) where needed[chatId] == nil {
            api.invokeMethod("dropChat", withArguments: [chatId])
            windows[chatId] = nil
        }
    }

    // MARK: - 小工具

    private func feedKV(_ key: String, api: JSValue, db: Database, stats: inout Stats) throws {
        let t = Date()
        if let v = try db.kv(key) {
            let text = String(decoding: try v.encoded(), as: UTF8.self)
            api.invokeMethod("kv", withArguments: [key, text])
            stats.bytes += text.utf8.count
        } else {
            api.invokeMethod("kv", withArguments: [key, NSNull()])
        }
        stats.feed += Date().timeIntervalSince(t)
    }

    private func noteChat(_ raw: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any], let id = o["id"] as? String else { return }
        chatChars[id] = o["characterIds"] as? [String] ?? []
    }

    /// 几行原文拼成一个 JSON 数组的原文
    static func array(_ rows: [Data]) -> String {
        var d = Data("[".utf8)
        for (i, r) in rows.enumerated() {
            if i > 0 { d.append(0x2C) }
            d.append(r)
        }
        d.append(0x5D)
        return String(decoding: d, as: UTF8.self)
    }
}
