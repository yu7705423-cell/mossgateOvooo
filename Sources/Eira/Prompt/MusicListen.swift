import Foundation

/// 聊天里的音乐（网页版 reply.js 的 listen / pick / newlist / song 与 system/listen.js）。
///
/// 角色写 [一起听]：排好一起听，等你点播放；[点歌：…]：一起听时换成这一首；[分享歌曲：…]：发一张歌曲卡片；
/// [建歌单：…] / [加入歌单：歌单 | 歌 ；歌]：收进角色自己的歌单。都不调模型，找歌先查本机曲库，没有再搜网易云。
enum MusicListen {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var chat: String?
    nonisolated(unsafe) private static var wanted: String?

    /// 这段会话此刻是不是在一起听（拼提示词时读，不能等主线程）。
    static func active(_ chatId: String) -> Bool { lock.lock(); defer { lock.unlock() }; return chat == chatId }
    static func setActive(_ chatId: String?) { lock.lock(); chat = chatId; lock.unlock() }

    static func effect(_ p: ReplyParser.Part, chat c: Chat, char: Character, turnId: String) throws -> Message? {
        guard !c.isGroup, char.row["canListen"]?.bool != false else { return nil }
        let chatId = c.id
        switch p.type {
        case .listen:
            lock.lock(); wanted = "\(chatId)|\(turnId)"; lock.unlock()
            Task { @MainActor in
                guard MusicPlayer.shared.listenChat != chatId else { return }
                do { try MusicPlayer.shared.startListen(chatId: chatId, autoplay: false) }
                catch { Diagnostics.shared.record("listen-start-failed", ["error": error.localizedDescription]) }
            }
            return nil
        case .pick:
            let q = p.text, charId = char.id
            Task {
                let ok: Bool = { lock.lock(); defer { lock.unlock() }; return chat == chatId || wanted == "\(chatId)|\(turnId)" }()
                guard ok else { return }
                guard let song = await MusicLibrary.resolve(q) else {
                    notice(chatId: chatId, charId: charId, turnId: turnId, "[没有找到可以播放的《\(MusicLibrary.splitQuery(q).title)》]")
                    return
                }
                await MainActor.run {
                    if MusicPlayer.shared.listenChat == chatId { MusicPlayer.shared.pick(song) }
                    else { try? MusicPlayer.shared.startListen(chatId: chatId, song: song, autoplay: false) }
                }
            }
            return nil
        case .newlist:
            let list = try MusicLibrary.listNamed(char.id, p.text)
            let queries = (p.extra ?? "").split(whereSeparator: { "；;\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let who = char.displayName, name = list.string("name")
            var m = Message.new(chatId: chatId, role: .char, authorId: char.id,
                                content: queries.isEmpty ? "[\(who)新建了歌单「\(name)」]" : "[\(who)正在整理歌单「\(name)」]", kind: "notice", turnId: turnId)
            m.row["playlistId"] = .string(list.id)
            m.row["status"] = .string("done")
            guard !queries.isEmpty else { return m }
            let noticeId = m.id, listId = list.id
            Task {
                var added: [String] = [], had: [String] = [], missing: [String] = []
                for q in queries {
                    guard let s = await MusicLibrary.resolve(q) else { missing.append(MusicLibrary.splitQuery(q).title); continue }
                    if (try? MusicLibrary.addTrack(listId, s.id)) == true { added.append(s.title) } else { had.append(s.title) }
                }
                var bits: [String] = []
                if !added.isEmpty { bits.append("\(who)把" + added.map { "《\($0)》" }.joined() + "加入了歌单「\(name)」") }
                if !had.isEmpty { bits.append(had.map { "《\($0)》" }.joined() + "已在歌单「\(name)」中") }
                if !missing.isEmpty { bits.append(missing.map { "《\($0)》" }.joined() + "没有找到") }
                guard var row = try? Database.shared.get(Collections.messages, id: noticeId) else { return }
                row["content"] = .string("[" + bits.joined(separator: "，") + "]")
                try? Database.shared.put(Collections.messages, row)
                NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
            }
            return m
        default:
            return nil
        }
    }

    private static func notice(chatId: String, charId: String, turnId: String, _ text: String) {
        var m = Message.new(chatId: chatId, role: .char, authorId: charId, content: text, kind: "notice", turnId: turnId)
        m.row["status"] = .string("done")
        _ = try? Repo.append(m)
        NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
    }

    /// 角色分享的歌：落下之后在后台找到那一首，写回卡片。
    static func resolveShared(_ created: [Message], onRow: @escaping ChatEngine.OnRow) {
        let jobs = created.filter { $0.kind == "song" && $0.row.string("songState") == "pending" }.map { ($0.id, $0.row.string("songQuery")) }
        guard !jobs.isEmpty else { return }
        Task.detached {
            for (id, q) in jobs {
                let song = await MusicLibrary.resolve(q)
                guard var row = try? Database.shared.get(Collections.messages, id: id) else { continue }
                if let song { row["songId"] = .string(song.id); row["songState"] = .string("done") } else { row["songState"] = .string("missing") }
                row.touch()
                if (try? Database.shared.put(Collections.messages, row)) != nil { onRow(Message(row: row)) }
            }
        }
    }

    /// 你分享一首歌到会话：落一张卡片，歌词在后台取回来挂上（发给角色时带上）。
    @discardableResult
    static func share(_ song: MusicLibrary.Song, chatId: String) throws -> Message {
        let q = song.artist.isEmpty ? song.title : "\(song.title) - \(song.artist)"
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: "[分享歌曲：\(q)]", kind: "song")
        m.row["songId"] = .string(song.id)
        m.row["songState"] = .string("done")
        m.row["songQuery"] = .string(q)
        m.row["status"] = .string("done")
        m = try Repo.append(m)
        if var c = try Repo.chat(chatId) { c.row["lastMessageAt"] = .number(Date().millis); try Repo.save(c) }
        let id = m.id
        Task.detached {
            let r = await MusicLibrary.lyricOf(song)
            guard var row = try? Database.shared.get(Collections.messages, id: id) else { return }
            row["songPure"] = .bool(r.pure)
            row["songLyric"] = .string(r.pure ? "" : r.lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n"))
            try? Database.shared.put(Collections.messages, row)
        }
        return m
    }
}
