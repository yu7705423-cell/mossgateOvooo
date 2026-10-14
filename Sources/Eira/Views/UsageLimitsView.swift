import SwiftUI

/// 「设置 - 用量与上限」：会多花钱的旋钮集中在这一页（网页版第 13、15 条）。
/// 键名、默认值与取值范围和网页版一致，导入的设置直接生效。原生版还没有的功能，它的旋钮等功能做到时再加。
struct UsageLimitsView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var today: [String: Int] = [:]

    var body: some View {
        let s = model.s
        let extra = ExtraCalls.active(s)
        Form {
            // 新版的汇总卡（.lmn-sum）：宋体大数字，下面列出开着的几项与各自什么时候多调一次
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("一次回复调用接口").font(.system(size: 12)).kerning(0.5).foregroundStyle(Theme.text2)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("1").font(Theme.serif(28))
                        Text(extra.isEmpty ? "次" : "次，另有 \(extra.count) 项开着时追加").font(.system(size: 15))
                    }
                    if !extra.isEmpty {
                        Divider().overlay(Theme.border).padding(.vertical, Theme.sp2)
                        VStack(alignment: .leading, spacing: Theme.sp2) {
                            ForEach(extra) { x in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(x.label).font(.system(size: 14))
                                    Text(x.when(s)).font(.system(size: 12)).foregroundStyle(Theme.text2).lineSpacing(3)
                                }
                            }
                        }
                    }
                    if ExtraCalls.attemptsPerCall(s) > 1 {
                        Text("请求失败时，一次调用最多发出 \(ExtraCalls.attemptsPerCall(s)) 个请求，每个都计费。自动重试与换接口是相乘的关系，不是相加。")
                            .font(.system(size: 13)).foregroundStyle(Theme.dangerText).padding(.top, Theme.sp3)
                    }
                }
                .padding(.vertical, Theme.sp2)
                .listRowBackground(Theme.surface2)
            }

            Section {
                LabeledContent("今天已发出的请求", value: "\(today.values.reduce(0, +)) 次")
                ForEach(today.keys.sorted { (today[$0] ?? 0) > (today[$1] ?? 0) }, id: \.self) { k in
                    LabeledContent(Self.taskLabel(k), value: "\(today[k] ?? 0)")
                        .font(.footnote)
                }
            } footer: {
                Text("每次实际发出的请求都计入，失败的也计入。")
            }

            Section {
                Stepper("自动重试：\(s.retryMax) 次", value: retryBinding, in: 0...3)
            } footer: {
                Text("接口返回 429 或 5xx 时自动重发。每重试一次即多一次计费。设为 0 表示不重试，最多 3 次。主动取消不计为失败，不会重试。")
            }

            Section {
                NumberRow(title: "日记带最近几天", value: model.number("diaryDays", 2), unit: "天", placeholder: "全部")
            } footer: {
                Text("对话里带上你公开给角色看的日记与角色自己写的日记，按日期取最近几天（2 表示今天与昨天）。填 0 表示全部，提示词随之变长。")
            }

            Section {
                NumberRow(title: "未读达到几条暂停主动发起对话", value: model.number("proactiveMaxUnread", 3), unit: "条", placeholder: "不限")
            } footer: {
                Text("开了「主动发起对话」的角色，未读消息堆到这个条数后不再主动发，看过之后恢复。填 0 表示一直发。每个角色的开关在各自的会话设置里。")
            }

            Section {
                Toggle("通话结束后写总结", isOn: model.bool("callSummary", true))
                NumberRow(title: "通话每轮回复上限", value: model.number("callMaxTokens", 400), unit: "token", placeholder: "不限")
            } header: {
                Text("通话")
            } footer: {
                Text("通话每说一轮调用一次接口。总结默认开启：每通接通过、有对白的电话挂断时多调用一次（走副用接口），关闭后可在通话记录上手动生成。回复上限填 0 表示不限。")
            }

            Section {
                Toggle("自动重压关系底色", isOn: model.bool("bondAuto", false))
            } footer: {
                Text("关系转折级记忆有增删改之后，下一次请求回复时把这些记忆重新压成「你们之间」的几句现状，多调用一次接口（走记忆接口，未单独配置时走副用）。失败当次记为已尝试，记忆再有变动才会再压。关闭后底色保持上一次的结果。")
            }

            Section {
                Toggle("接口失败时自动换下一套", isOn: model.bool("chatFallback", false))
                if s.chatFallback {
                    Stepper(s.failoverMax == 0 ? "最多再换：全部" : "最多再换：\(s.failoverMax) 套",
                            value: failoverBinding, in: 0...20)
                }
            } footer: {
                Text(fallbackNote(s))
            }

            Section {
                NumberRow(title: "回复多久没有新内容算断开", value: model.number("streamIdleSec", 120), unit: "秒", placeholder: "一直等")
            } footer: {
                Text("流式回复超过这个秒数没有收到新内容，或非流式请求超过它的四倍没有回应，按连接断开处理并报错，已收到的部分保留。填 0 表示一直等。")
            }

            Section {
                Toggle("缓存设定区那一段", isOn: model.bool("promptCache", true))
            } footer: {
                Text(s.promptCache
                     ? "对话时人设、世界书、消息规则这些整轮不变的内容声明为可缓存。连续对话时重复命中，这一段按十分之一计价；间隔过久未命中的那一次按一点二五倍计价。仅 Anthropic 接口支持声明，其余接口由服务端自行处理，开关不影响。"
                     : "已关闭。每一轮都按完整价格计算输入部分。")
            }

            Section {
                Toggle("导入角色卡时生成核心设定", isOn: model.bool("coreAuto", true))
            } footer: {
                Text(model.s.raw["coreAuto"]?.bool ?? true
                     ? "导入角色卡时额外调用一次接口，将人设压缩为三到五行，注入在提示词末尾。关闭后该字段留空，可自行填写。"
                     : "已关闭。核心设定需在编辑资料中自行填写。")
            }

            Section {
                NumberRow(title: "后台任务的回复上限", value: model.number("taskMaxTokens", 0), unit: "token", placeholder: "不限")
            } footer: {
                Text("读取角色卡、生成核心设定等后台任务一次最多写多少 token。默认不设，使用接口本身的上限。推理模型的思考过程也计入上限，数值偏小时回复会在写完之前被截断。上限只是封顶，没有用到的部分不计费。")
            }

            ProblemSection(text: model.problem)
        }
        .navigationTitle("用量与上限")
        .onAppear {
            model.reload()
            Task {
                let t = await Usage.shared.todayByTask()
                await MainActor.run { today = t }
            }
        }
    }

    private var retryBinding: Binding<Int> {
        Binding(get: { model.s.retryMax }, set: { model.set("retryMax", .number(Double($0))) })
    }

    private var failoverBinding: Binding<Int> {
        Binding(get: { model.s.failoverMax }, set: { model.set("failoverMax", .number(Double($0))) })
    }

    private func fallbackNote(_ s: AppSettings) -> String {
        guard s.chatFallback else { return "已关闭。接口报错时直接报错，不改用另一套重发。开启后失败的回合会多次计费。" }
        let n = ExtraCalls.swapCount(s)
        if n == 0 { return "已开启，但目前只有一套填全了的接口，换不出去。在「接口」中再配一套后生效。" }
        return "接口报错时按「主用、副用、其余」的顺序依次换，最多再换 \(n) 套。失败的那几次同样计费。没填全密钥与模型的接口会跳过。已收到部分回复或手动停止时不换。设为 0 表示其余接口全部尝试。当前填全的共 \(ExtraCalls.usableCount(s)) 套。"
    }

    /// 记账用的任务名翻成界面上的名字。没列的照原样显示。
    static func taskLabel(_ task: String) -> String {
        [
            "chat.reply": "对话回复",
            "card.import": "读取角色卡",
            "card.core": "生成核心设定",
            "vision": "识图",
            "api.test": "测试连接",
            "image": "生图",
            "image.translate": "生图提示词翻译",
            "tts": "语音合成",
            "asr": "语音识别",
            "memory.bond": "压缩关系底色",
            "memory.extract": "总结记忆",
            "inner.voice": "心声单独生成",
            "chat.call": "通话",
            "call.summary": "通话总结",
            "chat.proactive": "主动发起对话",
            "diary.write": "角色写日记",
            "day.plan": "当日日程",
            "event.batch": "生成随机事件",
            "recipe.batch": "生成食谱",
        ][task] ?? task
    }
}
