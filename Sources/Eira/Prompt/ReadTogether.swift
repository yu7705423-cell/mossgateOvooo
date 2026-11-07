import Foundation

/// 一起读（网页版 system/read.js 与 ai/context/watch.js 的 buildRead，ARCHITECTURE 4.1056）。
///
/// 和一起看同一个道理：角色那边没有第二本书，只把「读到哪一章、这一页写的是什么」摆到角色面前。
/// 进度不按时间走，按翻页走：「该不该开口」问的是翻过几页。翻页时自己开口是自动触发的调用，
/// 登记在 ExtraCalls 的 readAuto，原生版默认关（readGap 没填按 0，网页版默认 1 页），发之前先记「试过」。
enum ReadTogether {
    struct State: Equatable, Sendable {
        var active = false
        var chatId = ""
        var charId = ""
        var bookId = ""
        var at = 0
        var pages = 0
        var saidPage = -1
        var said = 0
        var awayAt: Double = 0
        /// 这一场从什么时候开始：阅读页上的对话只列这之后的消息
        var since: Double = 0
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

    static func reading() -> Bool { state.active }
    static func inChat(_ chatId: String) -> Bool { let x = state; return x.active && x.chatId == chatId }

    @discardableResult
    static func start(chatId: String, bookId: String) throws -> State {
        guard let chat = try Repo.chat(chatId), let row = Books.get(bookId) else { throw StoreError(message: "这本书或这段会话已经不在了") }
        // 一次只有一场：正看着片子就先收了那一场
        if Watch.playing() { Watch.stop() }
        // 离开阅读页再回来也走这里：同一场接着读，对话从开场那一刻算起
        let prev = state
        let same = prev.active && prev.chatId == chatId && prev.bookId == bookId
        set {
            $0 = State(active: true, chatId: chatId, charId: chat.characterIds.first ?? "", bookId: bookId, at: row.at,
                       since: same && prev.since > 0 ? prev.since : Date().millis)
        }
        _ = Books.text(bookId)
        return state
    }

    /// 翻到某处。翻页的人是用户，所以同时把书上的进度也记了
    static func setAt(_ at: Int) {
        let x = state
        guard x.active else { return }
        Books.setAt(x.bookId, at)
        set { $0.at = at; $0.pages += 1 }
    }

    static func away() { set { x in if x.active { x.awayAt = Date().millis } } }
    static func back() { set { x in if x.active { x.awayAt = 0 } } }

    @discardableResult
    static func sweep(now: Double = Date().millis, settings st: AppSettings = .load()) -> Bool {
        let x = state
        guard x.active, x.awayAt > 0 else { return false }
        let mins = Watch.awayEnd(st)
        guard mins > 0, now - x.awayAt >= mins * 60000 else { return false }
        stop()
        return true
    }

    /// 距上次开口翻过几页才自己开口。0 为只在你说话或点了才说。原生版没填按 0（默认关，登记在 ExtraCalls）
    static func gapOf(_ st: AppSettings) -> Int { max(0, Int(st.raw["readGap"]?.number ?? 0)) }
    /// 给角色看这一页的多少字。0 为只给章节与进度
    static func charsOf(_ st: AppSettings) -> Int { max(0, Int(st.raw["readChars"]?.number ?? 900)) }

    /// 该不该让角色开口：距上次开口翻过的页数够了才算。刚开场等翻过一页再说
    static func due(settings st: AppSettings = .load()) -> Bool {
        let x = state
        let gap = gapOf(st)
        guard x.active, x.awayAt == 0, x.saidPage >= 0, gap > 0 else { return false }
        return x.pages - x.saidPage >= gap
    }

    /// 要开口了（请求发出之前）：记下翻到哪一页。失败了也算试过
    static func markTried() { set { x in if x.active { x.saidPage = x.pages } } }
    static func markSaid() { set { x in if x.active { x.saidPage = x.pages; x.said += 1 } } }
    /// 开场那一下：记个起点，之后按翻页算
    static func markStart() { set { x in if x.active { x.saidPage = x.pages } } }

    // MARK: - 这段会话上的两项（和一起看的各存各的）

    static func howOf(_ chat: Chat?) -> String { chat?.row.string("readHow") == "face" ? "face" : "online" }
    static func replyOf(_ chat: Chat?) -> String { chat?.row.string("readReply") == "manual" ? "manual" : "auto" }

    static func setCfg(_ chatId: String, how: String? = nil, reply: String? = nil) throws {
        guard var c = try Repo.chat(chatId) else { return }
        if let how { c.row["readHow"] = .string(Watch.hows.contains(how) ? how : "online") }
        if let reply { c.row["readReply"] = .string(Watch.replies.contains(reply) ? reply : "auto") }
        c.row.touch()
        try Repo.save(c)
    }

    // MARK: - 注入

    struct Context: Equatable {
        var title: String
        var author: String
        var how: String
        var chapter: String
        var percent: Int
        var away: Bool
        var page: String
    }

    static func context(settings st: AppSettings = .load()) -> Context? {
        if sweep(settings: st) { return nil }
        let x = state
        guard x.active, let row = Books.get(x.bookId) else { return nil }
        let n = charsOf(st)
        let text = Books.peek(x.bookId) ?? Books.text(x.bookId)
        return Context(title: row.title, author: row.author, how: howOf(try? Repo.chat(x.chatId)),
                       chapter: Books.chapterAt(row, x.at)?.chapter.title ?? "", percent: Books.percent(row),
                       away: x.awayAt > 0, page: n > 0 ? Books.slice(text, x.at, n) : "")
    }

    static func block(settings st: AppSettings = .load()) -> String {
        guard let c = context(settings: st) else { return "" }
        return text(c)
    }

    static func text(_ c: Context) -> String {
        var lines = ["You are reading 《\(c.title)》 together with the other party."]
        if !c.author.isEmpty { lines.append("Written by \(c.author).") }
        lines.append(c.how == "face"
            ? "You and the other party are in the same place, reading the same book."
            : "You and the other party are in different places, each reading their own copy at the same position. You talk through chat messages.")
        lines.append(!c.chapter.isEmpty
            ? "They are on \(c.chapter), \(c.percent)% into the book."
            : "They are \(c.percent)% into the book.")
        if c.away { lines.append("The other party has left the reading page.") }
        lines.append("You know only what has been read so far; do not mention anything that"
            + " comes later in the book.")
        if !c.page.isEmpty {
            lines += ["", "[这一页]", c.page]
        } else {
            lines += ["", "The text on the page is not being shown to you. You know only the"
                + " title and the position."]
        }
        return "\n\n[你们正在读]\n" + lines.joined(separator: "\n")
    }

    // MARK: - 收场

    @discardableResult
    static func stop() -> Message? {
        let x = state
        set { $0 = State() }
        guard x.active else { return nil }
        var record: Message?
        if var chat = try? Repo.chat(x.chatId), let row = Books.get(x.bookId), x.pages > 0 {
            chat.row["lastMessageAt"] = .number(Date().millis)
            chat.row.touch()
            let ch = Books.chapterAt(row, x.at)?.chapter.title ?? ""
            var m = Message.new(chatId: chat.id, role: .user, authorId: "me",
                                content: "[一起读了 \(x.pages) 页]\n《\(row.title)》\u{3000}读到 \(Books.percent(row))%" + (ch.isEmpty ? "" : "\u{3000}\(ch)"),
                                kind: "read")
            m.row["bookId"] = .string(x.bookId)
            m.row["at"] = .number(Double(x.at))
            m.row["pages"] = .number(Double(x.pages))
            do {
                try Repo.save(chat)
                record = try Repo.append(m)
            } catch {
                Problems.report("一起读的记录未能写入：\(error.localizedDescription)")
            }
            NotificationCenter.default.post(name: .eiraChatChanged, object: chat.id)
        }
        if record != nil {
            let bid = x.bookId, cid = x.charId, at = Double(x.at)
            Task.detached { await Reviews.writeOnFinish(kind: .book, subjectId: bid, charId: cid, at: at) }
        }
        return record
    }

    // MARK: - 角色开口

    /// 角色说一句：一次调用，和聊天同一套接口，落进那段会话里。先记「试过」再发
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

    /// 翻页：记进度，翻够了间隔就让角色说一句（网页版 TogetherPage 的 turn）
    static func turn(to at: Int, onRow: @escaping ChatEngine.OnRow) async throws {
        setAt(at)
        guard due() else { return }
        try await talk(chatId: state.chatId, onRow: onRow)
    }
}
