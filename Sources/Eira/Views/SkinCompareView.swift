import SwiftUI
import UIKit

// 「对照」页（美化详情 - 查看还原情况 - 对照）：同一页示例会话，上面是网页版的效果，下面是原生版的效果。
//
// 网页版效果：按网页版会话页的结构（skin-contract.js 的 CHAT_TREE，类名一字不差）与默认样式排出一页示例会话，
// 套上这份 CSS，在画图那一边同一个关起来的 WKWebView 里截图（不联网、不跑脚本；CSS 引用的网络图片换成导入时下载到本机的那一份）。
// 示例页的默认样式全部写在 :where() 里（特异度为零），美化写了的一律盖得住。
//
// 原生版效果：同样的内容由原生元素现场画，经 \.phSkin、\.phRaster 与会话页走同一套 PhBox、CssRasterView。
// 结构写法的派生钩子按 CssStructural 的约定（base → first、tail、odd/even、cont、last）接在钩子串后面。
//
// 网页版截图按 CSS 原文、下载过的图与深浅色缓存在内存里，同一份不重复截。

// MARK: - 样板内容（两边共用）

enum SkinCompareMock {
    static let width: Double = 375
    static let height: Double = 667
    static var size: CGSize { CGSize(width: width, height: height) }

    static let title = "示例角色"
    static let placeholder = "输入消息"
    static let stamp = "21:36"
    static let read = "已读"

    enum Item: Equatable {
        case time(String)
        case turn(mine: Bool, bubbles: [String])
        case transfer(mine: Bool, amount: String, note: String)
    }

    /// 时间分隔、两边各几轮（含一轮两个气泡）、一张转账卡；最后一条是我发的，带消息时刻与已读
    static let items: [Item] = [
        .time("昨天 21:30"),
        .turn(mine: false, bubbles: ["今天的工作结束了吗？"]),
        .turn(mine: true, bubbles: ["刚刚结束。", "正在回家的路上。"]),
        .turn(mine: false, bubbles: ["路上注意安全。", "到家后告诉我。"]),
        .transfer(mine: true, amount: "¥52.00", note: "转账"),
        .turn(mine: true, bubbles: ["已经到家了。"]),
    ]

    /// 网页版样板页上必须挂着的契约类名（测试核对）
    static let requiredClasses: [String] = [
        "ph-screen", "ph-page", "ph-navbar", "ph-nav-left", "ph-nav-title", "ph-nav-right", "ph-nav-action", "ph-back",
        "ph-chat", "ph-chat-body", "ph-time-sep", "ph-msg", "ph-msg-mine", "ph-msg-theirs", "ph-face", "ph-avatar",
        "ph-col", "ph-bubble", "ph-bubble-mine", "ph-bubble-theirs", "ph-meta", "ph-stamp", "ph-read", "ph-transfer",
        "ph-composer", "ph-composer-btn", "ph-plus", "ph-composer-input", "ph-sticker-btn", "ph-send",
    ]

    // MARK: 结构（原生那一边按它接派生钩子）

    static func isMsg(_ item: Item) -> Bool {
        if case .time = item { return false }
        return true
    }

    static func mine(_ item: Item) -> Bool {
        switch item {
        case .time: return false
        case .turn(let m, _), .transfer(let m, _, _): return m
        }
    }

    /// 第 i 项（items 里的位置）这一条消息挂的钩子：base → odd/even → cont → last（同 CssStructural 的次序）。
    /// 奇偶按它在消息列表里的位置算（时间分隔也算一个，同 :nth-child）
    static func msgHooks(_ i: Int) -> [CssHook] {
        let item = items[i]
        let side = mine(item) ? "msg-mine" : "msg-theirs"
        var out: [CssHook] = ["msg", side]
        let nth = i + 1
        let parity = nth % 2 == 1 ? "-odd" : "-even"
        out += [CssStructural.hook("msg", parity), CssStructural.hook(side, parity)]
        if i > 0, isMsg(items[i - 1]), mine(items[i - 1]) == mine(item) {
            out += [CssStructural.hook("msg", "-cont"), CssStructural.hook(side, "-cont")]
        }
        let later = items[(i + 1)...]
        if !later.contains(where: { isMsg($0) && mine($0) == mine(item) }) { out.append(side + "-last") }
        if !later.contains(where: isMsg) { out.append("msg-last") }
        return out
    }

    /// 第 i 项里第 j 个气泡（共 n 个）挂的钩子：base → first → tail → odd/even → cont → last
    static func bubbleHooks(_ i: Int, _ j: Int, _ n: Int) -> [CssHook] {
        let m = mine(items[i])
        let side = m ? "bubble-mine" : "bubble-theirs"
        var out: [CssHook] = ["bubble", side]
        func add(_ suffix: String) { out += [CssStructural.hook("bubble", suffix), CssStructural.hook(side, suffix)] }
        if j == 0 { add("-first") }
        if j == n - 1 { add("-tail") }
        add((j + 1) % 2 == 1 ? "-odd" : "-even")
        if j > 0 { add("-cont") }
        let msg = msgHooks(i)
        if j == n - 1, msg.contains(m ? "msg-mine-last" : "msg-theirs-last") {
            out += ["bubble-last", side + "-last"]
        }
        return out
    }

    // MARK: 网页版样板页

    private static func svg(_ inner: String) -> String {
        "<svg width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" "
            + "stroke-linecap=\"round\" stroke-linejoin=\"round\">\(inner)</svg>"
    }

    static let iconBack = svg(#"<path d="M15 5l-7 7 7 7"/>"#)
    static let iconMore = svg(#"<circle cx="5" cy="12" r="1.2"/><circle cx="12" cy="12" r="1.2"/><circle cx="19" cy="12" r="1.2"/>"#)
    static let iconPlus = svg(#"<path d="M12 5v14M5 12h14"/>"#)
    static let iconSmile = svg(#"<circle cx="12" cy="12" r="9"/><path d="M8.5 14.5c1 1.2 2.2 1.8 3.5 1.8s2.5-.6 3.5-1.8"/><path d="M9 9.5h.01M15 9.5h.01"/>"#)
    static let iconSend = svg(#"<path d="M5 12h14M13 6l6 6-6 6"/>"#)

    /// 网页版的默认样子（近似）。全部包在 :where() 里，特异度为零：美化写了的一律盖得住
    static let baseCSS = """
    :root { --bg: var(--ph-bg, #FFFFFF); --surface: var(--ph-surface, #FFFFFF); --surface-2: var(--ph-surface-2, #F4F4F4); \
    --surface-3: var(--ph-surface-3, #ECECEC); --border: var(--ph-border, #EDEDED); --text: var(--ph-text, #000000); \
    --text-2: var(--ph-text-2, rgba(0, 0, 0, .56)); --text-3: var(--ph-text-3, rgba(0, 0, 0, .34)); \
    --accent: var(--ph-accent, #000000); --on-accent: var(--ph-on-accent, #FFFFFF); }
    :root[data-theme="dark"] { --bg: var(--ph-bg, #000000); --surface: var(--ph-surface, #0B0B0B); --surface-2: var(--ph-surface-2, #141414); \
    --surface-3: var(--ph-surface-3, #1E1E1E); --border: var(--ph-border, #1A1A1A); --text: var(--ph-text, #FFFFFF); \
    --text-2: var(--ph-text-2, rgba(255, 255, 255, .58)); --text-3: var(--ph-text-3, rgba(255, 255, 255, .36)); \
    --accent: var(--ph-accent, #FFFFFF); --on-accent: var(--ph-on-accent, #000000); }
    *, *::before, *::after { box-sizing: border-box; }
    :where(html, body) { margin: 0; padding: 0; height: 100%; overflow: hidden; }
    :where(body) { font-family: -apple-system, system-ui, "PingFang SC", sans-serif; font-size: 15px; line-height: 1.4; \
    color: var(--text); background: var(--bg); -webkit-text-size-adjust: 100%; }
    :where(.ph-screen) { position: relative; width: 375px; height: 667px; overflow: hidden; background: var(--bg); }
    :where(.ph-page) { display: flex; flex-direction: column; height: 100%; }
    :where(.ph-navbar) { flex: none; height: var(--ph-navbar-h, 44px); display: flex; align-items: center; padding: 0 8px; \
    background: var(--surface); border-bottom: 1px solid var(--border); }
    :where(.ph-nav-left) { width: 44px; flex: none; }
    :where(.ph-nav-right) { width: 44px; flex: none; display: flex; justify-content: flex-end; }
    :where(.ph-nav-title) { flex: 1; min-width: 0; text-align: center; font-size: 16px; font-weight: 600; white-space: nowrap; \
    overflow: hidden; text-overflow: ellipsis; }
    :where(.ph-back) { position: absolute; left: 8px; top: 4px; z-index: 5; }
    :where(.ph-back, .ph-nav-action, .ph-composer-btn) { width: 36px; height: 36px; flex: none; display: flex; \
    align-items: center; justify-content: center; color: var(--text); }
    :where(.ph-chat) { flex: 1; min-height: 0; display: flex; flex-direction: column; }
    :where(.ph-chat-body) { flex: 1; min-height: 0; overflow: hidden; padding: 4px 12px 12px; background: var(--ph-chat-bg, var(--surface-2)); }
    :where(.ph-time-sep) { margin-top: 12px; text-align: center; font-size: 12px; color: var(--text-3); }
    :where(.ph-msg) { display: flex; align-items: flex-start; gap: 8px; margin-top: var(--ph-bubble-gap, 16px); }
    :where(.ph-msg-mine) { flex-direction: row-reverse; }
    :where(.ph-face) { flex: none; }
    :where(.ph-avatar) { width: var(--ph-avatar-size, 36px); height: var(--ph-avatar-size, 36px); border-radius: var(--ph-avatar-r, 50%); \
    background: var(--surface-3); }
    :where(.ph-col) { display: flex; flex-direction: column; align-items: flex-start; gap: var(--ph-bubble-gap-in, 5px); \
    max-width: 70%; min-width: 0; }
    :where(.ph-msg-mine .ph-col) { align-items: flex-end; }
    :where(.ph-bubble) { padding: var(--ph-bubble-py, 8px) var(--ph-bubble-px, 12px); border-radius: var(--ph-bubble-r, 14px); \
    font-size: var(--ph-bubble-fs, 14px); line-height: 1.6; word-break: break-word; }
    :where(.ph-bubble-mine) { background: var(--accent); color: var(--on-accent); }
    :where(.ph-bubble-theirs) { background: var(--surface); color: var(--text); box-shadow: 0 1px 1px rgba(0, 0, 0, .06); }
    :where(.ph-transfer) { width: 220px; padding: 12px 14px; border-radius: var(--ph-bubble-r, 14px); background: var(--surface); \
    color: var(--text); box-shadow: 0 1px 1px rgba(0, 0, 0, .06); }
    :where(.rz-amount) { font-size: 18px; font-weight: 600; }
    :where(.rz-note) { margin-top: 2px; font-size: 12px; color: var(--text-2); }
    :where(.ph-meta) { display: flex; gap: 6px; font-size: 11px; color: var(--text-3); }
    :where(.ph-composer) { flex: none; display: flex; align-items: center; gap: 8px; padding: var(--ph-composer-pad, 8px 10px); \
    min-height: var(--ph-composer-h, 52px); background: var(--surface); border-top: 1px solid var(--border); }
    :where(.ph-composer-btn) { border-radius: 50%; background: var(--surface-2); }
    :where(.ph-composer-input) { flex: 1; min-width: 0; height: 36px; margin: 0; padding: 8px 12px; border: 0; outline: 0; resize: none; \
    border-radius: 18px; background: var(--surface-2); color: var(--text); font: inherit; font-size: 15px; line-height: 20px; \
    overflow: hidden; -webkit-appearance: none; appearance: none; }
    :where(.ph-composer-input)::placeholder { color: var(--text-3); }
    :where(.ph-send) { height: 36px; min-width: 36px; padding: 0 12px; flex: none; border-radius: 18px; display: flex; \
    align-items: center; justify-content: center; background: var(--accent); color: var(--on-accent); }
    :where(svg) { display: block; }
    """

    /// 动画一律跳到结束的那一帧、过渡不播：截图稳定（写了 forwards 的停在终点，其余回到原样）
    static let freezeCSS = "*, *::before, *::after { animation-duration: 0s !important; animation-delay: 0s !important; "
        + "animation-iteration-count: 1 !important; transition: none !important; caret-color: transparent !important; }"

    /// 消息列表里的内容
    static func bodyMarkup() -> String {
        var out = ""
        for (i, item) in items.enumerated() {
            switch item {
            case .time(let t):
                out += "<div class=\"ph-time-sep\">\(t)</div>"
            case .turn(let m, let bubbles):
                let side = m ? "mine" : "theirs"
                var col = bubbles.map { "<div class=\"ph-bubble ph-bubble-\(side)\">\($0)</div>" }.joined()
                if i == items.count - 1 {
                    col += "<div class=\"ph-meta\"><span class=\"ph-stamp\">\(stamp)</span><span class=\"ph-read\">\(read)</span></div>"
                }
                out += msg(side, col)
            case .transfer(let m, let amount, let note):
                out += msg(m ? "mine" : "theirs",
                           "<div class=\"ph-transfer\"><div class=\"rz-amount\">\(amount)</div><div class=\"rz-note\">\(note)</div></div>")
            }
        }
        return out
    }

    private static func msg(_ side: String, _ col: String) -> String {
        "<div class=\"ph-msg ph-msg-\(side)\"><div class=\"ph-face\"><div class=\"ph-avatar\"></div></div>"
            + "<div class=\"ph-col\">\(col)</div></div>"
    }

    /// 整页：层级照网页版 CHAT_TREE（悬浮返回键在 .ph-screen 里、.ph-page 外）
    static func markup() -> String {
        "<div class=\"ph-screen\"><div class=\"ph-page\">"
            + "<div class=\"ph-navbar\"><div class=\"ph-nav-left\"></div><div class=\"ph-nav-title\">\(title)</div>"
            + "<div class=\"ph-nav-right\"><div class=\"ph-nav-action\">\(iconMore)</div></div></div>"
            + "<div class=\"ph-chat\"><div class=\"ph-chat-body\">\(bodyMarkup())</div>"
            + "<div class=\"ph-composer\"><div class=\"ph-composer-btn ph-plus\">\(iconPlus)</div>"
            + "<textarea class=\"ph-composer-input\" rows=\"1\" readonly placeholder=\"\(placeholder)\"></textarea>"
            + "<div class=\"ph-composer-btn ph-sticker-btn\">\(iconSmile)</div>"
            + "<div class=\"ph-send\">\(iconSend)</div></div>"
            + "</div></div><div class=\"ph-back\">\(iconBack)</div></div>"
    }

    /// 网页版样板页。css 为已经换好网络图片的美化 CSS；dark 为深色（根元素挂 data-theme，配色查询定死）
    static func html(css: String, dark: Bool) -> String {
        let user = CssRasterPlan.schemeCSS(css, dark: dark)
            .replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
        let scheme = dark ? "dark" : "light"
        return "<!doctype html><html data-theme=\"\(scheme)\"><head><meta charset=\"utf-8\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(CssRasterPlan.csp)\">"
            + "<meta name=\"viewport\" content=\"width=\(Int(width)), initial-scale=1, maximum-scale=1, user-scalable=no\">"
            + "<meta name=\"color-scheme\" content=\"\(scheme)\">"
            + "<style>\(baseCSS)</style><style>\(user)</style><style>\(freezeCSS)</style>"
            + "</head><body>\(markup())</body></html>"
    }
}

// MARK: - 原生那一边用的样式

enum SkinCompare {
    /// 深色时把深色那一份逐项叠上去（同网页版：媒体查询里的规则在深色下生效、后写的赢）。叠两次与叠一次相同
    static func effective(_ c: CssCompiled, dark: Bool) -> CssCompiled {
        guard dark, !c.dark.isEmpty || !c.darkVars.isEmpty else { return c }
        var o = c
        for (k, st) in c.dark { o.styles[k] = CssStyle.merge(c.styles[k], st) }
        o.vars.merge(c.darkVars) { _, new in new }
        return o
    }
}

// MARK: - 网页版效果的截图

@MainActor
enum SkinCompareShot {
    private static var cache: [String: UIImage] = [:]
    private static var order: [String] = []

    static func key(css: String, remote: [String: String], dark: Bool) -> String {
        let r = remote.keys.sorted().map { "\($0)=\(remote[$0] ?? "")" }.joined(separator: "\n")
        return CssRasterPlan.hash(css + "\u{0}" + r) + (dark ? "|dark" : "|light")
    }

    static func cached(css: String, remote: [String: String], dark: Bool) -> UIImage? {
        cache[key(css: css, remote: remote, dark: dark)]
    }

    /// 截一张。remote 为导入时下载过的网络图片（地址 → 本机图 id），换成 data: 再画；没下载过的不显示（CSP 拦着，不联网）
    static func render(css: String, remote: [String: String], dark: Bool) async throws -> UIImage {
        let k = key(css: css, remote: remote, dark: dark)
        if let hit = cache[k] { return hit }
        var inline: [String: String] = [:]
        for (url, id) in remote {
            if let uri = await CssRasterizer.dataURI(id) { inline[url] = uri }
        }
        let html = SkinCompareMock.html(css: CssRasterPlan.substitute(css, inline), dark: dark)
        let shot = CssSnapshotter()
        defer { shot.close() }
        shot.appearance(dark: dark)
        guard await shot.load(html, size: SkinCompareMock.size) else {
            throw StoreError(message: "网页版效果绘制超时")
        }
        guard let img = await shot.snapshot(), img.cgImage != nil else {
            throw StoreError(message: "网页版效果截图失败")
        }
        cache[k] = img
        order.append(k)
        if order.count > 6 { cache.removeValue(forKey: order.removeFirst()) }
        return img
    }
}

// MARK: - 对照页

struct SkinCompareView: View {
    let id: String
    @Environment(\.colorScheme) private var scheme
    @State private var dark = false
    @State private var picked = false
    @State private var overlay = false
    @State private var mix = 0.5
    @State private var web: UIImage?
    @State private var loading = false
    @State private var problem: String?
    @State private var tick = 0

    private var row: Row? { _ = tick; return Skins.get(id) }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sp4) {
                    controls
                    if let row, let compiled = Skins.compiled(row) {
                        let scale = min(1, max(0.1, (geo.size.width - 2 * Theme.sp4) / CGFloat(SkinCompareMock.width)))
                        content(row, compiled, scale: scale)
                    } else {
                        Text("这份美化没有自定义 CSS。").foregroundStyle(Theme.text3)
                    }
                    HelpNote("上方为网页版效果：在不联网、不运行脚本的隔离网页中，按网页版会话页的结构与默认样式排出一页示例会话，套上这份 CSS 后截图；CSS 引用的网络图片使用导入时下载到本机的那一份，尚未下载的不显示。下方为原生版效果：同样的内容由原生元素按还原出的样式与绘制成的图片显示。示例页的默认样式为近似，比对时以美化写到的部分为准。「叠加」把网页版效果按设定的不透明度盖在原生版效果上，便于逐处比对。「浅色」「深色」切换两边的配色，美化写了深色规则的按深色规则显示。", title: "对照")
                }
                .padding(Theme.sp4)
            }
        }
        .background(Theme.surface2)
        .navigationTitle("对照")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !picked { dark = scheme == .dark; picked = true }
        }
        .task(id: "\(tick)|\(dark)") { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .eiraSkinChanged)) { _ in tick += 1 }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.sp3) {
            Picker("配色", selection: $dark) {
                Text("浅色").tag(false)
                Text("深色").tag(true)
            }
            .pickerStyle(.segmented)
            Picker("显示方式", selection: $overlay) {
                Text("上下对照").tag(false)
                Text("叠加").tag(true)
            }
            .pickerStyle(.segmented)
            if overlay {
                HStack {
                    Text("网页版不透明度").font(.system(size: 13)).foregroundStyle(Theme.text2)
                    Slider(value: $mix, in: 0...1)
                    Text("\(Int((mix * 100).rounded()))%").font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Theme.text2).frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ row: Row, _ compiled: CssCompiled, scale: CGFloat) -> some View {
        let native = SkinCompareNative(skin: SkinCompare.effective(compiled, dark: dark), raster: Skins.raster(row), dark: dark)
        if overlay {
            label("原生版效果，叠加网页版效果")
            framed(scale: scale) {
                ZStack(alignment: .topLeading) {
                    native
                    if let web {
                        Image(uiImage: web).resizable()
                            .frame(width: CGFloat(SkinCompareMock.width), height: CGFloat(SkinCompareMock.height))
                            .opacity(mix)
                            .allowsHitTesting(false)
                    }
                }
            }
            webStatus
        } else {
            label("网页版效果")
            framed(scale: scale) {
                if let web {
                    Image(uiImage: web).resizable()
                } else {
                    ZStack {
                        Theme.surface
                        if loading { ProgressView() }
                    }
                }
            }
            webStatus
            label("原生版效果")
            framed(scale: scale) { native }
        }
    }

    @ViewBuilder
    private var webStatus: some View {
        if let problem {
            Text(problem).font(.system(size: 13)).foregroundStyle(Theme.danger)
        } else if loading && overlay {
            Text("正在绘制网页版效果").font(.system(size: 13)).foregroundStyle(Theme.text3)
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
    }

    /// 按 375 × 667 的点画，再整体缩到屏幕宽度
    private func framed<V: View>(scale: CGFloat, @ViewBuilder _ inner: () -> V) -> some View {
        let w = CGFloat(SkinCompareMock.width), h = CGFloat(SkinCompareMock.height)
        return inner()
            .frame(width: w, height: h)
            .clipped()
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: w * scale, height: h * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    @MainActor
    private func load() async {
        guard let row else { return }
        let css = row.string("css")
        guard !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let remote = Skins.raster(row, current: false)?.remote ?? [:]
        if let hit = SkinCompareShot.cached(css: css, remote: remote, dark: dark) {
            web = hit
            problem = nil
            return
        }
        web = nil
        loading = true
        do {
            web = try await SkinCompareShot.render(css: css, remote: remote, dark: dark)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - 原生版效果

/// 同一页示例会话的原生画法：样式经环境值传下去，与会话页走同一套 PhBox、CssRasterView
struct SkinCompareNative: View {
    let skin: CssCompiled?
    let raster: CssRasterSet?
    let dark: Bool

    var body: some View {
        SkinCompareNativePage()
            .environment(\.phSkin, skin)
            .environment(\.phRaster, raster)
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}

private struct SkinCompareNativePage: View {
    @Environment(\.phSkin) private var skin

    var body: some View {
        let bodyStyle = skin?.resolve(["chat-body"])
        let skinBg = bodyStyle.map { !CssPaint.drawable($0.background).isEmpty } ?? false
        VStack(spacing: 0) {
            navbar
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(SkinCompareMock.items.enumerated()), id: \.offset) { i, item in
                    row(i, item)
                }
            }
            .padding(.horizontal, Theme.sp3)
            .padding(.top, Theme.sp1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { if !skinBg { Theme.surface2 } }
            .modifier(PhBodyBackground(style: bodyStyle))
            .clipped()
            composer
        }
        .frame(width: CGFloat(SkinCompareMock.width), height: CGFloat(SkinCompareMock.height))
        .background(Theme.bg)
    }

    private var navbar: some View {
        HStack(spacing: 0) {
            MockIcon(hooks: ["back"], symbol: "chevron.left")
                .frame(width: 36, height: 36)
                .modifier(MockBox(hooks: ["back"], fallback: PhFallback(minWidth: 36, minHeight: 36)))
                .frame(width: 44, alignment: .leading)
            Text(SkinCompareMock.title)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
                .modifier(MockBox(hooks: ["nav-title"], fallback: PhFallback(fg: Theme.text, fontSize: 16)))
                .frame(maxWidth: .infinity)
            MockIcon(hooks: ["nav-action"], symbol: "ellipsis")
                .frame(width: 36, height: 36)
                .modifier(MockBox(hooks: ["nav-action"], fallback: PhFallback(minWidth: 36, minHeight: 36)))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, Theme.sp2)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .modifier(MockBox(hooks: ["navbar"], fallback: PhFallback(fill: Theme.surface, continuous: false)))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder
    private func row(_ i: Int, _ item: SkinCompareMock.Item) -> some View {
        switch item {
        case .time(let t):
            Text(t)
                .font(.system(size: 12))
                .modifier(MockBox(hooks: ["time-sep"], fallback: PhFallback(fg: Theme.text3, fontSize: 12)))
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.sp3)
        case .turn(let mine, let bubbles):
            message(i, mine: mine) {
                ForEach(Array(bubbles.enumerated()), id: \.offset) { j, text in
                    MockBubble(text: text, mine: mine, hooks: SkinCompareMock.bubbleHooks(i, j, bubbles.count))
                }
                if i == SkinCompareMock.items.count - 1 {
                    HStack(spacing: 6) {
                        Text(SkinCompareMock.stamp).modifier(MockBox(hooks: ["stamp"], fallback: PhFallback(fg: Theme.text3, fontSize: 11)))
                        Text(SkinCompareMock.read).modifier(MockBox(hooks: ["read"], fallback: PhFallback(fg: Theme.text3, fontSize: 11)))
                    }
                    .font(.system(size: 11))
                    .modifier(MockBox(hooks: ["meta"], fallback: PhFallback(fg: Theme.text3, fontSize: 11)))
                }
            }
        case .transfer(let mine, let amount, let note):
            message(i, mine: mine) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(amount).font(.system(size: 18, weight: .semibold))
                    Text(note).font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                .frame(width: 192, alignment: .leading)
                .modifier(MockBox(hooks: ["transfer"], fallback: PhFallback(
                    fill: Theme.surface, radius: Theme.bubbleRadius, padH: 14, padV: 12, fg: Theme.text,
                    shadow: PhShadow(color: .black.opacity(0.06), radius: 1, y: 1))))
            }
        }
    }

    /// 一条消息：头像与那一列，美化在这一边最后一条上写的字（::after）接在下面
    private func message<C: View>(_ i: Int, mine: Bool, @ViewBuilder _ col: () -> C) -> some View {
        let hooks = SkinCompareMock.msgHooks(i)
        let tail = skin?.pseudoText(hooks, .after)
        return VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .top, spacing: Theme.sp2) {
                if !mine { avatar }
                VStack(alignment: mine ? .trailing : .leading, spacing: 5) { col() }
                    .frame(maxWidth: CGFloat(SkinCompareMock.width) * 0.7, alignment: mine ? .trailing : .leading)
                if mine { avatar }
            }
            if let tail {
                PhPseudoText(text: tail, style: skin?.resolve(hooks, .normal, .after))
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .modifier(MockBox(hooks: hooks, fallback: PhFallback()))
        .padding(.top, Theme.sp4)
    }

    private var avatar: some View {
        Circle().fill(Theme.surface3).frame(width: 36, height: 36)
    }

    private var composer: some View {
        let placeholder = skin?.resolve(["composer-input"], .normal, .placeholder)?.color?.color
        return HStack(spacing: Theme.sp2) {
            MockIcon(hooks: ["composer-btn", "plus"], symbol: "plus")
                .modifier(MockBox(hooks: ["composer-btn", "plus"], fallback: PhFallback(
                    fill: Theme.surface2, radius: 18, fg: Theme.text, minWidth: 36, minHeight: 36)))
            Text(SkinCompareMock.placeholder)
                .font(.system(size: 15))
                .foregroundStyle(placeholder ?? Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(MockBox(hooks: ["composer-input"], fallback: PhFallback(
                    fill: Theme.surface2, radius: 18, padH: 12, padV: 8, fg: Theme.text3, minHeight: 36, alignment: .leading, fontSize: 15)))
            MockIcon(hooks: ["composer-btn", "sticker-btn"], symbol: "face.smiling")
                .modifier(MockBox(hooks: ["composer-btn", "sticker-btn"], fallback: PhFallback(
                    fill: Theme.surface2, radius: 18, fg: Theme.text, minWidth: 36, minHeight: 36)))
            MockIcon(hooks: ["send"], symbol: "arrow.right")
                .modifier(MockBox(hooks: ["send"], fallback: PhFallback(
                    fill: Theme.accent, radius: 18, padH: 10, fg: Theme.onAccent, minWidth: 36, minHeight: 36)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.sp2)
        .frame(maxWidth: .infinity)
        .modifier(MockBox(hooks: ["composer"], fallback: PhFallback(fill: Theme.surface, continuous: false)))
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// 美化给这几个钩子写了样式就照着画（PhBox，含画好的图）；没写照 fallback 画元素原本的样子
private struct MockBox: ViewModifier {
    let hooks: [CssHook]
    let fallback: PhFallback
    @Environment(\.phSkin) private var skin

    func body(content: Content) -> some View {
        if let skin, skin.has(hooks), let st = skin.resolve(hooks) {
            content.modifier(PhBox(style: st, fallback: fallback, hooks: hooks))
        } else {
            let shape = RoundedRectangle(cornerRadius: fallback.radius, style: fallback.continuous ? .continuous : .circular)
            content
                .foregroundStyle(fallback.fg ?? Theme.text)
                .padding(.horizontal, fallback.padH ?? 0)
                .padding(.vertical, fallback.padV ?? 0)
                .frame(minWidth: fallback.minWidth, minHeight: fallback.minHeight, alignment: fallback.alignment)
                .background(fallback.fill ?? Color.clear, in: shape)
                .shadow(color: fallback.shadow?.color ?? .clear, radius: fallback.shadow?.radius ?? 0,
                        x: fallback.shadow?.x ?? 0, y: fallback.shadow?.y ?? 0)
        }
    }
}

/// 按钮里的图标：美化换了图（画好的那张）贴图；藏起来了而伪元素上写了字的写字；否则照原生的图标
private struct MockIcon: View {
    let hooks: [CssHook]
    let symbol: String
    @Environment(\.phSkin) private var skin
    @Environment(\.phRaster) private var raster

    var body: some View {
        let st = skin?.resolve(hooks)
        if let img = CssRasterDraw.icon(raster, hooks) {
            let s = CssRasterDraw.size(img)
            CssRasterView(image: img).frame(width: s.width, height: s.height)
        } else if st?.iconHidden == true {
            let part: CssPart = skin?.pseudoText(hooks, .before) != nil ? .before : .after
            if CssRasterDraw.pick(raster, hooks, parts: [part], kind: .decor) == nil, let t = skin?.pseudoText(hooks, part) {
                PhPseudoText(text: t, style: skin?.resolve(hooks, .normal, part), size: 15, color: st?.color?.color ?? Theme.text)
                    .lineLimit(1).fixedSize()
            } else {
                Color.clear.frame(width: 20, height: 20)
            }
        } else {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
        }
    }
}

/// 一个气泡：美化写了的照美化（与会话页同一套），没写照原生的默认样子
private struct MockBubble: View {
    let text: String
    let mine: Bool
    let hooks: [CssHook]
    @Environment(\.phSkin) private var skin

    var body: some View {
        let size = Theme.bubbleFont
        let fallback = PhFallback(
            fill: mine ? Theme.bubbleMine : Theme.bubbleTheirs, radius: Theme.bubbleRadius, continuous: true,
            padH: 12, padV: 8, fg: mine ? Theme.bubbleMineText : Theme.bubbleTheirsText,
            shadow: mine ? nil : PhShadow(color: .black.opacity(0.06), radius: 1, y: 1), fontSize: size)
        if let skin, skin.has(hooks), let st = skin.resolve(hooks) {
            let fs = CGFloat(st.fontSize ?? Double(size))
            Text(text)
                .font(CssFonts.font(st, size: fs))
                .lineSpacing(CssPaint.lineSpacing(st, fontSize: fs) ?? fs * 0.4)
                .modifier(PhBox(style: st, fallback: fallback, hooks: hooks))
        } else {
            Text(text)
                .font(.system(size: size))
                .lineSpacing(size * 0.4)
                .modifier(MockBox(hooks: [], fallback: fallback))
        }
    }
}
