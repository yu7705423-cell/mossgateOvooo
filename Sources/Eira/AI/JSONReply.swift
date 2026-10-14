import Foundation

/// 从模型的回复里取出 JSON（网页版 ai/sse.js 的 parseJSON）：
/// 先去掉思考段与 ``` 围栏；照原样解析不了，就修模型常犯的两种写法（字符串里直接换行、收尾前多一个逗号）再试；
/// 还不行，取第一个括号起、配对闭合的那一段。
enum JSONReply {
    static func parse(_ raw: String) -> JSONValue? {
        var text = ReplyParser.stripThink(raw).0
        if text.isEmpty { text = raw }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"```\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = parseText(text) { return v }
        let fixed = mend(text)
        return fixed == text ? nil : parseText(fixed)
    }

    /// 解析不出来时说清楚是哪一种：空的、被截断、写成了别的样子。
    static func failure(_ raw: String) -> String {
        let body = ReplyParser.stripThink(raw).0
        let head = String(body.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "模型没有返回内容（只有思考过程，或回复上限不够）" }
        if body.contains(where: { $0 == "{" || $0 == "[" }),
           let last = body.trimmingCharacters(in: .whitespacesAndNewlines).last, last != "}" && last != "]" {
            return "模型的回复没有写完就被截断。开头：\(head)"
        }
        return "模型返回的内容不是合法 JSON。开头：\(head)"
    }

    private static func parseText(_ text: String) -> JSONValue? {
        if let v = try? JSONValue.parse(Data(text.utf8)), v.object != nil || v.array != nil { return v }
        let chars = Array(text)
        guard let start = chars.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let open: Character = chars[start]
        let close: Character = open == Character("{") ? Character("}") : Character("]")
        var depth = 0, inStr = false, esc = false
        for i in start..<chars.count {
            let c = chars[i]
            if inStr {
                if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false }
                continue
            }
            if c == "\"" { inStr = true; continue }
            if c == open { depth += 1 } else if c == close {
                depth -= 1
                if depth == 0 { return try? JSONValue.parse(Data(String(chars[start...i]).utf8)) }
            }
        }
        return nil
    }

    private static func mend(_ text: String) -> String {
        var out = ""
        var inStr = false, esc = false
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if inStr {
                if esc { esc = false; out.append(c); continue }
                if c == "\\" { esc = true; out.append(c); continue }
                if c == "\"" { inStr = false; out.append(c); continue }
                switch c {
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.append(c)
                }
                continue
            }
            if c == "\"" { inStr = true; out.append(c); continue }
            if c == "," {
                let rest = chars[(i + 1)...].drop(while: { $0.isWhitespace })
                if let next = rest.first, next == "}" || next == "]" { continue }
            }
            out.append(c)
        }
        return out
    }
}
