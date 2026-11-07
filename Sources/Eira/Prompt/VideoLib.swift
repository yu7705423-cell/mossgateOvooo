import AVFoundation
import Foundation

/// 片库（网页版 system/video.js 与 ai/tasks/watch-outline.js，ARCHITECTURE 4.102、4.883）。
///
/// 一部片要么是一个地址，要么是本机文件（files 域），要么是 B 站的一部（只记 bvid、cid、分 P，播放地址开播时现取）。
/// 字幕存原文，用的时候现解析；offset 是整体偏移（秒），只在读出来时加，不改原文。
/// outline 是开看之前读完整份字幕写出的分段提纲 [{ from, to, text }]，注入时只给已经看到的那几段。
enum VideoLib {
    static let collection = "videos"

    struct Bili: Equatable, Sendable {
        var bvid: String
        var cid: Double
        var part: String
    }

    struct Segment: Equatable, Sendable {
        var from: Double
        var to: Double?
        var text: String
    }

    /// 一部片（读记录一律经它，缺的字段按网页版默认补）
    struct Video: Identifiable, Equatable, Sendable {
        var row: Row
        var id: String { row.id }
        var title: String { row.string("title") }
        var url: String { row.string("url") }
        var fileId: String { row.string("fileId") }
        var subtitle: String { row.string("subtitle") }
        var seconds: Double { row.number("seconds") ?? 0 }
        var createdAt: Double { row.created ?? 0 }
        var bili: Bili? { VideoLib.biliOf(row["bili"]) }
        var outline: [Segment] {
            (row["outline"]?.array ?? []).compactMap { s in
                guard let f = s["from"]?.number else { return nil }
                return Segment(from: f, to: s["to"]?.number, text: s["text"]?.string ?? "")
            }
        }
        var crew: [String] { row.strings("crew") }
    }

    /// B 站的片：bvid 是 BV 加十位、cid 大于 0 才算（网页版 biliOf）
    static func biliOf(_ v: JSONValue?) -> Bili? {
        guard let v, let bv = v["bvid"]?.string, bv.range(of: #"^BV[0-9A-Za-z]{10}$"#, options: .regularExpression) != nil,
              let cid = v["cid"]?.number, cid > 0 else { return nil }
        return Bili(bvid: bv, cid: cid, part: v["part"]?.string ?? "")
    }

    static func all() -> [Video] {
        ((try? Database.shared.all(collection)) ?? []).map(Video.init(row:)).sorted { $0.createdAt > $1.createdAt }
    }

    static func get(_ id: String) -> Video? {
        guard !id.isEmpty, let r = try? Database.shared.get(collection, id: id) else { return nil }
        return Video(row: r)
    }

    @discardableResult
    static func add(title: String, url: String = "", fileId: String = "", subtitle: String = "", seconds: Double = 0, bili: Bili? = nil) throws -> Video {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw StoreError(message: "请填写片名") }
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty || !fileId.isEmpty || bili != nil else { throw StoreError(message: "请填写播放地址或选择视频文件") }
        var f: [String: JSONValue] = [
            "title": .string(t),
            "url": .string(bili != nil ? "" : u),
            "fileId": bili != nil || fileId.isEmpty ? .null : .string(fileId),
            "subtitle": .string(subtitle),
            "seconds": .number(max(0, seconds.rounded())),
            "offset": .number(0),
            "outline": .array([]),
            "outlineAt": .number(0),
        ]
        if let b = bili { f["bili"] = .object(["bvid": .string(b.bvid), "cid": .number(b.cid), "part": .string(b.part)]) }
        let row = Row.new(prefix: "vid", f)
        try Database.shared.put(collection, row)
        return Video(row: row)
    }

    struct Patch {
        var title: String?
        var seconds: Double?
        var offset: Double?
        var subtitle: String?
        var outline: [Segment]?
        /// 地址与文件一起给（编辑页上二选一）。给了任一个就按这两个写
        var url: String?
        var fileId: String?
    }

    @discardableResult
    static func update(_ id: String, _ p: Patch) throws -> Video {
        guard var row = try Database.shared.get(collection, id: id) else { throw StoreError(message: "这部片已不在片库中") }
        if let t = p.title {
            let v = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { throw StoreError(message: "请填写片名") }
            row["title"] = .string(v)
        }
        if let s = p.seconds { row["seconds"] = .number(max(0, s.rounded())) }
        if let o = p.offset { row["offset"] = .number(offsetOf(o)) }
        // 字幕换了，原来那份提纲就对不上了，一并作废
        if let s = p.subtitle {
            if s != row.string("subtitle") { row["outline"] = .array([]); row["outlineAt"] = .number(0) }
            row["subtitle"] = .string(s)
        }
        if let o = p.outline {
            row["outline"] = .array(o.map { seg in
                var x: [String: JSONValue] = ["from": .number(seg.from), "text": .string(seg.text)]
                x["to"] = seg.to.map { JSONValue.number($0) } ?? JSONValue.null
                return .object(x)
            })
            row["outlineAt"] = .number(Date().millis)
        }
        if p.url != nil || p.fileId != nil {
            let url = (p.url ?? row.string("url")).trimmingCharacters(in: .whitespacesAndNewlines)
            let file = p.fileId ?? row.string("fileId")
            guard !url.isEmpty || !file.isEmpty || biliOf(row["bili"]) != nil else {
                throw StoreError(message: "请填写播放地址或选择视频文件")
            }
            // 填了地址或换了文件，就不再是 B 站那一部
            if !url.isEmpty || !file.isEmpty { row["bili"] = .null }
            row["url"] = .string(url)
            row["fileId"] = file.isEmpty ? .null : .string(file)
        }
        row.touch()
        try Database.shared.put(collection, row)
        return Video(row: row)
    }

    /// 从片库移除。挂在它台词上的段评一起清掉（网页版 paracomment.dropVideo）。
    /// 视频文件原样留在本机：原生版不自己删媒体，交给以后的「清理无引用」（网页版第 20 条：删之前要先核引用）
    static func remove(_ id: String) throws {
        try ParaNotes.dropSubject(ParaNotes.subject(.video, id))
        try Database.shared.delete(collection, id: id)
    }

    // MARK: - 字幕

    /// 偏移取整到十分之一秒，夹在正负一分钟之内（网页版 offsetOf）
    static func offsetOf(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return max(-60, min(60, (v * 10).rounded() / 10))
    }

    static func offset(_ v: Video?) -> Double { offsetOf(v?.row.number("offset") ?? 0) }

    static func lines(_ v: Video?) -> [Subtitle.Line] {
        guard let v else { return [] }
        let lines = Subtitle.parse(v.subtitle)
        let off = offset(v)
        guard off != 0 else { return lines }
        // 偏移之后跑到零之前的那几句夹在 0 上，不丢
        return lines.map { Subtitle.Line(at: max(0, $0.at + off), end: max(0, $0.end + off), text: $0.text) }
    }

    static func hasSubtitle(_ v: Video?) -> Bool { !lines(v).isEmpty }

    /// 到这一刻为止的提纲。严格截断：已经播过去的与正在演的这一段，后面的一段都不给
    static func outlineSoFar(_ v: Video?, _ sec: Double) -> [Segment] {
        (v?.outline ?? []).filter { $0.from <= sec + 1 }
    }

    // MARK: - 放哪儿

    /// 候选地址，放不了一个换下一个。B 站的片现取（主地址与备用），别的就是地址或本机文件那一个
    static func sources(_ v: Video) async throws -> [URL] {
        if let b = v.bili, v.url.isEmpty { return try await BiliApi.playUrls(b.bvid, cid: b.cid).compactMap(URL.init(string:)) }
        if !v.url.isEmpty, let u = URL(string: v.url) { return [u] }
        if !v.fileId.isEmpty, let u = MediaStore.url(.files, id: v.fileId) { return [u] }
        return []
    }

    /// 本机播放不了的格式（网页版 needsConvert：浏览器放不了的那一类；原生版能放 mov）
    static func needsConvert(_ ext: String) -> Bool {
        ["mkv", "avi", "flv", "wmv", "rmvb", "webm", "m2ts"].contains(ext.lowercased())
    }

    /// 把选中的视频文件拷进文件域，返回文件 id。大文件不整个读进内存
    static func saveFile(from src: URL) throws -> String {
        let ext = src.pathExtension.isEmpty ? "mp4" : src.pathExtension.lowercased()
        let id = Ids.make("f")
        let dir = AppPaths.media.appendingPathComponent(MediaKind.files.rawValue, isDirectory: true)
        let dst = dir.appendingPathComponent("\(id).\(ext)")
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            throw StoreError(message: "视频文件存不下：\(error.localizedDescription)")
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
        try Database.shared.registerMedia(kind: MediaKind.files.rawValue, id: id, ext: ext, bytes: bytes)
        return id
    }

    struct Embedded: Equatable {
        var srt: String
        var lines: Int
        var tracks: Int
        var lang: String
    }

    /// 从片子自己带的字幕轨里读一份（网页版 video.subtitleFromFile；网页版自己拆 MP4 的盒子，原生版交给 AVFoundation）。
    /// 好几轨时取句数最多的那一轨。读不到给 nil：多数片子没有内封字幕，这不算出错
    static func subtitleFromFile(_ url: URL) async -> Embedded? {
        let asset = AVURLAsset(url: url)
        var tracks: [AVAssetTrack] = []
        for kind in [AVMediaType.subtitle, .text, .closedCaption] {
            tracks += (try? await asset.loadTracks(withMediaType: kind)) ?? []
        }
        guard !tracks.isEmpty else { return nil }
        var best: (lines: [Subtitle.Line], lang: String)?
        for t in tracks {
            let got = readText(asset, t)
            guard !got.isEmpty else { continue }
            if got.count > (best?.lines.count ?? 0) {
                best = (got, (try? await t.load(.languageCode)) ?? "")
            }
        }
        guard let best else { return nil }
        return Embedded(srt: Subtitle.toSrt(best.lines), lines: best.lines.count, tracks: tracks.count, lang: best.lang)
    }

    /// tx3g 一类的文字样本：前两个字节是长度（大端），后面是 UTF-8 正文
    private static func readText(_ asset: AVAsset, _ track: AVAssetTrack) -> [Subtitle.Line] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(out) else { return [] }
        reader.add(out)
        guard reader.startReading() else { return [] }
        var lines: [Subtitle.Line] = []
        while let sample = out.copyNextSampleBuffer() {
            guard let buf = CMSampleBufferGetDataBuffer(sample) else { continue }
            let len = CMBlockBufferGetDataLength(buf)
            guard len > 2 else { continue }
            var bytes = [UInt8](repeating: 0, count: len)
            guard CMBlockBufferCopyDataBytes(buf, atOffset: 0, dataLength: len, destination: &bytes) == kCMBlockBufferNoErr else { continue }
            let n = min(len - 2, Int(bytes[0]) << 8 | Int(bytes[1]))
            guard n > 0, let raw = String(bytes: bytes[2..<(2 + n)], encoding: .utf8) else { continue }
            let text = Subtitle.clean(raw)
            guard !text.isEmpty else { continue }
            let at = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let dur = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
            guard at.isFinite else { continue }
            lines.append(.init(at: at, end: at + (dur.isFinite && dur > 0 ? dur : 3), text: text))
        }
        return lines
    }

    // MARK: - 分段提纲（一部片一次调用，用户点了才调）

    /// 字幕太长会撑爆上下文：每 15 秒只留一句，时间戳保留
    static func digest(_ lines: [Subtitle.Line], every: Double = 15) -> String {
        var out: [String] = []
        var last = -every
        for l in lines where l.at - last >= every {
            last = l.at
            out.append("[\(Subtitle.stamp(l.at))] \(l.text)")
        }
        return out.joined(separator: "\n")
    }

    static func canOutline(_ v: Video?) -> Bool { lines(v).count >= 10 }
    static func hasOutline(_ v: Video?) -> Bool { !(v?.outline ?? []).isEmpty }

    @discardableResult
    static func generateOutline(_ id: String) async throws -> [Segment] {
        guard let v = get(id) else { throw StoreError(message: "这部片已不在片库中") }
        let ls = lines(v)
        guard ls.count >= 10, let last = ls.last else { throw StoreError(message: "这部片还没有可用的字幕") }
        let s = AppSettings.load()
        let system = Templates.render("task.watch-outline", [
            "title": v.title,
            "length": Subtitle.stamp(last.end > 0 ? last.end : last.at),
            "digest": digest(ls),
        ], settings: s)
        let r = try await AIService.shared.send(task: "watch.outline", system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: 3000)
        guard let j = JSONReply.parse(r.text) else { throw StoreError(message: JSONReply.failure(r.text)) }
        let segs = parseOutline(j)
        guard !segs.isEmpty else { throw StoreError(message: "模型没有给出可用的分段") }
        try update(id, Patch(outline: segs))
        return segs
    }

    static func parseOutline(_ j: JSONValue) -> [Segment] {
        (j["segments"]?.array ?? []).compactMap { x -> Segment? in
            func sec(_ v: JSONValue?) -> Double? {
                if let n = v?.number { return n }
                return v?.string.flatMap(Subtitle.toSeconds)
            }
            let text = (x["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let from = sec(x["from"]), !text.isEmpty else { return nil }
            return Segment(from: from, to: sec(x["to"]), text: text)
        }
        .enumerated().sorted { $0.element.from != $1.element.from ? $0.element.from < $1.element.from : $0.offset < $1.offset }
        .map(\.element)
    }
}
