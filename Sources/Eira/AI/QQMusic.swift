import Foundation

/// QQ 音乐（原生版独有；网页版受浏览器跨域限制做不了）。走 QQ 音乐网页与客户端自己用的那几个接口，非官方，
/// 腾讯改了就要跟着修。接口的样子先在 GitHub Actions 上探过（scripts/qq-probe.mjs）：
///   搜歌     c.y.qq.com/soso/fcgi-bin/client_search_cp            不登录可用
///   歌词     c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg    不登录可用（nobase64=1）
///   封面     y.gtimg.cn/music/photo_new/T002R300x300M000{albummid}.jpg
///   歌单     c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg  公开歌单不登录可用
///   播放地址 u.y.qq.com/cgi-bin/musicu.fcg 的 vkey.GetVkeyServer   海外 IP 拿不到（invalidq），国内能拿到；会员歌要会员账号
///   扫码登录 ssl.ptlogin2.qq.com 的 ptqrshow / ptqrlogin，再经 graph.qq.com 授权换 code，最后 QQConnectLogin 换 musickey
///
/// 登录信息（uin、musickey、昵称）存在 settings.services.qqmusic，只在本机。读接口时直接连 QQ 音乐，不经过模型接口。
enum QQMusic {
    struct Track: Identifiable, Equatable, Sendable {
        var mid: String
        var id: String { mid }
        var songId: Int = 0
        var title: String
        var artist: String
        var albumMid: String = ""
        var seconds: Int = 0
        var cover: String { albumMid.isEmpty ? "" : "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg" }
        var label: String { artist.isEmpty ? title : "\(title) — \(artist)" }
    }

    struct QQError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let appId = "716027609", qqAppId = "100497308"

    /// 不让系统替我们存 cookie、也不自动跟随跳转：登录那几步要从跳转的 Location 与 Set-Cookie 里拿东西
    nonisolated(unsafe) static var session: URLSession = makeSession()

    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    static func makeSession(protocols: [AnyClass] = []) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        if !protocols.isEmpty { c.protocolClasses = protocols }
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }

    // MARK: - 设置

    static func config(_ s: AppSettings = .load()) -> [String: JSONValue] { s.services["qqmusic"]?.object ?? [:] }
    static func uin(_ s: AppSettings = .load()) -> String { config(s)["uin"]?.string ?? "" }
    static func musicKey(_ s: AppSettings = .load()) -> String { config(s)["musickey"]?.string ?? "" }
    static func loggedIn(_ s: AppSettings = .load()) -> Bool { !uin(s).isEmpty && !musicKey(s).isEmpty }

    static func patchConfig(_ patch: [String: JSONValue]) throws {
        var s = AppSettings.load()
        s.setService("qqmusic", patch)
        try s.save()
    }

    static func logout() throws { try patchConfig(["uin": .string(""), "musickey": .string(""), "nickname": .string(""), "avatar": .string("")]) }

    private static func loginCookie() -> String {
        let u = uin(), k = musicKey()
        guard !u.isEmpty, !k.isEmpty else { return "" }
        return "uin=o\(u); qqmusic_key=\(k); qm_keyst=\(k); tmeLoginType=2"
    }

    // MARK: - 请求

    struct Reply { var status: Int; var data: Data; var cookies: [String: String]; var location: String }

    static func get(_ url: String, cookie: String = "", referer: String = "https://y.qq.com/") async throws -> Reply {
        guard let u = URL(string: url) else { throw QQError(message: "地址有误") }
        var req = URLRequest(url: u)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        return try await send(req)
    }

    private static func send(_ req: URLRequest) async throws -> Reply {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw QQError(message: "连不上 QQ 音乐：\(error.localizedDescription)") }
        let http = resp as? HTTPURLResponse
        var cookies: [String: String] = [:]
        if let h = http, let url = h.url {
            let fields = h.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
            for c in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) where !c.value.isEmpty { cookies[c.name] = c.value }
        }
        return Reply(status: http?.statusCode ?? 0, data: data, cookies: cookies, location: http?.value(forHTTPHeaderField: "Location") ?? "")
    }

    private static func json(_ r: Reply) throws -> JSONValue {
        guard let j = try? JSONValue.parse(r.data) else {
            // 老接口有时包一层 callback(...)
            let t = String(data: r.data, encoding: .utf8) ?? ""
            if let a = t.firstIndex(of: "("), let b = t.lastIndex(of: ")"), let j = try? JSONValue.parse(Data(t[t.index(after: a)..<b].utf8)) { return j }
            throw QQError(message: "QQ 音乐返回的内容读不出来（HTTP \(r.status)）")
        }
        return j
    }

    /// musicu.fcg：一次可以带几个模块。登录了就带上登录信息
    static func musicu(_ reqs: [String: JSONValue]) async throws -> JSONValue {
        var comm: [String: JSONValue] = ["ct": .string("19"), "cv": .string("1859"), "uin": .string(uin().isEmpty ? "0" : uin())]
        if loggedIn() { comm["authst"] = .string(musicKey()); comm["tmeLoginType"] = .string("2") }
        var body = reqs
        body["comm"] = .object(comm)
        guard let u = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { throw QQError(message: "地址有误") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let ck = loginCookie()
        if !ck.isEmpty { req.setValue(ck, forHTTPHeaderField: "Cookie") }
        req.httpBody = try JSONValue.object(body).encoded()
        return try json(try await send(req))
    }

    // MARK: - 搜歌、歌词、播放地址

    private static func track(_ s: JSONValue) -> Track? {
        guard let mid = s["songmid"]?.string ?? s["mid"]?.string, !mid.isEmpty else { return nil }
        let singers = (s["singer"]?.array ?? []).compactMap { $0["name"]?.string }
        return Track(mid: mid, songId: Int(s["songid"]?.number ?? s["id"]?.number ?? 0),
                     title: s["songname"]?.string ?? s["name"]?.string ?? s["title"]?.string ?? "",
                     artist: singers.joined(separator: " / "),
                     albumMid: s["albummid"]?.string ?? s["album"]?["mid"]?.string ?? "",
                     seconds: Int(s["interval"]?.number ?? 0))
    }

    static func search(_ keywords: String, limit: Int = 30) async throws -> [Track] {
        let q = keywords.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var c = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
        c.queryItems = [.init(name: "w", value: q), .init(name: "format", value: "json"), .init(name: "p", value: "1"),
                        .init(name: "n", value: "\(max(1, limit))"), .init(name: "cr", value: "1")]
        let j = try json(try await get(c.url!.absoluteString))
        return (j["data"]?["song"]?["list"]?.array ?? []).compactMap(track)
    }

    static func lyric(_ mid: String) async throws -> (lrc: String, trans: String) {
        let j = try json(try await get("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(mid)&format=json&nobase64=1&g_tk=5381"))
        return (unescape(j["lyric"]?.string ?? ""), unescape(j["trans"]?.string ?? ""))
    }

    /// 老接口的歌词里有 &#58; 这类实体
    static func unescape(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        var out = s
        if let re = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                if let n = UInt32(ns.substring(with: m.range(at: 1))), let u = Unicode.Scalar(n), let r = Range(m.range, in: out) {
                    out.replaceSubrange(r, with: String(u))
                }
            }
        }
        return out
    }

    /// 播放地址。拿不到时把 QQ 音乐给的原因带出来（会员、地区、未登录）
    static func songUrl(_ mid: String) async throws -> String {
        let guid = String(Int.random(in: 1_000_000_000...9_999_999_999))
        let j = try await musicu(["req_0": .object([
            "module": .string("vkey.GetVkeyServer"), "method": .string("CgiGetVkey"),
            "param": .object(["guid": .string(guid), "songmid": .array([.string(mid)]), "songtype": .array([.number(0)]),
                              "uin": .string(uin().isEmpty ? "0" : uin()), "loginflag": .number(1), "platform": .string("20")]),
        ])])
        let d = j["req_0"]?["data"]
        let purl = d?["midurlinfo"]?[0]?["purl"]?.string ?? ""
        let sip = d?["sip"]?[0]?.string ?? "https://ws.stream.qqmusic.qq.com/"
        guard !purl.isEmpty else {
            let msg = d?["msg"]?.string ?? ""
            throw QQError(message: loggedIn()
                ? "QQ 音乐没有给出这首歌的播放地址，可能需要会员或版权受限\(msg.isEmpty ? "" : "（\(msg)）")"
                : "QQ 音乐没有给出这首歌的播放地址。登录 QQ 音乐后再试，会员歌曲需要会员账号\(msg.isEmpty ? "" : "（\(msg)）")")
        }
        return (sip.hasPrefix("http://") ? "https://" + sip.dropFirst(7) : sip) + purl
    }

    // MARK: - 歌单

    struct Playlist: Identifiable { var id: String; var name: String; var cover: String; var count: Int }

    /// 一张歌单里的歌（公开歌单不登录也能读）
    static func playlistTracks(_ id: String) async throws -> (name: String, tracks: [Track]) {
        let j = try json(try await get("https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&disstid=\(id)&format=json",
                                       cookie: loginCookie()))
        let cd = j["cdlist"]?[0]
        return (cd?["dissname"]?.string ?? "", (cd?["songlist"]?.array ?? []).compactMap(track))
    }

    /// 从分享链接或纯数字里取歌单 id
    static func playlistId(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: #"^\d{5,}$"#, options: .regularExpression) != nil { return t }
        for p in [#"[?&](?:id|disstid)=(\d{5,})"#, #"playlist/(\d{5,})"#, #"playsquare/(\d{5,})"#] {
            if let r = t.range(of: p, options: .regularExpression) {
                return String(t[r]).components(separatedBy: CharacterSet.decimalDigits.inverted).filter { $0.count >= 5 }.first
            }
        }
        return nil
    }

    /// 我建的歌单（要登录）
    static func myPlaylists() async throws -> [Playlist] {
        guard loggedIn() else { throw QQError(message: "尚未登录 QQ 音乐") }
        let j = try await musicu(["req": .object([
            "module": .string("music.musicasset.PlaylistBaseRead"), "method": .string("GetPlaylistByUin"),
            "param": .object(["uin": .string(uin())]),
        ])])
        let code = Int(j["req"]?["code"]?.number ?? -1)
        guard code == 0 else { throw QQError(message: "读不到歌单（QQ 音乐返回 \(code)），可能需要重新登录") }
        return (j["req"]?["data"]?["v_playlist"]?.array ?? []).compactMap { p in
            let id = p["tid"]?.number.map { String(Int($0)) } ?? p["tid"]?.string ?? ""
            guard !id.isEmpty, id != "0" else { return nil }
            return Playlist(id: id, name: p["dirName"]?.string ?? "", cover: p["picUrl"]?.string ?? "", count: Int(p["songNum"]?.number ?? 0))
        }
    }

    // MARK: - 扫码登录

    /// 腾讯那边用的散列（ptqrtoken、g_tk）
    /// 照 JS 的写法算：e += (e << 5) + 字符，其中 << 先把 e 截成 32 位有符号整数；最后 & 2147483647
    static func hash33(_ s: String, seed: Int = 0) -> Int {
        var e = Int64(seed)
        for u in s.utf16 { e = e &+ Int64(Int32(truncatingIfNeeded: e) &<< 5) &+ Int64(u) }
        return Int(Int32(truncatingIfNeeded: e)) & 2147483647
    }

    struct QR { var image: Data; var qrsig: String }

    static func qrStart() async throws -> QR {
        let r = try await get("https://ssl.ptlogin2.qq.com/ptqrshow?appid=\(appId)&e=2&l=M&s=3&d=72&v=4&t=\(Double.random(in: 0..<1))&daid=383&pt_3rd_aid=\(qqAppId)",
                              referer: "https://xui.ptlogin2.qq.com/")
        guard let sig = r.cookies["qrsig"], !r.data.isEmpty else { throw QQError(message: "没有取到登录二维码（HTTP \(r.status)）") }
        return QR(image: r.data, qrsig: sig)
    }

    enum QRState: Equatable { case waiting, scanned, expired, done(String), failed(String) }

    /// 问一次扫码的进度。成功时带回下一步要打开的地址
    static func qrCheck(_ qrsig: String) async throws -> (state: QRState, cookies: [String: String]) {
        let u1 = "https%3A%2F%2Fgraph.qq.com%2Foauth2.0%2Flogin_jump"
        let url = "https://ssl.ptlogin2.qq.com/ptqrlogin?u1=\(u1)&ptqrtoken=\(hash33(qrsig))&ptredirect=0&h=1&t=1&g=1&from_ui=1&ptlang=2052"
            + "&action=0-0-\(Int(Date().millis))&js_ver=20102616&js_type=1&pt_uistyle=40&aid=\(appId)&daid=383&pt_3rd_aid=\(qqAppId)&has_onekey=1"
        let r = try await get(url, cookie: "qrsig=\(qrsig)", referer: "https://xui.ptlogin2.qq.com/")
        let text = String(data: r.data, encoding: .utf8) ?? ""
        let parts = text.components(separatedBy: "'").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        let code = parts.first ?? ""
        switch code {
        case "0": return (.done(parts.count > 2 ? parts[2] : ""), r.cookies)
        case "66": return (.waiting, r.cookies)
        case "67": return (.scanned, r.cookies)
        case "65": return (.expired, r.cookies)
        default: return (.failed(parts.count > 4 ? parts[4] : "登录未完成（\(code.isEmpty ? text.prefix(60).description : code)）"), r.cookies)
        }
    }

    /// 扫码确认之后：打开那个地址拿到 p_skey，再到 graph.qq.com 授权换 code，最后换成 QQ 音乐的登录信息
    static func finishLogin(checkSigURL: String, cookies first: [String: String]) async throws -> String {
        var jar = first
        func cookieHeader() -> String { jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ") }
        let sig = try await get(checkSigURL, cookie: cookieHeader(), referer: "https://xui.ptlogin2.qq.com/")
        jar.merge(sig.cookies) { _, n in n }
        guard let pskey = jar["p_skey"], !pskey.isEmpty else { throw QQError(message: "登录第二步没有拿到 p_skey（HTTP \(sig.status)）") }

        guard let au = URL(string: "https://graph.qq.com/oauth2.0/authorize") else { throw QQError(message: "地址有误") }
        var req = URLRequest(url: au)
        req.httpMethod = "POST"
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://graph.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        let form: [(String, String)] = [
            ("response_type", "code"), ("client_id", qqAppId),
            ("redirect_uri", "https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/"),
            ("scope", "get_user_info,get_app_friends"), ("state", "state"), ("switch", ""), ("from_ptlogin", "1"), ("src", "1"),
            ("update_auth", "1"), ("openapi", "1010_1030"), ("g_tk", "\(hash33(pskey, seed: 5381))"), ("auth_time", "\(Int(Date().millis))"),
            ("ui", UUID().uuidString),
        ]
        req.httpBody = Data(form.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.1)" }.joined(separator: "&").utf8)
        let auth = try await send(req)
        guard let code = URLComponents(string: auth.location)?.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw QQError(message: "登录第三步没有拿到授权（HTTP \(auth.status)）")
        }

        let j = try await musicu(["req": .object([
            "module": .string("QQConnectLogin.LoginServer"), "method": .string("QQLogin"),
            "param": .object(["code": .string(code)]),
        ])])
        let d = j["req"]?["data"]
        let key = d?["musickey"]?.string ?? ""
        let uin = d?["musicid"]?.number.map { String(Int($0)) } ?? d?["musicid"]?.string ?? ""
        guard !key.isEmpty, !uin.isEmpty else {
            throw QQError(message: "登录最后一步没有成功（QQ 音乐返回 \(Int(j["req"]?["code"]?.number ?? -1))）")
        }
        try patchConfig(["uin": .string(uin), "musickey": .string(key), "nickname": .string(""), "loginAt": .number(Date().millis)])
        return uin
    }
}
