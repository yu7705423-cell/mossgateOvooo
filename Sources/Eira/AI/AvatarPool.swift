import Foundation

/// 角色的头像库（网页版 avatar.js 的 poolOf / addToPool / wear / restoreFace）。
/// 用户先传几张进去，角色在回复里写 [换头像：名字] 自己挑一张换上。库是空的，这个能力整个不注入。
/// `avatar` 一直是现在在用的那张；第一次被角色换掉时，原来那张记在 `avatarBase`，换回去用它。
enum AvatarPool {
    struct Item: Equatable, Identifiable {
        let imageId: String
        let name: String
        var id: String { imageId }
    }

    static func pool(_ row: Row) -> [Item] {
        (row["avatarPool"]?.array ?? []).compactMap { v in
            let id = v["imageId"]?.string ?? ""
            return id.isEmpty ? nil : Item(imageId: id, name: v["name"]?.string ?? "")
        }
    }

    /// 给模型看的名字单子。空库返回空串
    static func names(_ row: Row) -> String { pool(row).map(\.name).joined(separator: "、") }

    private static func encode(_ items: [Item]) -> JSONValue {
        .array(items.map { .object(["imageId": .string($0.imageId), "name": .string($0.name)]) })
    }

    @discardableResult
    static func add(_ charId: String, imageId: String, name: String) throws -> [Item] {
        guard let c = try Repo.character(charId), !imageId.isEmpty else { return [] }
        var items = pool(c.row)
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        items.append(Item(imageId: imageId, name: trimmed.isEmpty ? "第 \(items.count + 1) 张" : trimmed))
        _ = try People.update(c, ["avatarPool": encode(items)])
        return items
    }

    /// 整份写回（改名用）。名字空着的按位置补「第 N 张」
    static func save(_ charId: String, _ items: [Item]) throws {
        guard let c = try Repo.character(charId) else { return }
        let fixed = items.enumerated().map { i, it in
            let n = it.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return Item(imageId: it.imageId, name: n.isEmpty ? "第 \(i + 1) 张" : String(n.prefix(20)))
        }
        _ = try People.update(c, ["avatarPool": encode(fixed)])
    }

    static func remove(_ charId: String, imageId: String) throws {
        guard let c = try Repo.character(charId) else { return }
        _ = try People.update(c, ["avatarPool": encode(pool(c.row).filter { $0.imageId != imageId })])
    }

    /// 按名字换上一张。认不出名字就不换：凭空换成另一张，用户看到的是一个角色根本没提过的头像
    @discardableResult
    static func wear(_ charId: String, name: String) throws -> Item? {
        guard let c = try Repo.character(charId) else { return nil }
        let q = name.filter { !$0.isWhitespace }
        guard !q.isEmpty else { return nil }
        guard let hit = pool(c.row).first(where: { item in
            let t = item.name.filter { !$0.isWhitespace }
            return !t.isEmpty && (t.contains(q) || q.contains(t))
        }), hit.imageId != c.avatar else { return nil }
        var patch: [String: JSONValue] = ["avatar": .string(hit.imageId)]
        if c.row.string("avatarBase").isEmpty && !c.avatar.isEmpty { patch["avatarBase"] = .string(c.avatar) }
        _ = try People.update(c, patch)
        return hit
    }

    /// 原本那张（没被换过时为空）
    static func base(_ row: Row) -> String {
        let b = row.string("avatarBase")
        return b == row.string("avatar") ? "" : b
    }

    /// 换回原本那张。没换过返回 false
    @discardableResult
    static func restore(_ charId: String) throws -> Bool {
        guard let c = try Repo.character(charId) else { return false }
        let b = base(c.row)
        guard !b.isEmpty else { return false }
        _ = try People.update(c, ["avatar": .string(b), "avatarBase": .string("")])
        return true
    }
}
