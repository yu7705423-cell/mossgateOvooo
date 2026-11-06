import SwiftUI

/// 角色提出见面的那张卡片（网页版 MeetBits，ARCHITECTURE 4.721）：就在这里、单独页面、不去，三选一。选过的写明选了什么
struct MeetCard: View {
    let message: Message
    let char: Character?
    @State private var problem: String?
    @State private var sceneId: String?

    var body: some View {
        let place = message.row["meet"]?["place"]?.string ?? ""
        let state = message.row["meet"]?["state"]?.string ?? Meet.pending
        VStack(alignment: .leading, spacing: Theme.sp2) {
            HStack(spacing: Theme.gap) {
                Image(systemName: "figure.2").foregroundStyle(Theme.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(char?.displayName ?? "对方")想见面").font(.system(size: Theme.bubbleFont, weight: .medium))
                        .foregroundStyle(Theme.bubbleTheirsText)
                    if !place.isEmpty { Text(place).font(.system(size: 13)).foregroundStyle(Theme.text2) }
                }
            }
            if state == Meet.pending {
                HStack(spacing: Theme.sp2) {
                    Button("就在这里") { decide("here") }
                    Button("单独页面") { decide("page") }
                    Button("不去", role: .destructive) { decide("no") }
                }
                .font(.system(size: 13))
                .buttonStyle(.bordered)
                HelpNote("就在这里：切到面对面，还是这段聊天，地点照卡片。单独页面：新建一场线下长文并打开。不去：聊天里落一行「未答应见面」，角色下一轮读到。", title: "见面卡片")
            } else {
                Text(Meet.stateText(message)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                if state == "page", let id = message.row["meet"]?["sceneId"]?.string, Scenes.get(id) != nil {
                    Button("打开这一场") { sceneId = id }.font(.system(size: 13))
                }
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.dangerText) }
        }
        .frame(minWidth: 180, maxWidth: 260, alignment: .leading)
        .padding(Theme.pad)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
        .fullScreenCover(item: Binding(get: { sceneId.map { SceneRef(id: $0) } }, set: { sceneId = $0?.id })) { ref in
            NavigationStack {
                SceneReadView(sceneId: ref.id)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sceneId = nil } } }
            }
        }
    }

    private struct SceneRef: Identifiable { let id: String }

    private func decide(_ how: String) {
        do {
            let id = try Meet.decide(message.id, how)
            problem = nil
            NotificationCenter.default.post(name: .eiraChatChanged, object: message.chatId)
            if !id.isEmpty { sceneId = id }
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
        }
    }
}
