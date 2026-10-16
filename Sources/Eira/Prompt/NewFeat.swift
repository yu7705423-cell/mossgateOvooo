import Foundation

/// 新功能默认不注入（网页版 system/ai/newfeat.js，ARCHITECTURE 4.486，网页版第 24 条）。
///
/// 规矩定下时已有的能力与区块记在两张基线表里，照旧由各自的开关决定；之后新加的必须登记进 features，
/// 开不开看 settings.featureOpt[id]（"on" / "off"，没有就是还没问过，即不注入）。两张基线表照抄网页版，只许删不许加：
/// 往里加等于绕过这条规矩。NewFeatTests 核对原生拼进提示词的每一项能力与区块，不在基线里就必须在 features 里。
enum NewFeat {
    static let baseCaps: Set<String> = ["image", "video", "voice", "sticker", "keepphoto", "quote", "transfer", "gift", "mcp", "listen",
        "ring", "todo", "alt", "altadmit", "ties", "forumpost", "friendmoment", "smssend", "smsid", "wish", "dream", "acquire",
        "mall", "slip", "drafts", "location", "joint", "pact", "trip", "award", "watch", "agenda", "takeout", "outfit", "closetact",
        "lockcode", "pat", "groupnick", "groupadmin", "dm", "dice", "avatar", "remark", "react", "silence", "recall", "card", "file",
        "narration", "inner", "time", "translate"]

    static let baseBlocks: Set<String> = ["lorebook", "bond", "state", "pinned", "recent", "character", "loreAfter", "user", "impress",
        "alts", "groups", "privateRecent", "groupState", "linkRecent", "time", "dates", "day", "avatar", "geo", "music", "watch",
        "trip", "bill", "health", "fit", "closet", "collect", "mall", "forum", "slip", "focus", "memory", "space", "wishes", "diary",
        "dream", "fate", "ties", "sms", "proxy", "plan", "userSched", "moments", "friendMoments", "bridge", "badges"]

    struct Feature {
        let id: String
        let label: String
        /// 开了之后角色多知道 / 多能做什么、提示词大约多多少、会不会多调接口
        let desc: String
        /// 第一次打开时询问的那个 app
        let app: String
        var caps: [String] = []
        var blocks: [String] = []
    }

    /// 网页版 FEATURES 的一部分，不是全部。网页版共 9 项；这里列宠物、测试问卷两项（所在的 app 原生版尚未提供，
    /// 列出来是因为 featureOpt 两边共用，在这里改的就是导入进来的那一份）。其余 7 项（娱乐卡、门禁卡与钥匙、票券、会员卡、
    /// 扭蛋机、在群里发消息、暂时离开）原生版没有对应的能力与区块，做到时照网页版原文登记；用户在网页版选过的 featureOpt 原样留着
    static let features: [Feature] = [
        Feature(id: "pets", label: "宠物",
                desc: "开启后，角色知道自己的宠物、与你一起养的宠物和你自己的宠物，以及资料里填写的内容；每只宠物大约多几十到两百字，不多调用接口。监控记录不进提示词",
                app: "monitor", blocks: ["pets"]),
        Feature(id: "quiz", label: "测试问卷",
                desc: "开启后，角色记得最近几次与你一起做过的测试，并可以从已有的问卷里挑一份发给你作答。不多调用接口；角色作答仍由你在结果页点了才调用",
                app: "play", caps: ["quiz"], blocks: ["quizzes"]),
    ]

    static func decided(_ id: String, _ s: AppSettings) -> String { s.raw["featureOpt"]?.object?[id]?.string ?? "" }
    static func isOn(_ id: String, _ s: AppSettings) -> Bool { decided(id, s) == "on" }

    /// 这项能力能不能进提示词：不是新功能照旧（由各自的开关决定），是新功能看用户开没开
    static func capOn(_ id: String, _ s: AppSettings) -> Bool {
        guard let f = features.first(where: { $0.caps.contains(id) }) else { return true }
        return isOn(f.id, s)
    }

    static func blockOn(_ id: String, _ s: AppSettings) -> Bool {
        guard let f = features.first(where: { $0.blocks.contains(id) }) else { return true }
        return isOn(f.id, s)
    }

    static func set(_ id: String, _ on: Bool, _ s: inout AppSettings) {
        var o = s.raw["featureOpt"]?.object ?? [:]
        o[id] = .string(on ? "on" : "off")
        s.raw["featureOpt"] = .object(o)
    }

    /// 能不能在这一边登记：基线或新功能里有它
    static func known(cap id: String) -> Bool { baseCaps.contains(id) || features.contains { $0.caps.contains(id) } }
    static func known(block id: String) -> Bool { baseBlocks.contains(id) || features.contains { $0.blocks.contains(id) } }
}
