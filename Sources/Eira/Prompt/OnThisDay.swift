import Foundation

/// 那年今天（网页版 system/onthisday.js，ARCHITECTURE 4.166）：往年的同一天，这段对话里说过什么。全在本机翻，不调接口。
///
/// 「同一天」按月日算，2 月 29 日只在闰年那一天对得上。只算你和角色都开过口的那一天。
enum OnThisDay {
    struct Year: Identifiable {
        var year: Int
        var ago: Int
        var msgs: [Message]
        var id: Int { year }
    }

    static func ofChat(_ chatId: String, at: Date = Date()) -> [Year] {
        let cal = Calendar.current
        let key = cal.dateComponents([.month, .day, .year], from: at)
        var byYear: [Int: [Message]] = [:]
        for m in (try? Repo.messages(chatId: chatId)) ?? [] where m.createdAt > 0 && !m.isError {
            let d = cal.dateComponents([.month, .day, .year], from: Date(millis: m.createdAt))
            guard let y = d.year, let ty = key.year, y < ty, d.month == key.month, d.day == key.day else { continue }
            byYear[y, default: []].append(m)
        }
        return byYear.compactMap { y, msgs -> Year? in
            guard msgs.contains(where: { $0.role == .user }), msgs.contains(where: { $0.role == .char }) else { return nil }
            return Year(year: y, ago: (key.year ?? y) - y, msgs: msgs.sorted { $0.createdAt < $1.createdAt })
        }.sorted { $0.year > $1.year }
    }

    /// 非文字消息写成一个方括号标签（和消息列表那一行同一种写法）
    static func textOf(_ m: Message) -> String {
        let kinds = ["sticker": "[表情]", "image": "[图片]", "voice": "[语音]", "transfer": "[转账]", "location": "[位置]",
                     "gift": "[礼物]", "takeout": "[外卖]", "dice": "[骰子]", "narration": "[旁白]", "file": "[文件]",
                     "listen": "[一起听]", "call": "[通话]", "letter": "[信]", "pact": "[约定]", "video": "[视频]"]
        if m.kind == "text" { return m.content }
        return kinds[m.kind] ?? "[消息]"
    }
}
