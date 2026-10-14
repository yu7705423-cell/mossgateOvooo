import CommonCrypto
import CryptoKit
import Foundation

/// 按插入顺序编码的 JSON。网易云 eapi 的签名是对「发出去的那串 JSON」算的，键的顺序要和网页版一致，
/// 才能拿网页版的标准答案逐字节核对（网页版 tests/necrypto.test.mjs）。
indirect enum NJ: Sendable {
    case s(String), i(Int), b(Bool), null
    case o([(String, NJ)])
    case a([NJ])

    var json: String {
        switch self {
        case .s(let v): return NJ.quote(v)
        case .i(let v): return String(v)
        case .b(let v): return v ? "true" : "false"
        case .null: return "null"
        case .a(let list): return "[" + list.map(\.json).joined(separator: ",") + "]"
        case .o(let pairs): return "{" + pairs.map { NJ.quote($0.0) + ":" + $0.1.json }.joined(separator: ",") + "}"
        }
    }

    var str: String {
        if case .s(let v) = self { return v }
        return ""
    }

    /// 和 JS 的 JSON.stringify 一样：只转义引号、反斜杠与控制字符，中文原样。
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

/// 网易云接口的两种加密（网页版 system/ne/crypto.js，照 NeteaseCloudMusicApi 写）。这些常量是网易云客户端里公开写死的。
enum NeCrypto {
    static let iv = "0102030405060708"
    static let preset = "0CoJUm6Qyw8W8jud"
    static let eapiKey = "e82ckenh8dichen8"
    /// weapi 第二层用的密钥。网页版每次随机，原生版固定一把，encSecKey 预先用网易云的公钥算好（无填充 RSA，结果不变），
    /// 省得在本机做大数模幂。
    static let weapiKey = "EiraNativeWeapi7"
    static let weapiEncSecKey = "820bafb133137b8fd0781b6c1e9c0bd0ea37e39457cef2cf02c4bc89a9f32f4b1bb6e940f530e34c7b2f93431bb73ea8775edca1878cbea556eb35096f1f362cb4144ce38ebd43c71159815464edf1c0ab6bda4715cb71bc56646cea53e988aa7f754d86fdf84ee3834636067695b7b679829316987b3a51222cbf8eaaf514c8"

    static func aes(_ data: Data, key: String, iv: String?, ecb: Bool) -> Data {
        let k = Array(key.utf8), v = iv.map { Array($0.utf8) }
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = data.withUnsafeBytes { raw in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding | (ecb ? kCCOptionECBMode : 0)),
                    k, k.count, v, raw.baseAddress, data.count, &out, out.count, &moved)
        }
        return status == kCCSuccess ? Data(out.prefix(moved)) : Data()
    }

    static func md5Hex(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// weapi 的 params：固定密钥一层，再用 key 一层，各自 base64。
    static func weapiParams(_ text: String, key: String = weapiKey) -> String {
        let first = aes(Data(text.utf8), key: preset, iv: iv, ecb: false).base64EncodedString()
        return aes(Data(first.utf8), key: key, iv: iv, ecb: false).base64EncodedString()
    }

    static func weapi(_ obj: NJ) -> [(String, String)] {
        [("params", weapiParams(obj.json)), ("encSecKey", weapiEncSecKey)]
    }

    /// eapi：「网址 + JSON + 两者的 MD5」拼起来，AES-ECB，十六进制大写。
    static func eapiParams(_ url: String, _ obj: NJ) -> String {
        let text = obj.json
        let digest = md5Hex("nobody\(url)use\(text)md5forencrypt")
        let data = "\(url)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"
        return aes(Data(data.utf8), key: eapiKey, iv: nil, ecb: true).map { String(format: "%02X", $0) }.joined()
    }

    /// 游客注册时的设备编号那一段。
    static func encodeDeviceId(_ id: String) -> String {
        let key = Array("3go8&$8*3*3h0k(2)2".utf8)
        let x = Array(id.utf8).enumerated().map { $0.element ^ key[$0.offset % key.count] }
        let digest = Data(Insecure.MD5.hash(data: Data(x))).base64EncodedString()
        return Data("\(id) \(digest)".utf8).base64EncodedString()
    }
}

/// 一首网易云的歌（还没收进本机曲库的那种）。
struct NeTrack: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String = ""
    var cover: String = ""
    var seconds: Int = 0
    var at: Double = 0
    var count: Int = 0

    var label: String { artist.isEmpty ? title : "\(title) — \(artist)" }
}

/// 网易云（网页版 system/netease.js、ne/client.js、ne/routes.js）。
///
/// 网页版受浏览器跨域限制，要经一台转发服务器；原生版没有这层限制，直接和网易云说话，请求的写法与网页版一字不差。
/// 只调网易云，不调模型，不花接口的钱。登录只有扫码与粘贴 cookie 两种，不收密码。
enum Netease {
    struct Reply { var status: Int; var body: JSONValue; var cookies: [String] }

    static let domain = "https://music.163.com"
    static let apiDomain = "https://interface.music.163.com"
    static let special: Set<Int> = [201, 302, 400, 502, 800, 801, 802, 803]
    static let uaWeapi = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0"
    static let uaEapi = "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"

    /// 不让系统替我们存、替我们带 cookie：两个账号（你的与角色的）各带各的。
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    // MARK: - 设置

    static func config(_ s: AppSettings = .load()) -> [String: JSONValue] { s.raw["services"]?["netease"]?.object ?? [:] }
    static func userCookie(_ s: AppSettings = .load()) -> String { config(s)["cookie"]?.string ?? "" }

    static func cookieOf(_ charId: String) -> String {
        guard !charId.isEmpty else { return userCookie() }
        return (try? Repo.character(charId))?.row.string("neteaseCookie") ?? ""
    }

    static func patchConfig(_ patch: [String: JSONValue]) throws {
        var s = try AppSettings.loadForWrite()
        var all = s.raw["services"]?.object ?? [:]
        var n = all["netease"]?.object ?? [:]
        for (k, v) in patch { n[k] = v }
        all["netease"] = .object(n)
        s.raw["services"] = .object(all)
        try s.save()
    }

    /// 这台设备在网易云那边的身份：设备号、一个固定的国内 IP、游客身份。没有就造一份存下（和网页版存在同一处）。
    static func device() -> (id: String, ip: String, anon: String) {
        let d = config()["device"]
        if let id = d?["deviceId"]?.string, !id.isEmpty {
            return (id, d?["ip"]?.string ?? "", d?["anon"]?.string ?? "")
        }
        let id = String((0..<52).map { _ in "0123456789ABCDEF".randomElement()! })
        let prefixes = ["116.25"] + (76...94).map { "116.\($0)" }
        let ip = "\(prefixes.randomElement()!).\(Int.random(in: 1...255)).\(Int.random(in: 1...255))"
        try? patchConfig(["device": .object(["deviceId": .string(id), "ip": .string(ip), "anon": .string("")])])
        return (id, ip, "")
    }

    static func realIP() -> String {
        let r = (config()["realIP"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? device().ip : r
    }

    // MARK: - cookie

    static func cookieToJson(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in s.split(separator: ";") {
            guard let i = part.firstIndex(of: "=") else { continue }
            let k = part[..<i].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = part[part.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    private static func cookieString(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "; ")
    }

    private static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func hex(_ n: Int) -> String { (0..<n).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    // MARK: - 请求

    /// 发一个请求。uri 是 /api/... 那一段；crypto 是 weapi 或 eapi。状态码的算法与网页版一致。
    static func request(_ uri: String, _ data: [(String, NJ)], crypto: String = "eapi", cookie: String = "") async -> Reply {
        let dev = device()
        var ck = cookieToJson(cookie)
        let nuid = hex(32)
        let defaults: [(String, String)] = [
            ("__remember_me", "true"), ("ntes_kaola_ad", "1"), ("_ntes_nuid", ck["_ntes_nuid"] ?? nuid),
            ("_ntes_nnid", ck["_ntes_nnid"] ?? "\(nuid),\(Int(Date().millis))"), ("WNMCID", ck["WNMCID"] ?? "eiraok.\(Int(Date().millis)).01.0"),
            ("WEVNSM", ck["WEVNSM"] ?? "1.0.0"), ("osver", ck["osver"] ?? "Microsoft-Windows-10-Professional-build-19045-64bit"),
            ("deviceId", ck["deviceId"] ?? dev.id), ("os", ck["os"] ?? "pc"), ("channel", ck["channel"] ?? "netease"),
            ("appver", ck["appver"] ?? "3.1.17.204416"),
        ]
        for (k, v) in defaults { ck[k] = v }
        if !uri.contains("login") { ck["NMTID"] = hex(16) }
        if ck["MUSIC_U"] == nil, ck["MUSIC_A"] == nil, !dev.anon.isEmpty { ck["MUSIC_A"] = dev.anon }
        let csrf = ck["__csrf"] ?? ""
        var d = data + [("e_r", NJ.b(false))]

        let url: String, form: [(String, String)], headerCookie: String, ua: String
        var referer = ""
        if crypto == "weapi" {
            d.append(("csrf_token", .s(csrf)))
            form = NeCrypto.weapi(.o(d))
            url = "\(domain)/weapi/\(uri.dropFirst(5))"
            headerCookie = cookieString(ck.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
            ua = uaWeapi
            referer = domain
        } else {
            var header: [(String, NJ)] = [
                ("osver", .s(ck["osver"] ?? "")), ("deviceId", .s(ck["deviceId"] ?? "")), ("os", .s(ck["os"] ?? "")),
                ("appver", .s(ck["appver"] ?? "")), ("versioncode", .s(ck["versioncode"] ?? "140")),
                ("mobilename", .s(ck["mobilename"] ?? "")), ("buildver", .s(ck["buildver"] ?? String(String(Int(Date().millis)).prefix(10)))),
                ("resolution", .s(ck["resolution"] ?? "1920x1080")), ("__csrf", .s(csrf)), ("channel", .s(ck["channel"] ?? "")),
                ("requestId", .s("\(Int(Date().millis))_\(String(format: "%04d", Int.random(in: 0..<1000)))")),
            ]
            if let u = ck["MUSIC_U"] { header.append(("MUSIC_U", .s(u))) }
            if let a = ck["MUSIC_A"] { header.append(("MUSIC_A", .s(a))) }
            headerCookie = cookieString(header.map { ($0.0, $0.1.str) })
            ua = uaEapi
            d.append(("header", .o(header)))
            form = [("params", NeCrypto.eapiParams(uri, .o(d)))]
            url = "\(apiDomain)/eapi/\(uri.dropFirst(5))"
        }
        guard let u = URL(string: url) else { return Reply(status: 400, body: .object(["msg": .string("地址无效")]), cookies: []) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(headerCookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        let ip = realIP()
        if ip.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            req.setValue(ip, forHTTPHeaderField: "X-Real-IP")
            req.setValue(ip, forHTTPHeaderField: "X-Forwarded-For")
        }
        req.httpBody = Data(form.map { "\($0.0)=\(enc($0.1))" }.joined(separator: "&").utf8)
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            var cookies: [String] = []
            if let http, let fields = http.allHeaderFields as? [String: String] {
                cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: u).map { "\($0.name)=\($0.value)" }
            }
            guard let body = try? JSONValue.parse(data) else {
                return Reply(status: http?.statusCode ?? 500, body: .object(["msg": .string(String((String(data: data, encoding: .utf8) ?? "").prefix(200)))]), cookies: cookies)
            }
            var status = Int(body["code"]?.number ?? Double(http?.statusCode ?? 500))
            if special.contains(status) { status = 200 }
            if status <= 100 || status >= 600 { status = 400 }
            return Reply(status: status, body: body, cookies: cookies)
        } catch {
            return Reply(status: 502, body: .object(["code": .number(502), "msg": .string("连不上网易云：\(error.localizedDescription)")]), cookies: [])
        }
    }

    struct NeError: LocalizedError {
        var code: Int
        var message: String
        var errorDescription: String? { message }
    }

    static let risky: Set<Int> = [-462, -460]

    /// 发请求并要求成功。游客身份还没有就先注册一个；没登录时被风控拦下，换一个新的游客身份再试一次。
    static func call(_ uri: String, _ data: [(String, NJ)], crypto: String = "eapi", cookie: String = "") async throws -> Reply {
        if cookie.isEmpty { await ensureAnon() }
        var r = await request(uri, data, crypto: crypto, cookie: cookie)
        let code = Int(r.body["code"]?.number ?? 0)
        if cookie.isEmpty && risky.contains(code) {
            await ensureAnon(force: true)
            r = await request(uri, data, crypto: crypto, cookie: cookie)
        }
        guard r.status == 200 else {
            let c = Int(r.body["code"]?.number ?? Double(r.status))
            if risky.contains(c) {
                throw NeError(code: c, message: "网易云拦下了这台设备的请求（风控），换用游客身份也没有通过。可在「设置 - 音乐服务」中填写一个中国大陆 IP 后重试。")
            }
            throw NeError(code: c, message: "网易云 \(c)：\(r.body["message"]?.string ?? r.body["msg"]?.string ?? "请求失败")")
        }
        return r
    }

    static func ensureAnon(force: Bool = false) async {
        let dev = device()
        if !dev.anon.isEmpty && !force { return }
        let r = await request("/api/register/anonimous", [("username", .s(NeCrypto.encodeDeviceId(dev.id)))], crypto: "weapi")
        let a = cookieToJson(r.cookies.joined(separator: ";"))["MUSIC_A"] ?? ""
        guard !a.isEmpty else { return }
        var d = config()["device"]?.object ?? [:]
        d["anon"] = .string(a)
        try? patchConfig(["device": .object(d)])
    }

    // MARK: - 接口

    static func https(_ s: String) -> String { s.hasPrefix("http://") ? "https://" + s.dropFirst(7) : s }

    static func track(_ s: JSONValue) -> NeTrack? {
        guard let id = s["id"]?.number.map({ String(Int($0)) }) ?? s["id"]?.string, let title = s["name"]?.string else { return nil }
        let artists = (s["ar"]?.array ?? s["artists"]?.array ?? []).compactMap { $0["name"]?.string }.joined(separator: "、")
        let al = s["al"] ?? s["album"]
        return NeTrack(id: id, title: title, artist: artists, album: al?["name"]?.string ?? "",
                       cover: https(al?["picUrl"]?.string ?? ""), seconds: Int(((s["dt"]?.number ?? s["duration"]?.number ?? 0) / 1000).rounded()))
    }

    static func search(_ keywords: String, limit: Int = 30) async throws -> [NeTrack] {
        let q: [(String, NJ)] = [("s", .s(keywords)), ("type", .i(1)), ("limit", .i(limit)), ("offset", .i(0)), ("total", .b(true))]
        if let r = try? await call("/api/cloudsearch/pc", q), let songs = r.body["result"]?["songs"]?.array {
            return songs.compactMap(track)
        }
        let r = try await call("/api/search/get", Array(q.prefix(4)))
        return (r.body["result"]?["songs"]?.array ?? []).compactMap(track)
    }

    /// 播放地址。不存：地址会过期，每次播放时现取。
    static func songUrl(_ id: String, cookie: String = userCookie()) async throws -> String {
        if let r = try? await call("/api/song/enhance/player/url/v1", [("ids", .s("[\(id)]")), ("level", .s("standard")), ("encodeType", .s("flac"))], cookie: cookie),
           let u = r.body["data"]?[0]?["url"]?.string, !u.isEmpty { return https(u) }
        let r = try await call("/api/song/enhance/player/url", [("ids", .s("[\"\(id)\"]")), ("br", .i(999000))], cookie: cookie)
        guard let u = r.body["data"]?[0]?["url"]?.string, !u.isEmpty else {
            throw NeError(code: 404, message: "这首歌取不到播放地址，可能需要会员或版权受限")
        }
        return https(u)
    }

    struct Lyric { var lrc: String; var tlrc: String; var pure: Bool; var none: Bool }

    static func lyric(_ id: String) async throws -> Lyric {
        let r = try await call("/api/song/lyric", [("id", .s(id)), ("tv", .i(-1)), ("lv", .i(-1)), ("rv", .i(-1)), ("kv", .i(-1)), ("_nmclfl", .i(1))])
        return Lyric(lrc: r.body["lrc"]?["lyric"]?.string ?? "", tlrc: r.body["tlyric"]?["lyric"]?.string ?? "",
                     pure: r.body["pureMusic"]?.bool == true, none: r.body["nolyric"]?.bool == true || r.body["uncollected"]?.bool == true)
    }

    // 扫码登录

    static func qrKey() async throws -> String {
        let r = try await call("/api/login/qrcode/unikey", [("type", .i(3))])
        guard let k = r.body["unikey"]?.string else { throw NeError(code: 0, message: "没有取到二维码") }
        return k
    }

    static func qrURL(_ key: String) -> String { "https://music.163.com/login?codekey=\(key)" }

    /// 800 过期、801 等待扫码、802 已扫待确认、803 成功（带 cookie）。
    static func qrCheck(_ key: String) async throws -> (code: Int, message: String, cookie: String) {
        let r = try await call("/api/login/qrcode/client/login", [("key", .s(key)), ("type", .i(3))])
        return (Int(r.body["code"]?.number ?? 0), r.body["message"]?.string ?? "", r.cookies.joined(separator: "; "))
    }

    static func account(cookie: String) async throws -> (uid: String, nickname: String) {
        let r = try await call("/api/nuser/account/get", [], crypto: "weapi", cookie: cookie)
        guard let p = r.body["profile"], let uid = p["userId"]?.number else { throw NeError(code: 301, message: "登录已失效，请重新登录") }
        return (String(Int(uid)), p["nickname"]?.string ?? "")
    }

    /// 存登录：角色的存在角色身上，你的存在设置里。
    static func saveLogin(_ cookie: String, charId: String = "") async throws -> String {
        let raw = cookie.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { throw NeError(code: 0, message: "cookie 是空的") }
        let acc = try? await account(cookie: raw)
        if charId.isEmpty {
            try patchConfig(["cookie": .string(raw), "nickname": .string(acc?.nickname ?? ""), "uid": .string(acc?.uid ?? "")])
        } else {
            try Diary.patchChar(charId, ["neteaseCookie": .string(raw), "neteaseNick": .string(acc?.nickname ?? ""), "neteaseUid": .string(acc?.uid ?? "")])
        }
        return acc?.nickname ?? ""
    }

    static func logout(charId: String = "") throws {
        if charId.isEmpty { try patchConfig(["cookie": .string(""), "nickname": .string(""), "uid": .string("")]) }
        else { try Diary.patchChar(charId, ["neteaseCookie": .string(""), "neteaseNick": .string(""), "neteaseUid": .string("")]) }
    }

    static func uidOf(_ charId: String = "") async throws -> String {
        let saved = charId.isEmpty ? (config()["uid"]?.string ?? "") : ((try? Repo.character(charId))?.row.string("neteaseUid") ?? "")
        if !saved.isEmpty { return saved }
        return try await account(cookie: cookieOf(charId)).uid
    }

    // 账号的数据

    struct Profile { var nickname = "", avatar = "", signature = "", level = 0, listenSongs = 0, createDays = 0, follows = 0, followeds = 0, uid = "" }

    static func profile(_ charId: String = "") async throws -> Profile {
        let uid = try await uidOf(charId)
        let r = try await call("/api/v1/user/detail/\(uid)", [], crypto: "weapi", cookie: cookieOf(charId))
        let p = r.body["profile"]
        return Profile(nickname: p?["nickname"]?.string ?? "", avatar: https(p?["avatarUrl"]?.string ?? ""), signature: p?["signature"]?.string ?? "",
                       level: Int(r.body["level"]?.number ?? 0), listenSongs: Int(r.body["listenSongs"]?.number ?? 0),
                       createDays: Int(r.body["createDays"]?.number ?? 0), follows: Int(p?["follows"]?.number ?? 0),
                       followeds: Int(p?["followeds"]?.number ?? 0), uid: uid)
    }

    /// 听歌排行：最近一周或所有时间。
    static func record(_ charId: String = "", week: Bool) async throws -> [NeTrack] {
        let uid = try await uidOf(charId)
        let r = try await call("/api/v1/play/record", [("uid", .s(uid)), ("type", .i(week ? 1 : 0))], crypto: "weapi", cookie: cookieOf(charId))
        return (r.body[week ? "weekData" : "allData"]?.array ?? []).compactMap { row in
            guard var t = row["song"].flatMap(track) else { return nil }
            t.count = Int(row["playCount"]?.number ?? 0)
            return t
        }
    }

    /// 最近播放。取不到就退回本周排行（kind 为 week）。
    static func recent(_ charId: String = "", limit: Int = 5) async throws -> (kind: String, songs: [NeTrack]) {
        let cookie = cookieOf(charId)
        guard !cookie.isEmpty else { throw NeError(code: 301, message: "这个账号还没有登录网易云") }
        if let r = try? await call("/api/play-record/song/list", [("limit", .i(limit))], crypto: "weapi", cookie: cookie) {
            let songs = (r.body["data"]?["list"]?.array ?? []).compactMap { row -> NeTrack? in
                guard var t = track(row["data"] ?? row["song"] ?? row) else { return nil }
                t.at = row["playTime"]?.number ?? row["time"]?.number ?? 0
                return t
            }
            if !songs.isEmpty { return ("recent", songs) }
        }
        let week = try await record(charId, week: true)
        guard !week.isEmpty else { throw NeError(code: 404, message: "这个账号最近没有听歌记录") }
        return ("week", Array(week.prefix(limit)))
    }

    struct Playlist: Identifiable { var id: String; var name: String; var cover: String; var count: Int; var mine: Bool }

    static func playlists(_ charId: String = "") async throws -> [Playlist] {
        let uid = try await uidOf(charId)
        let r = try await call("/api/user/playlist", [("uid", .s(uid)), ("limit", .i(200)), ("offset", .i(0)), ("includeVideo", .b(true))],
                               crypto: "weapi", cookie: cookieOf(charId))
        return (r.body["playlist"]?.array ?? []).compactMap { p in
            guard let id = p["id"]?.number else { return nil }
            return Playlist(id: String(Int(id)), name: p["name"]?.string ?? "", cover: https(p["coverImgUrl"]?.string ?? ""),
                            count: Int(p["trackCount"]?.number ?? 0), mine: p["userId"]?.number.map { String(Int($0)) } == uid)
        }
    }

    static func playlistTracks(_ id: String) async throws -> [NeTrack] {
        let cookie = userCookie()
        let d = try await call("/api/v6/playlist/detail", [("id", .s(id)), ("n", .i(100000)), ("s", .i(8))], cookie: cookie)
        let ids = (d.body["playlist"]?["trackIds"]?.array ?? []).compactMap { $0["id"]?.number.map { Int($0) } }.prefix(1000)
        guard !ids.isEmpty else { return (d.body["playlist"]?["tracks"]?.array ?? []).compactMap(track) }
        let r = try await call("/api/v3/song/detail", [("c", .s("[" + ids.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"))], cookie: cookie)
        return (r.body["songs"]?.array ?? []).compactMap(track)
    }

    /// 记一次听歌（你的账号，或者角色的）。失败不管。
    static func scrobble(_ id: String, seconds: Int, cookie: String) async {
        guard !cookie.isEmpty, !id.isEmpty, let n = Int(id) else { return }
        let logs = NJ.a([.o([("action", .s("play")), ("json", .o([
            ("download", .i(0)), ("end", .s("playend")), ("id", .i(n)), ("sourceId", .i(n)), ("time", .i(max(1, seconds))),
            ("type", .s("song")), ("wifi", .i(0)), ("source", .s("list")), ("mainsite", .i(1)), ("content", .s("")),
        ]))])])
        _ = await request("/api/feedback/weblog", [("logs", .s(logs.json))], crypto: "weapi", cookie: cookie)
    }

    // MARK: - 角色在听什么

    nonisolated(unsafe) private static var lastTried: [String: Double] = [:]
    private static let lock = NSLock()

    /// 读角色那个账号的最近播放，记在角色身上。
    @discardableResult
    static func pullRecent(_ charId: String) async throws -> (kind: String, songs: [NeTrack]) {
        let got = try await recent(charId, limit: 5)
        let songs: [JSONValue] = got.songs.map { t in
            .object(["id": .string(t.id), "title": .string(t.title), "artist": .string(t.artist), "cover": .string(t.cover), "at": .number(t.at)])
        }
        try Diary.patchChar(charId, ["nowPlaying": .object(["kind": .string(got.kind), "songs": .array(songs), "at": .number(Date().millis)])])
        return got
    }

    /// 请求回复之前调：角色登录了网易云、离上次读已经过了设定的分钟数才读。只调网易云，不调模型。
    /// 试过就记下（成功失败都算），读失败时不会每条消息都再读一次。
    static func pullIfDue(_ charId: String) async {
        let gap = config()["recentGap"]?.number ?? 5
        guard gap > 0, !cookieOf(charId).isEmpty else { return }
        let last = max((try? Repo.character(charId))?.row["nowPlaying"]?["at"]?.number ?? 0, { lock.lock(); defer { lock.unlock() }; return lastTried[charId] ?? 0 }())
        let now = Date().millis
        guard now - last >= gap * 60000 else { return }
        lock.lock(); lastTried[charId] = now; lock.unlock()
        _ = try? await pullRecent(charId)
    }

    /// 进聊天提示词的 [你在听的歌]（网页版 context/music.js）。太久以前读到的不注入（musicFresh，默认 120 分钟，0 为不限）。
    static func block(_ char: Character, now: Double = Date().millis) -> String {
        guard let got = char.row["nowPlaying"], let songs = got["songs"]?.array, !songs.isEmpty else { return "" }
        let keep = AppSettings.load().raw["musicFresh"]?.number ?? 120
        let ms = keep * 60000
        if keep > 0, let at = got["at"]?.number, at > 0, now - at > ms { return "" }
        func line(_ s: JSONValue) -> String {
            let a = s["artist"]?.string ?? ""
            return (s["title"]?.string ?? "") + (a.isEmpty ? "" : " — \(a)")
        }
        let tail = "\nThe above is your own listening history. Answer from it when asked, and do not substitute other tracks."
        if got["kind"]?.string == "recent" {
            let fresh = keep > 0 ? songs.filter { s in (s["at"]?.number ?? 0) <= 0 || now - (s["at"]?.number ?? 0) <= ms } : songs
            guard let first = fresh.first else { return "" }
            var out = "[你在听的歌]\nMost recent track: \(line(first))"
            if fresh.count > 1 { out += "\nBefore that, in order: " + fresh.dropFirst().map(line).joined(separator: "；") }
            return out + tail
        }
        return "[你在听的歌]\nFrequently played lately: " + songs.map(line).joined(separator: "；") + tail
            + "\nThe history carries no timestamps; do not describe it as what you are playing right now."
    }
}
