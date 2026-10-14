import Foundation

/// 角色写 [表情：名字] 时按名字找（网页版 stickers.byName / normalizeName / learnName）。
///
/// 四级：抹平之后精确对、关键词对、去掉所有空白再对、最后才是包含匹配。一个字的名字不做包含匹配。
/// 找不到时气泡上写出它想发的名字，点一下自己指认，那个名字记成关键词，下次就对上了。
enum StickerMatch {
    static let defaultGroup = "默认"

    static func normalize(_ text: String) -> String {
        var t = text.precomposedStringWithCompatibilityMapping
        t = t.replacingOccurrences(of: "[\\u{200B}-\\u{200D}\\u{FEFF}]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\.(png|jpe?g|gif|webp|bmp|apng)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"^[\s"'`「『【\[(（]+|[\s"'`」』】\])）]+$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func group(_ r: Row) -> String {
        let g = r.string("group").trimmingCharacters(in: .whitespaces)
        return g.isEmpty ? defaultGroup : g
    }

    static func keywords(_ r: Row) -> [String] { (r["keywords"]?.array ?? []).compactMap(\.string) }

    static func find(_ name: String, in all: [Row]) -> Row? {
        // 「开心（猫猫）」：两个分组里有重名时，名单里给的就是这个形状
        if let m = try? NSRegularExpression(pattern: #"^(.+?)\s*[（(]([^（()）]+)[)）]\s*$"#)
            .firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let r1 = Range(m.range(at: 1), in: name), let r2 = Range(m.range(at: 2), in: name) {
            let want = normalize(String(name[r1])), g = normalize(String(name[r2]))
            if !want.isEmpty, let hit = all.first(where: { normalize($0.string("name")) == want && normalize(group($0)) == g }) {
                return hit
            }
        }
        let q = normalize(name)
        guard !q.isEmpty else { return nil }
        let nameOf: (Row) -> String = { normalize($0.string("name")) }
        let bare: (String) -> String = { $0.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression) }
        if let r = all.first(where: { nameOf($0) == q }) { return r }
        if let r = all.first(where: { keywords($0).contains { normalize($0) == q } }) { return r }
        if let r = all.first(where: { bare(nameOf($0)) == bare(q) }) { return r }
        guard q.count >= 2 else { return nil }
        return all.first { let n = nameOf($0); return n.count >= 2 && (n.contains(q) || q.contains(n)) }
    }

    /// 指认：这个名字记成那张表情的关键词（最多 12 个），已经认得的不重复记
    @discardableResult
    static func learn(_ stickerId: String, name: String) throws -> Row? {
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, var r = try Database.shared.get("stickers", id: stickerId) else { return nil }
        let kws = keywords(r)
        if (kws + [r.string("name")]).contains(where: { normalize($0) == normalize(raw) }) { return r }
        r["keywords"] = .array((kws + [raw]).prefix(12).map { .string($0) })
        r.touch()
        try Database.shared.put("stickers", r)
        return r
    }

    /// 把一条没认出来的表情消息指向选中的那张
    static func bind(_ m: Message, to sticker: Row) throws -> Message {
        try learn(sticker.id, name: m.row.string("stickerName"))
        var out = m
        out.row["stickerId"] = .string(sticker.id)
        out.row["content"] = .string("[表情：\(sticker.string("name"))]")
        out.row.touch()
        try Repo.save(out)
        return out
    }
}
