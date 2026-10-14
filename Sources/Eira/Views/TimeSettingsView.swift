import SwiftUI

/// 时间感知（网页版 TimePage.js，ARCHITECTURE 4.67、4.369）。全局设置，对所有会话生效。
/// 会话设置里那一行只是进这一页的路，开关与时区只在这一页里。
struct TimeSettingsView: View {
    @ObservedObject private var settings = SettingsModel.shared
    @State private var chars: [Character] = []
    @State private var problem: String?

    private var s: AppSettings { settings.s }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            form(real: ctx.date)
        }
        .navigationTitle("时间感知")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func form(real: Date) -> some View {
        let on = Clock.enabled(s)
        let virtual = s.raw["timeMode"]?.string == "virtual"
        let now = Clock.now(s, real: real)
        let uz = Clock.userZone(s)
        return Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                Toggle("时间感知", isOn: settings.bool("injectTime", true))
            } footer: {
                Text(on ? "向角色提供当前时间、双方时差与距上次对话的间隔。" : "关闭状态下，角色不知道当前日期与时间，也不知道距上次对话过去了多久。")
            }
            if on {
                Section {
                    Toggle("要求角色写出时间", isOn: settings.bool("timeStamp", true))
                } footer: {
                    Text("角色每条回复先输出一行当地时间，界面上过滤不显示。仅在设定中告知时间，模型往往不会真正参照；要求其输出一次，时间才会进入推理。")
                }
                Section {
                    Picker("时间来源", selection: Binding(get: { virtual ? "virtual" : "real" }, set: { setMode($0) })) {
                        Text("系统时间").tag("real")
                        Text("自定义").tag("virtual")
                    }
                    .pickerStyle(.segmented)
                    if virtual {
                        DatePicker("起始时刻", selection: Binding(
                            get: { Date(millis: s.raw["timeVirtualAt"]?.number ?? real.millis) },
                            set: { d in settings.update { for (k, v) in Clock.virtualPatch(d, frozen: s.raw["timeFrozen"]?.bool == true) { $0.raw[k] = v } } }))
                        Button("校准到当前时间") {
                            settings.update { for (k, v) in Clock.virtualPatch(Date(), frozen: false) { $0.raw[k] = v } }
                        }
                        Toggle("固定时刻", isOn: settings.bool("timeFrozen", false))
                    }
                } footer: {
                    Text(virtual ? "自设定的时刻起继续推进，而非固定在该时刻。开启「固定时刻」后时间不再推进，始终停留在设定的时刻。" : "采用本设备的系统时间。")
                }
                Section {
                    Picker("本人所在时区", selection: Binding(get: { uz }, set: { settings.set("timeZoneUser", .string($0)) })) {
                        ForEach(zoneChoices(uz), id: \.id) { Text($0.label).tag($0.id) }
                    }
                } header: { Text("所在时区") }
                if !chars.isEmpty {
                    Section {
                        ForEach(chars) { c in
                            Picker(selection: Binding(get: { c.row.string("timezone") }, set: { setCharZone(c, $0) })) {
                                Text("与本人相同").tag("")
                                ForEach(zoneChoices(c.row.string("timezone")).filter { $0.id != Clock.local }, id: \.id) { Text($0.label).tag($0.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.displayName)
                                    Text(Clock.clockOnly(now, zone: Clock.charZone(c, s))).font(.caption).foregroundStyle(Theme.text3)
                                }
                            }
                        }
                    } header: {
                        Text("角色所在时区")
                    } footer: {
                        Text("与角色卡中的同一项是同一份。未单独设置的角色，视为与本人处于同一时区。")
                    }
                }
                Section {
                    VStack(spacing: 4) {
                        Text(Clock.clockOnly(now, zone: uz)).font(.system(size: 40, weight: .light).monospacedDigit())
                        Text("\(TimeText.format(now, zone: Clock.zone(uz))) · \(Clock.label(uz))").font(.footnote).foregroundStyle(Theme.text2)
                        Text(virtual ? (s.raw["timeFrozen"]?.bool == true ? "自定义时间 · 已固定" : "自定义时间 · 持续推进") : "系统时间")
                            .font(.caption).foregroundStyle(Theme.text3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.sp2)
                }
            }
        }
    }

    /// 列表里没有的时区（别处填的 IANA 名）也放进去，免得选择器显示空白
    private func zoneChoices(_ current: String) -> [(id: String, label: String)] {
        var list = Clock.zones
        if !current.isEmpty && !list.contains(where: { $0.id == current }) { list.append((current, current)) }
        return list
    }

    private func setMode(_ m: String) {
        settings.update { st in
            if m == "virtual" && (st.raw["timeVirtualAt"]?.number ?? 0) <= 0 {
                for (k, v) in Clock.virtualPatch(Date(), frozen: false) { st.raw[k] = v }
            }
            st.raw["timeMode"] = .string(m)
        }
    }

    private func setCharZone(_ c: Character, _ z: String) {
        do {
            _ = try People.update(c, ["timezone": .string(z)])
            load()
        } catch {
            problem = "时区未能保存：\(error.localizedDescription)"
        }
    }

    private func load() {
        chars = ((try? Repo.characters()) ?? []).filter { ($0.row["parentId"]?.string ?? "").isEmpty && !$0.row.bool("isNpc") }
    }
}
