import Foundation

/// 删角色时一并清掉的数据（网页版 system/purge.js 的 dropCharacter）。
///
/// People.deleteCharacter 先处理会话、按 charId 索引的那几个数据域（日程、三餐、记忆、梦、印象……）与日记；
/// 其余数据域里指着这个角色的，按字段在这里逐一处理，与网页版同一套取舍：它自己的删掉，你的留着、只摘掉对它的指向。
/// 原生版大多还没有这些 app，数据是从网页版备份导入的：不清干净，删掉的角色留下的孤儿数据导出回网页版后还在。
/// 图片不删：同一张图可能被别处引用，删图要先核引用（网页版第 20 条），交给以后的「清理无引用图片」。
enum Purge {
    private static var db: Database { .shared }

    private static func drop(_ c: String, _ match: (Row) -> Bool) throws {
        for r in try db.all(c) where match(r) { try db.delete(c, id: r.id) }
    }

    private static func patch(_ c: String, _ match: (Row) -> Bool, _ change: (inout Row) -> Void) throws {
        for var r in try db.all(c) where match(r) {
            change(&r)
            r.touch()
            try db.put(c, r)
        }
    }

    private static func ids(_ r: Row, _ key: String) -> [String] { r.strings(key) }

    static func dropCharacter(_ id: String) throws {
        // 不挂会话的长篇：人物没了作品也就没了，连着每一章与正文
        for w in try db.all("works") where w.string("chatId").isEmpty && ids(w, "castIds").contains(id) {
            for ch in try db.all("chapters") where ch.string("workId") == w.id {
                try drop("beats") { $0.string("sceneId") == ch.id }
                try db.delete("chapters", id: ch.id)
            }
            try db.delete("works", id: w.id)
        }
        try drop("moments") { $0.string("authorId") == id }
        try drop("health") { $0.string("who") == id }
        try drop("reviews") { $0.string("charId") == id }
        try drop("todos") { $0.string("charId") == id }
        try drop("readnotes") { $0.string("authorId") == id }
        // 它自己的心愿删掉；你的心愿里关联它的那几条留着，只是不再关联任何角色
        try drop("wishes") { $0.string("owner") == id }
        try patch("wishes", { $0.string("owner") == "me" && $0.string("charId") == id }) { $0["charId"] = .string("") }
        // 它对别人、别人对它的好友与拉黑状态
        try drop(Ties.collection) { $0.string("from") == id || $0.string("to") == id }
        // 它来回的那几段短信，连同里面的消息
        for t in try db.all("smsThreads") where t.string("charId") == id {
            try db.deleteAll(Collections.messages, where: t.id)
            try db.delete("smsThreads", id: t.id)
        }
        // 自定义互动标识：从勾选里去掉它（定义本身留着）
        try patch("badgeDefs", { ids($0, "charIds").contains(id) }) { r in
            r["charIds"] = .array(ids(r, "charIds").filter { $0 != id }.map { .string($0) })
        }
        try drop("fateLines") { $0.string("charId") == id }
        try patch("fateLines", { $0.string("copyCharId") == id }) { $0["copyCharId"] = .string("") }
        // 论坛里的账号：退出入驻，发过的帖子留着
        try patch("forums", { ($0["members"]?.array ?? []).contains { $0["charId"]?.string == id } }) { r in
            r["members"] = .array((r["members"]?.array ?? []).filter { $0["charId"]?.string != id })
        }
        // 商城：它的商城身份、它挂的还没卖出的商品、它参与的议价。订单留着
        for p in try db.all("mallPeople") where p.string("kind") == "char" && p.string("charId") == id {
            for it in try db.all("mallItems") where it.string("sellerId") == p.id && it.string("state") != "sold" {
                try drop("mallThreads") { $0.string("itemId") == it.id }
                try db.delete("mallItems", id: it.id)
            }
            try drop("mallThreads") { $0.string("buyerId") == p.id || $0.string("sellerId") == p.id }
            try db.delete("mallPeople", id: p.id)
        }
        try dropSlips(id)
        // 专注：陪伴过的那几次去掉陪伴角色，记录本身是用户的
        try patch("focuses", { $0.string("companionId") == id }) { $0["companionId"] = .string("") }
        // 我的日记里关联它的那几篇留着，改成不关联任何角色
        try patch("diaries", { $0.string("owner") == "me" && $0.string("charId") == id }) { $0["charId"] = .string("") }
        // 角色自己建的歌单。歌本身留在曲库里
        try drop("playlists") { $0.string("owner") == id }
        // 角色的衣帽间。我这边收着的它送的东西不动
        try drop("closet") { $0.string("owner") == id }
        try dropCollection(id)
        // 宠物：它自己的删，和我一起养的改成我的；对着它的摄像头与监控记录
        try drop("pets") { $0.string("charId") == id && $0.string("owner") == "char" }
        try patch("pets", { $0.string("charId") == id }) { $0["owner"] = .string("me"); $0["charId"] = .string("") }
        try drop("camLogs") { $0.string("targetId") == id && $0.string("kind") == "char" }
        try drop("cams") { $0.string("targetId") == id && $0.string("kind") == "char" }
        try drop("quizRuns") { $0.string("charId") == id }
        // 我的人设里「与它相关」的条目，以及别的条目可见名单里的它
        try patch(Collections.personas, { p in
            (p["charNotes"]?.array ?? []).contains { $0["charId"]?.string == id || ($0["visIds"]?.array ?? []).contains(.string(id)) }
        }) { p in
            let kept = (p["charNotes"]?.array ?? []).filter { $0["charId"]?.string != id }.map { n -> JSONValue in
                guard var o = n.object else { return n }
                o["visIds"] = .array((o["visIds"]?.array ?? []).filter { $0 != .string(id) })
                return .object(o)
            }
            p["charNotes"] = .array(kept)
        }
        // 别人身上指着它的那条关系
        try patch(Collections.characters, { r in
            r.id != id && (r["relations"]?.array ?? []).contains { $0["charId"]?.string == id }
        }) { r in
            r["relations"] = .array((r["relations"]?.array ?? []).filter { $0["charId"]?.string != id })
        }
        // 设置里指着它的：你的日程里「不给这个角色看」、专注的陪伴角色
        var s = try AppSettings.loadForWrite()
        var changed = false
        if let hid = s.raw["userSchedHidden"]?.array, hid.contains(.string(id)) {
            s.raw["userSchedHidden"] = .array(hid.filter { $0 != .string(id) }); changed = true
        }
        if var fc = s.raw["focus"]?.object, fc["companionId"]?.string == id {
            fc["companionId"] = .string(""); s.raw["focus"] = .object(fc); changed = true
        }
        if changed { try s.save() }
        Proactive.setNext(id, 0)
    }

    /// 密语（网页版 slip.dropChar）：它的个人与私人纸条盒、它写的纸条；双人盒移出它，对象与看过的人里去掉它
    private static func dropSlips(_ id: String) throws {
        func dropSlip(_ sid: String) throws {
            try drop("slipLog") { $0.string("slipId") == sid }
            try db.delete("slips", id: sid)
        }
        for b in try db.all("boxes") where ["own", "private"].contains(b.string("kind")) && b.string("owner") == id {
            for sl in try db.all("slips") where sl.string("boxId") == b.id { try dropSlip(sl.id) }
            try db.delete("boxes", id: b.id)
        }
        for sl in try db.all("slips") where sl.string("author") == id { try dropSlip(sl.id) }
        for b in try db.all("boxes") where b.string("kind") == "pair" && ids(b, "members").contains(id) {
            let rest = ids(b, "members").filter { $0 != id }
            if rest.count < 2 {
                for sl in try db.all("slips") where sl.string("boxId") == b.id { try dropSlip(sl.id) }
                try db.delete("boxes", id: b.id)
            } else {
                var r = b
                r["members"] = .array(rest.map { .string($0) })
                r.touch()
                try db.put("boxes", r)
            }
        }
        try patch("boxes", { ($0["invites"]?.array ?? []).contains { $0["charId"]?.string == id } }) { r in
            r["invites"] = .array((r["invites"]?.array ?? []).filter { $0["charId"]?.string != id })
        }
        try patch("slipLog", { $0.bool("pending") && $0.string("holder") == id }) { $0["pending"] = .bool(false) }
        try patch("slips", { r in
            (r["to"]?.object?["ids"]?.array ?? []).contains(.string(id)) || ids(r, "knows").contains(id)
        }) { r in
            var to = r["to"]?.object ?? [:]
            let rest = (to["ids"]?.array ?? []).filter { $0 != .string(id) }
            if to["kind"]?.string == "chars" && rest.isEmpty {
                to = ["kind": .string("none"), "ids": .array([])]
            } else {
                to["ids"] = .array(rest)
            }
            r["to"] = .object(to)
            r["knows"] = .array(ids(r, "knows").filter { $0 != id }.map { .string($0) })
        }
    }

    /// 收藏馆（网页版 collect.handOver / forgetPerson）：它与别人共同拥有的交给另一方；它自己的删掉；
    /// 别人与它共有的改回不共有，它送的赠送人留空
    private static func dropCollection(_ id: String) throws {
        let all = try db.all("collection")
        for r in all where r.string("owner") == id && r.string("parentId").isEmpty && !r.string("shared").isEmpty && r.string("shared") != id {
            let to = r.string("shared")
            for x in all where x.id == r.id || x.string("parentId") == r.id {
                var y = x
                y["owner"] = .string(to)
                if x.id == r.id { y["shared"] = .string("") }
                y.touch()
                try db.put("collection", y)
            }
        }
        try drop("collection") { $0.string("owner") == id }
        try patch("collection", { $0.string("shared") == id || $0.string("giver") == id }) { r in
            if r.string("shared") == id { r["shared"] = .string("") }
            if r.string("giver") == id { r["giver"] = .string("") }
        }
    }
}
