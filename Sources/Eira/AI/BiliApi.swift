import Foundation

/// B 站（网页版 system/bili.js，ARCHITECTURE 4.883 至 4.887）：扫码登录、搜索、贴链接、播放地址、字幕（CC 与 AI 字幕，后者要登录），
/// 以及自己的最近观看、稍后再看、收藏夹。
///
/// 网页版在浏览器里要经转发服务；装成 App 时从手机直接发（4.886）。原生版就是从手机直接发：不经任何服务器，
/// 登录凭据只在手机与 B 站之间。接的是 B 站网页版自己用的那几个地址，B 站改了要跟着改：每一步失败都把原因原样说出来。
/// cookie 就是账号权限，只存在这台设备上（settings.services.bili，与网页版同一处）。播放地址会过期（约两小时），不存，开播时现取。
/// 这里没有一个请求是模型接口，不进 AIService，也不计接口调用次数。
enum BiliApi {
    static let api = "https://api.bilibili.com"
    static let passport = "https://passport.bilibili.com"
    static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    /// 视频服务器查来源页：播放时带上这两个
    static let playHeaders = ["Referer": "https://www.bilibili.com/", "User-Agent": ua]

    /// 不让系统替我们存、替我们带 cookie。测试里换成接住请求的那一个
    nonisolated(unsafe) static var session: URLSession = makeSession()

    static func makeSession(protocols: [AnyClass] = []) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        if !protocols.isEmpty { c.protocolClasses = protocols }
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }

    // MARK: - 设置

    static func config(_ s: AppSettings = .load()) -> [String: JSONValue] { s.raw["services"]?["bili"]?.object ?? [:] }

    static func patch(_ p: [String: JSONValue]) throws {
        var s = try AppSettings.loadForWrite()
        var all = s.raw["services"]?.object ?? [:]
        var b = all["bili"]?.object ?? [:]
        for (k, v) in p { b[k] = v }
        all["bili"] = .object(b)
        s.raw["services"] = .object(all)
        try s.save()
    }

    static func loggedIn(_ s: AppSettings = .load()) -> Bool { !(config(s)["cookie"]?.string ?? "").isEmpty }
    static func nick(_ s: AppSettings = .load()) -> String { config(s)["nick"]?.string ?? "" }

    static func logout() throws {
        try patch(["cookie": .string(""), "nick": .string(""), "mid": .string(""),
                   "wbi": .object(["img": .string(""), "sub": .string(""), "at": .number(0)])])
    }

    // MARK: - 请求

    /// 几行 Set-Cookie 被接成了一行：按「逗号后面紧跟着 名字=」切开；Expires 里的逗号后面是空格加日期，不会被切
    static func splitCookies(_ raw: String) -> [String] {
        Subtitle.split(raw, Subtitle.rx(#",\s*(?=[A-Za-z0-9_\-]+=)"#)).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    struct Reply {
        var status: Int
        var body: Data
        var cookies: [String]
        /// 跟着跳转走完之后的地址
        var finalURL: String
        var text: String { String(data: body, encoding: .utf8) ?? "" }
    }

    static func fetch(_ url: String, cookie: String = "") async throws -> Reply {
        guard let u = URL(string: url) else { throw StoreError(message: "B 站的地址无法识别") }
        var req = URLRequest(url: u)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw StoreError(message: "连不上 B 站（\(error.localizedDescription)）。请检查网络后重试") }
        let h = resp as? HTTPURLResponse
        return Reply(status: h?.statusCode ?? 0, body: data, cookies: splitCookies(h?.value(forHTTPHeaderField: "Set-Cookie") ?? ""),
                     finalURL: resp.url?.absoluteString ?? url)
    }

    /// 这一次要带的 cookie：登录了的那一份，再补上设备号 buvid3（不登录也要有，否则搜索回 412）
    static func cookieOf(_ s: AppSettings = .load()) -> String {
        let c = config(s)
        var parts = (c["cookie"]?.string ?? "").components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let b3 = c["buvid3"]?.string, !b3.isEmpty, !parts.contains(where: { $0.hasPrefix("buvid3=") }) { parts.append("buvid3=\(b3)") }
        return parts.joined(separator: "; ")
    }

    static func getJSON(_ url: String, cookie: Bool = true) async throws -> (body: JSONValue, cookies: [String]) {
        let r = try await fetch(url, cookie: cookie ? cookieOf() : "")
        if r.status == 412 { throw StoreError(message: "B 站拒绝了这台设备的请求（412，触发了风控）。请稍后再试，或换一个网络后再试") }
        guard let body = try? JSONValue.parse(r.body), body.object != nil else {
            throw StoreError(message: "B 站返回的内容无法识别（\(r.status)）")
        }
        return (body, r.cookies)
    }

    /// B 站自己的 code 不是 0 就报它给的原因
    static func must(_ body: JSONValue, _ what: String) throws -> JSONValue {
        let code = body["code"]?.number ?? -1
        guard code == 0 else {
            let msg = body["message"]?.string ?? body["msg"]?.string ?? "B 站返回 \(Int(code))"
            throw StoreError(message: "\(what)失败：\(msg)")
        }
        return body["data"] ?? .null
    }

    /// 不登录也要带的设备号。第一次用时取一次，存着
    static func ensureBuvid() async {
        guard (config()["buvid3"]?.string ?? "").isEmpty else { return }
        if let r = try? await getJSON("\(api)/x/frontend/finger/spi", cookie: false), let b3 = r.body["data"]?["b_3"]?.string, !b3.isEmpty {
            try? patch(["buvid3": .string(b3)])
        }
    }

    // MARK: - wbi 签名（网页版 signQuery）

    static let mixin = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
                        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52]
    static let wbiTTL: Double = 6 * 3600 * 1000

    static func keyOf(_ url: String) -> String {
        (url.components(separatedBy: "/").last ?? "").components(separatedBy: ".").first ?? ""
    }

    /// 原始密钥按固定的表重排，取前 32 位（有意截断：签名算法本来就只取这么多）
    static func mixinOf(img: String, sub: String) -> String {
        let raw = Array(img + sub)
        return String(mixin.compactMap { raw.indices.contains($0) ? raw[$0] : nil }.prefix(32))
    }

    /// nav 一次：登录状态与 wbi 密钥都在里面
    @discardableResult
    static func nav() async throws -> JSONValue {
        let r = try await getJSON("\(api)/x/web-interface/nav")
        let d = r.body["data"] ?? .null
        let img = keyOf(d["wbi_img"]?["img_url"]?.string ?? "")
        let sub = keyOf(d["wbi_img"]?["sub_url"]?.string ?? "")
        if !img.isEmpty && !sub.isEmpty {
            try? patch(["wbi": .object(["img": .string(img), "sub": .string(sub), "at": .number(Date().millis)])])
        }
        return d
    }

    static func mixinKey() async throws -> String {
        func cur() -> (String, String, Double) {
            let w = config()["wbi"]
            return (w?["img"]?.string ?? "", w?["sub"]?.string ?? "", w?["at"]?.number ?? 0)
        }
        var (img, sub, at) = cur()
        if img.isEmpty || sub.isEmpty || Date().millis - at > wbiTTL {
            try await nav()
            (img, sub, at) = cur()
        }
        guard !img.isEmpty, !sub.isEmpty else { throw StoreError(message: "没有取到 B 站的签名密钥") }
        return mixinOf(img: img, sub: sub)
    }

    /// encodeURIComponent 不编码的那几个
    private static let uriSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: uriSafe) ?? s }

    /// 给一组参数签名，回查询串。now 只给测试用
    static func signQuery(_ params: [String: String], mixin key: String, now: Double = Date().millis) -> String {
        var all = params
        all["wts"] = String(Int((now / 1000).rounded(.down)))
        let q = all.keys.sorted().map { k in
            let v = (all[k] ?? "").replacingOccurrences(of: #"[!'()*]"#, with: "", options: .regularExpression)
            return "\(encode(k))=\(encode(v))"
        }.joined(separator: "&")
        return "\(q)&w_rid=\(NeCrypto.md5Hex(q + key))"
    }

    static func wbiGet(_ path: String, _ params: [String: String]) async throws -> JSONValue {
        await ensureBuvid()
        let q = signQuery(params, mixin: try await mixinKey())
        return try await getJSON("\(api)\(path)?\(q)").body
    }

    // MARK: - 扫码登录（码同网页版 qrlogin：800 过期、801 等待、802 已扫、803 成功）

    static func qrStart() async throws -> (key: String, url: String) {
        await ensureBuvid()
        let d = try must(try await getJSON("\(passport)/x/passport-login/web/qrcode/generate").body, "获取二维码")
        guard let url = d["url"]?.string, let key = d["qrcode_key"]?.string, !url.isEmpty, !key.isEmpty else {
            throw StoreError(message: "没有拿到 B 站的二维码")
        }
        return (key, url)
    }

    /// 把 Set-Cookie 与跳转地址里的几样凭据收成一行 cookie
    static func cookieFrom(_ cookies: [String], url: String) -> String {
        var order: [String] = []
        var got: [String: String] = [:]
        func put(_ k: String, _ v: String) { if got[k] == nil { order.append(k) }; got[k] = v }
        let r = Subtitle.rx(#"^\s*([^=;\s]+)=([^;]*)"#)
        for c in cookies {
            if let m = Subtitle.groups(r, c), let k = m[1] { put(k, m[2] ?? "") }
        }
        if let items = URLComponents(string: url)?.queryItems {
            for k in ["DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct"] where got[k] == nil {
                if let v = items.first(where: { $0.name == k })?.value { put(k, v) }
            }
        }
        return order.map { "\($0)=\(got[$0] ?? "")" }.joined(separator: "; ")
    }

    static func qrCheck(_ key: String) async throws -> (code: Int, cookie: String) {
        let r = try await getJSON("\(passport)/x/passport-login/web/qrcode/poll?qrcode_key=\(encode(key))", cookie: false)
        let d = try must(r.body, "查询扫码状态")
        switch Int(d["code"]?.number ?? -1) {
        case 86038: return (800, "")
        case 86101: return (801, "")
        case 86090: return (802, "")
        case 0:
            let c = cookieFrom(r.cookies, url: d["url"]?.string ?? "")
            guard c.contains("SESSDATA=") else { throw StoreError(message: "扫码成功，但没有拿到登录凭据") }
            return (803, c)
        default:
            throw StoreError(message: d["message"]?.string ?? "扫码状态无法识别（\(Int(d["code"]?.number ?? -1))）")
        }
    }

    /// 存下登录凭据，再问一次 nav 拿昵称（顺带换一份 wbi 密钥）
    @discardableResult
    static func saveLogin(_ cookie: String) async throws -> String {
        try patch(["cookie": .string(cookie), "wbi": .object(["img": .string(""), "sub": .string(""), "at": .number(0)])])
        if let d = try? await nav(), d["isLogin"]?.bool == true {
            let mid: String = d["mid"]?.number.map { String(Int($0)) } ?? d["mid"]?.string ?? ""
            try? patch(["nick": .string(d["uname"]?.string ?? ""), "mid": .string(mid)])
        }
        let n = nick()
        return n.isEmpty ? "哔哩哔哩账号" : n
    }

    // MARK: - 找片

    struct Hit: Identifiable, Equatable {
        var id: String { bvid }
        var bvid: String
        var title: String
        var author: String
        var seconds: Double
        var cover: String
        var plays: Double = 0
        var progress: Double = 0
        var part: String = ""
    }

    static func plain(_ t: String) -> String {
        Subtitle.replace(t, Subtitle.rx(#"<[^>]+>"#), "").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func https(_ u: String) -> String {
        if u.hasPrefix("//") { return "https:" + u }
        return u.hasPrefix("http:") ? "https:" + u.dropFirst(5) : u
    }

    /// 「12:34」「1:02:03」换成秒
    static func secOf(_ v: JSONValue?) -> Double {
        if let n = v?.number { return n }
        return (v?.string ?? "").components(separatedBy: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    static func search(_ keyword: String, page: Int = 1) async throws -> [Hit] {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return [] }
        let d = try must(try await wbiGet("/x/web-interface/wbi/search/type", ["search_type": "video", "keyword": k, "page": "\(page)"]), "搜索")
        return (d["result"]?.array ?? []).compactMap { x in
            guard let bv = x["bvid"]?.string, !bv.isEmpty else { return nil }
            return Hit(bvid: bv, title: plain(x["title"]?.string ?? ""), author: plain(x["author"]?.string ?? ""), seconds: secOf(x["duration"]),
                       cover: https(x["pic"]?.string ?? ""), plays: x["play"]?.number ?? Double(x["play"]?.string ?? "") ?? 0)
        }
    }

    /// 文字里直接写着的 BV 号
    static func bvidIn(_ text: String) -> String? {
        guard let r = text.range(of: #"BV[0-9A-Za-z]{10}"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    /// 从链接或文字里认出 BV 号。b23.tv 短链接跟着跳一次，从落地地址或页面里认。认不出给空串
    static func bvidOf(_ text: String) async throws -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = bvidIn(t) { return hit }
        guard let r = t.range(of: #"https?://b23\.tv/[0-9A-Za-z]+"#, options: [.regularExpression, .caseInsensitive]) else { return "" }
        let short = String(t[r]).replacingOccurrences(of: "http://", with: "https://", options: [.caseInsensitive, .anchored])
        let got = try await fetch(short)
        if let m = bvidIn(got.finalURL) { return m }
        let page = got.text
        if let og = Subtitle.groups(Subtitle.rx(#"property="og:url"[^>]*content="[^"]*?(BV[0-9A-Za-z]{10})"#), page)?[1] { return og }
        if let m = bvidIn(page) { return m }
        throw StoreError(message: "这个短链接没有指向 B 站视频")
    }

    struct Info: Equatable {
        struct Page: Equatable { var cid: Double; var part: String; var seconds: Double }
        var bvid: String
        var title: String
        var author: String
        var cover: String
        var pages: [Page]
    }

    static func view(_ bvid: String) async throws -> Info {
        let d = try must(try await getJSON("\(api)/x/web-interface/view?bvid=\(encode(bvid))").body, "读取视频信息")
        let pages = (d["pages"]?.array ?? []).map { Info.Page(cid: $0["cid"]?.number ?? 0, part: $0["part"]?.string ?? "", seconds: $0["duration"]?.number ?? 0) }
        return Info(bvid: d["bvid"]?.string ?? bvid, title: plain(d["title"]?.string ?? ""), author: plain(d["owner"]?["name"]?.string ?? ""),
                    cover: https(d["pic"]?.string ?? ""),
                    pages: pages.isEmpty ? [Info.Page(cid: d["cid"]?.number ?? 0, part: "", seconds: d["duration"]?.number ?? 0)] : pages)
    }

    // 视频服务器（4.887）：海外镜像查来源页，换成国内镜像排在前面，原样的放最后作退路
    static let cnMirror = "upos-sz-mirrorcos.bilivideo.com"
    static func oversea(_ host: String) -> Bool {
        host.range(of: #"akamaized\.net$|mirrorakam|mirroraliov|mirrorcosov|mirrorhw(?:ov)?\.bilivideo\.com$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func rankUrls(_ list: [String]) -> [String] {
        func uniq(_ a: [String]) -> [String] { var seen = Set<String>(); return a.filter { seen.insert($0).inserted } }
        let urls = uniq(list.filter { !$0.isEmpty }.map(https))
        let host = { (u: String) in URLComponents(string: u)?.host ?? "" }
        let cn = urls.filter { !oversea(host($0)) }
        let ov = urls.filter { oversea(host($0)) }
        let swapped = ov.compactMap { u -> String? in
            guard var c = URLComponents(string: u) else { return nil }
            c.host = cnMirror
            return c.string
        }
        return uniq(cn + swapped + ov)
    }

    /// 播放地址：一整段 MP4（platform=html5）。会过期，不存；回排好序的几个候选，放不了一个换下一个
    static func playUrls(_ bvid: String, cid: Double) async throws -> [String] {
        let d = try must(try await wbiGet("/x/player/wbi/playurl", [
            "bvid": bvid, "cid": String(Int(cid)), "qn": "80", "fnval": "1", "fnver": "0", "fourk": "0", "platform": "html5", "high_quality": "1",
        ]), "取播放地址")
        let seg = d["durl"]?[0]
        let backups = (seg?["backup_url"]?.array ?? seg?["backupUrl"]?.array ?? []).compactMap(\.string)
        let list = rankUrls([seg?["url"]?.string ?? ""] + backups)
        guard !list.isEmpty else { throw StoreError(message: "B 站没有给出可以播放的地址（可能是大会员专享或有版权限制）") }
        return list
    }

    struct Track: Equatable {
        var lang: String
        var label: String
        var url: String
        var ai: Bool
    }

    static func subtitleTracks(_ bvid: String, cid: Double) async throws -> [Track] {
        let d = try must(try await wbiGet("/x/player/wbi/v2", ["bvid": bvid, "cid": String(Int(cid))]), "读取字幕")
        return (d["subtitle"]?["subtitles"]?.array ?? []).compactMap { s in
            guard let u = s["subtitle_url"]?.string, !u.isEmpty else { return nil }
            let lang = s["lan"]?.string ?? ""
            let doc = s["lan_doc"]?.string ?? ""
            return Track(lang: lang, label: doc.isEmpty ? lang : doc, url: https(u), ai: lang.hasPrefix("ai-"))
        }
    }

    /// B 站的字幕 JSON（{ body: [{ from, to, content }] }）换成 SRT，片库里存的是 SRT
    static func toSrt(_ json: JSONValue) -> String {
        Subtitle.toSrt((json["body"]?.array ?? []).map {
            Subtitle.Line(at: $0["from"]?.number ?? 0, end: $0["to"]?.number ?? 0, text: $0["content"]?.string ?? "")
        })
    }

    static func subtitleSrt(_ t: Track) async throws -> String {
        let r = try await fetch(t.url)
        guard let j = try? JSONValue.parse(r.body), j.object != nil else { throw StoreError(message: "字幕文件无法识别") }
        return toSrt(j)
    }

    /// 挑一轨：中文优先（人工的在 AI 的前面），没有就第一轨
    static func pickTrack(_ tracks: [Track]) -> Track? {
        guard !tracks.isEmpty else { return nil }
        let zh = tracks.filter { $0.lang.range(of: #"^(ai-)?zh"#, options: [.regularExpression, .caseInsensitive]) != nil }
        return zh.first { !$0.ai } ?? zh.first ?? tracks.first { !$0.ai } ?? tracks.first
    }

    // MARK: - 自己的：最近观看、稍后再看、收藏夹（都要登录，每一页是用户点了才取）

    private static func needLogin() throws { guard loggedIn() else { throw StoreError(message: "请先登录哔哩哔哩") } }

    struct Cursor: Equatable { var max: Double; var viewAt: Double }

    static func history(_ cursor: Cursor? = nil) async throws -> (items: [Hit], next: Cursor?) {
        try needLogin()
        var q = "ps=20&type=archive&business=archive"
        if let c = cursor, c.max > 0 { q += "&max=\(Int(c.max))&view_at=\(Int(c.viewAt))" }
        let d = try must(try await getJSON("\(api)/x/web-interface/history/cursor?\(q)").body, "读取最近观看")
        let items: [Hit] = (d["list"]?.array ?? []).compactMap { x in
            guard let h = x["history"], let bv = h["bvid"]?.string, !bv.isEmpty else { return nil }
            let biz = h["business"]?.string ?? ""
            guard biz.isEmpty || biz == "archive" else { return nil }
            return Hit(bvid: bv, title: plain(x["title"]?.string ?? ""), author: plain(x["author_name"]?.string ?? ""),
                       seconds: x["duration"]?.number ?? 0, cover: https(x["cover"]?.string ?? x["covers"]?[0]?.string ?? ""),
                       progress: x["progress"]?.number ?? 0, part: h["part"]?.string ?? "")
        }
        let c = d["cursor"]
        let next = !items.isEmpty && (c?["max"]?.number ?? 0) > 0 ? Cursor(max: c?["max"]?.number ?? 0, viewAt: c?["view_at"]?.number ?? 0) : nil
        return (items, next)
    }

    static func toView() async throws -> [Hit] {
        try needLogin()
        let d = try must(try await getJSON("\(api)/x/v2/history/toview").body, "读取稍后再看")
        return (d["list"]?.array ?? []).compactMap { x in
            guard let bv = x["bvid"]?.string, !bv.isEmpty else { return nil }
            return Hit(bvid: bv, title: plain(x["title"]?.string ?? ""), author: plain(x["owner"]?["name"]?.string ?? ""),
                       seconds: x["duration"]?.number ?? 0, cover: https(x["pic"]?.string ?? ""))
        }
    }

    struct Folder: Identifiable, Equatable { var id: String; var title: String; var count: Int }

    static func favFolders() async throws -> [Folder] {
        try needLogin()
        let mid = config()["mid"]?.string ?? ""
        guard !mid.isEmpty else { throw StoreError(message: "没有读到账号编号，请退出登录后重新登录") }
        let d = try must(try await getJSON("\(api)/x/v3/fav/folder/created/list-all?up_mid=\(encode(mid))&type=2").body, "读取收藏夹")
        return (d["list"]?.array ?? []).map { f in
            Folder(id: f["id"]?.number.map { String(Int($0)) } ?? f["id"]?.string ?? "", title: plain(f["title"]?.string ?? ""),
                   count: Int(f["media_count"]?.number ?? 0))
        }
    }

    /// 一个收藏夹里的视频，按页取（每页 20 个）。失效的视频（attr 不为 0）不列
    static func favItems(_ mediaId: String, page: Int = 1) async throws -> (items: [Hit], more: Bool, title: String) {
        try needLogin()
        let q = "media_id=\(encode(mediaId))&pn=\(page)&ps=20&order=mtime&type=0&tid=0&platform=web"
        let d = try must(try await getJSON("\(api)/x/v3/fav/resource/list?\(q)").body, "读取收藏夹")
        let items: [Hit] = (d["medias"]?.array ?? []).compactMap { x in
            guard let bv = x["bvid"]?.string, !bv.isEmpty, x["type"]?.number == 2, (x["attr"]?.number ?? 0) == 0 else { return nil }
            return Hit(bvid: bv, title: plain(x["title"]?.string ?? ""), author: plain(x["upper"]?["name"]?.string ?? ""),
                       seconds: x["duration"]?.number ?? 0, cover: https(x["cover"]?.string ?? ""))
        }
        return (items, d["has_more"]?.bool == true, plain(d["info"]?["title"]?.string ?? ""))
    }

    // MARK: - 加进片库

    /// 把一部 B 站视频的某一 P 加进片库。字幕取不到不拦着，照样加，说明原因。回 (这一部, 字幕几句, 取不到的原因)
    static func add(_ info: Info, page p: Info.Page) async throws -> (video: VideoLib.Video, lines: Int, why: String) {
        let title = info.pages.count > 1 && !p.part.isEmpty ? "\(info.title) - \(p.part)" : info.title
        if VideoLib.all().contains(where: { $0.bili?.bvid == info.bvid && $0.bili?.cid == p.cid }) {
            throw StoreError(message: "片库中已有这一部")
        }
        var srt = "", why = ""
        do {
            if let t = pickTrack(try await subtitleTracks(info.bvid, cid: p.cid)) { srt = try await subtitleSrt(t) }
            else { why = loggedIn() ? "该视频没有字幕" : "该视频没有公开字幕；登录后可以读取 AI 字幕" }
        } catch { why = "字幕读取失败：\(error.localizedDescription)" }
        let v = try VideoLib.add(title: title, subtitle: srt, seconds: p.seconds, bili: .init(bvid: info.bvid, cid: p.cid, part: p.part))
        return (v, Subtitle.parse(srt).count, why)
    }
}
