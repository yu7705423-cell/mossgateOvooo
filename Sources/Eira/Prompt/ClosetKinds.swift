import Foundation

/// 衣帽间的分类表（网页版 system/closet-kinds.js，ARCHITECTURE 4.213）。**只有这一份**：界面、识图、上下文都从这里读。
///
/// 三层：大类、小类、单品。颜色、季节、场合、来源、状态是横切的标签，只用来筛选，不决定位置。
/// 妆台的小类另带默认值：每次用量的单位与数量、开封后能用几个月（pao）、主要记色号（shade）。名字是数据，与网页版一字不差。
enum ClosetKinds {
    struct Sub: Equatable, Sendable {
        var label: String
        var unit = ""
        var dose = 0.0
        var pao = 0.0
        var shade = false
        var custom = false
    }

    struct Group: Equatable, Sendable, Identifiable {
        var id: String
        var side: String
        var label: String
        var subs: [Sub]
    }

    struct Tag: Equatable, Sendable, Identifiable {
        var id: String
        var label: String
    }

    static let sides: [Tag] = [Tag(id: "wear", label: "衣橱"), Tag(id: "beauty", label: "妆台")]

    private static func w(_ labels: [String]) -> [Sub] { labels.map { Sub(label: $0) } }

    static let groups: [Group] = [
        // ---- 衣橱 ----
        Group(id: "top", side: "wear", label: "上装", subs: w(["T 恤", "衬衫", "针织 / 毛衣", "卫衣", "背心 / 吊带"])),
        Group(id: "bottom", side: "wear", label: "下装", subs: w(["长裤", "牛仔裤", "半身裙", "短裤"])),
        Group(id: "onepiece", side: "wear", label: "连身", subs: w(["连衣裙", "连体裤", "套装"])),
        Group(id: "outer", side: "wear", label: "外套", subs: w(["大衣", "风衣", "夹克", "西装", "羽绒服", "开衫"])),
        Group(id: "shoes", side: "wear", label: "鞋", subs: w(["运动鞋", "靴子", "高跟鞋", "平底 / 乐福", "凉拖"])),
        Group(id: "bag", side: "wear", label: "包", subs: w(["手提", "斜挎", "双肩", "托特", "手拿"])),
        Group(id: "jewelry", side: "wear", label: "首饰", subs: w(["戒指", "项链", "耳饰", "手链 / 手镯", "胸针"])),
        Group(id: "acc", side: "wear", label: "配饰", subs: w(["帽子", "围巾", "领带", "眼镜", "腰带", "发饰", "手表", "袜子"])),
        Group(id: "home", side: "wear", label: "家居", subs: w(["睡衣", "家居服", "贴身"])),
        // 随身：包里带着的小东西。勾上是「今天带着」，不算穿在身上（4.216）
        Group(id: "carry", side: "wear", label: "随身", subs: w(["伞", "耳机", "相机", "钥匙", "零食", "小物"])),
        // ---- 妆台 ----
        Group(id: "skin", side: "beauty", label: "护肤", subs: [
            Sub(label: "洁面", unit: "克", dose: 1, pao: 12), Sub(label: "化妆水", unit: "毫升", dose: 2, pao: 12),
            Sub(label: "精华", unit: "滴管", dose: 1, pao: 12), Sub(label: "乳霜", unit: "克", dose: 0.5, pao: 12),
            Sub(label: "眼霜", unit: "克", dose: 0.1, pao: 6), Sub(label: "防晒", unit: "毫升", dose: 1, pao: 12),
            Sub(label: "面膜", unit: "片", dose: 1, pao: 0),
        ]),
        Group(id: "base", side: "beauty", label: "底妆", subs: [
            Sub(label: "妆前", unit: "泵", dose: 1, pao: 12), Sub(label: "粉底", unit: "泵", dose: 2, pao: 12),
            Sub(label: "遮瑕", unit: "克", dose: 0.1, pao: 12), Sub(label: "定妆", unit: "克", dose: 0.2, pao: 24),
        ]),
        Group(id: "eye", side: "beauty", label: "眼妆", subs: [
            Sub(label: "眼影", pao: 24, shade: true), Sub(label: "眼线", pao: 6, shade: true),
            Sub(label: "睫毛膏", pao: 3, shade: true), Sub(label: "眉笔", pao: 24, shade: true),
        ]),
        Group(id: "lip", side: "beauty", label: "唇妆", subs: [
            Sub(label: "口红", pao: 18, shade: true), Sub(label: "唇釉", pao: 12, shade: true), Sub(label: "润唇", pao: 12),
        ]),
        Group(id: "cheek", side: "beauty", label: "修容", subs: [
            Sub(label: "腮红", pao: 24, shade: true), Sub(label: "高光", pao: 24, shade: true), Sub(label: "修容", pao: 24, shade: true),
        ]),
        Group(id: "scent", side: "beauty", label: "香氛", subs: [
            Sub(label: "香水", unit: "喷", dose: 2, pao: 36), Sub(label: "香膏", unit: "克", dose: 0.1, pao: 12),
            Sub(label: "身体乳", unit: "泵", dose: 2, pao: 12),
        ]),
        Group(id: "hair", side: "beauty", label: "发与身体", subs: [
            Sub(label: "洗护", unit: "泵", dose: 2, pao: 12), Sub(label: "造型", unit: "喷", dose: 3, pao: 24),
            Sub(label: "身体护理", unit: "泵", dose: 2, pao: 12),
        ]),
        Group(id: "tool", side: "beauty", label: "工具", subs: w(["刷具", "美妆蛋", "卷发棒"])),
    ]

    /// 每次用量的单位换成毫升（或克，一比一）大约是多少。片、次按「一次一个」
    static let dose: [String: Double] = ["泵": 0.25, "滴管": 0.5, "喷": 0.1, "毫升": 1, "克": 1, "片": 1, "次": 1]
    static let doseUnits = ["泵", "滴管", "喷", "毫升", "克", "片", "次"]
    static let capUnits = ["毫升", "克", "片"]
    /// 只有购入日期、没开封时，按这么多个月算未开封的保质期
    static let shelfMonths = 36.0

    static let channels = ["官网", "实体店", "淘宝", "二手", "代购"]
    static let washWays: [Tag] = [Tag(id: "machine", label: "机洗"), Tag(id: "hand", label: "手洗"), Tag(id: "dry", label: "干洗"), Tag(id: "nowash", label: "不可水洗")]
    static let washRules: [Tag] = [Tag(id: "", label: "不提醒"), Tag(id: "wears", label: "按穿着次数"), Tag(id: "days", label: "按天数")]

    /// 色系。原生版不画彩色色块（规约第 4 条只用黑白灰），只用名字
    static let colors: [Tag] = [
        Tag(id: "black", label: "黑"), Tag(id: "white", label: "白"), Tag(id: "gray", label: "灰"), Tag(id: "beige", label: "米"),
        Tag(id: "brown", label: "棕"), Tag(id: "red", label: "红"), Tag(id: "pink", label: "粉"), Tag(id: "orange", label: "橙"),
        Tag(id: "yellow", label: "黄"), Tag(id: "green", label: "绿"), Tag(id: "blue", label: "蓝"), Tag(id: "purple", label: "紫"),
        Tag(id: "gold", label: "金"), Tag(id: "silver", label: "银"), Tag(id: "multi", label: "花色"),
    ]
    static let seasons: [Tag] = [Tag(id: "spring", label: "春"), Tag(id: "summer", label: "夏"), Tag(id: "autumn", label: "秋"), Tag(id: "winter", label: "冬")]
    static let occasions: [Tag] = [
        Tag(id: "daily", label: "日常"), Tag(id: "work", label: "通勤"), Tag(id: "date", label: "约会"),
        Tag(id: "formal", label: "正式"), Tag(id: "sport", label: "运动"), Tag(id: "home", label: "居家"),
    ]
    static let sources: [Tag] = [Tag(id: "self", label: "自己买的"), Tag(id: "gift", label: "收到的礼物"), Tag(id: "made", label: "一起做的")]
    /// 已用完、已送出的不删，默认不显示，也不告诉角色
    static let states: [Tag] = [
        Tag(id: "", label: "在用"), Tag(id: "fav", label: "收藏"), Tag(id: "idle", label: "闲置"),
        Tag(id: "done", label: "已用完"), Tag(id: "gone", label: "已送出"), Tag(id: "sold", label: "已卖出"),
    ]
    static let goneStates: Set<String> = ["done", "gone", "sold"]

    static func side(_ id: String) -> Tag { sides.first { $0.id == id } ?? sides[0] }
    static func group(_ id: String) -> Group? { groups.first { $0.id == id } }
    static func label(_ list: [Tag], _ id: String) -> String { list.first { $0.id == id }?.label ?? "" }
}
