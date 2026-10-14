import Foundation

/// 识图选了「单独的接口」时：用户发的图先交给识图接口读成一段描述，写回那条消息（网页版 Conversation.js 的 postImage）。
///
/// 每张图一次请求，是用户在「设置 - 识图」里选的这一档本身的花法。失败了标成 error，不自动再读：
/// 重试次数取 1 与用户的 retryMax 里较小的那个（默认 0），和网页版 vision.js 一样。
enum Vision {
    /// 描述写回之后，界面据此刷新那一条。
    static func describe(messageId: String) async throws -> Message? {
        let s = AppSettings.load()
        guard s.visionMode == "api", let preset = s.visionPreset,
              let row = try Database.shared.get(Collections.messages, id: messageId) else { return nil }
        let m = Message(row: row)
        guard m.kind == "image", !m.imageId.isEmpty, row.string("vision") == "pending" else { return nil }
        do {
            guard let url = MediaStore.url(.images, id: m.imageId) else { throw StoreError(message: "图片已不存在") }
            let data = try Data(contentsOf: url)
            let system = Templates.render("task.vision-describe", ["sample": sample(chatId: m.chatId)], settings: s)
            let image = AIImage(mediaType: Images.mediaType(ext: url.pathExtension), base64: data.base64EncodedString())
            let r = try await AIService.shared.send(
                task: "vision", preset: preset, system: system,
                messages: [AIMessage(role: .user, content: "Describe this image as instructed.", images: [image])],
                maxTokens: 500, retries: 1)
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw StoreError(message: "识图接口没有返回内容") }
            return try update(messageId) {
                $0["imageDesc"] = .string(text)
                $0["vision"] = .string("done")
                $0["content"] = .string("[图片：\(text)]")
            }
        } catch {
            _ = try? update(messageId) {
                $0["vision"] = .string("error")
                $0["visionError"] = .string(error.localizedDescription)
            }
            throw error
        }
    }

    /// 一小段原文，告诉模型这段对话是什么语言：先拿最近说的话，没有就拿角色卡（网页版 engine.js 的 langSampleOf）。
    static func sample(chatId: String) -> String {
        let list = ((try? Repo.messages(chatId: chatId)) ?? []).filter { $0.kind == "text" && !$0.content.isEmpty }
        let recent = list.suffix(3).map(\.content).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !recent.isEmpty { return String(recent.prefix(200)) }
        guard let chat = try? Repo.chat(chatId), let id = chat.characterIds.first,
              let char = try? Repo.character(id) else { return "" }
        return String((char.persona.isEmpty ? char.name : char.persona).prefix(200))
    }

    private static func update(_ id: String, _ change: (inout Row) -> Void) throws -> Message? {
        guard var row = try Database.shared.get(Collections.messages, id: id) else { return nil }
        change(&row)
        row.touch()
        try Database.shared.put(Collections.messages, row)
        return Message(row: row)
    }
}
