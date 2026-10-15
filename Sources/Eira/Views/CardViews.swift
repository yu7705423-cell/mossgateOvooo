import SwiftUI
import WebKit

/// HTML 卡片那一条气泡（网页版 CardBits.js 的 CardBubble，ARCHITECTURE 4.250）。
///
/// 卡片画在不跑脚本的网页视图里，上面留一条细栏写着「卡片 · 名字」：卡片能画得和应用一模一样，这条栏表明它是卡片。
/// 网页视图会吃掉手指，长按菜单挂在细栏上；右边「展开」看整张。
struct HtmlCardBubble: View {
    let message: Message
    let char: Character?
    var meName = "我"
    var meAvatar = ""
    var mine = false

    @Environment(\.colorScheme) private var scheme
    @State private var doc = ""
    @State private var open = false

    private var ref: [String: JSONValue] { message.row["card"]?.object ?? [:] }
    private var name: String { ref["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "卡片" }
    private var values: [String: JSONValue] { ref["values"]?.object ?? [:] }
    private var entry: HtmlCard.Entry? {
        HtmlCard.resolve(bookId: ref["bookId"]?.string ?? "", entryId: ref["entryId"]?.string ?? "", name: name, char: char)
    }

    var body: some View {
        let e = entry
        let size = e.map { HtmlCard.size($0.card) } ?? (w: 270, h: 0)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack").font(.system(size: 11))
                Text("卡片 · \(name)").font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                if e != nil {
                    Button("展开") { open = true }.font(.caption).buttonStyle(.borderless)
                }
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 10).padding(.vertical, 6)
            if e != nil {
                CardWebView(html: doc)
                    .frame(width: size.w, height: size.h)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("模板已不存在，以下为原始内容").font(.caption).foregroundStyle(Theme.secondaryText)
                    ForEach(values.keys.sorted(), id: \.self) { k in
                        HStack(alignment: .top, spacing: 8) {
                            Text(k).font(.footnote).foregroundStyle(Theme.secondaryText)
                            Text(Self.plain(values[k])).font(.footnote)
                        }
                    }
                }
                .padding(10)
            }
        }
        .frame(width: size.w, alignment: .leading)
        .background(Theme.bubbleTheirs)
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
        .task(id: "\(message.id)|\(scheme == .dark)|\(message.content)") { await render(e) }
        .sheet(isPresented: $open) {
            NavigationStack {
                ScrollView { CardWebView(html: doc).frame(width: size.w, height: size.h).frame(maxWidth: .infinity) }
                    .navigationTitle(name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { open = false } } }
            }
        }
    }

    private func render(_ e: HtmlCard.Entry?) async {
        guard let e else { doc = ""; return }
        let sys = await CardSys.of(charName: char?.name ?? "", charAvatar: char?.avatar ?? "", userName: meName, userAvatar: meAvatar)
        doc = HtmlCard.doc(e.card, values: values, sys: sys, dark: scheme == .dark)
    }

    static func plain(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        switch v {
        case .string(let t): return t
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "是" : "否"
        case .array(let a): return a.map { x in
            if let o = x.object { return o.keys.sorted().map { plain(o[$0]) }.joined(separator: "｜") }
            return plain(x)
        }.joined(separator: "\n")
        case .object(let o): return o.keys.sorted().map { plain(o[$0]) }.joined(separator: "｜")
        case .null: return ""
        }
    }
}

/// 应用自己填的那几个占位符：名字与头像。头像缩小后转成 data: 地址（卡片里不许联网，也读不到本机文件）
@MainActor
enum CardSys {
    private static var memo: [String: String] = [:]

    static func of(charName: String, charAvatar: String, userName: String, userAvatar: String) async -> [String: String] {
        ["char": charName, "user": userName,
         "char_avatar": await dataURL(charAvatar), "user_avatar": await dataURL(userAvatar)]
    }

    static func dataURL(_ id: String) async -> String {
        guard !id.isEmpty else { return "" }
        if let hit = memo[id] { return hit }
        guard let img = await Images.load(id, maxPixel: 160), let jpg = img.jpegData(compressionQuality: 0.8) else { return "" }
        let url = "data:image/jpeg;base64," + jpg.base64EncodedString()
        memo[id] = url
        return url
    }
}

/// 只显示一页 HTML 的网页视图：不跑脚本、不存数据、点了什么都不跳走
struct CardWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.backgroundColor = .clear
        v.scrollView.contentInsetAdjustmentBehavior = .never
        v.allowsLinkPreview = false
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        context.coordinator.allowNext = true
        v.loadHTMLString(html, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        var allowNext = false

        // 只放行自己装进去的那一页；卡片里的链接、表单一律不跳
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if allowNext && navigationAction.navigationType == .other {
                allowNext = false
                return .allow
            }
            return .cancel
        }
    }
}

/// 自己发卡片（网页版 CardSendSheet）：选一张这个角色能用的卡片，逐个字段填，预览，发出去。
/// 「帮我填」可选：写一句想发什么，点一下调一次接口把字段填好，发之前还能改
struct CardSendView: View {
    let chatId: String
    let char: Character
    var meName = "我"
    var meAvatar = ""
    var onSent: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var cards: [HtmlCard.Entry] = []
    @State private var pick: Int?
    @State private var form: [String: String] = [:]
    @State private var idea = ""
    @State private var busy = false
    @State private var doc = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Group {
                if let i = pick, cards.indices.contains(i) { editor(cards[i]) } else { chooser }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(pick == nil ? "关闭" : "返回") { if pick == nil { dismiss() } else { pick = nil; form = [:] } }
                }
            }
        }
        .onAppear { cards = HtmlCard.cards(for: char) }
    }

    private var chooser: some View {
        List {
            Section {
                ForEach(cards.indices, id: \.self) { i in
                    Button { pick = i; form = [:]; idea = "" } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cards[i].name).foregroundStyle(Theme.text)
                            Text(cards[i].bookId == HtmlCard.builtinBookId ? "内置卡片" : (((try? Repo.lorebooks()) ?? []).first(where: { $0.id == cards[i].bookId })?.name ?? ""))
                                .font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                }
                if cards.isEmpty {
                    Text("暂无可用的卡片。卡片放在世界书里：在世界书中新建卡片条目，或在加号面板「世界书」中开启内置卡片，并关联到该角色。")
                        .foregroundStyle(Theme.text2)
                }
            } header: { Text("该角色可用的卡片") }
        }
        .navigationTitle("发送卡片")
    }

    private func editor(_ e: HtmlCard.Entry) -> some View {
        let fields = e.fields
        let values = HtmlCard.parseValues(HtmlCard.formBlock(fields, form), fields: fields)
        let size = HtmlCard.size(e.card)
        return Form {
            Section {
                CardWebView(html: doc).frame(width: size.w, height: size.h).frame(maxWidth: .infinity)
            }
            Section {
                TextField("例如：分享一条关于流浪猫的微博", text: $idea)
                Button(busy ? "正在填写" : "帮我填") { fill(e) }.disabled(busy)
                Text("点一次调用一次接口。").font(.footnote).foregroundStyle(Theme.text2)
                HelpNote("写下想发什么，点「帮我填」由模型填写全部字段，发送前可以修改。不写也可以，模型按最近的聊天填写。", title: "帮我填")
            } header: { Text("帮我填") }
            Section {
                ForEach(fields, id: \.name) { f in
                    let cfg = e.card["fields"]?[f.name]?.object ?? [:]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.list ? "\(f.name)（一行一项\(f.sub.isEmpty ? "" : "，各部分用｜分隔：" + f.sub.joined(separator: "｜"))）" : f.name)
                            .font(.footnote).foregroundStyle(Theme.text2)
                        TextField(cfg["max"]?.number.map { "上限 \(Int($0)) 字" } ?? "", text: Binding(get: { form[f.name] ?? "" }, set: { form[f.name] = $0 }),
                                  axis: .vertical)
                            .lineLimit(f.list || cfg["long"]?.bool == true ? 3...8 : 1...4)
                    }
                }
            } header: { Text("字段") }
            Section {
                Button("发送") { send(e, values) }.disabled(values.isEmpty)
            }
            ProblemSection(text: problem)
        }
        .navigationTitle(e.name)
        .task(id: "\(e.id)|\(HtmlCard.formBlock(fields, form))|\(scheme == .dark)") {
            let sys = await CardSys.of(charName: char.name, charAvatar: char.avatar, userName: meName, userAvatar: meAvatar)
            doc = HtmlCard.doc(e.card, values: values, sys: sys, dark: scheme == .dark)
        }
    }

    private func fill(_ e: HtmlCard.Entry) {
        busy = true
        problem = nil
        let recent = ((try? Repo.messages(chatId: chatId, limit: 12)) ?? []).map {
            "\($0.role == .user ? meName : char.name): \(String($0.content.prefix(200)))"
        }.joined(separator: "\n")
        let charName = char.name, userName = meName, wish = self.idea
        Task {
            do {
                let v = try await HtmlCard.fillByModel(e, idea: wish, charName: charName, userName: userName, recent: recent)
                form = HtmlCard.toForm(e.fields, v)
            } catch { problem = error.localizedDescription }
            busy = false
        }
    }

    private func send(_ e: HtmlCard.Entry, _ values: [String: JSONValue]) {
        do {
            try HtmlCard.send(e, values: values, chatId: chatId)
            onSent()
            dismiss()
        } catch { problem = "未能发送：\(error.localizedDescription)" }
    }
}
