import Foundation

/// 会让「发一条消息」多打出去请求的那几项，只在这里登记（网页版 cost.js 的 EXTRA_CALLS，CLAUDE.md 第 15 条）。
/// 「用量与上限」据此把账摆出来。原生版做到哪一项就登记哪一项，每一项在 AppSettings 里的默认值都必须是关着的
/// （CostTests 核对）。
struct ExtraCall: Identifiable, Sendable {
    let id: String
    let label: String
    let isOn: @Sendable (AppSettings) -> Bool
    let when: @Sendable (AppSettings) -> String
    /// 用户明确要求默认开着的例外（网页版 check-calls.mjs 的 ALLOW_ON）。其余一律默认关
    var allowOn = false
}

enum ExtraCalls {
    static let all: [ExtraCall] = [
        ExtraCall(id: "chatFallback", label: "接口失败时自动换下一套",
                  isOn: { $0.chatFallback && usableCount($0) > 1 },
                  when: { s in "当前这一套报错时改用下一套，最多再换 \(swapCount(s)) 套" }),
        ExtraCall(id: "bondAuto", label: "自动重压关系底色",
                  isOn: { $0.raw["bondAuto"]?.bool == true },
                  when: { _ in "关系转折级记忆有增删改之后的第一条消息（走记忆接口，没单独配时走副用）" }),
        ExtraCall(id: "autoSummarize", label: "自动总结记忆",
                  isOn: { s in (s.raw["memoryEnabled"]?.bool ?? true)
                      && ["autoSummarizeInterval", "autoSummarizeMessages", "autoSummarizeChars"].contains { (s.raw[$0]?.number ?? 0) > 0 } },
                  when: { s in
                      var parts: [String] = []
                      if let n = s.raw["autoSummarizeInterval"]?.number, n > 0 { parts.append("每累计 \(Int(n)) 轮角色回复") }
                      if let n = s.raw["autoSummarizeMessages"]?.number, n > 0 { parts.append("未总结消息达到 \(Int(n)) 条") }
                      if let n = s.raw["autoSummarizeChars"]?.number, n > 0 { parts.append("未总结文字达到 \(Int(n)) 字") }
                      return parts.joined(separator: "，或") + "时一次（走记忆接口，没单独配时走副用）"
                  }),
        // 挂在会话上，不是全局设置：有一段会话开了就算开着
        ExtraCall(id: "inner", label: "心声单独生成",
                  isOn: { _ in ((try? Repo.chats()) ?? []).contains { $0.row.string("innerMode") == "apart" } },
                  when: { _ in "开了这一档的对话，每一轮在整轮说完之后再一次" }),
        // 挂在生图接口上（那一套选了「生图前翻译」），不是全局设置
        ExtraCall(id: "imageTranslate", label: "生图提示词译成英文",
                  isOn: { $0.imageReady && $0.activeImage?.promptLang == "translate" },
                  when: { _ in "选了「生图前翻译」的生图接口，每张含中文的图在生成之前一次（走副用接口）" }),
        // 默认开着：网页版用户明确要求的例外（每通接通过的电话挂断时一次）
        ExtraCall(id: "callSummary", label: "通话结束后写总结",
                  isOn: { $0.raw["callSummary"]?.bool != false },
                  when: { _ in "每通接通过、有对白的电话挂断时一次（走副用接口）" }, allowOn: true),
        // 挂在角色身上（会话设置里），不是全局设置
        ExtraCall(id: "proactive", label: "角色主动发起对话",
                  isOn: { _ in ((try? Repo.characters()) ?? []).contains { $0.row["proactive"]?.bool == true } },
                  when: { s in "每个开了的角色按设定的间隔一次" + (BgPush.isOn(s) ? "；应用不在前台时由后台消息服务器代发" : "；只在应用打开时发送") }),
        // 挂在角色身上（会话设置里）
        ExtraCall(id: "diaryAuto", label: "角色每天写日记",
                  isOn: { _ in ((try? Repo.characters()) ?? []).contains { $0.row["diaryAuto"]?.bool == true } },
                  when: { _ in "每个开了的角色，每天到了设定时刻之后一次（走副用接口）；当天已经有一篇时不写，失败当天不再自动试" }),
        // 挂在角色身上（会话设置里）
        ExtraCall(id: "dayOn", label: "角色的当日日程",
                  isOn: { _ in ((try? Repo.characters()) ?? []).contains { $0.row["dayOn"]?.bool == true } },
                  when: { _ in "每个开了的角色，每天第一条消息之前一次（走副用接口）；失败当天不再自动排" }),
        // 通话里角色每说一句走一次语音合成接口（网页版 callVoice）。通话页的喇叭键就是这个开关，默认关
        ExtraCall(id: "callVoice", label: "通话时出声",
                  isOn: { $0.raw["callSpeak"]?.bool == true && $0.voiceReady },
                  when: { _ in "通话中角色每说一句，走一次语音合成接口（不是聊天接口）；该角色在当前语音接口上没有音色时用系统自带的合成，不花钱" }),
        ExtraCall(id: "retryMax", label: "自动重试",
                  isOn: { $0.retryMax > 0 },
                  when: { s in "接口返回 429 或 5xx 时，最多再试 \(s.retryMax) 次" }),
    ]

    static func active(_ s: AppSettings) -> [ExtraCall] { all.filter { $0.isOn(s) } }

    /// 开着的里面，不是「默认就开着」的那几项。
    static func switchedOn(_ s: AppSettings) -> [ExtraCall] { active(s).filter { !$0.allowOn } }

    /// 填全了密钥与模型的对话接口有几套。
    static func usableCount(_ s: AppSettings) -> Int { s.chatPresets.filter(\.usable).count }

    /// 开着换接口时最多再换几套。
    static func swapCount(_ s: AppSettings) -> Int {
        guard s.chatFallback else { return 0 }
        let others = max(0, usableCount(s) - 1)
        return s.failoverMax == 0 ? others : min(others, s.failoverMax)
    }

    /// 失败时一次调用最多变成几个请求：重试与换接口是相乘的。
    static func attemptsPerCall(_ s: AppSettings) -> Int {
        (s.retryMax + 1) * (swapCount(s) + 1)
    }
}
