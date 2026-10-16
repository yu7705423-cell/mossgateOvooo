import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// 本机曲库与歌单（网页版 system/music.js）。songs 与 playlists 两个数据域，与网页版同一形状，备份互通。
///
/// 网易云收进来的只存标识（neteaseId），播放地址每次现取；本机文件存在 files 里，id 记在 audioId。
enum MusicLibrary {
    static let me = "me"

    struct Song: Identifiable, Equatable {
        var row: Row
        var id: String { row.id }
        var title: String { row.string("title") }
        var artist: String { row.string("artist") }
        var source: String { row.string("source").isEmpty ? "local" : row.string("source") }
        var neteaseId: String { row.string("neteaseId") }
        /// QQ 音乐的歌（原生版独有，source 为 qq）。网页版读到时只剩名字与歌手
        var qqMid: String { row.string("qqMid") }
        var audioId: String { row.string("audioId") }
        var url: String { row.string("url") }
        var cover: String { row.string("cover") }
        var lyric: String { row.string("lyric") }
        var seconds: Int { Int(row.number("seconds") ?? 0) }
        var label: String { artist.isEmpty ? title : "\(title) — \(artist)" }
    }

    static func songs() throws -> [Song] {
        try Database.shared.all("songs").map(Song.init(row:)).sorted { ($0.row.number("createdAt") ?? 0) > ($1.row.number("createdAt") ?? 0) }
    }

    static func song(_ id: String) -> Song? {
        guard let r = try? Database.shared.get("songs", id: id) else { return nil }
        return Song(row: r)
    }

    /// 收一首网易云的歌。已经收过的不重复收。
    @discardableResult
    static func fromNetease(_ t: NeTrack) throws -> Song {
        if let s = try songs().first(where: { $0.source == "netease" && $0.neteaseId == t.id }) { return s }
        let row = Row.new(prefix: "song", [
            "title": .string(String(t.title.prefix(60))), "artist": .string(String(t.artist.prefix(40))), "url": .string(""),
            "audioId": .null, "lyric": .string(""), "coverId": .null, "seconds": .number(Double(t.seconds)),
            "source": .string("netease"), "neteaseId": .string(t.id), "cover": .string(t.cover),
        ])
        try Database.shared.put("songs", row)
        return Song(row: row)
    }

    /// 收一首 QQ 音乐的歌。已经收过的不重复收
    @discardableResult
    static func fromQQ(_ t: QQMusic.Track) throws -> Song {
        if let s = try songs().first(where: { $0.source == "qq" && $0.qqMid == t.mid }) { return s }
        let row = Row.new(prefix: "song", [
            "title": .string(String(t.title.prefix(60))), "artist": .string(String(t.artist.prefix(40))), "url": .string(""),
            "audioId": .null, "lyric": .string(""), "coverId": .null, "seconds": .number(Double(t.seconds)),
            "source": .string("qq"), "qqMid": .string(t.mid), "qqId": .number(Double(t.songId)), "cover": .string(t.cover),
        ])
        try Database.shared.put("songs", row)
        return Song(row: row)
    }

    /// 收一个本机音频文件。
    @discardableResult
    static func addLocal(title: String, artist: String, data: Data, ext: String, lyric: String = "") throws -> Song {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !t.isEmpty else { throw StoreError(message: "请填写歌曲名称") }
        let type = ext.lowercased() == "m4a" ? "audio/mp4" : ext.lowercased() == "wav" ? "audio/wav" : "audio/mpeg"
        let audioId = try Files.save(data, ext: ext.isEmpty ? "mp3" : ext.lowercased(), type: type)
        var seconds = 0.0
        if let u = MediaStore.url(.files, id: audioId), let p = try? AVAudioPlayer(contentsOf: u) { seconds = p.duration.rounded() }
        let row = Row.new(prefix: "song", [
            "title": .string(t), "artist": .string(String(artist.trimmingCharacters(in: .whitespaces).prefix(40))), "url": .string(""),
            "audioId": .string(audioId), "lyric": .string(lyric), "coverId": .null, "seconds": .number(seconds), "source": .string("local"),
        ])
        try Database.shared.put("songs", row)
        return Song(row: row)
    }

    static func update(_ id: String, _ patch: [String: JSONValue]) throws {
        guard var r = try Database.shared.get("songs", id: id) else { return }
        for (k, v) in patch { r[k] = v }
        r.touch()
        try Database.shared.put("songs", r)
    }

    /// 按播放地址收一首（网页版 addSong 的地址那一路）
    @discardableResult
    static func addURL(title: String, artist: String, url: String, lyric: String) throws -> Song {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !t.isEmpty else { throw StoreError(message: "请填写歌曲名称") }
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { throw StoreError(message: "请填写播放地址或上传音频文件") }
        let row = Row.new(prefix: "song", [
            "title": .string(t), "artist": .string(String(artist.trimmingCharacters(in: .whitespaces).prefix(40))), "url": .string(u),
            "audioId": .null, "lyric": .string(lyric), "coverId": .null, "seconds": .number(0), "source": .string("local"),
        ])
        try Database.shared.put("songs", row)
        return Song(row: row)
    }

    /// 改一首（网页版 updateSong）：网易云的只改歌词，名称、歌手与地址以网易云为准
    static func edit(_ id: String, title: String, artist: String, url: String, lyric: String) throws {
        guard let s = song(id) else { throw StoreError(message: "这首歌已不在曲库中") }
        if s.source == "netease" || s.source == "qq" { try update(id, ["lyric": .string(lyric)]); return }
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !t.isEmpty else { throw StoreError(message: "请填写歌曲名称") }
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty || !s.audioId.isEmpty else { throw StoreError(message: "请填写播放地址或上传音频文件") }
        try update(id, ["title": .string(t), "artist": .string(String(artist.trimmingCharacters(in: .whitespaces).prefix(40))),
                        "url": .string(u), "lyric": .string(lyric)])
    }

    /// 删一整个歌单。歌留在曲库里
    static func removeList(_ id: String) throws { try Database.shared.delete("playlists", id: id) }

    /// 移除一首：歌单里的这一首一并去掉。上传的音频文件留着，交给「存储」统一清理（原生版不自己删文件）。
    static func remove(_ id: String) throws {
        for var l in try Database.shared.all("playlists") where l.strings("trackIds").contains(id) {
            l["trackIds"] = .array(l.strings("trackIds").filter { $0 != id }.map { .string($0) })
            try Database.shared.put("playlists", l)
        }
        try Database.shared.delete("songs", id: id)
    }

    // MARK: - 歌单

    static func lists() throws -> [Row] {
        try Database.shared.all("playlists").sorted {
            let a = $0.string("owner") == me ? 0 : 1, b = $1.string("owner") == me ? 0 : 1
            return a != b ? a < b : ($0.number("createdAt") ?? 0) < ($1.number("createdAt") ?? 0)
        }
    }

    static func tracks(_ listId: String) -> [Song] {
        guard let l = try? Database.shared.get("playlists", id: listId) else { return [] }
        return l.strings("trackIds").compactMap(song)
    }

    /// 按名字找这个人的歌单，没有就建一个。
    static func listNamed(_ owner: String, _ name: String) throws -> Row {
        let n = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
        if let l = try Database.shared.all("playlists").first(where: { $0.string("owner") == owner && $0.string("name") == n }) { return l }
        let row = Row.new(prefix: "pl", ["name": .string(n.isEmpty ? "未命名歌单" : n), "owner": .string(owner), "trackIds": .array([])])
        try Database.shared.put("playlists", row)
        return row
    }

    /// 加进歌单。已经在里面的返回 false。
    @discardableResult
    static func addTrack(_ listId: String, _ songId: String) throws -> Bool {
        guard var l = try Database.shared.get("playlists", id: listId) else { return false }
        var ids = l.strings("trackIds")
        if ids.contains(songId) { return false }
        ids.append(songId)
        l["trackIds"] = .array(ids.map { .string($0) })
        l.touch()
        try Database.shared.put("playlists", l)
        return true
    }

    static func removeTrack(_ listId: String, _ songId: String) throws {
        guard var l = try Database.shared.get("playlists", id: listId) else { return }
        l["trackIds"] = .array(l.strings("trackIds").filter { $0 != songId }.map { .string($0) })
        try Database.shared.put("playlists", l)
    }

    // MARK: - 按名字找歌（角色写的「歌名 - 歌手」）

    static func bare(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"[\s·・《》（）()\[\]【】"“”'‘’]"#, with: "", options: .regularExpression)
    }

    /// 「歌手《歌名》」「歌名（歌手）」「歌名 - 歌手」与只有歌名，拆成歌名与歌手。
    static func splitQuery(_ q: String) -> (title: String, artist: String) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"^(.*?)《(.+?)》"#, options: .regularExpression) {
            let m = String(t[r])
            let artist = m.components(separatedBy: "《").first ?? ""
            let title = m.components(separatedBy: "《").last?.replacingOccurrences(of: "》", with: "") ?? ""
            return (title.trimmingCharacters(in: .whitespaces), artist.trimmingCharacters(in: .whitespaces))
        }
        if let r = t.range(of: #"[（(]([^)）]+)[)）]\s*$"#, options: .regularExpression) {
            let artist = t[r].trimmingCharacters(in: CharacterSet(charactersIn: "（()） "))
            return (String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), artist)
        }
        if let r = t.range(of: #"\s*[-—–－|｜/]\s*"#, options: .regularExpression) {
            return (String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return (t, "")
    }

    static func findLocal(_ q: String) -> Song? {
        let (title, artist) = splitQuery(q)
        let all = (try? songs()) ?? []
        let bt = bare(title), ba = bare(artist)
        if let s = all.first(where: { bare($0.title) == bt && (ba.isEmpty || bare($0.artist).contains(ba) || ba.contains(bare($0.artist))) }) { return s }
        if let s = all.first(where: { bare($0.title) == bt }) { return s }
        return all.first { bt.count >= 2 && (bare($0.title + $0.artist).contains(bt) || (bare($0.title).count >= 2 && bt.contains(bare($0.title)))) }
    }

    // MARK: - 在线搜歌用哪一家（网页版 music.onlineSource，ARCHITECTURE 4.609、4.610）

    /// 音乐 app 搜索页、「我的」页、「设置 - 音乐服务」顶上切换「网易云 / QQ 音乐」，记住上次选的（settings.musicSource）。
    /// 会话里分享音乐、角色点歌找歌跟着它，不另放开关（第 5 条：同一个开关只有一个入口）
    static func onlineSource(_ s: AppSettings = .load()) -> String { s.raw["musicSource"]?.string == "qq" ? "qq" : "netease" }

    static func sourceName(_ src: String) -> String { src == "qq" ? "QQ 音乐" : "网易云" }

    /// 角色点歌、找歌时依次问的几家：选的那一家在前，另一家兜底。
    /// 网易云不登录也能搜能放，一直在列；QQ 音乐登录了、或者用户选的就是它时才问（原生版未登录也能搜 QQ，播放地址多半取不到）
    static func searchOrder(_ s: AppSettings = .load()) -> [String] {
        let first = onlineSource(s)
        let qqOn = first == "qq" || QQMusic.loggedIn(s)
        let all = first == "qq" ? ["qq", "netease"] : ["netease", "qq"]
        return all.filter { $0 != "qq" || qqOn }
    }

    /// 本机曲库里有就用；没有就按 searchOrder 依次去网易云、QQ 音乐搜，收进曲库。都找不到返回 nil。
    static func resolve(_ q: String) async -> Song? {
        if let s = findLocal(q) { return s }
        let (title, artist) = splitQuery(q)
        let q2 = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        for src in searchOrder() {
            if src == "qq" {
                if let list = try? await QQMusic.search(q2, limit: 5), !list.isEmpty {
                    let pick = list.first { bare($0.title) == bare(title) } ?? list[0]
                    if let song = try? fromQQ(pick) { return song }
                }
            } else if let list = try? await Netease.search(q2, limit: 5), !list.isEmpty {
                let pick = list.first { bare($0.title) == bare(title) } ?? list[0]
                if let song = try? fromNetease(pick) { return song }
            }
        }
        return nil
    }

    // MARK: - 点歌：歌名加歌手，原唱放不了就放翻唱（网页版 music.playableSong，ARCHITECTURE 4.219）

    /// 点歌的结果。notice 是要落在会话里的那一行提示（带方括号），没有就是空串：
    /// 原唱放不了、没搜到原唱而换了别人唱的，或者一个能放的都没有，都写明，角色下一轮读得到
    struct Playable {
        var song: Song?
        var notice: String
    }

    /// 比歌名用：括号里的去掉、空白去掉、小写（网页版 music.js 点歌那一段的 bare）
    static func bareTitle(_ s: String) -> String {
        s.replacingOccurrences(of: #"[(（\[【].*?[)）\]】]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression).lowercased()
    }

    static func sameArtist(_ a: String, _ b: String) -> Bool { b.isEmpty || a.isEmpty || a.contains(b) || b.contains(a) }

    /// 搜出来的一首：问得出播放地址才算放得出来；放得出来才收进曲库
    private struct Candidate {
        var key: String
        var title: String
        var artist: String
        var plays: () async -> Bool
        var keep: () throws -> Song
    }

    /// 角色点的那一首，找一个放得出来的版本。
    /// 本机曲库里有就用它；否则按 searchOrder 依次去网易云、QQ 音乐搜（用户选的那一家在前）：歌名对得上、歌手也对得上的是原唱，
    /// 歌名对得上、歌手不同的是别人唱的。原唱逐个问一次播放地址，放得出来就用；都放不了或没搜到原唱，依次试别人唱的版本。
    /// 问播放地址是音乐服务的接口，不是模型，不算多调一次（第 15 条）
    static func playableSong(_ query: String) async -> Playable {
        let (title, artist) = splitQuery(query)
        guard !title.isEmpty else { return Playable(song: nil, notice: "") }
        let all = (try? songs()) ?? []
        if let local = all.first(where: { bareTitle($0.title) == bareTitle(title) && sameArtist($0.artist, artist) })
            ?? (artist.isEmpty ? findLocal(title) : nil) {
            return Playable(song: local, notice: "")
        }
        let want = "\(artist.isEmpty ? "" : "\(artist)的")《\(title)》"

        // 先问用户选的那一家（settings.musicSource），原唱、翻唱都放不了再问另一家（网页版 4.609）。
        // 一家一家来：前一家有原唱放得出来，后一家不搜
        let netease: (String) async throws -> [Candidate] = { q in
            try await Netease.search(q, limit: 10).map { t in
                Candidate(key: t.id, title: t.title, artist: t.artist,
                          plays: { !(((try? await Netease.songUrl(t.id)) ?? "").isEmpty) },
                          keep: { try MusicLibrary.fromNetease(t) })
            }
        }
        let qq: (String) async throws -> [Candidate] = { q in
            try await QQMusic.search(q, limit: 10).map { t in
                Candidate(key: t.mid, title: t.title, artist: t.artist,
                          plays: { !(((try? await QQMusic.songUrl(t.mid)) ?? "").isEmpty) },
                          keep: { try MusicLibrary.fromQQ(t) })
            }
        }
        let sources = searchOrder().map { $0 == "qq" ? qq : netease }

        var fallback: Playable?
        for run in sources {
            var rows: [Candidate] = []
            if !artist.isEmpty { rows += (try? await run("\(title) \(artist)")) ?? [] }
            rows += (try? await run(title)) ?? []
            var seen = Set<String>()
            rows = rows.filter { seen.insert($0.key).inserted }
            let same = rows.filter { bareTitle($0.title) == bareTitle(title) }
            // 没写歌手时，搜出来的第一个同名版本当原唱
            let lead = artist.isEmpty ? Array(same.prefix(1)) : same.filter { sameArtist($0.artist, artist) }
            let leadKeys = Set(lead.map(\.key))
            let others = same.filter { !leadKeys.contains($0.key) }
            for t in lead {
                if await t.plays(), let song = try? t.keep() { return Playable(song: song, notice: "") }
            }
            guard fallback == nil else { continue }
            for t in others {
                guard await t.plays(), let song = try? t.keep() else { continue }
                let who = song.artist.isEmpty ? "其他歌手" : song.artist
                fallback = Playable(song: song, notice: lead.isEmpty
                    ? "[没有找到\(want)，换成了\(who)演唱的版本]"
                    : "[\(want)无法播放（需要会员或没有版权），换成了\(who)演唱的版本]")
                break
            }
        }
        return fallback ?? Playable(song: nil, notice: "[没有找到可以播放的\(want)]")
    }

    // MARK: - 歌词

    struct Line: Equatable { var at: Double; var text: String; var trans: String = "" }

    static func parseLyric(_ text: String) -> [Line] {
        guard let re = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#) else { return [] }
        var out: [Line] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let ms = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = ms.last else { continue }
            let body = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in ms {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0, ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                out.append(Line(at: mm * 60 + ss + frac, text: body))
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    static func merge(_ lines: [Line], _ trans: [Line]) -> [Line] {
        lines.compactMap { l in
            guard !l.text.isEmpty else { return nil }
            var x = l
            x.trans = trans.first { abs($0.at - l.at) < 0.06 }?.text ?? ""
            return x
        }
    }

    /// 歌词：本机写了就用本机的，网易云的歌去网易云取。
    static func lyricOf(_ s: Song) async -> (lines: [Line], pure: Bool) {
        if !s.lyric.isEmpty { return (merge(parseLyric(s.lyric), []), false) }
        if !s.qqMid.isEmpty {
            guard let r = try? await QQMusic.lyric(s.qqMid) else { return ([], false) }
            let lines = merge(parseLyric(r.lrc), parseLyric(r.trans))
            return (lines, lines.count <= 2 && r.lrc.contains("纯音乐"))
        }
        guard !s.neteaseId.isEmpty, let r = try? await Netease.lyric(s.neteaseId) else { return ([], false) }
        let lines = merge(parseLyric(r.lrc), parseLyric(r.tlrc))
        return (lines, r.pure || (lines.count <= 2 && r.lrc.contains("纯音乐")))
    }
}

/// 播放器（网页版 system/player.js）。锁屏与控制中心能看到正在放的歌，能暂停、切歌；应用退到后台照放。
@MainActor
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()

    @Published private(set) var queue: [MusicLibrary.Song] = []
    @Published private(set) var index = -1
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    @Published private(set) var seconds = 0.0
    @Published private(set) var duration = 0.0
    /// 和哪段会话一起听（[一起听]），空表示自己听
    @Published var listenChat: String? { didSet { MusicListen.setActive(listenChat) } }
    @Published private(set) var listenPlayed: [String] = []
    private var listenStarted: Date?

    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var played = 0.0
    private var remoteReady = false

    var current: MusicLibrary.Song? { queue.indices.contains(index) ? queue[index] : nil }

    func play(_ list: [MusicLibrary.Song], at i: Int) {
        queue = list
        index = max(0, min(i, list.count - 1))
        load(autoplay: true)
    }

    func playOne(_ s: MusicLibrary.Song) {
        if let i = queue.firstIndex(where: { $0.id == s.id }) { index = i } else { queue = [s]; index = 0 }
        load(autoplay: true)
    }

    func toggle() {
        guard let player else { if current != nil { load(autoplay: true) }; return }
        if playing { player.pause() } else { player.play() }
        playing.toggle()
        nowInfo()
    }

    func next(auto: Bool = false) {
        scrobble()
        guard !queue.isEmpty else { return }
        let mode = AppSettings.load().raw["playMode"]?.string ?? "order"
        if mode == "one" && auto { load(autoplay: true); return }
        if mode == "shuffle" && queue.count > 1 {
            var j = index
            while j == index { j = Int.random(in: 0..<queue.count) }
            index = j
        } else if index + 1 < queue.count {
            index += 1
        } else {
            stopEngine()
            playing = false
            return
        }
        load(autoplay: true)
    }

    func prev() {
        if seconds > 3 { seek(0); return }
        scrobble()
        index = max(0, index - 1)
        load(autoplay: true)
    }

    func seek(_ t: Double) {
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        seconds = t
        nowInfo()
    }

    func stop() {
        scrobble()
        stopEngine()
        queue = []
        index = -1
        playing = false
    }

    private func stopEngine() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
    }

    private func load(autoplay: Bool) {
        guard let s = current else { return }
        stopEngine()
        loading = true
        error = ""
        seconds = 0
        played = 0
        duration = Double(s.seconds)
        let want = s.id
        setupRemote()
        Task {
            do {
                let url = try await source(of: s)
                guard current?.id == want else { return }
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try? AVAudioSession.sharedInstance().setActive(true)
                let p = AVPlayer(url: url)
                player = p
                observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] t in
                    Task { @MainActor in
                        guard let self else { return }
                        self.seconds = t.seconds
                        if self.playing { self.played += 1 }
                        if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                    }
                }
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.next(auto: true) }
                }
                if autoplay { p.play(); playing = true }
                if listenChat != nil, !listenPlayed.contains(s.id) { listenPlayed.append(s.id) }
                loading = false
                nowInfo()
            } catch {
                loading = false
                playing = false
                self.error = error.localizedDescription
            }
        }
    }

    private func source(of s: MusicLibrary.Song) async throws -> URL {
        if !s.url.isEmpty, let u = URL(string: s.url) { return u }
        if !s.audioId.isEmpty, let u = MediaStore.url(.files, id: s.audioId) { return u }
        if !s.neteaseId.isEmpty, let u = URL(string: try await Netease.songUrl(s.neteaseId)) { return u }
        if !s.qqMid.isEmpty, let u = URL(string: try await QQMusic.songUrl(s.qqMid)) { return u }
        throw StoreError(message: "这首歌放不出来")
    }

    /// 听够了设定的秒数才记一次听歌（你的账号；一起听时角色的账号也记）。
    private func scrobble() {
        guard let s = current, !s.neteaseId.isEmpty, played > 0 else { return }
        let after = AppSettings.load().raw["scrobbleAfter"]?.number ?? 30
        if after > 0 && played < min(after, Double(s.seconds > 0 ? s.seconds : Int(after))) { return }
        let secs = Int(played), id = s.neteaseId
        var cookies = [Netease.userCookie()]
        if let chatId = listenChat, let c = try? Repo.chat(chatId), let charId = c.characterIds.first {
            let ck = Netease.cookieOf(charId)
            if !ck.isEmpty && ck != cookies[0] { cookies.append(ck) }
        }
        played = 0
        Task.detached { for ck in cookies { await Netease.scrobble(id, seconds: secs, cookie: ck) } }
    }

    // MARK: - 一起听

    /// 和这段会话一起听。没有指定歌就从角色的歌单、你的歌单、整个曲库里取第一首；只排好，等你点播放。
    func startListen(chatId: String, song: MusicLibrary.Song? = nil, autoplay: Bool = false) throws {
        guard let chat = try Repo.chat(chatId), let charId = chat.characterIds.first, let char = try Repo.character(charId) else {
            throw StoreError(message: "会话或角色不存在")
        }
        guard char.row["canListen"]?.bool != false else { throw StoreError(message: "该角色未开启一起听") }
        var list: [MusicLibrary.Song] = []
        for l in try MusicLibrary.lists() where l.string("owner") == charId { list += MusicLibrary.tracks(l.id) }
        if list.isEmpty { for l in try MusicLibrary.lists() where l.string("owner") == MusicLibrary.me { list += MusicLibrary.tracks(l.id) } }
        if list.isEmpty { list = try MusicLibrary.songs() }
        if let song { list.removeAll { $0.id == song.id }; list.insert(song, at: 0) }
        guard !list.isEmpty else { throw StoreError(message: "曲库里还没有歌。可在「音乐」中搜索网易云并收入曲库") }
        if listenChat != chatId { endListen() }
        listenChat = chatId
        listenStarted = listenStarted ?? Date()
        queue = list
        index = 0
        load(autoplay: autoplay)
    }

    /// 一起听的时候点一首（角色写的 [点歌：…]）。
    func pick(_ song: MusicLibrary.Song) {
        if let i = queue.firstIndex(where: { $0.id == song.id }) { index = i } else { queue.insert(song, at: index + 1); index += 1 }
        load(autoplay: playing)
    }

    /// 结束一起听：在会话里落一条「一起听了多久、几首」。
    func endListen() {
        guard let chatId = listenChat, let started = listenStarted else { listenChat = nil; return }
        let secs = Int(Date().timeIntervalSince(started))
        let names = listenPlayed.compactMap(MusicLibrary.song).map(\.label)
        if secs > 0 {
            let fmt = String(format: "%d:%02d", secs / 60, secs % 60)
            var m = Message.new(chatId: chatId, role: .user, authorId: "me",
                                content: "[一起听了 \(fmt)，\(listenPlayed.count) 首]" + (names.isEmpty ? "" : "\n" + names.joined(separator: "、")), kind: "listen")
            m.row["seconds"] = .number(Double(secs))
            m.row["trackIds"] = .array(listenPlayed.map { .string($0) })
            m.row["status"] = .string("done")
            do {
                _ = try Repo.append(m)
                if var c = try Repo.chat(chatId) {
                    c.row["listenSeconds"] = .number((c.row.number("listenSeconds") ?? 0) + Double(secs))
                    c.row["listenCount"] = .number((c.row.number("listenCount") ?? 0) + 1)
                    c.row["lastMessageAt"] = .number(Date().millis)
                    try Repo.save(c)
                }
                NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
            } catch {
                Problems.report("一起听的记录未能保存：\(error.localizedDescription)")
            }
        }
        listenChat = nil
        listenStarted = nil
        listenPlayed = []
    }

    // MARK: - 锁屏与控制中心

    private func setupRemote() {
        guard !remoteReady else { return }
        remoteReady = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in Task { @MainActor in if !MusicPlayer.shared.playing { MusicPlayer.shared.toggle() } }; return .success }
        c.pauseCommand.addTarget { _ in Task { @MainActor in if MusicPlayer.shared.playing { MusicPlayer.shared.toggle() } }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in MusicPlayer.shared.toggle() }; return .success }
        c.nextTrackCommand.addTarget { _ in Task { @MainActor in MusicPlayer.shared.next() }; return .success }
        c.previousTrackCommand.addTarget { _ in Task { @MainActor in MusicPlayer.shared.prev() }; return .success }
        c.changePlaybackPositionCommand.addTarget { e in
            let t = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in MusicPlayer.shared.seek(t) }
            return .success
        }
    }

    private func nowInfo() {
        guard let s = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: s.title, MPMediaItemPropertyArtist: s.artist,
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: seconds,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
    }

    static func fmt(_ sec: Double) -> String {
        guard sec.isFinite, sec > 0 else { return "--:--" }
        let n = Int(sec)
        return String(format: "%d:%02d", n / 60, n % 60)
    }
}
