import Foundation

/// 长按菜单里把角色的一条文字改成别的样子（网页版 MsgMenu 的 toPhotoText 与 reply.js 的 toVoice，ARCHITECTURE 4.799、4.881）。
///
/// - 改为文字图：和我「用文字发一张图」同一种东西（kind image、media text、没有图文件），角色读到的是自己那一侧的 [图片：原文]。
///   描述放在 imageDesc、prompt 留空：重画、重新生成时留图都只认 prompt，这一条永远不会被送去生图。不调接口。
/// - 改为语音：用这个角色的音色把原文念一遍，变成语音消息（原文进 voiceText），调一次语音接口；用户点了才调，不需要开关（第 15 条）。
/// 两样的原文都留在 textBefore，「改回文字」一字不差地恢复。
enum MsgConvert {
    /// 角色的一条纯文字：才有「改为文字图」「改为语音」
    static func canConvert(_ m: Message) -> Bool {
        m.role == .char && m.kind == "text" && !m.isError && !m.isRecalled
            && !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && m.content.range(of: #"<\s*(html|div|style|body|svg)\b"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// 由「改为文字图」改过来的那一条
    static func isTextImage(_ m: Message) -> Bool {
        m.kind == "image" && m.role == .char && m.row.string("media") == "text" && m.imageId.isEmpty
    }

    /// 由「改为语音」改过来的那一条
    static func isVoiced(_ m: Message) -> Bool {
        m.kind == "voice" && m.role == .char && m.row["textBefore"]?.string != nil
    }

    private static func save(_ id: String, _ change: (inout Row) -> Void) throws -> Message {
        guard var row = try Database.shared.get(Collections.messages, id: id) else { throw StoreError(message: "这条消息不存在") }
        change(&row)
        row.touch()
        try Database.shared.put(Collections.messages, row)
        return Message(row: row)
    }

    static func toTextImage(_ m: Message) throws -> Message {
        guard canConvert(m) else { throw StoreError(message: "这条消息不能改为文字图") }
        let t = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return try save(m.id) {
            $0["kind"] = .string("image")
            $0["imageId"] = .null
            $0["prompt"] = .string("")
            $0["media"] = .string("text")
            $0["imageDesc"] = .string(t)
            $0["content"] = .string("[图片：\(t)]")
            $0["textBefore"] = .string(m.content)
        }
    }

    static func fromTextImage(_ m: Message) throws -> Message {
        guard isTextImage(m) else { throw StoreError(message: "这条消息不是由文字改成的图") }
        let t = m.row["textBefore"]?.string ?? m.row.string("imageDesc")
        return try save(m.id) {
            $0["kind"] = .string("text")
            $0["content"] = .string(t)
            for k in ["imageDesc", "media", "prompt", "textBefore", "imageId"] { $0[k] = nil }
        }
    }

    /// 改成语音并合成一次。返回改好的那一条（合成的结果另由 VoiceGen 写回）；没配语音接口、这个角色没有音色时不改、不调
    static func toVoice(_ m: Message, settings s: AppSettings = .load()) throws -> Message {
        guard canConvert(m) else { throw StoreError(message: "这条消息不能改为语音") }
        guard s.voiceReady else { throw StoreError(message: "尚未配置语音接口，请先在「设置 - 接口与服务 - 语音」中填写") }
        guard let char = try Repo.character(m.authorId), let p = s.activeVoice, !VoiceGen.voiceId(char, presetId: p.id).isEmpty else {
            throw StoreError(message: "该角色在当前语音接口上尚未填写音色，请在角色卡中填写")
        }
        let text = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return try save(m.id) {
            $0["kind"] = .string("voice")
            $0["content"] = .string("[语音：\(text)]")
            $0["voiceText"] = .string(text)
            $0["audioId"] = .null
            $0["media"] = .string("pending")
            $0["mediaError"] = .string("")
            $0["textBefore"] = .string(m.content)
        }
    }

    /// 改为语音之后合成那一次（一条一次语音接口）
    @discardableResult
    static func speak(_ id: String) async -> Message? { await VoiceGen.fill(messageId: id) }

    /// 改回文字：只认由「改为语音」改过来的那几条。念好的那段音频不再挂在消息上（原生版不自己删文件）
    static func fromVoice(_ m: Message) throws -> Message {
        guard isVoiced(m) else { throw StoreError(message: "这条消息不是由文字改成的语音") }
        let t = m.row["textBefore"]?.string ?? m.row.string("voiceText")
        return try save(m.id) {
            $0["kind"] = .string("text")
            $0["content"] = .string(t)
            $0["mediaError"] = .string("")
            for k in ["voiceText", "audioId", "media", "voiceScript", "textBefore"] { $0[k] = nil }
        }
    }
}
