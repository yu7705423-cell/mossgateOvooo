import Foundation

/// 账号之间隔离（网页版 system/isolate.js，ARCHITECTURE 4.960、4.961）。
///
/// 账号上 `persona.isolate = { moments, friends, wallet, album }`，为真的那一项与别的账号分开。
/// 隔离的账号只看自己这边的；不隔离的账号看所有不隔离账号的，看不见隔离账号的。没有记号的老记录算第一个大号的。
/// 支线人设（fateLine）按它的根账号算。
///
/// 原生版眼下只有记账与钱包读它（`Ledger.visible`、卡包里列出的角色）；账号页上的开关与新账号的默认值随「账号之间隔离」一起做。
enum Isolate {
    static let keys = ["moments", "friends", "wallet", "album"]

    /// 大号，按建立的先后（网页版 accounts.roots）
    static func roots(_ all: [Persona]) -> [Persona] {
        all.filter { ($0.parentId ?? "").isEmpty }.sorted { ($0.row.created ?? 0) < ($1.row.created ?? 0) }
    }

    /// 当前账号（网页版 accounts.current：activePersonaId 找不到就取第一个大号）
    static func current(_ all: [Persona], _ s: AppSettings) -> Persona? {
        if let id = s.raw["activePersonaId"]?.string, let p = all.first(where: { $0.id == id }) { return p }
        return roots(all).first
    }

    /// 这个账号按谁算：支线人设算它的根账号（网页版 keyOf）。小号只往上找一层（accounts.rootOf）
    static func keyOf(_ personaId: String, _ all: [Persona]) -> String {
        guard let p = all.first(where: { $0.id == personaId }) else { return personaId }
        guard Ledger.truthy(p.row["fateLine"]) else { return p.id }
        if let parent = p.parentId, !parent.isEmpty, let root = all.first(where: { $0.id == parent }) { return root.id }
        return p.id
    }

    static func isolated(_ personaId: String, _ key: String, _ all: [Persona]) -> Bool {
        let k = keyOf(personaId, all)
        return all.first { $0.id == k }?.row["isolate"]?[key]?.bool == true
    }

    private static func firstRoot(_ all: [Persona]) -> String { roots(all).first?.id ?? "" }

    /// 新记录记哪个账号（网页版 tagNow）
    static func tagNow(_ s: AppSettings = .load()) -> String {
        let all = (try? Repo.personas()) ?? []
        return keyOf(current(all, s)?.id ?? "", all)
    }

    /// 一行带账号记号（personaId）的东西，这个账号看不看得见（网页版 seesRow）
    static func sees(personaId rowPid: String, _ key: String, viewer: String? = nil, all: [Persona]? = nil, settings s: AppSettings = .load()) -> Bool {
        let ps = all ?? ((try? Repo.personas()) ?? [])
        let v = keyOf(viewer ?? current(ps, s)?.id ?? "", ps)
        let tag = keyOf(rowPid.isEmpty ? firstRoot(ps) : rowPid, ps)
        if tag == v { return true }
        if isolated(v, key, ps) { return false }
        return !isolated(tag, key, ps)
    }

    /// 好友列表里这个角色，这个账号看不看得见（网页版 seesChar）
    static func seesChar(_ char: Character?, viewer: String? = nil, settings s: AppSettings = .load()) -> Bool {
        guard let char else { return false }
        let ps = (try? Repo.personas()) ?? []
        let v = keyOf(viewer ?? current(ps, s)?.id ?? "", ps)
        if !isolated(v, "friends", ps) { return true }
        if char.row.strings("friendOf").contains(v) { return true }
        let first = firstRoot(ps)
        return ((try? Repo.chats()) ?? []).contains {
            keyOf($0.personaId.isEmpty ? first : $0.personaId, ps) == v && $0.characterIds.contains(char.id)
        }
    }
}
