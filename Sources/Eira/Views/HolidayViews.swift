import SwiftUI

/// 「设置 - 节日」（网页版 settings/HolidayPage.js，ARCHITECTURE 4.380）。按国家分组，勾着的节日在当天与之前三天告诉角色。
/// 生日与纪念日不在这里：它们来自角色卡、个人资料与情侣空间，不需要勾。
struct HolidaySettingsView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var name = ""
    @State private var lunar = false
    @State private var month = 1
    @State private var day = 1
    @State private var note: String?
    @State private var removing: Holidays.Custom?

    private var c: Holidays.Cfg { Holidays.cfg(model.s) }

    /// 设置根页那一行的状态
    static func summary(_ s: AppSettings) -> String {
        let c = Holidays.cfg(s)
        let names = Holidays.regions.filter { c.regions.contains($0.id) }.map(\.name).joined(separator: "、")
        let parts = [names, c.custom.isEmpty ? "" : "自定义 \(c.custom.count) 个"].filter { !$0.isEmpty }
        return parts.isEmpty ? "未勾选任何节日" : parts.joined(separator: "，")
    }

    var body: some View {
        let cfg = c
        return Form {
            if let p = model.problem { Text(p).foregroundStyle(Theme.danger) }
            Section {
                ForEach(Holidays.regions) { r in
                    NavigationLink { HolidayRegionView(regionId: r.id) } label: {
                        HStack {
                            Text(r.name)
                            Spacer()
                            Text(status(r, cfg)).font(.system(size: 13)).foregroundStyle(Theme.text3)
                        }
                    }
                }
            } header: {
                Text("按国家与地区")
            } footer: {
                HelpNote("勾选的节日在当天与之前三天作为日期信息写入提示词，只说明哪一天是什么节日，不要求角色做什么。取消勾选后，角色不再从这里得知该节日。不调用接口。生日与纪念日来自角色卡、个人资料与情侣空间，不需要在此勾选。", title: "节日")
            }

            Section {
                if cfg.custom.isEmpty {
                    Text("尚未添加").foregroundStyle(Theme.text3)
                } else {
                    ForEach(cfg.custom) { x in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(x.name)
                                Text("每年\(x.lunar ? "农历" : "公历") \(x.month) 月 \(x.day) 日")
                                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
                            }
                            Spacer()
                            Button("删除") { removing = x }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.danger)
                        }
                    }
                }
            } header: {
                Text("自定义")
            } footer: {
                HelpNote("添加的节日每年重复，与上方勾选的节日一同告诉角色。", title: "自定义节日")
            }

            Section {
                TextField("名称，例：社团成立日", text: $name)
                Picker("历法", selection: $lunar) {
                    Text("公历").tag(false)
                    Text("农历").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("月", selection: $month) {
                    ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) }
                }
                Picker("日", selection: $day) {
                    ForEach(1...(lunar ? 30 : 31), id: \.self) { Text("\($0) 日").tag($0) }
                }
                Button("添加节日", action: add)
                if let note { Text(note).font(.footnote).foregroundStyle(Theme.text2) }
            } header: {
                Text("添加节日")
            }
        }
        .navigationTitle("节日")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.reload() }
        .onChange(of: lunar) { _, isLunar in if isLunar && day > 30 { day = 30 } }
        .confirmationDialog("删除这个节日", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { x in
            Button("删除", role: .destructive) {
                model.update { Holidays.removeCustom(x.id, &$0) }
                removing = nil
            }
            Button("取消", role: .cancel) { removing = nil }
        } message: { x in
            Text("删除「\(x.name)」。删除后不再告诉角色。")
        }
    }

    private func status(_ r: Holidays.Region, _ cfg: Holidays.Cfg) -> String {
        guard cfg.regions.contains(r.id) else { return "未启用，共 \(r.list.count) 个" }
        let n = r.list.filter { !cfg.off.contains(Holidays.keyOf(r.id, $0)) }.count
        return "已勾选 \(n) / \(r.list.count) 个"
    }

    private func add() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, (1...12).contains(month), (1...(lunar ? 30 : 31)).contains(day) else {
            note = "请填写名称与有效的日期"
            return
        }
        var made: Holidays.Custom?
        model.update { made = Holidays.addCustom(name: n, month: month, day: day, lunar: lunar, &$0) }
        guard made != nil, model.problem == nil else { note = nil; return }
        name = ""
        note = "已添加"
    }
}

/// 一个国家或地区里的节日，逐个开关（网页版 HolidayRegionPage）
struct HolidayRegionView: View {
    let regionId: String
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        if let r = Holidays.regions.first(where: { $0.id == regionId }) {
            content(r)
        } else {
            Text("没有这个地区。").navigationTitle("节日")
        }
    }

    private func content(_ r: Holidays.Region) -> some View {
        let on = Holidays.regionOn(r.id, model.s)
        let year = Calendar.current.component(.year, from: Date())
        return Form {
            if let p = model.problem { Text(p).foregroundStyle(Theme.danger) }
            Section {
                Toggle("启用\(r.name)的节日", isOn: Binding(get: { Holidays.regionOn(r.id, model.s) },
                                                     set: { v in model.update { Holidays.setRegion(r.id, v, &$0) } }))
            } footer: {
                HelpNote(on ? "下方勾选的节日会告诉角色。" : "关闭时，下方的节日一律不告诉角色。", title: "启用地区")
            }
            Section {
                ForEach(r.list) { h in
                    Toggle(isOn: Binding(get: { Holidays.itemOn(r.id, h, model.s) },
                                         set: { v in model.update { Holidays.setItem(r.id, h, v, &$0) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.name)
                            let when = whenText(h.rule, year)
                            if !when.isEmpty { Text(when).font(.system(size: 13)).foregroundStyle(Theme.text3) }
                        }
                    }
                    .disabled(!on)
                }
            } header: {
                Text("节日")
            }
        }
        .navigationTitle(r.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func whenText(_ rule: Holidays.Rule, _ year: Int) -> String {
        let at = Holidays.dateOf(rule, year)
        guard let d = Holidays.Day.parse(at) else { return "" }
        let lunar = rule.lunar != nil || rule.eve ? "，\(Holidays.lunarLabel(at))" : ""
        return "今年 \(d.month) 月 \(d.day) 日\(lunar)"
    }
}
