import Foundation

/// 角色近况（网页版 system/charnow.js，ARCHITECTURE 4.381）。
///
/// 把各处已经有的东西摆在一页：此刻在做什么、今天的安排、身体状态、在听的歌、今天穿的、最近的朋友圈、最近一篇日记。
/// **只读，不生成**：哪一样没有就不写，不调接口去补。人设正文一个字都不出现（网页版第 6 条）。
enum CharNow {
    struct Day: Equatable { var slot: String; var now: [String]; var meal: String; var event: String; var summary: [String]; var done: Int; var total: Int }
    struct Music: Equatable { var recent: Bool; var at: Double; var songs: [String] }
    struct MomentLine: Equatable, Identifiable { var id: String; var at: Double; var text: String; var pics: Int; var repost: Bool }
    struct DiaryLine: Equatable { var id: String; var date: String; var title: String; var locked: Bool; var text: String }

    struct Snapshot: Equatable {
        var charId: String
        var trip: String?
        var day: Day?
        var body: [String]?
        var music: Music?
        var worn: [String]?
        var moments: [MomentLine] = []
        var diary: DiaryLine?

        var isEmpty: Bool { trip == nil && day == nil && body == nil && music == nil && worn == nil && moments.isEmpty && diary == nil }
    }

    private static func today() -> String { Health.dateKey(Date()) }

    /// 正在进行的出行（网页版 trip.goingFor）：定了、今天落在出发与返回之间、所在会话里有这个角色
    static func trip(_ charId: String) -> Row? {
        let now = today()
        let chats = Dictionary(((try? Repo.chats()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func isDate(_ s: String) -> Bool { s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
        for r in (try? Database.shared.all("trips")) ?? [] {
            guard r.string("state") == "booked" else { continue }
            let from = isDate(r.string("from")) ? r.string("from") : ""
            let to = isDate(r.string("to")) ? r.string("to") : from
            guard !from.isEmpty, now >= from, now <= to else { continue }
            if let c = chats[r.string("chatId")], c.characterIds.contains(charId) { return r }
        }
        return nil
    }

    /// 今天穿着的（网页版 closet.wornToday，去掉随身那一类）：自己的没借出去的，加上借来的
    static func worn(_ charId: String) -> [String] {
        let d = today()
        let gone: Set<String> = ["done", "gone", "sold"]
        func live(_ r: Row) -> Bool { !gone.contains(r.string("state")) }
        func lent(_ r: Row) -> Bool { !(r["lent"]?["to"]?.string ?? "").isEmpty }
        func on(_ r: Row) -> Bool { r.string("side") == "wear" && r.string("wornOn") == d && live(r) }
        let all = (try? Database.shared.all("closet")) ?? []
        let own = all.filter { $0.string("owner") == charId && on($0) && !lent($0) }
        let borrowed = all.filter { lent($0) && $0["lent"]?["to"]?.string == charId && $0.string("owner") != charId
            && $0.string("side") != "outfit" && live($0) && on($0) }
        return (own + borrowed).filter { $0.string("group") != "carry" }.map { $0.string("name") }.filter { !$0.isEmpty }
    }

    static func snapshot(_ charId: String, personaId: String) -> Snapshot? {
        guard let char = try? Repo.character(charId) else { return nil }
        var out = Snapshot(charId: charId)
        let going = trip(charId)
        if let going { out.trip = going.string("title").isEmpty ? "出行中" : going.string("title") }

        // 出行期间日程让开（与 context/day.js 同一条）
        if going == nil, let b = DayPlan.brief(char) {
            let ev = b.event?["text"]?.string ?? ""
            out.day = Day(slot: b.slot.label, now: b.nowItems, meal: b.meal, event: ev, summary: b.summary, done: b.doneCount, total: b.total)
        }

        if Health.charOn(char) {
            let d = Health.day(charId)
            let sym = d.symptoms.map { Health.label(Health.symptoms, $0) }.filter { !$0.isEmpty }
            var body: [String] = []
            if !d.energy.isEmpty { body.append("精力：\(Health.label(Health.energy, d.energy))") }
            if !d.mood.isEmpty { body.append("心情：\(Health.label(Health.moods, d.mood))") }
            if !sym.isEmpty { body.append("不适：\(sym.joined(separator: "、"))") }
            if d.sleepMin > 0 { body.append("睡眠：\(Health.fmtSleep(d.sleepMin))") }
            if !body.isEmpty { out.body = body }
        }

        if let np = char.row["nowPlaying"]?.object, let songs = np["songs"]?.array, !songs.isEmpty {
            out.music = Music(recent: np["kind"]?.string == "recent", at: np["at"]?.number ?? 0, songs: songs.prefix(3).map { s in
                let t = s["title"]?.string ?? "", a = s["artist"]?.string ?? ""
                return a.isEmpty ? t : "\(t) — \(a)"
            })
        }

        let w = worn(charId)
        if !w.isEmpty { out.worn = w }

        out.moments = Moments.by(charId).filter { !$0.recalled }.sorted { $0.createdAt > $1.createdAt }.prefix(2).map {
            MomentLine(id: $0.id, at: $0.createdAt, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                       pics: $0.images.count, repost: $0.row["repost"].map { $0 != .null && $0 != .bool(false) } ?? false)
        }

        if let d = ((try? Diary.ofChar(charId, personaId)) ?? []).first {
            // 上了锁的不露正文，只说上了锁
            let text = d.locked ? "" : d.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // 有意截断：只是这一页上的一行摘要，正文在日记里
            out.diary = DiaryLine(id: d.id, date: d.date, title: d.title, locked: d.locked, text: String(text.prefix(80)))
        }
        return out
    }

    /// 资料页那一行的副标题：此刻在做的，没有就取最先有的一样
    static func line(_ s: Snapshot?) -> String {
        guard let s else { return "" }
        if let t = s.trip { return "出行中：\(t)" }
        if let d = s.day, !d.now.isEmpty { return "\(d.slot)：\(d.now.joined(separator: "；"))" }
        if let d = s.day, !d.slot.isEmpty { return d.slot }
        if let m = s.music, let first = m.songs.first { return "在听：\(first)" }
        if !s.moments.isEmpty { return "最近发了朋友圈" }
        return ""
    }
}
