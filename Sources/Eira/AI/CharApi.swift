import Foundation

/// 每个角色单独的聊天接口（网页版 engine.charPreset，ARCHITECTURE 4.828）。
///
/// 存在角色身上（character.chatApiId，指向「设置 - 接口」里的某一套），入口在单聊的会话菜单「回复用的接口」（第 5 条：改的是这个角色怎么说话）。
/// 默认跟随主用。只管这个角色亲自开口的那几样：聊天回复、通话；其余任务照旧按「设置 - 接口」与「任务用哪套接口」走，群聊照旧用主用。
/// 选的那一套被删了或没填全：改用主用，不报错。「用哪一套」不是「多打一次」，不需要开关（网页版第 15 条）。
extension AppSettings {
    /// 这个角色选的那一套；没选、找不到或没填全为 nil
    func charPreset(_ charId: String) -> ChatPreset? {
        guard !charId.isEmpty, let char = (try? Repo.character(charId)) ?? nil else { return nil }
        let id = char.row.string("chatApiId")
        guard !id.isEmpty, let p = chatPresets.first(where: { $0.id == id }), p.usable else { return nil }
        return p
    }
}

enum CharApi {
    /// 会话菜单那一行写的：选了的那一套的名字，没选写「跟随主用」；选的那套已删除或没填全写明改用主用
    static func label(_ char: Character?, _ s: AppSettings = .load()) -> String {
        let id = char?.row.string("chatApiId") ?? ""
        guard !id.isEmpty else { return "跟随主用" }
        guard let p = s.chatPresets.first(where: { $0.id == id }) else { return "所选接口已删除，改用主用" }
        guard p.usable else { return "所选接口未填全，改用主用" }
        return p.name.isEmpty ? "未命名接口" : p.name
    }

    /// 改这个角色的选择，空串为跟随主用
    static func set(_ charId: String, _ presetId: String) throws {
        guard var c = try Repo.character(charId) else { throw StoreError(message: "这个角色不存在") }
        c.row["chatApiId"] = .string(presetId)
        c.row.touch()
        try Database.shared.put(Collections.characters, c.row)
    }
}
