import Foundation

/// 多选底栏上面那一行的两颗（网页版 Conversation.js 的 pickSpan，ARCHITECTURE 4.757）。
///
/// 用户：「随机指定历史消息的一条然后选到这里（这条下面的全选），或者两条消息中间的全部选择」。
///     往下全选：从勾的最早那一条一直选到最新一条
///     选中间：最早与最晚勾的两条之间全部选上
/// 没有可补的就灰着：只勾了一条时的「选中间」、已经选到最后的「往下全选」。
/// ids 是会话页上排着的顺序（旧的在前）；不在里面的 id（已经删掉的）不算。
enum Picking {
    private static func at(_ ids: [String], _ picked: Set<String>) -> [Int] {
        ids.indices.filter { picked.contains(ids[$0]) }
    }

    /// toEnd 为 true 是「往下全选」，否则是「选中间」。一条都没勾时原样返回
    static func span(ids: [String], picked: Set<String>, toEnd: Bool) -> Set<String> {
        let idx = at(ids, picked)
        guard let a = idx.first, let last = idx.last else { return picked }
        let b = toEnd ? ids.count - 1 : last
        return picked.union(ids[a...b])
    }

    /// 「选中间」能不能点：至少勾了两条，而且中间还有没勾的
    static func spanGap(ids: [String], picked: Set<String>) -> Bool {
        let idx = at(ids, picked)
        guard idx.count >= 2, let a = idx.first, let b = idx.last else { return false }
        return b - a + 1 > idx.count
    }

    /// 「往下全选」能不能点：勾了至少一条，而且从最早那一条往下还有没勾的
    static func belowGap(ids: [String], picked: Set<String>) -> Bool {
        let idx = at(ids, picked)
        guard let a = idx.first else { return false }
        return ids.count - a > idx.count
    }

    /// 补上的那几条按位置排进勾选先后（「选到这里」从最后勾的那一条起算）
    static func order(_ old: [String], ids: [String], picked: Set<String>) -> [String] {
        let have = Set(old)
        return old.filter { picked.contains($0) } + ids.filter { picked.contains($0) && !have.contains($0) }
    }
}
