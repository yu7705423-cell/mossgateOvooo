import SwiftUI
import UIKit

// 会话右上角菜单点进去的几页（网页版 TranslatePage、InnerSetPage、ExtrasPage、ChatMorePage）。
// 每一页自己从库里读、自己写，返回菜单时菜单重新读一遍，各行的当前状态跟着变。

/// 改这段会话的几个字段，写不进去时回一句给屏幕（第 20 条：写入失败不许只打日志）
@discardableResult
private func patchChat(_ chatId: String, _ patch: [String: JSONValue]) -> String? {
    do {
        guard var c = try Repo.chat(chatId) else { return "这段会话不存在" }
        for (k, v) in patch { c.row[k] = v }
        c.row.touch()
        try Repo.save(c)
        NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
        return nil
    } catch {
        return "保存失败：\(error.localizedDescription)"
    }
}

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

// MARK: - 翻译（网页版 TranslatePage.js，4.529）

struct TranslatePageView: View {
    let chatId: String
    @ObservedObject private var model = SettingsModel.shared
    @State private var chat: Chat?
    /// 输入框里正在打的字。打空了不关翻译，离开输入框时回到存着的那个（网页版 draft）
    @State private var draft: String?
    @State private var rules = ""
    @FocusState private var langFocused: Bool
    @State private var loaded = false
    @State private var problem: String?

    /// 常见的几个，够挑就行；要别的直接填（网页版 COMMON）
    static let commonLangs = ["中文", "英文", "日文", "韩文", "法文", "德文", "西班牙文", "俄文"]
    static let showModes: [(id: String, label: String)] = [("both", "原文与译文"), ("trans", "只显示译文"), ("orig", "只显示原文")]
    static let openModes: [(id: String, label: String)] = [("tap", "点击展开"), ("turn", "下一轮收起"), ("always", "默认展开")]

    private var lang: String { trimmed(chat?.row.string("translateTo") ?? "") }
    private var showMode: String {
        let v = model.s.raw["translateShow"]?.string ?? "both"
        return Self.showModes.contains { $0.id == v } ? v : "both"
    }
    private var openMode: String {
        let v = model.s.raw["translateOpen"]?.string ?? "tap"
        return Self.openModes.contains { $0.id == v } ? v : "tap"
    }

    var body: some View {
        Form {
            Section {
                Toggle("翻译这段对话", isOn: Binding(get: { !lang.isEmpty }, set: { v in
                    let next = v ? (trimmed(draft ?? "").isEmpty ? "中文" : trimmed(draft ?? "")) : ""
                    draft = nil
                    set(["translateTo": .string(next)])
                }))
                Text(lang.isEmpty ? "开启后，角色每说一条会同时给出译文。原文照常按角色自己的语言写。"
                     : "角色每说一条，同时给出\(lang)译文。译文收在气泡里，不占额外消息。")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            if !lang.isEmpty {
                Section {
                    TextField("中文", text: Binding(get: { draft ?? lang }, set: { v in
                        draft = v
                        let t = trimmed(v)
                        if !t.isEmpty { set(["translateTo": .string(String(t.prefix(40)))]) }
                    }))
                    .focused($langFocused)
                    .onChange(of: langFocused) { _, f in if !f { draft = nil } }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.sp2) {
                            ForEach(Self.commonLangs, id: \.self) { l in
                                Button(l) { draft = nil; set(["translateTo": .string(l)]) }
                                    .font(.system(size: 13))
                                    .foregroundStyle(lang == l ? Theme.onAccent : Theme.text)
                                    .padding(.horizontal, Theme.sp3).padding(.vertical, 5)
                                    .background(lang == l ? Theme.accent : Theme.surface2, in: Capsule())
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("译成什么语言")
                } footer: {
                    HelpNote("填写译文的语言，不是角色说的语言。角色用任何语言说的话，包括一条之中混用几种语言的，都整条译成这一种。列表以外的语言可直接填写，例如「粤语」「文言文」。", title: "翻译：译成什么语言")
                }
                Section {
                    TextField("例如：保留原文中的称呼，不要替换为译文语言的习惯称呼", text: $rules, axis: .vertical).lineLimit(1...4)
                } header: {
                    Text("额外的翻译要求")
                } footer: {
                    HelpNote("写明这段对话的译文需要遵循的用语习惯，例如地区用语、称呼的处理方式、专有名词是否保留原文。只影响译文的内容，不改变译文的格式。对所有对话生效的要求在「设置 - 翻译」中填写，两处同时生效。留空则只按通用规则翻译。", title: "翻译：额外的翻译要求")
                    // 两种方式都用这一项（网页版 4.588）：只是送到的地方不同
                    HelpNote(byApi ? "当前该内容会随原文一并发送给翻译接口。" : "当前该内容会随回复的要求一并发送给聊天模型。", title: "翻译：额外的翻译要求")
                }
                Section {
                    Picker("显示哪一种", selection: Binding(get: { showMode }, set: { model.set("translateShow", .string($0)) })) {
                        ForEach(Self.showModes, id: \.id) { m in Text(m.label).tag(m.id) }
                    }
                    if showMode == "both" {
                        Picker("译文怎么显示", selection: Binding(get: { openMode }, set: { model.set("translateOpen", .string($0)) })) {
                            ForEach(Self.openModes, id: \.id) { m in Text(m.label).tag(m.id) }
                        }
                    }
                } header: {
                    Text("显示")
                } footer: {
                    HelpNote(showMode == "trans" ? "正在显示：只显示译文。正文位置显示译文，原文不显示；聊天气泡点击一次可查看原文。没有译文的消息仍显示原文。"
                             : showMode == "orig" ? "正在显示：只显示原文。译文一律不显示。译文仍然保存，切换回来即可看到。"
                             : "正在显示：原文与译文。原文与译文都显示，译文在原文下方。", title: "翻译：显示哪一种")
                    HelpNote("显示哪一种对聊天与心声中的译文生效。只改变显示，角色读到的内容不变。", title: "翻译：显示哪一种")
                    if showMode == "both" {
                        HelpNote(openMode == "turn" ? "下一轮收起：译文默认收起，点击气泡展开。角色下一轮回复到达时，已展开的全部收起。"
                                 : openMode == "always" ? "默认展开：译文直接显示在原文下方。"
                                 : "点击展开：译文默认收起，点击气泡展开，再次点击收起。展开的一直保持，直到再次点击。", title: "翻译：译文怎么显示")
                    }
                }
                Section {
                    // 当前走哪条路是全局的事，在「设置 - 翻译」里选；这里如实说明
                    Text(byApi ? "当前译文由单独的翻译接口生成，每轮回复之后多调用一次翻译接口。"
                         : "当前译文由聊天模型在生成回复时一并给出，不额外调用接口；回复变长，用量随之增加。")
                        .font(.footnote).foregroundStyle(Theme.text2)
                } footer: {
                    HelpNote("显示方式对所有对话生效，语言与额外要求只对这一段对话生效。开启前已经发出的消息没有译文，需要重新生成才会带上。"
                             + (byApi ? "当前译文由单独的翻译接口生成，该接口只收到原文与翻译规则，不接收角色人设与对话历史。"
                                : "当前译文由聊天模型在生成回复时一并给出，不额外调用接口。在「设置 - 翻译」中可改为单独的翻译接口。"),
                             title: "翻译")
                    HelpNote("通话中也按这一项翻译：字幕在原文下方显示译文。"
                             + (byApi ? "通话中配置了翻译接口时，角色每说完一轮，逐句交给翻译接口，每轮调用一次。"
                                : "通话中由角色在同一次回复里逐句写出译文，不额外调用接口。"), title: "翻译：通话")
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("翻译")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: rules) { _, v in
            guard loaded, v != (chat?.row.string("translateRules") ?? "") else { return }
            set(["translateRules": .string(String(v.prefix(500)))])
        }
    }

    private var byApi: Bool { model.s.translateMode == "api" }

    private func load() {
        chat = try? Repo.chat(chatId)
        rules = chat?.row.string("translateRules") ?? ""
        loaded = true
    }

    private func set(_ patch: [String: JSONValue]) {
        problem = patchChat(chatId, patch)
        chat = try? Repo.chat(chatId)
    }
}

// MARK: - 心声的样式（网页版 chatlook.js 的 INNER_FIELDS，4.398）

/// 存在 chat.look.inner.inline（贴在气泡下的一行）与 chat.look.inner.card（打开的那一页），字段与网页版一字不差：
/// fg 字色、bg 底色、fs 字号、r 圆角、bw 描边粗细、bc 描边颜色。没设的那一项照应用本来的样子。
enum InnerLook {
    struct Field: Identifiable {
        let id: String
        let label: String
        let color: Bool
        var min = 0
        var max = 0
    }

    static let fields: [Field] = [
        Field(id: "fg", label: "字色", color: true),
        Field(id: "bg", label: "底色", color: true),
        Field(id: "fs", label: "字号", color: false, min: 9, max: 30),
        Field(id: "r", label: "圆角", color: false, min: 0, max: 40),
        Field(id: "bw", label: "描边粗细", color: false, min: 0, max: 8),
        Field(id: "bc", label: "描边颜色", color: true),
    ]
    static let sides: [(id: String, label: String)] = [("inline", "贴在气泡下的一行"), ("card", "打开的那一页")]

    static func isHex(_ s: String) -> Bool { s.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }

    /// 一边的样式，只留认识的几项、数值钳在范围里（网页版 innerSide）
    static func of(_ chat: Chat, _ side: String) -> [String: JSONValue] {
        clean(chat.row["look"]?["inner"]?[side])
    }

    static func clean(_ v: JSONValue?) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for f in fields {
            guard let x = v?[f.id] else { continue }
            if f.color {
                if let s = x.string, isHex(s) { out[f.id] = .string(s) }
            } else if let n = x.number ?? x.string.flatMap({ Double($0) }), n.isFinite {
                out[f.id] = .number(Double(Swift.max(f.min, Swift.min(f.max, Int(n.rounded())))))
            }
        }
        return out
    }

    /// 改一边的几项；值为空串或 null 就是恢复默认（网页版 setInnerLook）
    static func set(_ chatId: String, _ side: String, _ patch: [String: JSONValue]) throws {
        guard let c = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
        var inner = c.row["look"]?["inner"]?.object ?? [:]
        var cur = inner[side]?.object ?? [:]
        for (k, v) in patch {
            if v.isNull || v.string == "" { cur[k] = nil } else { cur[k] = v }
        }
        inner[side] = .object(cur)
        try ChatLook.set(chatId, ["inner": .object(inner)])
    }

    static func color(_ l: [String: JSONValue], _ id: String) -> Color? { l[id]?.string.flatMap(Color.init(hex:)) }
    static func number(_ l: [String: JSONValue], _ id: String) -> CGFloat? { l[id]?.number.map { CGFloat($0) } }

    static func hex(_ c: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        let to = { (v: CGFloat) in Int((Swift.max(0, Swift.min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", to(r), to(g), to(b))
    }
}

/// 把一边的样式落到一段文字上：字色、字号、底色、圆角、描边。没设的项用传进来的默认值。
/// 会话页的心声那一行与心声卡要读这一份时，套上这个就行（预览也用它）。
struct InnerLookStyle: ViewModifier {
    let look: [String: JSONValue]
    let size: CGFloat
    let color: Color

    func body(content: Content) -> some View {
        let bg = InnerLook.color(look, "bg")
        let bw = InnerLook.number(look, "bw") ?? 0
        let r = InnerLook.number(look, "r") ?? 0
        let padded = bg != nil || bw > 0
        content
            .font(.system(size: InnerLook.number(look, "fs") ?? size))
            .foregroundStyle(InnerLook.color(look, "fg") ?? color)
            .padding(.horizontal, padded ? Theme.sp2 : 0)
            .padding(.vertical, padded ? Theme.sp1 : 0)
            .background(bg ?? .clear, in: RoundedRectangle(cornerRadius: r))
            .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(InnerLook.color(look, "bc") ?? Theme.border2, lineWidth: bw))
    }
}

/// 数值那几项：留空是默认，失焦或回车时才钳到范围里（打字打到一半不改）
private struct InnerNumRow: View {
    let field: InnerLook.Field
    let value: Double?
    let commit: (Double?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(field.label)
            Spacer()
            TextField("默认", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
                .focused($focused)
                .onSubmit(save)
            Text("px").foregroundStyle(Theme.text3)
        }
        .onAppear { text = value.map { String(Int($0)) } ?? "" }
        .onChange(of: value) { _, v in if !focused { text = v.map { String(Int($0)) } ?? "" } }
        .onChange(of: focused) { _, f in if !f { save() } }
    }

    private func save() {
        let t = trimmed(text)
        guard !t.isEmpty, let n = Double(t) else { text = ""; if value != nil { commit(nil) }; return }
        let v = Double(max(field.min, min(field.max, Int(n.rounded()))))
        text = String(Int(v))
        if v != value { commit(v) }
    }
}

// MARK: - 心声（网页版 InnerSetPage.js，4.398、4.632、4.636）

struct InnerSetPageView: View {
    let chatId: String
    @State private var chat: Chat?
    @State private var side = "inline"
    @State private var what = ""
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        Form {
            if let c = chat { content(c) }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("心声")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: what) { _, v in
            guard loaded, v != (chat?.row.string("innerWhat") ?? "") else { return }
            set(["innerWhat": .string(String(v.prefix(300)))])
        }
    }

    @ViewBuilder private func content(_ c: Chat) -> some View {
        // 群聊没有「单独生成」（网页版 4.636）：那一次调用只针对一个角色；存着的 apart 读成随回复一起
        let grouped = c.isGroup
        let mode = InnerVoice.mode(c)
        let style = InnerVoice.style(c)
        Section {
            Picker("生成方式", selection: Binding(get: { mode }, set: { set(["innerMode": .string($0)]) })) {
                Text("关闭").tag("off")
                Text("随回复一起").tag("inline")
                if !grouped { Text("单独生成").tag("apart") }
            }
        } footer: {
            if mode == "apart" && !grouped { Text("每轮多调用一次接口。") }
            if grouped {
                HelpNote("关闭：成员只说出口的那些话。随回复一起：每个开口的成员在自己那几句下面多写一行心声，不额外调用接口。点哪位成员的头像，看的是哪位成员的心声。群聊中没有「单独生成」：那一次调用只针对一个角色。", title: "群聊的心声")
            } else {
                HelpNote("关闭：角色只说出口的那些话。随回复一起：角色在同一次回复里多写一行心声，不额外调用接口；心声与台词出自同一次生成，两者会互相迁就。单独生成：每轮说完后另起一次调用，只问这几句话背后在想什么；代价是每轮多一次接口调用（走副用接口），费用随之增加。", title: "心声：生成方式")
            }
        }
        // 关闭时也列出显示方式、样式与措辞（网页版 4.632）：关着的人点进来也看得见有样式可改
        if mode == "off" {
            Section {
                Text("心声关闭时，下面的显示方式、样式与措辞照样可以先改好，开启后生效。")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
        }
        Section {
            Picker("显示方式", selection: Binding(get: { style }, set: { set(["innerStyle": .string($0)]) })) {
                Text("淡色小字").tag("quiet")
                Text("打开一页").tag("card")
            }
        } footer: {
            HelpNote(style == "card"
                     ? "点角色头像打开一页，上面是这一轮的心声，下面是这段会话里以前的每一条。只对这段会话生效。"
                     : "心声默认隐藏，点角色头像在气泡下面展开一行，再点收起。只对这段会话生效。", title: "心声：显示方式")
        }
        styleSection(c)
        Section {
            TextField(Templates.get("skeleton.inner-what", settings: AppSettings.load()), text: $what, axis: .vertical).lineLimit(1...4)
            if mode != "apart" {
                Text(fullPiece(c)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text2)
                    .textSelection(.enabled)
            }
        } header: {
            Text("心声写什么")
        } footer: {
            HelpNote("写进心声标记里的那一句，说明心声写什么内容。只改这段会话；留空使用默认。标记的写法保持不变，以保证程序能读出心声。", title: "心声写什么")
            HelpNote(mode == "apart" ? "单独生成时，这一句写进那一次调用的要求里。"
                     : "下方是发给模型的完整段落。这一段在提示词中的位置可以在「设定集 - 预设」中拖动，默认排在聊天记录之后。", title: "心声写什么")
        }
    }

    /// 样式：两处各一份，带预览，一键恢复这一处的默认
    @ViewBuilder private func styleSection(_ c: Chat) -> some View {
        let l = InnerLook.of(c, side)
        Section {
            Picker("改哪一处", selection: $side) {
                ForEach(InnerLook.sides, id: \.id) { s in Text(s.label).tag(s.id) }
            }
            .pickerStyle(.segmented)
            sample(l, name: c.characterIds.first.flatMap { try? Repo.character($0) }?.displayName ?? "角色")
            ForEach(InnerLook.fields) { f in
                if f.color {
                    ColorPicker(selection: Binding(
                        get: { InnerLook.color(l, f.id) ?? Theme.text3 },
                        set: { setLook([f.id: .string(InnerLook.hex($0))]) }), supportsOpacity: false) {
                        HStack {
                            Text(f.label)
                            Spacer()
                            Text(l[f.id]?.string ?? "默认").font(.footnote).foregroundStyle(Theme.text3)
                        }
                    }
                } else {
                    InnerNumRow(field: f, value: l[f.id]?.number) { v in
                        setLook([f.id: v.map { JSONValue.number($0) } ?? .null])
                    }
                    .id("\(side)-\(f.id)")
                }
            }
            Button("恢复这一处的默认样式") {
                setLook(Dictionary(uniqueKeysWithValues: InnerLook.fields.map { ($0.id, JSONValue.null) }))
            }
            .disabled(l.isEmpty)
        } header: {
            Text("样式")
        } footer: {
            HelpNote("只对这段会话生效。没有设置的项保持默认样式。", title: "心声：样式")
        }
    }

    @ViewBuilder private func sample(_ l: [String: JSONValue], name: String) -> some View {
        let line = "今天其实很想见你。"
        if side == "card" {
            VStack(spacing: Theme.sp2) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                Text(line).modifier(InnerLookStyle(look: l, size: 17, color: Theme.text))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(Theme.sp4)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rMd))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("刚下班。")
                    .font(.system(size: Theme.bubbleFont))
                    .foregroundStyle(Theme.bubbleTheirsText)
                    .padding(.horizontal, Theme.bubblePadX).padding(.vertical, Theme.bubblePadY)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                Text("心声：\(line)").modifier(InnerLookStyle(look: l, size: 13, color: Theme.tertiaryText))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.sp2)
        }
    }

    /// 发给模型的完整段落（网页版 full）：随回复一起那一档注入的那一段
    private func fullPiece(_ c: Chat) -> String {
        let s = AppSettings.load()
        return Templates.render(c.isGroup ? "skeleton.inner-group" : "skeleton.inner", ["what": InnerVoice.what(c, settings: s)], settings: s)
    }

    private func load() {
        chat = try? Repo.chat(chatId)
        what = chat?.row.string("innerWhat") ?? ""
        loaded = true
    }

    private func set(_ patch: [String: JSONValue]) {
        problem = patchChat(chatId, patch)
        chat = try? Repo.chat(chatId)
    }

    private func setLook(_ patch: [String: JSONValue]) {
        do {
            try InnerLook.set(chatId, side, patch)
            problem = nil
            NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
        }
        chat = try? Repo.chat(chatId)
    }
}

// MARK: - 互动（网页版 ExtrasPage.js）：旁白、草稿箱、拍一拍、骰子

struct ExtrasPageView: View {
    let chatId: String
    @State private var chat: Chat?
    @State private var problem: String?

    static let faces = ChatEngine.diceChoices

    var body: some View {
        Form {
            if let c = chat { content(c) }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("互动")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { chat = try? Repo.chat(chatId) }
    }

    @ViewBuilder private func content(_ c: Chat) -> some View {
        Section {
            Toggle("开启旁白", isOn: Binding(get: { c.row.bool("narration") }, set: { set(["narration": .bool($0)]) }))
        } header: {
            Text("旁白")
        } footer: {
            Text("不额外调用接口。颜色可在「聊天背景」中修改。")
            HelpNote("开启后，角色每轮回复至少写一行旁白，描写此刻的神态、动作与环境，显示为居中的一行小字，不算作一条消息。群聊中同样生效。", title: "旁白")
        }
        Section {
            Toggle("我也写旁白", isOn: Binding(get: { c.row.bool("userNarration") }, set: { set(["userNarration": .bool($0)]) }))
        } footer: {
            Text("不额外调用接口。")
            HelpNote("开启后，输入框上方出现「消息 旁白」切换。选择「旁白」后输入的内容以旁白发出，显示为居中的一行小字，发出后自动切回发送消息。旁白不单独触发回复，角色在下一次回复时一并读到。", title: "我也写旁白")
        }
        if !c.isGroup {
            Section {
                NavigationLink {
                    DraftsView(chatId: chatId)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("草稿箱")
                        Text(Drafts.on(c) ? "已开启，共 \(Drafts.list(chatId).count) 条。角色打了又没有发出的话存在这里。"
                             : "已关闭。开启后，角色可以写下打了又没有发出的话，不出现在对话里。不额外调用接口。")
                            .font(.caption).foregroundStyle(Theme.text3)
                    }
                }
            } header: {
                Text("草稿箱")
            }
        }
        // 拍角色时的后缀：网页版在角色卡里，原生版的角色卡还没有这一项，先留在这一页
        PatSection(charId: c.isGroup ? nil : c.characterIds.first)
        Section {
            Picker("几面", selection: Binding(get: { ChatEngine.diceFaces(c) }, set: { set(["diceFaces": .number(Double($0))]) })) {
                ForEach(Self.faces, id: \.self) { n in Text("\(n) 面").tag(n) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("骰子")
        } footer: {
            HelpNote("点数由本地随机数掷出，不由模型生成。角色也可以掷，但掷出的那一条要到下一轮才进入上下文，所以它写下那一行时还不知道点数。", title: "骰子：几面")
            HelpNote("角色能不能主动拍你、掷骰子，在会话菜单的「角色能力」中设置。", title: "互动")
        }
    }

    private func set(_ patch: [String: JSONValue]) {
        problem = patchChat(chatId, patch)
        chat = try? Repo.chat(chatId)
    }
}

// MARK: - 预设（网页版 Conversation.js 菜单里的「预设」）

struct ChatPresetPage: View {
    let chatId: String
    @State private var presetId = ""
    @State private var presets: [AppSettings.Preset] = []
    @State private var loaded = false
    @State private var problem: String?

    /// 菜单那一行与这一页的「跟随全局」写出全局那一套的名字（网页版 `跟随全局（名字）`）
    static func globalLabel(_ s: AppSettings = .load()) -> String {
        let n = Presets.name(s, Presets.activeId(s))
        return "跟随全局（\(n.isEmpty ? "默认" : n)）"
    }

    /// 菜单那一行：选了且那一套还在时写它的名字，否则写跟随全局
    static func label(_ c: Chat, _ s: AppSettings = .load()) -> String {
        s.presets.first(where: { $0.id == c.presetId && !c.presetId.isEmpty })?.name ?? globalLabel(s)
    }

    var body: some View {
        Form {
            Section {
                Picker("这段对话用哪一套预设", selection: $presetId) {
                    Text(Self.globalLabel()).tag("")
                    ForEach(presets) { p in Text(p.name).tag(p.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                HelpNote("这段对话用哪一套预设：条目顺序、自己加的条目与参数。只影响这段对话的回复、主动消息与通话。预设的内容在「设定集 - 预设」中编辑。选择跟随全局时，全局换成哪一套，这里跟着换。", title: "预设")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("预设")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            presets = AppSettings.load().presets
            let cur = ((try? Repo.chat(chatId)) ?? nil)?.presetId ?? ""
            // 选过的那一套已经删了：显示成跟随全局（不改库里存的）
            presetId = presets.contains(where: { $0.id == cur }) ? cur : ""
            loaded = true
        }
        .onChange(of: presetId) { _, v in
            guard loaded, let c = (try? Repo.chat(chatId)) ?? nil, v != c.presetId else { return }
            if v.isEmpty && !presets.contains(where: { $0.id == c.presetId }) { return }
            problem = patchChat(chatId, ["presetId": .string(v)])
        }
    }
}

// MARK: - 历史范围（网页版 HistoryPage.js，4.443）

/// 每一轮请求带上最近多少历史消息。这一项属于预设，这里只是入口：改的是这段会话所用的那一套预设，使用它的会话都跟着变
struct HistoryRangePage: View {
    let chatId: String
    @ObservedObject private var model = SettingsModel.shared

    /// 这段会话所用的那一套：选过且还在的那一套，否则全局那一套
    static func presetId(_ c: Chat?, _ s: AppSettings) -> String {
        if let id = c?.presetId, !id.isEmpty, s.presets.contains(where: { $0.id == id }) { return id }
        return Presets.activeId(s)
    }

    /// 菜单那一行：「20 条」「10 轮」，0 写「全部」
    static func label(_ c: Chat, _ s: AppSettings = .load()) -> String {
        let v = Presets.values(s, presetId(c, s))
        let byTurn = v.raw["historyMode"]?.string == "turn"
        let key = byTurn ? "historyTurns" : "historyLimit"
        let n = max(0, Int((v.raw[key]?.number ?? (byTurn ? 10 : 20)).rounded()))
        return n > 0 ? "\(n) \(byTurn ? "轮" : "条")" : "全部"
    }

    private var pid: String { Self.presetId((try? Repo.chat(chatId)) ?? nil, model.s) }

    var body: some View {
        let id = pid
        let v = Presets.values(model.s, id)
        let byTurn = v.raw["historyMode"]?.string == "turn"
        let key = byTurn ? "historyTurns" : "historyLimit"
        let name = Presets.name(model.s, id)
        Form {
            Section {
                Picker("按什么计", selection: Binding(get: { byTurn ? "turn" : "count" },
                                                  set: { m in model.update { Presets.patch(&$0, id, ["historyMode": .string(m)]) } })) {
                    Text("按条数").tag("count")
                    Text("按轮数").tag("turn")
                }
                .pickerStyle(.segmented)
                NumberRow(title: byTurn ? "每轮带最近几轮" : "每轮带最近几条",
                          value: Binding(get: { v.raw[key]?.number ?? (byTurn ? 10 : 20) },
                                         set: { n in model.update { Presets.patch(&$0, id, [key: .number(max(0, n.rounded()))]) } }),
                          unit: byTurn ? "轮" : "条", placeholder: "全部")
                LabeledContent("所属预设", value: name.isEmpty ? "默认" : name)
            } footer: {
                Text("填 0 表示整段对话都带，对话越长每次请求越贵。")
                HelpNote("每一轮请求带上最近这么多历史消息，更早的不进上下文，只能通过长期记忆或历史压缩留下来。按轮数时，一轮是你说一次、角色回一次；按条数时，角色拆成的几条气泡各算一条。这一项属于所用的预设，改动对使用该预设的会话都生效。要给这段对话单独一套，在菜单的「预设」里换一套。", title: "历史范围")
            }
        }
        .navigationTitle("历史范围")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 群聊的世界书（网页版：群聊中在各成员的角色资料里设置）

struct GroupLorePage: View {
    let chatId: String

    var body: some View {
        let chat = (try? Repo.chat(chatId)) ?? nil
        let members = chat.map { GroupChat.members($0) } ?? []
        Form {
            Section {
                ForEach(members) { m in
                    NavigationLink(chat.map { GroupChat.nameIn($0, m) } ?? m.displayName) { LoreQuickView(charId: m.id) }
                }
            } footer: {
                HelpNote("群聊中世界书按成员各自挂载的生效，在各成员的角色资料里设置；全局生效的书对所有成员生效。", title: "群聊的世界书")
            }
        }
        .navigationTitle("世界书")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 更多（网页版 ChatMorePage.js）：表情包、每轮的接口调用、清空

extension ExtraCalls {
    /// 这段对话每轮固定调用几次接口（网页版 cost.perTurn）：回复本身一次；单独的翻译接口、心声单独生成各加一次；
    /// 群聊按人头调用时，回复本身变成成员数那么多次
    static func perTurn(_ chat: Chat, _ s: AppSettings) -> Int {
        var n = 1
        if !chat.row.string("translateTo").trimmingCharacters(in: .whitespaces).isEmpty && s.translateMode == "api" { n += 1 }
        if InnerVoice.mode(chat) == "apart" { n += 1 }
        let size = chat.characterIds.compactMap { try? Repo.character($0) }.count
        if size > 1 && s.raw["groupPerChar"]?.bool == true { n += size - 1 }
        return n
    }

    /// 请求失败时这一轮最多打出去几个（网页版 worstPerTurn）：重试与换接口相乘
    static func worstPerTurn(_ chat: Chat, _ s: AppSettings) -> Int { perTurn(chat, s) * attemptsPerCall(s) }

    /// 「更多」页那一行（网页版 ChatMorePage 的副标题）
    static func perTurnText(_ chat: Chat, _ s: AppSettings) -> String {
        let n = perTurn(chat, s)
        let worst = worstPerTurn(chat, s)
        let head = n > 1 ? "这段对话每轮固定调用 \(n) 次接口" : "这段对话每轮调用 1 次接口"
        let tail = worst > n ? "，请求失败时最多 \(worst) 次" : ""
        return head + tail + (n > 1 || worst > n ? "。点击查看是哪几项，并可逐项关闭" : "")
    }
}

/// 清空这个角色的记忆（网页版 purge.clearMemories）：记忆、现状块（从记忆里压出来的）、记忆的历史版本一并删掉。
/// 聊天记录保留，下次总结时从现有的聊天记录重新提取。
enum ClearMemories {
    @discardableResult
    static func run(charId: String) throws -> Int {
        let n = try Database.shared.all(Collections.memories, where: charId).count
        // 现状块（4.441）是从记忆里压出来的，记忆清空了它也该空
        if var c = try Repo.character(charId), !(c.row["states"]?.object ?? [:]).isEmpty {
            c.row["states"] = .object([:])
            c.row.touch()
            try Database.shared.put(Collections.characters, c.row)
        }
        // 历史版本也是记忆：清空就是清空，不留一份能恢复回来的（4.560）
        try Database.shared.deleteAll(MemHistory.collection, where: charId)
        try Database.shared.deleteAll(Collections.memories, where: charId)
        Diagnostics.shared.record("clear-memories", ["charId": charId, "memories": n])
        return n
    }
}

struct ChatMorePageView: View {
    let chatId: String
    @State private var chat: Chat?
    @State private var counts = ClearHistory.Counts()
    @State private var stickerCount = 0
    @State private var wiping: String?
    @State private var done: String?
    @State private var problem: String?

    var body: some View {
        Form {
            if let c = chat { content(c) }
            if let done { Section { Text(done).foregroundStyle(Theme.text2) } }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("更多")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .confirmationDialog(wipeTitle, isPresented: Binding(get: { wiping != nil }, set: { if !$0 { wiping = nil } }),
                            titleVisibility: .visible) {
            Button(wipeTitle, role: .destructive) { if let w = wiping { wipe(w) } }
        } message: {
            Text(wipeMessage)
        }
    }

    @ViewBuilder private func content(_ c: Chat) -> some View {
        Section {
            NavigationLink { StickerManagerView() } label: {
                sub("表情包", "共 \(stickerCount) 个，所有角色共用")
            }
        } header: { Text("所有角色通用") }
        Section {
            NavigationLink { UsageLimitsView() } label: {
                sub("每轮的接口调用", ExtraCalls.perTurnText(c, AppSettings.load()))
            }
        } header: { Text("用量") }
        if !c.isGroup {
            Section {
                Button { wiping = "history" } label: {
                    sub("清空聊天记录", counts.chats > 1
                        ? "\(counts.messages) 条消息，分布在 \(counts.chats) 段会话中。已提取的记忆保留"
                        : "\(counts.messages) 条消息。已提取的记忆保留", danger: true)
                }
                Button { wiping = "memory" } label: {
                    sub("清空记忆", "\(counts.memories) 条记忆。聊天记录保留", danger: true)
                }
                Button { wiping = "both" } label: {
                    sub("清空记忆与聊天记录", "两者一并删除，角色卡本身保留", danger: true)
                }
            } header: {
                Text("数据")
            } footer: {
                Text("清除操作无法撤销。")
                HelpNote("清除操作针对该角色名下的全部内容。同一角色与多个身份分别聊过的，各段会话与各身份下的记忆都会被清除。角色卡、世界书关联与各项设置不受影响。清空聊天记录时，总结进度与未读一并归零。", title: "更多：清空")
            }
        }
    }

    private func sub(_ title: String, _ subtitle: String, danger: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(danger ? Theme.dangerText : Theme.text)
            Text(subtitle).font(.caption).foregroundStyle(Theme.text3)
        }
    }

    private var wipeTitle: String {
        ["history": "清空聊天记录", "memory": "清空记忆", "both": "清空记忆与聊天记录"][wiping ?? ""] ?? ""
    }

    private var wipeMessage: String {
        switch wiping {
        case "history": return "将删除 \(counts.messages) 条消息。已提取的记忆保留。无法撤销。"
        case "memory": return "将删除 \(counts.memories) 条记忆。聊天记录保留，下次总结时会从现有的聊天记录重新提取。无法撤销。"
        case "both": return "将删除 \(counts.messages) 条消息与 \(counts.memories) 条记忆。角色卡本身保留。无法撤销。"
        default: return ""
        }
    }

    private func load() {
        chat = try? Repo.chat(chatId)
        stickerCount = ((try? Stickers.all()) ?? []).count
        if let c = chat, !c.isGroup, let cid = c.characterIds.first {
            do { counts = try ClearHistory.counts(cid) } catch { problem = "读不出条数：\(error.localizedDescription)" }
        }
    }

    private func wipe(_ which: String) {
        guard let c = chat, !c.isGroup, let cid = c.characterIds.first else { return }
        do {
            switch which {
            case "history":
                let r = try ClearHistory.run(charId: cid)
                done = "已清空 \(r.messages) 条消息"
            case "memory":
                let n = try ClearMemories.run(charId: cid)
                done = "已清空 \(n) 条记忆"
            default:
                let r = try ClearHistory.run(charId: cid)
                let n = try ClearMemories.run(charId: cid)
                done = "已清空 \(r.messages) 条消息、\(n) 条记忆"
            }
            problem = nil
            for own in (try? ClearHistory.ownChats(cid)) ?? [] {
                NotificationCenter.default.post(name: .eiraChatChanged, object: own.id)
            }
        } catch {
            problem = "清空失败：\(error.localizedDescription)"
        }
        wiping = nil
        load()
    }
}
