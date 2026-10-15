import Foundation

/// 语音台本（网页版 ai/voicescript.js）：在要念的那句话里标出哪里停顿、哪里换情绪、哪里有一声叹气。
///
///   <情绪 平静>你回来了。<停顿 0.8><声音 叹气><情绪 生气>今天怎么这么晚？
///
/// 三个标记都是协议（第 14 条留中文）。用尖括号：台本常写在 `[语音：…]` 里，方括号会把外面那层提前收口。
/// 这里只管翻成各家的写法：
///   MiniMax        停顿 `<#0.8#>`；情绪一次请求一个（voice_setting.emotion），只认固定几个；声音 `(sighs)` 只有 speech-2.8 以上认
///   OpenAI 兼容    停顿写成省略号；情绪写进 instructions；声音丢掉
///   ElevenLabs     `<break time="0.8s" />`，最长 3 秒；没有情绪；声音丢掉
///   ElevenLabs v3  停顿、情绪、声音都写成方括号标签夹在句子里
/// 情绪一次请求一个的那几家按情绪切段，一段一次请求，音频按顺序接上。都按字数计费，切段不多花钱。
enum VoiceScript {
    struct Token: Equatable { var t: String; var v: String = ""; var s: Double = 0 }
    struct Segment: Equatable { var mood: String; var parts: [Token] }

    private static let tag = try! NSRegularExpression(pattern: #"<\s*(停顿|情绪|声音)\s*([^<>]*?)\s*>"#)
    private static let half = try! NSRegularExpression(pattern: #"<[^<>]*$"#)

    static func hasTags(_ raw: String) -> Bool {
        tag.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) != nil
    }

    /// 去掉所有标记之后的那句话：字幕、历史、翻译用的都是它
    static func plain(_ raw: String) -> String {
        let ns = raw as NSString
        var s = tag.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        s = half.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        return s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func seconds(_ v: String) -> Double {
        let n = Double(v.filter { $0.isNumber || $0 == "." }) ?? 0
        return n > 0 ? n : 0.5
    }

    static func tokens(_ raw: String) -> [Token] {
        let ns = raw as NSString
        var out: [Token] = []
        var last = 0
        for m in tag.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { out.append(Token(t: "text", v: ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
            let kind = ns.substring(with: m.range(at: 1)), val = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if kind == "停顿" { out.append(Token(t: "pause", s: seconds(val))) }
            else if !val.isEmpty { out.append(Token(t: kind == "情绪" ? "mood" : "sound", v: val)) }
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(Token(t: "text", v: ns.substring(from: last))) }
        return out.filter { $0.t != "text" || !$0.v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - 词表

    private static let moods: [String: String] = [
        "happy": "happy", "高兴": "happy", "开心": "happy",
        "sad": "sad", "难过": "sad", "伤心": "sad", "低落": "sad",
        "angry": "angry", "生气": "angry", "愤怒": "angry",
        "fearful": "fearful", "害怕": "fearful", "恐惧": "fearful",
        "disgusted": "disgusted", "厌恶": "disgusted",
        "surprised": "surprised", "惊讶": "surprised", "吃惊": "surprised",
        "calm": "calm", "平静": "calm", "冷静": "calm", "平淡": "calm",
        "fluent": "fluent", "流畅": "fluent",
        "whisper": "whisper", "耳语": "whisper", "低语": "whisper", "悄声": "whisper",
    ]
    private static let sounds: [String: String] = [
        "笑": "laughs", "大笑": "laughs", "轻笑": "chuckle", "咳嗽": "coughs", "清嗓子": "clear-throat",
        "呻吟": "groans", "呼吸": "breath", "喘气": "pant", "喘息": "pant", "吸气": "inhale", "呼气": "exhale",
        "倒吸气": "gasps", "吸鼻子": "sniffs", "抽鼻子": "sniffs", "叹气": "sighs", "叹息": "sighs",
        "嗤笑": "snorts", "哼": "snorts", "咂嘴": "lip-smacking", "哼歌": "humming", "嘘": "hissing",
        "嗯": "emm", "呃": "emm", "打喷嚏": "sneezes", "打嗝": "burps",
    ]
    private static let mmSounds: Set<String> = ["laughs", "chuckle", "coughs", "clear-throat", "groans", "breath", "pant", "inhale",
                                                "exhale", "gasps", "sniffs", "sighs", "snorts", "burps", "lip-smacking", "humming", "hissing", "emm", "sneezes"]

    private static func lookup(_ table: [String: String], _ w: String) -> String {
        let k = w.trimmingCharacters(in: .whitespaces)
        return table[k.lowercased()] ?? table[k] ?? ""
    }

    /// MiniMax 的 emotion。认不出、或者这个型号不认（fluent 与 whisper 只有 2.6 认），就是空串，不送
    static func mmEmotion(_ word: String, model: String = "") -> String {
        let e = lookup(moods, word)
        if e.isEmpty { return "" }
        if (e == "fluent" || e == "whisper") && !model.contains("2.6") { return "" }
        return e
    }

    private static func english(_ table: [String: String], _ w: String) -> String {
        let e = lookup(table, w)
        return e.isEmpty ? w.trimmingCharacters(in: .whitespaces) : e
    }

    // MARK: - 各家的写法

    struct Dialect { var pause: String; var sound: String?; var mood: String? }

    static func dialect(_ kind: String, model: String) -> Dialect {
        let m = model.lowercased()
        if kind == "minimax" {
            let soundOK = m.range(of: #"speech-(2\.[89]|[3-9])"#, options: .regularExpression) != nil
            return Dialect(pause: "mm", sound: soundOK ? "paren" : nil, mood: "param")
        }
        if kind == "eleven" {
            return m.contains("v3") ? Dialect(pause: "tag", sound: "tag", mood: "tag") : Dialect(pause: "break", sound: nil, mood: nil)
        }
        return Dialect(pause: "dots", sound: nil, mood: "param")
    }

    /// 切段：情绪走参数的，遇到情绪标记另起一段；连着的停顿合成一个；段首段尾的停顿去掉（两边没有能念的字，MiniMax 会拒）
    static func plan(_ kind: String, _ raw: String, baseMood: String = "", model: String = "") -> [Segment] {
        let d = dialect(kind, model: model)
        var segs: [Segment] = []
        var cur = Segment(mood: baseMood, parts: [])
        func spoken(_ s: Segment) -> Bool { s.parts.contains { $0.t == "text" || $0.t == "sound" } }
        for tk in tokens(raw) {
            if tk.t == "mood" {
                if d.mood == "param" {
                    if spoken(cur) { segs.append(cur) }
                    cur = Segment(mood: tk.v, parts: [])
                } else if d.mood == "tag" {
                    cur.parts.append(tk)
                }
            } else if tk.t == "pause" {
                if let last = cur.parts.last, last.t == "pause" { cur.parts[cur.parts.count - 1].s += tk.s }
                else { cur.parts.append(tk) }
            } else {
                cur.parts.append(tk)
            }
        }
        if spoken(cur) { segs.append(cur) }
        for i in segs.indices {
            while segs[i].parts.first?.t == "pause" { segs[i].parts.removeFirst() }
            while segs[i].parts.last?.t == "pause" { segs[i].parts.removeLast() }
        }
        return segs
    }

    /// 一段写成这一家认的文字
    static func text(_ kind: String, _ seg: Segment, model: String = "") -> String {
        let d = dialect(kind, model: model)
        let out = seg.parts.map { p -> String in
            switch p.t {
            case "text": return p.v
            case "pause":
                switch d.pause {
                case "mm": return "<#\(String(format: "%.2f", min(99.99, max(0.01, p.s))))#>"
                case "break": return " <break time=\"\(String(format: "%.1f", min(3, p.s)))s\" /> "
                case "tag": return p.s < 0.6 ? " [short pause] " : p.s < 1.5 ? " [pause] " : " [long pause] "
                default: return "……"
                }
            case "sound":
                if d.sound == "paren" {
                    let e = lookup(sounds, p.v).isEmpty ? p.v.lowercased() : lookup(sounds, p.v)
                    return mmSounds.contains(e) ? "(\(e))" : ""
                }
                if d.sound == "tag" { return " [\(english(sounds, p.v))] " }
                return ""
            case "mood": return " [\(english(moods, p.v))] "
            default: return ""
            }
        }.joined()
        return out.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
