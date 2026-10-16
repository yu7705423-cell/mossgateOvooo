import SwiftUI

/// 角色能力（网页版 chat/pages/AbilitiesPage.js，ARCHITECTURE 4.646）。
///
/// 从前这一段在「联系」的编辑资料最下面，与头像、人设排在一起：人在聊天里想到「让角色发语音」，要先想到这算角色卡。
/// 现在入口在会话右上角菜单「这个角色 - 角色能力」（群聊是「成员的能力」，先选成员）；编辑资料上那一行只是走到这一页来，
/// 开关仍然只有这一份（第 5 条）。音色、生图提示词、锁脸跟着各自的能力挪到这一页（审计 #24），存的字段不变。
///
/// 最上面写明对所有角色生效的两处（「设定集 - 能力开关」关掉的、尚未开启的新功能）：两处是「与」的关系，
/// 这里只写状态，点过去改，不在这里另放一份开关。单项开着却不会生效时，在那一项下面写明原因（4.485，网页版 capnote.blockerOf）。
enum Abilities {
    struct Item: Identifiable {
        let key: String, cap: String, label: String
        var defaultOn = true
        var id: String { key }
    }

    /// 这一页上的开关与默认值，菜单上「已开启 N 项」按它数。顺序照网页版。
    /// 网页版这一页还有当日日程与随机事件：原生版的开关在会话菜单「日常与日记」中，同一个开关不放两处
    static let items: [Item] = [
        Item(key: "canSendVoice", cap: "voice", label: "语音"),
        Item(key: "canSendImage", cap: "image", label: "图片"),
        Item(key: "canSendSticker", cap: "sticker", label: "表情"),
        Item(key: "canTransfer", cap: "transfer", label: "转账"),
        Item(key: "canCall", cap: "ring", label: "通话"),
        Item(key: "canListen", cap: "listen", label: "一起听"),
        Item(key: "canSendGift", cap: "gift", label: "礼物"),
        Item(key: "canPact", cap: "pact", label: "约定"),
        Item(key: "canTakeout", cap: "takeout", label: "点外卖"),
        Item(key: "canPat", cap: "pat", label: "拍一拍"),
        Item(key: "canRemark", cap: "remark", label: "改备注"),
        Item(key: "canChangeLock", cap: "lockcode", label: "改锁屏密码"),
        Item(key: "canRecall", cap: "recall", label: "撤回"),
        Item(key: "canReact", cap: "react", label: "回应"),
        Item(key: "canSilence", cap: "silence", label: "不回复", defaultOn: false),
        Item(key: "canDice", cap: "dice", label: "骰子"),
        Item(key: "canSendLocation", cap: "location", label: "位置"),
        Item(key: "canAward", cap: "award", label: "颁发标识"),
    ]

    static func item(_ key: String) -> Item? { items.first(where: { $0.key == key }) }

    static func isOn(_ it: Item, _ char: Character?) -> Bool {
        let v = char?.row[it.key]?.bool
        return it.defaultOn ? v != false : v == true
    }

    static func isOn(_ key: String, _ char: Character?) -> Bool {
        guard let it = item(key) else { return false }
        return isOn(it, char)
    }

    /// 菜单与编辑资料上那一行的右边：开着几项（网页版 abilityCount）
    static func countLabel(_ char: Character?) -> String {
        guard let char else { return "" }
        return "已开启 \(items.filter { isOn($0, char) }.count) 项"
    }

    /// 这一页上的能力里，已在全局关掉的那几项的名字
    static func shut(_ s: AppSettings) -> [String] {
        let off = CapsView.off(s)
        return items.filter { off.contains($0.cap) }.map(\.label)
    }

    /// 尚未开启的新功能（对所有角色生效）
    static func fresh(_ s: AppSettings) -> [String] {
        NewFeat.features.filter { !NewFeat.isOn($0.id, s) }.map(\.label)
    }

    /// 某一项能力开着却不会生效的原因；没有就回空串（网页版 capnote.blockerOf）。
    /// 只查与具体会话无关的那几条。网页版「曲库为空」一条在原生版不成立：原生版直连网易云，曲库空着也能点歌（ChatPrompt 的 listen）
    static func blocker(_ cap: String, char: Character?, _ s: AppSettings) -> String {
        if CapsView.off(s).contains(cap) { return "已在「设定集 - 能力开关」中关闭，此处开启不会生效" }
        if !NewFeat.capOn(cap, s) { return "这是新功能，尚未在「设定集 - 能力开关」的「新功能」中开启，此处开启暂不生效" }
        if cap == "image" && !s.imageReady { return "尚未配置生图接口，配置后生效" }
        if cap == "voice" && !s.voiceReady { return "尚未配置语音接口，配置后生效" }
        if cap == "voice", let char, let p = s.activeVoice, VoiceGen.voiceId(char, presetId: p.id).isEmpty {
            return "当前语音接口上尚未填写这个角色的音色，填写后生效"
        }
        return ""
    }
}

struct AbilitiesPage: View {
    let charId: String
    @ObservedObject private var model = SettingsModel.shared
    @State private var char: Character?
    @State private var missing = false
    @State private var stickerCount = 0
    @State private var problem: String?

    var body: some View {
        Form {
            if missing {
                Section { Text("该角色已不存在。").foregroundStyle(Theme.text2) }
            } else {
                everyone
                Section {
                    // 每组不超过十个子视图
                    Group {
                    ability("canSendVoice")
                    HelpNote("角色会在合适时以语音代替文字。音色、风格、语种与语速在下方「语音」中填写。", title: "角色能力：语音")
                    ability("canSendImage")
                    HelpNote("角色会在合适时描述画面，交由生图接口生成。这个角色的生图提示词与锁脸在下方「生图」中设置。", title: "角色能力：图片")
                    ability("canSendSticker", detail: stickerCount > 0 ? "可用表情 \(stickerCount) 个" : "尚无表情包，导入表情后生效")
                    HelpNote("表情名称会随对话一并提供给角色，由角色自行选用。", title: "角色能力：表情")
                    ability("canTransfer")
                    HelpNote("角色可以转账给你，也可以收下或退回你转过去的款项。关闭后角色不再转账，你转过去的款项也将无人处理。", title: "角色能力：转账")
                    ability("canCall")
                    HelpNote("角色可以接听你的来电，也可以主动打给你。关闭后两者都不再发生。", title: "角色能力：通话")
                    }
                    Group {
                    ability("canListen")
                    HelpNote("角色可以拉你一起听歌、点歌、分享歌曲与建自己的歌单。", title: "角色能力：一起听")
                    ability("canSendGift")
                    HelpNote("角色可以送礼物给你，也可以拆开或拒收你送的礼物。礼物封面与实际内容可以不一致。", title: "角色能力：礼物")
                    ability("canPact")
                    HelpNote("角色可以提出约定，也可以把做到的约定标记为完成。约定记在情侣空间中。", title: "角色能力：约定")
                    ability("canTakeout")
                    HelpNote("角色可以给自己点、请你吃，也可以让你代付。你点给它的那一单，它可以收下或谢绝。", title: "角色能力：点外卖")
                    ability("canPat")
                    HelpNote("角色可以主动拍你。你双击角色头像也可以拍它，无论此项开关。", title: "角色能力：拍一拍")
                    }
                    Group {
                    ability("canRemark")
                    HelpNote("角色可以修改你在它通讯录里的备注，会话中会出现一行提示。查看角色的手机时显示这个备注。", title: "角色能力：改备注")
                    ability("canChangeLock")
                    HelpNote("角色可以自己修改手机的锁屏密码，会话中会出现一行提示，不显示新密码。离上一次修改不满设定的天数时不会修改，聊到密码时不受此限。", title: "角色能力：改锁屏密码")
                    if let char, Abilities.isOn("canChangeLock", char) {
                        Stepper("两次修改至少间隔 \(Theirs.lockGap(char)) 天", value: Binding(
                            get: { Theirs.lockGap(char) },
                            set: { patch(["lockGapDays": .number(Double($0))]) }), in: 0...365)
                        HelpNote("填 0 表示不限制。", title: "改锁屏密码的间隔")
                    }
                    }
                    Group {
                    ability("canRecall")
                    HelpNote("角色可以撤回自己刚发出的消息。撤回的内容折叠显示，点击仍可查看。", title: "角色能力：撤回")
                    ability("canReact")
                    HelpNote("角色可以对一条消息贴一个 emoji 回应，显示在该消息的气泡下方。角色可以只回应而不发消息，此时会话中显示「已读，仅回应」。", title: "角色能力：回应")
                    ability("canSilence", detail: "此时会话中显示「已读，未回复」，这一次仍计入接口调用")
                    HelpNote("开启后，角色可以选择不回复。关闭后，角色每次都会回复。", title: "角色能力：不回复")
                    }
                    Group {
                    ability("canDice")
                    HelpNote("角色可以掷骰子。点数由本机随机决定，角色要到下一轮才知道结果。", title: "角色能力：骰子")
                    ability("canSendLocation")
                    HelpNote("角色会发送所在地的地点。设置了所在时区时以时区为准，未设置时依据人设判断。", title: "角色能力：位置")
                    ability("canAward")
                    HelpNote("角色可以给你颁发一枚互动标识，记进这段对话的标识收藏。", title: "角色能力：颁发标识")
                    }
                } header: {
                    Text("角色可主动发送的内容")
                } footer: {
                    Text("以上各项随回复一起完成，不另调接口。")
                }
                voiceSection
                imageSection
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("角色能力")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    // MARK: - 对所有角色生效

    @ViewBuilder private var everyone: some View {
        let shut = Abilities.shut(model.s)
        let fresh = Abilities.fresh(model.s)
        if !shut.isEmpty || !fresh.isEmpty {
            Section {
                if !shut.isEmpty {
                    NavigationLink { CapsView() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent("已在全局关闭", value: "\(shut.count) 项")
                            Text("\(shut.joined(separator: "、"))。这几项在下方开启也不会生效。")
                                .font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                    HelpNote("位于「设定集 - 能力开关」，对所有角色生效。与这一页是「与」的关系：两处都开启才生效。", title: "已在全局关闭")
                }
                if !fresh.isEmpty {
                    NavigationLink { CapsView() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent("尚未开启的新功能", value: "\(fresh.count) 项")
                            Text(fresh.joined(separator: "、")).font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                    HelpNote("新加的功能默认不写进提示词，开启后对所有角色生效。开关位于「设定集 - 能力开关」最上面的「新功能」。", title: "尚未开启的新功能")
                }
            } header: {
                Text("对所有角色生效")
            }
        }
    }

    // MARK: - 一项能力

    /// 开关一行；开着却不会生效时，下面写明原因（两版都显示）
    @ViewBuilder private func ability(_ key: String, detail: String = "") -> some View {
        if let it = Abilities.item(key) {
            let on = Abilities.isOn(it, char)
            let why = on ? Abilities.blocker(it.cap, char: char, model.s) : ""
            VStack(alignment: .leading, spacing: 2) {
                Toggle(it.label, isOn: Binding(get: { Abilities.isOn(it, char) }, set: { patch([it.key: .bool($0)]) }))
                let note = [detail, why].filter { !$0.isEmpty }.joined(separator: "。")
                if !note.isEmpty {
                    Text(note + "。").font(.footnote).foregroundStyle(why.isEmpty ? Theme.text2 : Theme.dangerText)
                }
            }
        }
    }

    // MARK: - 语音（从编辑资料挪来，字段不变）

    @ViewBuilder private var voiceSection: some View {
        if let char, Abilities.isOn("canSendVoice", char) {
            let s = model.s
            Section {
                if s.voicePresets.isEmpty {
                    Text("尚未配置语音接口。").foregroundStyle(Theme.text2)
                }
                ForEach(s.voicePresets) { p in
                    TextField(p.id == s.activeVoice?.id ? "音色 ID · \(p.name)（当前使用）" : "音色 ID · \(p.name)", text: Binding(
                        get: { VoiceGen.voiceId(self.char, presetId: p.id) },
                        set: { v in
                            guard let c = self.char else { return }
                            patch(VoiceGen.voiceIdPatch(c, presetId: p.id, id: v.trimmingCharacters(in: .whitespaces)))
                        }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                TextField("风格（留空用接口的默认风格）", text: stringBinding("voicePrompt"))
                Picker("语种", selection: stringBinding("voiceLang")) {
                    ForEach(VoicePreset.langs) { Text($0.id.isEmpty ? "跟随接口" : $0.label).tag($0.id) }
                }
                Stepper("语速 \(String(format: "%.1f", char.row.number("voiceSpeed") ?? 1))", value: Binding(
                    get: { self.char?.row.number("voiceSpeed") ?? 1 },
                    set: { patch(["voiceSpeed": .number(($0 * 10).rounded() / 10)]) }), in: 0.5...2, step: 0.1)
            } header: {
                Text("语音")
            } footer: {
                if s.voiceReady {
                    Text("每条语音调用一次语音接口。")
                }
                HelpNote("音色按语音接口分别填写，切换接口时音色随之切换。接口与模型在「设置 - 接口与服务 - 语音合成」中配置。风格与语种留空时使用接口自己的设置。", title: "语音")
            }
        }
    }

    // MARK: - 生图（从编辑资料挪来，字段不变）

    @ViewBuilder private var imageSection: some View {
        if let char, Abilities.isOn("canSendImage", char) {
            Section {
                TextField("这个角色的生图提示词", text: stringBinding("imagePrompt"), axis: .vertical).lineLimit(2...10)
                NavigationLink { FaceLockView(owner: .char(charId)) } label: {
                    LabeledContent("锁脸", value: faceLabel(char))
                }
            } header: {
                Text("生图")
            } footer: {
                HelpNote("生图提示词接在这个角色发的每一张图的画面描述后面，全局提示词在「设置 - 生图」中设置，两者都会生效。锁脸让这个角色每次生成的长相保持一致。外貌在「联系」的编辑资料中填写。", title: "生图")
            }
        }
    }

    private func faceLabel(_ c: Character) -> String {
        let n = FaceLock.faces(c.row).count
        if n == 0 { return "未上传" }
        switch FaceLock.mode(c.row) {
        case "off": return "\(n) 张 · 关闭"
        case "always": return "\(n) 张 · 始终"
        default: return "\(n) 张"
        }
    }

    // MARK: - 读写

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(get: { self.char?.row.string(key) ?? "" }, set: { patch([key: .string($0)]) })
    }

    private func load() {
        do {
            char = try Repo.character(charId)
            missing = char == nil
            stickerCount = try Database.shared.all("stickers").count
        } catch {
            problem = "读取失败：\(error.localizedDescription)"
        }
    }

    /// 随改随存。写不进去在屏幕上说（第 20 条）
    private func patch(_ fields: [String: JSONValue]) {
        do {
            guard let c = try Repo.character(charId) ?? char else { return }
            char = try People.update(c, fields)
            problem = nil
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
        }
    }
}

/// 群聊菜单里的「成员的能力」（网页版群聊菜单先选成员，再进同一页）
struct GroupAbilitiesView: View {
    let chatId: String
    @State private var members: [Character] = []
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                if members.isEmpty { Text("群里没有成员。").foregroundStyle(Theme.text2) }
                ForEach(members) { c in
                    NavigationLink { AbilitiesPage(charId: c.id) } label: {
                        HStack(spacing: Theme.gap) {
                            Avatar(imageId: c.avatar, name: c.name, size: 32)
                            LabeledContent(c.remark.isEmpty ? c.name : c.remark, value: Abilities.countLabel(c))
                        }
                    }
                }
            } footer: {
                HelpNote("各成员的能力开关属于那个角色本身，在这里改动后，与该角色的单聊同样生效。", title: "成员的能力")
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("成员的能力")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    /// 返回时重读：子页里改过的开关数要跟上
    private func load() {
        do {
            guard let chat = try Repo.chat(chatId) else { members = []; return }
            members = try chat.characterIds.compactMap { try Repo.character($0) }
            problem = nil
        } catch {
            problem = "读取失败：\(error.localizedDescription)"
        }
    }
}
