import Foundation

/// 一起看（网页版 system/watch.js、ai/context/watch.js，ARCHITECTURE 4.102、4.932）。
///
/// 是「角色陪你看」，不是两块屏幕对时间：角色那边没有第二个播放器，所以不做房间、不做同步，
/// 只把「现在演到哪儿、刚说了什么」摆到角色面前。这一场只在内存里（和网页版一样），播放器（WatchPlayer）每秒把进度写进来。
///
/// 角色什么时候自己开口本地算（字幕的疏密，Subtitle.density），不花钱；开口那一下是一次聊天回复。
/// 自己开口是自动触发的调用：登记在 ExtraCalls 的 watchAuto，原生版默认关（watchGap 没填按 0，网页版默认 90 秒），
/// 发请求之前先记「试过」（markTried），失败了也要再等一个完整的间隔（网页版 4.240）。
enum Watch {
    struct State: Equatable, Sendable {
        var active = false
        var chatId = ""
        var charId = ""
        var videoId = ""
        /// 现在播到第几秒
        var at: Double = 0
        var duration: Double = 0
        var playing = false
        /// 这一场看了多久
        var seconds: Double = 0
        /// 角色上一次开口（或试着开口）时片子播到哪儿
        var saidAt: Double = -1
        var said = 0
        /// 人离开播放页的时刻（毫秒）。0 表示人还在那一屏上
        var awayAt: Double = 0
        var error = ""
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var s = State()
    nonisolated(unsafe) private static var talking = false

    static var state: State { lock.lock(); defer { lock.unlock() }; return s }

    static func set(_ change: (inout State) -> Void) {
        lock.lock()
        change(&s)
        lock.unlock()
        NotificationCenter.default.post(name: .eiraWatchChanged, object: nil)
    }

    static func playing() -> Bool { state.active }
    static func inChat(_ chatId: String) -> Bool { let x = state; return x.active && x.chatId == chatId }
    static func current() -> VideoLib.Video? { VideoLib.get(state.videoId) }
    static func lines() -> [Subtitle.Line] { VideoLib.lines(current()) }

    /// 开一场。片子放不放得出来由播放页负责，这里只管记状态
    @discardableResult
    static func start(chatId: String, videoId: String) throws -> VideoLib.Video {
        guard let chat = try Repo.chat(chatId) else { throw StoreError(message: "会话不存在") }
        guard let row = VideoLib.get(videoId) else { throw StoreError(message: "这部片已不在片库中") }
        // 一次只有一场：正一起读着就先收了那一场
        if ReadTogether.reading() { ReadTogether.stop() }
        set {
            $0 = State(active: true, chatId: chatId, charId: chat.characterIds.first ?? "", videoId: videoId,
                       duration: row.seconds)
        }
        return row
    }

    /// 开一场并在会话里落一行「开始一起看《片名》」（与网页版选片页、片库里开场是同一条路）。
    /// 同一场正开着就直接接着看，不再落一行
    static func begin(chatId: String, videoId: String) throws {
        let cur = state
        if cur.active && cur.chatId == chatId && cur.videoId == videoId { return }
        if cur.active { _ = stop() }
        let row = try start(chatId: chatId, videoId: videoId)
        var m = Message.new(chatId: chatId, role: .user, authorId: "me", content: "[开始一起看《\(row.title)》]", kind: "notice")
        m.row["status"] = .string("done")
        _ = try Repo.append(m)
        NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
    }

    /// 播放页每秒写一次进度（网页版 attach 里的定时器）
    static func tick(at: Double, duration: Double, playing: Bool) {
        set { x in
            guard x.active else { return }
            x.at = at.isFinite ? at.rounded() : 0
            if duration.isFinite && duration > 0 { x.duration = duration.rounded() }
            x.playing = playing
            if playing { x.seconds += 1 }
            x.awayAt = 0
        }
    }

    /// 人离开了播放页：这一场不就此结束（中途回一条消息还要接着看），但画面停了，状态如实改成暂停并记下离开的时刻
    static func away() {
        set { x in
            guard x.active else { return }
            x.playing = false
            x.awayAt = Date().millis
        }
    }

    static func back() { set { x in if x.active { x.awayAt = 0 } } }

    /// 离开多久就算这一场散了（分钟）。0 表示一直留着
    static func awayEnd(_ st: AppSettings) -> Double {
        let n = st.raw["watchAwayEnd"]?.number ?? 15
        return n.isFinite && n >= 0 ? n.rounded() : 15
    }

    /// 人离开太久就替他收场。不起定时器：这一场只在被读的时候才有意义，谁来读谁顺手扫一眼
    @discardableResult
    static func sweep(now: Double = Date().millis, settings st: AppSettings = .load()) -> Bool {
        let x = state
        guard x.active, x.awayAt > 0 else { return false }
        let mins = awayEnd(st)
        guard mins > 0, now - x.awayAt >= mins * 60000 else { return false }
        _ = stop()
        return true
    }

    /// 要开口了（请求发出之前）：只记播到哪儿，不计数。必须在请求之前记（网页版 markTried）
    static func markTried() { set { x in if x.active { x.saidAt = x.at } } }

    /// 角色说完一句，记下说的时候播到哪儿
    static func markSaid() { set { x in x.saidAt = x.at; x.said += 1 } }

    /// 两次自己开口至少隔多少秒。0 为只在你说话时才回。原生版没填按 0（默认关，登记在 ExtraCalls）
    static func gapOf(_ st: AppSettings) -> Double {
        let n = st.raw["watchGap"]?.number ?? 0
        return n.isFinite && n >= 0 ? n.rounded() : 0
    }

    static func lineCount(_ st: AppSettings) -> Int {
        let n = st.raw["watchLines"]?.number ?? 8
        return n.isFinite && n > 0 ? Int(n.rounded()) : 8
    }

    /// 现在该不该让角色自己开口：间隔到了没、这一带是不是正演着对手戏、空窗够不够长
    static func due(settings st: AppSettings = .load(), now: Double = Date().millis) -> Bool {
        if sweep(now: now, settings: st) { return false }
        let x = state
        let gap = gapOf(st)
        guard x.active, x.playing, gap > 0 else { return false }
        let since = x.saidAt < 0 ? x.at : x.at - x.saidAt
        guard since >= gap else { return false }
        let d = Subtitle.density(lines(), x.at)
        if d.quiet { return true }
        if d.talky { return since >= gap * 2 }
        return true
    }

    // MARK: - 这段会话上的两项（网页版 4.932，存在会话上）

    static let hows = ["online", "face"]
    static let replies = ["auto", "manual"]
    static func howOf(_ chat: Chat?) -> String { chat?.row.string("watchHow") == "face" ? "face" : "online" }
    static func replyOf(_ chat: Chat?) -> String { chat?.row.string("watchReply") == "manual" ? "manual" : "auto" }

    static func setCfg(_ chatId: String, how: String? = nil, reply: String? = nil) throws {
        guard var c = try Repo.chat(chatId) else { return }
        if let how { c.row["watchHow"] = .string(hows.contains(how) ? how : "online") }
        if let reply { c.row["watchReply"] = .string(replies.contains(reply) ? reply : "auto") }
        c.row.touch()
        try Repo.save(c)
    }

    // MARK: - 注入

    struct Context: Equatable {
        var title: String
        var at: Double
        var duration: Double
        var playing: Bool
        var hasLines: Bool
        var recent: [String]
        var outline: [VideoLib.Segment]
        var away: Bool
        var seen: Bool
        var how: String
    }

    static func context(settings st: AppSettings = .load()) -> Context? {
        if sweep(settings: st) { return nil }
        let x = state
        guard x.active, let row = current() else { return nil }
        let all = lines()
        let recent = Subtitle.recentLines(all, x.at, lineCount(st))
        let char = try? Repo.character(x.charId)
        return Context(title: row.title, at: x.at, duration: x.duration, playing: x.playing, hasLines: !all.isEmpty,
                       recent: recent.map(\.text), outline: VideoLib.outlineSoFar(row, x.at), away: x.awayAt > 0,
                       seen: char?.row.bool("watchedBefore") ?? false, how: howOf(try? Repo.chat(x.chatId)))
    }

    /// 「[你们正在看]」那一段（网页版 context/watch.js 的 build），和一起读共用一个槽位。
    /// 只给正在一起看 / 一起读的那一段会话：网页版不看是哪段会话，别的会话里也会写成「正在一起看」
    static func block(chatId: String, settings st: AppSettings = .load()) -> String {
        if inChat(chatId), let c = context(settings: st) { return text(c) }
        if ReadTogether.inChat(chatId) { return ReadTogether.block(settings: st) }
        return ""
    }

    static func text(_ c: Context) -> String {
        var lines = ["You are watching 《\(c.title)》 together with the other party."]
        lines.append(c.how == "face"
            ? "You and the other party are in the same place, watching the same screen."
            : "You and the other party are in different places, each watching on their own screen at the same position. You talk through chat messages.")
        lines.append(c.duration > 0
            ? "Current position \(Subtitle.stamp(c.at)), of a total running time of \(Subtitle.stamp(c.duration))."
            : "Current position \(Subtitle.stamp(c.at)).")
        if c.away {
            lines.append("The other party has stepped away from the playback page. Playback is"
                + " paused and the position is held at the moment given above.")
        } else if !c.playing {
            lines.append("Playback is paused at this moment.")
        }
        lines.append(c.seen
            ? "You have seen this film before and know what is coming, but do not give it away."
            : "You are watching this film for the first time. You know only what has played so"
                + " far; do not mention anything that has not yet happened.")
        if !c.outline.isEmpty {
            lines.append("")
            lines.append("[到目前为止的剧情]")
            for seg in c.outline { lines.append("\(Subtitle.stamp(seg.from))\u{3000}\(seg.text)") }
        }
        if !c.recent.isEmpty {
            lines.append("")
            lines.append("[刚刚的台词]")
            lines += c.recent
        } else if !c.hasLines {
            lines.append("")
            lines.append("This film has no subtitles. You cannot hear the dialogue and know"
                + " only the position. Do not invent plot.")
        }
        lines.append("")
        lines.append("To pause, resume, or go back, write a line on its own in the form given"
            + " under [一起看].")
        return "\n\n[你们正在看]\n" + lines.joined(separator: "\n")
    }

    // MARK: - 播放控制（角色写 [暂停] [继续] [倒回：12:30]）

    enum Act: String { case pause, resume, seek }

    /// 不落消息：动的是播放器，不是聊天记录。这一场没开着就当没说过
    static func playback(_ act: Act, to: String, chatId: String) {
        guard inChat(chatId) else { return }
        var info: [String: Any] = ["act": act.rawValue]
        if act == .seek {
            guard let sec = Subtitle.markSeconds(to) else { return }
            info["to"] = sec
        }
        NotificationCenter.default.post(name: .eiraWatchControl, object: nil, userInfo: info)
    }

    // MARK: - 收场

    /// 收场：落一条记录，累积加在会话上；开着「看完自动写一篇」时另写一篇影评（默认关）
    @discardableResult
    static func stop() -> Message? {
        let x = state
        set { $0 = State() }
        guard x.active else { return nil }
        var record: Message?
        if var chat = try? Repo.chat(x.chatId), let row = VideoLib.get(x.videoId), x.seconds > 0 {
            chat.row["watchSeconds"] = .number((chat.row.number("watchSeconds") ?? 0) + x.seconds)
            chat.row["watchCount"] = .number((chat.row.number("watchCount") ?? 0) + 1)
            chat.row["lastMessageAt"] = .number(Date().millis)
            chat.row.touch()
            var m = Message.new(chatId: chat.id, role: .user, authorId: "me",
                                content: "[一起看了 \(fmt(x.seconds))]\n\(row.title)\u{3000}看到 \(Subtitle.stamp(x.at))", kind: "watch")
            m.row["seconds"] = .number(x.seconds)
            m.row["videoId"] = .string(x.videoId)
            m.row["at"] = .number(x.at)
            m.row["status"] = .string("done")
            do {
                try Repo.save(chat)
                record = try Repo.append(m)
            } catch {
                Problems.report("一起看的记录未能写入：\(error.localizedDescription)")
            }
            NotificationCenter.default.post(name: .eiraChatChanged, object: chat.id)
        }
        if record != nil {
            let vid = x.videoId, cid = x.charId, at = x.at
            Task.detached { await Reviews.writeOnFinish(kind: .video, subjectId: vid, charId: cid, at: at) }
        }
        return record
    }

    static func totals(_ chat: Chat?) -> (seconds: Double, count: Int) {
        (chat?.row.number("watchSeconds") ?? 0, Int(chat?.row.number("watchCount") ?? 0))
    }

    static func fmt(_ sec: Double) -> String {
        let n = max(0, sec.isFinite ? Int(sec.rounded()) : 0)
        let h = n / 3600, m = (n % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分钟" }
        if m > 0 { return "\(m) 分钟" }
        return "\(n) 秒"
    }

    // MARK: - 角色开口

    /// 角色说一句（你点了「让角色说一句」、发了一条立即回复的消息，或到点自动开口）。和聊天同一套接口、同一次回复。
    /// 先记「试过」再发：失败了也要再等一个间隔
    static func talk(chatId: String, onRow: @escaping ChatEngine.OnRow) async throws {
        lock.lock()
        if talking { lock.unlock(); return }
        talking = true
        lock.unlock()
        defer { lock.lock(); talking = false; lock.unlock() }
        markTried()
        try await ChatEngine.reply(chatId: chatId, onRow: onRow)
        markSaid()
    }

    /// 播放页每五秒问一次（网页版 WatchPage 的 setInterval）：到点了才让角色说一句
    static func autoTurn(onRow: @escaping ChatEngine.OnRow) async {
        guard due() else { return }
        let chatId = state.chatId
        guard !ChatEngine.isReplying(chatId) else { return }
        do { try await talk(chatId: chatId, onRow: onRow) }
        catch { Diagnostics.shared.record("watch-talk-failed", ["error": error.localizedDescription]) }
    }
}

extension Notification.Name {
    static let eiraWatchChanged = Notification.Name("eira.watchChanged")
    /// 角色写的 [暂停] [继续] [倒回]：userInfo 的 act（pause / resume / seek）与 to（秒）
    static let eiraWatchControl = Notification.Name("eira.watchControl")
}
