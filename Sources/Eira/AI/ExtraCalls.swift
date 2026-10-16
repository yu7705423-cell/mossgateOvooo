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
                  isOn: { _ in liveChats().contains { $0.row.string("innerMode") == "apart" } },
                  when: { _ in "开了这一档的对话，每一轮在整轮说完之后再一次" }),
        // 挂在生图接口上（那一套选了「生图前翻译」），不是全局设置
        ExtraCall(id: "imageTranslate", label: "生图提示词译成英文",
                  isOn: { $0.imageReady && $0.activeImage?.promptLang == "translate" },
                  when: { _ in "选了「生图前翻译」的生图接口，每张含中文的图在生成之前一次（走副用接口）" }),
        ExtraCall(id: "translateApi", label: "单独的翻译接口",
                  isOn: { $0.translateMode == "api" },
                  when: { _ in "设了翻译语言的会话，每一轮回复之后一次，这一轮要翻的几条一批（走翻译接口）" }),
        ExtraCall(id: "writeVoicePrompt", label: "合成语音前先写成台本",
                  isOn: { $0.raw["writeVoicePrompt"]?.bool == true },
                  when: { _ in "角色每发一条语音，先多一次接口在原句中标出停顿、情绪与声音（走副用接口；通话中随台词一并标出，不另计）" }),
        ExtraCall(id: "writeImagePrompt", label: "生图前先写一遍提示词",
                  isOn: { $0.raw["writeImagePrompt"]?.bool == true },
                  when: { _ in "角色每写一个 [图片：…]，先多一次接口把它改写成完整描述（走副用接口）" }),
        // 挂在角色与身份上（有锁脸照片才有）：每组照片读一次，读失败的那一组不再自动读
        ExtraCall(id: "faceDesc", label: "锁脸照片读成外貌描述",
                  isOn: { s in s.visionMode != "off" && (liveChars().contains { !FaceLock.faces($0.row).isEmpty }
                      || ((try? Repo.personas()) ?? []).contains { !FaceLock.faces($0.row).isEmpty }) },
                  when: { _ in "有锁脸照片、这一张用到锁脸且接口不收参考图时，每组照片读一次（走识图那一档），之后用缓存" }),
        // 默认开着：网页版用户明确要求的例外（每通接通过的电话挂断时一次）
        ExtraCall(id: "callSummary", label: "打完电话自动总结",
                  isOn: { $0.raw["callSummary"]?.bool != false },
                  when: { _ in "每通接通过、有对白的电话挂断时一次（走副用接口）" }, allowOn: true),
        // 挂在角色身上（会话设置里），不是全局设置。深夜那一档并在这一项里（网页版 cost.js 的 proactive）：
        // 原生版深夜那一档只在主动发起开着时才发，所以只看 proactive
        ExtraCall(id: "proactive", label: "角色主动发消息",
                  isOn: { _ in liveChars().contains { $0.row["proactive"]?.bool == true } },
                  when: { s in "每个开了的角色按设定的间隔一次，深夜那一档另算"
                      + (BgPush.isOn(s) ? "；应用不在前台时由后台消息服务器代发，深夜那一档只在应用打开时发送" : "；只在应用打开时发送")
                      + "。开关在该角色的会话菜单" }),
        ExtraCall(id: "groupProactive", label: "群里主动开口",
                  isOn: { _ in liveChats().contains { $0.isGroup && $0.row["groupProactive"]?["on"]?.bool == true } },
                  when: { _ in "每个开了的群按设定的间隔一次；只在应用打开时发送。开关在群资料" }),
        // 挂在角色身上（会话设置里）
        ExtraCall(id: "diaryAuto", label: "角色每天写日记",
                  isOn: { _ in liveChars().contains { $0.row["diaryAuto"]?.bool == true } },
                  when: { _ in "每个开了的角色，每天到了设定时刻之后一次（走副用接口）；当天已经有一篇时不写，失败当天不再自动试" }),
        // 挂在角色身上（会话设置里）
        ExtraCall(id: "dayOn", label: "角色的当日日程",
                  isOn: { _ in liveChars().contains { $0.row["dayOn"]?.bool == true } },
                  when: { _ in "每个开了的角色，每天第一条消息之前一次（走副用接口）；失败当天不再自动排" }),
        // 通话里角色每说一句走一次语音合成接口（网页版 callVoice）。通话页的喇叭键就是这个开关，默认关
        ExtraCall(id: "callVoice", label: "通话时出声",
                  isOn: { $0.raw["callSpeak"]?.bool == true && $0.voiceReady },
                  when: { _ in "通话中角色每说一句，走一次语音合成接口（不是聊天接口）；该角色在当前语音接口上没有音色时用系统自带的合成，不花钱" }),
        ExtraCall(id: "groupPerChar", label: "群聊中每个角色单独调用",
                  isOn: { $0.raw["groupPerChar"]?.bool == true },
                  when: { _ in "群聊每轮按开口的成员各调用一次：被 @ 的成员，或未 @ 时的全体成员（不开时一轮只调用一次）" }),
        ExtraCall(id: "scenePerChar", label: "多人线下每人单独调用",
                  isOn: { $0.raw["scenePerChar"]?.bool == true },
                  when: { _ in "线下不止一个角色在场时，每个在场角色各一次（不开时一轮只调用一次）" }),
        ExtraCall(id: "sceneSummary", label: "线下一场收尾时生成摘要",
                  isOn: { $0.raw["sceneSummary"]?.bool == true },
                  when: { _ in "线下点「收场」时一次（走记忆接口，没单独配时走副用）" }),
        ExtraCall(id: "sceneCompress", label: "线下把窗口外的段落压成摘要",
                  isOn: { $0.raw["sceneCompress"]?.bool == true && ($0.raw["sceneWindow"]?.number ?? 0) > 0 },
                  when: { _ in "线下有段落被窗口挡在外面时，写下一段之前一次；失败后要再多出一个窗口的段落才再试（走记忆接口，没单独配时走副用）" }),
        ExtraCall(id: "retryMax", label: "自动重试",
                  isOn: { $0.retryMax > 0 },
                  when: { s in "接口返回 429 或 5xx 时，最多再试 \(s.retryMax) 次" }),
        // 挂在识图方式上（「设置 - 识图」选了交给聊天模型），不是单独的开关；识图默认关（网页版 visionCarry）
        ExtraCall(id: "visionCarry", label: "发给角色的图写成描述",
                  isOn: { $0.visionMode == "chat" },
                  when: { _ in "你每发一张图，角色回复之后一次，把图写成一句描述存下；之后几轮只带描述，不再重传图片。识图方式在「设置 - 识图」" }),
        // 只有单独配了翻译接口才多调（网页版 4.633）。「随回复写译文」时角色在同一次回复里逐句写，不另调接口
        ExtraCall(id: "callTranslate", label: "通话中翻译角色的话",
                  isOn: { s in s.translateMode == "api" && liveChats().contains { !$0.row.string("translateTo").trimmingCharacters(in: .whitespaces).isEmpty } },
                  when: { _ in "开了翻译的对话里打电话、并且单独配了翻译接口时，角色每说完一轮一次，逐句交给翻译接口；选「随回复写译文」时由角色在同一次回复里逐句写，不多调" }),
    ]

    /// 没封存的角色（网页版 cost.js 的 liveChars，4.557）：封存的不再自动做任何事，账上也不算它
    static func liveChars() -> [Character] { ((try? Repo.characters()) ?? []).filter { !$0.archived } }

    /// 角色没有全都封存的会话（网页版 liveChats）
    static func liveChats() -> [Chat] { ((try? Repo.chats()) ?? []).filter { !Archive.chatArchived($0) } }

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
