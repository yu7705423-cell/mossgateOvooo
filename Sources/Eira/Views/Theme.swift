import SwiftUI
import UIKit

/// 颜色、圆角、间距、字号集中在这里，视图里不写死（网页版第 4 条：一律来自令牌）。
/// 往后美化包读进来的颜色与尺寸也覆盖到这里。
enum Theme {
    static let background = Color(uiColor: .systemBackground)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let bubbleMine = Color(uiColor: .label)
    static let bubbleMineText = Color(uiColor: .systemBackground)
    static let bubbleTheirs = Color(uiColor: .secondarySystemBackground)
    static let bubbleTheirsText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let danger = Color(red: 0.62, green: 0.16, blue: 0.16)
    static let placeholder = Color(uiColor: .tertiarySystemFill)

    static let bubbleRadius: CGFloat = 16
    static let avatarSize: CGFloat = 36
    static let listAvatarSize: CGFloat = 48
    static let gap: CGFloat = 8
    static let pad: CGFloat = 12
}

/// 本地图片。按 id 在后台读、按 maxPixel 缩小着解码；读出来之前和读不到时显示占位块。
struct LocalImage: View {
    let id: String
    var maxPixel: CGFloat = 600
    var fit = false
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                if fit { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(uiImage: image).resizable().scaledToFill() }
            } else {
                Theme.placeholder
            }
        }
        .task(id: id) { image = await Images.load(id, maxPixel: maxPixel) }
    }
}

/// 圆形头像。没有图时显示名字的第一个字。
struct Avatar: View {
    let imageId: String
    let name: String
    var size: CGFloat = Theme.avatarSize

    var body: some View {
        Group {
            if !imageId.isEmpty, MediaStore.url(.images, id: imageId) != nil {
                LocalImage(id: imageId, maxPixel: size * 3)
            } else {
                ZStack {
                    Theme.placeholder
                    Text(String(name.prefix(1))).font(.system(size: size * 0.42)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
