import Foundation

/// 回复失败那一条下方的链接（网页版 FailNote 与 services.presetLinks）。
/// 失败的那几套里填了链接的：余额不足给「去充值」，别的错误给「打开站点」。链接在「设置 - 接口」里各套自己填。
enum FailLinks {
    struct Row: Equatable {
        var id: String
        var label: String
        var url: URL
    }

    static func of(_ m: Message, settings s: AppSettings) -> (broke: Bool, rows: [Row]) {
        var seen = Set<String>()
        let failed: [(id: String, balance: Bool)] = (m.row["failedPresets"]?.array ?? []).compactMap { v in
            guard let id = v["id"]?.string, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return (id, v["balance"]?.bool == true)
        }
        let presets = s.chatPresets
        let known = failed.compactMap { f in presets.first { $0.id == f.id }.map { (f, $0) } }
        let broke = known.contains { $0.0.balance }
        let links: [(Bool, ChatPreset, URL)] = known.compactMap { f, p in
            (f.balance ? p.topup : p.site).map { (f.balance, p, $0) }
        }
        let many = links.count > 1
        let rows = links.map { balance, p, url in
            Row(id: p.id, label: (balance ? "去充值" : "打开站点") + (many ? "（\(p.name.isEmpty ? "接口" : p.name)）" : ""), url: url)
        }
        return (broke, rows)
    }
}
