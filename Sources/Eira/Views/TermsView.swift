import SwiftUI

/// 使用须知，随时重看（网页版 settings/TermsPage.js 与 system/terms.js 的 NOTICE，ARCHITECTURE 4.246、4.619）。只读。
/// 内测结束后只剩使用须知这一份（4.619）。文字照抄网页版，网页版改了这里跟着改。
struct TermsView: View {
    struct Part {
        let title: String
        let body: [String]
    }

    static let title = "Eira 使用须知"
    static let intro = "在使用 Eira 前，请确认你符合以下条件，并阅读、理解以下说明："
    static let sections: [Part] = [
        Part(title: "1. 使用资格", body: ["Eira 仅面向已年满 18 周岁的成年女性使用。未满 18 周岁者请勿使用。"]),
        Part(title: "2. 数据与隐私", body: [
            "Eira 本身不建立或保存云端聊天记录，聊天内容及相关数据原则上仅保存在你的本地设备中。",
            "生成回复时，对话内容会发送给你所配置的第三方接口服务商。你开启「后台消息」「云端备份」等功能时，相关数据会发送到你自己配置的服务器或账号。接口密钥仅保存在本机。清除浏览器数据、卸载应用或更换设备，可能导致本地数据丢失，请定期备份。",
        ]),
        Part(title: "3. AI 生成内容", body: [
            "第三方 API 生成的内容属于自动生成内容，不代表 Eira 或相关服务商的立场、观点、承诺或建议。AI 生成内容可能存在错误、遗漏、虚构、不准确、不完整或不适用于特定情境的情况，不应被视为专业的法律、医疗、财务或其他专业意见。",
            "你应根据实际情况独立判断，并在必要时向具备相应资质的专业人士寻求帮助。对于 AI 生成内容的阅读、采用、修改、保存、传播或其他使用方式，请务必谨慎。",
        ]),
        Part(title: "4. 费用", body: [
            "接口费用由第三方服务商向你收取，Eira 不收取任何费用。每次生成、重试以及开启的自动功能都会产生调用，调用情况可在「设置 - 用量与上限」和「后台任务」中查看。",
        ]),
        Part(title: "5. 情感与现实边界", body: [
            "Eira 中的内容均由 AI 生成，无法替代专业人士的帮助。请重视现实中的人际关系与专业支持；如果你正经历难以承受的情绪困扰，请及时向身边信任的人或专业人士寻求帮助。",
        ]),
        Part(title: "6. 法律、平台规则与用户责任", body: [
            "你应自行确保通过 Eira 生成、输入、使用、保存、分享或传播的内容，符合你所在地区适用的法律法规，以及所使用的第三方服务、API 和相关平台的服务条款、内容政策及其他规则。",
            "不得利用 Eira 从事违法活动，侵犯他人隐私、著作权、商标权、名誉权或其他合法权益，或规避第三方服务的限制与安全措施。",
            "因用户自行输入、生成、使用、保存、分享或传播相关内容，或因用户违反适用法律法规、第三方服务规则而产生的责任、损失或争议，由用户自行承担。Eira 不对第三方 API 的可用性、准确性、持续性或其数据处理行为作出保证。",
        ]),
        Part(title: "7. 关于酒馆人设与世界书", body: [
            "不支持在 Eira 内直接使用、导入或运行来自「酒馆 / Tavern」的人设、世界书及相关角色设定文件。",
        ]),
        Part(title: "8. 好友与联机群", body: [
            "好友之间与联机群内的消息在设备上加密后发出，只有群内成员的设备能解开。服务器只转交密文，送达后删除，最多保留七天；运营方无法读取消息内容。",
            "服务器保存的只有：账号、设备公钥、好友关系与拉黑记录、群成员名单与轮次、加密后的消息与文件。昵称、群名、角色名单同样以加密消息传递。",
            "群内角色由其主人的设备生成回复：近期的群聊内容会发送至该角色主人所配置的模型接口，费用由该主人承担。角色的人设与记忆只在主人的设备上读取，不发给群内任何人。",
            "举报时，只有举报人自己选择提交的那几条消息会以明文发送给管理员；除此之外管理员看不到任何聊天内容。",
            "加密身份保存在本设备上，不进入备份。更换设备或恢复备份后，群内其他成员的设备会为新设备补发密钥；此前的消息以备份中已解开的为准。",
            "超过 15 天未打开应用的设备会在服务器上自动注销，期间发给它的消息无法再取回；好友关系与群保留，再次打开应用后自动重新登记并补发密钥。",
        ]),
    ]
    static let outro = "继续使用 Eira，即表示你已阅读并理解以上说明，并确认自己符合 Eira 的使用条件。"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sp4) {
                Text(Self.intro)
                ForEach(Self.sections, id: \.title) { s in
                    VStack(alignment: .leading, spacing: Theme.sp2) {
                        Text(s.title).font(.headline)
                        ForEach(Array(s.body.enumerated()), id: \.offset) { _, p in
                            Text(p)
                        }
                    }
                }
                Text(Self.outro).foregroundStyle(Theme.text2)
            }
            .font(.system(size: 15))
            .lineSpacing(5)
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.pad * 2)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(Self.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
