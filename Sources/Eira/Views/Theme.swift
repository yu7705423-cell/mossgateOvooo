import SwiftUI
import UIKit

/// 颜色、圆角、间距、字号集中在这里，视图里不写死（网页版第 4 条：一律来自令牌）。
///
/// 数值照抄网页版新版界面（`styles/tokens.css` 的 :root 与 [data-theme="dark"]、`[data-ui="new"]` 那几项）：
/// 黑白为主，次级文字用黑或白降低不透明度，删除一类用暗红。往后美化包读进来的颜色也覆盖到这里。
enum Theme {
    /// 浅色、深色各一个值
    static func pair(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }

    // MARK: 颜色（--bg、--surface…）
    static let bg = pair(hex(0xFFFFFF), hex(0x000000))
    static let surface = pair(hex(0xFFFFFF), hex(0x0B0B0B))
    static let surface2 = pair(hex(0xF4F4F4), hex(0x141414))
    static let surface3 = pair(hex(0xECECEC), hex(0x1E1E1E))
    static let border = pair(hex(0xEDEDED), hex(0x1A1A1A))
    static let border2 = pair(hex(0xDCDCDC), hex(0x2A2A2A))
    static let text = pair(hex(0x000000), hex(0xFFFFFF))
    static let text2 = pair(hex(0x000000, 0.56), hex(0xFFFFFF, 0.58))
    static let text3 = pair(hex(0x000000, 0.34), hex(0xFFFFFF, 0.36))
    static let accent = text
    static let onAccent = bg
    /// 删除一类：暗红文字。黑白里唯一的颜色，只给不能撤销的操作（新版 --danger-text）
    static let dangerText = pair(hex(0xA8322A), hex(0xE8968F))
    /// 分组胶囊：极浅的灰底，不描边
    static let groupFill = pair(hex(0xF5F5F5), hex(0x121212))
    static let groupLine = pair(hex(0x000000, 0.07), hex(0xFFFFFF, 0.08))
    /// 默认头像与无图格子的底（--cat-bg）
    static let catBg = pair(hex(0xEDEDEC), hex(0x222224))

    // 旧名字照旧能用，指到新令牌上
    static let background = bg
    static let groupedBackground = surface2
    static let bubbleMine = accent
    static let bubbleMineText = onAccent
    static let bubbleTheirs = surface
    static let bubbleTheirsText = text
    static let secondaryText = text2
    static let tertiaryText = text3
    static let danger = dangerText
    static let placeholder = catBg

    // MARK: 圆角（--r-*）
    static let rXs: CGFloat = 6
    static let rSm: CGFloat = 10
    static let rMd: CGFloat = 14
    static let rLg: CGFloat = 18
    static let rXl: CGFloat = 24
    /// 新版按钮的圆角（--r-btn）
    static let rBtn: CGFloat = 12

    // MARK: 间距（--sp-*）
    static let sp1: CGFloat = 4
    static let sp2: CGFloat = 8
    static let sp3: CGFloat = 12
    static let sp4: CGFloat = 16
    static let sp5: CGFloat = 20
    static let sp6: CGFloat = 24
    static let sp8: CGFloat = 32

    // MARK: 会话（--bubble-*、--composer-h）
    static let bubbleRadius: CGFloat = rMd
    static let bubblePadX: CGFloat = sp3
    static let bubblePadY: CGFloat = sp2
    static let bubbleFont: CGFloat = 14
    static let composerH: CGFloat = 38
    static let avatarSize: CGFloat = 36
    static let listAvatarSize: CGFloat = 46

    static let gap: CGFloat = sp2
    static let pad: CGFloat = sp3

    // MARK: 字
    /// 新版的标题宋体（思源宋体 600，网页版 vendor/fonts/noto-serif-sc 合成一份）
    static let serifName = "EiraSerif-SemiBold"
    static func serif(_ size: CGFloat) -> Font { .custom(serifName, fixedSize: size) }
    static func serifUI(_ size: CGFloat) -> UIFont {
        UIFont(name: serifName, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }
    /// 正文默认字号：新版列表标题 15 + 1
    static let bodySize: CGFloat = 16

    /// 全局的样子：顶栏（宋体大标题、17 号小标题、不画分隔线）、列表底色。启动时调一次。
    static func install() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(bg)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: UIColor(text)]
        nav.largeTitleTextAttributes = [.font: serifUI(30), .foregroundColor: UIColor(text), .kern: 0.6]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = UIColor(text)
    }
}

extension View {
    /// 新版界面的全局默认：正文 16 号、按钮与开关用文字色（黑白）、列表不垫系统的灰底，露出页面底色。
    func eiraLook() -> some View {
        self
            .font(.system(size: Theme.bodySize))
            .tint(Theme.text)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
    }
}

extension View {
    /// 列表里的一行，放在网页版那种浅灰分组胶囊里（.capsule，--group-fill），行间一条发丝线
    func eiraRow() -> some View {
        listRowBackground(Theme.groupFill).listRowSeparatorTint(Theme.groupLine)
    }
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

/// 没有图时的占位（网页版新版的 cat-face / cat-full）：应用图标那只猫，头像取脸、格子取整只。
struct CatFill: View {
    var full = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let name = "cat-\(full ? "full" : "face")-\(scheme == .dark ? "dark" : "light")"
        ZStack {
            Theme.catBg
            if let img = UIImage(named: name) {
                if full {
                    GeometryReader { g in
                        Image(uiImage: img).resizable().scaledToFit()
                            .frame(width: min(g.size.width, g.size.height) * 0.38)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    Image(uiImage: img).resizable().scaledToFit()
                }
            }
        }
    }
}

/// 头像（网页版 .avatar）：圆角方形，边长 44 时圆角 14，按比例缩放。没有图时显示那只猫。
struct Avatar: View {
    let imageId: String
    let name: String
    var size: CGFloat = Theme.avatarSize

    var body: some View {
        Group {
            if !imageId.isEmpty, MediaStore.url(.images, id: imageId) != nil {
                LocalImage(id: imageId, maxPixel: size * 3)
            } else {
                CatFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 14 / 44, style: .continuous))
        .accessibilityLabel(name)
    }
}

/// 空状态（新版 .empty）：往下放，宋体一句标题，说明一行。
struct EmptyState: View {
    let title: String
    var desc: String = ""

    var body: some View {
        VStack(spacing: Theme.sp2) {
            Text(title).font(Theme.serif(20)).foregroundStyle(Theme.text)
            if !desc.isEmpty {
                Text(desc).font(.system(size: 13)).foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center).frame(maxWidth: 280)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
        .padding(.horizontal, Theme.sp6)
        .padding(.bottom, Theme.sp8)
    }
}

/// 新版按钮（方案 A）：主按钮描边，其余是文字，删除是暗红文字。没有填色的按钮。
struct EiraButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, danger }
    var kind: Kind = .primary
    var full = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: kind == .ghost ? .medium : .semibold))
            .foregroundStyle(kind == .danger ? Theme.dangerText : Theme.text)
            .padding(.horizontal, Theme.sp4)
            .frame(maxWidth: full ? .infinity : nil, minHeight: 44)
            .background {
                if kind == .primary {
                    RoundedRectangle(cornerRadius: Theme.rBtn, style: .continuous).strokeBorder(Theme.text, lineWidth: 1.2)
                }
            }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
