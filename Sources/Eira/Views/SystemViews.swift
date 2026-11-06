import SwiftUI

/// 「设置 - 消息通知」里的系统来电界面（SystemCall，网页版 4.895）
struct CallKitSection: View {
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var call = SystemCall.shared
    @State private var testing = false
    @State private var note: String?

    var body: some View {
        Section {
            Toggle("系统来电界面", isOn: model.bool("callKit", false))
            if SystemCall.isOn(model.s) {
                if let l = call.last {
                    Text(l.ok ? "上一次（\(When.show(l.at))）已弹出。" : "上一次（\(When.show(l.at))）未能弹出：\(l.error)")
                        .font(.footnote).foregroundStyle(l.ok ? Theme.secondaryText : Theme.danger)
                }
                Button(testing ? "3 秒后响铃" : "试一次系统来电") { runTest() }.disabled(testing)
                if let note { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) }
            }
        } header: {
            Text("来电")
        } footer: {
            HelpNote("开启后，角色打来电话而你没有在看那段会话时，用 iPhone 自己的来电界面响铃，锁屏时整屏显示。接听后打开那段会话并直接接通；拒接记为已拒接，三十秒无人接听记为未接来电。系统来电界面弹不出来时，照旧记一条未接来电并发一条来电通知。通话不进入系统「电话」的最近通话。选了 Eira 推送时，应用关闭期间角色打来的电话同样在这里响铃。关闭后，没有在看那段会话时角色打来的电话直接记为未接来电。不增加接口调用。", title: "系统来电界面")
        }
    }

    private func runTest() {
        testing = true
        note = "请在 3 秒内锁屏或切到其他应用。"
        Task {
            let why = await call.test()
            note = why == nil ? "已弹出测试来电。" : why
            testing = false
        }
    }
}

/// 「设置 - 后台消息」里的通知通道：Eira 推送（EiraPush，网页版 4.896、4.948）
struct EiraPushSection: View {
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var push = EiraPush.shared
    @State private var relay = EiraPush.relay()
    @State private var note: String?
    @State private var noteIsError = false
    @State private var testing = false
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let reg = EiraPush.registration()
        let on = EiraPush.selected(model.s) && reg != nil
        Section {
            TextField("https://eira-apns.example.workers.dev", text: $relay)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .disabled(push.busy)
                .onChange(of: relay) { _, v in EiraPush.setRelay(v) }
            LabeledContent("Eira 推送", value: push.busy ? "正在登记" : on ? "已登记，\(When.show(reg?.at ?? 0))" : "尚未登记")
            if on {
                if !AppGroup.shared { Text("通知扩展读不到密钥，锁屏上只显示「收到一条新消息」。").font(.footnote).foregroundStyle(Theme.danger) }
                if reg?.voip == nil { Text("来电推送不可用：系统没有给来电推送的地址。").font(.footnote).foregroundStyle(Theme.danger) }
            }
            Button(on ? "重新登记" : "登记") { register() }.disabled(push.busy || !EiraPush.relayOk(relay))
            if on {
                Button(testing ? "正在发送" : "经推送转发试一条") { test() }.disabled(testing)
                Button("停用 Eira 推送", role: .destructive) {
                    Task { await push.unregister(); note = "已停用。"; noteIsError = false; tick += 1 }
                }
            }
            if let note { Text(note).font(.footnote).foregroundStyle(noteIsError ? Theme.danger : Theme.secondaryText) }
            if !push.problem.isEmpty { Text(push.problem).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("通知通道")
        } footer: {
            HelpNote("登记后，后台消息服务器替角色发出消息时，经推送转发送到锁屏上；角色在消息里打电话、并且开启了「系统来电界面」时，响系统来电。应用关闭时同样送达。推送转发只看到加密后的内容：加密密钥由本机生成，只交给你自己的后台消息服务器。登记记在这台手机上，不随备份导出。停用后，消息在打开应用时取回。不增加接口调用。", title: "Eira 推送")
        }
    }

    private func register() {
        note = "正在登记。"
        noteIsError = false
        Task {
            do {
                try await push.register()
                note = "已登记。" + (BgPush.isOn() ? "" : "开启后台消息后生效。")
                noteIsError = false
            } catch {
                note = error.localizedDescription
                noteIsError = true
            }
            tick += 1
        }
    }

    private func test() {
        testing = true
        Task {
            do { try await EiraPush.test(); note = "已发出一条测试推送。"; noteIsError = false }
            catch { note = error.localizedDescription; noteIsError = true }
            testing = false
        }
    }
}

/// 「设置 - 主题」里的 iPhone 桌面组件（WidgetFeed，网页版 4.941）：显示哪个角色
struct IosWidgetSection: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var chars: [Character] = []

    var body: some View {
        Section {
            Picker("角色此刻", selection: Binding(get: { model.s.raw["iosWidgetChar"]?.string ?? "" }, set: { v in
                model.set("iosWidgetChar", .string(v))
                WidgetFeed.sync()
            })) {
                Text("自动").tag("")
                ForEach(chars) { c in Text(c.displayName).tag(c.id) }
            }
            .pickerStyle(.navigationLink)
            if !AppGroup.shared {
                Text("这个安装包没有分到共用存储，桌面组件读不到数据。").font(.footnote).foregroundStyle(Theme.danger)
            }
        } header: {
            Text("iPhone 桌面组件")
        } footer: {
            HelpNote("在 iPhone 主屏幕长按空白处、点左上角添加小组件，选择 Eiraowo。「角色此刻」显示所选角色今天的日程中此刻这一时段的安排，到点自动切换；选择「自动」时取最近聊过、开启了当日日程的角色。「健康」组件上点按即记一杯水、一次排便或一样药，下次打开本应用时计入健康记录。组件只显示本机已有的数据，不调用接口。", title: "iPhone 桌面组件")
        }
        .onAppear { chars = ((try? Repo.characters()) ?? []).filter { !$0.isNpc } }
    }
}
