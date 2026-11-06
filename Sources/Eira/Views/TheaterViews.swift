import SwiftUI
import WebKit

/// 小剧场（网页版 TheaterBits.js，ARCHITECTURE 4.769）。
///
/// 聊天里是一张封面：暗的幕布、主题、梗概。点开是整页：页面占满，底下一条细栏写着这一条怎么进上下文、你点过几下。
/// 封面还没有页面的（打开时生成那一档）：整页上先是幕布，点「开幕」调一次接口（第 15 条：用户点了才调）。
/// 页面关进盒子（网页版第 21 条）：不落盘的数据存储、不透明的源、最前面一条 CSP（不许联网），只放行自己装进去的那一页；
/// 往外只有一条通道 eiraTheater，只认主页面报上来的 eira.say，记成一行文字。读不到应用里的任何数据。
struct TheaterBubble: View {
    let message: Message
    let char: Character?
    var meName = "我"
    var meAvatar = ""
    @State private var open = false

    private var t: [String: JSONValue] { message.row["theater"]?.object ?? [:] }

    var body: some View {
        let title = (t["title"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "小剧场"
        let brief = t["brief"]?.string ?? ""
        let has = !(t["html"]?.string ?? "").isEmpty
        Button { open = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label("小剧场", systemImage: "theatermasks").font(.system(size: 11)).foregroundStyle(Theme.curtainDim)
                Text(title).font(Theme.serif(17)).foregroundStyle(Theme.curtainInk).multilineTextAlignment(.leading)
                if !brief.isEmpty {
                    Text(brief).font(.system(size: 13)).foregroundStyle(Theme.curtainDim).lineLimit(3).multilineTextAlignment(.leading)
                }
                Text(has ? "点击开幕" : "点击开幕 · 将调用一次接口生成").font(.system(size: 11)).foregroundStyle(Theme.curtainDim)
                    .padding(.top, 2)
            }
            .frame(minWidth: 180, maxWidth: 260, alignment: .leading)
            .padding(Theme.pad)
            .background(Theme.curtain, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("小剧场：\(title)")
        .fullScreenCover(isPresented: $open) {
            TheaterSheet(msgId: message.id, char: char, meName: meName, meAvatar: meAvatar)
        }
    }
}

private let injectItems: [(id: String, label: String)] = [("text", "仅文字"), ("code", "含代码"), ("none", "仅标题")]
private let injectNote = ["text": "角色读到页面里的文字，不读代码", "code": "角色读到整段页面代码，上下文更长", "none": "角色只读到小剧场的标题"]

struct TheaterSheet: View {
    let msgId: String
    let char: Character?
    var meName = "我"
    var meAvatar = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var msg: Message?
    @State private var busy = false
    @State private var err = ""
    @State private var gone = false
    @State private var cardDoc = ""
    @State private var askAgain = false
    @State private var job: Task<Void, Never>?

    private var t: [String: JSONValue] { msg?.row["theater"]?.object ?? [:] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                if msg != nil { bar }
            }
            .background(Theme.bg)
            .navigationTitle((t["title"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "小剧场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { job?.cancel(); dismiss() } }
                if !(t["html"]?.string ?? "").isEmpty && !(t["gen"]?.string ?? "").isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { askAgain = true } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(busy).accessibilityLabel("重新生成")
                    }
                }
            }
            .alert("重新生成", isPresented: $askAgain) {
                Button("取消", role: .cancel) {}
                Button("重新生成") {
                    do { try Theater.clearActs(msgId) } catch { err = "保存失败：\(error.localizedDescription)" }
                    run()
                }
            } message: {
                Text("将再调用一次接口，按同一个主题重写这一页。此前的互动记录一并清除。")
            }
        }
        .onAppear(perform: reload)
        .onDisappear { job?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .eiraChatChanged)) { _ in reload() }
        .task(id: "\(t["card"].map { _ in "card" } ?? "")|\(scheme == .dark)|\(msg?.row["updatedAt"]?.number ?? 0)") { await renderCard() }
    }

    private func reload() { msg = Theater.message(msgId) }

    @ViewBuilder private var stage: some View {
        let html = t["html"]?.string ?? ""
        if gone {
            note("该页面试图打开外部网页，已停止显示")
        } else if !html.isEmpty && !busy {
            if let card = t["card"]?.object, !card.isEmpty {
                if cardDoc.isEmpty { note("模板「\(card["name"]?.string ?? "")」已不存在") }
                else { CardWebView(html: cardDoc) }
            } else {
                TheaterBox(html: html, onSay: { s in
                    do { try Theater.act(msgId, s) } catch { Problems.report("小剧场的互动记录未能保存：\(error.localizedDescription)") }
                }, onEscape: { gone = true })
            }
        } else {
            curtain
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.footnote).foregroundStyle(Theme.text3).padding(Theme.pad).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var curtain: some View {
        VStack(spacing: Theme.sp3) {
            Text("小剧场").font(.system(size: 11)).foregroundStyle(Theme.curtainDim)
            Text((t["title"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "小剧场").font(Theme.serif(22)).foregroundStyle(Theme.curtainInk)
                .multilineTextAlignment(.center)
            if let b = t["brief"]?.string, !b.isEmpty {
                Text(b).font(.system(size: 14)).foregroundStyle(Theme.curtainDim).multilineTextAlignment(.center)
            }
            if busy {
                HStack(spacing: 6) { ProgressView().tint(Theme.curtainInk); Text("正在生成").foregroundStyle(Theme.curtainDim) }
            } else {
                Button("开幕", action: run).buttonStyle(.bordered).tint(Theme.curtainInk)
                Text("将调用一次接口生成页面").font(.system(size: 12)).foregroundStyle(Theme.curtainDim)
            }
            if !err.isEmpty { Text(err).font(.system(size: 13)).foregroundStyle(Theme.dangerText).multilineTextAlignment(.center) }
        }
        .padding(Theme.sp5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.curtain)
    }

    private var bar: some View {
        let inject = t["inject"]?.string ?? "text"
        let acts = (t["acts"]?.array ?? []).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("进入上下文").font(.system(size: 13)).foregroundStyle(Theme.text2)
                Picker("进入上下文", selection: Binding(get: { inject }, set: { v in
                    do { try Theater.setInject(msgId, v) } catch { err = "保存失败：\(error.localizedDescription)" }
                    reload()
                })) {
                    ForEach(injectItems, id: \.id) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.segmented)
            }
            HStack {
                Text(injectNote[inject] ?? "").font(.system(size: 12)).foregroundStyle(Theme.text3)
                Spacer()
                if acts > 0 {
                    Button("互动 \(acts) 条 · 清除") {
                        do { try Theater.clearActs(msgId) } catch { err = "保存失败：\(error.localizedDescription)" }
                        reload()
                    }
                    .font(.system(size: 12))
                }
            }
        }
        .padding(.horizontal, Theme.pad).padding(.vertical, Theme.sp2)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private func run() {
        guard !busy else { return }
        guard AppSettings.load().mainPreset?.usable == true || AppSettings.load().fallbackPreset?.usable == true else {
            err = "尚未配置聊天接口"; return
        }
        busy = true; err = ""; gone = false
        job = Task {
            do { try await Theater.generate(msgId) } catch { if !Task.isCancelled { err = error.localizedDescription.isEmpty ? "生成失败" : error.localizedDescription } }
            busy = false
            reload()
        }
    }

    /// 按卡片模板生成的那一档：照 HTML 卡片画（不跑脚本）
    private func renderCard() async {
        guard let card = t["card"]?.object, !card.isEmpty,
              let e = HtmlCard.resolve(bookId: card["bookId"]?.string ?? "", entryId: card["entryId"]?.string ?? "",
                                       name: card["name"]?.string ?? "", char: char) else { cardDoc = ""; return }
        let sys = await CardSys.of(charName: char?.name ?? "", charAvatar: char?.avatar ?? "", userName: meName, userAvatar: meAvatar)
        cardDoc = HtmlCard.doc(e.card, values: card["values"]?.object ?? [:], sys: sys, dark: scheme == .dark)
    }
}

/// 小剧场的盒子：跑脚本，但不联网、读不到应用数据；只认主页面经 eiraTheater 报上来的那一句
struct TheaterBox: UIViewRepresentable {
    let html: String
    var onSay: (String) -> Void
    var onEscape: () -> Void

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
        cfg.userContentController.add(Proxy(context.coordinator), name: Theater.channel)
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        v.allowsLinkPreview = false
        v.allowsBackForwardNavigationGestures = false
        v.scrollView.contentInsetAdjustmentBehavior = .never
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        let c = context.coordinator
        c.onSay = onSay
        c.onEscape = onEscape
        guard c.loaded != html else { return }
        c.loaded = html
        c.escaped = false
        c.doc = Theater.docOf(html)
        c.allowNext = true
        v.loadHTMLString(c.doc, baseURL: nil)
    }

    static func dismantleUIView(_ v: WKWebView, coordinator: Coordinator) {
        v.configuration.userContentController.removeScriptMessageHandler(forName: Theater.channel)
        v.stopLoading()
        v.navigationDelegate = nil
        v.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded: String?
        var doc = ""
        var allowNext = false
        var escaped = false
        var onSay: (String) -> Void = { _ in }
        var onEscape: () -> Void = {}

        /// 只放行自己装进去的那一页与同一页里的锚点；主页面跳走就停（网页版第二次 load 就撤掉），子页面、新窗口不给
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.targetFrame?.isMainFrame == true else { return .cancel }
            if allowNext && navigationAction.navigationType == .other {
                allowNext = false
                return .allow
            }
            if CustomWidget.sameDocument(navigationAction.request.url, from: webView.url) { return .allow }
            if !escaped { escaped = true; onEscape() }
            return .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !doc.isEmpty, !escaped else { return }
            allowNext = true
            webView.loadHTMLString(doc, baseURL: nil)
        }

        func receive(_ body: Any, mainFrame: Bool) {
            guard !escaped, let s = Theater.sayOf(body, mainFrame: mainFrame) else { return }
            onSay(s)
        }
    }

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

// MARK: - 会话菜单里的「小剧场」

struct TheaterPageView: View {
    let chatId: String
    @State private var chat: Chat?
    @State private var c = Theater.Config()
    @State private var problem: String?
    @State private var cards: [HtmlCard.Entry] = []

    var body: some View {
        Form {
            Section {
                let cast = (chat?.characterIds ?? []).compactMap { (try? Repo.character($0)) ?? nil }
                let on = NewFeat.anyOn("theater", AppSettings.load(), chars: cast)
                NavigationLink { CapsView() } label: {
                    LabeledContent("小剧场", value: on ? "已开启" : "未开启")
                }
                HelpNote("角色按对话自己开一段小剧场：一页可以交互的网页。是否开启在「设定集 - 能力开关」的「新功能」中设置，对所有会话生效；单个角色可在会话菜单「角色能力」的「新功能」中另行开启或关闭。", title: "小剧场")
            }
            Section {
                Picker("写法", selection: bind("mode", c.mode)) {
                    Text("角色直接写").tag(Theater.inline)
                    Text("打开时生成").tag(Theater.separate)
                }
                .pickerStyle(.segmented)
                HelpNote("角色直接写：角色在回复里写出整页，不多调用接口，这一轮回复变长。打开时生成：角色只写主题与梗概，聊天里先是一张封面。", title: "小剧场：写法")
                if c.mode == Theater.separate {
                    Text("每打开一张新的封面调用一次接口").font(.footnote).foregroundStyle(Theme.text3)
                    Picker("生成方式", selection: bind("gen", c.gen)) {
                        Text("自由页面").tag(Theater.free)
                        Text("按卡片模板").tag(Theater.template)
                    }
                    .pickerStyle(.segmented)
                    HelpNote("自由页面：按主题写一整页，可以带交互。按卡片模板：按选定的 HTML 卡片逐个字段填写，样式固定，不运行脚本。", title: "小剧场：生成方式")
                    if c.gen == Theater.template {
                        Picker("模板", selection: bind("cardName", c.cardName)) {
                            Text("未选择").tag("")
                            ForEach(cards, id: \.id) { Text($0.name).tag($0.name) }
                            if !c.cardName.isEmpty && !cards.contains(where: { $0.name == c.cardName }) { Text(c.cardName).tag(c.cardName) }
                        }
                        if cards.isEmpty {
                            Text("没有可用的 HTML 卡片，可在世界书中添加卡片条目").font(.footnote).foregroundStyle(Theme.text3)
                        }
                    }
                }
            } header: { Text("写法") }
            Section {
                Picker("新的小剧场默认怎样进入上下文", selection: bind("inject", c.inject)) {
                    ForEach(injectItems, id: \.id) { Text($0.label).tag($0.id) }
                }
                HelpNote("每一条在打开后的底栏中可以单独更改。你在页面里的操作另起一行进入上下文。", title: "小剧场：进入上下文")
            }
            Section {
                TextField("不填写则不作要求", text: textBind("style", c.style), axis: .vertical).lineLimit(2...6)
                HelpNote("只用于小剧场页面里的文字，不影响聊天回复。", title: "小剧场：文风")
            } header: { Text("文风") }
            Section {
                NumberRow(title: "字数", value: Binding(get: { Double(c.words) }, set: { v in save(["words": .number(max(0, v.rounded()))]) }),
                          unit: "字", placeholder: "不限")
                HelpNote("页面里的文字大约多少字。", title: "小剧场：字数")
            }
            Section {
                TextField("例如：三个标签页，分别是菜单、点单与账单", text: textBind("frame", c.frame), axis: .vertical).lineLimit(2...6)
                HelpNote("页面大致的结构，例如有几个标签页、几个场景、需要哪些可以点的东西。", title: "小剧场：框架")
            } header: { Text("框架") } footer: {
                HelpNote("文风、字数与框架写进小剧场那一段说明，只约束小剧场页面。选「角色直接写」时每轮随能力说明发送；选「打开时生成」时只在生成那一次发送。", title: "小剧场：文风、字数与框架")
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("小剧场")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        chat = (try? Repo.chat(chatId)) ?? nil
        c = Theater.cfg(chat)
        if let id = chat?.characterIds.first, let ch = (try? Repo.character(id)) ?? nil { cards = HtmlCard.cards(for: ch) }
    }

    private func save(_ patch: [String: JSONValue]) {
        do { try Theater.setCfg(chatId, patch); problem = nil } catch { problem = "保存失败：\(error.localizedDescription)" }
        load()
    }

    private func bind(_ key: String, _ cur: String) -> Binding<String> {
        Binding(get: { cur }, set: { save([key: .string($0)]) })
    }

    private func textBind(_ key: String, _ cur: String) -> Binding<String> {
        Binding(get: { cur }, set: { save([key: .string($0)]) })
    }
}
