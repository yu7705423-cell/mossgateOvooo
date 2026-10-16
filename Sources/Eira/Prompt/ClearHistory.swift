import Foundation

/// 清空聊天记录（网页版 system/purge.js 的 counts / clearHistory，会话「更多」页的「清空聊天记录」）。
///
/// 按角色算，不按会话算：这个角色名下、各个身份的单聊都清（网页版 ownChatsOf）；群聊里还有别人说的话，不归它，不动。
/// 会话本身留着，只是空了。总结进度（memoryUpTo*、memoryTried*）、前情摘要、未读一并归零：
/// 消息没了，水位线还指着已删的消息，前情还留在提示词里（审计 #5）。已提取的记忆保留，线下各场不动（与网页版相同）。
///
/// 图片与语音：网页版清完消息后按引用表释放没人用的图、删掉语音与视频片段。原生版的媒体登记表（Database 的 media 表）
/// 还没有注销的接口，也还没有引用表（见 ChatLook、ChatFaces 的「宁可留着」），只删文件不注销会让导出报「读不出来」。
/// 所以这里**只算出**清完之后已经没有任何记录提到的那几个 id（orphans），不删（网页版第 20 条：先核引用，宁可留着）。
enum ClearHistory {
    struct Counts: Equatable {
        var chats = 0
        var messages = 0
        var memories = 0
    }

    struct Result: Equatable {
        var messages = 0
        /// 清完之后库里已经没有任何记录、设置、主屏布局提到的图片与文件 id（只算不删，见上）
        var orphanImages: [String] = []
        var orphanFiles: [String] = []
    }

    /// 这个角色名下的单聊（网页版 ownChatsOf）：characterIds 里有它、不是群
    static func ownChats(_ charId: String) throws -> [Chat] {
        try Repo.chats().filter { $0.characterIds.contains(charId) && !$0.row.bool("group") }
    }

    /// 清之前先数一遍（网页版 counts）。确认框里写明条数，不让用户蒙着点
    static func counts(_ charId: String) throws -> Counts {
        let list = try ownChats(charId)
        var n = Counts(chats: list.count)
        for c in list { n.messages += try Database.shared.all(Collections.messages, where: c.id).count }
        n.memories = try Repo.memories(charId: charId).count
        return n
    }

    /// 一条消息挂着的图（图片消息、娱乐卡卡面、视频海报）
    static func imageIds(_ m: Row) -> [String] {
        ["imageId", "cardImageId", "posterId"].map { m.string($0) }.filter { !$0.isEmpty }
    }

    /// 一条消息挂着的文件（语音、视频片段、通话里按句存下的声音，网页版 callAudio）
    static func fileIds(_ m: Row) -> [String] {
        var out = ["audioId", "clipId"].map { m.string($0) }.filter { !$0.isEmpty }
        if m.string("kind") == "call" {
            for line in m["callLog"]?.array ?? [] {
                out += (line["audio"]?.array ?? []).compactMap(\.string).filter { !$0.isEmpty }
            }
        }
        return out
    }

    /// 清空这个角色名下全部单聊的聊天记录。返回删了几条，以及清完之后没人再提到的图片与文件 id
    @discardableResult
    static func run(charId: String) throws -> Result {
        var out = Result()
        var imgs: [String] = []
        var files: [String] = []
        for chat in try ownChats(charId) {
            let rows = try Database.shared.all(Collections.messages, where: chat.id)
            for m in rows {
                imgs += imageIds(m)
                files += fileIds(m)
            }
            try Database.shared.deleteAll(Collections.messages, where: chat.id)
            out.messages += rows.count
            // 消息没了，游标不归零的话下次总结找不到位置；前情与未读同理
            guard var c = try Repo.chat(chat.id) else { continue }
            c.row["memoryUpTo"] = .null
            c.row["memoryUpToAt"] = .number(0)
            c.row["memoryUpToBeat"] = .null
            c.row["memoryUpToBeatAt"] = .number(0)
            c.row["memoryTriedId"] = .null
            c.row["memoryTriedAt"] = .number(0)
            c.row["summary"] = .string("")
            c.row["unread"] = .number(0)
            c.row.touch()
            try Repo.save(c)
        }
        let candidates = Set(imgs + files)
        if !candidates.isEmpty {
            let used = try stillMentioned(candidates)
            var seen = Set<String>()
            out.orphanImages = imgs.filter { !used.contains($0) && seen.insert($0).inserted }
            out.orphanFiles = files.filter { !used.contains($0) && seen.insert($0).inserted }
        }
        Diagnostics.shared.record("clear-history", ["charId": charId, "messages": out.messages,
                                                    "orphanImages": out.orphanImages.count, "orphanFiles": out.orphanFiles.count])
        return out
    }

    /// 这几个 id 里，库里还有记录、设置、我的人设或主屏布局提到的。按原文找，宁可多算（多算只是少删）
    static func stillMentioned(_ ids: Set<String>) throws -> Set<String> {
        var left = ids
        var used = Set<String>()
        func scan(_ text: String) {
            for id in left where text.contains(id) { used.insert(id) }
            left.subtract(used)
        }
        for name in try Database.shared.collections() {
            for data in try Database.shared.rawRows(name) {
                guard !left.isEmpty else { return used }
                scan(String(decoding: data, as: UTF8.self))
            }
        }
        for key in [KVKey.settings, KVKey.persona, KVKey.layout] where !left.isEmpty {
            if let v = try Database.shared.kv(key) { scan(String(decoding: try v.encoded(), as: UTF8.self)) }
        }
        return used
    }
}
