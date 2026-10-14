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
        // 返回：网页版顶栏左上角那个细线左箭头（chevronLeft，22），不带上一页的标题
        let back = SvgShapes.uiImage("chevronLeft", size: 22)
        nav.setBackIndicatorImage(back, transitionMaskImage: back)
        let hidden: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.clear, .font: UIFont.systemFont(ofSize: 0.1)]
        nav.backButtonAppearance.normal.titleTextAttributes = hidden
        nav.backButtonAppearance.highlighted.titleTextAttributes = hidden
        // 顶栏的文字按钮（取消、保存）：网页版 .nav-text，14 号文字色
        let plain = UIBarButtonItemAppearance()
        plain.normal.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor(text)]
        nav.buttonAppearance = plain
        let done = UIBarButtonItemAppearance()
        done.normal.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: UIColor(text)]
        nav.doneButtonAppearance = done
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = UIColor(text)
        // 分段选择（.segmented）：浅灰底，选中的那一格白底，13 号字
        let seg = UISegmentedControl.appearance()
        seg.backgroundColor = UIColor(surface2)
        seg.selectedSegmentTintColor = UIColor(surface)
        seg.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor(text2)], for: .normal)
        seg.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: UIColor(text)], for: .selected)
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
    /// 圆角（nil 为默认的 14/44）
    var radius: CGFloat?

    var body: some View {
        Group {
            if !imageId.isEmpty, MediaStore.url(.images, id: imageId) != nil {
                LocalImage(id: imageId, maxPixel: size * 3)
            } else {
                CatFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius ?? size * 14 / 44, style: .continuous))
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

/// 一级页的大标题（新版 Page 的 hero）：上面一行眉题，下面宋体大标题。
/// 放在列表最前面；滚出屏幕之后顶栏的小标题才出现（.page.has-hero:not(.is-scrolled) .nav-title { opacity: 0 }）。
struct HeroHeader: View {
    let eyebrow: String
    let title: String
    @Binding var shown: Bool

    private var cjk: Bool { eyebrow.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !eyebrow.isEmpty {
                Text(cjk ? eyebrow : eyebrow.uppercased())
                    .font(.system(size: 11, weight: cjk ? .regular : .semibold))
                    .kerning(cjk ? 0.44 : 2.2)
                    .foregroundStyle(cjk ? Theme.text2 : Theme.text3)
            }
            Text(title).font(Theme.serif(30)).kerning(0.6).foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.sp1)
        .padding(.bottom, Theme.sp2)
        .onAppear { shown = true }
        .onDisappear { shown = false }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: Theme.sp4, bottom: 0, trailing: Theme.sp4))
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// 配合 HeroHeader：顶栏只放小标题，大标题还在屏幕上时小标题藏起来
    func heroTitle(_ title: String, heroShown: Bool) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                        .opacity(heroShown ? 0 : 1)
                        .animation(.easeOut(duration: 0.14), value: heroShown)
                }
            }
    }
}

/// 分组小标题（新版 .list-title）：12 号半粗，次级文字色，不转大写
struct GroupTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).kerning(0.5).foregroundStyle(Theme.text2).textCase(nil)
    }
}

/// 列表里一行入口（ListItem 带 left 图标与 right 状态）：线条图标、名字、右边灰字
struct IconRow: View {
    let title: String
    let icon: String
    var value: String = ""

    var body: some View {
        HStack(spacing: Theme.sp3) {
            SvgIcon(name: icon, size: 19, color: Theme.text2)
            Text(title)
            Spacer(minLength: Theme.sp2)
            if !value.isEmpty { Text(value).font(.system(size: 13)).foregroundStyle(Theme.text3).lineLimit(1) }
        }
        .frame(minHeight: 38)
    }
}

extension Theme {
    /// 日常首页的眉题（网页版 ui/page.js 的 todayLine）：10月14日 · 周二
    static func todayLine(_ d: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.month, .day, .weekday], from: d)
        let w = Array("日一二三四五六")[((c.weekday ?? 1) - 1) % 7]
        return "\(c.month ?? 1)月\(c.day ?? 1)日 · 周\(w)"
    }
}

/// 说明（网页版 ListItem 的 info，ARCHITECTURE 4.525、4.527）：界面上不显示，收进「设置 - 说明书」。
/// 一项只写名字和当前状态；会多花钱的、不能撤销的那一句仍用 Text 写在原处。
/// scripts/gen-help.mjs 从代码里收集这些文字生成 Resources/help.json，改了说明要重跑（编译时核对）。
struct HelpNote: View {
    /// title：说明书里这一条的标题，不写时取所在那一组的组头或第一个控件的名字
    init(_ text: String, title: String = "") {}
    var body: some View { EmptyView() }
}
