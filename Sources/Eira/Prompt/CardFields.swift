import Foundation

/// 编辑资料上「从人设中生成 / 提取」的三个按钮（网页版 ai/tasks/card.js 的 makeCore、makeExamples、makeAppearance，ARCHITECTURE 4.590）。
///
/// 用户点了才调，每次一次接口，不自动重试，不进 ExtraCalls（网页版第 15 条：手动的一次调用不是「一条消息变成两次」）。
/// 记账的任务名照网页版：card.core、card.examples、card.appearance。
/// 失败照实抛出，由界面写在屏幕上（导入确认页那一处用的是 CardImport.makeCore，失败回空串，两处各管各的）。
enum CardFields {
    enum Kind: String, CaseIterable, Sendable {
        case core, examples, appearance

        /// 提示词模板（Resources/templates.json，从网页版搬来）
        var template: String {
            switch self {
            case .core: return "task.core"
            case .examples: return "task.examples"
            case .appearance: return "task.appearance"
            }
        }

        /// 记账用的任务名，与网页版 runTextTask 的第一个参数一字不差
        var task: String { "card.\(rawValue)" }

        /// 写回角色卡的字段
        var field: String {
            switch self {
            case .core: return "core"
            case .examples: return "exampleDialogue"
            case .appearance: return "appearance"
            }
        }

        var label: String {
            switch self {
            case .core: return "核心设定"
            case .examples: return "对话示例"
            case .appearance: return "外貌"
            }
        }
    }

    /// 读人设调一次接口。人设为空不发请求，抛出原因；接口回了空也抛出，不拿空串去盖那一栏。
    /// 人设整段送去，回来的也不截（网页版 4.571）
    static func make(_ kind: Kind, persona: String) async throws -> String {
        let text = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw StoreError(message: kind == .appearance ? "人设是空的，没有可提取的内容" : "人设是空的，无法生成")
        }
        let s = AppSettings.load()
        let system = Templates.render(kind.template, ["persona": text], settings: s)
        let r = try await AIService.shared.send(task: kind.task, system: system,
                                                messages: [AIMessage(role: .user, content: "Produce the output as instructed.")])
        let out = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else {
            throw StoreError(message: kind == .appearance ? "这段人设里没有写到外貌" : "没有生成内容")
        }
        return out
    }
}
