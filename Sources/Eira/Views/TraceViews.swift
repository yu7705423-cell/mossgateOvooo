import SwiftUI

/// 「设置 - 存储与备份 - 请求记录」（网页版 TracePage）：排查提示词用，默认关着
struct TraceView: View {
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var trace = Trace.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("记录每一轮请求", isOn: Binding(get: { Trace.isOn(model.s) }, set: { v in
                    model.set("traceOn", .bool(v))
                    if !v { trace.clear() }
                }))
            } footer: {
                Text("记录只保存在内存中，关闭应用即清除。日常使用无需开启。")
                HelpNote("开启后，每次向模型发出的请求都会被记录，包括完整的 system、消息与返回内容，用于排查提示词。不多调用接口。", title: "请求记录")
            }
            if Trace.isOn(model.s) {
                Section {
                    NumberRow(title: "保留条数", value: Binding(get: { Double(Trace.maxOf(model.s)) }, set: { model.set("traceMax", .number(max(0, $0.rounded()))) }),
                              unit: "条", placeholder: "20")
                } footer: {
                    HelpNote("超出后丢弃最早的记录。填 0 表示不限制，长时间开启会持续占用内存。", title: "请求记录：保留条数")
                }
                Section("已记录 \(trace.rows.count)") {
                    if trace.rows.isEmpty {
                        Text("尚无记录。发送一条消息，或触发任意一项需要调用接口的功能，记录会出现在这里。").foregroundStyle(Theme.text2)
                    }
                    ForEach(trace.rows) { r in
                        NavigationLink { TraceDetailView(row: r) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(r.at.formatted(date: .omitted, time: .standard)) · \(r.task)").lineLimit(1)
                                Text([r.model.isEmpty ? "未知模型" : r.model, "约 \(r.tokens) tokens", "\(r.messages.count) 条消息",
                                      r.error.isEmpty ? (r.ms > 0 ? "\(r.ms) 毫秒" : "进行中") : "失败"].joined(separator: " · "))
                                    .font(.caption).foregroundStyle(r.error.isEmpty ? Theme.text2 : Theme.danger)
                            }
                        }
                    }
                }
                if !trace.rows.isEmpty {
                    Section { Button("清空记录", role: .destructive) { confirmClear = true }.foregroundStyle(Theme.dangerText) }
                }
            }
        }
        .navigationTitle("请求记录")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("将清除已记录的全部请求。", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空记录", role: .destructive) { trace.clear() }
        }
    }
}

/// 一条记录：system、每条消息、返回，各自可展开
struct TraceDetailView: View {
    let row: Trace.Row
    @State private var open = "system"

    var body: some View {
        List {
            Section {
                LabeledContent("任务", value: row.task)
                LabeledContent("接口", value: row.preset.isEmpty ? "未命名" : row.preset)
                LabeledContent("模型", value: row.model.isEmpty ? "未知" : row.model)
                LabeledContent("耗时", value: "\(row.ms) 毫秒")
                LabeledContent("估算长度", value: "约 \(row.tokens) tokens")
                if !row.error.isEmpty { Text(row.error).foregroundStyle(Theme.danger) }
            }
            Section {
                block("system", "system", row.system)
                ForEach(Array(row.messages.enumerated()), id: \.offset) { i, m in
                    block("m\(i)", "消息 \(i + 1) · \(m.role)\(m.images > 0 ? " · 含图片" : "")", m.content)
                }
                block("reply", "模型返回", row.error.isEmpty ? row.reply : "（失败）" + row.error)
            }
        }
        .navigationTitle("这一轮发了什么")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("复制") { UIPasteboard.general.string = Trace.text(row) }
            }
        }
    }

    @ViewBuilder private func block(_ key: String, _ title: String, _ text: String) -> some View {
        Button { open = open == key ? "" : key } label: {
            HStack {
                Text(title).foregroundStyle(Theme.text)
                Spacer()
                Text("\(text.count) 字").font(.caption).foregroundStyle(Theme.text2)
                Image(systemName: open == key ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(Theme.text2)
            }
        }
        if open == key {
            Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }
    }
}
