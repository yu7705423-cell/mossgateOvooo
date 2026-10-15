import Foundation

/// 从接口拉模型列表（网页版 ai/models.js）。各家路径不同，返回都归一成一串 id。
/// 只是读一份列表，不调用模型，不计进请求次数。
enum ModelList {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func fetch(provider: String, baseUrl: String, apiKey: String) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure(message: "请先填写密钥") }
        var base = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        var req: URLRequest
        if provider == "anthropic" {
            if base.isEmpty { base = "https://api.anthropic.com" }
            guard let u = URL(string: base + "/v1/models?limit=200") else { throw Failure(message: "接口地址无效") }
            req = URLRequest(url: u)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            if base.isEmpty { base = "https://api.openai.com/v1" }
            let path = base.range(of: #"/v\d+$"#, options: .regularExpression) != nil ? "/models" : "/v1/models"
            guard let u = URL(string: base + path) else { throw Failure(message: "接口地址无效") }
            req = URLRequest(url: u)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        req.timeoutInterval = 30
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw Failure(message: "连不上接口：\(error.localizedDescription)") }
        let json = try? JSONValue.parse(data)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = json?["error"]?["message"]?.string ?? json?["message"]?.string ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw Failure(message: "接口返回 \(status)：\(detail)")
        }
        return normalize(json)
    }

    static func normalize(_ json: JSONValue?) -> [String] {
        let rows = json?["data"]?.array ?? json?["models"]?.array ?? json?.array ?? []
        return rows.compactMap { m in
            if let s = m.string { return s }
            return m["id"]?.string ?? m["model_id"]?.string ?? m["name"]?.string ?? m["model"]?.string
        }
    }

    /// 简单的模糊匹配：包含的排前面，其次按顺序出现的子序列
    static func filter(_ list: [String], _ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        var scored: [(Int, String)] = []
        for id in list {
            let s = id.lowercased()
            if s.contains(q) { scored.append((0, id)); continue }
            var rest = Substring(s)
            var ok = true
            for ch in q {
                guard let i = rest.firstIndex(of: ch) else { ok = false; break }
                rest = rest[rest.index(after: i)...]
            }
            if ok { scored.append((1, id)) }
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.1)
    }
}
