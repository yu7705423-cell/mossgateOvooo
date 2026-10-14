import SwiftUI
import UIKit

/// 「设置 - 消息通知」：角色主动发来消息时弹通知。全局的，放在设置里。
struct NotifyView: View {
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var notifier = Notifier.shared
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                Toggle("消息通知", isOn: Binding(get: { Notifier.isOn(model.s) }, set: toggle))
                if Notifier.isOn(model.s) {
                    Toggle("通知里显示消息内容", isOn: model.bool("nativeNotifyText", true))
                }
                if let note { Text(note).font(.footnote).foregroundStyle(Theme.danger) }
            } footer: {
                HelpNote("开启后，开了「主动发起对话」的角色发来消息、而你没有在看那段会话时，弹出一条通知；开了免打扰的会话不弹。应用图标上的角标是全部会话的未读数。不增加接口调用。")
            }
            Section {
                LabeledContent("后台消息", value: BgPush.isOn(model.s) ? "开启" : "关闭")
            } footer: {
                HelpNote(BgPush.isOn(model.s)
                     ? "应用不在前台时，系统会不定时让应用醒来片刻，向后台消息服务器询问有没有角色发来的消息，有则弹出通知。询问不调用模型，不额外花钱；何时醒来由系统决定，可能延迟，系统设置中关闭「后台 App 刷新」后不会询问。消息本身在打开应用时取回。"
                     : "未开启后台消息时，只有应用在前台期间角色主动发来的消息会弹通知。后台消息在「设置 - 后台消息」中开启。")
            }
        }
        .navigationTitle("消息通知")
        .task { await notifier.refreshAuthorization() }
    }

    private func toggle(_ on: Bool) {
        note = nil
        if on {
            Task {
                let ok = await notifier.enable()
                if !ok { note = "未获得通知权限。可在系统「设置 - 通知 - Eiraowo」中允许后再开启。" }
            }
        } else {
            notifier.disable()
        }
    }
}
