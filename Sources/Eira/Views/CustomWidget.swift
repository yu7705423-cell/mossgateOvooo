import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

extension Notification.Name {
    /// 主屏版式在主屏自己的整理流程之外被改了（自定义组件存数据、点空的自定义组件改内容）。外壳据此重读一遍
    static let eiraHomeLayoutChanged = Notification.Name("eira.homeLayoutChanged")
}

/// 主屏的「自定义组件」（网页版 src/screens/home/widgets.js 的 custom、customGuide.js、WidgetEditor.js 里的那一段）：
/// 用户自己传一段 HTML 进来，画在一格里。
///
/// 外来的网页一律关进盒子（网页版第 21 条、system/sandbox.js、ARCHITECTURE 4.247），原生版的对应做法：
/// - WKWebView 用不落盘的数据存储（nonPersistent），loadHTMLString 的 baseURL 为 nil（不透明的源，
///   永远不给 file:// 与应用包的地址），读不到本应用的任何文件与数据；
/// - 文档最前面插一条与网页版 wrap() 一字不差的 CSP：不能联网、不能加载外部脚本，https 的图片与字体可以用（主屏组件一律开）；
/// - 除了自己装进去的那一页，任何跳转一律拦下，并显示「已停止」（网页版 escapeGuard）；window.open 一律不给；
///   链接预览、数据识别、左右滑动前进后退全部关掉；
/// - 和外面只有一条通道（messageHandlers.eiraWidget）：只认主页面、只认这一格的 id、只认 state 与 size 两种消息。
///   state 必须是不超过 CUSTOM_STATE_MAX 的 JSON 对象，经 HomeLayout 先读再写存进这一格的 config.state。
///   不交出设置、密钥、数据库、文件或任何别的接口。
/// 网页版把按压转发给主屏（down / move / up 与 eiraHeld）好让长按进整理模式；原生版不搬这一段，长按仍走主屏格子上的 contextMenu。
enum CustomWidget {
    static let id = "custom"
    /// 网页版 CUSTOM_MAX_BYTES
    static let maxBytes = 512 * 1024
    /// 网页版 CUSTOM_STATE_MAX：组件自己存的东西（widget.set），存在这一格的 config.state 里
    static let stateMax = 64 * 1024
    /// 盒子与外面唯一的那条通道
    static let channel = "eiraWidget"
    static let def = MoreWidgets.Def(id: id, label: "自定义组件", desc: "", sizes: [(2, 1), (2, 2), (4, 1), (4, 2), (4, 4)], fields: [], framed: true)

    /// 读出来的 HTML 按文件缓存（网页版 htmlCache）。主屏翻页、重排时组件会重挂，不必每次再读一遍
    nonisolated(unsafe) static var htmlCache: [String: String] = [:]
    /// 各格组件在盒子里量到的实际大小（写法说明里显示）
    nonisolated(unsafe) static var sizes: [String: (w: Int, h: Int)] = [:]
    /// 清除了组件保存的数据之后要重新装一遍那一页（否则页面里还拿着旧数据，下一次 set 又写回去）。按格子计数
    nonisolated(unsafe) static var resets: [String: Int] = [:]

    static func kb(_ n: Int) -> String { "\(Int((Double(n) / 1024).rounded())) KB" }

    /// 'fit' | 'cell'，没写过按 fit（网页版 CUSTOM_DEFAULT）
    static func fit(_ config: [String: JSONValue]) -> String { config["fit"]?.string == "cell" ? "cell" : "fit" }

    /// 这一份文件的文字。读不到按空串（与网页版相同：缓存成空，不反复去读）
    static func text(_ fileId: String) -> String {
        if let hit = htmlCache[fileId] { return hit }
        var t = ""
        if let url = MediaStore.url(.files, id: fileId), let d = try? Data(contentsOf: url) { t = String(decoding: d, as: UTF8.self) }
        htmlCache[fileId] = t
        return t
    }

    // MARK: - 盒子（网页版 system/sandbox.js 的 policy、wrap）

    static func csp(images: Bool) -> String {
        [
            "default-src 'none'",
            "script-src 'unsafe-inline' 'unsafe-eval'",
            images ? "style-src 'unsafe-inline' https:" : "style-src 'unsafe-inline'",
            images ? "img-src data: blob: https:" : "img-src data: blob:",
            images ? "font-src data: https:" : "font-src data:",
            "media-src data: blob:",
            "connect-src 'none'",
            "form-action 'none'",
            "frame-src 'none'",
            "worker-src 'none'",
            "base-uri 'none'",
        ].joined(separator: "; ")
    }

    private static func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// CSP 必须在它自己的任何东西之前：放在最前面，并去掉它自己的 doctype，我们自己补一个在最前
    static func wrap(_ html: String, bridge: String = "", images: Bool = false) -> String {
        let body = html.replacingOccurrences(of: #"^\x{FEFF}?\s*<!doctype[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        return "<!DOCTYPE html>"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(attr(csp(images: images)))\">"
            + "<meta charset=\"utf-8\">"
            + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            + (bridge.isEmpty ? "" : "<script>\(bridge)</script>")
            + body
    }

    /// 一个值写成 JS 字面量（网页版 JSON.stringify）。`<` 换成 \u003c 转义，存的数据里有 </script> 也截不断外面那段脚本
    static func js(_ v: JSONValue, fallback: String) -> String {
        guard let d = try? v.encoded(), let s = String(data: d, encoding: .utf8) else { return fallback }
        return s.replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // MARK: - 盒子里的桥（网页版 widgetBridge，去掉了按压转发）

    static let fontStack = "-apple-system, BlinkMacSystemFont, \"Segoe UI\", \"PingFang SC\", \"Hiragino Sans GB\", \"Microsoft YaHei\", sans-serif"
    static let serifStack = "\"Songti SC\", \"Times New Roman\", Georgia, serif"
    /// 网页版 WG_VARS
    static let vars = ["--wg-text", "--wg-text-2", "--wg-text-3", "--wg-bg", "--wg-bg-2", "--wg-border", "--wg-accent", "--wg-radius", "--wg-font", "--wg-font-serif"]

    private static func css(_ c: Color, _ t: UITraitCollection) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).resolvedColor(with: t).getRed(&r, green: &g, blue: &b, alpha: &a)
        func n(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        if a >= 0.999 { return String(format: "#%02X%02X%02X", n(r), n(g), n(b)) }
        return "rgba(\(n(r)),\(n(g)),\(n(b)),\(String(format: "%.3f", Double(max(0, min(1, a))))))"
    }

    /// 主题变量（网页版 themeOf 的 vars）：取本应用的主题令牌，按深浅色各取一份
    static func themeVars(dark: Bool) -> String {
        let t = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let colors: [(String, Color)] = [
            ("--wg-text", Theme.text), ("--wg-text-2", Theme.text2), ("--wg-text-3", Theme.text3),
            ("--wg-bg", Theme.surface), ("--wg-bg-2", Theme.surface2), ("--wg-border", Theme.border),
            ("--wg-accent", Theme.accent),
        ]
        var out = colors.map { "\($0.0):\(css($0.1, t))" }
        out.append("--wg-radius:\(Int(Theme.rMd))px")
        out.append("--wg-font:\(fontStack)")
        out.append("--wg-font-serif:\(serifStack)")
        return out.joined(separator: ";")
    }

    static func bridge(id: String, cols: Int, rows: Int, fit: String, state: JSONValue, vars: String, scheme: String) -> String {
        let fitting = fit != "cell"
        let s: JSONValue = state.object != nil ? state : .object([:])
        var out = "(function(){\n"
        out += "var ID=\(js(.string(id), fallback: "\"\"")),S=\(js(s, fallback: "{}")),MAX=\(stateMax),timer=0,d=document.documentElement;\n"
        out += "function send(m){m.eiraWidget=ID;try{window.webkit.messageHandlers.\(channel).postMessage(m)}catch(e){}}\n"
        out += "d.setAttribute('data-size',\(js(.string("\(cols)x\(rows)"), fallback: "\"\"")));d.setAttribute('data-scheme',\(js(.string(scheme), fallback: "\"light\"")));\n"
        out += "var st=document.createElement('style');\n"
        out += "st.textContent=':root{'+\(js(.string(vars), fallback: "\"\""))+'}:where(html,body){margin:0;padding:0;background:transparent;color:var(--wg-text);font-family:var(--wg-font)}'\n"
        out += "+':where(html){-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;-webkit-tap-highlight-color:transparent}'"
        out += (fitting ? "+'html{overflow:hidden}'" : "") + ";\n"
        out += "(document.head||d).appendChild(st);\n"
        out += "addEventListener('contextmenu',function(e){e.preventDefault()},true);\n"
        out += "function copy(v){return v===undefined?null:JSON.parse(JSON.stringify(v))}\n"
        out += "function flush(){if(timer){clearTimeout(timer);timer=0;send({t:'state',data:JSON.stringify(S)})}}\n"
        out += "window.widget={cols:\(cols),rows:\(rows),\n"
        out += "get:function(k){return k===undefined?copy(S):copy(S[k])},\n"
        out += "set:function(k,v){var n=copy(S);if(v===undefined||v===null)delete n[k];else n[k]=copy(v);\n"
        out += "if(JSON.stringify(n).length>MAX)throw new Error('widget storage is full (limit '+MAX+' bytes)');\n"
        out += "S=n;clearTimeout(timer);timer=setTimeout(flush,200);return true},\n"
        out += "remove:function(k){return this.set(k,null)},\n"
        out += "clear:function(){S={};clearTimeout(timer);timer=1;flush()}};\n"
        out += "addEventListener('pagehide',flush);\n"
        if fitting {
            out += "function fit(){var b=document.body;if(!b)return;d.style.zoom='';\n"
            out += "var w=Math.max(d.scrollWidth,b.scrollWidth),h=Math.max(d.scrollHeight,b.scrollHeight);\n"
            out += "var k=Math.min(innerWidth/w,innerHeight/h,1);if(k<0.995)d.style.zoom=String(Math.floor(k*1000)/1000)}\n"
            out += "addEventListener('load',function(){fit();setTimeout(fit,300);setTimeout(fit,1200)});addEventListener('resize',fit);\n"
            out += "if(document.fonts&&document.fonts.ready)document.fonts.ready.then(fit);\n"
        }
        out += "addEventListener('load',function(){send({t:'size',w:innerWidth,h:innerHeight})});\n"
        out += "})();"
        return out
    }

    /// 一格组件的整页：盒子 + 桥 + 它自己的代码。外部 https 图片与字体放开（网页版 images: true）
    static func document(_ html: String, cell: Shell.Cell, fit: String, vars: String, scheme: String) -> String {
        let b = bridge(id: cell.id, cols: cell.w, rows: cell.h, fit: fit, state: cell.config["state"] ?? .object([:]), vars: vars, scheme: scheme)
        return wrap(html, bridge: b, images: true)
    }

    // MARK: - 盒子里发出来的消息

    enum Inbound: Equatable {
        case state(JSONValue)
        case size(Int, Int)
    }

    /// 只认主页面、只认这一格、只认 state 与 size。state 必须是不超过上限的 JSON 对象（数组、别的都不收）
    static func accept(_ body: Any, cellId: String, mainFrame: Bool) -> Inbound? {
        guard mainFrame, !cellId.isEmpty, let m = body as? [String: Any],
              (m["eiraWidget"] as? String) == cellId, let t = m["t"] as? String else { return nil }
        switch t {
        case "state":
            guard let s = m["data"] as? String, s.utf16.count <= stateMax,
                  let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)), obj is [String: Any] else { return nil }
            return .state(JSONValue(any: obj))
        case "size":
            let w = (m["w"] as? NSNumber)?.doubleValue ?? 0
            let h = (m["h"] as? NSNumber)?.doubleValue ?? 0
            guard w.isFinite, h.isFinite else { return nil }
            return .size(Int(max(0, min(100_000, w)).rounded()), Int(max(0, min(100_000, h)).rounded()))
        default:
            return nil
        }
    }

    // MARK: - 存

    /// 先读到库里那一份版式再改再存，读不到不改（网页版第 20 条）。失败在屏幕上说
    @discardableResult
    static func apply(settings: [String: JSONValue], _ f: (inout HomeLayout) throws -> Void) -> Bool {
        do {
            var h = try HomeLayout.begin(settings: settings)
            try f(&h)
            try h.save()
            NotificationCenter.default.post(name: .eiraHomeLayoutChanged, object: nil)
            return true
        } catch let e as HomeLayout.Failure {
            Problems.report(e.reason)
        } catch {
            Problems.report("主屏版式未能保存：\(error.localizedDescription)")
        }
        return false
    }

    /// 组件用 widget.set 存的数据，写进这一格的 config.state
    static func saveState(_ cellId: String, _ state: JSONValue, settings: [String: JSONValue]) {
        apply(settings: settings) { $0.setConfig(cellId, ["state": state]) }
    }

    /// 上传或粘贴的那一份过不过得去。nil 为可以
    static func check(_ data: Data, paste: Bool) -> String? {
        if paste && String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "代码为空" }
        if data.count > maxBytes { return paste ? "代码太长，上限 \(kb(maxBytes))" : "文件太大，上限 \(kb(maxBytes))" }
        return nil
    }

    /// 存成一份 .html 文件，给回要写进这一格 config 的几项（fileId、name）
    static func saveHtml(_ data: Data, name: String, paste: Bool) throws -> [String: JSONValue] {
        if let e = check(data, paste: paste) { throw StoreError(message: e) }
        let id = try Files.save(data, ext: "html", type: "text/html")
        htmlCache[id] = String(decoding: data, as: UTF8.self)
        return ["fileId": .string(id), "name": .string(name)]
    }
}

// MARK: - 主屏上的那一格

extension CustomWidget {
    struct CellView: View {
        let cell: Shell.Cell
        let home: HomeLook
        @State private var loaded = 0
        @State private var escapedKey = ""
        @State private var editing = false

        var body: some View {
            let _ = loaded
            let fid = cell.config["fileId"]?.string ?? ""
            let text: String? = fid.isEmpty ? nil : CustomWidget.htmlCache[fid]
            let fit = CustomWidget.fit(cell.config)
            let scheme = home.dark ? "dark" : "light"
            let vars = CustomWidget.themeVars(dark: home.dark)
            // 这几样变了才重新装整页；组件自己存的状态变了不重装
            let key = [fid, fit, "\(cell.w)", "\(cell.h)", vars, scheme, "\(CustomWidget.resets[cell.id] ?? 0)"].joined(separator: "|")
            ZStack {
                if fid.isEmpty {
                    placeholder("square.grid.2x2", "点这里上传 HTML 文件或粘贴代码")
                        .contentShape(Rectangle())
                        .onTapGesture { editing = true }
                } else if let text {
                    if escapedKey == key {
                        placeholder("lock", "该组件试图打开外部网页，已停止")
                    } else {
                        Box(key: key, cellId: cell.id, settings: home.s, scrollable: fit == "cell",
                            make: { CustomWidget.document(text, cell: cell, fit: fit, vars: vars, scheme: scheme) },
                            escaped: { escapedKey = key })
                            .accessibilityLabel(cell.config["name"]?.string ?? "自定义组件")
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: fid) {
                guard !fid.isEmpty, CustomWidget.htmlCache[fid] == nil else { return }
                _ = CustomWidget.text(fid)
                loaded += 1
            }
            .sheet(isPresented: $editing) {
                NavigationStack {
                    EditView(cell: cell, apply: { f in CustomWidget.apply(settings: home.s, f) }, done: { editing = false })
                }
                .eiraLook()
            }
        }

        private func placeholder(_ icon: String, _ text: String) -> some View {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(home.subText)
                Text(text).font(.system(size: 12)).foregroundStyle(home.subText).multilineTextAlignment(.center)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 盒子本身
    struct Box: UIViewRepresentable {
        let key: String
        let cellId: String
        let settings: [String: JSONValue]
        let scrollable: Bool
        let make: () -> String
        let escaped: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> WKWebView {
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .nonPersistent()
            cfg.defaultWebpagePreferences.allowsContentJavaScript = true
            cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
            cfg.dataDetectorTypes = []
            cfg.allowsAirPlayForMediaPlayback = false
            cfg.allowsPictureInPictureMediaPlayback = false
            cfg.mediaTypesRequiringUserActionForPlayback = .all
            // 只经一个弱引用的转手对象挂到通道上：userContentController 强引用处理者，直接挂 coordinator 会绕成环
            cfg.userContentController.add(Proxy(context.coordinator), name: CustomWidget.channel)
            let v = WKWebView(frame: .zero, configuration: cfg)
            v.navigationDelegate = context.coordinator
            v.uiDelegate = context.coordinator
            v.isOpaque = false
            v.backgroundColor = .clear
            v.scrollView.backgroundColor = .clear
            v.scrollView.contentInsetAdjustmentBehavior = .never
            v.scrollView.bounces = false
            v.scrollView.alwaysBounceHorizontal = false
            v.allowsLinkPreview = false
            v.allowsBackForwardNavigationGestures = false
            return v
        }

        func updateUIView(_ v: WKWebView, context: Context) {
            let c = context.coordinator
            c.cellId = cellId
            c.settings = settings
            c.onEscape = escaped
            v.scrollView.isScrollEnabled = scrollable
            guard c.key != key else { return }
            c.key = key
            c.escaped = false
            c.doc = make()
            c.allowNext = true
            v.loadHTMLString(c.doc, baseURL: nil)
        }

        static func dismantleUIView(_ v: WKWebView, coordinator: Coordinator) {
            v.configuration.userContentController.removeScriptMessageHandler(forName: CustomWidget.channel)
            v.stopLoading()
            v.navigationDelegate = nil
            v.uiDelegate = nil
        }

        @MainActor
        final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
            var key: String?
            var doc = ""
            var allowNext = false
            var escaped = false
            var cellId = ""
            var settings: [String: JSONValue] = [:]
            var onEscape: () -> Void = {}

            /// 只放行自己装进去的那一页，以及同一页里的锚点（#…，不重新载入）。
            /// 其余一律拦下：主页面跳走就显示「已停止」；子页面、新窗口直接不给
            func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
                guard navigationAction.targetFrame?.isMainFrame == true else { return .cancel }
                if allowNext && navigationAction.navigationType == .other {
                    allowNext = false
                    return .allow
                }
                if CustomWidget.sameDocument(navigationAction.request.url, from: webView.url) { return .allow }
                if !escaped {
                    escaped = true
                    onEscape()
                }
                return .cancel
            }

            func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                         for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
                nil
            }

            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                webView.scrollView.pinchGestureRecognizer?.isEnabled = false
            }

            /// 页面进程被系统收走（内存紧张）：把同一页重新装一遍，不留一块空白
            func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
                guard !doc.isEmpty, !escaped else { return }
                allowNext = true
                webView.loadHTMLString(doc, baseURL: nil)
            }

            func receive(_ body: Any, mainFrame: Bool) {
                guard !escaped, let m = CustomWidget.accept(body, cellId: cellId, mainFrame: mainFrame) else { return }
                switch m {
                case .state(let v): CustomWidget.saveState(cellId, v, settings: settings)
                case let .size(w, h): CustomWidget.sizes[cellId] = (w, h)
                }
            }
        }

        /// 通道的处理者：弱引用 coordinator，消息转回主线程交给它核
        final class Proxy: NSObject, WKScriptMessageHandler {
            weak var target: Coordinator?
            init(_ target: Coordinator) { self.target = target }

            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                let body = message.body
                let main = message.frameInfo.isMainFrame
                let t = target
                Task { @MainActor in t?.receive(body, mainFrame: main) }
            }
        }
    }

    /// 同一页里的锚点跳转（about:blank#x）：不重新载入，不算跳走
    static func sameDocument(_ to: URL?, from: URL?) -> Bool {
        guard let to, let from, to.fragment != nil else { return false }
        let base = { (u: URL) -> String in u.absoluteString.components(separatedBy: "#").first ?? "" }
        return base(to) == base(from)
    }
}

// MARK: - 编辑页（网页版 WidgetEditor 里 custom 那一段）

extension CustomWidget {
    struct EditView: View {
        let cell: Shell.Cell
        let apply: HomeApply
        var done: () -> Void

        @State private var fileId = ""
        @State private var name = ""
        @State private var fit = "fit"
        @State private var bytes = 0
        @State private var stateBytes = 0
        @State private var importing = false
        @State private var clearing = false
        @State private var problem: String?
        @State private var loaded = false

        var body: some View {
            Form {
                Section {
                    if !fileId.isEmpty {
                        LabeledContent(name.isEmpty ? "自定义组件" : name, value: CustomWidget.kb(bytes))
                    }
                    Button(fileId.isEmpty ? "选择文件" : "更换文件") { importing = true }
                    NavigationLink(fileId.isEmpty ? "粘贴代码" : "编辑代码") {
                        CodePage(initial: fileId.isEmpty ? "" : CustomWidget.text(fileId)) { saveCode($0) }
                    }
                    if !fileId.isEmpty {
                        Button("移除", role: .destructive) {
                            CustomWidget.resets[cell.id, default: 0] += 1
                            if write(["fileId": .null, "name": .string(""), "state": .object([:])]) {
                                fileId = ""; name = ""; bytes = 0; stateBytes = 0
                            }
                        }
                    }
                } header: {
                    Text("HTML")
                } footer: {
                    HelpNote("上传 .html 文件，或直接粘贴代码。上限 512 KB，保存在本设备。组件运行在隔离环境中，读不到本应用的数据与已保存的接口密钥，无法联网，也无法加载外部脚本；可以使用 https 开头的外部图片与字体。", title: "自定义组件：HTML")
                }
                Section {
                    Picker("显示方式", selection: Binding(get: { fit }, set: { v in if write(["fit": .string(v)]) { fit = v } })) {
                        Text("缩放到格子里").tag("fit")
                        Text("按格子大小").tag("cell")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("显示方式")
                } footer: {
                    HelpNote("缩放到格子里：内容比格子大时，整块等比缩小到放得下；没有超出时不缩放。按格子大小：按格子大小显示，内容超出格子的部分由组件自己处理（裁掉或滚动）。", title: "自定义组件：显示方式")
                }
                Section {
                    NavigationLink("写法说明") { GuidePage(cellId: cell.id) }
                    if stateBytes > 2 {
                        Button("清除组件保存的数据", role: .destructive) { clearing = true }
                        Text("组件用 widget.set 保存了 \(CustomWidget.kb(stateBytes)) 的数据").font(.footnote).foregroundStyle(Theme.text2)
                    }
                } footer: {
                    HelpNote("写法说明：组件的大小、可用的颜色变量、保存数据的方法与限制；可复制起步模板，或复制一段说明交给 AI 编写。", title: "自定义组件：写法说明")
                }
                ProblemSection(text: problem)
            }
            .navigationTitle("自定义组件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { done() } }
            }
            .confirmationDialog("清除组件保存的数据", isPresented: $clearing, titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    CustomWidget.resets[cell.id, default: 0] += 1
                    if write(["state": .object([:])]) { stateBytes = 0 }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("组件用 widget.set 保存的数据全部删除，组件回到初始状态。")
            }
            .documentPicker(isPresented: $importing, types: [.html]) { urls in
                if let url = urls.first { upload(url) }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                fileId = cell.config["fileId"]?.string ?? ""
                name = cell.config["name"]?.string ?? ""
                fit = CustomWidget.fit(cell.config)
                bytes = fileId.isEmpty ? 0 : CustomWidget.text(fileId).utf8.count
                stateBytes = (try? cell.config["state"]?.encoded())?.count ?? 0
            }
        }

        private func write(_ cfg: [String: JSONValue]) -> Bool {
            apply { $0.setConfig(cell.id, cfg) }
        }

        private func upload(_ url: URL) {
            guard ["html", "htm"].contains(url.pathExtension.lowercased()) else { problem = "只接受 .html 文件"; return }
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                problem = "读取失败：\(error.localizedDescription)"
                return
            }
            if let e = CustomWidget.check(data, paste: false) { problem = e; return }
            do {
                let cfg = try CustomWidget.saveHtml(data, name: url.lastPathComponent, paste: false)
                if write(cfg) {
                    fileId = cfg["fileId"]?.string ?? ""
                    name = url.lastPathComponent
                    bytes = data.count
                    problem = nil
                }
            } catch {
                problem = "读取失败：\(error.localizedDescription)"
            }
        }

        /// 粘贴或编辑过的代码存成一份新的 .html 文件。给回错误文字，nil 为存好了
        private func saveCode(_ text: String) -> String? {
            let data = Data(text.utf8)
            if let e = CustomWidget.check(data, paste: true) { return e }
            let n = name.isEmpty ? "自定义组件.html" : name
            do {
                let cfg = try CustomWidget.saveHtml(data, name: n, paste: true)
                guard write(cfg) else { return "保存失败：主屏版式未能写入" }
                fileId = cfg["fileId"]?.string ?? ""
                name = n
                bytes = data.count
                problem = nil
                return nil
            } catch {
                return "保存失败：\(error.localizedDescription)"
            }
        }
    }

    /// 粘贴、编辑代码的那一页。智能引号、自动更正一律关掉，免得把代码里的引号换掉
    struct CodePage: View {
        @State private var code: String
        var save: (String) -> String?
        @Environment(\.dismiss) private var dismiss
        @State private var problem: String?

        init(initial: String, save: @escaping (String) -> String?) {
            _code = State(initialValue: initial)
            self.save = save
        }

        var body: some View {
            Form {
                Section {
                    CodeText(text: $code).frame(minHeight: 360)
                } header: {
                    Text("HTML 代码")
                }
                ProblemSection(text: problem)
            }
            .navigationTitle(code.isEmpty ? "粘贴代码" : "编辑代码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let e = save(code) { problem = e } else { dismiss() }
                    }
                }
            }
        }
    }

    struct CodeText: UIViewRepresentable {
        @Binding var text: String

        func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

        func makeUIView(context: Context) -> UITextView {
            let v = UITextView()
            v.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            v.textColor = UIColor(Theme.text)
            v.backgroundColor = .clear
            v.autocorrectionType = .no
            v.autocapitalizationType = .none
            v.spellCheckingType = .no
            v.smartQuotesType = .no
            v.smartDashesType = .no
            v.smartInsertDeleteType = .no
            v.text = text
            v.delegate = context.coordinator
            return v
        }

        func updateUIView(_ v: UITextView, context: Context) {
            context.coordinator.text = $text
            if v.text != text { v.text = text }
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var text: Binding<String>
            init(text: Binding<String>) { self.text = text }
            func textViewDidChange(_ textView: UITextView) { text.wrappedValue = textView.text }
        }
    }

    /// 写法说明（网页版 CustomGuide）：复制模板、复制给 AI 的说明、各节说明
    struct GuidePage: View {
        let cellId: String
        @State private var copied: String?

        var body: some View {
            List {
                Section {
                    Button("复制模板") {
                        UIPasteboard.general.string = CustomWidget.template
                        copied = "模板已复制"
                    }
                    Button("复制给 AI 的说明") {
                        UIPasteboard.general.string = CustomWidget.aiBrief()
                        copied = "说明已复制，可以粘贴给 AI 并写上想要的功能"
                    }
                } footer: {
                    if let copied { Text(copied) }
                }
                ForEach(Array(CustomWidget.guideSections(current: CustomWidget.sizes[cellId]).enumerated()), id: \.offset) { _, s in
                    Section {
                        Text(Self.rich(s.body)).font(.footnote).foregroundStyle(Theme.text)
                    } header: {
                        Text(s.title)
                    }
                }
            }
            .navigationTitle("写法说明")
            .navigationBarTitleDisplayMode(.inline)
        }

        /// 行内的 `代码` 照 Markdown 画成等宽；读不懂就原样
        static func rich(_ s: String) -> AttributedString {
            (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        }
    }
}

// MARK: - 写法说明的正文（网页版 customGuide.js，一字不差）

extension CustomWidget {
    /// 原生版量不到主屏网格时各尺寸的像素，照网页版给那一句
    static let sizeLines = "- 在主屏上打开编辑页时，这里会列出各尺寸的实际像素"

    static func guideText(current: (w: Int, h: Int)?) -> String {
        let cur = current.map { "当前这个组件：\($0.w) × \($0.h) 像素。\n\n" } ?? ""
        let varList = vars.map { "- `var(\($0))`" }.joined(separator: "\n")
        return """
        ## 格式

        一个完整的 HTML 文件，样式写在 `<style>` 里，脚本写在 `<script>` 里，全部放在同一个文件中。文件不超过 \(kb(maxBytes))。

        ## 大小

        组件铺满所在的格子，页面宽高就是格子的宽高。请给 `html`、`body` 写 `height: 100%`，再用百分比或弹性布局铺满，不要写死像素宽高。

        \(cur)\(sizeLines)

        根元素上有 `data-size`，值为 `2x1`、`2x2`、`4x2` 这样的格子数，可以按它为不同尺寸写不同样式，例如 `html[data-size="2x1"] .detail { display: none; }`。

        显示方式选「缩放到格子里」时，内容比格子大会整块等比缩小；选「按格子大小」时不缩放，超出的部分由组件自己处理（裁掉或滚动）。

        ## 颜色与字体

        以下变量跟随本应用的主题与深浅色模式，直接在样式里使用：

        \(varList)

        根元素上的 `data-scheme` 为 `light` 或 `dark`。页面默认背景透明、无外边距、文字颜色为 `--wg-text`，组件自己写的样式会覆盖这些默认值。

        ## 保存数据

        脚本里可以使用 `widget` 保存组件自己的数据，关闭应用后重新打开仍然保留：

        - `widget.get('key')`：读取一项，没有时为 `null`；`widget.get()` 读取全部
        - `widget.set('key', value)`：保存一项，value 为可以转成 JSON 的值
        - `widget.remove('key')`、`widget.clear()`：删除一项、全部删除

        所有数据合计不超过 \(kb(stateMax))，超出时 `set` 抛出错误。数据只属于这一个组件，读不到本应用和其他组件的数据。
        另有 `widget.cols`、`widget.rows` 两个数字，为格子数。

        ## 限制

        - 不能联网：`fetch`、`XMLHttpRequest`、WebSocket 均不可用，也不能加载外部脚本
        - 可以使用 https 开头的外部图片与字体（包括 Google Fonts 这类字体样式表）
        - 读不到本应用的数据与已保存的接口密钥；`localStorage` 不可用，请改用 `widget`
        - 不能打开外部网页；组件试图跳转时会被停止
        - 长按组件进入主屏整理模式，组件内部不要依赖长按手势
        """
    }

    struct GuideSection { let title: String; let body: String }

    /// 按「## 」切成几节
    static func guideSections(current: (w: Int, h: Int)?) -> [GuideSection] {
        var out: [GuideSection] = []
        for chunk in guideText(current: current).components(separatedBy: "## ") {
            let t = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let parts = t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let title = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let body = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            out.append(GuideSection(title: title, body: body))
        }
        return out
    }

    /// 起步模板：一个带计数的小卡片，演示变量、尺寸与保存数据
    static let template = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
      html, body { height: 100%; }
      body {
        box-sizing: border-box; padding: 14px;
        display: flex; flex-direction: column; justify-content: space-between;
        background: var(--wg-bg); border-radius: var(--wg-radius);
      }
      .title { font-size: 13px; color: var(--wg-text-3); }
      .count { font-size: 34px; font-weight: 600; }
      button {
        font: inherit; font-size: 13px; color: var(--wg-bg); background: var(--wg-accent);
        border: 0; border-radius: 999px; padding: 6px 14px; align-self: flex-start;
      }
      html[data-size="2x1"] .title { display: none; }
    </style>
    </head>
    <body>
      <div class="title">今日计数</div>
      <div class="count" id="count">0</div>
      <button id="add">加一</button>
    <script>
      const today = new Date().toDateString();
      let saved = widget.get('counter') || { day: today, n: 0 };
      if (saved.day !== today) saved = { day: today, n: 0 };
      const show = () => { document.getElementById('count').textContent = saved.n; };
      document.getElementById('add').addEventListener('click', () => {
        saved.n += 1;
        widget.set('counter', saved);
        show();
      });
      show();
    </script>
    </body>
    </html>

    """

    /// 「复制给 AI 的说明」：交给任何 AI，让它按这个格式写组件
    static func aiBrief() -> String {
        """
        请按以下规格写一个手机主屏小组件，只输出一个完整的 HTML 文件，不要附加解释。

        【格式】单个 HTML 文件，样式与脚本全部内联，不引用任何外部脚本，文件不超过 \(kb(maxBytes))。

        【大小】页面宽高等于小组件格子的宽高。请给 html、body 写 height: 100%，再用百分比或弹性布局铺满，不要写死像素宽高。常见尺寸：
        \(sizeLines)
        根元素 html 上有 data-size 属性（如 2x1、2x2、4x2），可以按尺寸写不同样式。

        【颜色与字体】使用这些 CSS 变量，它们跟随主题与深浅色模式：\(vars.joined(separator: "、"))。根元素上 data-scheme 为 light 或 dark。页面默认背景透明。

        【保存数据】需要记住状态时使用全局对象 widget：widget.get(key) 读取（没有时为 null），widget.set(key, value) 保存（value 可转为 JSON），widget.remove(key)，widget.clear()。合计不超过 \(kb(stateMax))。不要使用 localStorage、sessionStorage、IndexedDB 与 cookie，它们不可用。

        【限制】不能联网（fetch、XMLHttpRequest、WebSocket 均不可用）；可以使用 https 开头的外部图片与字体；不能跳转或打开外部网页；不要使用长按手势，长按用于进入主屏整理模式。

        【组件要做的事】（在这里写你想要的样子与功能）
        """
    }
}
