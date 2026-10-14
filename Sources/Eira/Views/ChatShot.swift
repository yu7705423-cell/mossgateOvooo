import Photos
import SwiftUI

/// 多选之后「存为图片」（网页版 shotPicked）：选中的几条画成一张长图，存到「照片」。
/// 网页版存进应用内相册；原生版还没有应用内相册，存到系统的「照片」。只要「添加照片」这一项权限，不读相册。
@MainActor
enum ChatShot {
    struct Line: Identifiable {
        var id: String
        var who: String
        var mine: Bool
        var text: String
        var image: UIImage?
    }

    /// 选中的几条按时间排好，图先读出来（画的时候不能再等）
    static func lines(_ msgs: [Message], nameOf: (Message) -> String) async -> [Line] {
        var out: [Line] = []
        for m in msgs.sorted(by: { $0.createdAt < $1.createdAt }) {
            var img: UIImage?
            if m.kind == "image" && !m.imageId.isEmpty { img = await Images.load(m.imageId, maxPixel: 800) }
            let body = MessageActions.bodyText(m)
            let text = m.isRecalled ? "[已撤回]" : (body.isEmpty ? m.content : body)
            out.append(Line(id: m.id, who: nameOf(m), mine: m.role == .user, text: img == nil ? text : "", image: img))
        }
        return out
    }

    static func render(_ lines: [Line], title: String) -> UIImage? {
        let view = Card(lines: lines, title: title)
        let r = ImageRenderer(content: view)
        r.scale = 3
        r.proposedSize = ProposedViewSize(width: 390, height: nil)
        return r.uiImage
    }

    /// 存到「照片」，回给界面上要说的那一句
    static func save(_ image: UIImage) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "没有添加照片的权限。可在「设置 - Eiraowo - 照片」中开启。"
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAsset(from: image)
            }
            return "已存到照片。"
        } catch {
            return "保存失败：\(error.localizedDescription)"
        }
    }

    /// 画出来的那张：标题、一条一条的气泡，我在右、对方在左
    struct Card: View {
        let lines: [Line]
        let title: String

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.sp3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                ForEach(lines) { l in
                    VStack(alignment: l.mine ? .trailing : .leading, spacing: 3) {
                        Text(l.who).font(.system(size: 11)).foregroundStyle(Theme.text3)
                        if let img = l.image {
                            Image(uiImage: img).resizable().scaledToFit()
                                .frame(maxWidth: 220, maxHeight: 280)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
                        } else {
                            Text(l.text).font(.system(size: 15))
                                .foregroundStyle(l.mine ? Theme.bubbleMineText : Theme.bubbleTheirsText)
                                .padding(.horizontal, Theme.bubblePadX).padding(.vertical, Theme.bubblePadY)
                                .background(l.mine ? Theme.bubbleMine : Theme.bubbleTheirs,
                                            in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
                                .frame(maxWidth: 280, alignment: l.mine ? .trailing : .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: l.mine ? .trailing : .leading)
                }
            }
            .padding(Theme.sp5)
            .frame(width: 390)
            .background(Theme.bg)
        }
    }
}
