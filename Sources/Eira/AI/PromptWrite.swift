import Foundation

/// 把角色随手写的那一句改写成一份真正能用的生成提示词（网页版 ai/promptwrite.js）。
///
/// 角色写 `[图片：乃木喵和调色盘]`，生图模型收不到这段对话，「乃木喵」对它只是三个字。
/// 这一步把只有这段对话里成立的说法翻成一份自带全部信息的描述。
/// **是实打实的第二次接口调用**（第 15 条）：默认关，登记在 ExtraCalls；走副用接口。
/// 写不出来就用原话：为了改写把整张图断掉，比不改写更糟。
enum PromptWrite {
    static func imageOn(_ s: AppSettings = .load()) -> Bool { s.raw["writeImagePrompt"]?.bool == true }
    static func voiceOn(_ s: AppSettings = .load()) -> Bool { s.raw["writeVoicePrompt"]?.bool == true }

    /// 拿给改写用的上下文：角色名、一段设定、最近十几条对话
    static func context(chatId: String, char: Character?) -> String {
        var bits: [String] = []
        if let c = char, !c.name.isEmpty { bits.append("[角色]\n\(c.name)") }
        let persona = (char?.persona ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !persona.isEmpty { bits.append("[角色设定]\n\(persona.prefix(600))") }
        if !chatId.isEmpty {
            let recent = ((try? Repo.messages(chatId: chatId, limit: 12)) ?? []).map { m -> String in
                let who = m.role == .user ? "对方" : (((try? Repo.character(m.authorId)) ?? nil)?.name ?? "角色")
                return "\(who)：\(m.content)"
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !recent.isEmpty { bits.append("[最近的对话]\n\(recent)") }
        }
        return bits.joined(separator: "\n\n")
    }

    static func write(task: String, template: String, vars: [String: String]) async throws -> String {
        let s = AppSettings.load()
        let r = try await AIService.shared.send(task: task, system: Templates.render(template, vars, settings: s),
                                                messages: [AIMessage(role: .user, content: "Write it as instructed. Output the result only.")],
                                                maxTokens: 500)
        // 模型爱加一层代码块或引号
        var out = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.replacingOccurrences(of: #"^\s*```[a-zA-Z]*\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"```\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^["'「『]|["'」』]$"#, with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 生图那一句。回来的仍是一段画面描述，后面照旧接世界书与全局提示词
    static func forImage(_ desc: String, chatId: String, char: Character?) async -> String {
        let raw = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard imageOn(), !raw.isEmpty else { return raw }
        do {
            let out = try await write(task: "image.prompt", template: "task.image-prompt",
                                      vars: ["desc": raw, "context": context(chatId: chatId, char: char), "ask": ImageGen.styleAsk(.load())])
            return out.isEmpty ? raw : out
        } catch {
            Diagnostics.shared.record("image-prompt-failed", ["error": error.localizedDescription])
            return raw
        }
    }
}
