import Foundation

/// 预设里的「条目顺序」。照抄网页版 `ai/layout.js` 与 `ai/context/index.js` 的 resolveOrder（ARCHITECTURE 4.387）。
///
/// 一份提示词从上到下是一条条的段落。各段的文字由 ChatPrompt 算出来（pieces：id 对应文字），
/// 先后、开关、用户自己加的条目由这里按设置排。四种情形各一份（线上聊天、线下、群聊、通话）；
/// 原生版现在只拼线上聊天，其余三份照样读、照样存，改线上聊天时不动它们。
///
/// **默认顺序与网页版一字不差。** 没动过的人，发出去的提示词不变。
enum Layout {
    static let history = "history"

    struct Mode: Identifiable {
        let id: String
        let label: String
    }

    static let modes = [Mode(id: "chat", label: "线上聊天"), Mode(id: "scene", label: "线下"), Mode(id: "group", label: "群聊"), Mode(id: "call", label: "通话")]

    // MARK: - 注入区块

    /// 网页版 context/index.js 的 DEFAULT_ORDER：认得的区块全在这里，存着的顺序里缺的按这个补在末尾。
    static let defaultOrder = ["lorebook", "bond", "state", "pinned", "recent", "character", "loreAfter", "user", "impress", "alts",
        "groups", "privateRecent", "groupState", "linkRecent", "time", "dates", "day", "avatar", "geo", "music", "watch", "trip",
        "bill", "health", "fit", "closet", "collect", "mall", "forum", "slip", "focus", "memory", "space", "wishes", "diary",
        "dream", "pets", "quizzes", "fate", "ties", "sms", "proxy", "plan", "userSched", "moments", "friendMoments", "bridge", "badges"]

    /// 设置里没有 injectOrder 时用的那一份：网页版出厂值经过它自己的迁移 4、5、7 之后的样子
    /// （世界书拆成角色前后、关系底色排在人设前、一起看排在记忆前）。
    static let factoryOrder = ["lorebook", "bond", "character", "loreAfter", "user", "time", "watch", "memory"]

    /// 每轮都变的那几块，归「此刻的状态」（网页版 VOLATILE）。
    static let volatile: Set<String> = ["time", "dates", "day", "music", "watch", "avatar", "trip", "bill", "health", "fit", "bridge",
        "plan", "userSched", "badges", "moments", "friendMoments", "closet", "collect", "mall", "linkRecent", "forum", "slip", "focus", "recent"]

    static let blockMeta: [String: (label: String, desc: String)] = [
        "character": ("角色人设", "角色卡里写的设定"),
        "user": ("用户信息", "我的昵称与人设分区，以及该角色读得到的「与角色相关」条目；小号会额外说明关系"),
        "time": ("时间情境", "现在几点、两边的时差、距上次说话多久"),
        "lorebook": ("世界书（角色前）", "标为「角色前」且留在设定区的条目"),
        "loreAfter": ("世界书（角色后）", "标为「角色后」且留在设定区的条目"),
        "bond": ("关系底色", "由关系转折级记忆压成的几句现状，常驻"),
        "pinned": ("一直记着", "钉住的记忆与忌讳的话题，每轮常驻。在记忆条目上单独设置"),
        "state": ("现状", "关于你、关于角色自己、最近，以及进行中的事。总结记忆时整块改写，每轮常驻"),
        "recent": ("最近记下的", "最近几条记忆，不问相关不相关一律带上"),
        "memory": ("本轮相关记忆", "按相关度召回的条目。默认插在对话末尾附近，不在设定区"),
        "space": ("情侣空间", "在一起多少天、快到的纪念日、还没完成的约定"),
        "day": ("今天", "角色当天的日程、当前时段、撞上的事"),
        "avatar": ("对方的头像", "对方换头像时提示一次，附一句客观描述"),
        "geo": ("两人距离", "双方位置与算好的直线距离"),
        "music": ("角色在听什么", "角色那个音乐账号的真实播放记录"),
        "watch": ("正在一起看 / 一起读", "片名或书名、进度、剧情提纲、最近的台词或这一页的原文"),
        "bill": ("账户余额", "角色与对方的余额、情侣账户、本月支出"),
        "trip": ("这次出行", "眼下这一次出行：去哪儿、什么时候、到哪一步了"),
        "health": ("身体状况", "当天的睡眠、步数、体重、饮水、心情与不适"),
        "bridge": ("另一边", "线下带上手机里刚说过的几句；线上带上最近一次见面"),
        "plan": ("你记着的事", "「待办」里已经计入、还没做的那几条"),
        "badges": ("互动标识", "连续互发的天数、今天的状态、刚解锁的标识"),
        "moments": ("朋友圈", "你最近发的几条朋友圈，以及这个角色自己最近几条动态和下面的评论"),
        "friendMoments": ("认识的人的朋友圈", "这个角色认识的人最近发的几条朋友圈"),
        "dates": ("节日与纪念日", "当天与之后三天内的节日、生日与纪念日"),
        "closet": ("衣帽间", "对方与角色今天穿的，以及聊到穿搭时衣帽间的清单"),
        "collect": ("收藏馆", "聊到收藏时，带上该角色收藏馆的清单与入手原因"),
        "mall": ("商城", "该角色在商城里的身份、挂的东西、订单与对话"),
        "forum": ("论坛", "该角色所在论坛的热帖与它自己帖子下的新回复"),
        "slip": ("纸条", "该角色能用的纸条盒、手里的纸条与最近的纸条往来"),
        "focus": ("专注", "用户正在专注时，写明专注的事项、到几点结束"),
        "alts": ("角色的其他账号", "本体与小号互相知道对方那边最近的对话"),
        "groups": ("所在群聊的最近消息", "私聊时带上这个角色所在群聊的最近消息"),
        "privateRecent": ("成员与你的私聊", "群聊时每个成员附上该成员与你私聊的最近消息"),
        "linkRecent": ("联机群近况", "私聊时带上该角色所在联机群的最近几句"),
        "fate": ("千丝万缕：一起观看", "会话开着「一起观看」时，带上那条支线的节点与走向"),
        "fit": ("起居：饮食与运动", "今天的预算、摄入与消耗、运动、目标进度"),
        "groupState": ("群内身份与禁言", "群主、管理员、群昵称与禁言状态"),
        "wishes": ("心愿", "角色自己记下的心愿，以及你设为给角色看的心愿"),
        "diary": ("日记", "你设为公开的日记，以及该角色自己最近写的日记"),
        "dream": ("昨夜的梦", "该角色此刻还记得的昨夜的梦"),
        "ties": ("好友与拉黑", "该角色拉黑了谁、从联系人里删了谁，以及你发来的好友申请"),
        "sms": ("短信", "该角色和哪些号码有过短信往来"),
        "proxy": ("代发与手机上的对话", "你登录角色的手机代发的消息与对方的回复"),
        "userSched": ("对方的日程", "「日常 - 我的日程」里你的课表与排班"),
        "impress": ("角色眼中的你", "该角色在相处中形成、你已收下的印象"),
        "pets": ("宠物", "该角色的宠物、一起养的宠物与你的宠物"),
        "quizzes": ("一起做过的测试", "最近几次与该角色有关的测试问卷"),
    ]

    struct Group {
        let label: String
        let blocks: [String]
        let follow: String
    }

    /// 注入区块分组（网页版 GROUPS）。没登记的区块落进「你们之间」。
    static let groups: [String: Group] = [
        "char": Group(label: "角色人设", blocks: ["character"], follow: ""),
        "loreBefore": Group(label: "世界书（角色前）", blocks: ["lorebook"], follow: "跟随世界书里每一本、每一条的开关"),
        "you": Group(label: "用户信息", blocks: ["user"], follow: ""),
        "recall": Group(label: "本轮相关记忆", blocks: ["memory"], follow: "跟随记忆的开关"),
        "bond": Group(label: "关系底色与现状", blocks: ["bond", "state"], follow: "跟随记忆的开关"),
        "pinned": Group(label: "一直记着", blocks: ["pinned"], follow: "跟随记忆的开关"),
        "loreAfter": Group(label: "世界书（角色后）", blocks: ["loreAfter"], follow: "跟随世界书里每一本、每一条的开关"),
        "impress": Group(label: "角色眼中的你", blocks: ["impress"], follow: "跟随画像的开关"),
        "circle": Group(label: "其他账号与群聊", blocks: ["alts", "groups", "privateRecent", "groupState", "linkRecent"], follow: "跟随小号、群聊互通与联机群各自的开关"),
        "between": Group(label: "你们之间", blocks: ["geo", "space", "wishes", "diary", "dream", "pets", "quizzes", "fate", "ties", "sms", "proxy"], follow: "跟随各项功能自己的开关"),
        "now": Group(label: "此刻的状态", blocks: [], follow: "跟随各项功能自己的开关"),
    ]

    private static let groupOfBlock: [String: String] = {
        var out: [String: String] = [:]
        for (g, v) in groups { for b in v.blocks { out[b] = g } }
        return out
    }()

    static func groupOf(_ block: String) -> String {
        volatile.contains(block) ? "now" : groupOfBlock[block] ?? "between"
    }

    /// 读出一份干净的顺序：丢掉不认识的，补上缺的。
    static func resolveOrder(_ raw: [String]?) -> [String] {
        let known = Set(defaultOrder)
        var seen = Set<String>()
        var out: [String] = []
        for id in raw ?? factoryOrder where known.contains(id) && !seen.contains(id) { seen.insert(id); out.append(id) }
        for id in defaultOrder where !seen.contains(id) { seen.insert(id); out.append(id) }
        return out
    }

    static func injectOrder(_ s: AppSettings) -> [String]? {
        s.raw["injectOrder"]?.array.map { $0.compactMap(\.string) }
    }

    /// 一组里有哪几块，按 injectOrder 的先后。
    static func blocksOf(_ group: String, _ order: [String]?) -> [String] {
        resolveOrder(order).filter { groupOf($0) == group }
    }

    // MARK: - 系统段落

    struct Segment {
        let label: String
        let desc: String
        var locked = false
        var follow = ""
        /// 可以改措辞的那一段模板，按情形
        var edit: [String: String] = [:]
    }

    static let segments: [String: Segment] = [
        "opening": Segment(label: "身份开场", desc: "该角色是谁、在和谁说话", edit: ["chat": "skeleton.opening", "scene": "skeleton.scene-opening", "call": "skeleton.opening"]),
        "faceOpening": Segment(label: "身份开场（见面时）", desc: "会话切到见面时，替换上面那一段", edit: ["chat": "skeleton.face-opening"]),
        "groupOpening": Segment(label: "群聊开场", desc: "这是一个群聊、成员有谁", edit: ["group": "skeleton.group-opening"]),
        "gender": Segment(label: "性别（开头）", desc: "角色卡与用户资料里填写的性别"),
        "genderTail": Segment(label: "性别（末尾）", desc: "与开头一段相同，放在贴近输出的位置"),
        "ident": Segment(label: "这一场的身份", desc: "这一场里换过的身份", follow: "跟随这一场的设置"),
        "members": Segment(label: "成员设定", desc: "每个成员的人设、情境、示例、核心设定与记忆", follow: "群聊与线下的基本内容，其中各项跟随角色卡与记忆的开关"),
        "faceSetup": Segment(label: "见面的地点与时刻", desc: "会话切到见面时填写的地点、时刻、情境", follow: "跟随会话的见面设置"),
        "summary": Segment(label: "更早之前的摘要", desc: "压缩历史得到的摘要", follow: "跟随历史压缩的开关。摘要由接口生成，在这里关闭会使已生成的摘要无法使用"),
        "sceneSummary": Segment(label: "这一场之前的摘要", desc: "这一场开始之前的摘要", follow: "跟随线下压缩与收场总结的开关"),
        "groupNote": Segment(label: "群聊说明", desc: "每个成员单独调用时，告知其他成员是谁", edit: ["chat": "skeleton.group", "call": "skeleton.group", "scene": "skeleton.group"]),
        "groupRules": Segment(label: "群聊格式", desc: "每行以说话人名字开头", locked: true),
        "rules": Segment(label: "消息规则", desc: "每轮分几条发出（条数在「参数」中设置）", locked: true),
        "sceneRules": Segment(label: "正文规则", desc: "每轮写一段，不写用户", locked: true),
        "caps": Segment(label: "能力说明", desc: "开启的能力各自的写法；其中的时间戳与译文是回复格式的一部分", follow: "跟随「能力开关」、角色卡与会话中的各项开关"),
        "status": Segment(label: "状态栏", desc: "会话开启状态栏时出现。栏目与规则在会话菜单的「状态栏」中", locked: true),
        "inner": Segment(label: "心声", desc: "会话开启「随回复一起」的心声时出现。开关与措辞在会话菜单的「心声」中", locked: true),
        "closet": Segment(label: "衣帽间标记", desc: "线下换装、借还、塞进包里的写法", follow: "跟随衣帽间的开关"),
        "setup": Segment(label: "这一场", desc: "地点、时刻、在场的人、情境", follow: "跟随这一场的设置"),
        "time": Segment(label: "时间写法", desc: "先写出当地时间的那一行", locked: true),
        "length": Segment(label: "篇幅", desc: "每段大约多少字", follow: "跟随线下设置中填写的字数，未填写时不出现"),
        "style": Segment(label: "文风", desc: "这一场或这段会话选用的文风", follow: "跟随会话或这一场选用的文风，未选用时不出现", edit: ["chat": "skeleton.scene-style", "scene": "skeleton.scene-style"]),
        "core": Segment(label: "核心设定", desc: "角色卡里的核心设定", follow: "跟随角色卡中的核心设定，未填写时不出现", edit: ["chat": "skeleton.core", "scene": "skeleton.core", "call": "skeleton.core"]),
        "ban": Segment(label: "不要写这些", desc: "内容来自「不要写这些」", follow: "跟随「不要写这些」的开关"),
        "call": Segment(label: "通话规则", desc: "说一段就停下，不写动作与标记", locked: true),
        "callScript": Segment(label: "语音台本", desc: "停顿、情绪、声音的标记写法（开启语音台本时）", locked: true),
    ]

    /// 开放改措辞的那几段模板。其余一律锁定。
    static let editable: Set<String> = Set(segments.values.flatMap { $0.edit.values })

    /// 「聊天记录」下面固定贴着最后一条的几样，不参与排序。
    static let fixedTail: [String: [String]] = [
        "chat": ["本轮相关记忆", "译文提醒（开启行内译文时）"],
        "scene": ["本轮相关记忆", "场外指示", "续写说明（续写时）", "收尾提醒", "附带译文（开启时）"],
        "group": ["各成员的本轮相关记忆"],
        "call": [],
    ]

    private static let dataChat = ["loreBefore", "bond", "char", "loreAfter", "you", "recall", "pinned", "impress", "circle", "between"]
    private static let dataGroup = ["loreBefore", "loreAfter", "you", "circle"]
    private static let defaults: [String: [String]] = [
        "chat": ["opening", "faceOpening", "gender", "@data", "faceSetup", "summary", "groupNote", "rules", "caps", "style",
                 "core", "ban", "genderTail", history, "inner", "status", "grp:now"],
        "scene": ["opening", "gender", "@data", "ident", "members", "summary", "sceneSummary", "groupNote", "sceneRules", "closet", "setup",
                  "time", "length", "style", "core", "ban", "genderTail", history, "status", "grp:now"],
        "group": ["groupOpening", "@data", "members", "summary", "groupRules", "rules", "caps", "ban", "genderTail", history, "inner", "grp:now"],
        "call": ["opening", "gender", "@data", "summary", "groupNote", "core", "ban", "genderTail", "grp:now", "call", "callScript", history],
    ]

    /// 数据组按 injectOrder 里各组第一块出现的先后排。群聊固定。
    private static func dataOrder(_ mode: String, _ order: [String]?) -> [String] {
        if mode == "group" { return dataGroup.map { "grp:\($0)" } }
        var seen: [String] = []
        for id in resolveOrder(order) {
            let g = groupOf(id)
            if g != "now", dataChat.contains(g), !seen.contains(g) { seen.append(g) }
        }
        for g in dataChat where !seen.contains(g) { seen.append(g) }
        return seen.map { "grp:\($0)" }
    }

    static func defaultIds(_ mode: String, _ order: [String]?) -> [String] {
        (defaults[mode] ?? defaults["chat"]!).flatMap { $0 == "@data" ? dataOrder(mode, order) : [$0] }
    }

    // MARK: - 自己加的条目

    struct Custom: Identifiable, Equatable {
        var id: String
        var name: String
        var text: String
        var json: [String: JSONValue]
    }

    static func customs(_ s: AppSettings) -> [Custom] {
        (s.raw["promptCustom"]?.array ?? []).compactMap { v in
            guard let o = v.object, let id = o["id"]?.string else { return nil }
            return Custom(id: id, name: o["name"]?.string ?? "", text: o["text"]?.string ?? "", json: o)
        }
    }

    // MARK: - 开关

    static func isLocked(_ id: String) -> Bool { segments[id]?.locked ?? false }

    /// 这一条跟随哪里的开关；不跟随回空串。跟随别处开关的条目在预设里只排位置、不能关（网页版 4.485）。
    static func followOf(_ id: String) -> String {
        if id.hasPrefix("grp:") { return groups[String(id.dropFirst(4))]?.follow ?? "" }
        return segments[id]?.follow ?? ""
    }

    static func isFixed(_ id: String) -> Bool { isLocked(id) || !followOf(id).isEmpty }

    struct Item: Equatable, Identifiable {
        var id: String
        var on: Bool
    }

    /// 这一种情形的条目顺序：存着的为准；存着的里没有的按默认位置补进去，认不出的丢掉。「聊天记录」一定在。
    static func resolve(_ mode: String, _ s: AppSettings) -> [Item] {
        let defs = defaultIds(mode, injectOrder(s))
        let known = Set(defs + customs(s).map { "custom:\($0.id)" })
        let stored = (s.raw["promptLayout"]?.object?[mode]?.array ?? []).compactMap { v -> Item? in
            guard let id = v["id"]?.string, known.contains(id) else { return nil }
            return Item(id: id, on: v["on"]?.bool != false || isFixed(id))
        }
        var out: [Item] = []
        var seen = Set<String>()
        for it in stored where !seen.contains(it.id) { seen.insert(it.id); out.append(it) }
        for (i, id) in defs.enumerated() where !seen.contains(id) {
            seen.insert(id)
            var at = 0
            for k in stride(from: i - 1, through: 0, by: -1) {
                if let j = out.firstIndex(where: { $0.id == defs[k] }) { at = j + 1; break }
            }
            out.insert(Item(id: id, on: true), at: at)
        }
        // 通话的聊天记录在 system 外面，下面不放东西
        if mode == "call", let h = out.firstIndex(where: { $0.id == history }) {
            out.append(out.remove(at: h))
        }
        return out
    }

    /// 按条目顺序把算好的各段排起来。pieces：id 对应文字，grp:xxx 是各数据组。
    /// 回来两段：system（聊天记录上面的），tail（下面的，贴着最后一条插进对话）。
    static func arrange(_ mode: String, pieces: [String: String], settings s: AppSettings, names: [String: String]) -> (system: String, tail: String) {
        let byId = Dictionary(customs(s).map { ("custom:\($0.id)", $0) }, uniquingKeysWith: { a, _ in a })
        var sys: [String] = []
        var tail: [String] = []
        var below = false
        for it in resolve(mode, s) {
            if it.id == history { below = true; continue }
            if !it.on && !isFixed(it.id) { continue }
            let raw = byId[it.id].map { Templates.fill($0.text, names) } ?? pieces[it.id] ?? ""
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if below && mode != "call" { tail.append(text) } else { sys.append(text) }
        }
        return (sys.joined(separator: "\n\n"), tail.joined(separator: "\n\n"))
    }

    /// 各数据组的文字：区块按 injectOrder 的先后，同一组里的用空行连起来。
    static func groupPieces(_ blocks: [String: String], order: [String]?) -> [String: String] {
        var out: [String: [String]] = [:]
        for id in resolveOrder(order) {
            let t = (blocks[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out["grp:\(groupOf(id))", default: []].append(t) }
        }
        return out.mapValues { $0.joined(separator: "\n\n") }
    }
}
