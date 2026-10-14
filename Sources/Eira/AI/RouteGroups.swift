import Foundation

/// 几件事各自用哪套接口（「设置 - 任务用哪套接口」，settings.taskRoutes）。照抄网页版 engine.js 的 ROUTE_GROUPS。
///
/// 原生版还没有的功能也列着：导入的设置里已经选好的，在这里看得到、改得了，等功能做到时直接生效。
/// 「用哪一套」不是「多打一次」，这一项不增加调用次数（网页版第 15 条）。
struct RouteGroup: Identifiable, Sendable {
    let id: String
    let label: String
    let tasks: [String]
    let def: String

    private static let spare = "默认用副用接口，副用没配时用主用"

    static let all: [RouteGroup] = [
        .init(id: "proactive", label: "角色主动发消息", tasks: ["chat.proactive"], def: spare),
        .init(id: "memory", label: "总结记忆", tasks: Array(AIService.memoryTasks), def: "默认用记忆接口，没单独配时用副用"),
        .init(id: "closetDaily", label: "角色的每日穿搭", tasks: ["closet.daily"], def: spare),
        .init(id: "diary", label: "角色写日记", tasks: ["diary.write"], def: spare),
        .init(id: "dream", label: "角色做梦", tasks: ["dream.write"], def: spare),
        .init(id: "drama", label: "音声（剧情、性格锚点、台本）", tasks: ["drama.plot", "drama.anchors", "drama.script"], def: spare),
        .init(id: "fate", label: "千丝万缕（关键事件、推演、角色选）", tasks: ["fate.nodes", "fate.branch", "fate.pick"], def: spare),
        .init(id: "fit", label: "起居（周计划、周回顾、提示）", tasks: ["fit.plan", "fit.meal", "fit.sched", "fit.review", "fit.tips"], def: spare),
        .init(id: "letter", label: "角色写信", tasks: ["letter.write"], def: spare),
        .init(id: "impress", label: "整理与对照对我的印象", tasks: ["impress.organize", "impress.compare"], def: spare),
        .init(id: "scene", label: "线下、长篇与番外的正文", tasks: ["scene.write"], def: "默认用主用接口，主用没配时用副用"),
        .init(id: "novel", label: "长篇的简介、大纲、走向与改写身份", tasks: ["work.synopsis", "work.outline", "work.branch", "work.identity"], def: spare),
        .init(id: "inner", label: "心声（单独生成那一档）", tasks: ["inner.voice"], def: spare),
        .init(id: "fileFill", label: "让角色填写文件", tasks: ["file.fill"], def: spare),
        .init(id: "mall", label: "商城的刷新与私聊回复", tasks: ["mall.refresh", "mall.auto", "mall.reply", "mall.nick", "mall.value", "mall.charlist", "mall.charlist.now"], def: spare),
        .init(id: "forum", label: "论坛的刷新、回复、小法庭与私信", tasks: ["forum.refresh", "forum.replies", "forum.court", "forum.dm"], def: spare),
        .init(id: "slip", label: "角色自己写纸条", tasks: ["slip.write", "slip.write.now"], def: spare),
        .init(id: "focus", label: "专注陪伴的台词", tasks: ["focus.lines"], def: spare),
        .init(id: "linkChar", label: "联机群里的角色发言", tasks: ["link.char"], def: spare),
        .init(id: "quiz", label: "游戏里角色答问卷、整理题库、个人解读与角色感想", tasks: ["quiz.answer", "quiz.parse", "quiz.interpret", "quiz.react"], def: spare),
        .init(id: "game", label: "桌游里角色说话、谁是卧底的描述与投票", tasks: ["game.talk", "game.spy"], def: spare),
        .init(id: "tools", label: "工具箱的各个生成器",
              tasks: ["tool.prompt", "tool.web", "tool.npc", "tool.user", "tool.pet", "tool.world", "tool.lore", "tool.extra", "tool.card"], def: spare),
    ]

    /// 这个任务属于哪一组。不属于任何一组的照默认规则走。
    static func of(task: String) -> String? {
        all.first { $0.tasks.contains(task) }?.id
    }
}
