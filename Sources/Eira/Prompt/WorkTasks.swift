import Foundation

/// 长篇的几次请求（网页版 ai/tasks/novel.js 与 ai/tasks/work.js，ARCHITECTURE 4.263、4.264、4.283）。
///
/// **全部由用户点按钮触发，点一次调一次**，按钮下写明次数；不是自动触发的，不进 ExtraCalls（第 15 条）。CostTests 数着：
///   简介   按人设、世界观、体裁、篇幅、灵感写一段
///   大纲   总纲 + 卷纲一次；章数少的连章纲一起要
///   卷纲   写到哪一卷补哪一卷（每卷一次）
///   走向   章末给几个候选（一次）
///   重排   按已经写出来的走向重排后续大纲（一次）
///   身份   按这部作品的世界改写一份身份（一次，先给用户看、改，再存）
/// 前五样走「长篇的简介、大纲、走向与改写身份」那一组接口（RouteGroups 的 novel），没选时用副用。
///
/// 收篇摘要（work.summary）是另一次调用，**默认关**（settings.workSummary，登记在 ExtraCalls）。
enum WorkTasks {
    static let synopsisTask = "work.synopsis", outlineTask = "work.outline", branchTask = "work.branch"
    static let identityTask = "work.identity", summaryTask = "work.summary"

    /// 读历史、注入摘要时每条取多少字（网页版 snipLen，4.875）：0 为全文，默认全文
    static func snipLen(_ s: AppSettings = .load()) -> Int { max(0, Int(s.num("snipLen", 0).rounded())) }

    private static func snipTail(_ text: String, _ s: AppSettings) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = snipLen(s)
        return n > 0 && t.count > n ? "…" + String(t.suffix(n)) : t   // 有意截断：用户设的「每条摘录的字数」，0 为全文
    }

    struct Ctx {
        var cast = "", world = "(none)", genres = "(none)"
        var chapters = 0, perChapter = 0
        var title = "", synopsis = "", secret = "", inspiration = ""
    }

    /// 这部作品的固定材料：人物、世界观、体裁、篇幅。几次请求共用。存进去的字一律不截断（第 13 条）
    static func contextOf(_ w: Row) -> Ctx {
        let c = Works.charOf(w), m = Works.meOf(w)
        func line(_ name: String, _ p: String) -> String {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            return "- \(name): \(t.isEmpty ? "(no persona)" : t)"
        }
        var cast = [line(c.name, c.persona), line(m.name, m.persona)]
        for id in w.strings("castIds").dropFirst() {
            if let x = (try? Repo.character(id)) ?? nil { cast.append(line(x.row.string("name"), x.persona)) }
        }
        let lib = (try? Repo.lorebooks()) ?? []
        let books = w.strings("lorebookIds").compactMap { id in lib.first { $0.id == id } }
        let world = books.flatMap { b in
            b.entries.filter { $0.enabled && !$0.isCard }.map { e in
                (e.comment.isEmpty ? "" : "\(e.comment): ") + e.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var out = Ctx()
        out.cast = cast.joined(separator: "\n")
        out.world = world.isEmpty ? "(none)" : world.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let g = w.strings("genres")
        out.genres = g.isEmpty ? "(none)" : g.joined(separator: ", ")
        out.chapters = max(0, Int((w["length"]?["chapters"]?.number ?? 0).rounded()))
        out.perChapter = max(0, Int((w["length"]?["perChapter"]?.number ?? 0).rounded()))
        func t(_ k: String) -> String { w.string(k).trimmingCharacters(in: .whitespacesAndNewlines) }
        out.title = t("title"); out.synopsis = t("premise"); out.secret = t("secret"); out.inspiration = t("inspiration")
        return out
    }

    private static func lengthText(_ c: Ctx) -> String {
        c.chapters > 0 ? "\(c.chapters) chapters" + (c.perChapter > 0 ? ", about \(c.perChapter) Chinese characters each" : "") : "(length not fixed)"
    }

    private static func ask(_ task: String, system: String, maxTokens: Int) async throws -> JSONValue {
        let r = try await AIService.shared.send(task: task, system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the JSON as instructed.")],
                                                maxTokens: maxTokens, retries: 1)
        guard let json = JSONReply.parse(r.text) else { throw StoreError(message: JSONReply.failure(r.text)) }
        return json
    }

    private static func str(_ v: JSONValue?) -> String { (v?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - 身份（4.283）

    /// 按这部作品的世界改写身份。who 是 char 或 me。改写的是原来那份（角色卡 / 账号资料），不是已经改过一次的。这里不写库
    static func identity(_ w: Row, who: String) async throws -> (name: String, persona: String) {
        let ctx = contextOf(w)
        let c = Works.charOf(w), m = Works.meOf(w)
        let me = who == "me"
        let base = (me ? m.basePersona : c.basePersona).trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = me ? (m.baseName.isEmpty ? "我" : m.baseName) : (c.baseName.isEmpty ? c.name : c.baseName)
        if base.isEmpty { throw StoreError(message: me ? "当前账号还没有写人设" : "这个角色还没有写人设") }
        let system = Templates.render("task.novel-identity", [
            "name": baseName, "persona": base,
            "title": ctx.title.isEmpty ? "(untitled)" : ctx.title, "premise": ctx.synopsis.isEmpty ? "(none)" : ctx.synopsis,
            "genres": ctx.genres, "world": ctx.world, "other": me ? c.name : m.name,
        ], settings: .load())
        let r = try await ask(identityTask, system: system, maxTokens: 2000)
        let name = str(r["name"])
        return (name.isEmpty ? baseName : name, str(r["persona"]))
    }

    // MARK: - 简介

    /// 简介。隐藏大纲的那一档另要一份作者私纲（含谜底），读者简介里不剧透。字数是用户在预设里填的（4.387）
    static func synopsis(_ w: Row, hidden: Bool) async throws -> (title: String, synopsis: String, secret: String) {
        let ctx = contextOf(w)
        let s = AppSettings.load()
        let system = Templates.render("task.novel-synopsis", [
            "cast": ctx.cast, "world": ctx.world, "genres": ctx.genres, "length": lengthText(ctx),
            "inspiration": ctx.inspiration.isEmpty ? "(none)" : ctx.inspiration, "title": ctx.title.isEmpty ? "(not chosen yet)" : ctx.title,
            "synMin": "\(max(1, Int(s.num("synopsisMin", 400).rounded())))", "synMax": "\(max(1, Int(s.num("synopsisMax", 800).rounded())))",
            "secret": hidden ? "Also write \"secret\": the author-only plan with the twists and the answers, which the reader synopsis must not reveal." : "",
        ], settings: s)
        let r = try await ask(synopsisTask, system: system, maxTokens: 1200)
        return (str(r["title"]), str(r["synopsis"]), hidden ? str(r["secret"]) : "")
    }

    // MARK: - 大纲

    private static func masterText(_ m: Novel.Master?) -> String {
        guard let m else { return "(none)" }
        return ["Main line: \(m.mainline)", m.subline.isEmpty ? "" : "Hidden line: \(m.subline)", m.ending.isEmpty ? "" : "Ending: \(m.ending)",
                m.twists.isEmpty ? "" : "Turns: \(m.twists.joined(separator: "; "))"].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 总纲 + 卷纲。章数不多就连章纲一起
    static func outline(_ w: Row) async throws -> Novel.Made {
        let ctx = contextOf(w)
        let chapters = ctx.chapters > 0 ? ctx.chapters : 24
        let withChapters = chapters <= Novel.oneShotChapters
        let system = Templates.render("task.novel-outline", [
            "cast": ctx.cast, "world": ctx.world, "genres": ctx.genres, "length": lengthText(ctx),
            "title": ctx.title.isEmpty ? "(untitled)" : ctx.title, "synopsis": ctx.synopsis.isEmpty ? "(none)" : ctx.synopsis,
            "secret": ctx.secret.isEmpty ? "" : "## Author-only plan (twists and answers)\n\(ctx.secret)",
            "chapters": "\(chapters)", "volumes": "\(Novel.volumesFor(chapters))",
            "chapterRule": withChapters
                ? "This book is short, so also list every chapter: each volume gets \"chapters\": [{\"no\": 1, \"title\": \"...\", \"line\": \"one sentence: what happens and what changes\"}], covering every chapter number from \"from\" to \"to\"."
                : "Do not list individual chapters; they are planned volume by volume later.",
        ], settings: .load())
        let r = try await ask(outlineTask, system: system, maxTokens: withChapters ? 4000 : 2600)
        let made = Novel.made(r)
        guard r["master"]?.object != nil, !(r["volumes"]?.array ?? []).isEmpty else { throw StoreError(message: "模型没有给出可用的大纲") }
        return made
    }

    /// 某一卷的章纲
    static func volume(_ w: Row, _ vol: Novel.Volume) async throws -> [Novel.Line] {
        let ctx = contextOf(w)
        let s = AppSettings.load()
        let o = Novel.outlineOf(w)
        let done = o.volumes.filter { $0.no < vol.no }.map { "Volume \($0.no)\($0.title.isEmpty ? "" : " \($0.title)"): \($0.goal)" }.joined(separator: "\n")
        let written = Works.chaptersOf(w.id).filter { Int($0.number("no") ?? 0) < vol.from }.suffix(3)
            .map { "Chapter \(Int($0.number("no") ?? 0)): \(Works.digestOf($0.id, chars: snipLen(s)))" }.joined(separator: "\n")
        let system = Templates.render("task.novel-volume", [
            "cast": ctx.cast, "genres": ctx.genres, "title": ctx.title.isEmpty ? "(untitled)" : ctx.title, "synopsis": ctx.synopsis.isEmpty ? "(none)" : ctx.synopsis,
            "secret": ctx.secret.isEmpty ? "" : "## Author-only plan\n\(ctx.secret)",
            "master": masterText(o.master), "before": done.isEmpty ? "(this is the first volume)" : done, "written": written.isEmpty ? "(nothing written yet)" : written,
            "no": "\(vol.no)", "vtitle": vol.title, "goal": vol.goal, "from": "\(vol.from)", "to": "\(vol.to)", "reveal": vol.reveal.isEmpty ? "(nothing in particular)" : vol.reveal,
        ], settings: s)
        let r = try await ask(outlineTask, system: system, maxTokens: 3000)
        let raw = r["chapters"]?.array ?? r.array ?? []
        guard !raw.isEmpty else { throw StoreError(message: "模型没有给出这一卷的章纲") }
        return raw.enumerated().map { i, c in
            let n = c["no"]?.number.map { Int($0.rounded()) } ?? 0
            return Novel.Line(no: n != 0 ? n : vol.from + i, title: str(c["title"]), line: str(c["line"]))
        }
    }

    struct Branch: Equatable, Identifiable {
        var title: String
        var line: String
        var follows: Bool
        var id: String { title + "|" + line }
    }

    /// 章末：给几个走向（4.264）。count 由用户定
    static func branches(_ w: Row, after chapter: Row?, count: Int) async throws -> [Branch] {
        let ctx = contextOf(w)
        let s = AppSettings.load()
        let o = Novel.outlineOf(w)
        let cur = Int(chapter?.number("no") ?? 0)
        let next = cur + 1
        let vol = Novel.volumeOf(o, next)
        let line = vol.flatMap { v in (o.chapters[v.no] ?? []).first { $0.no == next } }
        let recent = Works.chaptersOf(w.id).filter { Int($0.number("no") ?? 0) <= cur }.suffix(2).map { c in
            let t = c.string("title")
            return "Chapter \(Int(c.number("no") ?? 0))\(t.isEmpty ? "" : " \(t)"): \(Works.digestOf(c.id, chars: snipLen(s)))"
        }.joined(separator: "\n")
        let system = Templates.render("task.novel-branches", [
            "cast": ctx.cast, "genres": ctx.genres, "title": ctx.title.isEmpty ? "(untitled)" : ctx.title, "synopsis": ctx.synopsis.isEmpty ? "(none)" : ctx.synopsis,
            "secret": ctx.secret.isEmpty ? "" : "## Author-only plan\n\(ctx.secret)",
            "master": masterText(o.master), "recent": recent.isEmpty ? "(nothing written yet)" : recent,
            "volume": vol.map { "Volume \($0.no): \($0.goal)" } ?? "(no volume plan)",
            "planned": line.map { ($0.title.isEmpty ? "" : "\($0.title): ") + $0.line } ?? "(no chapter plan)",
            "next": "\(next)", "count": "\(max(1, count))",
        ], settings: s)
        let r = try await ask(branchTask, system: system, maxTokens: 1600)
        let raw = r["options"]?.array ?? r.array ?? []
        guard !raw.isEmpty else { throw StoreError(message: "模型没有给出走向") }
        return raw.map { Branch(title: str($0["title"]), line: str($0["line"]), follows: $0["follows"]?.bool != false) }.filter { !$0.line.isEmpty }
    }

    /// 剧情偏离大纲之后：从下一章起重排后续的卷与章（一次）
    static func replan(_ w: Row, from fromNo: Int) async throws -> Novel.Made {
        let ctx = contextOf(w)
        let s = AppSettings.load()
        let o = Novel.outlineOf(w)
        let written = Works.chaptersOf(w.id).filter { Int($0.number("no") ?? 0) < fromNo }.map { c in
            let t = c.string("title")
            return "Chapter \(Int(c.number("no") ?? 0))\(t.isEmpty ? "" : " \(t)"): \(Works.digestOf(c.id, chars: snipLen(s)))"
        }.joined(separator: "\n")
        let chapters = ctx.chapters > 0 ? ctx.chapters : 24
        let left = max(1, chapters - fromNo + 1)
        let tail = snipTail(written, s)
        let system = Templates.render("task.novel-replan", [
            "cast": ctx.cast, "genres": ctx.genres, "title": ctx.title.isEmpty ? "(untitled)" : ctx.title, "synopsis": ctx.synopsis.isEmpty ? "(none)" : ctx.synopsis,
            "secret": ctx.secret.isEmpty ? "" : "## Author-only plan\n\(ctx.secret)",
            "master": masterText(o.master), "written": tail.isEmpty ? "(nothing written yet)" : tail,
            "from": "\(fromNo)", "to": "\(chapters)", "volumes": "\(Novel.volumesFor(left))",
            "chapterRule": left <= Novel.oneShotChapters
                ? "Also list every remaining chapter inside each volume as \"chapters\": [{\"no\", \"title\", \"line\"}]."
                : "Do not list individual chapters; they are planned volume by volume later.",
        ], settings: s)
        let r = try await ask(outlineTask, system: system, maxTokens: 3600)
        guard !(r["volumes"]?.array ?? []).isEmpty else { throw StoreError(message: "模型没有给出可用的大纲") }
        var made = Novel.made(r)
        if made.master == nil { made.master = o.master }
        return made
    }

    /// 重排的结果并进现有大纲：已经写过的卷留着，后面接上新排的（网页版 WorkPage 的 replan）
    @discardableResult
    static func applyReplan(_ workId: String, from: Int, _ made: Novel.Made) throws -> Row? {
        try Novel.setOutline(workId) { o in
            let kept = o.volumes.filter { $0.to < from }
            var chs: [Int: [Novel.Line]] = [:]
            for v in kept { if let l = o.chapters[v.no] { chs[v.no] = l } }
            var fresh: [Novel.Volume] = []
            for (i, v0) in made.volumes.enumerated() {
                var v = v0
                v.no = kept.count + i + 1
                if let l = made.chapters[v0.no], !l.isEmpty { chs[v.no] = l }
                fresh.append(v)
            }
            o.master = made.master ?? o.master
            o.volumes = kept + fresh
            o.chapters = chs
            o.drift = false
            o.madeAt = Date().millis
        }
    }

    // MARK: - 收篇摘要（默认关）

    static func summaryOn(_ s: AppSettings = .load()) -> Bool { s.raw["workSummary"]?.bool == true }

    /// 收篇：把这一篇压成一段，写回 chapter.summary。开关关着时不调
    @discardableResult
    static func wrap(_ chapterId: String) async throws -> String {
        guard summaryOn() else { return "" }
        guard let row = Works.getChapter(chapterId), let w = Works.workOfChapter(chapterId) else { throw StoreError(message: "这一篇已经不在了") }
        let c = Works.charOf(w), m = Works.meOf(w)
        let body = Scenes.beatsOf(chapterId).filter { $0.string("role") != Scenes.DIRECTOR && !$0.string("text").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { b -> String in
                let who = b.string("role") == Scenes.ME ? m.name : c.name
                let at = b.string("at").isEmpty ? "" : "（\(b.string("at"))）"
                return "\(who)\(at)：\n\(b.string("text").trimmingCharacters(in: .whitespacesAndNewlines))"
            }.joined(separator: "\n\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let t = row.string("title")
        let head = [w.string("title").isEmpty ? "" : "作品：\(w.string("title"))",
                    w.string("kind") == Works.SAGA ? "第 \(Int(row.number("no") ?? 0)) 章" + (t.isEmpty ? "" : "　\(t)") : t,
                    row.string("place").isEmpty ? "" : "地点：\(row.string("place"))",
                    row.string("summary").isEmpty ? "" : "[这一篇之前发生过什么]\n\(row.string("summary"))"]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let s = AppSettings.load()
        let r = try await AIService.shared.send(task: summaryTask, system: Templates.get("task.work-summary", settings: s),
                                                messages: [AIMessage(role: .user, content: [head, body].filter { !$0.isEmpty }.joined(separator: "\n\n"))],
                                                maxTokens: 1200, retries: 1)
        let text = ReplyParser.stripThink(r.text).0.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { try Works.updateChapter(chapterId, ["summary": .string(text)]) }
        return text
    }
}
