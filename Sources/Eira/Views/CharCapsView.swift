import SwiftUI

/// 角色卡上的「角色可主动发送的内容」（网页版 CharacterEdit 的能力那一组）：这个角色能不能发语音、打电话、转账……
/// 开关属于这个角色，放在角色卡上（第 5 条）。全局「能力开关」与这里是「与」的关系：全局关了，这里开着也不生效，页上写明
struct CharCapsView: View {
    let charId: String
    @ObservedObject private var model = SettingsModel.shared
    @State private var char: Character?
    @State private var lockGap = 30
    @State private var problem: String?

    struct Item: Identifiable {
        let key: String, cap: String, label: String, info: String
        var defaultOn = true
        var id: String { key }
    }

    static let items: [Item] = [
        Item(key: "canSendVoice", cap: "voice", label: "语音", info: "角色可以发语音消息，由语音接口合成。需要在「语音」中为该角色填写音色"),
        Item(key: "canSendImage", cap: "image", label: "图片", info: "角色可以描述画面，交由生图接口生成"),
        Item(key: "canSendSticker", cap: "sticker", label: "表情", info: "角色可以从表情库里选用表情。表情名称随对话一并提供给角色"),
        Item(key: "canTransfer", cap: "transfer", label: "转账", info: "角色可以转账，也可以收下或退回你的转账。关闭后你转过去的款项无人处理"),
        Item(key: "canCall", cap: "ring", label: "通话", info: "角色可以接听你的来电，也可以主动打给你。关闭后两者都不再发生"),
        Item(key: "canListen", cap: "listen", label: "一起听", info: "角色可以拉你一起听歌、点歌、分享歌曲与建歌单"),
        Item(key: "canSendGift", cap: "gift", label: "礼物", info: "角色可以送礼物，也可以拆开或拒收你送的礼物"),
        Item(key: "canPact", cap: "pact", label: "约定", info: "角色可以提出约定，也可以把做到的约定标记为完成"),
        Item(key: "canTakeout", cap: "takeout", label: "点外卖", info: "角色可以给自己点、请你吃，也可以让你代付；你点给它的那一单，它可以收下或谢绝"),
        Item(key: "canPat", cap: "pat", label: "拍一拍", info: "角色可以主动拍你。你双击角色头像拍它不受此项影响"),
        Item(key: "canRemark", cap: "remark", label: "改备注", info: "角色可以修改给你的备注，会话中出现一行提示"),
        Item(key: "canChangeLock", cap: "lockcode", label: "改锁屏密码", info: "角色可以修改自己手机的锁屏密码，会话中出现一行提示，不显示新密码"),
        Item(key: "canRecall", cap: "recall", label: "撤回", info: "角色可以撤回自己刚发出的消息。撤回的内容折叠显示，点击仍可查看"),
        Item(key: "canReact", cap: "react", label: "回应", info: "角色可以对一条消息贴一个 emoji 回应；可以只回应而不发消息"),
        Item(key: "canSilence", cap: "silence", label: "不回复", info: "角色可以选择不回复，此时会话中显示「已读，未回复」。这一次仍计入接口调用", defaultOn: false),
        Item(key: "canDice", cap: "dice", label: "骰子", info: "角色可以掷骰子。点数由本机随机决定，角色下一轮才知道结果"),
        Item(key: "canSendLocation", cap: "location", label: "位置", info: "角色可以发送所在地的地点"),
        Item(key: "canAward", cap: "award", label: "颁发标识", info: "角色可以给你颁发一枚互动标识"),
    ]

    var body: some View {
        let off = CapsView.off(model.s)
        Form {
            Section {
                ForEach(Self.items) { it in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(it.label, isOn: Binding(get: { isOn(it) }, set: { set(it.key, $0) }))
                        if off.contains(it.cap) && isOn(it) {
                            Text("已在「设定集 - 能力开关」中关闭，此处开着也不生效。").font(.footnote).foregroundStyle(Theme.text2)
                        }
                        HelpNote(it.info + "。关闭后提示词中不出现这一项。", title: "角色能力：\(it.label)")
                    }
                    if it.key == "canChangeLock" && isOn(it) {
                        Stepper("两次修改至少间隔 \(lockGap) 天", value: $lockGap, in: 0...365)
                            .onChange(of: lockGap) { _, v in setValue("lockGapDays", .number(Double(v))) }
                    }
                }
            } footer: {
                Text("这些能力都随回复一起完成，不另调接口。")
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("角色能做的事")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            char = (try? Repo.character(charId)) ?? nil
            if let char { lockGap = Theirs.lockGap(char) }
        }
    }

    private func isOn(_ it: Item) -> Bool {
        let v = char?.row[it.key]?.bool
        return it.defaultOn ? v != false : v == true
    }

    private func set(_ key: String, _ v: Bool) { setValue(key, .bool(v)) }

    private func setValue(_ key: String, _ v: JSONValue) {
        guard let c = char else { return }
        do { char = try People.update(c, [key: v]); problem = nil }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}
