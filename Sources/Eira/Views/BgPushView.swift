import SwiftUI

/// 「设置 - 后台消息」：应用不在前台时，由你自己部署的服务器代角色主动发起对话（网页版 设置 - 通知 - 后台消息）。
struct BgPushView: View {
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var bg = BgPush.shared
    @State private var busy = false
    @State private var note: String?
    @State private var noteIsError = false

    var body: some View {
        Form {
            Section {
                TextField("https://push.example.workers.dev", text: serverBinding)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .disabled(BgPush.isOn(model.s))
            } header: {
                Text("服务器地址")
            } footer: {
                HelpNote("与网页版同一台后台消息服务器（worker/push.js），部署步骤见网页版「部署教程」。开启后，地址需先关闭才能修改。")
            }
            Section {
                Toggle("后台消息", isOn: Binding(get: { BgPush.isOn(model.s) }, set: toggle))
                    .disabled(busy)
                if BgPush.isOn(model.s) {
                    Stepper("每个角色离开期间最多 \(BgPush.perChar(model.s)) 次", value: perCharBinding, in: 1...10)
                }
                if let note { Text(note).font(.footnote).foregroundStyle(noteIsError ? Theme.danger : Theme.secondaryText) }
                if !bg.problem.isEmpty { Text(bg.problem).font(.footnote).foregroundStyle(Theme.danger) }
            } footer: {
                Text("开启后，接口密钥与聊天上下文交给后台消息服务器保管。")
                HelpNote("开启后，应用退到后台时，开了「主动发起对话」的角色接下来几次开口的时间，连同到时候发给模型的那一次完整请求（含接口密钥与聊天上下文），一起交给上面的服务器；服务器加密保存，到点代发，结果在打开应用时取回并落进会话。同一次开口只调用一次接口：应用在前台时由本机发，在后台时由服务器发；回到前台后先取回结果再恢复本机发送，取不回来时本机也不发。原生版收不到推送通知，消息在打开应用时出现。")
            }
        }
        .navigationTitle("后台消息")
    }

    private var serverBinding: Binding<String> {
        Binding(get: { BgPush.config(model.s)["server"]?.string ?? "" },
                set: { v in model.update { s in
                    var c = BgPush.config(s)
                    c["server"] = .string(v.trimmingCharacters(in: .whitespacesAndNewlines))
                    s.raw["bgPush"] = .object(c)
                } })
    }

    private var perCharBinding: Binding<Int> {
        Binding(get: { BgPush.perChar(model.s) },
                set: { v in model.update { s in
                    var c = BgPush.config(s)
                    c["perChar"] = .number(Double(v))
                    s.raw["bgPush"] = .object(c)
                } })
    }

    private func toggle(_ on: Bool) {
        busy = true
        note = nil
        Task {
            do {
                if on { try await bg.enable(); note = "已开启。"; noteIsError = false }
                else { await bg.disable(); note = "已关闭，服务器上这台设备的任务已删除。"; noteIsError = false }
            } catch {
                note = error.localizedDescription
                noteIsError = true
            }
            busy = false
        }
    }
}
