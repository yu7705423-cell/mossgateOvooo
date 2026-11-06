import SwiftUI

/// 角色截下的聊天记录画成一张（网页版 ui/chatshot.js 的 ShotThumb，ARCHITECTURE 4.904）。
/// 画的是冻起来的消息副本：截图的主人（角色）在右边，你在左边。原生版不跑当时的美化 CSS，按原生的气泡画
struct CharShotCard: View {
    let msgs: [JSONValue]
    var note = ""
    /// 缩略：只画前几条，字号小一号
    var limit = 0

    var body: some View {
        let all = CharShot.lines(msgs)
        let lines = limit > 0 ? Array(all.prefix(limit)) : all
        VStack(alignment: .leading, spacing: limit > 0 ? 4 : Theme.sp2) {
            ForEach(lines) { l in
                VStack(alignment: l.right ? .trailing : .leading, spacing: 2) {
                    if limit == 0 && !l.name.isEmpty {
                        Text(l.name).font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                    content(l)
                }
                .frame(maxWidth: .infinity, alignment: l.right ? .trailing : .leading)
            }
            if limit > 0 && all.count > lines.count {
                Text("共 \(all.count) 条").font(.system(size: 10)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(limit > 0 ? Theme.sp2 : Theme.sp4)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
    }

    @ViewBuilder private func content(_ l: CharShot.Line) -> some View {
        let size: CGFloat = limit > 0 ? 11 : 15
        if !l.imageId.isEmpty && limit == 0 {
            LocalImage(id: l.imageId, maxPixel: 600, fit: true)
                .frame(maxWidth: 200, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
        } else {
            Text(l.text.isEmpty ? "[消息]" : l.text).font(.system(size: size))
                .lineLimit(limit > 0 ? 2 : nil)
                .foregroundStyle(l.right ? Theme.bubbleMineText : Theme.bubbleTheirsText)
                .padding(.horizontal, limit > 0 ? 6 : Theme.bubblePadX).padding(.vertical, limit > 0 ? 3 : Theme.bubblePadY)
                .background(l.right ? Theme.bubbleMine : Theme.bubbleTheirs,
                            in: RoundedRectangle(cornerRadius: limit > 0 ? 8 : Theme.bubbleRadius, style: .continuous))
                .frame(maxWidth: limit > 0 ? 150 : 280, alignment: l.right ? .trailing : .leading)
        }
    }
}

/// 聊天里那一条（kind charshot）：说明一行，下面一张缩略，点开看整张
struct CharShotBubble: View {
    let message: Message
    @State private var open = false

    var body: some View {
        let shot = message.row["shot"]?.object ?? [:]
        let msgs = shot["msgs"]?.array ?? []
        let note = shot["note"]?.string ?? ""
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            Button { open = true } label: {
                VStack(alignment: .leading, spacing: Theme.sp1) {
                    Text(note.isEmpty ? "聊天截图" : note).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                    CharShotCard(msgs: msgs, limit: 4)
                }
                .frame(width: 200)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("聊天截图：\(note)")
            if message.role != .user { Spacer(minLength: 60) }
        }
        .padding(.horizontal, Theme.sp4)
        .sheet(isPresented: $open) {
            NavigationStack {
                ScrollView { CharShotCard(msgs: msgs).padding(Theme.sp4) }
                    .background(Theme.background)
                    .navigationTitle(note.isEmpty ? "聊天截图" : note)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { open = false } } }
            }
        }
    }
}
