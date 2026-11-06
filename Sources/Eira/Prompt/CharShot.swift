import CryptoKit
import Foundation

/// 角色截下和你的聊天记录（网页版 system/charshot.js，ARCHITECTURE 4.904、4.936）。
///
/// 角色在回复里单独写一行 `[截图：从「那句原话」开始|说明]`：从最后一条含着那句原话的消息截到这一轮之前，没写原话截最近 6 条。
/// 加 `|私密` 存进第一本有密码的本子，一本都没有就建一本「私密」，密码用这台手机的锁屏密码。**截的时候聊天里什么都不留**
/// （用户定的：「给一个惊喜」），只有翻角色的手机才看得到。`[发截图：说明]` 从它存过的里挑一张发进聊天（kind charshot，
/// 正文 `[聊天截图：说明]` 给模型读）；一张都没存过就什么都不发（网页版第 22 条：不凭空编）。
///
/// 截图存在角色手机的 photos 里（kind: shot），和网页版同一份字段：msgs（冻起来的消息副本）、shotId（那一刻的美化 CSS 快照，
/// 存在 shots 数据域里，按内容哈希去重）、chatId、note。**是角色那一边的截图**：冻副本时两边对调，角色自己说的在右边（role user），
/// 你说的在左边，你的名字是角色给你存的备注。旁白不截（4.936）。全在本机做，不调接口（第 15 条）。
/// 网页版另在后台画一张 png 挂在 imageId 上；原生版按冻下的消息副本画，不另存图。
enum CharShot {
    static let fallback = 6
    private static let skip: Set<String> = ["typing", "notice", "narration"]

    /// 新功能（第 24 条）开着、并且「设定集 - 能力开关」没关掉
    static func capOn(_ char: Character?, _ s: AppSettings = .load()) -> Bool {
        let off = Set((s.raw["capsOff"]?.array ?? []).compactMap(\.string))
        return NewFeat.capOn("charshot", s, char: char) && !off.contains("charshot")
    }

    /// 去掉空白、引号与标点再比，模型抄原话时常改一两个标点
    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: #"[\s「」『』"“”'‘’，。！？、,.!?…~～]"#, with: "", options: .regularExpression).lowercased()
    }

    /// 这一段对话里、这一轮之前的消息。这一轮自己刚落下的不算（角色截的是已经发生的）
    static func before(_ msgs: [Message], turnId: String) -> [Message] {
        let list = msgs.filter { !skip.contains($0.kind) && !$0.isError }
        return turnId.isEmpty ? list : list.filter { !($0.turnId == turnId && $0.role == .char) }
    }

    /// 从哪一条截起：最后一条正文里含着那句原话的。对不上回 nil
    static func startOf(_ list: [Message], quote: String) -> Int? {
        let q = norm(quote)
        guard !q.isEmpty else { return nil }
        return list.lastIndex { norm($0.content).contains(q) }
    }

    struct Parsed: Equatable { var quote: String; var note: String; var priv: Bool }

    /// 解析 [截图：…] 冒号后面那一段：从「原话」开始 | 说明 | 私密。三样都可有可无
    static func parse(_ raw: String) -> Parsed {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let quote = s.range(of: #"[「『"“]([^」』"”]+)[」』"”]"#, options: .regularExpression).map { r -> String in
            String(s[r].dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        } ?? ""
        let parts = s.components(separatedBy: CharacterSet(charactersIn: "|｜")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let isPriv: (String) -> Bool = { $0.range(of: #"^(私密|private|locked)$"#, options: [.regularExpression, .caseInsensitive]) != nil }
        let rest = parts.filter { !isPriv($0) }
            .map { $0.replacingOccurrences(of: #"^从?\s*[「『"“][^」』"”]+[」』"”]\s*(开始|起)?\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Parsed(quote: quote, note: rest.joined(separator: " "), priv: parts.contains(where: isPriv))
    }

    /// 存进哪一本：要私密的放进第一本有密码的；一本都没有就建一本「私密」，密码用这台手机的锁屏密码
    static func albumFor(_ charId: String, priv: Bool) throws -> String {
        guard priv else { return "" }
        if let locked = Theirs.albums(charId).first(where: { !$0.code.isEmpty }) { return locked.id }
        return try Theirs.addAlbum(charId, name: "私密", code: Theirs.lock(charId)?.code ?? "").id
    }

    /// 冻起来的消息副本（网页版 album.freeze）：原消息以后删了、改了，截图都是当时那个样子
    static func freeze(_ msgs: [Message], meName: String, meAvatar: String) -> [JSONValue] {
        msgs.map { m in
            let mine = m.role == .user
            let author = mine ? nil : ((try? Repo.character(m.authorId)) ?? nil)
            var o: [String: JSONValue] = [
                "id": .string(m.id), "role": .string(m.role.rawValue), "kind": .string(m.kind), "content": .string(m.content),
                "imageId": m.imageId.isEmpty ? .null : .string(m.imageId),
                "stickerId": m.row.string("stickerId").isEmpty ? .null : .string(m.row.string("stickerId")),
                "createdAt": .number(m.createdAt),
                "_name": .string(mine ? meName : (author?.name ?? "")),
            ]
            let face = mine ? meAvatar : (author?.avatar ?? "")
            o["_avatar"] = face.isEmpty ? .null : .string(face)
            return .object(o)
        }
    }

    /// 美化 CSS 快照（网页版 album.keepShot）：按内容哈希取 id，同样的内容共用一份
    static func keepShot(_ css: String) throws -> String {
        let digest = SHA256.hash(data: Data(css.utf8))
        let id = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        if try Database.shared.get("shots", id: id) == nil {
            try Database.shared.put("shots", Row(fields: ["id": .string(id), "css": .string(css), "createdAt": .number(Date().millis)]))
        }
        return id
    }

    /// 截一张。截不到（这段对话还没有消息）回 nil。回存下的那一张在 photos 里的 id
    @discardableResult
    static func take(chat: Chat, char: Character, raw: String, turnId: String) throws -> String? {
        let p = parse(raw)
        let list = before(try Repo.messages(chatId: chat.id), turnId: turnId)
        guard !list.isEmpty else { return nil }
        let picked = startOf(list, quote: p.quote).map { Array(list[$0...]) } ?? Array(list.suffix(fallback))
        let me = ((try? Repo.personas()) ?? []).first { $0.id == chat.personaId } ?? ((try? Repo.activePersona()) ?? nil)
        let meFace = ChatFaces.of(chat, key: ChatFaces.me, fallback: me?.avatar ?? "")
        let remark = chat.row.string("charRemark").trimmingCharacters(in: .whitespaces)
        let youName = remark.isEmpty ? (me?.name ?? "我") : remark
        // 角色那一边：你说的放左边、名字写它给你的备注；它自己说的放右边
        let frozen: [JSONValue] = freeze(picked, meName: me?.name ?? "我", meAvatar: meFace).map { v in
            guard var o = v.object else { return v }
            if o["role"]?.string == "user" {
                o["role"] = .string("char"); o["_name"] = .string(youName); o["_avatar"] = meFace.isEmpty ? .null : .string(meFace)
            } else if o["role"]?.string == "char" {
                o["role"] = .string("user"); o["_name"] = .string(char.name); o["_avatar"] = char.avatar.isEmpty ? .null : .string(char.avatar)
            }
            return .object(o)
        }
        // 这个角色自己的截图美化（4.936）接在当前美化后面，后写的赢
        let css = [AppSettings.load().raw["customCSS"]?.string ?? "", char.row.string("shotCss")].filter { !$0.isEmpty }.joined(separator: "\n")
        let shotId = try keepShot(css)
        let note = p.note.isEmpty ? (p.quote.isEmpty ? "聊天记录" : "从「\(p.quote)」开始") : p.note
        let row: JSONValue = .object(["kind": .string("shot"), "msgs": .array(frozen), "shotId": .string(shotId),
                                      "chatId": .string(chat.id), "note": .string(note)])
        guard try Theirs.addPhotos(char.id, [row], albumId: try albumFor(char.id, priv: p.priv)) > 0 else { return nil }
        return Theirs.photos(char.id).first { $0.kind == "shot" }?.id
    }

    /// 这个角色存过的截图，新的在前
    static func shotsOf(_ charId: String) -> [Theirs.Photo] {
        Theirs.photos(charId).filter { $0.kind == "shot" && !$0.msgs.isEmpty }
    }

    /// 按一句说明挑一张：说明里的字对得上的那张；对不上取最近的一张。一张都没有回 nil
    static func pick(_ charId: String, _ query: String) -> Theirs.Photo? {
        let list = shotsOf(charId)
        guard let first = list.first else { return nil }
        let q = norm(query)
        if !q.isEmpty, let hit = list.first(where: { p in
            norm(p.note).contains(q) || q.contains(norm(p.note))
                || p.msgs.contains { norm($0["content"]?.string ?? "").contains(q) }
        }) { return hit }
        return first
    }

    /// 发出去时带的那一份：消息副本与美化快照，和相册里那张是同一份内容
    static func carry(_ p: Theirs.Photo) -> JSONValue {
        .object(["msgs": .array(p.msgs), "shotId": .string(p.shotId), "note": .string(p.note)])
    }

    /// 给模型看的清单：只有每张的说明
    static func savedLine(_ charId: String) -> String {
        let notes = Theirs.photos(charId).filter { $0.kind == "shot" }.map(\.note).filter { !$0.isEmpty }
        return notes.isEmpty ? "none" : notes.joined(separator: "; ")
    }

    /// 一张截图里的几条：名字、正文、在不在右边（右边是截图的主人）
    struct Line: Identifiable, Equatable {
        var id: String
        var name: String
        var text: String
        var right: Bool
        var imageId: String
        var stickerId: String
    }

    static func lines(_ msgs: [JSONValue]) -> [Line] {
        msgs.enumerated().compactMap { i, v in
            guard let o = v.object else { return nil }
            return Line(id: o["id"]?.string ?? "\(i)", name: o["_name"]?.string ?? "", text: o["content"]?.string ?? "",
                        right: o["role"]?.string == "user", imageId: o["imageId"]?.string ?? "", stickerId: o["stickerId"]?.string ?? "")
        }
    }
}
