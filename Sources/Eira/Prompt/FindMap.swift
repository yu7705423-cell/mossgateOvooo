import Foundation

/// 找功能（网页版 system/findmap.js，ARCHITECTURE 4.646）：一样功能在哪儿、怎么过去。
///
/// 一行一样功能：名字、位置的写法、要找它的人会打的词、过去的那一页（`dest`，由 `FindPlaceView` 画）。不记说明，说明在说明书里。
/// 只登记原生版真有的那几页；网页版有、原生版没做的不列，免得点了过去是空的。
/// 用在两处：主屏下滑搜索的「功能」一组，说明书搜索上面的「位置」。
///
/// per：这一项挂在某一段对话（chat）或某个角色（char）上（第 5 条：开关放在对象自己身上）。
/// 从主屏或说明书找到它时，先选是哪一段对话；只有一段时直接进去。group：群聊里也有这一项（没写的只在单聊里）。
/// 页面改名、挪位置，这里跟着改一行；FindMapTests 核对每一项的 dest 都画得出来。
enum FindMap {
    enum Per: Sendable { case global, chat, char }

    struct Entry: Identifiable, Hashable, Sendable {
        let t: String
        let at: String
        let dest: String
        var per: Per = .global
        var group = false
        let k: String
        var id: String { t }
    }

    private static func e(_ t: String, _ at: String, _ dest: String, per: Per = .global, group: Bool = false, _ k: String) -> Entry {
        Entry(t: t, at: at, dest: dest, per: per, group: group, k: k)
    }

    static let entries: [Entry] = [
        // ---- 挂在一段对话上的：会话右上角的菜单 ----
        e("角色能力", "会话右上角菜单 - 角色能力", "abilities", per: .char,
          "能力 开关 让角色 发语音 语音 发图 图片 照片 表情 转账 通话 打电话 来电 一起听 礼物 约定 发文件 文件 日程 外卖 拍一拍 改备注 锁屏密码 撤回 回应 不回复 骰子 随机事件 位置 锁脸 长相 生图提示词"),
        e("节奏与自动回复", "会话右上角菜单 - 节奏与自动回复", "pace", per: .chat, group: true,
          "回复节奏 延迟回复 自动回复 成员的自动回复 发完就回 按按钮才回 忙碌 暂时离开 回几条"),
        e("主动发起对话", "会话右上角菜单 - 主动发起对话", "proactive", per: .char,
          "主动消息 主动找我 定时 间隔 免打扰 深夜 主动发消息"),
        e("心声", "会话右上角菜单 - 心声", "inner", per: .chat, group: true, "心声 内心 心声卡片 卡片模板"),
        e("互动", "会话右上角菜单 - 互动", "extras", per: .chat, group: true, "旁白 拍一拍后缀 骰子面数 草稿箱"),
        e("状态栏", "会话右上角菜单 - 状态栏", "status", per: .chat, "状态栏 好感度 数值 栏目"),
        e("翻译", "会话右上角菜单 - 翻译", "translate", per: .chat, group: true, "翻译 译文 外语 双语"),
        e("记忆总结", "会话右上角菜单 - 记忆总结", "summary", per: .chat, group: true, "记忆 总结 自动总结 忘了 记不住 隔夜"),
        e("关系底色", "会话右上角菜单 - 关系底色", "bond", per: .chat, "关系 底色 关系描述"),
        e("互动标识", "会话右上角菜单 - 互动标识", "badges", per: .chat, group: true, "火花 连续互发 等级 徽章 年度回顾 标识"),
        e("美化", "会话右上角菜单 - 美化", "skin", per: .chat, group: true, "美化 气泡 美化包 css 头像形状 已读 字体"),
        e("聊天背景", "会话右上角菜单 - 聊天背景", "look", per: .chat, group: true, "背景 聊天背景 壁纸 遮罩 模糊"),
        e("搜索聊天记录", "会话右上角菜单 - 搜索", "search", per: .chat, group: true, "聊天记录 查找 找消息 搜索"),
        e("角色卡", "会话右上角菜单 - 角色卡与备注", "card", per: .char,
          "角色卡 头像 音色 音色id 语种 语速 时区 所在地区 关联世界书 备注"),
        e("拉黑与删除好友", "会话右上角菜单 - 好友与拉黑", "ties", per: .chat, "拉黑 删除好友 解除拉黑 屏蔽"),
        e("导出与清空这段对话", "会话右上角菜单 - 更多", "more", per: .chat, group: true, "清空聊天记录 清空记忆 每轮的接口调用"),

        // ---- 对所有角色生效的：设定集 ----
        e("能力开关", "设定集 - 能力", "caps", "能力 全局 所有角色 新功能 开启新功能"),
        e("世界书", "设定集 - 世界书", "lore", "世界书 设定 条目 关键词 导入世界书"),
        e("记忆", "设定集 - 记忆", "memory", "记忆 记忆库 编辑记忆 导入记忆"),
        e("预设", "设定集 - 预设", "presets", "预设 条目 参数 温度 每轮条数 回几条 思维链 提示词 模板 文风 上下文 历史 读几条 轮数"),
        e("不要写这些", "设定集 - 不要写这些", "ban", "禁词 屏蔽词 不要写 八股"),
        e("正则替换", "设定集 - 正则替换", "regex", "正则 替换 regex"),

        // ---- 设置 ----
        e("主用接口", "设置 - 接口与服务 - 接口", "api", "接口 api 密钥 key 模型 中转 主用 副用 base url 换模型"),
        e("任务用哪套接口", "设置 - 接口与服务 - 任务用哪套接口", "routes", "任务 接口 路由 分开"),
        e("记忆接口", "设置 - 接口与服务 - 记忆接口", "memoryApi", "记忆接口"),
        e("语音合成", "设置 - 接口与服务 - 语音合成", "voice", "语音接口 tts 音色 minimax 朗读"),
        e("生图", "设置 - 接口与服务 - 生图", "image", "生图 画图 生图接口 全局生图提示词 参考图 画风"),
        e("音乐服务", "设置 - 接口与服务 - 音乐服务", "music", "音乐 网易云 qq音乐 登录音乐"),
        e("和风天气", "设置 - 接口与服务 - 和风天气", "weather", "天气 和风"),
        e("识图", "设置 - 接口与服务 - 识图", "vision", "识图 看图 读图"),
        e("语音识别", "设置 - 接口与服务 - 语音识别", "asr", "语音识别 语音转文字 asr"),
        e("翻译接口", "设置 - 接口与服务 - 翻译", "translateApi", "翻译接口"),
        e("消息通知", "设置 - 消息通知", "notify", "通知 提醒 横幅"),
        e("后台消息", "设置 - 后台消息", "bgpush", "后台消息 推送 推送服务器 worker 部署"),
        e("用量与上限", "设置 - 用量与上限", "limits", "用量 上限 花钱 省钱 重试 额外调用 每轮调用 次数 失败换接口"),
        e("节日", "设置 - 节日", "holidays", "节日 纪念日 生日"),
        e("主题与壁纸", "设置 - 主题", "appearance", "主题 深色 夜间 壁纸 图标 字体 字号 配色 回应样式 锁屏 界面"),
        e("锁屏密码", "设置 - 主题 - 锁屏 - 锁屏密码", "lockpin", "锁屏 密码 解锁 我的锁屏"),
        e("存储与备份", "设置 - 存储与备份", "storage", "备份 导出 导入 恢复 换手机 清空数据 存储 占用 网页版"),
        e("说明书", "设置 - 说明书", "help", "说明书 帮助 怎么用"),
        e("问题反馈", "设置 - 问题反馈", "feedback", "反馈 问题 出错 闪退"),
        e("使用须知", "设置 - 使用须知", "terms", "使用须知 须知 条款 隐私"),

        // ---- 其余几处 ----
        e("时间感知", "聊天 - 会话右上角菜单 - 时间感知", "time", "时间 时区 时差 虚拟时间 固定时间"),
        e("表情包", "聊天 - 会话右上角菜单 - 更多 - 表情包", "stickers", "表情包 导入表情 贴纸"),
        e("我的人设", "联系 - 我", "personas", "我的人设 人设 我的资料 我的锁脸 我的长相 用户 小号 多个身份"),
        e("主屏图标与名字", "主屏 - 长按图标", "", "图标 换图标 改名字 主屏 整理 排列 小组件 文件夹"),
    ]

    static func norm(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }

    /// 按词找（网页版 find）。整句（「怎么让角色发语音」）里含着表里的某个词也算。
    /// scope "chat"（会话菜单里）只给不挂在对话上的那几项；group 为 true 时只留群聊里也有的
    static func find(_ q: String, scope: String = "", group: Bool = false) -> [Entry] {
        let key = norm(q)
        guard !key.isEmpty else { return [] }
        var out: [(Entry, Int, Int)] = []
        for (i, e) in entries.enumerated() {
            if scope == "chat" && e.per != .global { continue }
            if group && e.per != .global && !e.group { continue }
            let t = norm(e.t)
            let words = e.k.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var score = 0
            if t == key { score = 5 }
            else if t.contains(key) { score = 4 }
            else if words.contains(key) { score = 3 }
            else if words.contains(where: { $0.contains(key) }) { score = 2 }
            else if key.count >= 3 && words.contains(where: { $0.count >= 2 && key.contains($0) }) { score = 1 }
            else if norm(e.at).contains(key) { score = 1 }
            if score > 0 { out.append((e, score, i)) }
        }
        return out.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map { $0.0 }
    }

    /// 挂在对话上的那一项能落到哪几段对话：只在单聊里的不给群聊；拉黑只给有好友关系的那几段。新的在前
    static func chats(for e: Entry, in all: [Chat]) -> [Chat] {
        all.filter { c in
            guard !c.characterIds.isEmpty, e.group || !c.isGroup else { return false }
            if e.dest == "ties" { return Ties.pair(c) != nil }
            return true
        }
        .sorted { $0.lastMessageAt > $1.lastMessageAt }
    }

    /// 列表里一段对话的名字：群聊用群名，单聊用角色的名字（备注优先）
    static func title(_ c: Chat, names: [String: String]) -> String {
        if c.isGroup { return c.title.isEmpty ? "群聊" : c.title }
        return c.characterIds.first.flatMap { names[$0] } ?? (c.title.isEmpty ? "会话" : c.title)
    }
}
