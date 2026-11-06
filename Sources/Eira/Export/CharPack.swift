import Foundation

/// 角色包（网页版 system/charpack.js，ARCHITECTURE 4.116）：一个角色和挂在它名下的一切打成一个 zip，换台设备装回去。
///
/// 格式与网页版一字不差：zip（只存不压）里一份 `character.json`（`_format: mini-phone-character`、`_version: 2`），
/// 加 `images/<id>.<ext>`、`files/<id>.<ext>`。网页版打的包原生版装得回，原生版打的包网页版装得回（CharPackTests、check-export.mjs）。
///
/// 带走的两批与 purge 的删正好对应：挂在会话上的（消息、线下、出行、纪念日、草稿、美化）与挂在角色上的（记忆、动态、每一天、
/// 吃饭、健康、影评书评、段评、待办、那台手机……）。不带走使用者自己的库：书、片子、歌（会话与动态里用到的那几首除外）、表情、相册。
///
/// 装回去：角色 id 撞了整包换一套 id 另建副本，不覆盖；世界书与美化 id 撞了用本机那一份；图片与文件已有的跳过。
/// 会话、记忆一律挂到当前账号下（包里的 personaId 是导出那台设备的）。
enum CharPack {
    static let format = "mini-phone-character"
    static let version = 2

    private static var db: Database { .shared }
    private static func has(_ c: String, _ id: String) -> Bool { !id.isEmpty && ((try? db.get(c, id: id)) ?? nil) != nil }

    // MARK: - 带走哪些

    /// 包里每一组的键名，按网页版 build 写出来的顺序。除了 alts（角色的小号，在 characters 里）都是数据域的名字
    static let kinds = ["alts", "lorebooks", "memories", "chats", "messages", "scenes", "works", "chapters", "beats", "trips", "spaceItems",
                        "skins", "days", "meals", "health", "phones", "phoneChats", "moments", "reviews", "readnotes", "todos", "playlists",
                        "songs", "closet", "wishes", "ties", "smsThreads", "diaries", "dreams", "memsnaps", "dramas", "drafts", "impressions",
                        "collection", "mallPeople", "mallItems", "pets", "cams", "camLogs", "quizRuns", "boxes", "slips", "slipLog"]

    /// 除会话、消息、记忆、线下、美化之外，跟着角色走的那几域。界面上报一个总数
    static let extraKinds = ["trips", "spaceItems", "days", "meals", "health", "phones", "phoneChats", "moments", "reviews", "readnotes",
                             "todos", "playlists", "closet", "wishes", "ties", "smsThreads", "diaries", "dreams", "memsnaps", "dramas", "drafts",
                             "impressions", "collection", "mallPeople", "mallItems", "slips", "pets", "camLogs", "quizRuns"]

    struct Gathered {
        var main: Row
        var groups: [String: [Row]]
        var imgIds: [String]
        var fileIds: [String]
        func n(_ k: String) -> Int { groups[k]?.count ?? 0 }
    }

    private static func ids(_ v: JSONValue?) -> [String] { (v?.array ?? []).compactMap(\.string) }

    static func collect(_ charId: String, history: Bool = true) throws -> Gathered {
        guard let main = try db.get(Collections.characters, id: charId) else { throw StoreError(message: "这个角色已经不在了") }
        let allChars = try db.all(Collections.characters)
        let alts = allChars.filter { $0.string("parentId") == charId && $0.id != charId }
        let cast = [main] + alts
        let castIds = Set(cast.map(\.id))
        var g: [String: [Row]] = ["alts": alts]

        // 关联的世界书。全局那种不带走
        var bookIds: [String] = []
        for c in cast { for b in ids(c["lorebookIds"]) where !bookIds.contains(b) { bookIds.append(b) } }
        g["lorebooks"] = try bookIds.compactMap { try db.get(Collections.lorebooks, id: $0) }.filter { !$0.bool("global") }

        // 群不带走：群里的其他成员不一定在这个包里。只在群里生效的记忆同理
        let chatRows = try history ? db.all(Collections.chats).filter { r in
            r["group"]?.bool != true && ids(r["characterIds"]).contains { castIds.contains($0) }
        } : []
        let smsRows = try history ? db.all("smsThreads").filter { castIds.contains($0.string("charId")) } : []
        g["chats"] = chatRows
        g["smsThreads"] = smsRows
        g["messages"] = try (chatRows + smsRows).flatMap { try db.all(Collections.messages, where: $0.id) }
        g["memories"] = try history ? cast.flatMap { try db.all(Collections.memories, where: $0.id) }.filter { $0.string("scopeChat").isEmpty } : []

        // 挂在这几段会话上的
        let sceneRows = try chatRows.flatMap { try db.all("scenes", where: $0.id) }
        let workRows = try chatRows.flatMap { try db.all("works", where: $0.id) }
            + db.all("works").filter { $0.string("chatId").isEmpty && ids($0["castIds"]).contains { castIds.contains($0) } }
        let chapterRows = try workRows.flatMap { try db.all("chapters", where: $0.id) }
        g["scenes"] = sceneRows
        g["works"] = workRows
        g["chapters"] = chapterRows
        g["beats"] = try (sceneRows + chapterRows).flatMap { try db.all("beats", where: $0.id) }
        g["trips"] = try chatRows.flatMap { try db.all("trips", where: $0.id) }
        g["spaceItems"] = try chatRows.flatMap { try db.all("spaceItems", where: $0.id) }
        g["drafts"] = try chatRows.flatMap { try db.all("drafts", where: $0.id) }
        // 角色眼中的你：印象与零散依据跟着会话走；整理结果与水位线不带
        g["impressions"] = try history ? cast.flatMap { try db.all("impressions", where: $0.id) }
            .filter { ["imp", "note"].contains($0.string("kind")) } : []
        var skinIds: [String] = []
        for c in chatRows { let s = c.string("skinId"); if !s.isEmpty && !skinIds.contains(s) { skinIds.append(s) } }
        g["skins"] = try skinIds.compactMap { try db.get("skins", id: $0) }

        // 挂在这几个角色上的
        func byIndex(_ c: String) throws -> [Row] { try cast.flatMap { try db.all(c, where: $0.id) } }
        func whereField(_ c: String, _ k: String) throws -> [Row] { try db.all(c).filter { castIds.contains($0.string(k)) } }
        g["days"] = try history ? byIndex("days") : []
        g["meals"] = try history ? byIndex("meals") : []
        g["health"] = try history ? byIndex("health") : []
        g["phones"] = try history ? byIndex("phones") : []
        g["phoneChats"] = try history ? byIndex("phoneChats") : []
        let momentRows = try history ? whereField("moments", "authorId") : []
        g["moments"] = momentRows
        g["reviews"] = try history ? whereField("reviews", "charId") : []
        g["readnotes"] = try history ? whereField("readnotes", "authorId") : []
        g["todos"] = try history ? whereField("todos", "charId") : []
        // 角色自己的衣帽间与收藏馆：算角色的一部分，不看要不要带聊天记录
        g["closet"] = try byIndex("closet")
        g["collection"] = try byIndex("collection")
        // 商城身份与它挂着、还没卖出的商品。订单与议价不带
        let mallPeople = try db.all("mallPeople").filter { $0.string("kind") == "char" && castIds.contains($0.string("charId")) }
        let mallPids = Set(mallPeople.map(\.id))
        g["mallPeople"] = mallPeople
        g["mallItems"] = try db.all("mallItems").filter { mallPids.contains($0.string("sellerId")) && $0.string("state") != "sold" }
        g["wishes"] = try history ? whereField("wishes", "owner") : []
        // 密语：角色的个人与私人纸条盒、里面的纸条与时间线
        let boxes = try history ? db.all("boxes").filter { ["own", "private"].contains($0.string("kind")) && castIds.contains($0.string("owner")) } : []
        let slips = try boxes.flatMap { try db.all("slips", where: $0.id) }
        let slipIds = Set(slips.map(\.id))
        g["boxes"] = boxes
        g["slips"] = slips
        g["slipLog"] = try history ? db.all("slipLog").filter { slipIds.contains($0.string("slipId")) } : []
        g["diaries"] = try history ? byIndex("diaries") : []
        g["dreams"] = try history ? byIndex("dreams") : []
        g["memsnaps"] = try history ? byIndex("memsnaps") : []
        g["dramas"] = try history ? byIndex("dramas").filter { $0.string("kind") == "made" } : []
        // 宠物：这几个角色的、和我一起养的；对着角色与这几只宠物的摄像头一起带，监控记录跟着聊天记录走
        let pets = try db.all("pets").filter { $0.string("owner") != "me" && castIds.contains($0.string("charId")) }
        let petIds = Set(pets.map(\.id))
        func onPack(_ r: Row) -> Bool { r.string("kind") == "char" ? castIds.contains(r.string("targetId")) : petIds.contains(r.string("targetId")) }
        g["pets"] = pets
        g["cams"] = try db.all("cams").filter(onPack)
        g["camLogs"] = try history ? db.all("camLogs").filter(onPack) : []
        g["quizRuns"] = try history ? whereField("quizRuns", "charId") : []
        // 好友与拉黑：这几个角色与你之间的（两个方向）
        g["ties"] = try history ? db.all(Ties.collection).filter { t in
            (castIds.contains(t.string("from")) && t.string("to") == "me") || (t.string("from") == "me" && castIds.contains(t.string("to")))
        } : []
        // 角色自己的歌单，以及歌单里、会话里分享过的、动态里带的那几首
        let lists = try history ? whereField("playlists", "owner") : []
        g["playlists"] = lists
        var songIds: [String] = []
        func addSong(_ s: String) { if !s.isEmpty && !songIds.contains(s) { songIds.append(s) } }
        for p in lists { ids(p["trackIds"]).forEach(addSong) }
        for m in g["messages"] ?? [] where m.string("kind") == "song" { addSong(m.string("songId")) }
        for m in momentRows { addSong(m.string("songId")) }
        g["songs"] = try songIds.compactMap { try db.get("songs", id: $0) }

        let (img, file) = media(cast: cast, g: g, chats: chatRows)
        return Gathered(main: main, groups: g,
                        imgIds: img.filter { MediaStore.url(.images, id: $0) != nil },
                        fileIds: file.filter { MediaStore.url(.files, id: $0) != nil })
    }

    /// 要跟着走的图片与音频（网页版 collect 后半段，同一张清单）
    private static func media(cast: [Row], g: [String: [Row]], chats: [Row]) -> ([String], [String]) {
        var img: [String] = [], file: [String] = []
        func i(_ v: JSONValue?) { if let s = v?.string, !s.isEmpty, !img.contains(s) { img.append(s) } }
        func f(_ v: JSONValue?) { if let s = v?.string, !s.isEmpty, !file.contains(s) { file.append(s) } }
        func each(_ v: JSONValue?, _ body: (JSONValue) -> Void) { (v?.array ?? []).forEach(body) }
        for c in cast {
            ["avatar", "cover", "faceImage", "callImage", "portrait", "avatarBase"].forEach { i(c[$0]) }
            each(c["faceImages"]) { i($0) }; each(c["imageRefs"]) { i($0) }
            each(c["avatarPool"]) { i($0["imageId"]) }
            each(c["highlights"]) { i($0["imageId"]) }
            each(c["shelf"]) { i($0["cover"]) }
        }
        for m in g["messages"] ?? [] {
            i(m["imageId"]); each(m["imageVers"]) { i($0) }; i(m["posterId"])
            each(m["forward"]?["items"]) { i($0["imageId"]); i($0["face"]) }
            each(m["share"]?["images"]) { i($0) }
            f(m["audioId"]); f(m["clipId"])
            for e in (m["swipeMedia"]?.object ?? [:]).values {
                i(e["imageId"]); each(e["imageVers"]) { i($0) }; i(e["posterId"]); f(e["audioId"]); f(e["clipId"])
            }
            f(m["fileId"])
            if m.string("kind") == "call" { each(m["callLog"]) { each($0["audio"]) { f($0) } } }
        }
        for m in g["moments"] ?? [] { each(m["images"]) { i($0) } }
        for r in g["closet"] ?? [] { i(r["imageId"]) }
        for r in g["collection"] ?? [] { each(r["photos"]) { i($0["imageId"]) } }
        for r in g["mallItems"] ?? [] { each(r["images"]) { i($0) } }
        for r in g["mallPeople"] ?? [] { i(r["avatar"]) }
        for p in g["pets"] ?? [] {
            i(p["photo"]); each(p["faces"]) { i($0) }
            each(p["care"]?["stages"]) { for v in ($0["images"]?.object ?? [:]).values { i(v) } }
        }
        for l in g["camLogs"] ?? [] { each(l["entries"]) { i($0["imageId"]) } }
        for r in g["quizRuns"] ?? [] {
            let q = r["snap"]
            i(q?["style"]?["cover"])
            each(q?["questions"]) { x in i(x["image"]); each(x["options"]) { i($0["image"]) } }
            each(q?["results"]) { i($0["image"]) }
        }
        for c in chats {
            i(c["look"]?["bg"])
            for v in (c["faces"]?.object ?? [:]).values { i(v) }
        }
        for s in g["songs"] ?? [] { i(s["coverId"]); f(s["audioId"]) }
        for d in g["dramas"] ?? [] { each(d["tracks"]) { each($0["lines"]) { f($0["audio"]) } } }
        for row in g["phones"] ?? [] {
            each(row["photos"]) { i($0["imageId"]) }
            i(row["wallpaper"])
            for v in (row["icons"]?.object ?? [:]).values { i(v["imageId"]) }
        }
        return (img, file)
    }

    struct Estimate: Equatable {
        var name: String
        var alts, books, chats, messages, memories, scenes, works, chapters, extras, skins, images, files: Int
    }

    /// 导出前把账摆出来：带走几段会话、多少条消息、几张图
    static func estimate(_ charId: String, history: Bool = true) throws -> Estimate {
        let g = try collect(charId, history: history)
        let name = g.main.string("name")
        return Estimate(name: name.isEmpty ? "未命名" : name, alts: g.n("alts"), books: g.n("lorebooks"), chats: g.n("chats"),
                        messages: g.n("messages"), memories: g.n("memories"), scenes: g.n("scenes"), works: g.n("works"),
                        chapters: g.n("chapters"), extras: extraKinds.reduce(0) { $0 + g.n($1) }, skins: g.n("skins"),
                        images: g.imgIds.count, files: g.fileIds.count)
    }

    // MARK: - 打包

    /// 文件名。名字里可能有斜杠之类的，扫掉再用（网页版 fileNameFor）
    static func fileName(_ name: String, now: Date = Date()) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let clean = String(String((name.isEmpty ? "未命名" : name).unicodeScalars.filter { !bad.contains($0) }).prefix(24))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return "角色-\(clean.isEmpty ? "未命名" : clean)-\(f.string(from: now)).zip"
    }

    struct Built { var file: URL; var bytes: Int; var media: Int }

    static func build(_ charId: String, history: Bool = true) throws -> Built {
        let g = try collect(charId, history: history)
        let dataVersion = Int((try db.kv(KVKey.dataVersion))?.number ?? Double(BackupImporter.minDataVersion))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // 键的先后照网页版 build：一份一份接起来，不经过字典（字典不保留顺序）
        var head: [(String, JSONValue)] = [
            ("_format", .string(format)), ("_version", .number(Double(version))), ("_data", .number(Double(dataVersion))),
            ("_history", .bool(history)), ("exportedAt", .string(iso.string(from: Date()))), ("character", .object(g.main.fields)),
        ]
        for k in kinds { head.append((k, .array((g.groups[k] ?? []).map { .object($0.fields) }))) }
        var json = Data("{".utf8)
        for (i, (k, v)) in head.enumerated() {
            if i > 0 { json.append(UInt8(ascii: ",")) }
            json.append(try JSONValue.string(k).encoded())
            json.append(UInt8(ascii: ":"))
            json.append(try v.encoded())
        }
        json.append(UInt8(ascii: "}"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eira-charpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(fileName(g.main.string("name")))
        let zip = try ZipWriter(url: out)
        try zip.add(name: "character.json", data: json)
        var written = 0
        for (kind, list) in [(MediaKind.images, g.imgIds), (MediaKind.files, g.fileIds)] {
            for id in list {
                guard let url = MediaStore.url(kind, id: id), let bytes = try? Data(contentsOf: url) else { continue }
                try zip.add(name: "\(kind.rawValue)/\(id).\(url.pathExtension.isEmpty ? "bin" : url.pathExtension)", data: bytes)
                written += 1
            }
        }
        try zip.finish()
        // 打出来先自己读一遍（网页版 verify）
        guard let check = try? ZipReader(data: Data(contentsOf: out, options: .mappedIfSafe)),
              let e = check.entry(named: "character.json"), let back = check.contents(of: e),
              (try? JSONValue.parse(back))?["_format"]?.string == format else {
            throw StoreError(message: "打出来的包自检没过，请重试")
        }
        let bytes = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.intValue ?? 0
        Diagnostics.shared.record("charpack-export", ["messages": g.n("messages"), "media": written, "history": history])
        return Built(file: out, bytes: bytes, media: written)
    }

    // MARK: - 读包

    struct Pack {
        var data: [String: JSONValue]
        var zip: ZipReader
        var name: String
        var exists: Bool
        var history: Bool
        func n(_ k: String) -> Int { data[k]?.array?.count ?? 0 }
        var extras: Int { CharPack.extraKinds.reduce(0) { $0 + n($1) } }
    }

    /// 读一个包出来先看看，**不动库**。界面照着它写确认，确认了再 install
    static func read(_ url: URL) throws -> Pack {
        let raw = try Data(contentsOf: url, options: .mappedIfSafe)
        guard ZipReader.looksLikeZip(raw) else { throw StoreError(message: "这不是一个角色包") }
        let zip = try ZipReader(data: raw)
        guard let e = zip.entry(named: "character.json"), let body = zip.contents(of: e) else {
            let names = zip.names.prefix(5).joined(separator: "、")
            throw StoreError(message: names.isEmpty ? "这个包里一条记录都读不出来，可能不是角色包"
                : "这个包里没有 character.json。里面是：\(names)\(zip.names.count > 5 ? " 等" : "")")
        }
        guard let data = try? JSONValue.parse(body).object else { throw StoreError(message: "character.json 读不出来，包可能已损坏") }
        guard data["_format"]?.string == format else { throw StoreError(message: "这不是一个角色包") }
        guard let main = data["character"]?.object, let id = main["id"]?.string, !id.isEmpty else { throw StoreError(message: "这个包里没有角色") }
        let name = main["name"]?.string ?? ""
        return Pack(data: data, zip: zip, name: name.isEmpty ? "未命名" : name, exists: has(Collections.characters, id),
                    history: data["_history"]?.bool ?? false)
    }

    // MARK: - 装回去

    struct Installed: Equatable { var charId: String; var copied: Bool; var chats: Int; var messages: Int; var memories: Int; var media: Int; var dropped: Int }

    private static func rows(_ v: JSONValue?) -> [[String: JSONValue]] { (v?.array ?? []).compactMap(\.object) }
    private static func put(_ c: String, _ f: [String: JSONValue]) throws { try db.put(c, Row(fields: f)) }

    @discardableResult
    static func install(_ pack: Pack) throws -> Installed {
        let data = pack.data
        let me = try People.ensureActivePersona().id

        // 图片与音频先放回去，已经有的跳过。内容本身是 ZIP 的不存（网页版 4.273）
        var mediaCount = 0
        let re = try NSRegularExpression(pattern: #"^(images|files)/([^./]+)(?:\.([^/]*))?$"#)
        for e in pack.zip.entries {
            let ns = e.name as NSString
            guard let m = re.firstMatch(in: e.name, range: NSRange(location: 0, length: ns.length)) else { continue }
            let kind: MediaKind = ns.substring(with: m.range(at: 1)) == "images" ? .images : .files
            let id = ns.substring(with: m.range(at: 2))
            let ext = m.range(at: 3).location != NSNotFound && m.range(at: 3).length > 0 ? ns.substring(with: m.range(at: 3)) : "bin"
            guard MediaStore.url(kind, id: id) == nil, let bytes = pack.zip.contents(of: e) else { continue }
            if bytes.count >= 4 && bytes.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]) { continue }
            let dir = AppPaths.media.appendingPathComponent(kind.rawValue, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try bytes.write(to: dir.appendingPathComponent("\(id).\(ext)"), options: .atomic)
            } catch { throw StoreError(message: "写入图片或文件失败（\(id)）：\(error.localizedDescription)") }
            try db.registerMedia(kind: kind.rawValue, id: id, ext: ext, bytes: bytes.count)
            mediaCount += 1
        }

        // 世界书：本机已经有同一个 id 就用本机那本，不覆盖
        for b in rows(data["lorebooks"]) { if let id = b["id"]?.string, !id.isEmpty, !has(Collections.lorebooks, id) { try put(Collections.lorebooks, b) } }

        // 角色。撞了就整包换一套 id，另建一个副本
        let cast = ([data["character"]?.object].compactMap { $0 } + rows(data["alts"])).filter { !($0["id"]?.string ?? "").isEmpty }
        let copied = cast.contains { has(Collections.characters, $0["id"]!.string!) }
        var idMap: [String: String] = [:]
        for c in cast { let id = c["id"]!.string!; idMap[id] = copied ? Ids.make("char") : id }
        func remap(_ id: String) -> String { idMap[id] ?? id }
        func who(_ id: String) -> String { id == "me" || id.isEmpty ? id : remap(id) }
        func whoV(_ v: JSONValue?) -> JSONValue { v?.string.map { .string(who($0)) } ?? (v ?? .null) }
        for c in cast {
            var row = c
            row["id"] = .string(remap(c["id"]!.string!))
            if let p = c["parentId"]?.string, !p.isEmpty { row["parentId"] = .string(remap(p)) }
            // 指向包外角色的关系留着不动：读的时候本来就会滤掉找不到的那些
            if let rels = c["relations"]?.array {
                row["relations"] = .array(rels.map { r in
                    guard var o = r.object, let cid = o["charId"]?.string else { return r }
                    o["charId"] = .string(remap(cid)); return .object(o)
                })
            }
            // 内置卡片那本不在库里，照样留着
            row["lorebookIds"] = .array(ids(c["lorebookIds"]).filter { has(Collections.lorebooks, $0) || $0 == HtmlCard.builtinBookId }.map { .string($0) })
            if copied {
                let n = c["name"]?.string ?? ""
                row["name"] = .string("\(n.isEmpty ? "未命名" : n)（副本）")
                // 导进来的副本是一个新角色，不带原来那位的封存
                row["archived"] = .number(0)
            }
            try put(Collections.characters, row)
        }

        func fresh(_ map: inout [String: String], _ col: String, _ id: String, _ prefix: String) -> String {
            let n = (copied || has(col, id)) ? Ids.make(prefix) : id
            map[id] = n
            return n
        }
        func newId(_ col: String, _ id: String, _ prefix: String) -> String { (copied || has(col, id)) ? Ids.make(prefix) : id }
        let mine = Set(idMap.keys)

        // 美化：id 撞了用本机那一份，不覆盖
        var skinMap: [String: String] = [:]
        for k in rows(data["skins"]) {
            guard let id = k["id"]?.string, !id.isEmpty else { continue }
            if !has("skins", id) { try put("skins", k) }
            skinMap[id] = id
        }

        // 会话与消息
        var chatMap: [String: String] = [:]
        for c in rows(data["chats"]) {
            let id = fresh(&chatMap, Collections.chats, c["id"]?.string ?? "", "chat")
            var o = c
            o["id"] = .string(id); o["personaId"] = .string(me)
            o["characterIds"] = .array(ids(c["characterIds"]).map { .string(remap($0)) })
            let sk = c["skinId"]?.string ?? ""
            o["skinId"] = .string(sk.isEmpty ? "" : (skinMap[sk] ?? ""))
            try put(Collections.chats, o)
        }
        for t in rows(data["smsThreads"]) {
            let id = fresh(&chatMap, "smsThreads", t["id"]?.string ?? "", "sms")
            let cid = remap(t["charId"]?.string ?? "")
            var o = t
            o["id"] = .string(id); o["personaId"] = .string(me); o["charId"] = .string(cid)
            o["characterIds"] = .array(cid.isEmpty ? [] : [.string(cid)])
            let via = t["via"]?.string ?? ""
            o["via"] = .string(via.isEmpty ? "" : remap(via))
            o["memoryUpTo"] = .null; o["memoryTriedId"] = .null
            try put("smsThreads", o)
        }
        var msgMap: [String: String] = [:]
        var msgCount = 0
        for m in rows(data["messages"]) {
            guard let chatId = chatMap[m["chatId"]?.string ?? ""] else { continue }   // 会话没带进来的消息不要
            var o = m
            o["id"] = .string(fresh(&msgMap, Collections.messages, m["id"]?.string ?? "", "msg"))
            o["chatId"] = .string(chatId)
            if let a = m["authorId"] { o["authorId"] = whoV(a) }
            try put(Collections.messages, o)
            msgCount += 1
        }

        // 记忆：一律归到当前账号名下
        var memIds: [String: String] = [:]
        for m in rows(data["memories"]) {
            let old = m["id"]?.string ?? ""
            let id = newId(Collections.memories, old, "mem")
            memIds[old] = id
            var o = m
            o["id"] = .string(id); o["charId"] = .string(remap(m["charId"]?.string ?? "")); o["personaId"] = .string(me)
            try put(Collections.memories, o)
        }

        // ---- 挂在会话上的那几域 ----
        var proseMap: [String: String] = [:]
        for sc in rows(data["scenes"]) {
            guard let chatId = chatMap[sc["chatId"]?.string ?? ""] else { continue }
            var o = sc
            o["id"] = .string(fresh(&proseMap, "scenes", sc["id"]?.string ?? "", "sc"))
            o["chatId"] = .string(chatId)
            o["castIds"] = .array(ids(sc["castIds"]).map { .string(remap($0)) })
            try put("scenes", o)
        }
        var workMap: [String: String] = [:]
        for w in rows(data["works"]) {
            let wc = w["chatId"]?.string ?? ""
            let chatId = wc.isEmpty ? "" : chatMap[wc]
            guard let chatId else { continue }
            var o = w
            o["id"] = .string(fresh(&workMap, "works", w["id"]?.string ?? "", "wk"))
            o["chatId"] = .string(chatId)
            o["castIds"] = .array(ids(w["castIds"]).map { .string(remap($0)) })
            try put("works", o)
        }
        for c in rows(data["chapters"]) {
            guard let workId = workMap[c["workId"]?.string ?? ""] else { continue }
            var o = c
            o["id"] = .string(fresh(&proseMap, "chapters", c["id"]?.string ?? "", "cp"))
            o["workId"] = .string(workId)
            try put("chapters", o)
        }
        var beatMap: [String: String] = [:]
        for b in rows(data["beats"]) {
            guard let owner = proseMap[b["sceneId"]?.string ?? ""] else { continue }
            var o = b
            o["id"] = .string(fresh(&beatMap, "beats", b["id"]?.string ?? "", "bt"))
            o["sceneId"] = .string(owner)
            if let a = b["authorId"] { o["authorId"] = whoV(a) }
            try put("beats", o)
        }
        // 「已总结到这儿」的水位线指着消息与正文的 id：换了 id 跟着换；包里找不到的原样留着
        for c in rows(data["chats"]) {
            guard let id = chatMap[c["id"]?.string ?? ""], var row = try db.get(Collections.chats, id: id) else { continue }
            func mark(_ map: [String: String], _ v: JSONValue?) -> JSONValue {
                guard let s = v?.string, !s.isEmpty else { return v ?? .null }
                return .string(map[s] ?? s)
            }
            row["memoryUpTo"] = mark(msgMap, c["memoryUpTo"])
            row["memoryUpToBeat"] = mark(beatMap, c["memoryUpToBeat"])
            if let t = c["memoryTriedId"]?.string, !t.isEmpty { row["memoryTriedId"] = .string(msgMap[t] ?? beatMap[t] ?? t) }
            else { row["memoryTriedId"] = c["memoryTriedId"] ?? .null }
            row["wishTriedId"] = mark(msgMap, c["wishTriedId"])
            row.touch()
            try db.put(Collections.chats, row)
        }
        for (col, prefix) in [("trips", "tr"), ("spaceItems", "si"), ("drafts", "df")] {
            for x in rows(data[col]) {
                guard let chatId = chatMap[x["chatId"]?.string ?? ""] else { continue }
                var o = x
                o["id"] = .string(newId(col, x["id"]?.string ?? "", prefix))
                o["chatId"] = .string(chatId)
                if col == "drafts" { o["charId"] = .string(remap(x["charId"]?.string ?? "")) }
                try put(col, o)
            }
        }

        // ---- 挂在角色上的那几域 ----
        func byChar(_ col: String, _ prefix: String, _ key: String) throws {
            for r in rows(data[col]) {
                guard mine.contains(r[key]?.string ?? "") else { continue }
                var o = r
                o["id"] = .string(newId(col, r["id"]?.string ?? "", prefix))
                o[key] = .string(remap(r[key]!.string!))
                try put(col, o)
            }
        }
        try byChar("days", "day", "charId")
        try byChar("meals", "ml", "charId")
        try byChar("health", "hl", "who")
        try byChar("phones", "ph", "charId")
        // 衣帽间：单品先放，记下新旧 id；套装后放，里面的单品 id 换成新的
        var clIds: [String: String] = [:]
        let clRows = rows(data["closet"]).filter { mine.contains($0["owner"]?.string ?? "") }
        for r in clRows where r["side"]?.string != "outfit" {
            var o = r
            o["id"] = .string(fresh(&clIds, "closet", r["id"]?.string ?? "", "cl"))
            o["owner"] = .string(remap(r["owner"]!.string!))
            try put("closet", o)
        }
        for r in clRows where r["side"]?.string == "outfit" {
            var o = r
            o["id"] = .string(newId("closet", r["id"]?.string ?? "", "cl"))
            o["owner"] = .string(remap(r["owner"]!.string!))
            o["items"] = .array(ids(r["items"]).compactMap { clIds[$0] }.map { .string($0) })
            try put("closet", o)
        }
        // 收藏馆：组成的 parentId 换成新 id；提醒待办不带
        var cxIds: [String: String] = [:]
        let cxRows = rows(data["collection"]).filter { mine.contains($0["owner"]?.string ?? "") }
        for r in cxRows { let id = r["id"]?.string ?? ""; cxIds[id] = newId("collection", id, "cx") }
        for r in cxRows {
            var o = r
            o["id"] = .string(cxIds[r["id"]?.string ?? ""] ?? "")
            o["owner"] = .string(remap(r["owner"]!.string!))
            let p = r["parentId"]?.string ?? ""
            o["parentId"] = .string(p.isEmpty ? "" : (cxIds[p] ?? ""))
            o["todoIds"] = .object([:])
            try put("collection", o)
        }
        // 商城身份与商品。身份换 id 时，商品的卖家跟着换
        var mpIds: [String: String] = [:]
        for p in rows(data["mallPeople"]) where p["kind"]?.string == "char" && mine.contains(p["charId"]?.string ?? "") {
            var o = p
            o["id"] = .string(fresh(&mpIds, "mallPeople", p["id"]?.string ?? "", "mp"))
            o["charId"] = .string(remap(p["charId"]!.string!))
            try put("mallPeople", o)
        }
        for it in rows(data["mallItems"]) {
            guard let seller = mpIds[it["sellerId"]?.string ?? ""] else { continue }
            var o = it
            o["id"] = .string(newId("mallItems", it["id"]?.string ?? "", "mi"))
            o["sellerId"] = .string(seller); o["fav"] = .bool(false)
            try put("mallItems", o)
        }
        for r in rows(data["phoneChats"]) where mine.contains(r["charId"]?.string ?? "") {
            var o = r
            o["id"] = .string(newId("phoneChats", r["id"]?.string ?? "", "pc"))
            o["charId"] = .string(remap(r["charId"]!.string!))
            let npc = r["npcId"]?.string ?? ""
            o["npcId"] = .string(npc.isEmpty ? "" : remap(npc))
            try put("phoneChats", o)
        }
        for r in rows(data["moments"]) where mine.contains(r["authorId"]?.string ?? "") {
            var o = r
            o["id"] = .string(newId("moments", r["id"]?.string ?? "", "mo"))
            o["authorId"] = .string(remap(r["authorId"]!.string!))
            o["likes"] = .array((r["likes"]?.array ?? []).map { whoV($0) })
            o["comments"] = .array((r["comments"]?.array ?? []).map { c in
                guard var x = c.object else { return c }
                x["authorId"] = whoV(x["authorId"]); return .object(x)
            })
            try put("moments", o)
        }
        // 影评书评与段评指着本机的书或片子：对方没有那一本时这几条落不下去，报个数
        var dropped = 0
        func hasSubject(_ kind: String, _ id: String) -> Bool { kind == "video" ? has("videos", id) : has("ebooks", id) }
        for r in rows(data["reviews"]) where mine.contains(r["charId"]?.string ?? "") {
            guard hasSubject(r["kind"]?.string ?? "", r["subjectId"]?.string ?? "") else { dropped += 1; continue }
            var o = r
            o["id"] = .string(newId("reviews", r["id"]?.string ?? "", "rev"))
            o["charId"] = .string(remap(r["charId"]!.string!))
            try put("reviews", o)
        }
        for r in rows(data["readnotes"]) where mine.contains(r["authorId"]?.string ?? "") {
            let book = r["bookId"]?.string ?? ""
            guard hasSubject(book.isEmpty ? "video" : "book", book.isEmpty ? (r["videoId"]?.string ?? "") : book) else { dropped += 1; continue }
            var o = r
            o["id"] = .string(newId("readnotes", r["id"]?.string ?? "", "rn"))
            o["authorId"] = .string(remap(r["authorId"]!.string!))
            try put("readnotes", o)
        }
        for t in rows(data["todos"]) where mine.contains(t["charId"]?.string ?? "") {
            var o = t
            o["id"] = .string(newId("todos", t["id"]?.string ?? "", "td"))
            o["charId"] = .string(remap(t["charId"]!.string!))
            let c = t["chatId"]?.string ?? "", s = t["srcMsgId"]?.string ?? ""
            o["chatId"] = .string(c.isEmpty ? "" : (chatMap[c] ?? ""))
            o["srcMsgId"] = .string(s.isEmpty ? "" : (msgMap[s] ?? ""))
            try put("todos", o)
        }
        for w in rows(data["wishes"]) where mine.contains(w["owner"]?.string ?? "") {
            var o = w
            let owner = remap(w["owner"]!.string!)
            o["id"] = .string(newId("wishes", w["id"]?.string ?? "", "ws"))
            o["owner"] = .string(owner); o["charId"] = .string(owner); o["personaId"] = .string(me)
            let c = w["chatId"]?.string ?? ""
            o["chatId"] = .string(c.isEmpty ? "" : (chatMap[c] ?? ""))
            try put("wishes", o)
        }
        try unpackSlips(data, remap: remap, me: me, copied: copied)
        for d in rows(data["diaries"]) where mine.contains(d["owner"]?.string ?? "") {
            var o = d
            let owner = remap(d["owner"]!.string!)
            o["id"] = .string(newId("diaries", d["id"]?.string ?? "", "dy"))
            o["owner"] = .string(owner); o["charId"] = .string(owner); o["personaId"] = .string(me); o["imageIds"] = .array([])
            try put("diaries", o)
        }
        // 宠物与对着它们、对着角色的摄像头和监控记录
        var petMap: [String: String] = [:]
        for p in rows(data["pets"]) where mine.contains(p["charId"]?.string ?? "") {
            var o = p
            o["id"] = .string(fresh(&petMap, "pets", p["id"]?.string ?? "", "pet"))
            o["charId"] = .string(remap(p["charId"]!.string!))
            try put("pets", o)
        }
        func camTarget(_ r: [String: JSONValue]) -> String {
            let t = r["targetId"]?.string ?? ""
            return r["kind"]?.string == "char" ? (mine.contains(t) ? remap(t) : "") : (petMap[t] ?? "")
        }
        for (col, prefix) in [("cams", "cam"), ("camLogs", "cl")] {
            for r in rows(data[col]) {
                let t = camTarget(r)
                guard !t.isEmpty else { continue }
                var o = r
                o["id"] = .string(newId(col, r["id"]?.string ?? "", prefix))
                o["targetId"] = .string(t)
                try put(col, o)
            }
        }
        for r in rows(data["quizRuns"]) where mine.contains(r["charId"]?.string ?? "") {
            var o = r
            o["id"] = .string(newId("quizRuns", r["id"]?.string ?? "", "qr"))
            o["charId"] = .string(remap(r["charId"]!.string!)); o["chatId"] = .string(""); o["msgIds"] = .array([])
            try put("quizRuns", o)
        }
        for d in rows(data["dreams"]) where mine.contains(d["charId"]?.string ?? "") {
            var o = d
            o["id"] = .string(newId("dreams", d["id"]?.string ?? "", "dm"))
            o["charId"] = .string(remap(d["charId"]!.string!)); o["personaId"] = .string(me); o["memoryId"] = .string("")
            try put("dreams", o)
        }
        // 记忆的历史版本：里面每条记忆的 id 与上面换得一致
        for x in rows(data["memsnaps"]) where mine.contains(x["charId"]?.string ?? "") {
            var o = x
            o["id"] = .string(newId("memsnaps", x["id"]?.string ?? "", "msnap"))
            o["charId"] = .string(remap(x["charId"]!.string!))
            o["memories"] = .array(rows(x["memories"]).filter { ($0["scopeChat"]?.string ?? "").isEmpty }.map { m in
                var y = m
                let old = m["id"]?.string ?? ""
                y["id"] = .string(memIds[old] ?? newId(Collections.memories, old, "mem"))
                y["charId"] = .string(remap(m["charId"]?.string ?? "")); y["personaId"] = .string(me)
                return .object(y)
            })
            try put("memsnaps", o)
        }
        for d in rows(data["dramas"]) where mine.contains(d["charId"]?.string ?? "") {
            var o = d
            o["id"] = .string(newId("dramas", d["id"]?.string ?? "", "dra"))
            o["charId"] = .string(remap(d["charId"]!.string!)); o["personaId"] = .string(me)
            try put("dramas", o)
        }
        // 角色眼中的你：依据指着的消息与会话换成这边的 id，没带进来的留着原话、不能跳转
        for x in rows(data["impressions"]) where mine.contains(x["charId"]?.string ?? "") && ["imp", "note"].contains(x["kind"]?.string ?? "") {
            var o = x
            o["id"] = .string(newId("impressions", x["id"]?.string ?? "", "imp"))
            o["charId"] = .string(remap(x["charId"]!.string!)); o["personaId"] = .string(me)
            func ev(_ v: JSONValue?) -> JSONValue {
                .array(rows(v).map { e in
                    var y = e
                    y["msgId"] = .string(msgMap[e["msgId"]?.string ?? ""] ?? "")
                    y["chatId"] = .string(chatMap[e["chatId"]?.string ?? ""] ?? "")
                    return .object(y)
                })
            }
            o["evidence"] = ev(x["evidence"]); o["against"] = ev(x["against"])
            try put("impressions", o)
        }
        for t in rows(data["ties"]) {
            let from = t["from"]?.string ?? "", to = t["to"]?.string ?? ""
            guard mine.contains(from) || mine.contains(to) else { continue }
            var o = t
            o["id"] = .string(newId(Ties.collection, t["id"]?.string ?? "", "ti"))
            o["from"] = .string(from == "me" ? "me" : remap(from)); o["to"] = .string(to == "me" ? "me" : remap(to))
            o["personaId"] = .string(me); o["hist"] = .array([])
            try put(Ties.collection, o)
        }
        // 曲库里的歌按 id 认：本机已经有同一首就用本机那一行
        for x in rows(data["songs"]) { if let id = x["id"]?.string, !id.isEmpty, !has("songs", id) { try put("songs", x) } }
        for p in rows(data["playlists"]) where mine.contains(p["owner"]?.string ?? "") {
            var o = p
            o["id"] = .string(newId("playlists", p["id"]?.string ?? "", "pl"))
            o["owner"] = .string(remap(p["owner"]!.string!))
            o["trackIds"] = .array(ids(p["trackIds"]).filter { has("songs", $0) }.map { .string($0) })
            try put("playlists", o)
        }

        let mainId = remap(data["character"]?["id"]?.string ?? "")
        Diagnostics.shared.record("charpack-import", ["copied": copied, "messages": msgCount, "media": mediaCount, "dropped": dropped])
        return Installed(charId: mainId, copied: copied, chats: rows(data["chats"]).count, messages: rows(data["messages"]).count,
                         memories: rows(data["memories"]).count, media: mediaCount, dropped: dropped)
    }

    /// 密语（网页版 slip.unpack）：盒子的 id 由角色与身份算出，按这边的角色 id 与当前身份重算
    private static func unpackSlips(_ data: [String: JSONValue], remap: (String) -> String, me: String, copied: Bool) throws {
        var boxMap: [String: String] = [:]
        for b in rows(data["boxes"]) {
            let kind = b["kind"]?.string ?? ""
            guard kind == "own" || kind == "private" else { continue }
            let owner = remap(b["owner"]?.string ?? "")
            guard has(Collections.characters, owner) else { continue }
            let id = kind == "own" ? "bx~own~\(owner)~\(me)" : "bx~prv~\(owner)~\(me)"
            boxMap[b["id"]?.string ?? ""] = id
            if !has("boxes", id) {
                var o = b
                o["id"] = .string(id); o["owner"] = .string(owner); o["members"] = .array([.string(owner)]); o["personaId"] = .string(me)
                try put("boxes", o)
            }
        }
        let list = rows(data["slips"]).filter { boxMap[$0["boxId"]?.string ?? ""] != nil }
        var slipMap: [String: String] = [:]
        for s in list { let id = s["id"]?.string ?? ""; slipMap[id] = (copied || has("slips", id)) ? Ids.make("sp") : id }
        func keep(_ w: String) -> Bool { w == "me" || has(Collections.characters, w) }
        for s in list {
            var o = s
            let to = s["to"]?.object
            let tids = ids(to?["ids"]).map(remap).filter(keep)
            o["id"] = .string(slipMap[s["id"]?.string ?? ""] ?? "")
            o["boxId"] = .string(boxMap[s["boxId"]?.string ?? ""] ?? "")
            o["author"] = .string(remap(s["author"]?.string ?? ""))
            o["personaId"] = .string(me)
            if to?["kind"]?.string == "chars" && tids.isEmpty {
                o["to"] = .object(["kind": .string("none"), "ids": .array([])])
            } else {
                var t = to ?? ["kind": .string("none")]
                t["ids"] = .array(tids.map { .string($0) })
                o["to"] = .object(t)
            }
            var knows: [String] = []
            for k in ids(s["knows"]).map(remap) where keep(k) && !knows.contains(k) { knows.append(k) }
            o["knows"] = .array(knows.map { .string($0) })
            o["replyTo"] = .string(slipMap[s["replyTo"]?.string ?? ""] ?? "")
            try put("slips", o)
        }
        for r in rows(data["slipLog"]) {
            guard let sid = slipMap[r["slipId"]?.string ?? ""] else { continue }
            var o = r
            o["id"] = .string(Ids.make("sl")); o["slipId"] = .string(sid)
            o["boxId"] = .string(boxMap[r["boxId"]?.string ?? ""] ?? "")
            let by = r["by"]?.string ?? ""
            o["by"] = .string(by.isEmpty ? "" : remap(by)); o["personaId"] = .string(me)
            try put("slipLog", o)
        }
    }
}
