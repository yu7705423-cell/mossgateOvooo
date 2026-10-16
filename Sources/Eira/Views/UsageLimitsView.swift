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
                HelpNote("每次实际发出的请求都计入，失败的也计入。")
            }

            Section {
                Stepper("自动重试：\(s.retryMax) 次", value: retryBinding, in: 0...3)
            } footer: {
                Text("每重试一次即多一次计费。")
                HelpNote("接口返回 429 或 5xx 时自动重发。每重试一次即多一次计费。设为 0 表示不重试，最多 3 次。主动取消不计为失败，不会重试。")
            }

            Section {
                NumberRow(title: "会话一次渲染多少条", value: model.number("chatPage", 60), unit: "条", placeholder: "全部")
            } footer: {
                HelpNote("打开会话时先渲染最近的这些消息，再往上翻会按同样的数量继续加载。不影响发给模型的内容，只影响打开速度。填 0 表示一次渲染全部，消息很多的会话打开时会明显卡顿。")
            }

            Section {
                NumberRow(title: "角色手机代发带进对话几条", value: model.number("proxyLines", 10), unit: "条", placeholder: "全部")
            } footer: {
                HelpNote("在角色手机上代发的消息与对方的回复，按时间取最近这么多条写进双方的对话。填 0 表示全部，提示词随之变长。")
            }

            Section {
                NumberRow(title: "你的日程往前读几天", value: model.number("userSchedBack", 1), unit: "天", placeholder: "只读今天")
                NumberRow(title: "你的日程往后读几天", value: model.number("userSchedAhead", 0), unit: "天", placeholder: "不读")
            } footer: {
                HelpNote("每次请求带上「日常 - 我的日程」里今天以及往前这么多天的安排，并写明此刻是否正在其中。填 0 表示只读今天。在「我的日程」页里关掉的角色读不到。", title: "你的日程往前读几天")
                HelpNote("同上，今天以及往后这么多天的安排。填 0 表示不读今天以后的。", title: "你的日程往后读几天")
            }

            Section {
                NumberRow(title: "日记带最近几天", value: model.number("diaryDays", 2), unit: "天", placeholder: "全部")
            } footer: {
                HelpNote("对话里带上你公开给角色看的日记与角色自己写的日记，按日期取最近几天（2 表示今天与昨天）。填 0 表示全部，提示词随之变长。")
            }

            // 朋友圈（网页版 LimitsPage 的 momentsCount、ownMomentsCount、momentChatRecent、momentImageRate）
            Section {
                NumberRow(title: "带上你最近几条朋友圈", value: model.number("momentsCount", 3), unit: "条", placeholder: "全部")
                NumberRow(title: "带上角色自己最近几条朋友圈", value: model.number("ownMomentsCount", 3), unit: "条", placeholder: "全部")
                NumberRow(title: "写动态与评论时带上最近几条私聊", value: model.number("momentChatRecent", 20), unit: "条", placeholder: "全部")
            } header: {
                Text("朋友圈")
            } footer: {
                Text("不增加调用次数，只增加每次请求的长度。填 0 表示全部带上。")
                HelpNote("每次请求带上你自己发的最近这么多条朋友圈：时间、文字、几张图、配的歌，以及这个角色点过赞、评论过什么。图片本身不发送，只说明张数。填 0 表示全部带上。", title: "带上你最近几条朋友圈")
                HelpNote("每次请求带上这个角色自己发的最近这么多条朋友圈，以及每条下面的全部评论（谁说的、说了什么）。用于让角色在聊天中知道自己发过什么、你评论过什么、自己回复过什么。填 0 表示全部带上。", title: "带上角色自己最近几条朋友圈")
                HelpNote("角色写朋友圈、评论、回复评论时，同一次请求里带上与你私聊的最近这么多条消息，回复评论时还带上这条动态下已有的评论。", title: "写动态与评论时带上最近几条私聊")
            }

            Section {
                NumberRow(title: "角色朋友圈配图的比例", value: model.number("momentImageRate", 30), unit: "%", placeholder: "0", range: 0...100)
            } footer: {
                Text("每配一张图调用一次生图接口。填 100 表示每一条都可以配图，填 0 表示一律不配图。")
                HelpNote("角色每次写朋友圈时，按这个比例随机决定这一条可不可以配图；可以配图时由角色决定配不配，不可以的那一条只有文字与歌。未配置生图接口时一律不配图。", title: "角色朋友圈配图的比例")
            }

            // 排日程（网页版 dayPlanRecent、dayPlanSceneBeats）
            Section {
                NumberRow(title: "排日程时带几条最近的对话", value: model.number("dayPlanRecent", 12), unit: "条", placeholder: "全部")
                NumberRow(title: "排日程时带进行中的线下几段", value: model.number("dayPlanSceneBeats", 4), unit: "段", placeholder: "全部")
            } header: {
                Text("日程")
            } footer: {
                Text("不增加调用次数，只增加这一次请求的长度。填 0 表示全部带上。")
                HelpNote("每天排角色的日程时，把与该角色最近这么多条对话（含线下正文）连同历史摘要与最近的记忆一并发出，日程据此确定角色此刻所在的地方与正在发生的事。", title: "排日程时带几条最近的对话")
                HelpNote("有尚未收场的线下剧情时，排日程会另外带上这一场的地点、最近写到的时刻与最近这么多段正文的全文，日程据此接上剧情中角色所在的地方与正在发生的事。上面那一项中的对话每条只取前 200 字，这一项不截断。填 0 表示这一场的正文全部带上。", title: "排日程时带进行中的线下几段")
            }

            // 总结记忆时发给模型去重的已有记忆（网页版 memoryDedupeAll、memoryDedupeRelevant、memoryDedupeRecent）
            Section {
                Toggle("发送全部已有记忆", isOn: model.bool("memoryDedupeAll", false))
                if !(s.raw["memoryDedupeAll"]?.bool ?? false) {
                    NumberRow(title: "与这一批对话相关的已有记忆", value: model.number("memoryDedupeRelevant", 30), unit: "条", placeholder: "相关的全部")
                    NumberRow(title: "最近记下的已有记忆", value: model.number("memoryDedupeRecent", 10), unit: "条", placeholder: "不另外发送")
                }
            } header: {
                Text("总结记忆")
            } footer: {
                Text(s.raw["memoryDedupeAll"]?.bool ?? false
                     ? "开启后每次发送全部，记忆越多，每次请求越长。"
                     : "关闭时只发送上面两类：与要总结的这一批对话相关的、最近记下的。不额外调用接口。")
                HelpNote("总结记忆时会把已有的记忆发给模型，用于去重和改写旧条目。开启后每次发送全部，记忆越多，每次请求越长。关闭时只发送下面两类：与要总结的这一批对话相关的、最近记下的。", title: "发送全部已有记忆")
                HelpNote("按关键词与字面重合挑出与要总结的对话相关的记忆，不额外调用接口。填 0 表示相关的全部发送。", title: "与这一批对话相关的已有记忆")
                HelpNote("另外发送最近记下的几条。刚记下的最容易与新内容重复。填 0 表示不另外发送。", title: "最近记下的已有记忆")
            }

            Section {
                NumberRow(title: "批量生成时发多少条已有词条", value: model.number("eventDedupeList", 0), unit: "条", placeholder: "全部")
            } footer: {
                Text("条数越多重复越少，每次请求也越长。填 0 表示全部发送。无论此处如何设置，入库时都会再比对一次。")
                HelpNote("批量生成随机事件时，会把该格已有的词条一并发给模型以避免重复。", title: "批量生成时发多少条已有词条")
            }

            Section {
                NumberRow(title: "未读达到几条暂停主动发起对话", value: model.number("proactiveMaxUnread", 3), unit: "条", placeholder: "不限")
            } footer: {
                HelpNote("开了「主动发起对话」的角色，未读消息堆到这个条数后不再主动发，看过之后恢复。填 0 表示一直发。每个角色的开关在各自的会话设置里。")
            }

            Section {
                Toggle("群聊中每个角色单独调用", isOn: model.bool("groupPerChar", false))
            } header: {
                Text("群聊")
            } footer: {
                Text("开启后群里有几人，每轮最多多几次调用。")
                HelpNote("关闭时，群聊每轮调用一次接口，由模型写出这一轮开口的几位成员。开启后，开口的成员各调用一次：这一轮被 @ 的成员，没有 @ 时全体成员按顺序各说一次，后说的看得见先说的。禁言与封存的成员不开口。重新生成仍按一次调用写整轮。", title: "群聊中每个角色单独调用")
            }

            Section {
                Toggle("多人线下每人单独调用", isOn: model.bool("scenePerChar", false))
                Toggle("线下一场收尾时生成摘要", isOn: model.bool("sceneSummary", false))
                Toggle("线下把窗口外的段落压成摘要", isOn: model.bool("sceneCompress", false))
                NumberRow(title: "每段正文的上限", value: model.number("sceneMaxTokens", 0), unit: "token", placeholder: "不限")
                NumberRow(title: "线下注入预算", value: model.number("sceneBudget", 120000), unit: "token", placeholder: "不限")
                NumberRow(title: "往回带几段正文", value: model.number("sceneWindow", 0), unit: "段", placeholder: "全部")
                NumberRow(title: "世界书与记忆按最近几段扫", value: model.number("sceneScan", 4), unit: "段", placeholder: "全部")
                NumberRow(title: "每段大约多少字", value: model.number("sceneWords", 0), unit: "字", placeholder: "不写")
            } header: {
                Text("线下")
            } footer: {
                Text("线下每写一段调用一次接口。开启「每人单独调用」后，多人在场时每个在场角色各调用一次；开启收场摘要后每次收场多调用一次；开启压缩后，有段落被挡在窗口外时多调用一次。")
                HelpNote("线下每写一段调用一次接口（走主用接口）。不止一个角色在场时，默认一次调用写整轮，由模型按名字分段；开启「多人线下每人单独调用」后，每个在场角色各调用一次，后写的看得见先写的。每段正文的上限填 0 时不发送这个字段，由接口自己定。注入预算按 token 算世界书与正文的总量，填 0 表示不限。往回带几段填 0 表示整场都带；钉住的段落不受这一项限制。每段字数填 0 时提示词里不写篇幅。收场摘要：点「收场」时把整场压成一段，写进这一场的摘要，之后在这一场里继续写时读得到。压缩：「往回带几段」不为 0 时，被挡在外面的段落先压成摘要再挡掉；填 0 时不会触发。两项都走记忆接口，没单独配时走副用。")
            }

            Section {
                Toggle("打完电话自动总结", isOn: model.bool("callSummary", true))
                NumberRow(title: "通话每轮回复上限", value: model.number("callMaxTokens", 400), unit: "token", placeholder: "不限")
                NumberRow(title: "视频通话两帧画面的间隔", value: model.number("callFrameGap", 8), unit: "秒", placeholder: "每轮都带")
            } header: {
                Text("通话")
            } footer: {
                Text("通话每轮调用一次接口；开启总结时每通电话多调用一次。视频通话里每带一帧画面都是一次图片费用。")
                HelpNote("通话每说一轮调用一次接口。总结默认开启：每通接通过、有对白的电话挂断时多调用一次（走副用接口），关闭后可在通话记录上手动生成。回复上限填 0 表示不限。视频通话中打开摄像头、且识图设为「交给聊天模型」时，画面随你说的那句一起发出，不另调接口；画面间隔填 0 表示每轮都带一帧，画面最新，费用也最高。")
            }

            Section {
                Toggle("自动生成关系底色", isOn: model.bool("bondAuto", false))
            } footer: {
                Text("开启后多调用一次接口。")
                HelpNote("关系转折级记忆有增删改之后，下一次请求回复时把这些记忆重新压成「你们之间」的几句现状，多调用一次接口（走记忆接口，未单独配置时走副用）。失败当次记为已尝试，记忆再有变动才会再压。关闭后底色保持上一次的结果。")
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
                HelpNote("流式回复超过这个秒数没有收到新内容，或非流式请求超过它的四倍没有回应，按连接断开处理并报错，已收到的部分保留。填 0 表示一直等。")
            }

            Section {
                Toggle("缓存设定区那一段", isOn: model.bool("promptCache", true))
            } footer: {
                HelpNote(s.promptCache
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
                HelpNote("读取角色卡、生成核心设定等后台任务一次最多写多少 token。默认不设，使用接口本身的上限。推理模型的思考过程也计入上限，数值偏小时回复会在写完之前被截断。上限只是封顶，没有用到的部分不计费。")
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
            "chat.compare": "换一套接口对比",
            "chat.vision-describe": "发给角色的图写成描述",
            "card.import": "读取角色卡",
            "card.core": "生成核心设定",
            "card.examples": "生成对话示例",
            "card.appearance": "从人设中提取外貌",
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
            "moment.create": "角色发朋友圈",
            "moment.comment": "朋友圈评论",
            "moment.reply": "朋友圈回复",
            "translate.lines": "翻译单条消息",
            "usersched.import": "导入我的日程",
            "phone.lock": "角色手机的锁屏密码",
            "phone.chats": "角色手机的会话列表",
            "phone.chat": "角色手机的一段会话",
            "phone.reply": "角色手机里对方回话",
            "phone.album": "角色手机的相册",
            "phone.notes": "角色手机的备忘录",
            "phone.visits": "角色手机的浏览记录",
        ][task] ?? task
    }
}
